import Testing
import Foundation
 import FDBRecordCore
@testable import FoundationDB
@testable import FDBRecordLayer

// MARK: - Test Models with @Recordable + #Directory

/// User model with static directory
@Recordable
struct UserWithDirectory {
    #Directory<UserWithDirectory>("app", "users", layer: .recordStore)
    #PrimaryKey<UserWithDirectory>([\.userID])

    

    var userID: Int64
    var name: String
    var email: String
}

/// Order model with recordStore layer (static path)
@Recordable
struct OrderWithDirectory {
    #Directory<OrderWithDirectory>("app", "orders", layer: .recordStore)
    #PrimaryKey<OrderWithDirectory>([\.orderID])

    

    var orderID: Int64
    var userID: Int64
    var total: Double
}

/// Product model with custom layer
@Recordable
struct ProductWithCustomLayer {
    #Directory<ProductWithCustomLayer>("app", "products", layer: .luceneIndex)
    #PrimaryKey<ProductWithCustomLayer>([\.productID])

    

    var productID: Int64
    var name: String
    var description: String
}

/// Tenant Order model with partition (single KeyPath)
@Recordable
struct TenantOrder {
    #Directory<TenantOrder>("tenants", Field(\TenantOrder.tenantID), "orders", layer: .partition)
    #PrimaryKey<TenantOrder>([\.orderID])

    

    var orderID: Int64
    var tenantID: String
    var total: Double
}

/// Channel Message model with partition (multiple KeyPaths)
@Recordable
struct ChannelMessage {
    #Directory<ChannelMessage>("tenants", Field(\ChannelMessage.tenantID), "channels", Field(\ChannelMessage.channelID), "messages", layer: .partition)
    #PrimaryKey<ChannelMessage>([\.messageID])



    var messageID: Int64
    var tenantID: String
    var channelID: String
    var content: String
}

/// Multi-tenant User model with Directory + Index + Unique + PrimaryKey (CLAUDE.md use case)
@Recordable
struct MultiTenantUser {
    #Unique<MultiTenantUser>([\.email])
    #Index<MultiTenantUser>([\.city, \.age])
    #Directory<MultiTenantUser>("tenants", Field(\MultiTenantUser.tenantID), "users", layer: .partition)
    #PrimaryKey<MultiTenantUser>([\.userID])



    var userID: Int64
    var tenantID: String
    var email: String
    var name: String
    var city: String
    var age: Int
}

// MARK: - Integration Tests

@Suite("@Recordable + #Directory Integration Tests", .tags(.integration))
struct RecordableDirectoryIntegrationTests {

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    @Test("UserWithDirectory generates openDirectory() method")
    func userWithDirectoryOpenDirectory() async throws {
        // Verify method signature exists
        let _: (any DatabaseProtocol) async throws -> DirectorySubspace =
            UserWithDirectory.openDirectory(database:)

        // This verifies that @Recordable macro:
        // 1. Detected #Directory<UserWithDirectory>(["app", "users"], layer: .recordStore)
        // 2. Generated: public static func openDirectory(database:) async throws -> DirectorySubspace
    }

    @Test("UserWithDirectory generates store() method")
    func userWithDirectoryStore() async throws {
        // Verify method signature exists
        let _: (any DatabaseProtocol, Schema) async throws -> RecordStore<UserWithDirectory> =
            UserWithDirectory.store(database:schema:)

        // This verifies that @Recordable macro:
        // 1. Generated: public static func store(database:schema:) async throws -> RecordStore<UserWithDirectory>
    }

    @Test("OrderWithDirectory generates openDirectory() method")
    func orderWithDirectoryOpenDirectory() async throws {
        // Verify method signature exists
        let _: (any DatabaseProtocol) async throws -> DirectorySubspace =
            OrderWithDirectory.openDirectory(database:)
    }

    @Test("OrderWithDirectory generates store() method")
    func orderWithDirectoryStore() async throws {
        // Verify method signature exists
        let _: (any DatabaseProtocol, Schema) async throws -> RecordStore<OrderWithDirectory> =
            OrderWithDirectory.store(database:schema:)
    }

    @Test("ProductWithCustomLayer generates openDirectory() method")
    func productWithCustomLayerOpenDirectory() async throws {
        // Verify method signature exists
        let _: (any DatabaseProtocol) async throws -> DirectorySubspace =
            ProductWithCustomLayer.openDirectory(database:)

        // This verifies custom layer (.luceneIndex) support
    }

