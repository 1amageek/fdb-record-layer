import Foundation
import FoundationDB

/// Query plan that computes intersection of multiple child plans
///
/// TypedIntersectionPlan implements streaming merge-join intersection.
/// It assumes child plans return results ordered by primary key.
///
/// **Algorithm:**
/// 1. Maintain cursor for each child plan
/// 2. Find minimum primary key across all cursors
/// 3. If all cursors have the same primary key → emit record
/// 4. Otherwise, advance cursors with minimum key
/// 5. Repeat until any cursor is exhausted
///
/// **Usage:**
/// ```swift
/// let plan1 = TypedIndexScanPlan(...) // Scan city index
/// let plan2 = TypedIndexScanPlan(...) // Scan age index
/// let intersectionPlan = TypedIntersectionPlan(childPlans: [plan1, plan2])
/// // Returns records matching both city AND age
/// ```
///
/// **Contract:**
/// - Child plans MUST return results ordered by primary key
/// - Index scans naturally satisfy this (index includes primary key suffix)
/// - Full scans satisfy this (scanning by primary key order)
///
/// **Performance:**
/// - Time: O(n₁ + n₂ + ... + nₖ) where nᵢ is size of child i
/// - Memory: O(1) (streaming, no buffering)
/// - I/O: Proportional to union size (not product)
public struct TypedIntersectionPlan<Record: Sendable>: TypedQueryPlan {
    // MARK: - Properties

    /// Child plans to intersect
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

        // Return intersection cursor
        let intersectionCursor = TypedIntersectionCursor(
            cursors: cursors,
            recordAccess: recordAccess,
            primaryKeyExpression: primaryKeyExpression
        )
        return AnyTypedRecordCursor(intersectionCursor)
    }
}

// MARK: - TypedIntersectionCursor

/// Cursor that performs streaming merge-join intersection
struct TypedIntersectionCursor<Record: Sendable>: TypedRecordCursor {
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
            if current.allSatisfy({ $0 == nil }) {
                for i in 0..<iterators.count {
                    current[i] = try await iterators[i].next()
                }
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
