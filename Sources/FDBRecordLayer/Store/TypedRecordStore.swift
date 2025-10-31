import Foundation
import FoundationDB
import Logging

/// Type-safe record store for managing records and indexes
///
/// TypedRecordStore is generic over the record type, providing full type safety
/// and compile-time guarantees.
public final class TypedRecordStore<Record: Sendable>: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    public let subspace: Subspace
    private let recordType: TypedRecordType<Record>
    private let indexes: [TypedIndex<Record>]
    private let serializer: any RecordSerializer<Record>
    private let accessor: any FieldAccessor<Record>
    private let logger: Logger
    private let indexStateManager: IndexStateManager

    // Subspaces
    private let recordSubspace: Subspace
    private let indexSubspace: Subspace
    private let indexStateSubspace: Subspace

    // MARK: - Initialization

    public init<A: FieldAccessor, S: RecordSerializer>(
        database: any DatabaseProtocol,
        subspace: Subspace,
        recordType: TypedRecordType<Record>,
        indexes: [TypedIndex<Record>] = [],
        serializer: S,
        accessor: A,
        logger: Logger? = nil
    ) where A.Record == Record, S.Record == Record {
        self.database = database
        self.subspace = subspace
        self.recordType = recordType
        self.indexes = indexes
        self.serializer = serializer
        self.accessor = accessor
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.store")
        self.indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace,
            logger: logger
        )

        // Initialize subspaces
        self.recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        self.indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
        self.indexStateSubspace = subspace.subspace(RecordStoreKeyspace.indexState.rawValue)
    }

    // MARK: - Record Operations

    /// Save a record
    ///
    /// If the record already exists (same primary key), it will be updated.
    /// All indexes are automatically maintained.
    public func save(_ record: Record, context: RecordContext) async throws {
        logger.debug("Saving record")

        let transaction = context.getTransaction()

        // 1. Extract primary key
        let primaryKey = recordType.extractPrimaryKey(from: record, accessor: accessor)

        // 2. Load existing record for index updates
        let existingRecord = try await load(primaryKey: primaryKey, context: context)

        // 3. Serialize new record
        let serialized = try serializer.serialize(record)

        // 4. Save record
        let recordKey = recordSubspace.pack(primaryKey)
        transaction.setValue(serialized, for: recordKey)

        // 5. Update indexes
        try await updateIndexesForRecord(
            oldRecord: existingRecord,
            newRecord: record,
            primaryKey: primaryKey,
            context: context
        )

        logger.debug("Record saved successfully")
    }

    /// Load a record by primary key
    public func load(primaryKey: Tuple, context: RecordContext) async throws -> Record? {
        logger.debug("Loading record with primary key")

        let transaction = context.getTransaction()
        let recordKey = recordSubspace.pack(primaryKey)

        guard let bytes = try await transaction.getValue(for: recordKey) else {
            logger.debug("Record not found")
            return nil
        }

        let record = try serializer.deserialize(bytes)
        logger.debug("Record loaded successfully")
        return record
    }

    /// Delete a record by primary key
    public func delete(primaryKey: Tuple, context: RecordContext) async throws {
        logger.debug("Deleting record with primary key")

        let transaction = context.getTransaction()

        // 1. Load existing record for index updates
        guard let existingRecord = try await load(primaryKey: primaryKey, context: context) else {
            logger.debug("Record not found, nothing to delete")
            return
        }

        // 2. Delete record
        let recordKey = recordSubspace.pack(primaryKey)
        transaction.clear(key: recordKey)

        // 3. Update indexes
        try await updateIndexesForRecord(
            oldRecord: existingRecord,
            newRecord: nil,
            primaryKey: primaryKey,
            context: context
        )

        logger.debug("Record deleted successfully")
    }

    // MARK: - Query Execution

    /// Execute a query and return a cursor over the results
    public func executeQuery(
        _ query: TypedRecordQuery<Record>,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Filter to only readable indexes (using the same transaction context)
        let readableIndexes = try await filterReadableIndexes(context: context)

        // Create a query planner with only readable indexes
        let planner = TypedRecordQueryPlanner(recordType: recordType, indexes: readableIndexes)

        // Generate an execution plan
        let plan = try planner.plan(query)

        // Execute the plan
        return try await plan.execute(
            subspace: subspace,
            serializer: serializer,
            accessor: accessor,
            context: context
        )
    }

    /// Execute a query and collect all results into an array
    public func records(
        matching query: TypedRecordQuery<Record>,
        context: RecordContext
    ) async throws -> [Record] {
        let cursor = try await executeQuery(query, context: context)

        var results: [Record] = []
        for try await record in cursor {
            results.append(record)
        }

        return results
    }

    /// Execute a query and return the first result
    public func firstRecord(
        matching query: TypedRecordQuery<Record>,
        context: RecordContext
    ) async throws -> Record? {
        // Add limit to the query if not already present
        let limitedQuery: TypedRecordQuery<Record>
        if query.limit == nil {
            limitedQuery = query.limit(1)
        } else {
            limitedQuery = query
        }

        let cursor = try await executeQuery(limitedQuery, context: context)

        var iterator = cursor.makeAsyncIterator()
        return try await iterator.next()
    }

    /// Count records matching a query
    public func count(
        matching query: TypedRecordQuery<Record>,
        context: RecordContext
    ) async throws -> Int {
        let cursor = try await executeQuery(query, context: context)

        var count = 0
        for try await _ in cursor {
            count += 1
        }

        return count
    }

    // MARK: - Index Management

    /// Get index state
    ///
    /// Delegates to IndexStateManager for consistent state management
    public func indexState(of indexName: String, context: RecordContext) async throws -> IndexState {
        return try await indexStateManager.state(of: indexName, context: context)
    }

    // MARK: - Internal Methods

    /// Filter indexes to only those that are readable
    ///
    /// - Parameter context: Transaction context for consistent state reading
    /// - Returns: List of readable indexes
    private func filterReadableIndexes(context: RecordContext) async throws -> [TypedIndex<Record>] {
        let indexNames = indexes.map { $0.name }
        let states = try await indexStateManager.states(of: indexNames, context: context)

        return indexes.filter { index in
            guard let state = states[index.name] else { return false }
            return state.isReadable
        }
    }

    /// Filter indexes to only those that should be maintained
    ///
    /// - Parameter context: Transaction context for consistent state reading
    /// - Returns: List of maintainable indexes
    private func filterMaintainableIndexes(context: RecordContext) async throws -> [TypedIndex<Record>] {
        let indexNames = indexes.map { $0.name }
        let states = try await indexStateManager.states(of: indexNames, context: context)

        return indexes.filter { index in
            guard let state = states[index.name] else { return false }
            return state.shouldMaintain
        }
    }

    private func updateIndexesForRecord(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        context: RecordContext
    ) async throws {
        let transaction = context.getTransaction()

        // Only update indexes that should be maintained (using the same transaction context)
        let maintainableIndexes = try await filterMaintainableIndexes(context: context)

        for index in maintainableIndexes {
            let maintainer = createIndexMaintainer(for: index)

            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: newRecord,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    private func createIndexMaintainer(for index: TypedIndex<Record>) -> AnyTypedIndexMaintainer<Record> {
        let indexSubspace = self.indexSubspace.subspace(index.subspaceTupleKey)

        // We need to work around the existential type issue by creating closures
        // that capture the accessor and perform the operations

        let updateFunc: @Sendable (Record?, Record?, Tuple, any TransactionProtocol) async throws -> Void
        let scanFunc: @Sendable (Record, Tuple, any TransactionProtocol) async throws -> Void

        let accessor = self.accessor
        let extractNumeric = Self.extractNumericValue

        switch index.type {
        case .value:
            updateFunc = { oldRecord, newRecord, primaryKey, transaction in
                if let oldRecord = oldRecord {
                    let indexedValues = index.rootExpression.evaluate(record: oldRecord, accessor: accessor)
                    let primaryKeyElements = try Tuple.decode(from: primaryKey.encode())
                    let allElements = indexedValues + primaryKeyElements
                    let tuple = TupleHelpers.toTuple(allElements)
                    let oldKey = indexSubspace.pack(tuple)
                    transaction.clear(key: oldKey)
                }

                if let newRecord = newRecord {
                    let indexedValues = index.rootExpression.evaluate(record: newRecord, accessor: accessor)
                    let primaryKeyElements = try Tuple.decode(from: primaryKey.encode())
                    let allElements = indexedValues + primaryKeyElements
                    let tuple = TupleHelpers.toTuple(allElements)
                    let newKey = indexSubspace.pack(tuple)
                    transaction.setValue(FDB.Bytes(), for: newKey)
                }
            }

            scanFunc = { record, primaryKey, transaction in
                let indexedValues = index.rootExpression.evaluate(record: record, accessor: accessor)
                let primaryKeyElements = try Tuple.decode(from: primaryKey.encode())
                let allElements = indexedValues + primaryKeyElements
                let tuple = TupleHelpers.toTuple(allElements)
                let indexKey = indexSubspace.pack(tuple)
                transaction.setValue(FDB.Bytes(), for: indexKey)
            }

        case .count:
            updateFunc = { oldRecord, newRecord, primaryKey, transaction in
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
                let countKey = indexSubspace.pack(groupingTuple)

                let delta: Int64 = (newRecord != nil ? 1 : 0) - (oldRecord != nil ? 1 : 0)
                if delta != 0 {
                    let deltaBytes = TupleHelpers.int64ToBytes(delta)
                    transaction.atomicOp(key: countKey, param: deltaBytes, mutationType: .add)
                }
            }

            scanFunc = { record, primaryKey, transaction in
                let values = index.rootExpression.evaluate(record: record, accessor: accessor)
                let groupingTuple = TupleHelpers.toTuple(values)
                let countKey = indexSubspace.pack(groupingTuple)
                let increment = TupleHelpers.int64ToBytes(1)
                transaction.atomicOp(key: countKey, param: increment, mutationType: .add)
            }

        case .sum:
            updateFunc = { oldRecord, newRecord, primaryKey, transaction in
                if let newRecord = newRecord {
                    let values = index.rootExpression.evaluate(record: newRecord, accessor: accessor)
                    if values.count >= 2 {
                        let groupingValues = Array(values.dropLast())
                        let sumValue = try extractNumeric(values.last!)
                        let groupingTuple = TupleHelpers.toTuple(groupingValues)
                        let sumKey = indexSubspace.pack(groupingTuple)
                        let deltaBytes = TupleHelpers.int64ToBytes(sumValue)
                        transaction.atomicOp(key: sumKey, param: deltaBytes, mutationType: .add)
                    }
                }

                if let oldRecord = oldRecord {
                    let values = index.rootExpression.evaluate(record: oldRecord, accessor: accessor)
                    if values.count >= 2 {
                        let groupingValues = Array(values.dropLast())
                        let sumValue = try extractNumeric(values.last!)
                        let groupingTuple = TupleHelpers.toTuple(groupingValues)
                        let sumKey = indexSubspace.pack(groupingTuple)
                        let deltaBytes = TupleHelpers.int64ToBytes(-sumValue)
                        transaction.atomicOp(key: sumKey, param: deltaBytes, mutationType: .add)
                    }
                }
            }

            scanFunc = { record, primaryKey, transaction in
                let values = index.rootExpression.evaluate(record: record, accessor: accessor)
                guard values.count >= 2 else {
                    throw RecordLayerError.internalError("Sum index requires at least 2 values")
                }
                let groupingValues = Array(values.dropLast())
                let sumValue = try extractNumeric(values.last!)
                let groupingTuple = TupleHelpers.toTuple(groupingValues)
                let sumKey = indexSubspace.pack(groupingTuple)
                let valueBytes = TupleHelpers.int64ToBytes(sumValue)
                transaction.atomicOp(key: sumKey, param: valueBytes, mutationType: .add)
            }

        case .rank, .version, .permuted:
            fatalError("Index type \(index.type) not yet implemented")
        }

        // Create a simple maintainer from the closures
        return AnyTypedIndexMaintainer(SimpleIndexMaintainer(updateFunc: updateFunc, scanFunc: scanFunc))
    }

    private static func extractNumericValue(_ element: any TupleElement) throws -> Int64 {
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

/// Simple maintainer implementation using closures
private struct SimpleIndexMaintainer<Record: Sendable>: TypedIndexMaintainer {
    let updateFunc: @Sendable (Record?, Record?, Tuple, any TransactionProtocol) async throws -> Void
    let scanFunc: @Sendable (Record, Tuple, any TransactionProtocol) async throws -> Void

    func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        try await updateFunc(oldRecord, newRecord, primaryKey, transaction)
    }

    func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        try await scanFunc(record, primaryKey, transaction)
    }
}
