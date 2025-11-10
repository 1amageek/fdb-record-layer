import Foundation
import FoundationDB

// MARK: - Internal Helper Functions

/// Extract field names from a KeyExpression for error messages
private func extractFieldNames(from expression: KeyExpression) -> [String] {
    if let field = expression as? FieldKeyExpression {
        return [field.fieldName]
    } else if let concat = expression as? ConcatenateKeyExpression {
        return concat.children.flatMap { extractFieldNames(from: $0) }
    } else {
        // For other expression types (Literal, Empty, etc.), use placeholder
        return ["<expression>"]
    }
}

/// Build detailed error message for grouping validation
private func buildGroupingErrorMessage(
    index: Index,
    providedCount: Int,
    expectedCount: Int,
    providedValues: [any TupleElement]
) -> String {
    let fieldNames = extractFieldNames(from: index.rootExpression)
    let groupingFields = Array(fieldNames.prefix(expectedCount))
    let valueField = fieldNames.count > expectedCount ? fieldNames[expectedCount] : "<value>"

    var message = "Grouping values count (\(providedCount)) does not match expected count (\(expectedCount)) for index '\(index.name)'\n"
    message += "Expected grouping fields: [\(groupingFields.joined(separator: ", "))]\n"
    message += "Value field: \(valueField)\n"
    message += "Provided values: [\(providedValues.map { "\"\($0)\"" }.joined(separator: ", "))]"

    if providedCount < expectedCount {
        let missingFields = Array(groupingFields.suffix(expectedCount - providedCount))
        message += "\nMissing: [\(missingFields.joined(separator: ", "))]"
    } else if providedCount > expectedCount {
        let extraValues = Array(providedValues.suffix(providedCount - expectedCount))
        message += "\nExtra values: [\(extraValues.map { "\"\($0)\"" }.joined(separator: ", "))]"
    }

    return message
}

/// Find the minimum value in a grouped MIN index
internal func findMinValue(
    index: Index,
    subspace: Subspace,
    groupingValues: [any TupleElement],
    transaction: any TransactionProtocol
) async throws -> Int64 {
    let expectedGroupingCount = index.rootExpression.columnCount - 1
    guard groupingValues.count == expectedGroupingCount else {
        throw RecordLayerError.invalidArgument(
            buildGroupingErrorMessage(
                index: index,
                providedCount: groupingValues.count,
                expectedCount: expectedGroupingCount,
                providedValues: groupingValues
            )
        )
    }

    let groupingTuple = TupleHelpers.toTuple(groupingValues)
    let groupingBytes = groupingTuple.pack()
    let groupingSubspace = Subspace(prefix: subspace.prefix + groupingBytes)
    let range = groupingSubspace.range()

    let selector = FDB.KeySelector.firstGreaterOrEqual(range.begin)
    guard let firstKey = try await transaction.getKey(selector: selector, snapshot: true) else {
        throw RecordLayerError.internalError("No values found for MIN aggregate")
    }

    guard groupingSubspace.contains(firstKey) else {
        throw RecordLayerError.internalError("No values found for MIN aggregate in range")
    }

    let dataTuple = try groupingSubspace.unpack(firstKey)
    let dataElements = try Tuple.unpack(from: dataTuple.pack())
    guard !dataElements.isEmpty else {
        throw RecordLayerError.internalError("Invalid MIN index key structure")
    }

    return try extractNumericValue(dataElements[0])
}

