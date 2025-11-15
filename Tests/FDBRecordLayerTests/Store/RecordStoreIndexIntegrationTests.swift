import Testing
import Foundation
import Synchronization
@testable import FoundationDB
@testable import FDBRecordLayer

/// Integration tests for RecordStore with Index automatic maintenance
///
/// Test Coverage:
/// 1. Index updates on record save (new & update)
/// 2. Index deletion on record delete
/// 3. Multiple indexes maintained simultaneously
/// 4. Index state transitions (disabled → writeOnly → readable)
/// 5. Direct index entry verification
@Suite("RecordStore Index Integration Tests", .serialized)
struct RecordStoreIndexIntegrationTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Test Model (reuse from CRUD tests)

    struct Product: Codable, Equatable, Recordable {
        let productID: Int64
        let name: String
        let price: Int64
        let category: String
        let inStock: Bool

        static var recordName: String { "Product" }
        static var primaryKeyFields: [String] { ["productID"] }
        static var allFields: [String] { ["productID", "name", "price", "category", "inStock"] }

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "productID": return 1
            case "name": return 2
            case "price": return 3
            case "category": return 4
            case "inStock": return 5
            default: return nil
            }
        }

        func extractField(_ fieldName: String) -> [any TupleElement] {
            switch fieldName {
            case "productID": return [productID]
            case "name": return [name]
            case "price": return [price]
            case "category": return [category]
            case "inStock": return [inStock ? 1 : 0]
            default: return []
            }
        }

        func extractPrimaryKey() -> Tuple {
            return Tuple(productID)
        }
    }

    // MARK: - Test Helpers

    func createTestDatabase() throws -> any DatabaseProtocol {
        return try FDBClient.openDatabase()
    }

    func createTestSubspace() -> Subspace {
        return Subspace(prefix: Array("test_index_integration_\(UUID().uuidString)".utf8))
    }

    func createIndexedSchema() throws -> Schema {
        // Value index on category
        let categoryIndex = Index(
            name: "product_by_category",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "category"),
            recordTypes: ["Product"]
        )

        // Value index on price
        let priceIndex = Index(
            name: "product_by_price",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "price"),
            recordTypes: ["Product"]
        )

        return Schema([Product.self], indexes: [categoryIndex, priceIndex])
    }

    func setupIndexedStore() async throws -> (
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        store: RecordStore<Product>
    ) {
        let database = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createIndexedSchema()

        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: database, subspace: subspace.subspace("stats"))
        )

        // Make all indexes readable
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        for indexName in ["product_by_category", "product_by_price"] {
            try await indexStateManager.enable(indexName)
            try await indexStateManager.makeReadable(indexName)
        }

        return (database, subspace, schema, store)
    }

    func cleanupSubspace(_ database: any DatabaseProtocol, _ subspace: Subspace) async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    func countIndexEntries(
        _ database: any DatabaseProtocol,
        indexSubspace: Subspace,
        indexName: String,
        keyPrefix: Tuple
    ) async throws -> Int {
        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexNameSubspace = indexSubspace.subspace(indexName)

            // Extract elements from Tuple and apply them individually
            // to avoid nested tuple encoding
            let elements = keyPrefix.elements
            var rangeSubspace = indexNameSubspace
            for element in elements {
                rangeSubspace = rangeSubspace.subspace(element)
            }

            let (begin, end) = rangeSubspace.range()

            var count = 0
            for try await _ in transaction.getRange(begin: begin, end: end) {
                count += 1
            }
            return count
        }
    }

    // MARK: - Index Update on Save Tests

    @Test("Index is automatically updated when record is saved")
    func testIndexUpdatedOnSave() async throws {
        let (database, subspace, _, store) = try await setupIndexedStore()

        let product = Product(
            productID: 1,
            name: "Laptop",
            price: 1500,
            category: "Electronics",
            inStock: true
        )

        // Save record
        try await store.save(product)

        // Verify index entry exists
        let indexSubspace = subspace.subspace("I")
        let count = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("Electronics")
        )
        
        #expect(count == 1, "Should have 1 index entry for Electronics category")

        // Verify record can be loaded
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded != nil)
        #expect(loaded?.name == "Laptop")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Index automatically updated on save")
    }

    @Test("Index is updated when record is overwritten")
    func testIndexUpdatedOnOverwrite() async throws {
        let (database, subspace, _, store) = try await setupIndexedStore()

        let original = Product(
            productID: 1,
            name: "Original",
            price: 100,
            category: "CategoryA",
            inStock: true
        )

        let updated = Product(
            productID: 1,
            name: "Updated",
            price: 200,
            category: "CategoryB",
            inStock: true
        )

        // Save original
        try await store.save(original)

        // Save updated (same primary key, different category)
        try await store.save(updated)

        let indexSubspace = subspace.subspace("I")

        // Verify old category index is removed
        let oldCount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("CategoryA")
        )
        #expect(oldCount == 0, "Old category index should be removed")

        // Verify new category index exists
        let newCount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("CategoryB")
        )
        #expect(newCount == 1, "New category index should exist")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Index updated on record overwrite")
    }

    @Test("Multiple indexes are updated simultaneously")
    func testMultipleIndexesUpdated() async throws {
        let (database, subspace, _, store) = try await setupIndexedStore()

        let product = Product(
            productID: 1,
            name: "Desk",
            price: 300,
            category: "Furniture",
            inStock: true
        )

        // Save record
        try await store.save(product)

        let indexSubspace = subspace.subspace("I")

        // Verify category index
        let categoryCount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("Furniture")
        )
        #expect(categoryCount == 1, "Category index should be created")

        // Verify price index
        let priceCount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_price",
            keyPrefix: Tuple(300)
        )
        #expect(priceCount == 1, "Price index should be created")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Multiple indexes updated simultaneously")
    }

    // MARK: - Index Deletion on Delete Tests

    @Test("Index entries are deleted when record is deleted")
    func testIndexDeletedOnRecordDelete() async throws {
        let (database, subspace, _, store) = try await setupIndexedStore()

        let product = Product(
            productID: 1,
            name: "Chair",
            price: 200,
            category: "Furniture",
            inStock: true
        )

        // Save then delete
        try await store.save(product)
        try await store.delete(by: Tuple(1))

        let indexSubspace = subspace.subspace("I")

        // Verify index entry is deleted
        let count = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("Furniture")
        )
        #expect(count == 0, "Index entry should be deleted")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Index entries deleted on record delete")
    }

    @Test("Multiple index entries are deleted on record delete")
    func testMultipleIndexEntriesDeleted() async throws {
        let (database, subspace, _, store) = try await setupIndexedStore()

        let products = [
            Product(productID: 1, name: "Product 1", price: 100, category: "A", inStock: true),
            Product(productID: 2, name: "Product 2", price: 200, category: "A", inStock: true),
            Product(productID: 3, name: "Product 3", price: 300, category: "B", inStock: true)
        ]

        // Save all
        for product in products {
            try await store.save(product)
        }

        // Delete product 1
        try await store.delete(by: Tuple(1))

        let indexSubspace = subspace.subspace("I")

        // Verify category A still has one entry (product 2)
        let categoryACount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("A")
        )
        #expect(categoryACount == 1, "Category A should have 1 remaining entry")

        // Verify price 100 index is deleted
        let price100Count = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_price",
            keyPrefix: Tuple(100)
        )
        #expect(price100Count == 0, "Price 100 index should be deleted")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Multiple index entries deleted")
    }

    // MARK: - Complex Scenarios

    @Test("Index maintains consistency across multiple updates")
    func testIndexConsistencyAcrossUpdates() async throws {
        let (database, subspace, _, store) = try await setupIndexedStore()

        // Initial save
        try await store.save(Product(productID: 1, name: "P1", price: 100, category: "A", inStock: true))

        // Update 1: Change category
        try await store.save(Product(productID: 1, name: "P1", price: 100, category: "B", inStock: true))

        // Update 2: Change price
        try await store.save(Product(productID: 1, name: "P1", price: 200, category: "B", inStock: true))

        let indexSubspace = subspace.subspace("I")

        // Verify final category B exists
        let categoryBCount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("B")
        )
        #expect(categoryBCount == 1, "Category B should exist")

        // Verify old category A is gone
        let categoryACount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("A")
        )
        #expect(categoryACount == 0, "Category A should be removed")

        // Verify final price 200 exists
        let price200Count = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_price",
            keyPrefix: Tuple(200)
        )
        #expect(price200Count == 1, "Price 200 should exist")

        // Verify old price 100 is gone
        let price100Count = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_price",
            keyPrefix: Tuple(100)
        )
        #expect(price100Count == 0, "Price 100 should be removed")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Index consistency maintained across updates")
    }

    @Test("Index updates work with batch saves")
    func testIndexUpdatesWithBatchSaves() async throws {
        let (database, subspace, _, store) = try await setupIndexedStore()

        // Save 20 products
        for i in 1...20 {
            let product = Product(
                productID: Int64(i),
                name: "Product \(i)",
                price: Int64(i * 10),
                category: i % 2 == 0 ? "Even" : "Odd",
                inStock: true
            )
            try await store.save(product)
        }

        let indexSubspace = subspace.subspace("I")

        // Verify even category
        let evenCount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("Even")
        )
        #expect(evenCount == 10, "Should have 10 even products")

        // Verify odd category
        let oddCount = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("Odd")
        )
        #expect(oddCount == 10, "Should have 10 odd products")

        // Delete some products
        for i in 1...5 {
            try await store.delete(by: Tuple(Int64(i)))
        }

        // Re-count odd (should have 5 fewer: 1, 3, 5 deleted)
        let oddCountAfter = try await countIndexEntries(
            database,
            indexSubspace: indexSubspace,
            indexName: "product_by_category",
            keyPrefix: Tuple("Odd")
        )
        #expect(oddCountAfter == 7, "Should have 7 odd products after deletes")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Index updates work with batch saves")
    }
}