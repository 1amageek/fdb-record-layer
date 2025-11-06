import Testing
import Foundation
import FoundationDB
@testable import FDBRecordLayer

/// PartitionManagerのテスト
///
/// PartitionManagerは、マルチテナント環境でアカウントごとに完全に分離された
/// RecordStoreを管理します。このテストでは、以下を検証します：
///
/// 1. アカウント分離: 各アカウントが独立したSubspaceを持つ
/// 2. キャッシング: RecordStoreが適切にキャッシュされる
/// 3. 削除機能: アカウント全体の削除が正しく動作する
/// 4. 並行性: 複数のアカウントに同時アクセスできる
@Suite("PartitionManager Tests")
struct PartitionManagerTests {

    // MARK: - Test Models

    struct User: Recordable, Equatable {
        static let recordTypeName = "User"
        static let primaryKey = \User.userID

        var userID: Int64
        var accountID: String
        var name: String
        var email: String

        static func fieldName(for keyPath: PartialKeyPath<User>) -> String {
            switch keyPath {
            case \User.userID: return "userID"
            case \User.accountID: return "accountID"
            case \User.name: return "name"
            case \User.email: return "email"
            default: fatalError("Unknown keyPath")
            }
        }
    }

    struct Order: Recordable, Equatable {
        static let recordTypeName = "Order"
        static let primaryKey = \Order.orderID

        var orderID: String
        var accountID: String
        var total: Double

        static func fieldName(for keyPath: PartialKeyPath<Order>) -> String {
            switch keyPath {
            case \Order.orderID: return "orderID"
            case \Order.accountID: return "accountID"
            case \Order.total: return "total"
            default: fatalError("Unknown keyPath")
            }
        }
    }

    // MARK: - Helper Methods

    func createDatabase() throws -> any DatabaseProtocol {
        return try FDB.selectAPIVersion(630)
    }

    func createMetaData() throws -> RecordMetaData {
        let metaData = RecordMetaData()
        try metaData.registerRecordType(User.self)
        try metaData.registerRecordType(Order.self)
        return metaData
    }

    func clearTestData(_ db: any DatabaseProtocol) async throws {
        let transaction = try db.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let tr = context.getTransaction()
        let rootSubspace = Subspace(rootPrefix: "test-partition")
        let range = rootSubspace.range()
        tr.clearRange(beginKey: range.begin, endKey: range.end)

        try await context.commit()
    }

    // MARK: - Tests

