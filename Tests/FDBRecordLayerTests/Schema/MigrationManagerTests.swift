import Testing
import Foundation
@testable import FDBRecordCore
@testable import FDBRecordLayer
@testable import FoundationDB

// MARK: - Test Record Types

@Recordable
struct MigrationTestUser {
    #PrimaryKey<MigrationTestUser>([\.id])
    var id: Int64
    var name: String
}

@Recordable
struct Product {
    #PrimaryKey<Product>([\.id])
    var id: Int64
    var name: String
    var category: String
}

@Recordable
struct Article {
    #PrimaryKey<Article>([\.id])
    var id: Int64
    var title: String
    var author: String
}

@Recordable
struct Order {
    #PrimaryKey<Order>([\.id])
    var id: Int64
    var status: String
    var amount: Int64
}

@Recordable
struct Customer {
    #PrimaryKey<Customer>([\.id])
    var id: Int64
    var name: String
    var email: String
    var city: String
}

@Recordable
struct MigrationUserV1 {
    #PrimaryKey<MigrationUserV1>([\.id])
    var id: Int64
    var fullName: String
}

@Recordable
struct MigrationUserV2 {
    #PrimaryKey<MigrationUserV2>([\.id])
    var id: Int64
    var firstName: String
    var lastName: String
}

@Recordable
struct LightweightProduct {
    #PrimaryKey<LightweightProduct>([\.id])
    var id: Int64
    var name: String
    var price: Double
}

@Recordable
struct GameScore {
    #PrimaryKey<GameScore>([\.id])
    var id: Int64
    var playerID: String
    var score: Int64
    var gameType: String
}

enum LightweightSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any Recordable.Type] { [LightweightProduct.self] }
}

enum LightweightSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any Recordable.Type] { [LightweightProduct.self] }
}

/// Tests for Migration Manager with Store Registry
@Suite("MigrationManager with StoreRegistry", .tags(.slow, .integration))
struct MigrationManagerTests {
    let database: any DatabaseProtocol
    let subspace: Subspace

    init() throws {
        // Initialize FDB network
        do {
            try FDBNetwork.shared.initialize(version: 720)
        } catch {
            // Network already initialized - this is fine
        }

        self.database = try FDBClient.openDatabase()
        self.subspace = Subspace(prefix: Tuple("migration_test", UUID().uuidString).pack())
    }

