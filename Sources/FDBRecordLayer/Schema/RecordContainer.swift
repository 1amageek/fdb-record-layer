import Foundation
import FoundationDB
import Synchronization
import Logging

/// RecordContainer - Manages app's schema and model storage configuration
///
/// Corresponds to SwiftData's ModelContainer:
/// - Schema and database integration
/// - RecordStore creation
/// - Migration execution (future)
/// - StatisticsManager management
///
/// **Example usage**:
/// ```swift
/// let container = try RecordContainer(
///     for: schema,
///     configurations: DatabaseConfiguration(apiVersion: 630)
/// )
///
/// let userStore = container.store(for: User.self, path: "users")
/// ```
public final class RecordContainer: Sendable {

    // MARK: - Properties

    /// Schema
    public let schema: Schema

    /// Configurations
    public let configurations: [RecordConfiguration]

    /// Migration plan (future implementation)
    public let migrationPlan: (any SchemaMigrationPlan.Type)?

    /// Internal: Database connection
    private nonisolated(unsafe) let database: any DatabaseProtocol

    /// Internal: StatisticsManager (optional)
    private let statisticsManager: (any StatisticsManagerProtocol)?

    /// Internal: MetricsRecorder (default: NullMetricsRecorder)
    private let metricsRecorder: any MetricsRecorder

    /// Internal: Logger (optional)
    private let logger: Logger?

    /// Internal: RecordStore cache key
    private struct StoreCacheKey: Hashable {
        let subspace: Subspace
        let typeName: String
    }

    /// Internal: RecordStore cache
    /// Key: StoreCacheKey (type-safe)
    /// Value: RecordStore<Record> (type-erased)
    private let storeCache: Mutex<[StoreCacheKey: Any]>

    // MARK: - Initialization

    /// Create RecordContainer (SwiftData-compatible)
    ///
    /// - Parameters:
    ///   - configurations: Record configurations (uses first configuration's settings)
    ///   - migrationPlan: Migration plan (optional)
    ///
    /// **Example usage**:
    /// ```swift
    /// let schema = Schema([User.self, Order.self])
    /// let config = RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
    /// let container = try RecordContainer(configurations: [config])
    /// ```
    public init(
        configurations: [RecordConfiguration],
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) throws {
        guard let firstConfig = configurations.first else {
            throw RecordLayerError.internalError("At least one configuration is required")
        }

        // Use first configuration's schema
        // Note: Multiple configurations are for different storage backends (e.g., in-memory + persistent)
        // not for merging schemas
        self.schema = firstConfig.schema

        self.configurations = configurations
        self.migrationPlan = migrationPlan

        // Use first configuration's settings
        self.metricsRecorder = firstConfig.metricsRecorder ?? NullMetricsRecorder()
        self.logger = firstConfig.logger

        // Note: API version selection must be done globally before creating RecordContainer
        // If apiVersion is specified in configuration, it's for documentation purposes only
        // The actual API version selection should be done via FDBClient at application startup
        if let apiVersion = firstConfig.apiVersion {
            // Log warning if apiVersion is specified (it should be selected globally before)
            let logger = Logger(label: "com.fdb.recordlayer.container")
            logger.warning("API version \(apiVersion) specified in configuration, but API version must be selected globally before RecordContainer initialization. This value is ignored.")
        }

        // Create FDB connection
        self.database = try FDBClient.openDatabase(clusterFilePath: firstConfig.clusterFilePath)

        // Create StatisticsManager (optional)
        if let statsSubspace = firstConfig.statisticsSubspace {
            self.statisticsManager = StatisticsManager(
                database: database,
                subspace: statsSubspace
            )
        } else {
            self.statisticsManager = nil
        }

        // Initialize cache
        self.storeCache = Mutex([:])

        // Execute migrations (future implementation)
        if migrationPlan != nil {
            // try await runMigrations(plan: migrationPlan)
        }
    }