    @Test("ProductWithCustomLayer generates store() method")
    func productWithCustomLayerStore() async throws {
        // Verify method signature exists
        let _: (any DatabaseProtocol, Schema) async throws -> RecordStore<ProductWithCustomLayer> =
            ProductWithCustomLayer.store(database:schema:)
    }

    @Test("UserWithDirectory has Recordable conformance")
    func userWithDirectoryRecordableConformance() {
        #expect(UserWithDirectory.recordName == "UserWithDirectory")
        #expect(UserWithDirectory.primaryKeyFields == ["userID"])
        #expect(UserWithDirectory.allFields == ["userID", "name", "email"])
    }

    @Test("OrderWithDirectory has Recordable conformance")
    func orderWithDirectoryRecordableConformance() {
        #expect(OrderWithDirectory.recordName == "OrderWithDirectory")
        #expect(OrderWithDirectory.primaryKeyFields == ["orderID"])
        #expect(OrderWithDirectory.allFields == ["orderID", "userID", "total"])
    }

    @Test("ProductWithCustomLayer has Recordable conformance")
    func productWithCustomLayerRecordableConformance() {
        #expect(ProductWithCustomLayer.recordName == "ProductWithCustomLayer")
        #expect(ProductWithCustomLayer.primaryKeyFields == ["productID"])
        #expect(ProductWithCustomLayer.allFields == ["productID", "name", "description"])
    }

    // MARK: - Partition Models with KeyPath

    @Test("TenantOrder generates openDirectory() method with partition key")
    func tenantOrderOpenDirectory() async throws {
        // Verify method signature exists with tenantID parameter
        let _: (String, any DatabaseProtocol) async throws -> DirectorySubspace =
            TenantOrder.openDirectory(tenantID:database:)
    }

    @Test("TenantOrder generates store() method with partition key")
    func tenantOrderStore() async throws {
        // Verify method signature exists with tenantID parameter
        let _: (String, any DatabaseProtocol, Schema) async throws -> RecordStore<TenantOrder> =
            TenantOrder.store(tenantID:database:schema:)
    }

    @Test("TenantOrder has Recordable conformance")
    func tenantOrderRecordableConformance() {
        #expect(TenantOrder.recordName == "TenantOrder")
        #expect(TenantOrder.primaryKeyFields == ["orderID"])
        #expect(TenantOrder.allFields == ["orderID", "tenantID", "total"])
    }

    @Test("ChannelMessage generates openDirectory() method with multiple partition keys")
    func channelMessageOpenDirectory() async throws {
        // Verify method signature exists with tenantID and channelID parameters
        let _: (String, String, any DatabaseProtocol) async throws -> DirectorySubspace =
            ChannelMessage.openDirectory(tenantID:channelID:database:)
    }

    @Test("ChannelMessage generates store() method with multiple partition keys")
    func channelMessageStore() async throws {
        // Verify method signature exists with tenantID and channelID parameters
        let _: (String, String, any DatabaseProtocol, Schema) async throws -> RecordStore<ChannelMessage> =
            ChannelMessage.store(tenantID:channelID:database:schema:)
    }

    @Test("ChannelMessage has Recordable conformance")
    func channelMessageRecordableConformance() {
        #expect(ChannelMessage.recordName == "ChannelMessage")
        #expect(ChannelMessage.primaryKeyFields == ["messageID"])
        #expect(ChannelMessage.allFields == ["messageID", "tenantID", "channelID", "content"])
    }

    // MARK: - MultiTenantUser Tests (Directory + Index + Unique + PrimaryKey)

    @Test("MultiTenantUser generates openDirectory() method with partition key")
    func multiTenantUserOpenDirectory() async throws {
        // Verify method signature exists with tenantID parameter
        let _: (String, any DatabaseProtocol) async throws -> DirectorySubspace =
            MultiTenantUser.openDirectory(tenantID:database:)
    }

    @Test("MultiTenantUser generates store() method with partition key")
    func multiTenantUserStore() async throws {
        // Verify method signature exists with tenantID parameter
        let _: (String, any DatabaseProtocol, Schema) async throws -> RecordStore<MultiTenantUser> =
            MultiTenantUser.store(tenantID:database:schema:)
    }

    @Test("MultiTenantUser has Recordable conformance")
    func multiTenantUserRecordableConformance() {
        #expect(MultiTenantUser.recordName == "MultiTenantUser")
        #expect(MultiTenantUser.primaryKeyFields == ["userID"])
        #expect(MultiTenantUser.allFields == ["userID", "tenantID", "email", "name", "city", "age"])
    }