    @Test("PartitionManager creates isolated RecordStores")
    func testAccountIsolation() async throws {
        let db = try createDatabase()
        let metaData = try createMetaData()

        // Clean up
        try await clearTestData(db)

        // Create PartitionManager
        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "test-partition"),
            metaData: metaData
        )

        // Get RecordStores for different accounts
        let store1: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        let store2: RecordStore<User> = try await manager.recordStore(
            for: "account-002",
            collection: "users"
        )

        // Verify different subspaces
        #expect(store1.subspace != store2.subspace)

        // Save records
        let user1 = User(userID: 1, accountID: "account-001", name: "Alice", email: "alice@example.com")
        let user2 = User(userID: 1, accountID: "account-002", name: "Bob", email: "bob@example.com")

        try await store1.save(user1)
        try await store2.save(user2)

        // Verify isolation: each account can only see its own data
        let fetchedUser1 = try await store1.fetch(by: 1)
        let fetchedUser2 = try await store2.fetch(by: 1)

        #expect(fetchedUser1?.name == "Alice")
        #expect(fetchedUser2?.name == "Bob")
        #expect(fetchedUser1?.accountID == "account-001")
        #expect(fetchedUser2?.accountID == "account-002")
    }

    @Test("PartitionManager caches RecordStores")
    func testRecordStoreCaching() async throws {
        let db = try createDatabase()
        let metaData = try createMetaData()

        try await clearTestData(db)

        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "test-partition"),
            metaData: metaData
        )

        // Get the same RecordStore twice
        let store1: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        let store2: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        // Verify they are the same instance (cached)
        #expect(store1.subspace == store2.subspace)

        // Verify cache size
        #expect(manager.cacheSize() == 1)
    }

    @Test("PartitionManager supports multiple collections")
    func testMultipleCollections() async throws {
        let db = try createDatabase()
        let metaData = try createMetaData()

        try await clearTestData(db)

        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "test-partition"),
            metaData: metaData
        )

        // Get RecordStores for different collections in the same account
        let userStore: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        let orderStore: RecordStore<Order> = try await manager.recordStore(
            for: "account-001",
            collection: "orders"
        )

        // Verify different subspaces
        #expect(userStore.subspace != orderStore.subspace)

        // Save records
        let user = User(userID: 1, accountID: "account-001", name: "Alice", email: "alice@example.com")
        let order = Order(orderID: "order-001", accountID: "account-001", total: 99.99)

        try await userStore.save(user)
        try await orderStore.save(order)

        // Verify both collections work independently
        let fetchedUser = try await userStore.fetch(by: 1)
        let fetchedOrder = try await orderStore.fetch(by: "order-001")

        #expect(fetchedUser?.name == "Alice")
        #expect(fetchedOrder?.total == 99.99)

        // Verify cache has both stores
        #expect(manager.cacheSize() == 2)
    }

    @Test("PartitionManager deletes entire account")
    func testDeleteAccount() async throws {
        let db = try createDatabase()
        let metaData = try createMetaData()

        try await clearTestData(db)

        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "test-partition"),
            metaData: metaData
        )

        // Create stores and save data
        let userStore: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        let orderStore: RecordStore<Order> = try await manager.recordStore(
            for: "account-001",
            collection: "orders"
        )

        let user = User(userID: 1, accountID: "account-001", name: "Alice", email: "alice@example.com")
        let order = Order(orderID: "order-001", accountID: "account-001", total: 99.99)

        try await userStore.save(user)
        try await orderStore.save(order)

        // Verify data exists
        #expect(try await userStore.fetch(by: 1) != nil)
        #expect(try await orderStore.fetch(by: "order-001") != nil)

        // Delete the entire account
        try await manager.deleteAccount("account-001")

        // Verify cache is cleared
        #expect(manager.cacheSize() == 0)

        // Create new stores (since cache was cleared)
        let newUserStore: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        let newOrderStore: RecordStore<Order> = try await manager.recordStore(
            for: "account-001",
            collection: "orders"
        )

        // Verify data is gone
        #expect(try await newUserStore.fetch(by: 1) == nil)
        #expect(try await newOrderStore.fetch(by: "order-001") == nil)
    }

    @Test("PartitionManager handles concurrent access")
    func testConcurrentAccess() async throws {
        let db = try createDatabase()
        let metaData = try createMetaData()

        try await clearTestData(db)

        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "test-partition"),
            metaData: metaData
        )

        // Create multiple users concurrently across different accounts
        await withTaskGroup(of: Void.self) { group in
            for accountNum in 1...10 {
                group.addTask {
                    let accountID = "account-\(String(format: "%03d", accountNum))"
                    do {
                        let store: RecordStore<User> = try await manager.recordStore(
                            for: accountID,
                            collection: "users"
                        )

                        let user = User(
                            userID: Int64(accountNum),
                            accountID: accountID,
                            name: "User\(accountNum)",
                            email: "user\(accountNum)@example.com"
                        )

                        try await store.save(user)
                    } catch {
                        Issue.record("Failed to save user for \(accountID): \(error)")
                    }
                }
            }
        }

        // Verify all accounts have their data
        for accountNum in 1...10 {
            let accountID = "account-\(String(format: "%03d", accountNum))"
            let store: RecordStore<User> = try await manager.recordStore(
                for: accountID,
                collection: "users"
            )

            let user = try await store.fetch(by: Int64(accountNum))
            #expect(user?.name == "User\(accountNum)")
        }

        // Verify cache has all 10 stores
        #expect(manager.cacheSize() == 10)
    }

    @Test("PartitionManager clearCache works correctly")
    func testClearCache() async throws {
        let db = try createDatabase()
        let metaData = try createMetaData()

        try await clearTestData(db)

        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "test-partition"),
            metaData: metaData
        )

        // Create multiple stores
        let _: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        let _: RecordStore<Order> = try await manager.recordStore(
            for: "account-001",
            collection: "orders"
        )

        let _: RecordStore<User> = try await manager.recordStore(
            for: "account-002",
            collection: "users"
        )

        // Verify cache has stores
        #expect(manager.cacheSize() == 3)

        // Clear cache
        manager.clearCache()

        // Verify cache is empty
        #expect(manager.cacheSize() == 0)
    }

    @Test("PartitionManager Subspace structure is correct")
    func testSubspaceStructure() async throws {
        let db = try createDatabase()
        let metaData = try createMetaData()

        try await clearTestData(db)

        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "test-partition"),
            metaData: metaData
        )

        let store: RecordStore<User> = try await manager.recordStore(
            for: "account-001",
            collection: "users"
        )

        // Expected structure: /test-partition/accounts/account-001/users/
        let expectedSubspace = Subspace(rootPrefix: "test-partition")
            .subspace(Tuple(["accounts"]))
            .subspace(Tuple(["account-001"]))
            .subspace(Tuple(["users"]))

        #expect(store.subspace == expectedSubspace)
    }
}
