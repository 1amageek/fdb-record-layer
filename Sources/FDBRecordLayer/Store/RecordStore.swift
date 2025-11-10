import Foundation
import FoundationDB
import Logging

/// Record store for managing a specific record type
///
/// RecordStore manages a single record type with type safety guaranteed at compile time.
///
/// **Basic Usage Example**:
/// ```swift
/// // Create Schema (define types and indexes)
/// let schema = Schema([User.self])
///
/// // Initialize typed RecordStore
/// let userStore = RecordStore<User>(
///     database: database,
///     subspace: subspace,
///     schema: schema,
///     statisticsManager: statisticsManager
/// )
///
/// // Type-safe save (no type parameter needed)
/// try await userStore.save(user)
///
/// // Type-safe fetch (no User.self needed)
/// if let user = try await userStore.fetch(by: 1) {
///     print(user.name)
/// }
///
/// // Type-safe query (no User.self needed)
/// let users = try await userStore.query()
///     .where(\.name == "Alice")
///     .execute()
/// ```
///
/// **Composite Primary Key Example**:
///
/// Composite primary keys ensure uniqueness through a combination of multiple fields.
/// Supported in two ways:
///
/// 1. **Using Tuple Type**:
/// ```swift
/// struct OrderItem: Recordable {
///     // Composite primary key: (orderID, itemID)
///     static var primaryKey: KeyPath<OrderItem, Tuple> = \.compositeKey
///
///     let orderID: String
///     let itemID: String
///     var quantity: Int
///
///     var compositeKey: Tuple {
///         Tuple(orderID, itemID)
///     }
/// }
///
/// // Save
/// let item = OrderItem(orderID: "order-001", itemID: "item-456", quantity: 2)
/// try await store.save(item)
///
/// // Fetch: using Tuple
/// let key = Tuple("order-001", "item-456")
/// if let item = try await store.fetch(by: key) {
///     print("Found: \(item.quantity)")
/// }
///
/// // Delete: using Tuple
/// try await store.delete(by: Tuple("order-001", "item-456"))
/// ```
///
/// 2. **Using Variadic Arguments (Recommended)**:
/// ```swift
/// // Fetch: variadic arguments (more concise)
/// if let item = try await store.fetch(by: "order-001", "item-456") {
///     print("Found: \(item.quantity)")
/// }
///
/// // Delete: variadic arguments
/// try await store.delete(by: "order-001", "item-456")
///
/// // Can also be used within transactions
/// try await store.transaction { transaction in
///     if let item = try await transaction.fetch(by: "order-001", "item-456") {
///         var updated = item
///         updated.quantity += 1
///         try await transaction.save(updated)
///     }
/// }
/// ```
///
/// **Important Notes**:
/// - Internal key format is unified for single and composite primary keys
/// - `fetchInternal`/`deleteInternal` automatically normalize keys
/// - Variadic argument versions support both single and composite keys
public final class RecordStore<Record: Recordable>: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    public let subspace: Subspace
    public let schema: Schema
    private let logger: Logger

    /// Statistics manager for cost-based query optimization
    private let statisticsManager: any StatisticsManagerProtocol

    /// Metrics recorder for observability
    private let metricsRecorder: any MetricsRecorder

    /// Aggregate metrics for MIN/MAX/COUNT/SUM queries
    public let aggregateMetrics: AggregateMetrics

    // Subspaces
    internal let recordSubspace: Subspace
    internal let indexSubspace: Subspace

    // MARK: - Initialization

    /// Initialize RecordStore with injected StatisticsManager
    ///
    /// - Parameters:
    ///   - database: The FDB database
    ///   - subspace: The subspace for this record store
    ///   - schema: Schema with registered types and indexes
    ///   - statisticsManager: Statistics manager for cost-based optimization
    ///   - logger: Optional logger
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        statisticsManager: any StatisticsManagerProtocol,
        metricsRecorder: any MetricsRecorder = NullMetricsRecorder(),
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.schema = schema
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.store")
        self.statisticsManager = statisticsManager
        self.metricsRecorder = metricsRecorder
        self.aggregateMetrics = AggregateMetrics()

        // Initialize subspaces
        self.recordSubspace = subspace.subspace(Tuple("R"))  // Records
        self.indexSubspace = subspace.subspace(Tuple("I"))    // Indexes
    }

    // MARK: - Statistics Support

    /// Create RecordStore with real StatisticsManager for cost-based optimization
    ///
    /// This is the recommended way to create a RecordStore for production use.
    /// It automatically initializes a StatisticsManager for cost-based query optimization.
    ///
    /// **Example**:
    /// ```swift
    /// // Create StatisticsManager first
    /// let statsManager = StatisticsManager(
    ///     database: database,
    ///     subspace: subspace.subspace(Tuple("stats"))
    /// )
    ///
    /// // Create RecordStore with statistics support
    /// let store = RecordStore(
    ///     database: database,
    ///     subspace: subspace,
    ///     schema: schema,
    ///     statisticsManager: statsManager
    /// )
    /// ```
    ///
    /// - Note: For testing or environments where statistics are not needed,
    ///         you can pass `NullStatisticsManager()` instead.

    // MARK: - Internal Methods (shared by RecordStore and RecordTransaction)

    /// Internal save logic (shared between RecordStore and RecordTransaction)
    ///
    /// - Parameters:
    ///   - record: Record to save
    ///   - context: Transaction context
    /// - Throws: RecordLayerError if save fails
    internal func saveInternal(_ record: Record, context: RecordContext) async throws {
        let recordAccess = GenericRecordAccess<Record>()
        let bytes = try recordAccess.serialize(record)
        let primaryKey = recordAccess.extractPrimaryKey(from: record)

        // Subspace control: Always automatically add record type name
        //
        // Future enhancement: #Subspace macro support for custom partitioning
        //
        // The #Subspace macro would allow declarative multi-tenant or regional partitioning:
        // ```swift
        // @Recordable
        // #Subspace([\.tenantID, \.region])
        // struct Order {
        //     var tenantID: String
        //     var region: String
        //     @PrimaryKey var orderID: Int64
        // }
        // ```
        //
        // Implementation requirements:
        // 1. Macro generates `subspaceKeyPath` static property on Recordable
        // 2. RecordAccess.extractSubspaceKey(from:) method
        // 3. Migration strategy for existing data
        // 4. Query planner awareness of subspace structure
        //
        // Current design (record type name) is sufficient for most use cases and
        // maintains compatibility with standard Record Layer patterns.
        let effectiveSubspace = recordSubspace.subspace(Tuple([Record.recordName]))
        let key = effectiveSubspace.subspace(primaryKey).pack(Tuple())

        let tr = context.getTransaction()

        // Load old record if it exists (for index updates)
        let oldRecord: Record?
        if let existingBytes = try await tr.getValue(for: key, snapshot: false) {
            oldRecord = try recordAccess.deserialize(existingBytes)
        } else {
            oldRecord = nil
        }

        // Save the record
        tr.setValue(bytes, for: key)

        // Update indexes
        let indexManager = IndexManager(schema: schema, subspace: indexSubspace)
        try await indexManager.updateIndexes(
            for: record,
            primaryKey: primaryKey,
            oldRecord: oldRecord,
            context: context,
            recordSubspace: recordSubspace
        )
    }

    /// Internal fetch logic (shared between RecordStore and RecordTransaction)
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key value
    ///   - context: Transaction context
    /// - Returns: Record (nil if not found)
    /// - Throws: RecordLayerError if fetch fails
    internal func fetchInternal(by primaryKey: any TupleElement, context: RecordContext) async throws -> Record? {
        let recordAccess = GenericRecordAccess<Record>()

        // Subspace control: Always automatically add record type name (Phase 2a-1)
        let effectiveSubspace = recordSubspace.subspace(Tuple([Record.recordName]))

        // Composite primary key support: Use Tuple as-is, or convert single value to Tuple
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.subspace(keyTuple).pack(Tuple())

        let tr = context.getTransaction()
        guard let bytes = try await tr.getValue(for: key, snapshot: false) else {
            return nil
        }

        return try recordAccess.deserialize(bytes)
    }

    /// Internal delete logic (shared between RecordStore and RecordTransaction)
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key value
    ///   - context: Transaction context
    /// - Throws: RecordLayerError if delete fails
    internal func deleteInternal(by primaryKey: any TupleElement, context: RecordContext) async throws {
        let recordAccess = GenericRecordAccess<Record>()

        // Subspace control: Always automatically add record type name (Phase 2a-1)
        let effectiveSubspace = recordSubspace.subspace(Tuple([Record.recordName]))

        // Composite primary key support: Use Tuple as-is, or convert single value to Tuple
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.subspace(keyTuple).pack(Tuple())

        let tr = context.getTransaction()

        // Load the record before deletion (needed for index updates)
        guard let existingBytes = try await tr.getValue(for: key, snapshot: false) else {
            // Record doesn't exist, nothing to delete
            return
        }

        // Deserialize the record
        let record = try recordAccess.deserialize(existingBytes)

        // Delete the record
        tr.clear(key: key)

        // Delete index entries
        let indexManager = IndexManager(schema: schema, subspace: indexSubspace)
        try await indexManager.deleteIndexes(
            oldRecord: record,
            primaryKey: keyTuple,
            context: context,
            recordSubspace: recordSubspace
        )
    }

    // MARK: - Save

    /// Save a record (type-safe)
    ///
    /// - Parameter record: Record to save
    /// - Throws: RecordLayerError if save fails
    public func save(_ record: Record) async throws {
        let start = DispatchTime.now()

        do {
            // Create transaction
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            // Use common logic
            try await saveInternal(record, context: context)

            try await context.commit()

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordSave(duration: duration)

            // Structured logging with record-type details
            logger.trace("Record saved", metadata: [
                "recordType": "\(Record.recordName)",
                "duration_ns": "\(duration)",
                "operation": "save"
            ])
        } catch {
            // Record error metrics
            metricsRecorder.recordError(
                operation: "save",
                errorType: String(reflecting: Swift.type(of: error))
            )

            // Structured logging for error details
            logger.error("Failed to save record", metadata: [
                "recordType": "\(Record.recordName)",
                "operation": "save",
                "error": "\(error)"
            ])

            throw error
        }
    }

    // MARK: - Fetch

    /// Fetch a record by primary key
    ///
    /// - Parameter primaryKey: Primary key value
    /// - Returns: Record (nil if not found)
    /// - Throws: RecordLayerError if fetch fails
    public func record(
        for primaryKey: any TupleElement
    ) async throws -> Record? {
        let start = DispatchTime.now()

        do {
            // Create transaction
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            // Use common logic
            let result = try await fetchInternal(by: primaryKey, context: context)

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordFetch(duration: duration)

            // Structured logging
            logger.trace("Record fetch completed", metadata: [
                "recordType": "\(Record.recordName)",
                "duration_ns": "\(duration)",
                "operation": "fetch",
                "found": "\(result != nil)"
            ])

            return result
        } catch {
            // Record error metrics
            metricsRecorder.recordError(
                operation: "fetch",
                errorType: String(reflecting: Swift.type(of: error))
            )

            // Structured logging for error details
            logger.error("Failed to fetch record", metadata: [
                "recordType": "\(Record.recordName)",
                "operation": "fetch",
                "error": "\(error)"
            ])

            throw error
        }
    }

    /// Fetch a record by composite primary key (variadic argument version)
    ///
    /// **Usage Example**:
    /// ```swift
    /// // Single key
    /// let user = try await store.fetch(by: 123)
    ///
    /// // Composite key (variadic arguments)
    /// let orderItem = try await store.record(forCompositeKey: "order-001", "item-456")
    /// ```
    ///
    /// - Parameter keys: Primary key elements (variadic)
    /// - Returns: Record (nil if not found)
    /// - Throws: RecordLayerError if fetch fails
    public func record(
        forCompositeKey keys: any TupleElement...
    ) async throws -> Record? {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "record(forCompositeKey:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        return try await record(for: primaryKey)
    }

    // MARK: - Query

    /// Create a query builder (no type parameter needed)
    ///
    /// - Returns: Query builder
    public func query() -> QueryBuilder<Record> {
        return QueryBuilder(
            store: self,
            recordType: Record.self,
            schema: schema,
            database: database,
            subspace: subspace,
            statisticsManager: statisticsManager
        )
    }

    // MARK: - Delete

    /// Delete a record
    ///
    /// - Parameter primaryKey: Primary key value
    /// - Throws: RecordLayerError if delete fails
    public func delete(
        by primaryKey: any TupleElement
    ) async throws {
        let start = DispatchTime.now()

        do {
            // Create transaction
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            // Use common logic
            try await deleteInternal(by: primaryKey, context: context)

            try await context.commit()

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordDelete(duration: duration)

            // Structured logging
            logger.trace("Record delete completed", metadata: [
                "recordType": "\(Record.recordName)",
                "duration_ns": "\(duration)",
                "operation": "delete"
            ])
        } catch {
            // Record error metrics
            metricsRecorder.recordError(
                operation: "delete",
                errorType: String(reflecting: Swift.type(of: error))
            )

            // Structured logging for error details
            logger.error("Failed to delete record", metadata: [
                "recordType": "\(Record.recordName)",
                "operation": "delete",
                "error": "\(error)"
            ])

            throw error
        }
    }

    /// Delete a record by composite primary key (variadic argument version)
    ///
    /// **Usage Example**:
    /// ```swift
    /// // Single key
    /// try await store.delete(by: 123)
    ///
    /// // Composite key (variadic arguments)
    /// try await store.delete(by: "order-001", "item-456")
    /// ```
    ///
    /// - Parameter keys: Primary key elements (variadic)
    /// - Throws: RecordLayerError if delete fails
    public func delete(
        by keys: any TupleElement...
    ) async throws {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "delete(by:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        try await delete(by: primaryKey)
    }

    // MARK: - Transaction

    /// Execute operations within a transaction
    ///
    /// - Parameter block: Block to execute within the transaction
    /// - Returns: Return value of the block
    /// - Throws: Error thrown by the block
    public func transaction<T>(
        _ block: (RecordTransaction<Record>) async throws -> T
    ) async throws -> T {
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let recordTransaction = RecordTransaction<Record>(
            store: self,
            context: context
        )

        let result = try await block(recordTransaction)
        try await context.commit()

        return result
    }
}