    @Test("MultiTenantUser has correct index definitions")
    func multiTenantUserIndexDefinitions() {
        let indexes = MultiTenantUser.indexDefinitions

        // Should have 2 indexes: 1 unique + 1 regular
        #expect(indexes.count == 2)

        // Check unique index on email
        let uniqueIndex = indexes.first { $0.name.contains("email") }
        #expect(uniqueIndex != nil)
        #expect(uniqueIndex?.unique == true)

        // Check composite index on city + age
        let cityAgeIndex = indexes.first { $0.name.contains("city") && $0.name.contains("age") }
        #expect(cityAgeIndex != nil)
        #expect(cityAgeIndex?.unique == false)
    }

    @Test("MultiTenantUser end-to-end: Directory + Index + Unique + PrimaryKey")
    func multiTenantUserEndToEnd() async throws {
        // This test verifies the complete use case from CLAUDE.md:
        // - Multi-tenant directory (partition)
        // - Unique constraint on email
        // - Composite index on city + age
        // - Primary key on userID

        let database = try FDBClient.openDatabase()
        let schema = Schema([MultiTenantUser.self], version: Schema.Version(1, 0, 0))

        // Open store for tenant "acme-corp"
        let store = try await MultiTenantUser.store(
            tenantID: "acme-corp",
            database: database,
            schema: schema
        )

        // Create test users
        let user1 = MultiTenantUser(
            userID: 1,
            tenantID: "acme-corp",
            email: "alice@acme.com",
            name: "Alice",
            city: "Tokyo",
            age: 25
        )

        let user2 = MultiTenantUser(
            userID: 2,
            tenantID: "acme-corp",
            email: "bob@acme.com",
            name: "Bob",
            city: "Tokyo",
            age: 30
        )

        // Save users
        try await store.save(user1)
        try await store.save(user2)

        // Verify users were saved
        let loaded1 = try await store.record(for: Tuple(1))
        #expect(loaded1?.email == "alice@acme.com")

        let loaded2 = try await store.record(for: Tuple(2))
        #expect(loaded2?.email == "bob@acme.com")

        // Clean up
        try await store.delete(by: 1)
        try await store.delete(by: 2)
    }

    @Test("directoryPathComponents is generated correctly for static path")
    func testDirectoryPathComponentsStatic() {
        // UserWithDirectory has static path: "app", "users"
        let components = UserWithDirectory.directoryPathComponents

        #expect(components.count == 2)

        if let first = components[0] as? Path {
            #expect(first.value == "app")
        } else {
            Issue.record("First component should be Path")
        }

        if let second = components[1] as? Path {
            #expect(second.value == "users")
        } else {
            Issue.record("Second component should be Path")
        }
    }

    @Test("directoryPathComponents is generated correctly for partition with Field")
    func testDirectoryPathComponentsPartition() {
        // TenantOrder has path: "tenants", Field(\.tenantID), "orders"
        let components = TenantOrder.directoryPathComponents

        #expect(components.count == 3)

        if let first = components[0] as? Path {
            #expect(first.value == "tenants")
        } else {
            Issue.record("First component should be Path")
        }

        if let _ = components[1] as? Field<TenantOrder> {
            // Field exists, verify it has a KeyPath
            // (We can't check the exact KeyPath value, but we can verify the type)
        } else {
            Issue.record("Second component should be Field<TenantOrder>")
        }

        if let third = components[2] as? Path {
            #expect(third.value == "orders")
        } else {
            Issue.record("Third component should be Path")
        }
    }

    @Test("directoryLayerType is generated correctly for recordStore")
    func testDirectoryLayerTypeRecordStore() {
        #expect(UserWithDirectory.directoryLayerType == .recordStore)
        #expect(OrderWithDirectory.directoryLayerType == .recordStore)
    }

    @Test("directoryLayerType is generated correctly for partition")
    func testDirectoryLayerTypePartition() {
        #expect(TenantOrder.directoryLayerType == .partition)
        #expect(ChannelMessage.directoryLayerType == .partition)
        #expect(MultiTenantUser.directoryLayerType == .partition)
    }

    @Test("directoryLayerType is generated correctly for custom")
    func testDirectoryLayerTypeCustom() {
        #expect(ProductWithCustomLayer.directoryLayerType == .luceneIndex)
    }
}
