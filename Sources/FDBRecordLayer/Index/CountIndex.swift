import Foundation
import FoundationDB

/// Maintainer for count aggregation indexes
///
/// Count indexes maintain counts of records grouped by specific field values.
/// They use atomic operations for efficient concurrent updates.
public struct CountIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace

    public init(index: Index, subspace: Subspace) {
        self.index = index
        self.subspace = subspace
    }

    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // Determine the grouping key
        let groupingValues: [any TupleElement]?

        if let newRecord = newRecord {
            groupingValues = index.rootExpression.evaluate(record: newRecord)
        } else if let oldRecord = oldRecord {
            groupingValues = index.rootExpression.evaluate(record: oldRecord)
        } else {
            return // Nothing to do
        }

        guard let values = groupingValues else { return }

        let groupingTuple = TupleHelpers.toTuple(values)
        let countKey = subspace.pack(groupingTuple)

        // Calculate delta: +1 for insert, -1 for delete, 0 for update with same group
        let delta: Int64 = (newRecord != nil ? 1 : 0) - (oldRecord != nil ? 1 : 0)

        if delta != 0 {
            let deltaBytes = TupleHelpers.int64ToBytes(delta)
            transaction.atomicOp(key: countKey, param: deltaBytes, mutationType: .add)
        }
    }

    public func scanRecord(
        _ record: [String: Any],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let values = index.rootExpression.evaluate(record: record)
        let groupingTuple = TupleHelpers.toTuple(values)
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
