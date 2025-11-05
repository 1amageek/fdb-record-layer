import Foundation
import FoundationDB

/// Query plan that computes union of multiple child plans
///
/// TypedUnionPlan implements streaming merge-union with automatic deduplication.
/// It assumes child plans return results ordered by primary key.
///
/// **Algorithm:**
/// 1. Maintain cursor for each child plan
/// 2. Find minimum primary key across all active cursors
/// 3. Emit record with minimum primary key
/// 4. Advance all cursors that had minimum key (automatic deduplication)
/// 5. Repeat until all cursors are exhausted
///
/// **Usage:**
/// ```swift
/// let plan1 = TypedIndexScanPlan(...) // Scan city="Tokyo"
/// let plan2 = TypedIndexScanPlan(...) // Scan city="Osaka"
/// let unionPlan = TypedUnionPlan(childPlans: [plan1, plan2])
/// // Returns records from Tokyo OR Osaka (no duplicates)
/// ```
///
/// **Contract:**
/// - Child plans MUST return results ordered by primary key
/// - Deduplication is automatic (primary key-based)
/// - No Set<Record> required (memory-efficient)
///
/// **Performance:**
/// - Time: O(n₁ + n₂ + ... + nₖ) where nᵢ is size of child i
/// - Memory: O(1) (streaming, no buffering)
/// - I/O: Proportional to union size (duplicates read only once)
public struct TypedUnionPlan<Record: Sendable>: TypedQueryPlan {
    // MARK: - Properties

    /// Child plans to union
    public let childPlans: [any TypedQueryPlan<Record>]

    /// Primary key expression for comparing records
    public let primaryKeyExpression: KeyExpression

    // MARK: - Initialization

    public init(childPlans: [any TypedQueryPlan<Record>], primaryKeyExpression: KeyExpression) {
        self.childPlans = childPlans
        self.primaryKeyExpression = primaryKeyExpression
    }

    // MARK: - TypedQueryPlan

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Execute all child plans
        var cursors: [AnyTypedRecordCursor<Record>] = []
        for childPlan in childPlans {
            let cursor = try await childPlan.execute(
                subspace: subspace,
                recordAccess: recordAccess,
                context: context,
                snapshot: snapshot
            )
            cursors.append(cursor)
        }

        // Return union cursor
        let unionCursor = TypedUnionCursor(
            cursors: cursors,
            recordAccess: recordAccess,
            primaryKeyExpression: primaryKeyExpression
        )
        return AnyTypedRecordCursor(unionCursor)
    }
}

// MARK: - TypedUnionCursor

/// Cursor that performs streaming merge-union with deduplication
struct TypedUnionCursor<Record: Sendable>: TypedRecordCursor {
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

        public mutating func next() async throws -> Record? {
            // Initialize current records if needed
            if current.allSatisfy({ $0 == nil }) && !iterators.isEmpty {
                for i in 0..<iterators.count {
                    current[i] = try await iterators[i].next()
                }
            }

            // Find cursors with minimum primary key
            var minPK: Tuple? = nil
            var minRecord: Record? = nil

            for record in current {
                guard let record = record else {
                    continue // Cursor exhausted
                }

                let pk = try recordAccess.extractPrimaryKey(from: record, using: primaryKeyExpression)

                if let currentMinPK = minPK {
                    let comparison = compareTuples(pk, currentMinPK)
                    if comparison == .orderedAscending {
                        minPK = pk
                        minRecord = record
                    }
                } else {
                    minPK = pk
                    minRecord = record
                }
            }

            // No more records
            guard let minPK = minPK, let minRecord = minRecord else {
                return nil
            }

            // Advance all cursors with minimum key (automatic deduplication)
            for i in 0..<iterators.count {
                guard let record = current[i] else {
                    continue
                }

                let pk = try recordAccess.extractPrimaryKey(from: record, using: primaryKeyExpression)
                if compareTuples(pk, minPK) == .orderedSame {
                    current[i] = try await iterators[i].next()
                }
            }

            return minRecord
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
