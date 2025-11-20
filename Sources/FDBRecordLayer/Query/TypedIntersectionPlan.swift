import Foundation
import FoundationDB

/// Query plan that computes intersection of multiple child plans
///
/// TypedIntersectionPlan supports two intersection strategies:
///
/// **1. Sorted-Merge Intersection (default):**
/// - Requires: Child plans return results ordered by primary key
/// - Algorithm: Streaming merge-join, O(1) memory
/// - Use case: Regular index scans with PK suffix
///
/// **2. Hash-Based Intersection (fallback):**
/// - Works with: Any cursor order (doesn't require PK sorting)
/// - Algorithm: Materialize smallest cursor to Set, filter others
/// - Use case: Range overlap queries, complex predicates
///
/// **Algorithm Selection:**
/// - If `requiresPKSort: false` → use hash-based
/// - Otherwise → use sorted-merge (assumes PK-sorted cursors)
///
/// **Usage:**
/// ```swift
/// // Regular intersection (PK-sorted)
/// let plan1 = TypedIndexScanPlan(...) // Scan city index
/// let plan2 = TypedIndexScanPlan(...) // Scan age index
/// let intersectionPlan = TypedIntersectionPlan(childPlans: [plan1, plan2])
///
/// // Range overlap intersection (not PK-sorted)
/// let plan1 = TypedIndexScanPlan(...) // Scan lowerBound < X
/// let plan2 = TypedIndexScanPlan(...) // Scan upperBound > Y
/// let intersectionPlan = TypedIntersectionPlan(childPlans: [plan1, plan2], requiresPKSort: false)
/// ```
///
/// **Performance:**
/// - Sorted-merge: Time O(n₁ + n₂ + ... + nₖ), Memory O(1)
/// - Hash-based: Time O(n₁ + n₂ + ... + nₖ), Memory O(min(n₁, n₂, ..., nₖ))
///
/// **Current Limitation (TODO):**
/// When `requiresPKSort: false`, ALL child plans use hash intersection, even if some
/// are PK-sorted (e.g., regular indexes mixed with Range indexes).
///
/// **Future Optimization:**
/// Implement hybrid intersection:
/// 1. Group plans into "PK-sorted" and "not PK-sorted"
/// 2. Hash-intersect the "not PK-sorted" group → produces PK set
/// 3. Sorted-merge the PK set with "PK-sorted" plans → streaming with O(1) memory
///
/// This would allow queries like `overlaps(capacity, ...) AND city == "Tokyo"` to use:
/// - Hash intersection for Range plans (capacity start/end indexes)
/// - Sorted-merge for regular index (city index)
///
/// Current behavior: All 3 plans use hash intersection (less memory-efficient)
internal struct TypedIntersectionPlan<Record: Sendable>: TypedQueryPlan {
    // MARK: - Properties

    /// Child plans to intersect
    internal let childPlans: [any TypedQueryPlan<Record>]

    /// Primary key expression for comparing records
    public let primaryKeyExpression: KeyExpression

    /// Whether child plans are guaranteed to return results in primary key order
    /// - true: Use sorted-merge intersection (O(1) memory, requires PK-sorted cursors)
    /// - false: Use hash-based intersection (O(n) memory, works with any cursor order)
    internal let requiresPKSort: Bool

    // MARK: - Initialization

    internal init(
        childPlans: [any TypedQueryPlan<Record>],
        primaryKeyExpression: KeyExpression,
        requiresPKSort: Bool = true
    ) {
        self.childPlans = childPlans
        self.primaryKeyExpression = primaryKeyExpression
        self.requiresPKSort = requiresPKSort
    }

    // MARK: - TypedQueryPlan

    internal func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: TransactionContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Execute all child plans concurrently
        let cursors: [AnyTypedRecordCursor<Record>] = try await withThrowingTaskGroup(
            of: (Int, AnyTypedRecordCursor<Record>).self
        ) { group in
            // Schedule all child plans
            for (index, childPlan) in childPlans.enumerated() {
                group.addTask {
                    let cursor = try await childPlan.execute(
                        subspace: subspace,
                        recordAccess: recordAccess,
                        context: context,
                        snapshot: snapshot
                    )
                    return (index, cursor)
                }
            }

            // Collect results in order
            var results: [(Int, AnyTypedRecordCursor<Record>)] = []
            for try await result in group {
                results.append(result)
            }

            // Sort by index to preserve plan order
            return results.sorted(by: { $0.0 < $1.0 }).map { $0.1 }
        }

