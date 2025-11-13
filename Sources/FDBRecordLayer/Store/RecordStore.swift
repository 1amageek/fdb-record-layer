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

    /// Root subspace for global indexes
    ///
    /// When provided, global-scoped indexes will be stored at the root level for cross-partition access.
    /// If nil, global indexes will fall back to partition-local storage (backward compatibility).
    internal let rootSubspace: Subspace?

    // MARK: - Internal API for Index Operations

    /// Execute a closure with direct database transaction access
    ///
    /// **INTERNAL USE ONLY**: This method is for internal index implementations
    /// that need direct TransactionProtocol access (e.g., RankIndexAPI).
    ///
    /// - Parameter operation: Closure that receives a TransactionProtocol
    /// - Returns: The result of the operation
    /// - Throws: Any error thrown by the operation
    internal func withDatabaseTransaction<T: Sendable>(
        _ operation: @Sendable (any TransactionProtocol) async throws -> T
    ) async throws -> T {
        return try await database.withTransaction(operation)
    }

    /// Fetch record by primary key using TransactionProtocol
    ///
    /// **INTERNAL USE ONLY**: This method is for internal index implementations
    /// that already have a TransactionProtocol (e.g., RankIndexAPI).
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    ///   - transaction: Transaction to use for the fetch
    /// - Returns: The fetched record, or nil if not found
    /// - Throws: RecordLayerError if fetch fails
    internal func fetchByPrimaryKey(
        _ primaryKey: any TupleElement,
        transaction: any TransactionProtocol
    ) async throws -> Record? {
        let recordAccess = GenericRecordAccess<Record>()

        // Subspace control: Always automatically add record type name
        let effectiveSubspace = recordSubspace.subspace(Record.recordName)

        // Composite primary key support: Use Tuple as-is, or convert single value to Tuple
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.subspace(keyTuple).pack(Tuple())

        guard let bytes = try await transaction.getValue(for: key, snapshot: false) else {
            return nil
        }

        return try recordAccess.deserialize(bytes)
    }

    // MARK: - Initialization

    /// Initialize RecordStore with injected StatisticsManager
    ///
    /// - Parameters:
    ///   - database: The FDB database
    ///   - subspace: The subspace for this record store
    ///   - schema: Schema with registered types and indexes
    ///   - statisticsManager: Statistics manager for cost-based optimization
    ///   - rootSubspace: Optional root subspace for global indexes (defaults to subspace for backward compatibility)
    ///   - metricsRecorder: Metrics recorder for observability
    ///   - logger: Optional logger
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        statisticsManager: any StatisticsManagerProtocol,
        rootSubspace: Subspace? = nil,
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
        self.rootSubspace = rootSubspace

        // Initialize subspaces
        self.recordSubspace = subspace.subspace("R")  // Records
        self.indexSubspace = subspace.subspace("I")    // Indexes
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
        let effectiveSubspace = recordSubspace.subspace(Record.recordName)
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
        let indexManager = IndexManager(schema: schema, subspace: indexSubspace, rootSubspace: rootSubspace)
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
        let effectiveSubspace = recordSubspace.subspace(Record.recordName)

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
        let effectiveSubspace = recordSubspace.subspace(Record.recordName)

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
        let indexManager = IndexManager(schema: schema, subspace: indexSubspace, rootSubspace: rootSubspace)
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

    /// Get rank of a specific value
    ///
    /// Returns the rank (0-based) of a specific value in the specified field.
    /// Requires a RANK index on the target field in readable state.
    ///
    /// **Prerequisites**:
    /// - A RANK index must be defined on the target field
    /// - The index must be in 'readable' state
    ///
    /// **Performance**:
    /// - O(log n) where n = total records
    /// - Linear search: O(n)
    /// - **Improvement**: Up to 1,000x faster (for 1M records)
    ///
    /// **Example**:
    /// ```swift
    /// // Get user's rank by score
    /// let userScore: Int64 = 9500
    /// if let rank = try await store.rank(of: userScore, in: \.score, for: user) {
    ///     print("User is ranked #\(rank)")  // Already 1-based (1 = best)
    /// }
    ///
    /// // With explicit index name
    /// if let rank = try await store.rank(
    ///     of: userScore,
    ///     in: \.score,
    ///     for: user,
    ///     indexName: "user_by_score_rank"
    /// ) {
    ///     print("Rank: \(rank)")  // 1-based rank
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - value: Value to find rank for (score)
    ///   - keyPath: KeyPath to the ranked field
    ///   - record: The record instance (needed for grouping values and primary key)
    ///   - indexName: Index name to use (optional, auto-detected if nil)
    /// - Returns: **1-based rank** (1 = best, 2 = second, etc.), nil if record not found in index
    /// - Throws: RecordLayerError if index not found or not ready
    ///
    /// **Performance**: O(log n) using Range Tree count nodes
    ///
    /// **Supports**:
    /// - Simple RANK indexes: `Index([\.score])`
    /// - Grouped RANK indexes: `Index([\.gameID, \.score])` for per-game leaderboards
    // ✅ BUG FIX #3: Restrict type signature to BinaryInteger (not Comparable)
    // This provides compile-time safety - only Int/Int64/Int32/UInt types are allowed
    /// Get the rank by score, primary key, and grouping values (no record instance needed)
    ///
    /// **Use Case**: Ranking screens where you only have the primary key and score,
    /// without needing to load the full record from the database.
    ///
    /// **Example**:
    /// ```swift
    /// // Leaderboard: Get rank for a specific player
    /// let rank = try await store.rank(
    ///     score: 9500,
    ///     primaryKey: 12345,  // playerID
    ///     grouping: ["game_123"],  // For grouped indexes
    ///     indexName: "player_score_rank"
    /// )
    /// print("Player #12345 is ranked: \(rank ?? 0)")
    /// ```
    ///
    /// - Parameters:
    ///   - score: The score value (must match the index's scoreTypeName)
    ///   - primaryKey: Primary key value (single field or tuple)
    ///   - grouping: Grouping values for grouped indexes (empty for simple indexes)
    ///   - indexName: Name of the RANK index to use
    /// - Returns: **1-based rank** (1 = best), or nil if not found
    /// - Throws: RecordLayerError if index not found, not ready, or score type mismatch
    public func rank(
        score: any TupleElement,
        primaryKey: any TupleElement,
        grouping: [any TupleElement] = [],
        indexName: String
    ) async throws -> Int? {
        // 1. Find RANK index by name
        let applicableIndexes = schema.indexes(for: Record.recordName)

        guard let targetIndex = applicableIndexes.first(where: { $0.name == indexName }) else {
            throw RecordLayerError.indexNotFound("RANK index '\(indexName)' not found")
        }

        // Validate that it's a RANK index
        guard targetIndex.type == .rank else {
            throw RecordLayerError.invalidArgument(
                "Index '\(indexName)' is type '\(targetIndex.type)', not a RANK index. " +
                "Use rank() API for RANK indexes only."
            )
        }

        // 2. Verify index is in readable state
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let state = try await indexStateManager.state(of: targetIndex.name, context: context)

        guard state == .readable else {
            throw RecordLayerError.indexNotReady("RANK index '\(targetIndex.name)' is in '\(state)' state")
        }

        // 3. Convert primaryKey to Tuple
        let primaryKeyTuple: Tuple
        if let tuple = primaryKey as? Tuple {
            primaryKeyTuple = tuple
        } else {
            primaryKeyTuple = Tuple(primaryKey)
        }

        // 4. Delegate to dynamic rank helper for O(log n) rank calculation
        let indexNameSubspace = indexSubspace.subspace(targetIndex.name)
        return try await getRankDynamic(
            recordType: Record.self,
            index: targetIndex,
            subspace: indexNameSubspace,
            recordSubspace: recordSubspace,
            groupingValues: grouping,
            score: score,
            primaryKey: primaryKeyTuple,
            transaction: context.getTransaction()
        )
    }

    /// Get rank of a record by score and KeyPath (convenience method)
    ///
    /// This is a convenience wrapper that extracts the primary key from the record.
    ///
    /// - Parameters:
    ///   - score: Score value (must match index's scoreTypeName type)
    ///   - keyPath: KeyPath to the ranked field (for validation and grouping extraction)
    ///   - record: Record instance (to extract primary key)
    ///   - indexName: Optional index name (auto-detects if nil)
    /// - Returns: **1-based rank** (1 = best), or nil if not found
    /// - Throws: RecordLayerError if index not found, not ready, or score type mismatch
    public func rank(
        of score: any TupleElement,
        in keyPath: PartialKeyPath<Record>,
        for record: Record,
        indexName: String? = nil
    ) async throws -> Int? {
        return try await rankInternal(
            score: score,
            keyPath: keyPath,
            for: record,
            indexName: indexName
        )
    }

    /// Internal rank implementation (extracts grouping values and primary key from record)
    private func rankInternal(
        score: any TupleElement,
        keyPath: PartialKeyPath<Record>,
        for record: Record,
        indexName: String?
    ) async throws -> Int? {
        let fieldName = Record.fieldName(for: keyPath)

        // 1. Find RANK index for the field (check LAST field for grouped indexes)
        let applicableIndexes = schema.indexes(for: Record.recordName)

        let targetIndex: Index
        if let specifiedIndexName = indexName {
            guard let index = applicableIndexes.first(where: { $0.name == specifiedIndexName }) else {
                throw RecordLayerError.indexNotFound("RANK index '\(specifiedIndexName)' not found")
            }

            // ✅ BUG FIX #2: Validate that the specified index is actually a RANK index
            guard index.type == .rank else {
                throw RecordLayerError.invalidArgument(
                    "Index '\(specifiedIndexName)' is type '\(index.type)', not a RANK index. " +
                    "Use rankQuery() API for RANK indexes only."
                )
            }

            targetIndex = index
        } else {
            let indexes = applicableIndexes.filter { index in
                guard index.type == .rank else { return false }

                // Extract the ranked field (last field in expression)
                guard let rankedField = Self.extractRankedField(from: index.rootExpression) else {
                    return false
                }

                return rankedField == fieldName
            }

            guard let index = indexes.first else {
                throw RecordLayerError.indexNotFound("No RANK index found for field '\(fieldName)'")
            }
            targetIndex = index
        }

        // 2. Verify index is in readable state
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let state = try await indexStateManager.state(of: targetIndex.name, context: context)

        guard state == .readable else {
            throw RecordLayerError.indexNotReady("RANK index '\(targetIndex.name)' is in '\(state)' state")
        }

        // 3. Extract grouping values from record (if grouped index)
        // ✅ BUG FIX #4: Now throws if grouping fields contain unsupported expression types
        let groupingFieldNames = try Self.extractGroupingFields(from: targetIndex.rootExpression)
        let recordAccess = GenericRecordAccess<Record>()

        var groupingValues: [any TupleElement] = []
        for groupingFieldName in groupingFieldNames {
            let values = try recordAccess.extractField(from: record, fieldName: groupingFieldName)
            guard let firstValue = values.first else {
                throw RecordLayerError.invalidArgument("Grouping field '\(groupingFieldName)' not found in record")
            }
            groupingValues.append(firstValue)
        }

        // 4. Extract primary key from record
        let primaryKeyTuple = recordAccess.extractPrimaryKey(from: record)

        // 5. Delegate to dynamic rank helper for O(log n) rank calculation
        let indexNameSubspace = indexSubspace.subspace(targetIndex.name)
        return try await getRankDynamic(
            recordType: Record.self,
            index: targetIndex,
            subspace: indexNameSubspace,
            recordSubspace: recordSubspace,
            groupingValues: groupingValues,
            score: score,
            primaryKey: primaryKeyTuple,
            transaction: context.getTransaction()
        )
    }

    // MARK: - Scan

    /// Scan all records of this type
    ///
    /// Returns an async sequence that iterates over all records in the store.
    /// This is useful for:
    /// - GROUP BY operations
    /// - Data migration and transformation
    /// - Full table scans
    ///
    /// **Performance Considerations**:
    /// - Uses snapshot reads (no conflicts)
    /// - Streams results to avoid loading all records into memory
    /// - Respects FoundationDB transaction limits (5s timeout, 10MB size)
    ///
    /// **Example**:
    /// ```swift
    /// // Scan all users
    /// for try await user in store.scan() {
    ///     print(user.name)
    /// }
    ///
    /// // Count all records
    /// var count = 0
    /// for try await _ in store.scan() {
    ///     count += 1
    /// }
    /// ```
    ///
    /// - Returns: Async sequence of records
    public func scan() -> RecordScanSequence<Record> {
        return RecordScanSequence(
            database: database,
            recordSubspace: recordSubspace,
            recordName: Record.recordName
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

            // Execute query within a single transaction to avoid race conditions
            // Index state check and query execution use the same transaction snapshot
            let indexSubspace = self.indexSubspace.subspace(function.indexName)
            let result = try await database.withRecordContext { context in
                // Check index state within the same transaction as the query
                // This ensures consistency: if makeReadable() was called in the same transaction,
                // we will see the updated state
                let indexStateManager = IndexStateManager(database: database, subspace: subspace)
                let state = try await indexStateManager.state(of: function.indexName, context: context)

                guard state == .readable else {
                    throw RecordLayerError.indexNotReady(
                        "Cannot query index '\(function.indexName)' in '\(state)' state. " +
                        "Index must be in 'readable' state for aggregate queries. " +
                        "Current state: \(state)"
                    )
                }

                // Execute query in the same transaction
                let transaction = context.getTransaction()
                return try await function.evaluate(
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
        let indexSubspace = self.indexSubspace.subspace(function.indexName)

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

            // ✅ BUG FIX #6: Convert tuple to human-readable string instead of hex encoding
            // For single element: use the element directly
            // For multiple elements: join with comma separator
            let groupKeyString: String
            if unpacked.count == 1, let element = unpacked[0] {
                groupKeyString = "\(element)"
            } else {
                // Multi-element tuple: join with commas
                var elements: [String] = []
                for i in 0..<unpacked.count {
                    if let element = unpacked[i] {
                        elements.append("\(element)")
                    }
                }
                groupKeyString = elements.joined(separator: ",")
            }

            // Decode aggregate value
            let aggregateValue = TupleHelpers.bytesToInt64(value)

            results[groupKeyString] = aggregateValue as F.Result
        }

        return results
    }
}

// MARK: - Record Scan Sequence

/// Async sequence for scanning all records of a type
///
/// This sequence provides streaming access to all records in a RecordStore,
/// allowing efficient iteration without loading all records into memory.
///
/// **Features:**
/// - Lazy transaction creation on first `next()` call
/// - **Snapshot consistency**: All batches read from the same snapshot (readVersion)
/// - Snapshot reads to avoid transaction conflicts
/// - Resumable scans with lastKey tracking
/// - Automatic key deduplication with successor() function
///
/// **Implementation Details**:
/// - Uses snapshot reads to avoid transaction conflicts
/// - **Snapshot consistency across batches**: The first transaction's readVersion
///   is captured and reused for all subsequent transactions, ensuring GROUP BY
///   and other aggregations see a consistent snapshot even across 100+ record batches
/// - Streams results as they are read from FoundationDB
/// - Automatically handles record deserialization
/// - Respects FoundationDB's transaction limits (5s timeout, 10MB size)
/// - Supports batched processing with resumption
///
/// **Usage**:
/// ```swift
/// // Simple scan
/// let store = RecordStore<User>(...)
/// for try await user in store.scan() {
///     print(user.name)
/// }
///
/// // Batch scan with resumption
/// var lastKey: FDB.Bytes? = nil
/// var iterator = store.scan(resumeFrom: lastKey).makeAsyncIterator()
/// while let record = try await iterator.next() {
///     process(record)
///     lastKey = iterator.getLastKey()
/// }
/// ```
public struct RecordScanSequence<Record: Recordable>: AsyncSequence {
    public typealias Element = Record

    private let database: any DatabaseProtocol
    private let recordSubspace: Subspace
    private let recordName: String
    private let resumeFrom: FDB.Bytes?

    init(
        database: any DatabaseProtocol,
        recordSubspace: Subspace,
        recordName: String,
        resumeFrom: FDB.Bytes? = nil
    ) {
        self.database = database
        self.recordSubspace = recordSubspace
        self.recordName = recordName
        self.resumeFrom = resumeFrom
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            database: database,
            recordSubspace: recordSubspace,
            recordName: recordName,
            resumeFrom: resumeFrom
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = Record

        private let database: any DatabaseProtocol
        private let recordSubspace: Subspace
        private let recordName: String
        private let maxRecordsPerBatch: Int
        private var kvIterator: FDB.AsyncKVSequence.AsyncIterator?
        private var transaction: (any TransactionProtocol)?
        private let recordAccess: GenericRecordAccess<Record>
        private var lastKey: FDB.Bytes?
        private var recordsInCurrentBatch: Int

        // ✅ FIX: Store readVersion from first transaction for snapshot consistency
        private var snapshotReadVersion: Int64?

        init(
            database: any DatabaseProtocol,
            recordSubspace: Subspace,
            recordName: String,
            resumeFrom: FDB.Bytes? = nil,
            maxRecordsPerBatch: Int = 100
        ) {
            self.database = database
            self.recordSubspace = recordSubspace
            self.recordName = recordName
            self.maxRecordsPerBatch = maxRecordsPerBatch
            self.recordAccess = GenericRecordAccess<Record>()
            self.lastKey = resumeFrom
            self.recordsInCurrentBatch = 0
            self.snapshotReadVersion = nil
        }

        /// Get the next key after the given key
        ///
        /// This is critical for resuming range scans without duplicates.
        /// FDB range reads are inclusive on both ends, so using the same key
        /// as begin would re-read the last record.
        ///
        /// **Example:**
        /// ```
        /// "foo" -> "foo\x00" (next possible key)
        /// "bar\x01\x02" -> "bar\x01\x02\x00"
        /// ```
        ///
        /// - Parameter key: The current key
        /// - Returns: The lexicographically next key
        private func successor(of key: FDB.Bytes) -> FDB.Bytes {
            var nextKey = key
            // Append 0x00 byte to get the next possible key
            nextKey.append(0x00)
            return nextKey
        }

        public mutating func next() async throws -> Record? {
            // Create/recreate transaction if needed (for batching to respect 5s/10MB limits)
            if kvIterator == nil {
                // ✅ BUG FIX #7: Cancel previous transaction before creating new one
                if let oldTransaction = transaction {
                    oldTransaction.cancel()
                    self.transaction = nil
                }

                // Reset batch counter
                recordsInCurrentBatch = 0

                // Create new transaction
                let tx = try database.createTransaction()

                // ✅ FIX: Maintain snapshot consistency across batches
                // First transaction: capture readVersion for future batches
                // Subsequent transactions: reuse the same readVersion
                if snapshotReadVersion == nil {
                    // First batch: get and store readVersion
                    snapshotReadVersion = try await tx.getReadVersion()
                } else {
                    // Subsequent batches: use stored readVersion
                    tx.setReadVersion(snapshotReadVersion!)
                }

                self.transaction = tx

                // Build subspace for this record type
                let effectiveSubspace = recordSubspace.subspace(recordName)

                // Resume from successor of lastKey to avoid duplication
                let beginKey: FDB.Bytes
                if let last = lastKey {
                    beginKey = successor(of: last)
                } else {
                    beginKey = effectiveSubspace.range().begin
                }

                let endKey = effectiveSubspace.range().end

                // Create range scan with snapshot read
                let sequence = tx.getRange(
                    begin: beginKey,
                    end: endKey,
                    snapshot: true  // Snapshot read: no conflicts
                )

                self.kvIterator = sequence.makeAsyncIterator()
            }

            // Get next key-value pair
            guard let (key, value) = try await kvIterator?.next() else {
                // ✅ BUG FIX #7: Clean up transaction when scan completes
                if let tx = transaction {
                    tx.cancel()
                    self.transaction = nil
                }
                return nil
            }

            // Track last key for resumption
            self.lastKey = key

            // Increment batch counter
            recordsInCurrentBatch += 1

            // Check if we've reached batch limit - force transaction recreation on next call
            if recordsInCurrentBatch >= maxRecordsPerBatch {
                self.kvIterator = nil  // Force new transaction on next iteration
            }

            // Deserialize record
            return try recordAccess.deserialize(value)
        }

        /// Get the last key read by this iterator
        ///
        /// Useful for resuming scans from the last processed record.
        ///
        /// - Returns: The last key, or nil if no records have been read
        public func getLastKey() -> FDB.Bytes? {
            return lastKey
        }
    }
}

// MARK: - Helper Methods for RANK Index Detection

extension RecordStore {
    /// Extract the last (ranked) field from a RANK index expression
    ///
    /// For RANK indexes, the structure is:
    /// - **Simple**: `FieldKeyExpression("score")` → ranked field: "score"
    /// - **Grouped**: `ConcatenateKeyExpression([Field("gameID"), Field("score")])` → ranked field: "score"
    ///
    /// The last field in the expression is always the ranked value; preceding fields are grouping fields.
    ///
    /// - Parameter expression: Index root expression
    /// - Returns: Field name of the ranked value, or nil if not extractable
    private static func extractRankedField(from expression: any KeyExpression) -> String? {
        if let fieldExpr = expression as? FieldKeyExpression {
            // Simple RANK index: single field
            return fieldExpr.fieldName
        } else if let concatExpr = expression as? ConcatenateKeyExpression {
            // Grouped RANK index: last field is the ranked value
            if let lastField = concatExpr.children.last as? FieldKeyExpression {
                return lastField.fieldName
            }
        }
        return nil
    }

    /// Extract grouping fields from a RANK index expression
    ///
    /// For grouped RANK indexes like `[gameID, score]`, this returns `["gameID"]`.
    /// For simple RANK indexes, this returns an empty array.
    ///
    /// ✅ BUG FIX #4: Now throws error if any grouping field is not a FieldKeyExpression
    ///
    /// - Parameter expression: Index root expression
    /// - Returns: Array of grouping field names (empty for ungrouped indexes)
    /// - Throws: RecordLayerError.invalidArgument if grouping field is not a simple field expression
    private static func extractGroupingFields(from expression: any KeyExpression) throws -> [String] {
        if let concatExpr = expression as? ConcatenateKeyExpression {
            // All fields except the last are grouping fields
            let groupingChildren = concatExpr.children.dropLast()

            // ✅ BUG FIX #4: Use map instead of compactMap to fail loudly on unsupported types
            return try groupingChildren.map { child in
                guard let fieldExpr = child as? FieldKeyExpression else {
                    throw RecordLayerError.invalidArgument(
                        "RANK index grouping fields must be simple FieldKeyExpression, " +
                        "but found \(type(of: child)). " +
                        "Complex expressions (LiteralKeyExpression, NestExpression, etc.) are not supported for grouping."
                    )
                }
                return fieldExpr.fieldName
            }
        }
        return []
    }
}