// MARK: - RecordTransaction

/// RecordStore wrapper for use within a transaction
///
/// Used to perform record operations within a transaction.
public struct RecordTransaction<Record: Recordable> {
    private let store: RecordStore<Record>
    internal let context: RecordContext

    internal init(store: RecordStore<Record>, context: RecordContext) {
        self.store = store
        self.context = context
    }

    /// Save a record
    public func save(_ record: Record) async throws {
        // Use common logic
        try await store.saveInternal(record, context: context)
    }

    /// Fetch a record
    public func record(
        for primaryKey: any TupleElement
    ) async throws -> Record? {
        // Use common logic
        return try await store.fetchInternal(by: primaryKey, context: context)
    }

    /// Fetch a record by composite primary key (variadic argument version)
    ///
    /// **Usage Example**:
    /// ```swift
    /// try await store.transaction { transaction in
    ///     // Single key
    ///     let user = try await transaction.record(for: 123)
    ///
    ///     // Composite key (variadic arguments)
    ///     let orderItem = try await transaction.record(forCompositeKey: "order-001", "item-456")
    /// }
    /// ```
    ///
    /// - Parameter keys: Primary key elements (variadic)
    /// - Returns: Record (nil if not found)
    /// - Throws: RecordLayerError if fetch fails
    public func record(
        forCompositeKey keys: any TupleElement...
    ) async throws -> Record? {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "record(forCompositeKey:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        return try await record(for: primaryKey)
    }