/// Find the maximum value in a grouped MAX index
internal func findMaxValue(
    index: Index,
    subspace: Subspace,
    groupingValues: [any TupleElement],
    transaction: any TransactionProtocol
) async throws -> Int64 {
    let expectedGroupingCount = index.rootExpression.columnCount - 1
    guard groupingValues.count == expectedGroupingCount else {
        throw RecordLayerError.invalidArgument(
            buildGroupingErrorMessage(
                index: index,
                providedCount: groupingValues.count,
                expectedCount: expectedGroupingCount,
                providedValues: groupingValues
            )
        )
    }

    let groupingTuple = TupleHelpers.toTuple(groupingValues)
    let groupingBytes = groupingTuple.pack()
    let groupingSubspace = Subspace(prefix: subspace.prefix + groupingBytes)
    let range = groupingSubspace.range()

    let selector = FDB.KeySelector.lastLessThan(range.end)
    guard let lastKey = try await transaction.getKey(selector: selector, snapshot: true) else {
        throw RecordLayerError.internalError("No values found for MAX aggregate")
    }

    guard groupingSubspace.contains(lastKey) else {
        throw RecordLayerError.internalError("No values found for MAX aggregate in range")
    }

    let dataTuple = try groupingSubspace.unpack(lastKey)
    let dataElements = try Tuple.unpack(from: dataTuple.pack())
    guard !dataElements.isEmpty else {
        throw RecordLayerError.internalError("Invalid MAX index key structure")
    }

    return try extractNumericValue(dataElements[0])
}

/// Extract numeric value from a tuple element as Int64
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
        throw RecordLayerError.internalError("Aggregate value must be numeric, got: \(type(of: element))")
    }
}

// MARK: - Generic Min Index Maintainer

/// Generic maintainer for MIN aggregation indexes
///
/// **Index Definition:**
/// ```swift
/// let minIndex = Index(
///     name: "age_min_by_city",
///     type: .min,
///     rootExpression: ConcatenateKeyExpression(children: [
///         FieldKeyExpression(fieldName: "city"),
///         FieldKeyExpression(fieldName: "age")
///     ])
/// )
/// ```
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
        if let oldRecord = oldRecord {
            let oldKey = try buildIndexKey(record: oldRecord, recordAccess: recordAccess)
            transaction.clear(key: oldKey)
        }

        if let newRecord = newRecord {
            let newKey = try buildIndexKey(record: newRecord, recordAccess: recordAccess)
            transaction.setValue([], for: newKey)
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
    public func getMin(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        return try await findMinValue(
            index: index,
            subspace: subspace,
            groupingValues: groupingValues,
            transaction: transaction
        )
    }

    // MARK: - Private Methods

    private func buildIndexKey(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> FDB.Bytes {
        let indexedValues = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        let primaryKeyTuple: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKeyTuple = recordableRecord.extractPrimaryKey()
        } else {
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }
        let primaryKeyValues = try Tuple.unpack(from: primaryKeyTuple.pack())

        let allValues = indexedValues + primaryKeyValues
        let tuple = TupleHelpers.toTuple(allValues)
        return subspace.pack(tuple)
    }
}

// MARK: - Generic Max Index Maintainer

/// Generic maintainer for MAX aggregation indexes
///
/// **Index Definition:**
/// ```swift
/// let maxIndex = Index(
///     name: "age_max_by_city",
///     type: .max,
///     rootExpression: ConcatenateKeyExpression(children: [
///         FieldKeyExpression(fieldName: "city"),
///         FieldKeyExpression(fieldName: "age")
///     ])
/// )
/// ```
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
        if let oldRecord = oldRecord {
            let oldKey = try buildIndexKey(record: oldRecord, recordAccess: recordAccess)
            transaction.clear(key: oldKey)
        }

        if let newRecord = newRecord {
            let newKey = try buildIndexKey(record: newRecord, recordAccess: recordAccess)
            transaction.setValue([], for: newKey)
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
    public func getMax(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        return try await findMaxValue(
            index: index,
            subspace: subspace,
            groupingValues: groupingValues,
            transaction: transaction
        )
    }

    // MARK: - Private Methods

    private func buildIndexKey(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> FDB.Bytes {
        let indexedValues = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        let primaryKeyTuple: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKeyTuple = recordableRecord.extractPrimaryKey()
        } else {
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }
        let primaryKeyValues = try Tuple.unpack(from: primaryKeyTuple.pack())

        let allValues = indexedValues + primaryKeyValues
        let tuple = TupleHelpers.toTuple(allValues)
        return subspace.pack(tuple)
    }
}
