import Testing
import Foundation
import FoundationDB
@testable import FDBRecordLayer

// MARK: - Test Models with @Recordable + #Directory

/// User model with static directory
@Recordable
struct UserWithDirectory {
    #Directory<UserWithDirectory>("app", "users", layer: .recordStore)

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
}

/// Order model with recordStore layer (static path)
@Recordable
struct OrderWithDirectory {
    #Directory<OrderWithDirectory>("app", "orders", layer: .recordStore)

    @PrimaryKey var orderID: Int64
    var userID: Int64
    var total: Double
}

/// Product model with custom layer
@Recordable
struct ProductWithCustomLayer {
    #Directory<ProductWithCustomLayer>("app", "products", layer: .luceneIndex)

    @PrimaryKey var productID: Int64
    var name: String
    var description: String
}

/// Tenant Order model with partition (single KeyPath)
@Recordable
struct TenantOrder {
    #Directory<TenantOrder>("tenants", Field(\TenantOrder.tenantID), "orders", layer: .partition)

    @PrimaryKey var orderID: Int64
    var tenantID: String
    var total: Double
}

/// Channel Message model with partition (multiple KeyPaths)
@Recordable
struct ChannelMessage {
    #Directory<ChannelMessage>("tenants", Field(\ChannelMessage.tenantID), "channels", Field(\ChannelMessage.channelID), "messages", layer: .partition)

    @PrimaryKey var messageID: Int64
    var tenantID: String
    var channelID: String
    var content: String
}

// MARK: - Integration Tests

@Suite("@Recordable + #Directory Integration Tests")
struct RecordableDirectoryIntegrationTests {

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
}
