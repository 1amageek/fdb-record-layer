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
        // Determine the grouping key
        let groupingValues: [any TupleElement]

        if let newRecord = newRecord {
            groupingValues = try recordAccess.evaluate(
                record: newRecord,
                expression: index.rootExpression
            )
        } else if let oldRecord = oldRecord {
            groupingValues = try recordAccess.evaluate(
                record: oldRecord,
                expression: index.rootExpression
            )
        } else {
            return // Nothing to do
        }

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let countKey = subspace.pack(groupingTuple)

        // Calculate delta: +1 for insert, -1 for delete, 0 for update with same group
        let delta: Int64 = (newRecord != nil ? 1 : 0) - (oldRecord != nil ? 1 : 0)

        if delta != 0 {
            let deltaBytes = TupleHelpers.int64ToBytes(delta)
            transaction.atomicOp(key: countKey, param: deltaBytes, mutationType: .add)
        }
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
