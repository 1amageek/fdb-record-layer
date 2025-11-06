import Testing
import Foundation
import FoundationDB
@testable import FDBRecordLayer

/// 複合主キーのテスト
///
/// このテストスイートは、複合主キー（複数フィールドの組み合わせで一意性を保証）
/// の機能を検証します：
///
/// 1. Tuple型を使用した複合主キー
/// 2. 可変長引数を使用した複合主キー
/// 3. トランザクション内での複合主キー操作
/// 4. 複合主キーによるインデックス更新
@Suite("Composite Primary Key Tests")
struct CompositeKeyTests {

    // MARK: - Test Models

    /// 複合主キーを持つOrderItemモデル
    /// 主キー: (orderID, itemID)
    struct OrderItem: Recordable, Equatable {
        static let recordTypeName = "OrderItem"
        static let primaryKey = \OrderItem.compositeKey

        var orderID: String
        var itemID: String
        var quantity: Int32
        var price: Double

        var compositeKey: Tuple {
            Tuple(orderID, itemID)
        }

        static func fieldName(for keyPath: PartialKeyPath<OrderItem>) -> String {
            switch keyPath {
            case \OrderItem.orderID: return "orderID"
            case \OrderItem.itemID: return "itemID"
            case \OrderItem.quantity: return "quantity"
            case \OrderItem.price: return "price"
            case \OrderItem.compositeKey: return "compositeKey"
            default: fatalError("Unknown keyPath")
            }
        }
    }

    /// 3フィールド複合主キーを持つInventoryモデル
    /// 主キー: (warehouseID, productID, batchID)
    struct Inventory: Recordable, Equatable {
        static let recordTypeName = "Inventory"
        static let primaryKey = \Inventory.compositeKey

        var warehouseID: String
        var productID: String
        var batchID: String
        var quantity: Int32

        var compositeKey: Tuple {
            Tuple(warehouseID, productID, batchID)
        }

