import Foundation
import FoundationDB

// MARK: - Generic Value Index Maintainer

/// Generic maintainer for value indexes (standard B-tree)
///
/// This is the new generic version that works with any record type
/// through RecordAccess instead of assuming dictionary-based records.
///
/// Value indexes map indexed field values to primary keys, enabling
/// efficient lookups and range scans.
///
/// **Usage:**
/// ```swift
/// let maintainer = GenericValueIndexMaintainer(
///     index: valueIndex,
///     recordType: userType,
///     subspace: valueSubspace,
///     recordSubspace: recordSubspace
/// )
/// ```
public struct GenericValueIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
    public let index: Index
    public let recordType: RecordType
    public let subspace: Subspace
    public let recordSubspace: Subspace

    public init(
        index: Index,
        recordType: RecordType,
        subspace: Subspace,
        recordSubspace: Subspace
    ) {
        self.index = index
        self.recordType = recordType
        self.subspace = subspace
        self.recordSubspace = recordSubspace
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old index entry
        if let oldRecord = oldRecord {
            let oldKey = try buildIndexKey(record: oldRecord, recordAccess: recordAccess)
            transaction.clear(key: oldKey)
        }

        // Add new index entry
        if let newRecord = newRecord {
            let newKey = try buildIndexKey(record: newRecord, recordAccess: recordAccess)
            let value = buildIndexValue()
            transaction.setValue(value, for: newKey)
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        let indexKey = try buildIndexKey(record: record, recordAccess: recordAccess)
        let value = buildIndexValue()
        transaction.setValue(value, for: indexKey)
    }

    // MARK: - Private Methods

    private func buildIndexKey(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> FDB.Bytes {
        // Evaluate index expression to get indexed values
        let indexedValues = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        // Extract primary key values
        let primaryKeyValues = try recordAccess.evaluate(
            record: record,
            expression: recordType.primaryKey
        )

        // Combine indexed values with primary key for uniqueness
        let allValues = indexedValues + primaryKeyValues

        // Build tuple and encode with subspace
        let tuple = TupleHelpers.toTuple(allValues)
        return subspace.pack(tuple)
    }

    private func buildIndexValue() -> FDB.Bytes {
        // For value indexes, we typically store empty value
        // The key contains all necessary information
        return FDB.Bytes()
    }
}
