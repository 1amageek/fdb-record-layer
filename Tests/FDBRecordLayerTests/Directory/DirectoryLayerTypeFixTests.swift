import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer
@testable import FDBRecordCore

/// Tests verifying the fixes for DirectoryLayerType conversion and cache key bugs
///
/// Bug 1: DirectoryLayerType was not properly converted to DirectoryType
///        - Only .partition was converted, others got nil
///        - Caused macro-generated code and RecordContext to create different directories
///
/// Bug 2: Directory cache key was missing layerType
///        - Same path with different layerTypes shared the same cache entry
///        - Could cause wrong directory to be reused
@Suite("DirectoryLayerType Fix Verification")
struct DirectoryLayerTypeFixTests {

    // MARK: - Helper Methods

    /// Initialize FDB network (idempotent - safe to call multiple times)
    private func initializeFDB() throws {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized - this is fine
        }
    }

    // MARK: - Test Models

    @Recordable
    struct PartitionUser {
        #PrimaryKey<PartitionUser>([\.userID])
        #Directory<PartitionUser>("tenants", Field(\PartitionUser.tenantID), "users", layer: .partition)

        var userID: Int64
        var tenantID: String
        var name: String
    }

    @Recordable
    struct RecordStoreProduct {
        #PrimaryKey<RecordStoreProduct>([\.productID])
        #Directory<RecordStoreProduct>("app", "products", layer: .recordStore)

        var productID: Int64
        var name: String
        var category: String
    }

    @Recordable
    struct LuceneOrder {
        #PrimaryKey<LuceneOrder>([\.orderID])
        #Directory<LuceneOrder>("search", "orders", layer: .luceneIndex)

        var orderID: Int64
        var customerID: Int64
        var total: Double
    }

    @Recordable
    struct TimeSeriesEvent {
        #PrimaryKey<TimeSeriesEvent>([\.eventID])
        #Directory<TimeSeriesEvent>("metrics", "events", layer: .timeSeries)

        var eventID: Int64
        var timestamp: Date
        var value: Double
    }

    @Recordable
    struct VectorDocument {
        #PrimaryKey<VectorDocument>([\.docID])
        #Directory<VectorDocument>("vectors", "docs", layer: .vectorIndex)

        var docID: Int64
        var embedding: [Float32]
    }

    @Recordable
    struct CustomLayerData {
        #PrimaryKey<CustomLayerData>([\.dataID])
        #Directory<CustomLayerData>("custom", "data", layer: .custom("my_custom_layer"))

        var dataID: Int64
        var content: String
    }

    // Models for testing cache key distinction (same path, different layerTypes)
    @Recordable
    struct SamePathRecordStoreA {
        #PrimaryKey<SamePathRecordStoreA>([\.id])
        #Directory<SamePathRecordStoreA>("shared", "path", layer: .recordStore)

        var id: Int64
        var value: String
    }

    @Recordable
    struct SamePathLuceneB {
        #PrimaryKey<SamePathLuceneB>([\.id])
        #Directory<SamePathLuceneB>("shared", "path", layer: .luceneIndex)

        var id: Int64
        var value: String
    }
    
    // MARK: - Bug 1: DirectoryLayerType Conversion Tests

    @Test("All DirectoryLayerType values are properly converted to DirectoryType")
    func testAllDirectoryLayerTypesConversion() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        // Use test-specific isolated subspace for all tests
        let testSubspace = Subspace(prefix: Tuple("record-layer-tests", "directory-fix", UUID().uuidString).pack())

        // Test DirectoryLayer directly with isolated subspace
        let directoryLayer = DirectoryLayer(
            database: database,
            nodeSubspace: testSubspace.subspace(0xFE),
            contentSubspace: testSubspace
        )
        let simpleDir = try await directoryLayer.createOrOpen(
            path: ["test", "simple"],
            type: nil
        )
        #expect(simpleDir.subspace.prefix.count > 0)

        // Test .partition
        let partitionSchema = Schema([PartitionUser.self])
        let partitionContainer = try RecordContainer(configurations: [
            RecordConfiguration(schema: partitionSchema, isStoredInMemoryOnly: false)
        ])
        let partitionUser = PartitionUser(userID: 1, tenantID: "tenant-001", name: "Alice")
        let partitionDir = try await partitionContainer.getOrOpenDirectory(
            for: PartitionUser.self,
            with: partitionUser
        )
        #expect(partitionDir.prefix.count > 0, "Partition directory should be created")

        // Test .recordStore
        let recordStoreSchema = Schema([RecordStoreProduct.self])
        let recordStoreContainer = try RecordContainer(configurations: [
            RecordConfiguration(schema: recordStoreSchema, isStoredInMemoryOnly: false)
        ])
        let product = RecordStoreProduct(productID: 1, name: "Widget", category: "Hardware")
        let recordStoreDir = try await recordStoreContainer.getOrOpenDirectory(
            for: RecordStoreProduct.self,
            with: product
        )
        #expect(recordStoreDir.prefix.count > 0, "RecordStore directory should be created")

        // Test .luceneIndex
        let luceneSchema = Schema([LuceneOrder.self])
        let luceneContainer = try RecordContainer(configurations: [
            RecordConfiguration(schema: luceneSchema, isStoredInMemoryOnly: false)
        ])
        let order = LuceneOrder(orderID: 1, customerID: 100, total: 99.99)
        let luceneDir = try await luceneContainer.getOrOpenDirectory(
            for: LuceneOrder.self,
            with: order
        )
        #expect(luceneDir.prefix.count > 0, "Lucene directory should be created")

        // Test .timeSeries
        let timeSeriesSchema = Schema([TimeSeriesEvent.self])
        let timeSeriesContainer = try RecordContainer(configurations: [
            RecordConfiguration(schema: timeSeriesSchema, isStoredInMemoryOnly: false)
        ])
        let event = TimeSeriesEvent(eventID: 1, timestamp: Date(), value: 42.0)
        let timeSeriesDir = try await timeSeriesContainer.getOrOpenDirectory(
            for: TimeSeriesEvent.self,
            with: event
        )
        #expect(timeSeriesDir.prefix.count > 0, "TimeSeries directory should be created")

        // Test .vectorIndex
        let vectorSchema = Schema([VectorDocument.self])
        let vectorContainer = try RecordContainer(configurations: [
            RecordConfiguration(schema: vectorSchema, isStoredInMemoryOnly: false)
        ])
        let doc = VectorDocument(docID: 1, embedding: [0.1, 0.2, 0.3])
        let vectorDir = try await vectorContainer.getOrOpenDirectory(
            for: VectorDocument.self,
            with: doc
        )
        #expect(vectorDir.prefix.count > 0, "Vector directory should be created")

        // Test .custom
        let customSchema = Schema([CustomLayerData.self])
        let customContainer = try RecordContainer(configurations: [
            RecordConfiguration(schema: customSchema, isStoredInMemoryOnly: false)
        ])
        let data = CustomLayerData(dataID: 1, content: "test")
        let customDir = try await customContainer.getOrOpenDirectory(
            for: CustomLayerData.self,
            with: data
        )
        #expect(customDir.prefix.count > 0, "Custom directory should be created")

        // Verify all directories are different (different prefixes)
        let allPrefixes = [
            partitionDir.prefix,
            recordStoreDir.prefix,
            luceneDir.prefix,
            timeSeriesDir.prefix,
            vectorDir.prefix,
            customDir.prefix
        ]
        let uniquePrefixes = Set(allPrefixes.map { $0 })
        #expect(uniquePrefixes.count == allPrefixes.count, "All directories should have unique prefixes")
    }

    @Test("RecordContext and macro-generated code create identical directories")
    func testRecordContextAndMacroCreateSameDirectory() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        // Create record
        let product = RecordStoreProduct(productID: 42, name: "Test Widget", category: "Testing")

        // Method 1: RecordContext (uses RecordContainer.getOrOpenDirectory)
        let schema = Schema([RecordStoreProduct.self])
        let container = try RecordContainer(configurations: [
            RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ])
        let contextDir = try await container.getOrOpenDirectory(
            for: RecordStoreProduct.self,
            with: product
        )

        // Method 2: Macro-generated static method
        let macroDir = try await RecordStoreProduct.openDirectory(database: database)

        // Verify they create the same directory (same prefix)
        #expect(contextDir.prefix == macroDir.subspace.prefix, """
            RecordContext and macro-generated code should create directories with identical prefixes.
            Context prefix: \(contextDir.prefix.map { String(format: "%02x", $0) }.joined())
            Macro prefix: \(macroDir.subspace.prefix.map { String(format: "%02x", $0) }.joined())
            """)

        // Use default DirectoryLayer to verify directory exists
        let directoryLayer = DirectoryLayer(database: database)

        // Check if directory exists (with the appended suffix)
        let exists = try await directoryLayer.exists(path: ["app", "products", "_recordStore"])
        #expect(exists, "Directory should exist")

        // Open the directory (non-optional return)
        let openedDir = try await directoryLayer.open(path: ["app", "products", "_recordStore"])
        #expect(openedDir.subspace.prefix.count > 0, "Directory should be openable with valid prefix")
    }

    @Test("Records saved via RecordContext are readable via macro-generated store")
    func testCrossCompatibility() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([RecordStoreProduct.self])

        // Save via RecordContext
        let container = try RecordContainer(configurations: [
            RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ])
        let context = await container.mainContext
        let product1 = RecordStoreProduct(productID: 100, name: "Context Product", category: "Testing")
        context.insert(product1)
        try await context.save()

        // Read via macro-generated store
        let macroStore = try await RecordStoreProduct.store(database: database, schema: schema)
        let loaded = try await macroStore.record(for: 100)
        #expect(loaded != nil, "Record saved via RecordContext should be readable via macro-generated store")
        #expect(loaded?.name == "Context Product")

        // Save via macro-generated store
        let product2 = RecordStoreProduct(productID: 200, name: "Macro Product", category: "Testing")
        try await macroStore.save(product2)

        // Read via RecordContext
        let contextStore = container.store(
            for: RecordStoreProduct.self,
            subspace: try await RecordStoreProduct.openDirectory(database: database).subspace
        )
        let loadedViaContext = try await contextStore.record(for: 200)
        #expect(loadedViaContext != nil, "Record saved via macro should be readable via RecordContext")
        #expect(loadedViaContext?.name == "Macro Product")
    }

    // MARK: - Bug 2: Cache Key Tests

    @Test("Cache correctly distinguishes different layerTypes on same path")
    func testCacheDistinguishesLayerTypes() async throws {
        try initializeFDB()
        _ = try FDBClient.openDatabase(clusterFilePath: nil)

        // Use module-level models with same path but different layerTypes
        let schema = Schema([SamePathRecordStoreA.self, SamePathLuceneB.self])
        let container = try RecordContainer(configurations: [
            RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ])

        let recordStoreRecord = SamePathRecordStoreA(id: 1, value: "recordStore")
        let luceneRecord = SamePathLuceneB(id: 1, value: "lucene")

        // Get directories for both layerTypes
        let recordStoreDir = try await container.getOrOpenDirectory(
            for: SamePathRecordStoreA.self,
            with: recordStoreRecord
        )

        let luceneDir = try await container.getOrOpenDirectory(
            for: SamePathLuceneB.self,
            with: luceneRecord
        )

        // Verify they have different prefixes (different directories)
        #expect(recordStoreDir.prefix != luceneDir.prefix, """
            Same path with different layerTypes should create different directories.
            RecordStore prefix: \(recordStoreDir.prefix.map { String(format: "%02x", $0) }.joined())
            Lucene prefix: \(luceneDir.prefix.map { String(format: "%02x", $0) }.joined())
            """)
    }

    @Test("Cache reuses directory for same path and layerType")
    func testCacheReusesDirectoryForSamePathAndLayer() async throws {
        try initializeFDB()
        _ = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([PartitionUser.self])
        let container = try RecordContainer(configurations: [
            RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ])

        // Create two records with the same tenantID (same path)
        let user1 = PartitionUser(userID: 1, tenantID: "tenant-123", name: "Alice")
        let user2 = PartitionUser(userID: 2, tenantID: "tenant-123", name: "Bob")

        // Get directory for first record (cache miss)
        let dir1 = try await container.getOrOpenDirectory(for: PartitionUser.self, with: user1)

        // Get directory for second record with same path (cache hit)
        let dir2 = try await container.getOrOpenDirectory(for: PartitionUser.self, with: user2)

        // Verify they return the same directory (same prefix)
        #expect(dir1.prefix == dir2.prefix, "Same path and layerType should return cached directory")

        // Verify cache size
        #expect(container.directoryCacheSize() >= 1, "Cache should contain at least one entry")
    }

    @Test("Cache creates different directories for different Field values")
    func testCacheDifferentFieldValues() async throws {
        try initializeFDB()
        _ = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([PartitionUser.self])
        let container = try RecordContainer(configurations: [
            RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ])

        // Create records with different tenantIDs (different paths)
        let userA = PartitionUser(userID: 1, tenantID: "tenant-A", name: "Alice")
        let userB = PartitionUser(userID: 2, tenantID: "tenant-B", name: "Bob")

        // Get directories
        let dirA = try await container.getOrOpenDirectory(for: PartitionUser.self, with: userA)
        let dirB = try await container.getOrOpenDirectory(for: PartitionUser.self, with: userB)

        // Verify they have different prefixes (different directories)
        #expect(dirA.prefix != dirB.prefix, """
            Different Field values should create different directories (multi-tenant isolation).
            Tenant A prefix: \(dirA.prefix.map { String(format: "%02x", $0) }.joined())
            Tenant B prefix: \(dirB.prefix.map { String(format: "%02x", $0) }.joined())
            """)

        // Verify cache contains both directories
        #expect(container.directoryCacheSize() >= 2, "Cache should contain entries for both tenants")
    }

    // MARK: - DirectoryLayerType.rawValue Tests

    @Test("DirectoryLayerType.rawValue returns stable strings")
    func testRawValueStability() {
        #expect(DirectoryLayerType.partition.rawValue == "partition")
        #expect(DirectoryLayerType.recordStore.rawValue == "recordStore")
        #expect(DirectoryLayerType.luceneIndex.rawValue == "luceneIndex")
        #expect(DirectoryLayerType.timeSeries.rawValue == "timeSeries")
        #expect(DirectoryLayerType.vectorIndex.rawValue == "vectorIndex")
        #expect(DirectoryLayerType.custom("myLayer").rawValue == "custom:myLayer")
    }

    @Test("DirectoryLayerType.init(rawValue:) properly decodes all types")
    func testRawValueRoundTrip() {
        let types: [DirectoryLayerType] = [
            .partition,
            .recordStore,
            .luceneIndex,
            .timeSeries,
            .vectorIndex,
            .custom("testLayer")
        ]

        for type in types {
            let rawValue = type.rawValue
            let decoded = DirectoryLayerType(rawValue: rawValue)
            #expect(decoded == type, "RawValue round-trip should preserve type: \(type)")
        }
    }

    @Test("DirectoryLayerType.init(rawValue:) returns nil for invalid values")
    func testRawValueInvalidInput() {
        #expect(DirectoryLayerType(rawValue: "invalid") == nil)
        #expect(DirectoryLayerType(rawValue: "") == nil)
        #expect(DirectoryLayerType(rawValue: "custom") == nil) // Missing ":"
    }
}
