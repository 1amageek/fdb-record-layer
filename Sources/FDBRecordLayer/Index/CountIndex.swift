import Foundation
import FoundationDB

// MARK: - Generic Count Index Maintainer

/// Generic maintainer for count aggregation indexes
///
/// This is the new generic version that works with any record type
/// through RecordAccess instead of assuming dictionary-based records.
///
/// Count indexes maintain counts of records grouped by specific field values.
/// They use atomic operations for efficient concurrent updates.
///
/// **Usage:**
/// ```swift
/// let maintainer = GenericCountIndexMaintainer(
///     index: countIndex,
///     recordType: userType,
///     subspace: countSubspace
/// )
/// ```
public struct GenericCountIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
    public let index: Index
    public let recordType: RecordType
    public let subspace: Subspace

    public init(
        index: Index,
        recordType: RecordType,
        subspace: Subspace
    ) {
        self.index = index
        self.recordType = recordType
        self.subspace = subspace
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Extract grouping values for old and new records
        let oldGrouping: [any TupleElement]?
        if let oldRecord = oldRecord {
            oldGrouping = try recordAccess.evaluate(
                record: oldRecord,
                expression: index.rootExpression
            )
        } else {
            oldGrouping = nil
        }

        let newGrouping: [any TupleElement]?
        if let newRecord = newRecord {
            newGrouping = try recordAccess.evaluate(
                record: newRecord,
                expression: index.rootExpression
            )
        } else {
            newGrouping = nil
        }

        // Compare groupings if both exist (update case)
        if let old = oldGrouping, let new = newGrouping {
            let oldKey = subspace.pack(TupleHelpers.toTuple(old))
            let newKey = subspace.pack(TupleHelpers.toTuple(new))

            if oldKey == newKey {
                // Same group, count unchanged - no operation needed
                return
            } else {
                // Different groups: decrement old, increment new
                let decrement = TupleHelpers.int64ToBytes(-1)
                transaction.atomicOp(key: oldKey, param: decrement, mutationType: .add)

                let increment = TupleHelpers.int64ToBytes(1)
                transaction.atomicOp(key: newKey, param: increment, mutationType: .add)
            }
        } else if let new = newGrouping {
            // Insert: increment new group
            let newKey = subspace.pack(TupleHelpers.toTuple(new))
            let increment = TupleHelpers.int64ToBytes(1)
            transaction.atomicOp(key: newKey, param: increment, mutationType: .add)
        } else if let old = oldGrouping {
            // Delete: decrement old group
            let oldKey = subspace.pack(TupleHelpers.toTuple(old))
            let decrement = TupleHelpers.int64ToBytes(-1)
            transaction.atomicOp(key: oldKey, param: decrement, mutationType: .add)
        }
        // else: both nil, nothing to do
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        let groupingValues = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let countKey = subspace.pack(groupingTuple)

        // Increment count
        let increment = TupleHelpers.int64ToBytes(1)
        transaction.atomicOp(key: countKey, param: increment, mutationType: .add)
    }

    /// Get the count for a specific grouping
    /// - Parameters:
    ///   - groupingValues: The grouping key values
    ///   - transaction: The transaction to use
    /// - Returns: The count
    public func getCount(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let countKey = subspace.pack(groupingTuple)

        guard let bytes = try await transaction.getValue(for: countKey) else {
            return 0
        }

        return TupleHelpers.bytesToInt64(bytes)
    }
}
