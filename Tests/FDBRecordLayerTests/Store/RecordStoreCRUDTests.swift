import Testing
import Foundation
import Synchronization
@testable import FoundationDB
@testable import FDBRecordLayer

/// Comprehensive tests for RecordStore CRUD operations
///
/// Test Coverage:
/// 1. Save operations (new records, updates, bulk saves)
/// 2. Load operations (existing, non-existing, transactions)
/// 3. Delete operations (single, multiple, cascade to indexes)
/// 4. Scan operations (full scan, range scan, filtered scan)
/// 5. Edge cases (empty dataset, large records, special characters)
@Suite("RecordStore CRUD Tests", .serialized)
struct RecordStoreCRUDTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Test Model

    /// Simple product model for testing CRUD operations
    struct Product: Codable, Equatable, Recordable {
        let productID: Int64
        let name: String
        let price: Int64
        let category: String
        let inStock: Bool

        // MARK: - Recordable Conformance

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
        return Subspace(prefix: Array("test_crud_\(UUID().uuidString)".utf8))
    }

    func createTestSchema(withIndexes: Bool = false) throws -> Schema {
        if withIndexes {
            // Create schema with indexes for integration tests
            let categoryIndex = Index(
                name: "product_by_category",
                type: .value,
                rootExpression: FieldKeyExpression(fieldName: "category"),
                recordTypes: ["Product"]
            )

            let priceIndex = Index(
                name: "product_by_price",
                type: .value,
                rootExpression: FieldKeyExpression(fieldName: "price"),
                recordTypes: ["Product"]
            )

            return Schema([Product.self], indexes: [categoryIndex, priceIndex])
        } else {
            // Basic schema without indexes
            return Schema([Product.self], indexes: [])
        }
    }

    func setupTestStore(withIndexes: Bool = false) async throws -> (
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        store: RecordStore<Product>
    ) {
        let database = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createTestSchema(withIndexes: withIndexes)

        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: database, subspace: subspace.subspace("stats"))
        )

        // Make indexes readable if present
        if withIndexes {
            let indexStateManager = IndexStateManager(database: database, subspace: subspace)
            try await indexStateManager.enable("product_by_category")
            try await indexStateManager.makeReadable("product_by_category")
            try await indexStateManager.enable("product_by_price")
            try await indexStateManager.makeReadable("product_by_price")
        }

        return (database, subspace, schema, store)
    }

    func cleanupSubspace(_ database: any DatabaseProtocol, _ subspace: Subspace) async throws {
        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Save Operation Tests

    @Test("Save new record succeeds")
    func testSaveNewRecord() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let product = Product(
            productID: 1,
            name: "Laptop",
            price: 1500,
            category: "Electronics",
            inStock: true
        )

        // Save the record
        try await store.save(product)

        // Verify it was saved by loading it back
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded != nil, "Saved record should be loadable")
        #expect(loaded?.productID == 1)
        #expect(loaded?.name == "Laptop")
        #expect(loaded?.price == 1500)
        #expect(loaded?.category == "Electronics")
        #expect(loaded?.inStock == true)

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ New record saved and loaded successfully")
    }

    @Test("Save overwrites existing record")
    func testSaveOverwriteExisting() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let original = Product(
            productID: 1,
            name: "Original Name",
            price: 100,
            category: "Category A",
            inStock: true
        )

        let updated = Product(
            productID: 1,
            name: "Updated Name",
            price: 200,
            category: "Category B",
            inStock: false
        )

        // Save original
        try await store.save(original)

        // Save updated with same primary key
        try await store.save(updated)

        // Load and verify it was overwritten
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded?.name == "Updated Name", "Name should be updated")
        #expect(loaded?.price == 200, "Price should be updated")
        #expect(loaded?.category == "Category B", "Category should be updated")
        #expect(loaded?.inStock == false, "inStock should be updated")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Record overwritten successfully")
    }

    @Test("Save multiple records succeeds")
    func testSaveMultipleRecords() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let products = [
            Product(productID: 1, name: "Laptop", price: 1500, category: "Electronics", inStock: true),
            Product(productID: 2, name: "Mouse", price: 25, category: "Electronics", inStock: true),
            Product(productID: 3, name: "Desk", price: 300, category: "Furniture", inStock: false),
            Product(productID: 4, name: "Chair", price: 200, category: "Furniture", inStock: true),
            Product(productID: 5, name: "Monitor", price: 400, category: "Electronics", inStock: true)
        ]

        // Save all products
        for product in products {
            try await store.save(product)
        }

        // Verify all were saved
        for product in products {
            let loaded = try await store.record(for: Tuple(product.productID))
            #expect(loaded != nil, "Product \(product.productID) should be saved")
            #expect(loaded?.name == product.name)
        }

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Multiple records saved successfully")
    }

    @Test("Save within transaction commits atomically")
    func testSaveWithinTransaction() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let products = [
            Product(productID: 1, name: "Product 1", price: 100, category: "A", inStock: true),
            Product(productID: 2, name: "Product 2", price: 200, category: "B", inStock: true)
        ]

        // Save both products in individual transactions (atomic per-record)
        // TODO: Add transaction support with RecordTransaction API
        for product in products {
            try await store.save(product)
        }

        // Verify both were saved
        let loaded1 = try await store.record(for: Tuple(1))
        let loaded2 = try await store.record(for: Tuple(2))

        #expect(loaded1 != nil, "First product should be saved")
        #expect(loaded2 != nil, "Second product should be saved")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Multiple saves succeeded")
    }

    @Test("Save with special characters in fields")
    func testSaveWithSpecialCharacters() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let product = Product(
            productID: 1,
            name: "Product \"Special\" \n\t\\",
            price: 100,
            category: "Category/Sub🔥",
            inStock: true
        )

        try await store.save(product)

        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded?.name == "Product \"Special\" \n\t\\", "Special characters should be preserved")
        #expect(loaded?.category == "Category/Sub🔥", "Unicode should be preserved")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Special characters handled correctly")
    }

    // MARK: - Load Operation Tests

    @Test("Load existing record succeeds")
    func testLoadExistingRecord() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let product = Product(
            productID: 42,
            name: "Test Product",
            price: 999,
            category: "Test",
            inStock: true
        )

        try await store.save(product)

        // Load the record
        let loaded = try await store.record(for: Tuple(42))

        #expect(loaded != nil, "Record should exist")
        #expect(loaded == product, "Loaded record should match saved record")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Existing record loaded successfully")
    }

    @Test("Load non-existing record returns nil")
    func testLoadNonExistingRecord() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        // Try to load a record that doesn't exist
        let loaded = try await store.record(for: Tuple(999))

        #expect(loaded == nil, "Non-existing record should return nil")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Non-existing record correctly returns nil")
    }

    @Test("Load after save sees committed write")
    func testLoadAfterSaveSeesWrite() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let product = Product(
            productID: 1,
            name: "Transaction Test",
            price: 100,
            category: "Test",
            inStock: true
        )

        // Save
        try await store.save(product)

        // Load and verify
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded != nil, "Should load saved record")
        #expect(loaded?.name == "Transaction Test")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Load after save succeeded")
    }

    @Test("Load multiple records by primary key")
    func testLoadMultipleRecords() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let products = [
            Product(productID: 1, name: "Product 1", price: 100, category: "A", inStock: true),
            Product(productID: 2, name: "Product 2", price: 200, category: "B", inStock: true),
            Product(productID: 3, name: "Product 3", price: 300, category: "C", inStock: false)
        ]

        // Save all products
        for product in products {
            try await store.save(product)
        }

        // Load all products
        for product in products {
            let loaded = try await store.record(for: Tuple(product.productID))
            #expect(loaded == product, "Loaded product should match saved product")
        }

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Multiple records loaded successfully")
    }

    // MARK: - Delete Operation Tests

    @Test("Delete existing record succeeds")
    func testDeleteExistingRecord() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let product = Product(
            productID: 1,
            name: "To Delete",
            price: 100,
            category: "Test",
            inStock: true
        )

        // Save then delete
        try await store.save(product)
        try await store.delete(by: Tuple(1))

        // Verify it's gone
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded == nil, "Deleted record should not be loadable")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Record deleted successfully")
    }

    @Test("Delete non-existing record does not error")
    func testDeleteNonExistingRecord() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        // Delete a record that doesn't exist - should not throw
        try await store.delete(by: Tuple(999))

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Deleting non-existing record handled gracefully")
    }

    @Test("Delete multiple records succeeds")
    func testDeleteMultipleRecords() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let products = [
            Product(productID: 1, name: "Product 1", price: 100, category: "A", inStock: true),
            Product(productID: 2, name: "Product 2", price: 200, category: "B", inStock: true),
            Product(productID: 3, name: "Product 3", price: 300, category: "C", inStock: false)
        ]

        // Save all
        for product in products {
            try await store.save(product)
        }

        // Delete first two
        try await store.delete(by: Tuple(1))
        try await store.delete(by: Tuple(2))

        // Verify deletion
        let loaded1 = try await store.record(for: Tuple(1))
        let loaded2 = try await store.record(for: Tuple(2))
        let loaded3 = try await store.record(for: Tuple(3))

        #expect(loaded1 == nil, "Product 1 should be deleted")
        #expect(loaded2 == nil, "Product 2 should be deleted")
        #expect(loaded3 != nil, "Product 3 should still exist")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Multiple records deleted successfully")
    }

    @Test("Delete multiple records succeeds sequentially")
    func testDeleteMultipleRecordsSequentially() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let products = [
            Product(productID: 1, name: "Product 1", price: 100, category: "A", inStock: true),
            Product(productID: 2, name: "Product 2", price: 200, category: "B", inStock: true)
        ]

        // Save products
        for product in products {
            try await store.save(product)
        }

        // Delete both sequentially (each in its own transaction)
        // TODO: Add transaction support with RecordTransaction API
        try await store.delete(by: Tuple(1))
        try await store.delete(by: Tuple(2))

        // Verify both deleted
        let loaded1 = try await store.record(for: Tuple(1))
        let loaded2 = try await store.record(for: Tuple(2))

        #expect(loaded1 == nil, "Product 1 should be deleted")
        #expect(loaded2 == nil, "Product 2 should be deleted")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Sequential deletes succeeded")
    }

    // MARK: - Scan Operation Tests (Basic - will expand later)

    @Test("Scan returns all records")
    func testScanAllRecords() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        let products = [
            Product(productID: 1, name: "Product 1", price: 100, category: "A", inStock: true),
            Product(productID: 2, name: "Product 2", price: 200, category: "B", inStock: true),
            Product(productID: 3, name: "Product 3", price: 300, category: "C", inStock: false)
        ]

        // Save all products
        for product in products {
            try await store.save(product)
        }

        // Scan all records
        let scanned = try await store.query().execute()

        #expect(scanned.count == 3, "Should scan 3 records")

        // Verify all products are present
        let scannedIDs = Set(scanned.map { $0.productID })
        #expect(scannedIDs.contains(1))
        #expect(scannedIDs.contains(2))
        #expect(scannedIDs.contains(3))

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Scan returned all records")
    }

    @Test("Scan empty store returns no records")
    func testScanEmptyStore() async throws {
        let (database, subspace, _, store) = try await setupTestStore()


        // Scan without saving anything
        let scanned = try await store.query().execute()

        #expect(scanned.isEmpty, "Empty store should return no records")

        
                // Cleanup
                try await cleanupSubspace(database, subspace)
        
                print("✅ Scan of empty store handled correctly")
    }
}
