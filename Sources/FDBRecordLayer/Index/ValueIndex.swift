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
    public let subspace: Subspace
    public let recordSubspace: Subspace

    public init(
        index: Index,
        subspace: Subspace,
        recordSubspace: Subspace
    ) {
        self.index = index
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
            if let oldKey = try buildIndexKey(record: oldRecord, recordAccess: recordAccess) {
                transaction.clear(key: oldKey)
            }
        }

        // Add new index entry
        if let newRecord = newRecord {
            if let newKey = try buildIndexKey(record: newRecord, recordAccess: recordAccess) {
                let value = try buildIndexValue(record: newRecord, recordAccess: recordAccess)
                transaction.setValue(value, for: newKey)
            }
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        if let indexKey = try buildIndexKey(record: record, recordAccess: recordAccess) {
            let value = try buildIndexValue(record: record, recordAccess: recordAccess)
            transaction.setValue(value, for: indexKey)
        }
    }

    // MARK: - Private Methods

    private func buildIndexKey(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> FDB.Bytes? {
        // Evaluate index expression to get indexed values
        let indexedValues = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        // If indexed values are empty (e.g., nil Optional Range), don't create index entry
        guard !indexedValues.isEmpty else {
            return nil
        }

        // Extract primary key values using Recordable protocol
        let primaryKeyTuple: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKeyTuple = recordableRecord.extractPrimaryKey()
        } else {
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }
        let primaryKeyValues = try Tuple.unpack(from: primaryKeyTuple.pack())

        // Combine indexed values with primary key for uniqueness
        let allValues = indexedValues + primaryKeyValues

        // Build tuple and encode with subspace
        let tuple = TupleHelpers.toTuple(allValues)
        return subspace.pack(tuple)
    }

    /// Build index value with optional covering fields
    ///
    /// **Non-covering index** (backward compatible):
    /// - Returns empty bytes
    /// - All data stored in index key
    ///
    /// **Covering index**:
    /// - Evaluates covering field expressions
    /// - Packs covering field values as Tuple
    /// - Stores in index value for record reconstruction
    ///
    /// **Example**:
    /// ```swift
    /// // Non-covering: value = []
    /// // Covering: value = Tuple(name, email).pack()
    /// ```
    private func buildIndexValue(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> FDB.Bytes {
        // Check if this is a covering index
        guard let coveringFields = index.coveringFields, !coveringFields.isEmpty else {
            // Non-covering index: empty value (backward compatible)
            return FDB.Bytes()
        }

        // Covering index: evaluate and store covering fields
        var coveringValues: [any TupleElement] = []

        for coveringExpr in coveringFields {
            let values = try recordAccess.evaluate(
                record: record,
                expression: coveringExpr
            )
            coveringValues.append(contentsOf: values)
        }

        // Pack covering values as Tuple
        let tuple = TupleHelpers.toTuple(coveringValues)
        return tuple.pack()
    }
}