    /// Convenience initializer - SwiftData style (single schema with varargs)
    ///
    /// **Example usage**:
    /// ```swift
    /// let config = RecordConfiguration(for: User.self, Order.self)
    /// let container = try RecordContainer(configurations: [config])
    ///
    /// // Or even simpler:
    /// let container = try RecordContainer(for: User.self, Order.self)
    /// ```
    public convenience init(
        for types: any Recordable.Type...,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        clusterFilePath: String? = nil,
        isStoredInMemoryOnly: Bool = false
    ) throws {
        // Convert varargs to array
        let schema = Schema(types)
        let config = RecordConfiguration(
            schema: schema,
            clusterFilePath: clusterFilePath,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        try self.init(
            configurations: [config],
            migrationPlan: migrationPlan
        )
    }

    // MARK: - RecordStore Access

    /// Get RecordStore with path specification
    ///
    /// - Parameters:
    ///   - type: Recordable type
    ///   - path: Firestore-style path (e.g., "accounts/acct-001/users")
    ///
    /// **Example usage**:
    /// ```swift
    /// let userStore = container.store(for: User.self, path: "accounts/acct-001/users")
    /// try await userStore.save(user)
    /// ```
    ///
    /// **Performance**: RecordStores are cached and reused for the same path and type.
    public func store<Record: Recordable>(
        for type: Record.Type,
        path: String
    ) -> RecordStore<Record> {
        let subspace = Subspace(path: path)
        let cacheKey = StoreCacheKey(subspace: subspace, typeName: Record.recordName)

        // Check cache (fast path)
        if let cached = storeCache.withLock({ $0[cacheKey] as? RecordStore<Record> }) {
            return cached
        }

        // Create new RecordStore (slow path)
        let store = RecordStore<Record>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: statisticsManager ?? NullStatisticsManager(),
            metricsRecorder: metricsRecorder,
            logger: logger
        )

        // Cache the store
        storeCache.withLock { $0[cacheKey] = store }

        return store
    }

    /// Get RecordStore with Subspace specification
    ///
    /// - Parameters:
    ///   - type: Recordable type
    ///   - subspace: Subspace
    public func store<Record: Recordable>(
        for type: Record.Type,
        subspace: Subspace
    ) -> RecordStore<Record> {
        let cacheKey = StoreCacheKey(subspace: subspace, typeName: Record.recordName)

        // Check cache
        if let cached = storeCache.withLock({ $0[cacheKey] as? RecordStore<Record> }) {
            return cached
        }

        // Create new RecordStore
        let store = RecordStore<Record>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: statisticsManager ?? NullStatisticsManager(),
            metricsRecorder: metricsRecorder,
            logger: logger
        )

        // Cache the store
        storeCache.withLock { $0[cacheKey] = store }

        return store
    }

    // MARK: - Container Management

    /// Delete all data (SwiftData compatible)
    ///
    /// Removes all persisted model data from persistent storage.
    public func deleteAllData() async throws {
        // Delete data for all entities
        for _ in schema.entities {
            // Future implementation: Clear data for each entity
        }
    }

    /// Erase container (SwiftData compatible)
    ///
    /// Completely erases the database.
    public func erase() throws {
        // Future implementation: Clear entire database
        throw RecordLayerError.internalError("RecordContainer.erase() is not implemented yet")
    }

    /// Clear RecordStore cache
    ///
    /// Use this to reduce memory usage or during testing.
    public func clearCache() {
        storeCache.withLock { $0.removeAll() }
    }

    /// Get cache size
    ///
    /// - Returns: Number of cached RecordStores
    public func cacheSize() -> Int {
        return storeCache.withLock { $0.count }
    }

    // MARK: - Transaction Support

    /// Execute a block within a single atomic transaction
    ///
    /// All operations within the block are executed in a single FDB transaction,
    /// ensuring all-or-nothing semantics.
    ///
    /// **Example**:
    /// ```swift
    /// try await container.withTransaction { context in
    ///     let userStore = container.store(for: User.self, path: "users")
    ///     try await userStore.saveInternal(user1, context: context)
    ///     try await userStore.saveInternal(user2, context: context)
    ///     // Both saves commit together
    /// }
    /// ```
    ///
    /// - Parameter block: Transaction block to execute
    /// - Returns: Result of the block
    /// - Throws: RecordLayerError if transaction fails
    public func withTransaction<T>(
        _ block: (RecordContext) async throws -> T
    ) async throws -> T {
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let result = try await block(context)
        try await context.commit()

        return result
    }
}

// MARK: - CustomDebugStringConvertible

extension RecordContainer: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "RecordContainer(schema: \(schema), configurations: \(configurations.count), cacheSize: \(cacheSize()))"
    }
}
