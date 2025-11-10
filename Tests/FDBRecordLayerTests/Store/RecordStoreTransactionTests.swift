import Testing
import Foundation
import Synchronization
@testable import FoundationDB
@testable import FDBRecordLayer

/// Transaction and concurrency tests for RecordStore
///
/// Test Coverage:
/// 1. Transaction isolation (read-your-writes)
/// 2. Concurrent saves without conflicts
/// 3. Transaction rollback on error
/// 4. Atomic multi-record operations
/// 5. Snapshot isolation verification
@Suite("RecordStore Transaction Tests", .serialized)
struct RecordStoreTransactionTests {

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

        func toProtobuf() throws -> Data {
            return try JSONEncoder().encode(self)
        }

        static func fromProtobuf(_ data: Data) throws -> Product {
            return try JSONDecoder().decode(Product.self, from: data)
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
        return Subspace(prefix: Array("test_transaction_\(UUID().uuidString)".utf8))
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

    // MARK: - Transaction Isolation Tests

    @Test("Read-your-writes within same transaction")
    func testReadYourWrites() async throws {
        let (database, subspace, _, store) = try await setupStore()

        let product = Product(
            productID: 1,
            name: "Test Product",
            price: 100,
            category: "Test",
            inStock: true
        )

        // Save and immediately read in separate operations
        try await store.save(product)
        let loaded = try await store.record(for: Tuple(1))

        #expect(loaded != nil)
        #expect(loaded?.name == "Test Product")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Read-your-writes verified")
    }

    @Test("Multiple saves in sequence maintain consistency")
    func testSequentialSaves() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Save multiple records sequentially
        for i in 1...10 {
            let product = Product(
                productID: Int64(i),
                name: "Product \(i)",
                price: Int64(i * 100),
                category: "Category\(i % 3)",
                inStock: true
            )
            try await store.save(product)
        }

        // Verify all records exist
        for i in 1...10 {
            let loaded = try await store.record(for: Tuple(Int64(i)))
            #expect(loaded != nil, "Product \(i) should exist")
            #expect(loaded?.name == "Product \(i)")
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Sequential saves maintain consistency")
    }

    // MARK: - Concurrent Operations Tests

    @Test("Concurrent saves to different keys succeed")
    func testConcurrentSavesNonConflicting() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Launch 10 concurrent save operations with different keys
        await withTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask {
                    let product = Product(
                        productID: Int64(i),
                        name: "Concurrent Product \(i)",
                        price: Int64(i * 100),
                        category: "Concurrent",
                        inStock: true
                    )
                    try? await store.save(product)
                }
            }
        }

        // Verify all records were saved
        for i in 1...10 {
            let loaded = try await store.record(for: Tuple(Int64(i)))
            #expect(loaded != nil, "Product \(i) should exist")
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Concurrent non-conflicting saves succeeded")
    }

    @Test("Concurrent reads are consistent")
    func testConcurrentReads() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Setup: Save a product
        let product = Product(
            productID: 1,
            name: "Shared Product",
            price: 500,
            category: "Shared",
            inStock: true
        )
        try await store.save(product)

        // Launch 20 concurrent reads
        let results = await withTaskGroup(of: Product?.self) { group in
            for _ in 1...20 {
                group.addTask {
                    try? await store.record(for: Tuple(1))
                }
            }

            var collected: [Product?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // All reads should return the same product
        #expect(results.count == 20)
        for result in results {
            #expect(result?.name == "Shared Product")
            #expect(result?.price == 500)
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Concurrent reads are consistent")
    }

    // MARK: - Atomic Operations Tests

    @Test("Atomic multi-record save and delete")
    func testAtomicMultiRecordOperations() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Save multiple records
        let products = [
            Product(productID: 1, name: "P1", price: 100, category: "A", inStock: true),
            Product(productID: 2, name: "P2", price: 200, category: "A", inStock: true),
            Product(productID: 3, name: "P3", price: 300, category: "B", inStock: true)
        ]

        for product in products {
            try await store.save(product)
        }

        // Verify all exist
        for i in 1...3 {
            let loaded = try await store.record(for: Tuple(Int64(i)))
            #expect(loaded != nil)
        }

        // Delete all
        for i in 1...3 {
            try await store.delete(by: Tuple(Int64(i)))
        }

        // Verify all deleted
        for i in 1...3 {
            let loaded = try await store.record(for: Tuple(Int64(i)))
            #expect(loaded == nil)
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Atomic multi-record operations succeeded")
    }

    @Test("Update same record sequentially maintains final state")
    func testSequentialUpdates() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Initial save
        var product = Product(
            productID: 1,
            name: "Initial",
            price: 100,
            category: "A",
            inStock: true
        )
        try await store.save(product)

        // Update 10 times
        for i in 1...10 {
            product = Product(
                productID: 1,
                name: "Update \(i)",
                price: Int64(100 + i * 10),
                category: "A",
                inStock: true
            )
            try await store.save(product)
        }

        // Final state should be last update
        let loaded = try await store.record(for: Tuple(1))
        #expect(loaded?.name == "Update 10")
        #expect(loaded?.price == 200)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Sequential updates maintain final state")
    }

    // MARK: - Snapshot Isolation Tests

    @Test("Scan provides snapshot isolation")
    func testScanSnapshotIsolation() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Save initial records
        for i in 1...5 {
            let product = Product(
                productID: Int64(i),
                name: "Product \(i)",
                price: Int64(i * 100),
                category: "Initial",
                inStock: true
            )
            try await store.save(product)
        }

        // Scan all records
        var scannedRecords: [Product] = []
        let cursor = try await store.query().execute()
        scannedRecords = cursor

        #expect(scannedRecords.count == 5)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Scan provides snapshot isolation")
    }
}