        // Select intersection strategy based on cursor ordering
        if requiresPKSort {
            // Use sorted-merge intersection (O(1) memory, requires PK-sorted cursors)
            let intersectionCursor = TypedSortedMergeIntersectionCursor(
                cursors: cursors,
                recordAccess: recordAccess,
                primaryKeyExpression: primaryKeyExpression
            )
            return AnyTypedRecordCursor(intersectionCursor)
        } else {
            // Use hash-based intersection (O(n) memory, works with any cursor order)
            let intersectionCursor = TypedHashIntersectionCursor(
                cursors: cursors,
                recordAccess: recordAccess,
                primaryKeyExpression: primaryKeyExpression
            )
            return AnyTypedRecordCursor(intersectionCursor)
        }
    }
}

// MARK: - TypedSortedMergeIntersectionCursor

/// Cursor that performs streaming merge-join intersection
///
/// **Requirements**: All child cursors MUST return records in primary key order
///
/// **Algorithm**:
/// 1. Maintain current record for each cursor
/// 2. Extract primary keys from all current records
/// 3. If all PKs are equal → emit record, advance all cursors
/// 4. Otherwise → advance cursors with minimum PK
/// 5. Repeat until any cursor is exhausted
///
/// **Performance**:
/// - Time: O(n₁ + n₂ + ... + nₖ) where nᵢ is size of cursor i
/// - Memory: O(1) (streaming, no buffering)
///
/// **Use Case**: Regular index scans where index key includes PK suffix
struct TypedSortedMergeIntersectionCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    // MARK: - Properties

    private let cursors: [AnyTypedRecordCursor<Record>]
    private let recordAccess: any RecordAccess<Record>
    private let primaryKeyExpression: KeyExpression

    // MARK: - Initialization

    init(
        cursors: [AnyTypedRecordCursor<Record>],
        recordAccess: any RecordAccess<Record>,
        primaryKeyExpression: KeyExpression
    ) {
        self.cursors = cursors
        self.recordAccess = recordAccess
        self.primaryKeyExpression = primaryKeyExpression
    }

    // MARK: - TypedRecordCursor

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterators: [AnyTypedRecordCursor<Record>.AnyAsyncIterator]
        let recordAccess: any RecordAccess<Record>
        let primaryKeyExpression: KeyExpression

        /// Current record at each cursor (nil = cursor exhausted)
        var current: [Record?]

        var isFirstNext = true

        public mutating func next() async throws -> Record? {
            // Initialize current records if needed
            if current.allSatisfy({ $0 == nil }) {
                for i in 0..<iterators.count {
                    current[i] = try await iterators[i].next()
                }
                isFirstNext = false
            }

            while true {
                // Check if any cursor is exhausted
                if current.contains(where: { $0 == nil }) {
                    return nil // Intersection is empty
                }

                // Extract primary keys from all current records
                var primaryKeys: [Tuple] = []
                for record in current {
                    guard let record = record else {
                        return nil
                    }
                    let pk = try recordAccess.extractPrimaryKey(from: record, using: primaryKeyExpression)
                    primaryKeys.append(pk)
                }

                // Find min and max primary key
                guard let minPK = primaryKeys.min(by: { compareTuples($0, $1) == .orderedAscending }),
                      let maxPK = primaryKeys.max(by: { compareTuples($0, $1) == .orderedAscending }) else {
                    return nil
                }

                // Check if all primary keys are equal
                if compareTuples(minPK, maxPK) == .orderedSame {
                    // Found intersection! Emit record and advance all cursors
                    let result = current[0]!

                    // Advance all cursors
                    for i in 0..<iterators.count {
                        current[i] = try await iterators[i].next()
                    }

                    return result
                }

                // Not all equal: advance cursors with minimum key
                for i in 0..<iterators.count {
                    if compareTuples(primaryKeys[i], minPK) == .orderedSame {
                        current[i] = try await iterators[i].next()
                    }
                }
            }
        }

        // MARK: - Private Helpers

        /// Compare two tuples lexicographically
        private func compareTuples(_ lhs: Tuple, _ rhs: Tuple) -> ComparisonResult {
            let minCount = Swift.min(lhs.count, rhs.count)

            for i in 0..<minCount {
                guard let lhsElement = lhs[i],
                      let rhsElement = rhs[i] else {
                    continue
                }

                let result = compareElements(lhsElement, rhsElement)
                if result != ComparisonResult.orderedSame {
                    return result
                }
            }

            // All compared elements are equal, compare by count
            if lhs.count < rhs.count {
                return .orderedAscending
            } else if lhs.count > rhs.count {
                return .orderedDescending
            } else {
                return .orderedSame
            }
        }

        /// Compare two tuple elements
        private func compareElements(
            _ lhs: any TupleElement,
            _ rhs: any TupleElement
        ) -> ComparisonResult {
            // String comparison
            if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
                return lhsStr.compare(rhsStr)
            }

            // Int64 comparison
            if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
                if lhsInt < rhsInt { return .orderedAscending }
                if lhsInt > rhsInt { return .orderedDescending }
                return .orderedSame
            }

            // Int comparison
            if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int {
                if lhsInt < rhsInt { return .orderedAscending }
                if lhsInt > rhsInt { return .orderedDescending }
                return .orderedSame
            }

            // Double comparison
            if let lhsDouble = lhs as? Double, let rhsDouble = rhs as? Double {
                if lhsDouble < rhsDouble { return .orderedAscending }
                if lhsDouble > rhsDouble { return .orderedDescending }
                return .orderedSame
            }

            // Float comparison
            if let lhsFloat = lhs as? Float, let rhsFloat = rhs as? Float {
                if lhsFloat < rhsFloat { return .orderedAscending }
                if lhsFloat > rhsFloat { return .orderedDescending }
                return .orderedSame
            }

            // Bool comparison (false < true)
            if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
                if !lhsBool && rhsBool { return .orderedAscending }
                if lhsBool && !rhsBool { return .orderedDescending }
                return .orderedSame
            }

            // Mixed types or unsupported: treat as equal
            return .orderedSame
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let iterators = cursors.map { $0.makeAsyncIterator() }
        return AsyncIterator(
            iterators: iterators,
            recordAccess: recordAccess,
            primaryKeyExpression: primaryKeyExpression,
            current: Array(repeating: nil, count: cursors.count)
        )
    }
}