    /// Delete a record
    public func delete(
        by primaryKey: any TupleElement
    ) async throws {
        // Use common logic
        try await store.deleteInternal(by: primaryKey, context: context)
    }

    /// Delete a record by composite primary key (variadic argument version)
    ///
    /// **Usage Example**:
    /// ```swift
    /// try await store.transaction { transaction in
    ///     // Single key
    ///     try await transaction.delete(by: 123)
    ///
    ///     // Composite key (variadic arguments)
    ///     try await transaction.delete(by: "order-001", "item-456")
    /// }
    /// ```
    ///
    /// - Parameter keys: Primary key elements (variadic)
    /// - Throws: RecordLayerError if delete fails
    public func delete(
        by keys: any TupleElement...
    ) async throws {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "delete(by:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        try await delete(by: primaryKey)
    }
}

// MARK: - Aggregate Functions

extension RecordStore {
    /// Evaluate an aggregate function on an index
    ///
    /// This method queries an aggregate index (COUNT, SUM, MIN, MAX) and returns
    /// the aggregated value for a specific grouping.
    ///
    /// **Example:**
    /// ```swift
    /// // Count users by city
    /// let count = try await store.evaluateAggregate(
    ///     .count(indexName: "user_count_by_city"),
    ///     groupBy: ["Tokyo"]
    /// )
    ///
    /// // Sum salaries by department
    /// let total = try await store.evaluateAggregate(
    ///     .sum(indexName: "salary_by_dept"),
    ///     groupBy: ["Engineering"]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - function: The aggregate function to evaluate
    ///   - groupBy: The grouping values (e.g., city name, department ID)
    /// - Returns: The aggregated result
    /// - Throws: RecordLayerError if index not found or evaluation fails
    public func evaluateAggregate<F: AggregateFunction>(
        _ function: F,
        groupBy: [any TupleElement]
    ) async throws -> F.Result {
        let startTime = Date()

        do {
            guard let index = schema.index(named: function.indexName) else {
                throw RecordLayerError.indexNotFound("Index '\(function.indexName)' not found in schema")
            }

            // Check index state - must be readable for queries
            let indexStateManager = IndexStateManager(database: database, subspace: subspace)
            let state = try await indexStateManager.state(of: function.indexName)

            guard state == .readable else {
                throw RecordLayerError.indexNotReady(
                    "Cannot query index '\(function.indexName)' in '\(state)' state. " +
                    "Index must be in 'readable' state for aggregate queries. " +
                    "Current state: \(state)"
                )
            }

            // Execute query in a read-only transaction with automatic lifecycle management
            let indexSubspace = self.indexSubspace.subspace(Tuple([function.indexName]))
            let result = try await database.withTransaction { transaction in
                try await function.evaluate(
                    index: index,
                    subspace: indexSubspace,
                    groupBy: groupBy,
                    transaction: transaction
                )
            }

            // Record successful query metrics
            let duration = Date().timeIntervalSince(startTime)
            aggregateMetrics.recordQuery(
                indexName: function.indexName,
                aggregateType: function.aggregateType,
                duration: duration
            )

            return result
        } catch {
            // Record failure metrics
            aggregateMetrics.recordFailure(
                indexName: function.indexName,
                aggregateType: function.aggregateType,
                error: error
            )
            throw error
        }
    }

