import Foundation
import FoundationDB

/// Protocol for maintaining a type-safe index
///
/// TypedIndexMaintainer works with a specific record type for full type safety.
public protocol TypedIndexMaintainer<Record>: Sendable {
    associatedtype Record: Sendable

    /// Update index entries when a record changes
    /// - Parameters:
    ///   - oldRecord: The old record (nil if inserting)
    ///   - newRecord: The new record (nil if deleting)
    ///   - primaryKey: The record's primary key
    ///   - transaction: The transaction to use
    func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws

    /// Scan and build index entries for a record
    /// - Parameters:
    ///   - record: The record to scan
    ///   - primaryKey: The record's primary key
    ///   - transaction: The transaction to use
    func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws
}

// MARK: - Type-Erased Maintainer

/// Type-erased index maintainer
public struct AnyTypedIndexMaintainer<Record: Sendable>: TypedIndexMaintainer {
    private let _updateIndex: @Sendable (Record?, Record?, Tuple, any TransactionProtocol) async throws -> Void
    private let _scanRecord: @Sendable (Record, Tuple, any TransactionProtocol) async throws -> Void

    public init<M: TypedIndexMaintainer>(_ maintainer: M) where M.Record == Record {
        self._updateIndex = { oldRecord, newRecord, primaryKey, transaction in
            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: newRecord,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
        self._scanRecord = { record, primaryKey, transaction in
            try await maintainer.scanRecord(
                record,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        try await _updateIndex(oldRecord, newRecord, primaryKey, transaction)
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        try await _scanRecord(record, primaryKey, transaction)
    }
}

// MARK: - Value Index Maintainer

/// Maintainer for value indexes (standard B-tree)
public struct TypedValueIndexMaintainer<Record: Sendable, A: FieldAccessor>: TypedIndexMaintainer where A.Record == Record {
    public let index: TypedIndex<Record>
    public let subspace: Subspace
    public let accessor: A
    public let recordType: TypedRecordType<Record>

    public init(
        index: TypedIndex<Record>,
        subspace: Subspace,
        accessor: A,
        recordType: TypedRecordType<Record>
    ) {
        self.index = index
        self.subspace = subspace
        self.accessor = accessor
        self.recordType = recordType
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old index entry
        if let oldRecord = oldRecord {
            let oldKey = buildIndexKey(record: oldRecord, primaryKey: primaryKey)
            transaction.clear(key: oldKey)
        }

        // Add new index entry
        if let newRecord = newRecord {
            let newKey = buildIndexKey(record: newRecord, primaryKey: primaryKey)
            let value = buildIndexValue()
            transaction.setValue(value, for: newKey)
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let indexKey = buildIndexKey(record: record, primaryKey: primaryKey)
        let value = buildIndexValue()
        transaction.setValue(value, for: indexKey)
    }

    // MARK: - Private Methods

    private func buildIndexKey(record: Record, primaryKey: Tuple) -> FDB.Bytes {
        // Evaluate index expression to get indexed values
        let indexedValues = index.rootExpression.evaluate(record: record, accessor: accessor)

        // Append primary key for uniqueness
        let primaryKeyElements = try! Tuple.decode(from: primaryKey.encode())
        let allElements: [any TupleElement] = indexedValues + primaryKeyElements.map { $0 as any TupleElement }

        // Build tuple and encode with subspace
        let tuple = TupleHelpers.toTuple(allElements)
        return subspace.pack(tuple)
    }

    private func buildIndexValue() -> FDB.Bytes {
        // For value indexes, we typically store empty value
        return FDB.Bytes()
    }
}

// MARK: - Count Index Maintainer

/// Maintainer for count aggregation indexes
public struct TypedCountIndexMaintainer<Record: Sendable, A: FieldAccessor>: TypedIndexMaintainer where A.Record == Record {
    public let index: TypedIndex<Record>
    public let subspace: Subspace
    public let accessor: A

    public init(
        index: TypedIndex<Record>,
        subspace: Subspace,
        accessor: A
    ) {
        self.index = index
        self.subspace = subspace
        self.accessor = accessor
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // Determine the grouping key
        let groupingValues: [any TupleElement]?

        if let newRecord = newRecord {
            groupingValues = index.rootExpression.evaluate(record: newRecord, accessor: accessor)
        } else if let oldRecord = oldRecord {
            groupingValues = index.rootExpression.evaluate(record: oldRecord, accessor: accessor)
        } else {
            return
        }

        guard let values = groupingValues else { return }

        let groupingTuple = TupleHelpers.toTuple(values)
        let countKey = subspace.pack(groupingTuple)

        // Calculate delta
        let delta: Int64 = (newRecord != nil ? 1 : 0) - (oldRecord != nil ? 1 : 0)

        if delta != 0 {
            let deltaBytes = TupleHelpers.int64ToBytes(delta)
            transaction.atomicOp(key: countKey, param: deltaBytes, mutationType: .add)
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let values = index.rootExpression.evaluate(record: record, accessor: accessor)
        let groupingTuple = TupleHelpers.toTuple(values)
        let countKey = subspace.pack(groupingTuple)

        let increment = TupleHelpers.int64ToBytes(1)
        transaction.atomicOp(key: countKey, param: increment, mutationType: .add)
    }
}

// MARK: - Sum Index Maintainer

/// Maintainer for sum aggregation indexes
public struct TypedSumIndexMaintainer<Record: Sendable, A: FieldAccessor>: TypedIndexMaintainer where A.Record == Record {
    public let index: TypedIndex<Record>
    public let subspace: Subspace
    public let accessor: A

    public init(
        index: TypedIndex<Record>,
        subspace: Subspace,
        accessor: A
    ) {
        self.index = index
        self.subspace = subspace
        self.accessor = accessor
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        if let newRecord = newRecord {
            let values = index.rootExpression.evaluate(record: newRecord, accessor: accessor)
            if values.count >= 2 {
                let groupingValues = Array(values.dropLast())
                let sumValue = try extractNumericValue(values.last!)

                let groupingTuple = TupleHelpers.toTuple(groupingValues)
                let sumKey = subspace.pack(groupingTuple)

                let deltaBytes = TupleHelpers.int64ToBytes(sumValue)
                transaction.atomicOp(key: sumKey, param: deltaBytes, mutationType: .add)
            }
        }

        if let oldRecord = oldRecord {
            let values = index.rootExpression.evaluate(record: oldRecord, accessor: accessor)
            if values.count >= 2 {
                let groupingValues = Array(values.dropLast())
                let sumValue = try extractNumericValue(values.last!)

                let groupingTuple = TupleHelpers.toTuple(groupingValues)
                let sumKey = subspace.pack(groupingTuple)

                let deltaBytes = TupleHelpers.int64ToBytes(-sumValue)
                transaction.atomicOp(key: sumKey, param: deltaBytes, mutationType: .add)
            }
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let values = index.rootExpression.evaluate(record: record, accessor: accessor)

        guard values.count >= 2 else {
            throw RecordLayerError.internalError("Sum index requires at least 2 values")
        }

        let groupingValues = Array(values.dropLast())
        let sumValue = try extractNumericValue(values.last!)

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let sumKey = subspace.pack(groupingTuple)

        let valueBytes = TupleHelpers.int64ToBytes(sumValue)
        transaction.atomicOp(key: sumKey, param: valueBytes, mutationType: .add)
    }

    // MARK: - Private

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
            throw RecordLayerError.internalError("Sum index value must be numeric")
        }
    }
}