// MARK: - TypedHashIntersectionCursor

/// Cursor that performs hash-based intersection
///
/// **Requirements**: Works with cursors in any order (doesn't require PK sorting)
///
/// **Algorithm**:
/// 1. Materialize all records from first cursor into a Set (by PK)
/// 2. For each subsequent cursor:
///    - Read all records
///    - Keep only records whose PK is in the Set
///    - Update Set to intersection
/// 3. Iterate through final Set to emit records
///
/// **Performance**:
/// - Time: O(n₁ + n₂ + ... + nₖ) where nᵢ is size of cursor i
/// - Memory: O(min(n₁, n₂, ..., nₖ)) (materializes smallest cursor)
///
/// **Use Case**: Range overlap queries, complex predicates where cursors aren't PK-sorted
struct TypedHashIntersectionCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    // MARK: - Properties

    private let cursors: [AnyTypedRecordCursor<Record>]
    private let recordAccess: any RecordAccess<Record>
    private let primaryKeyExpression: KeyExpression

    // MARK: - Initialization

    init(
        cursors: [AnyTypedRecordCursor<Record>],
        recordAccess: any RecordAccess<Record>,
        primaryKeyExpression: KeyExpression
    ) {
        self.cursors = cursors
        self.recordAccess = recordAccess
        self.primaryKeyExpression = primaryKeyExpression
    }

    // MARK: - TypedRecordCursor

    public struct AsyncIterator: AsyncIteratorProtocol {
        var cursors: [AnyTypedRecordCursor<Record>.AnyAsyncIterator]
        let recordAccess: any RecordAccess<Record>
        let primaryKeyExpression: KeyExpression

        /// Records indexed by primary key (for intersection)
        /// Uses Tuple directly for efficient Hashable comparison
        var recordsByPK: [Tuple: Record]?

        /// Iterator over final intersection result
        var resultIterator: Dictionary<Tuple, Record>.Values.Iterator?

        public mutating func next() async throws -> Record? {
            // Lazy initialization: compute intersection on first next() call
            if recordsByPK == nil {
                try await computeIntersection()
            }

            // Return next record from intersection
            return resultIterator?.next()
        }

        /// Compute intersection by materializing cursors into Sets
        ///
        /// **Algorithm**:
        /// 1. Sample each cursor to estimate size
        /// 2. Materialize smallest cursor (by sample) into Set
        /// 3. Intersect with remaining cursors sequentially
        /// 4. Early exit if intersection becomes empty
        ///
        /// **Dynamic Selection**: Samples first 100 records from each cursor to estimate size.
        /// If multiple cursors hit the sample limit, continues sampling up to 200 records to
        /// distinguish between moderately large and very large cursors. This ensures accurate
        /// selection of the minimum cursor for O(min(n₁, n₂, ..., nₖ)) memory.
        ///
        /// **Optimization**: Uses Tuple directly as dictionary key (Hashable + Equatable)
        /// instead of String conversion, improving performance for long tuples.
        ///
        /// **Memory**: O(size of smallest cursor) = O(min(n₁, n₂, ..., nₖ))
        private mutating func computeIntersection() async throws {
            guard !cursors.isEmpty else {
                recordsByPK = [:]
                resultIterator = [:].values.makeIterator()
                return
            }

            // Step 1: Sample each cursor to estimate size (first 100 records)
            let initialSampleSize = 100
            let extendedSampleSize = 200  // For tie-breaking between large cursors
            var samples: [[Record]] = []
            var estimatedSizes: [Int] = []
            var hitLimit: [Bool] = []

            for i in 0..<cursors.count {
                var sample: [Record] = []
                var iterator = cursors[i]
                var count = 0

                // Initial sampling
                while let record = try await iterator.next(), count < initialSampleSize {
                    sample.append(record)
                    count += 1
                }

                samples.append(sample)
                hitLimit.append(count == initialSampleSize)

                // Estimate size based on sample
                if count < initialSampleSize {
                    // Small cursor - exact count
                    estimatedSizes.append(count)
                } else {
                    // Large cursor - mark for extended sampling
                    estimatedSizes.append(Int.max)
                }
            }

            // Step 1b: Extended sampling for cursors that hit initial limit
            // This helps distinguish between moderately large (200-1000) and very large (>10K) cursors
            let largeCursorIndices = hitLimit.enumerated().compactMap { $0.element ? $0.offset : nil }
            if largeCursorIndices.count > 1 {
                // Multiple large cursors - need tie-breaking
                for i in largeCursorIndices {
                    var iterator = cursors[i]
                    var count = samples[i].count

                    // Continue sampling up to 200
                    while let record = try await iterator.next(), count < extendedSampleSize {
                        samples[i].append(record)
                        count += 1
                    }

                    // Update estimate
                    estimatedSizes[i] = count
                }
            }

            // Step 2: Select minimum cursor by estimated size
            guard let minIndex = estimatedSizes.enumerated().min(by: { $0.element < $1.element })?.offset else {
                recordsByPK = [:]
                resultIterator = [:].values.makeIterator()
                return
            }

            // Step 3: Materialize minimum cursor (sample + remaining records) into map
            // Use Tuple directly as key (Hashable + Equatable) - more efficient than String
            var currentSet: [Tuple: Record] = [:]

            // Add sample records
            for record in samples[minIndex] {
                let pk = try recordAccess.extractPrimaryKey(from: record, using: primaryKeyExpression)
                currentSet[pk] = record
            }

            // Add remaining records from minimum cursor
            var minIterator = cursors[minIndex]
            while let record = try await minIterator.next() {
                let pk = try recordAccess.extractPrimaryKey(from: record, using: primaryKeyExpression)
                currentSet[pk] = record
            }

            // Step 4: Intersect with remaining cursors (using samples + remaining records)
            for i in 0..<cursors.count {
                if i == minIndex {
                    continue  // Skip minimum cursor (already materialized)
                }

                var nextSet: [Tuple: Record] = [:]

                // Process sample records first
                for record in samples[i] {
                    let pk = try recordAccess.extractPrimaryKey(from: record, using: primaryKeyExpression)

                    if currentSet[pk] != nil {
                        nextSet[pk] = record
                    }
                }

                // Process remaining records
                var iterator = cursors[i]
                while let record = try await iterator.next() {
                    let pk = try recordAccess.extractPrimaryKey(from: record, using: primaryKeyExpression)

                    if currentSet[pk] != nil {
                        nextSet[pk] = record
                    }
                }

                currentSet = nextSet

                // Early exit if intersection is empty
                if currentSet.isEmpty {
                    break
                }
            }

            // Step 5: Create iterator over final result
            recordsByPK = currentSet
            resultIterator = currentSet.values.makeIterator()
        }

        /// Convert Tuple to unique string key for dictionary
        ///
        /// Uses Tuple.pack() to ensure collision-free representation.
        /// The packed bytes are converted to hex string for dictionary key.
        ///
        /// **Collision Safety**:
        /// - Tuple.pack() produces unique byte sequences for distinct tuples
        /// - Hex encoding preserves byte-level uniqueness
        /// - No risk of collision like string concatenation (e.g., ["a|b", "c"] vs ["a", "b|c"])
        ///
        /// - Parameter tuple: Primary key tuple
        /// - Returns: Hex-encoded packed tuple (collision-free)
        private func tupleToPKString(_ tuple: Tuple) -> String {
            let packed = tuple.pack()
            return packed.map { String(format: "%02x", $0) }.joined()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let iterators = cursors.map { $0.makeAsyncIterator() }
        return AsyncIterator(
            cursors: iterators,
            recordAccess: recordAccess,
            primaryKeyExpression: primaryKeyExpression,
            recordsByPK: nil,
            resultIterator: nil
        )
    }
}
