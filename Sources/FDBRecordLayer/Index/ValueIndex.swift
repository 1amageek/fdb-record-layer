import Foundation
import FoundationDB

/// Maintainer for value indexes (standard B-tree)
///
/// Value indexes map indexed field values to primary keys, enabling
/// efficient lookups and range scans.
public struct ValueIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    public init(index: Index, subspace: Subspace, recordSubspace: Subspace) {
        self.index = index
        self.subspace = subspace
        self.recordSubspace = recordSubspace
    }

    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old index entry
        if let oldRecord = oldRecord {
            let oldKey = try buildIndexKey(record: oldRecord)
            transaction.clear(key: oldKey)
        }

        // Add new index entry
        if let newRecord = newRecord {
            let newKey = try buildIndexKey(record: newRecord)
            let value = buildIndexValue()
            transaction.setValue(value, for: newKey)
        }
    }

    public func scanRecord(
        _ record: [String: Any],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let indexKey = try buildIndexKey(record: record)
        let value = buildIndexValue()
        transaction.setValue(value, for: indexKey)
    }

    // MARK: - Private Methods

    private func buildIndexKey(record: [String: Any]) throws -> FDB.Bytes {
        // Evaluate index expression to get indexed values
        let indexedValues = index.rootExpression.evaluate(record: record)

        // For value indexes, we need to append primary key for uniqueness
        // Extract primary key values from record
        // (In a real implementation, we'd get the RecordType to know the primary key expression)

        // For now, assume there's an "id" field
        let primaryKeyValue: any TupleElement
        if let id = record["id"] as? Int64 {
            primaryKeyValue = id
        } else if let id = record["id"] as? Int {
            primaryKeyValue = Int64(id)
        } else if let id = record["id"] as? String {
            primaryKeyValue = id
        } else {
            primaryKeyValue = ""
        }

        // Combine indexed values with primary key
        let allValues = indexedValues + [primaryKeyValue]

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
