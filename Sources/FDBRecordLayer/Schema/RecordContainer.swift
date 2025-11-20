import Foundation
import FoundationDB
import FDBRecordCore
import Synchronization
import Logging

/// RecordContainer - Manages app's schema and model storage configuration
///
/// Corresponds to SwiftData's ModelContainer:
/// - Schema and database integration
/// - RecordStore creation
/// - Migration execution (future)
/// - StatisticsManager management
/// - **DirectoryLayer singleton management** (create once, reuse)
///
/// **DirectoryLayer Management**:
///
/// RecordContainerは初期化時にDirectoryLayerインスタンスを作成し、
/// すべてのディレクトリ操作で再利用します。これにより、内部キャッシュが
/// 効率的に機能し、パフォーマンスが向上します。
///
/// ```swift
/// // RecordContainerが内部でDirectoryLayerを管理
/// let container = try RecordContainer(
///     configurations: [config]
/// )
///
/// // すべてのディレクトリ操作で同じDirectoryLayerインスタンスを再利用
/// let subspace1 = try await container.getOrOpenDirectory(for: User.self, with: user1)
/// let subspace2 = try await container.getOrOpenDirectory(for: User.self, with: user2)
/// ```
///
/// **Test Isolation**:
///
/// テストでは`directoryLayer`パラメータでカスタムDirectoryLayerを注入できます：
///
/// ```swift
/// let testSubspace = Subspace(prefix: Tuple("test", UUID().uuidString).pack())
/// let testDirectoryLayer = DirectoryLayer(
///     database: database,
///     nodeSubspace: testSubspace.subspace(0xFE),
///     contentSubspace: testSubspace
/// )
///
/// let container = try RecordContainer(
///     configurations: [config],
///     directoryLayer: testDirectoryLayer  // カスタムレイヤー注入
/// )
/// ```
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

    /// Internal: DirectoryLayer instance (created once, reused for all operations)
    private let directoryLayer: DirectoryLayer

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

    /// Internal: Directory cache for resolved directories
    /// Key: Directory path + layer type (e.g., "tenants/acct-001/users::partition")
    /// Value: Resolved Subspace from DirectoryLayer
    private let directoryCache: Mutex<[String: Subspace]>

    /// Convert DirectoryLayerType to DirectoryType (matches macro-generated code)
    private func convertLayerType(_ layerType: DirectoryLayerType) -> DirectoryType? {
        switch layerType {
        case .partition:
            return .partition
        case .recordStore:
            return .custom("fdb_record_layer")
        case .luceneIndex:
            return .custom("lucene_index")
        case .timeSeries:
            return .custom("time_series")
        case .vectorIndex:
            return .custom("vector_index")
        case .custom(let name):
            return .custom(name)
        }
    }

    // MARK: - Context

    /// Main context for managing records (SwiftData-compatible)
    ///
    /// Use this context for CRUD operations with automatic change tracking.
    ///
    /// **Example usage**:
    /// ```swift
    /// let context = await container.mainContext
    /// context.insert(user)
    /// context.insert(product)
    /// try await context.save()  // Atomic save
    /// ```
    @MainActor
    public var mainContext: RecordContext {
        get {
            return _mainContextLock.withLock { cached in
                if let existing = cached {
                    return existing
                }
                let newContext = RecordContext(container: self)
                cached = newContext
                return newContext
            }
        }
    }

    private let _mainContextLock: Mutex<RecordContext?> = Mutex(nil)

    // MARK: - Initialization

    /// Create RecordContainer (SwiftData-compatible)
    ///
    /// - Parameters:
    ///   - configurations: Record configurations (uses first configuration's settings)
    ///   - migrationPlan: Migration plan (optional)
    ///   - directoryLayer: Custom DirectoryLayer for test isolation (optional)
    ///
    /// **DirectoryLayer Parameter**:
    ///
    /// `directoryLayer`パラメータはテストアイソレーション用です。
    /// - `nil` (デフォルト): `database.makeDirectoryLayer()`でデフォルトDirectoryLayerを作成
    /// - 非nil: カスタムDirectoryLayerを使用（テスト用の独立したサブスペース）
    ///
    /// ```swift
    /// // 本番環境: デフォルトDirectoryLayer
    /// let container = try RecordContainer(configurations: [config])
    ///
    /// // テスト環境: 独立したサブスペース
    /// let testSubspace = Subspace(prefix: Tuple("test", UUID().uuidString).pack())
    /// let testDirectoryLayer = DirectoryLayer(
    ///     database: database,
    ///     nodeSubspace: testSubspace.subspace(0xFE),
    ///     contentSubspace: testSubspace
    /// )
    /// let container = try RecordContainer(
    ///     configurations: [config],
    ///     directoryLayer: testDirectoryLayer
    /// )
    /// ```
    ///
    /// **Example usage**:
    /// ```swift
    /// let schema = Schema([User.self, Order.self])
    /// let config = RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
    /// let container = try RecordContainer(configurations: [config])
    /// ```
    public init(
        configurations: [RecordConfiguration],
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        directoryLayer: DirectoryLayer? = nil
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

        // Initialize DirectoryLayer (singleton pattern - create once, reuse for all operations)
        // This improves performance by allowing internal caching to work efficiently.
        // For tests, a custom DirectoryLayer can be injected for isolation.
        if let customLayer = directoryLayer {
            // Test mode: use custom DirectoryLayer with isolated subspace
            self.directoryLayer = customLayer
        } else {
            // Production mode: use default DirectoryLayer (nodeSubspace: 0xFE)
            self.directoryLayer = database.makeDirectoryLayer()
        }

        // Create StatisticsManager (optional)
        if let statsSubspace = firstConfig.statisticsSubspace {
            self.statisticsManager = StatisticsManager(
                database: database,
                subspace: statsSubspace
            )
        } else {
            self.statisticsManager = nil
        }

        // Initialize caches
        self.storeCache = Mutex([:])
        self.directoryCache = Mutex([:])

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

    /// Build static directory path (for queries without Field values)
    ///
    /// This method is used by fetch() which doesn't have a record instance.
    /// If the directory contains Field components, this method will throw an error.
    ///
    /// - Parameter type: Recordable type
    /// - Returns: Resolved Subspace
    /// - Throws: RecordLayerError if Field components are present
    internal func buildStaticDirectory<Record: Recordable>(for type: Record.Type) async throws -> Subspace {
        let components = Record.directoryPathComponents
        let layerType = Record.directoryLayerType

        // If no directory components, use record name as default
        guard !components.isEmpty else {
            return Subspace(path: Record.recordName)
        }

        // Build directory path from Path components only
        var pathStrings: [String] = []
        for component in components {
            if let path = component as? Path {
                pathStrings.append(path.value)
            } else if component is Field<Record> {
                // Field components require a record instance
                throw RecordLayerError.internalError(
                    "Cannot use fetch() for record types with Field components in #Directory. " +
                    "Field values are required for directory resolution."
                )
            }
        }

        // Append layer-specific suffix to make path unique
        // FoundationDB DirectoryLayer does not allow same path with different layer types
        if layerType != .partition {
            switch layerType {
            case .recordStore:
                pathStrings.append("_recordStore")
            case .luceneIndex:
                pathStrings.append("_lucene")
            case .timeSeries:
                pathStrings.append("_timeSeries")
            case .vectorIndex:
                pathStrings.append("_vector")
            case .custom(let name):
                pathStrings.append("_\(name)")
            case .partition:
                break
            }
        }

        // Cache key includes both path and layer type
        let pathKey = pathStrings.joined(separator: "/") + "::" + layerType.rawValue

        // Check directory cache
        if let cached = directoryCache.withLock({ $0[pathKey] }) {
            return cached
        }

        // Convert DirectoryLayerType to DirectoryType (matches macro-generated code)
        let directoryType = convertLayerType(layerType)

        // Open directory using DirectoryLayer
        let directoryLayer = DirectoryLayer(database: database)
        let directorySubspace = try await directoryLayer.createOrOpen(
            path: pathStrings,
            type: directoryType
        )

        let subspace = directorySubspace.subspace

        // Cache the resolved subspace
        directoryCache.withLock { $0[pathKey] = subspace }

        return subspace
    }

    /// Get or open directory for a record instance using #Directory macro metadata
    ///
    /// This method resolves the storage directory for a record instance based on:
    /// - `directoryPathComponents`: Path and Field components from #Directory macro
    /// - `directoryLayerType`: Layer type (.partition, .recordStore, etc.)
    ///
    /// Field values are extracted from the record instance using KeyPath subscript.
    /// The resolved directory is cached for performance.
    ///
    /// - Parameters:
    ///   - type: Recordable type
    ///   - record: Record instance (for extracting Field values)
    /// - Returns: Resolved Subspace from DirectoryLayer
    public func getOrOpenDirectory<Record: Recordable>(
        for type: Record.Type,
        with record: Record
    ) async throws -> Subspace {
        let components = Record.directoryPathComponents
        let layerType = Record.directoryLayerType

        // If no directory components, use record name as default (no DirectoryLayer)
        guard !components.isEmpty else {
            return Subspace(path: Record.recordName)
        }

        // Build directory path from components
        var pathStrings: [String] = []
        for component in components {
            if let path = component as? Path {
                pathStrings.append(path.value)
            } else if let field = component as? Field<Record> {
                // Extract field value using KeyPath subscript
                let value = record[keyPath: field.value]
                pathStrings.append(String(describing: value))
            }
        }

        // Append layer-specific suffix to make path unique
        // FoundationDB DirectoryLayer does not allow same path with different layer types
        if layerType != .partition {
            switch layerType {
            case .recordStore:
                pathStrings.append("_recordStore")
            case .luceneIndex:
                pathStrings.append("_lucene")
            case .timeSeries:
                pathStrings.append("_timeSeries")
            case .vectorIndex:
                pathStrings.append("_vector")
            case .custom(let name):
                pathStrings.append("_\(name)")
            case .partition:
                break
            }
        }

        // Cache key includes both path and layer type
        let pathKey = pathStrings.joined(separator: "/") + "::" + layerType.rawValue

        // Check directory cache
        if let cached = directoryCache.withLock({ $0[pathKey] }) {
            return cached
        }

        // Convert DirectoryLayerType to DirectoryType (matches macro-generated code)
        let directoryType = convertLayerType(layerType)

        // Open directory using DirectoryLayer (reuse shared instance)
        let directorySubspace = try await self.directoryLayer.createOrOpen(
            path: pathStrings,
            type: directoryType
        )

        let subspace = directorySubspace.subspace

        // Cache the resolved subspace
        directoryCache.withLock { $0[pathKey] = subspace }

        return subspace
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

    /// Get directory cache size
    ///
    /// - Returns: Number of cached directories
    public func directoryCacheSize() -> Int {
        return directoryCache.withLock { $0.count }
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
    internal func withTransaction<T>(
        _ block: (TransactionContext) async throws -> T
    ) async throws -> T {
        let transaction = try database.createTransaction()
        let context = TransactionContext(transaction: transaction)
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
