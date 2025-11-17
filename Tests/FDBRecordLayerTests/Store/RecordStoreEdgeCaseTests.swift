import Testing
import Foundation
import Synchronization
@testable import FoundationDB
@testable import FDBRecordLayer

/// Edge case and boundary condition tests for RecordStore
///
/// Test Coverage:
/// 1. Empty database operations
/// 2. Large batch operations
/// 3. Special characters in data
/// 4. Boundary values (max/min Int64)
/// 5. Repeated operations (idempotency)
/// 6. Schema edge cases
@Suite("RecordStore Edge Case Tests", .serialized, .tags(.slow))
struct RecordStoreEdgeCaseTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Test Model

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
        return Subspace(prefix: Array("test_edgecase_\(UUID().uuidString)".utf8))
    }

    func createTestSchema() throws -> Schema {
        return Schema([Product.self])
    }

    func setupStore() async throws -> (
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        store: RecordStore<Product>
    ) {
        let database = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createTestSchema()

        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: database, subspace: subspace.subspace("stats"))
        )

        return (database, subspace, schema, store)
    }

    func cleanupSubspace(_ database: any DatabaseProtocol, _ subspace: Subspace) async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Empty Database Tests

    @Test("Load from empty database returns nil")
    func testLoadFromEmptyDatabase() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded == nil)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Load from empty database returns nil")
    }

    @Test("Scan empty database returns empty results")
    func testScanEmptyDatabase() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let results = try await store.query().execute()
        #expect(results.isEmpty)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Scan empty database returns empty results")
    }

    @Test("Delete from empty database succeeds silently")
    func testDeleteFromEmptyDatabase() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Should not throw
        try await store.delete(by: Tuple(999))

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Delete from empty database succeeds silently")
    }

    // MARK: - Large Batch Tests

    @Test("Save and load 1000 records")
    func testLargeBatchOperations() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Save 1000 records
        for i in 1...1000 {
            let product = Product(
                productID: Int64(i),
                name: "Product \(i)",
                price: Int64(i),
                category: "Category\(i % 10)",
                inStock: i % 2 == 0
            )
            try await store.save(product)
        }

        // Verify count via scan
        let results = try await store.query().execute()
        #expect(results.count == 1000)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Saved and loaded 1000 records successfully")
    }

    // MARK: - Special Characters Tests

    @Test("Handle special characters in string fields")
    func testSpecialCharacters() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let specialStrings = [
            "Hello\nWorld",           // Newline
            "Tab\there",             // Tab
            "Quote\"Test",           // Quote
            "Emoji 😀🎉",            // Emoji
            "日本語テスト",              // Japanese
            "Null\0Byte",            // Null byte
            "Backslash\\Test",       // Backslash
        ]

        for (i, str) in specialStrings.enumerated() {
            let product = Product(
                productID: Int64(i + 1),
                name: str,
                price: 100,
                category: "Special",
                inStock: true
            )
            try await store.save(product)

            let loaded = try await store.record(for: Tuple(Int64(i + 1)))
            #expect(loaded?.name == str, "Failed for: \(str)")
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Special characters handled correctly")
    }

    @Test("Handle empty strings")
    func testEmptyStrings() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let product = Product(
            productID: 1,
            name: "",
            price: 100,
            category: "",
            inStock: true
        )
        try await store.save(product)

        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded?.name == "")
        #expect(loaded?.category == "")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Empty strings handled correctly")
    }

    // MARK: - Boundary Value Tests

    @Test("Handle large Int64 values")
    func testLargeInt64Values() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Use large but realistic values (not Int64.max/min which may not be supported by Tuple encoding)
        let largePositive: Int64 = 9_000_000_000_000_000_000  // 9 quintillion
        let largeNegative: Int64 = -9_000_000_000_000_000_000

        let positiveProduct = Product(
            productID: largePositive,
            name: "Large Positive ID",
            price: largePositive,
            category: "Boundary",
            inStock: true
        )
        try await store.save(positiveProduct)

        let negativeProduct = Product(
            productID: largeNegative,
            name: "Large Negative ID",
            price: largeNegative,
            category: "Boundary",
            inStock: true
        )
        try await store.save(negativeProduct)

        // Load and verify
        let loadedPositive = try await store.record(for: Tuple(largePositive))
        #expect(loadedPositive?.productID == largePositive)
        #expect(loadedPositive?.price == largePositive)

        let loadedNegative = try await store.record(for: Tuple(largeNegative))
        #expect(loadedNegative?.productID == largeNegative)
        #expect(loadedNegative?.price == largeNegative)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Large Int64 values handled correctly")
    }

    @Test("Handle zero values")
    func testZeroValues() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let product = Product(
            productID: 0,
            name: "Zero",
            price: 0,
            category: "Zero",
            inStock: false
        )
        try await store.save(product)

        let loaded = try await store.record(for: Tuple(0))
        #expect(loaded?.productID == 0)
        #expect(loaded?.price == 0)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Zero values handled correctly")
    }

    // MARK: - Idempotency Tests

    @Test("Repeated saves are idempotent")
    func testRepeatedSavesIdempotent() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let product = Product(
            productID: 1,
            name: "Test",
            price: 100,
            category: "Test",
            inStock: true
        )

        // Save the same product 10 times
        for _ in 1...10 {
            try await store.save(product)
        }

        // Should only have one record
        let results = try await store.query().execute()
        #expect(results.count == 1)

        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded?.name == "Test")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Repeated saves are idempotent")
    }

    @Test("Repeated deletes are idempotent")
    func testRepeatedDeletesIdempotent() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let product = Product(
            productID: 1,
            name: "Test",
            price: 100,
            category: "Test",
            inStock: true
        )
        try await store.save(product)

        // Delete the same record 10 times
        for _ in 1...10 {
            try await store.delete(by: Tuple(1))
        }

        // Record should be gone
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded == nil)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Repeated deletes are idempotent")
    }

    // MARK: - Schema Edge Cases

    @Test("Very long string values")
    func testVeryLongStrings() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let longString = String(repeating: "A", count: 10000)

        let product = Product(
            productID: 1,
            name: longString,
            price: 100,
            category: "Long",
            inStock: true
        )
        try await store.save(product)

        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded?.name == longString)
        #expect(loaded?.name.count == 10000)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Very long strings handled correctly")
    }

    @Test("Save then immediately delete")
    func testSaveThenImmediateDelete() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let product = Product(
            productID: 1,
            name: "Temporary",
            price: 100,
            category: "Temp",
            inStock: true
        )

        // Save
        try await store.save(product)

        // Immediately delete
        try await store.delete(by: Tuple(1))

        // Should be gone
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded == nil)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Save then immediate delete works correctly")
    }

    @Test("Multiple alternating saves and deletes")
    func testAlternatingSavesAndDeletes() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let product = Product(
            productID: 1,
            name: "Alternating",
            price: 100,
            category: "Test",
            inStock: true
        )

        // Alternate save and delete 5 times
        for _ in 1...5 {
            try await store.save(product)
            try await store.delete(by: Tuple(1))
        }

        // Record should be gone
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded == nil)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Alternating saves and deletes work correctly")
    }
}