    /// Evaluate an aggregate function with no grouping (aggregate over all records)
    ///
    /// For cases where you want the aggregate over all records without grouping.
    ///
    /// **Example:**
    /// ```swift
    /// // Total user count (all cities)
    /// let totalUsers = try await store.evaluateAggregate(
    ///     .count(indexName: "user_count")
    /// )
    /// ```
    ///
    /// - Parameter function: The aggregate function to evaluate
    /// - Returns: The aggregated result
    /// - Throws: RecordLayerError if index not found or evaluation fails
    public func evaluateAggregate<F: AggregateFunction>(
        _ function: F
    ) async throws -> F.Result {
        return try await evaluateAggregate(function, groupBy: [])
    }

    /// Evaluate an aggregate function with grouped results
    ///
    /// Returns a dictionary mapping each group to its aggregated value.
    ///
    /// **Example:**
    /// ```swift
    /// // Get count for all cities
    /// let cityCounts = try await store.evaluateAggregateGrouped(
    ///     .count(indexName: "user_count_by_city")
    /// )
    /// // Result: ["Tokyo": 1000, "NYC": 500, ...]
    /// ```
    ///
    /// - Parameter function: The aggregate function to evaluate
    /// - Returns: Dictionary mapping group keys to aggregated values
    /// - Throws: RecordLayerError if index not found or evaluation fails
    public func evaluateAggregateGrouped<F: AggregateFunction>(
        _ function: F
    ) async throws -> [String: F.Result] where F.Result == Int64 {
        // Create context for this operation (will auto-close on deinit)
        let context = try RecordContext(database: database)

        // Get index subspace
        let indexSubspace = self.indexSubspace.subspace(Tuple([function.indexName]))

        // Get transaction
        let transaction = context.getTransaction()

        // Scan all entries in the index
        let range = indexSubspace.range()
        let sequence = transaction.getRange(
            begin: range.begin,
            end: range.end,
            snapshot: true
        )

        var results: [String: F.Result] = [:]

        for try await (key, value) in sequence {
            // Extract group key from the index key
            let unpacked = try indexSubspace.unpack(key)

            // Build group key: serialize tuple to bytes for reliable hashing
            // This properly handles multi-element tuples by using FDB's tuple encoding
            let groupKeyBytes = unpacked.pack()
            let groupKeyString = groupKeyBytes.map { String(format: "%02x", $0) }.joined()

            // Decode aggregate value
            let aggregateValue = TupleHelpers.bytesToInt64(value)

            results[groupKeyString] = aggregateValue as F.Result
        }

        return results
    }
}
