import Foundation
import FoundationDB

// MARK: - Generic Min Index Maintainer

/// Generic maintainer for MIN aggregation indexes
///
/// MIN indexes are implemented as VALUE indexes with special semantics.
/// The index stores entries with keys: [grouping..., value, primaryKey...]
/// MIN query scans for the first entry in the grouping range.
///
/// **Index Definition:**
/// ```swift
/// let minIndex = Index(
///     name: "age_min_by_city",
///     type: .min,
///     rootExpression: ConcatenateKeyExpression(children: [
///         FieldKeyExpression(fieldName: "city"),  // grouping
///         FieldKeyExpression(fieldName: "age")     // min value
///     ])
/// )
/// ```
///
/// **Storage:**
/// - Keys: `subspace.pack([city, age, userID])`
/// - Values: Empty (all info in key)
///
/// **Query:**
/// - Get first key in range `[city, ...]`
/// - Extract age value from key
public struct GenericMinIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
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
        // MIN indexes are VALUE indexes - same update logic
        // Remove old entry
        if let oldRecord = oldRecord {
            let oldKey = try buildIndexKey(record: oldRecord, recordAccess: recordAccess)
            transaction.clear(key: oldKey)
        }

        // Add new entry
        if let newRecord = newRecord {
            let newKey = try buildIndexKey(record: newRecord, recordAccess: recordAccess)
            transaction.setValue([], for: newKey)  // Empty value
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        let indexKey = try buildIndexKey(record: record, recordAccess: recordAccess)
        transaction.setValue([], for: indexKey)
    }

    /// Get the minimum value for a specific grouping
    /// - Parameters:
    ///   - groupingValues: The grouping key values
    ///   - transaction: The transaction to use
    /// - Returns: The minimum value
    public func getMin(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let range = subspace.subspace(groupingTuple).range()

        // Use key selector for efficient O(log n) lookup
        let selector = FDB.KeySelector.firstGreaterOrEqual(range.begin)
        guard let firstKey = try await transaction.getKey(selector: selector, snapshot: true) else {
            throw RecordLayerError.internalError("No values found for MIN aggregate")
        }

        // Verify key is within range
        guard firstKey.starts(with: range.begin) else {
            throw RecordLayerError.internalError("No values found for MIN aggregate in range")
        }

        // Extract value from key
        // Key structure: [grouping..., value, primaryKey...]
        // Value is at position: groupingValues.count
        let elements = try Tuple.unpack(from: firstKey)
        guard elements.count > groupingValues.count else {
            throw RecordLayerError.internalError("Invalid MIN index key structure")
        }

        let valueElement = elements[groupingValues.count]
        return try extractNumericValue(valueElement)
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
        let primaryKeyTuple: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKeyTuple = recordableRecord.extractPrimaryKey()
        } else {
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }
        let primaryKeyValues = try Tuple.unpack(from: primaryKeyTuple.pack())

        // Combine: [grouping..., value, primaryKey...]
        let allValues = indexedValues + primaryKeyValues
        let tuple = TupleHelpers.toTuple(allValues)
        return subspace.pack(tuple)
    }

    private func extractNumericValue(_ element: any TupleElement) throws -> Int64 {
        if let int64 = element as? Int64 {
            return int64
        } else if let int = element as? Int {
            return Int64(int)
        } else if let int32 = element as? Int32 {
            return Int64(int32)
        } else if let double = element as? Double {
            return Int64(double)
        } else if let float = element as? Float {
            return Int64(float)
        } else {
            throw RecordLayerError.internalError("MIN index value must be numeric, got: \(type(of: element))")
        }
    }
}

// MARK: - Generic Max Index Maintainer

/// Generic maintainer for MAX aggregation indexes
///
/// MAX indexes are implemented as VALUE indexes with special semantics.
/// The index stores entries with keys: [grouping..., value, primaryKey...]
/// MAX query scans for the last entry in the grouping range.
///
/// **Index Definition:**
/// ```swift
/// let maxIndex = Index(
///     name: "age_max_by_city",
///     type: .max,
///     rootExpression: ConcatenateKeyExpression(children: [
///         FieldKeyExpression(fieldName: "city"),  // grouping
///         FieldKeyExpression(fieldName: "age")     // max value
///     ])
/// )
/// ```
///
/// **Storage:**
/// - Keys: `subspace.pack([city, age, userID])`
/// - Values: Empty (all info in key)
///
/// **Query:**
/// - Get last key in range `[city, ...]`
/// - Extract age value from key
public struct GenericMaxIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
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
        // MAX indexes are VALUE indexes - same update logic
        // Remove old entry
        if let oldRecord = oldRecord {
            let oldKey = try buildIndexKey(record: oldRecord, recordAccess: recordAccess)
            transaction.clear(key: oldKey)
        }

        // Add new entry
        if let newRecord = newRecord {
            let newKey = try buildIndexKey(record: newRecord, recordAccess: recordAccess)
            transaction.setValue([], for: newKey)  // Empty value
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        let indexKey = try buildIndexKey(record: record, recordAccess: recordAccess)
        transaction.setValue([], for: indexKey)
    }

    /// Get the maximum value for a specific grouping
    /// - Parameters:
    ///   - groupingValues: The grouping key values
    ///   - transaction: The transaction to use
    /// - Returns: The maximum value
    public func getMax(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let range = subspace.subspace(groupingTuple).range()

        // Use key selector for efficient O(log n) lookup
        let selector = FDB.KeySelector.lastLessThan(range.end)
        guard let lastKey = try await transaction.getKey(selector: selector, snapshot: true) else {
            throw RecordLayerError.internalError("No values found for MAX aggregate")
        }

        // Verify key is within range
        guard lastKey.starts(with: range.begin) else {
            throw RecordLayerError.internalError("No values found for MAX aggregate in range")
        }

        // Extract value from key
        // Key structure: [grouping..., value, primaryKey...]
        // Value is at position: groupingValues.count
        let elements = try Tuple.unpack(from: lastKey)
        guard elements.count > groupingValues.count else {
            throw RecordLayerError.internalError("Invalid MAX index key structure")
        }

        let valueElement = elements[groupingValues.count]
        return try extractNumericValue(valueElement)
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
        let primaryKeyTuple: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKeyTuple = recordableRecord.extractPrimaryKey()
        } else {
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }
        let primaryKeyValues = try Tuple.unpack(from: primaryKeyTuple.pack())

        // Combine: [grouping..., value, primaryKey...]
        let allValues = indexedValues + primaryKeyValues
        let tuple = TupleHelpers.toTuple(allValues)
        return subspace.pack(tuple)
    }

    private func extractNumericValue(_ element: any TupleElement) throws -> Int64 {
        if let int64 = element as? Int64 {
            return int64
        } else if let int = element as? Int {
            return Int64(int)
        } else if let int32 = element as? Int32 {
            return Int64(int32)
        } else if let double = element as? Double {
            return Int64(double)
        } else if let float = element as? Float {
            return Int64(float)
        } else {
            throw RecordLayerError.internalError("MAX index value must be numeric, got: \(type(of: element))")
        }
    }
}