        static func fieldName(for keyPath: PartialKeyPath<Inventory>) -> String {
            switch keyPath {
            case \Inventory.warehouseID: return "warehouseID"
            case \Inventory.productID: return "productID"
            case \Inventory.batchID: return "batchID"
            case \Inventory.quantity: return "quantity"
            case \Inventory.compositeKey: return "compositeKey"
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
        try metaData.registerRecordType(OrderItem.self)
        try metaData.registerRecordType(Inventory.self)
        return metaData
    }

    func createStore<T: Recordable>() throws -> RecordStore<T> {
        let db = try createDatabase()
        let metaData = try createMetaData()
        let subspace = Subspace(rootPrefix: "test-composite-\(UUID().uuidString)")

        return RecordStore<T>(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: NullStatisticsManager()
        )
    }

    func clearTestData<T: Recordable>(_ store: RecordStore<T>) async throws {
        let transaction = try store.database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let tr = context.getTransaction()
        let range = store.subspace.range()
        tr.clearRange(beginKey: range.begin, endKey: range.end)

        try await context.commit()
    }

    // MARK: - Tests

    @Test("Save and fetch with Tuple-based composite key")
    func testTupleCompositeKey() async throws {
        let store: RecordStore<OrderItem> = try createStore()
        try await clearTestData(store)

        // Create record with composite key
        let item = OrderItem(
            orderID: "order-001",
            itemID: "item-456",
            quantity: 2,
            price: 19.99
        )

        // Save
        try await store.save(item)

        // Fetch using Tuple
        let key = Tuple("order-001", "item-456")
        let fetched = try await store.fetch(by: key)

        #expect(fetched != nil)
        #expect(fetched?.orderID == "order-001")
        #expect(fetched?.itemID == "item-456")
        #expect(fetched?.quantity == 2)
        #expect(fetched?.price == 19.99)
    }

    @Test("Save and fetch with variadic composite key")
    func testVariadicCompositeKey() async throws {
        let store: RecordStore<OrderItem> = try createStore()
        try await clearTestData(store)

        // Create record
        let item = OrderItem(
            orderID: "order-002",
            itemID: "item-789",
            quantity: 5,
            price: 29.99
        )

        // Save
        try await store.save(item)

        // Fetch using variadic arguments (more concise)
        let fetched = try await store.fetch(by: "order-002", "item-789")

        #expect(fetched != nil)
        #expect(fetched?.orderID == "order-002")
        #expect(fetched?.itemID == "item-789")
        #expect(fetched?.quantity == 5)
        #expect(fetched?.price == 29.99)
    }

    @Test("Update record with composite key")
    func testUpdateCompositeKey() async throws {
        let store: RecordStore<OrderItem> = try createStore()
        try await clearTestData(store)

        // Create and save initial record
        let item = OrderItem(
            orderID: "order-003",
            itemID: "item-111",
            quantity: 1,
            price: 9.99
        )
        try await store.save(item)

        // Update quantity
        var updatedItem = item
        updatedItem.quantity = 10
        try await store.save(updatedItem)

        // Fetch and verify
        let fetched = try await store.fetch(by: "order-003", "item-111")

        #expect(fetched?.quantity == 10)
        #expect(fetched?.price == 9.99) // Unchanged
    }

    @Test("Delete record with composite key using Tuple")
    func testDeleteCompositeKeyTuple() async throws {
        let store: RecordStore<OrderItem> = try createStore()
        try await clearTestData(store)

        // Create and save record
        let item = OrderItem(
            orderID: "order-004",
            itemID: "item-222",
            quantity: 3,
            price: 14.99
        )
        try await store.save(item)

        // Verify it exists
        let beforeDelete = try await store.fetch(by: Tuple("order-004", "item-222"))
        #expect(beforeDelete != nil)

        // Delete using Tuple
        try await store.delete(by: Tuple("order-004", "item-222"))

        // Verify it's gone
        let afterDelete = try await store.fetch(by: "order-004", "item-222")
        #expect(afterDelete == nil)
    }

    @Test("Delete record with composite key using variadic")
    func testDeleteCompositeKeyVariadic() async throws {
        let store: RecordStore<OrderItem> = try createStore()
        try await clearTestData(store)

        // Create and save record
        let item = OrderItem(
            orderID: "order-005",
            itemID: "item-333",
            quantity: 7,
            price: 24.99
        )
        try await store.save(item)

        // Verify it exists
        let beforeDelete = try await store.fetch(by: "order-005", "item-333")
        #expect(beforeDelete != nil)

        // Delete using variadic arguments
        try await store.delete(by: "order-005", "item-333")

        // Verify it's gone
        let afterDelete = try await store.fetch(by: "order-005", "item-333")
        #expect(afterDelete == nil)
    }

    @Test("Transaction operations with composite key")
    func testTransactionCompositeKey() async throws {
        let store: RecordStore<OrderItem> = try createStore()
        try await clearTestData(store)

        // Perform multiple operations in a transaction
        try await store.transaction { transaction in
            // Save multiple items
            let item1 = OrderItem(
                orderID: "order-006",
                itemID: "item-A",
                quantity: 1,
                price: 10.00
            )

            let item2 = OrderItem(
                orderID: "order-006",
                itemID: "item-B",
                quantity: 2,
                price: 20.00
            )

            try await transaction.save(item1)
            try await transaction.save(item2)

            // Fetch within transaction using variadic
            let fetched = try await transaction.fetch(by: "order-006", "item-A")
            #expect(fetched?.quantity == 1)

            // Update within transaction
            var updated = item2
            updated.quantity = 5
            try await transaction.save(updated)
        }

        // Verify changes persisted
        let item1 = try await store.fetch(by: "order-006", "item-A")
        let item2 = try await store.fetch(by: "order-006", "item-B")

        #expect(item1?.quantity == 1)
        #expect(item2?.quantity == 5) // Updated value
    }

    @Test("Three-field composite key")
    func testThreeFieldCompositeKey() async throws {
        let store: RecordStore<Inventory> = try createStore()
        try await clearTestData(store)

        // Create record with 3-field composite key
        let inventory = Inventory(
            warehouseID: "warehouse-01",
            productID: "product-123",
            batchID: "batch-2024-01",
            quantity: 100
        )

        // Save
        try await store.save(inventory)

        // Fetch using 3 variadic arguments
        let fetched = try await store.fetch(
            by: "warehouse-01",
            "product-123",
            "batch-2024-01"
        )

        #expect(fetched != nil)
        #expect(fetched?.warehouseID == "warehouse-01")
        #expect(fetched?.productID == "product-123")
        #expect(fetched?.batchID == "batch-2024-01")
        #expect(fetched?.quantity == 100)
    }

    @Test("Composite key isolation between records")
    func testCompositeKeyIsolation() async throws {
        let store: RecordStore<OrderItem> = try createStore()
        try await clearTestData(store)

        // Create multiple items with same orderID but different itemID
        let items = [
            OrderItem(orderID: "order-007", itemID: "item-X", quantity: 1, price: 10.00),
            OrderItem(orderID: "order-007", itemID: "item-Y", quantity: 2, price: 20.00),
            OrderItem(orderID: "order-007", itemID: "item-Z", quantity: 3, price: 30.00),
        ]

        for item in items {
            try await store.save(item)
        }

        // Fetch each item independently
        let itemX = try await store.fetch(by: "order-007", "item-X")
        let itemY = try await store.fetch(by: "order-007", "item-Y")
        let itemZ = try await store.fetch(by: "order-007", "item-Z")

        #expect(itemX?.quantity == 1)
        #expect(itemY?.quantity == 2)
        #expect(itemZ?.quantity == 3)

        // Delete one item
        try await store.delete(by: "order-007", "item-Y")

        // Verify only that item is deleted
        #expect(try await store.fetch(by: "order-007", "item-X") != nil)
        #expect(try await store.fetch(by: "order-007", "item-Y") == nil)
        #expect(try await store.fetch(by: "order-007", "item-Z") != nil)
    }

    @Test("Composite key with numeric types")
    func testCompositeKeyNumeric() async throws {
        // Test with numeric types in composite key
        struct UserSession: Recordable, Equatable {
            static let recordTypeName = "UserSession"
            static let primaryKey = \UserSession.compositeKey

            var userID: Int64
            var sessionID: Int64
            var loginTime: Int64

            var compositeKey: Tuple {
                Tuple(userID, sessionID)
            }

            static func fieldName(for keyPath: PartialKeyPath<UserSession>) -> String {
                switch keyPath {
                case \UserSession.userID: return "userID"
                case \UserSession.sessionID: return "sessionID"
                case \UserSession.loginTime: return "loginTime"
                case \UserSession.compositeKey: return "compositeKey"
                default: fatalError("Unknown keyPath")
                }
            }
        }

        let metaData = RecordMetaData()
        try metaData.registerRecordType(UserSession.self)

        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test-composite-numeric-\(UUID().uuidString)")

        let store = RecordStore<UserSession>(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: NullStatisticsManager()
        )

        try await clearTestData(store)

        // Save session
        let session = UserSession(
            userID: 12345,
            sessionID: 67890,
            loginTime: 1234567890
        )
        try await store.save(session)

        // Fetch using numeric variadic arguments
        let fetched = try await store.fetch(by: Int64(12345), Int64(67890))

        #expect(fetched != nil)
        #expect(fetched?.userID == 12345)
        #expect(fetched?.sessionID == 67890)
        #expect(fetched?.loginTime == 1234567890)
    }
}