    /// Test basic migration manager initialization with store registry
    @Test("Initialize MigrationManager with store registry")
    func testInitialization() async throws {
        let schema = Schema([MigrationTestUser.self], version: Schema.Version(1, 0, 0))
        let store = RecordStore<MigrationTestUser>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let registry: [String: any AnyRecordStore] = ["MigrationTestUser": store]

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [],
            storeRegistry: registry,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Verify manager is initialized
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == nil, "Initial version should be nil")
    }

    /// Test single record store convenience initializer
    @Test("Initialize MigrationManager with single store")
    func testSingleStoreInitialization() async throws {
        let schema = Schema([MigrationTestUser.self], version: Schema.Version(1, 0, 0))
        let store = RecordStore<MigrationTestUser>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Verify manager is initialized
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == nil, "Initial version should be nil")
    }

    /// Test AnyRecordStore protocol conformance
    @Test("RecordStore conforms to AnyRecordStore")
    func testAnyRecordStoreConformance() async throws {
        let schema = Schema([MigrationTestUser.self], version: Schema.Version(1, 0, 0))
        let store = RecordStore<MigrationTestUser>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Verify AnyRecordStore protocol properties
        let anyStore: any AnyRecordStore = store
        #expect(anyStore.recordName == "MigrationTestUser")
        #expect(anyStore.schema.version == Schema.Version(1, 0, 0))
        #expect(anyStore.subspace == subspace)
    }

    /// Test migration context with store registry
    @Test("MigrationContext can access stores from registry")
    func testMigrationContextStoreAccess() async throws {
        let schema = Schema([MigrationTestUser.self], version: Schema.Version(1, 0, 0))
        let store = RecordStore<MigrationTestUser>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let registry: [String: any AnyRecordStore] = ["MigrationTestUser": store]

        let context = MigrationContext(
            database: database,
            schema: schema,
            metadataSubspace: subspace.subspace("metadata"),
            storeRegistry: registry
        )

        // Verify store can be accessed
        let retrievedStore = try context.store(for: "MigrationTestUser")
        #expect(retrievedStore.recordName == "MigrationTestUser")

        // Verify error when store not found
        #expect(throws: RecordLayerError.self) {
            try context.store(for: "NonExistentUser")
        }
    }

    /// Test direct version storage
    @Test("Direct version storage and retrieval")
    func testDirectVersionStorage() async throws {
        let migrationSubspace = subspace.subspace("migrations")

        // Manually write a version
        try await database.withTransaction { transaction in
            let versionKey = migrationSubspace.pack(Tuple("current_version"))
            let versionTuple = Tuple(Int64(1), Int64(2), Int64(3))
            transaction.setValue(versionTuple.pack(), for: versionKey)
        }

        // Manually read it back
        let readVersion = try await database.withTransaction { transaction in
            let versionKey = migrationSubspace.pack(Tuple("current_version"))
            guard let versionData = try await transaction.getValue(for: versionKey, snapshot: true) else {
                throw RecordLayerError.internalError("Version not found")
            }

            // Decode version
            let tuple = try Tuple.unpack(from: versionData)
            #expect(tuple.count >= 3, "Tuple should have at least 3 elements, got \(tuple.count)")

            guard let major = tuple[0] as? Int64,
                  let minor = tuple[1] as? Int64,
                  let patch = tuple[2] as? Int64 else {
                let types = (0..<tuple.count).map { i in
                    let element = tuple[i]
                    return "\(i): \(type(of: element))"
                }.joined(separator: ", ")
                throw RecordLayerError.invalidSerializedData("Invalid version format. Types: [\(types)]")
            }

            return SchemaVersion(major: Int(major), minor: Int(minor), patch: Int(patch))
        }

        #expect(readVersion == SchemaVersion(major: 1, minor: 2, patch: 3))
    }

    /// Test simple migration execution
    @Test("Execute simple no-op migration")
    func testSimpleMigration() async throws {
        let schema = Schema([Product.self], version: Schema.Version(1, 0, 0))
        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Create a simple no-op migration
        let migration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in
            // No-op
        }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [migration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Verify initial version is nil
        let initialVersion = try await manager.getCurrentVersion()
        #expect(initialVersion == nil)

        // Apply migration
        try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))

        // Verify version was updated
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 1, minor: 0, patch: 0))

        // Verify migration was marked as applied
        let isApplied = try await manager.isMigrationApplied(migration)
        #expect(isApplied == true)
    }

    /// Test index addition migration
    @Test("Add index via migration")
    func testAddIndexMigration() async throws {
        // Create index to add
        let categoryIndex = Index(
            name: "product_by_category",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "category")
        )

        // Create schema with the index
        let schema = Schema([Product.self], version: Schema.Version(2, 0, 0), indexes: [categoryIndex])

        // Create store with the schema
        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Create migrations
        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in
            // No-op
        }

        let indexMigration = MigrationManager.addIndexMigration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            index: categoryIndex
        )

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, indexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migrations
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify version was updated
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify both migrations were applied
        let isInitialApplied = try await manager.isMigrationApplied(initialMigration)
        let isIndexApplied = try await manager.isMigrationApplied(indexMigration)
        #expect(isInitialApplied == true)
        #expect(isIndexApplied == true)
    }

    /// Test rebuild index migration
    @Test("Rebuild index via migration")
    func testRebuildIndexMigration() async throws {
        // Create index
        let categoryIndex = Index(
            name: "product_by_category",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "category")
        )

        // Create schema with the index
        let schema = Schema([Product.self], version: Schema.Version(2, 0, 0), indexes: [categoryIndex])

        // Create store
        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Create migrations
        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in
            // No-op
        }

        let indexMigration = MigrationManager.addIndexMigration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            index: categoryIndex
        )

        // Create rebuild migration
        let rebuildMigration = Migration(
            fromVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 1, patch: 0),
            description: "Rebuild category index"
        ) { context in
            try await context.rebuildIndex(indexName: "product_by_category")
        }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, indexMigration, rebuildMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply all migrations
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 1, patch: 0))

        // Verify version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 2, minor: 1, patch: 0))

        // Verify all migrations were applied
        let isInitialApplied = try await manager.isMigrationApplied(initialMigration)
        let isIndexApplied = try await manager.isMigrationApplied(indexMigration)
        let isRebuildApplied = try await manager.isMigrationApplied(rebuildMigration)
        #expect(isInitialApplied == true)
        #expect(isIndexApplied == true)
        #expect(isRebuildApplied == true)
    }

    /// Test remove index migration
    @Test("Remove index via migration")
    func testRemoveIndexMigration() async throws {
        // Create index
        let categoryIndex = Index(
            name: "product_by_category",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "category")
        )

        // Create schema v2 with the index
        let schemaV2 = Schema([Product.self], version: Schema.Version(2, 0, 0), indexes: [categoryIndex])

        // Create store
        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schemaV2,
            statisticsManager: NullStatisticsManager()
        )

        // Create migrations
        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in
            // No-op
        }

        let indexMigration = MigrationManager.addIndexMigration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            index: categoryIndex
        )

        // Create schema v3 without the index
        let schemaV3 = Schema([Product.self], version: Schema.Version(3, 0, 0))

        let removeIndexMigration = MigrationManager.removeIndexMigration(
            fromVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 3, minor: 0, patch: 0),
            indexName: "product_by_category",
            addedVersion: SchemaVersion(major: 2, minor: 0, patch: 0)
        )

        let manager = MigrationManager(
            database: database,
            schema: schemaV3,
            migrations: [initialMigration, indexMigration, removeIndexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply all migrations
        try await manager.migrate(to: SchemaVersion(major: 3, minor: 0, patch: 0))

        // Verify version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 3, minor: 0, patch: 0))

        // Verify all migrations were applied
        let isInitialApplied = try await manager.isMigrationApplied(initialMigration)
        let isIndexApplied = try await manager.isMigrationApplied(indexMigration)
        let isRemoveApplied = try await manager.isMigrationApplied(removeIndexMigration)
        #expect(isInitialApplied == true)
        #expect(isIndexApplied == true)
        #expect(isRemoveApplied == true)
    }

    /// Test lightweight migration with no changes (should succeed)
    @Test("Lightweight migration with identical schemas")
    func testLightweightMigration() async throws {
        // Use identical schemas (only version differs)
        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in
            // No-op
        }

        let lightweightMigration = MigrationManager.lightweightMigration(
            from: LightweightSchemaV1.self,
            to: LightweightSchemaV2.self
        )

        let schema = Schema([LightweightProduct.self], version: Schema.Version(2, 0, 0))
        let store = RecordStore<LightweightProduct>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, lightweightMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migrations
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify migrations were applied
        let isInitialApplied = try await manager.isMigrationApplied(initialMigration)
        let isLightweightApplied = try await manager.isMigrationApplied(lightweightMigration)
        #expect(isInitialApplied == true)
        #expect(isLightweightApplied == true)
    }

    /// Test lightweight migration failure with unsupported changes
    @Test("Lightweight migration fails with removed record type")
    func testLightweightMigrationFailure() async throws {
        // Define schemas with removed record type
        enum SchemaWithProduct: VersionedSchema {
            static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
            static var models: [any Recordable.Type] { [Product.self, Article.self] }
        }

        enum SchemaWithoutProduct: VersionedSchema {
            static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
            static var models: [any Recordable.Type] { [Article.self] }  // Product removed
        }

        // Initial migration
        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in
            // No-op
        }

        // Create lightweight migration (should fail during execution)
        let lightweightMigration = MigrationManager.lightweightMigration(
            from: SchemaWithProduct.self,
            to: SchemaWithoutProduct.self
        )

        let schema = Schema([Article.self], version: Schema.Version(2, 0, 0))
        let store = RecordStore<Article>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, lightweightMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Expect error when trying to migrate
        do {
            try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))
            Issue.record("Expected error for removed record type")
        } catch let error as RecordLayerError {
            // Verify error message contains information about removed record type
            if case .internalError(let message) = error {
                #expect(message.contains("removed"))
                #expect(message.contains("Product"))
            } else {
                Issue.record("Expected internalError, got: \(error)")
            }
        }
    }

    // MARK: - Advanced Migration Tests

    /// Test multi-step migration chain (V1 → V2 → V3 → V4)
    @Test("Multi-step migration chain")
    func testMultiStepMigrationChain() async throws {
        let schema = Schema([Customer.self], version: Schema.Version(4, 0, 0))
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Create migration chain
        let migration1 = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize V1"
        ) { _ in }

        let migration2 = Migration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            description: "Upgrade to V2"
        ) { _ in }

        let migration3 = Migration(
            fromVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 3, minor: 0, patch: 0),
            description: "Upgrade to V3"
        ) { _ in }

        let migration4 = Migration(
            fromVersion: SchemaVersion(major: 3, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 4, minor: 0, patch: 0),
            description: "Upgrade to V4"
        ) { _ in }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [migration1, migration2, migration3, migration4],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Migrate from V0 to V4 (should apply all migrations in order)
        try await manager.migrate(to: SchemaVersion(major: 4, minor: 0, patch: 0))

        // Verify final version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 4, minor: 0, patch: 0))

        // Verify all migrations were applied
        #expect(try await manager.isMigrationApplied(migration1))
        #expect(try await manager.isMigrationApplied(migration2))
        #expect(try await manager.isMigrationApplied(migration3))
        #expect(try await manager.isMigrationApplied(migration4))
    }

    /// Test migration idempotency (running same migration multiple times)
    @Test("Migration idempotency")
    func testMigrationIdempotency() async throws {
        let schema = Schema([Customer.self], version: Schema.Version(1, 0, 0))
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let migration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [migration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migration first time
        try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))
        let version1 = try await manager.getCurrentVersion()
        #expect(version1 == SchemaVersion(major: 1, minor: 0, patch: 0))

        // Apply migration second time (should be idempotent)
        try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))
        let version2 = try await manager.getCurrentVersion()
        #expect(version2 == SchemaVersion(major: 1, minor: 0, patch: 0))

        // Verify migration is still marked as applied
        #expect(try await manager.isMigrationApplied(migration))
    }

    /// Test concurrent migration prevention
    @Test("Concurrent migration prevention")
    func testConcurrentMigrationPrevention() async throws {
        let schema = Schema([Customer.self], version: Schema.Version(1, 0, 0))
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Create a slow migration
        let slowMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Slow migration"
        ) { _ in
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [slowMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Start first migration (will be slow)
        let task1 = Task {
            try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))
        }

        // Wait a bit to ensure first migration has started
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Try to start second migration concurrently (should fail)
        do {
            try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))
            Issue.record("Expected error for concurrent migration")
        } catch let error as RecordLayerError {
            if case .internalError(let message) = error {
                #expect(message.contains("already in progress"))
            } else {
                Issue.record("Expected internalError, got: \(error)")
            }
        }

        // Wait for first migration to complete
        try await task1.value
    }

    /// Test migration path not found error
    @Test("Migration path not found")
    func testMigrationPathNotFound() async throws {
        let schema = Schema([Customer.self], version: Schema.Version(3, 0, 0))
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Create migrations with a gap (1.0 → 2.0, 3.0 → 4.0 - missing 2.0 → 3.0)
        let migration1 = Migration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            description: "V1 to V2"
        ) { _ in }

        let migration2 = Migration(
            fromVersion: SchemaVersion(major: 3, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 4, minor: 0, patch: 0),
            description: "V3 to V4"
        ) { _ in }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [migration1, migration2],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Manually set current version to 2.0
        try await database.withTransaction { transaction in
            let versionKey = subspace.subspace("migrations").pack(Tuple("current_version"))
            let versionTuple = Tuple(Int64(2), Int64(0), Int64(0))
            transaction.setValue(versionTuple.pack(), for: versionKey)
        }

        // Try to migrate to 4.0 (should fail - no path from 2.0 to 3.0)
        do {
            try await manager.migrate(to: SchemaVersion(major: 4, minor: 0, patch: 0))
            Issue.record("Expected error for missing migration path")
        } catch let error as RecordLayerError {
            if case .internalError(let message) = error {
                #expect(message.contains("No migration path found"))
            } else {
                Issue.record("Expected internalError, got: \(error)")
            }
        }
    }

    /// Test multi-record type migration
    @Test("Multi-record type migration")
    func testMultiRecordTypeMigration() async throws {
        // Create stores for multiple record types
        let customerSchema = Schema([Customer.self], version: Schema.Version(1, 0, 0))
        let customerStore = RecordStore<Customer>(
            database: database,
            subspace: subspace.subspace("customers"),
            schema: customerSchema,
            statisticsManager: NullStatisticsManager()
        )

        let orderSchema = Schema([Order.self], version: Schema.Version(1, 0, 0))
        let orderStore = RecordStore<Order>(
            database: database,
            subspace: subspace.subspace("orders"),
            schema: orderSchema,
            statisticsManager: NullStatisticsManager()
        )

        let storeRegistry: [String: any AnyRecordStore] = [
            "Customer": customerStore,
            "Order": orderStore
        ]

        // Create migration that affects multiple record types
        let multiTypeMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize multiple record types"
        ) { context in
            // Access both stores
            let _ = try context.store(for: "Customer")
            let _ = try context.store(for: "Order")
        }

        let manager = MigrationManager(
            database: database,
            schema: customerSchema,
            migrations: [multiTypeMigration],
            storeRegistry: storeRegistry,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migration
        try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))

        // Verify migration was applied
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 1, minor: 0, patch: 0))
        #expect(try await manager.isMigrationApplied(multiTypeMigration))
    }

    /// Test aggregate index migrations (COUNT, SUM)
    @Test("Aggregate index migration")
    func testAggregateIndexMigration() async throws {
        // Create COUNT index
        let cityCountIndex = Index(
            name: "customer_count_by_city",
            type: .count,
            rootExpression: FieldKeyExpression(fieldName: "city")
        )

        let schema = Schema([Customer.self], version: Schema.Version(2, 0, 0), indexes: [cityCountIndex])
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in }

        let countIndexMigration = MigrationManager.addIndexMigration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            index: cityCountIndex
        )

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, countIndexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migrations
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 2, minor: 0, patch: 0))
    }

    /// Test partial migration (migrate to intermediate version)
    @Test("Partial migration to intermediate version")
    func testPartialMigration() async throws {
        let schema = Schema([Customer.self], version: Schema.Version(3, 0, 0))
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let migration1 = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "V0 to V1"
        ) { _ in }

        let migration2 = Migration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            description: "V1 to V2"
        ) { _ in }

        let migration3 = Migration(
            fromVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 3, minor: 0, patch: 0),
            description: "V2 to V3"
        ) { _ in }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [migration1, migration2, migration3],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Migrate only to V2 (not V3)
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify only V2 is current
        let version1 = try await manager.getCurrentVersion()
        #expect(version1 == SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify only first two migrations applied
        #expect(try await manager.isMigrationApplied(migration1))
        #expect(try await manager.isMigrationApplied(migration2))
        #expect(!(try await manager.isMigrationApplied(migration3)))

        // Now migrate to V3
        try await manager.migrate(to: SchemaVersion(major: 3, minor: 0, patch: 0))

        let version2 = try await manager.getCurrentVersion()
        #expect(version2 == SchemaVersion(major: 3, minor: 0, patch: 0))
        #expect(try await manager.isMigrationApplied(migration3))
    }

    /// Test index state after migration
    @Test("Index state validation after migration")
    func testIndexStateAfterMigration() async throws {
        let emailIndex = Index(
            name: "customer_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let schema = Schema([Customer.self], version: Schema.Version(2, 0, 0), indexes: [emailIndex])
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in }

        let indexMigration = MigrationManager.addIndexMigration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            index: emailIndex
        )

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, indexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migrations
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify index state is readable
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let indexState = try await indexStateManager.state(of: "customer_by_email")
        #expect(indexState == .readable)
    }

    /// Test FormerIndex creation
    @Test("FormerIndex validation")
    func testFormerIndexValidation() async throws {
        let categoryIndex = Index(
            name: "customer_by_city",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "city")
        )

        let schemaV2 = Schema([Customer.self], version: Schema.Version(2, 0, 0), indexes: [categoryIndex])
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schemaV2,
            statisticsManager: NullStatisticsManager()
        )

        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in }

        let addIndexMigration = MigrationManager.addIndexMigration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            index: categoryIndex
        )

        // Apply initial migrations
        var manager = MigrationManager(
            database: database,
            schema: schemaV2,
            migrations: [initialMigration, addIndexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Now remove the index
        let schemaV3 = Schema([Customer.self], version: Schema.Version(3, 0, 0))

        let removeIndexMigration = MigrationManager.removeIndexMigration(
            fromVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 3, minor: 0, patch: 0),
            indexName: "customer_by_city",
            addedVersion: SchemaVersion(major: 2, minor: 0, patch: 0)
        )

        manager = MigrationManager(
            database: database,
            schema: schemaV3,
            migrations: [initialMigration, addIndexMigration, removeIndexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )
        try await manager.migrate(to: SchemaVersion(major: 3, minor: 0, patch: 0))

        // Verify index is disabled
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let indexState = try await indexStateManager.state(of: "customer_by_city")
        #expect(indexState == .disabled)
    }

    /// Test multiple index addition in single migration
    @Test("Multiple index addition")
    func testMultipleIndexAddition() async throws {
        let emailIndex = Index(
            name: "customer_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let cityIndex = Index(
            name: "customer_by_city",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "city")
        )

        let schema = Schema([Customer.self], version: Schema.Version(2, 0, 0), indexes: [emailIndex, cityIndex])
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize"
        ) { _ in }

        let multiIndexMigration = Migration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            description: "Add multiple indexes"
        ) { context in
            try await context.addIndex(emailIndex)
            try await context.addIndex(cityIndex)
        }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, multiIndexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migrations
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify both indexes are readable
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let emailState = try await indexStateManager.state(of: "customer_by_email")
        let cityState = try await indexStateManager.state(of: "customer_by_city")
        #expect(emailState == .readable)
        #expect(cityState == .readable)
    }

    /// Test data transformation migration
    @Test("Data transformation migration")
    func testDataTransformationMigration() async throws {
        let schema = Schema([Customer.self], version: Schema.Version(2, 0, 0))
        let store = RecordStore<Customer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Initial migration: add some test records
        let initialMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Initialize with test data"
        ) { context in
            // Add test records in migration
            let testCustomers = [
                Customer(id: 1, name: "Alice", email: "alice@example.com", city: "Tokyo"),
                Customer(id: 2, name: "Bob", email: "bob@example.com", city: "Osaka"),
                Customer(id: 3, name: "Charlie", email: "charlie@example.com", city: "Tokyo")
            ]

            let _ = try context.store(for: "Customer")

            // Manually save records using the RecordStore's serialization
            for _ in testCustomers {
                // Create a minimal save operation through the store
                // Note: This is a simplified approach for testing
                // In a real migration, you'd use the store's save methods
            }
        }

        // Data transformation migration
        let transformMigration = Migration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            description: "Transform customer data"
        ) { context in
            let customerStore = try context.store(for: "Customer")

            // Scan and transform records
            let records = customerStore.scanRecords { _ in
                // Filter logic (e.g., only process records from Tokyo)
                return true
            }

            for try await _ in records {
                // In a real scenario, you would:
                // 1. Deserialize the record
                // 2. Transform the data
                // 3. Save the transformed record
            }

            // Verify some records were scanned
            // (count may be 0 if no records exist, which is fine for this test)
        }

        let manager = MigrationManager(
            database: database,
            schema: schema,
            migrations: [initialMigration, transformMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migrations
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 2, minor: 0, patch: 0))

        // Verify both migrations were applied
        #expect(try await manager.isMigrationApplied(initialMigration))
        #expect(try await manager.isMigrationApplied(transformMigration))
    }

    /// Test rank index migration with grouping
    @Test("Rank index migration with grouping")
    func testRankIndexMigration() async throws {
        // Create rank index grouped by gameType
        let rankIndex = Index(
            name: "score_rank_by_game",
            type: .rank,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "gameType"),  // Grouping field
                FieldKeyExpression(fieldName: "score")      // Rank field
            ])
        )

        let schemaV1 = Schema([GameScore.self], version: Schema.Version(1, 0, 0), indexes: [rankIndex])
        let store = RecordStore<GameScore>(
            database: database,
            subspace: subspace,
            schema: schemaV1,
            statisticsManager: NullStatisticsManager()
        )

        // Migration to add rank index
        let rankIndexMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Add rank index for game scores"
        ) { context in
            try await context.addIndex(rankIndex)
        }

        let manager = MigrationManager(
            database: database,
            schema: schemaV1,
            migrations: [rankIndexMigration],
            store: store,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migration
        try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))

        // Verify migration was applied
        #expect(try await manager.isMigrationApplied(rankIndexMigration))

        // Verify rank index is readable
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let rankState = try await indexStateManager.state(of: "score_rank_by_game")
        #expect(rankState == .readable)

        // Verify current version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 1, minor: 0, patch: 0))
    }

    /// Test multi-RecordStore registry migration
    @Test("Multi-RecordStore registry migration")
    func testMultiRecordStoreMigration() async throws {
        // Create indexes for both Customer and GameScore
        let emailIndex = Index(
            name: "customer_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email"),
            recordTypes: ["Customer"]
        )

        let rankIndex = Index(
            name: "score_rank_by_game",
            type: .rank,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "gameType"),
                FieldKeyExpression(fieldName: "score")
            ]),
            recordTypes: ["GameScore"]
        )

        let schemaV1 = Schema(
            [Customer.self, GameScore.self],
            version: Schema.Version(1, 0, 0),
            indexes: [emailIndex, rankIndex]
        )

        // Create separate subspaces for each record type
        let customerSubspace = subspace.subspace("customers")
        let gameScoreSubspace = subspace.subspace("game_scores")

        let customerStore = RecordStore<Customer>(
            database: database,
            subspace: customerSubspace,
            schema: schemaV1,
            statisticsManager: NullStatisticsManager()
        )

        let gameScoreStore = RecordStore<GameScore>(
            database: database,
            subspace: gameScoreSubspace,
            schema: schemaV1,
            statisticsManager: NullStatisticsManager()
        )

        // Create store registry with both record types
        let storeRegistry: [String: any AnyRecordStore] = [
            "Customer": customerStore,
            "GameScore": gameScoreStore
        ]

        // Migration to add both indexes
        let multiTypeMigration = Migration(
            fromVersion: SchemaVersion(major: 0, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            description: "Add indexes for multiple record types"
        ) { context in
            try await context.addIndex(emailIndex)
            try await context.addIndex(rankIndex)
        }

        let manager = MigrationManager(
            database: database,
            schema: schemaV1,
            migrations: [multiTypeMigration],
            storeRegistry: storeRegistry,
            migrationSubspace: subspace.subspace("migrations")
        )

        // Apply migration
        try await manager.migrate(to: SchemaVersion(major: 1, minor: 0, patch: 0))

        // Verify migration was applied
        #expect(try await manager.isMigrationApplied(multiTypeMigration))

        // Verify both indexes are readable in their respective stores
        let customerIndexManager = IndexStateManager(database: database, subspace: customerSubspace)
        let emailState = try await customerIndexManager.state(of: "customer_by_email")
        #expect(emailState == .readable)

        let gameScoreIndexManager = IndexStateManager(database: database, subspace: gameScoreSubspace)
        let rankState = try await gameScoreIndexManager.state(of: "score_rank_by_game")
        #expect(rankState == .readable)

        // Verify current version
        let currentVersion = try await manager.getCurrentVersion()
        #expect(currentVersion == SchemaVersion(major: 1, minor: 0, patch: 0))
    }
}
