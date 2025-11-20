import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Debug test to understand index key structure
@Suite("Debug Index Keys", .serialized)
struct DebugIndexKeysTests {

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized
        }
    }

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

    @Test("Debug: Manually write and read index entry")
    func testManualIndexEntry() async throws {
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_debug_\(UUID().uuidString)".utf8))

        let _ = Product(
            productID: 1,
            name: "Laptop",
            price: 1500,
            category: "Electronics",
            inStock: true
        )

        try await database.withTransaction { transaction in

            // Build index key manually (same logic as ValueIndexMaintainer)
            let indexSubspace = subspace.subspace("I")
            let indexNameSubspace = indexSubspace.subspace("product_by_category")

            // Index key structure: (indexed_value, primary_key)
            let indexKey = indexNameSubspace.pack(Tuple("Electronics", 1))
            let indexValue = FDB.Bytes()  // Empty value

            print("📝 Writing index entry:")
            print("  Subspace: \(subspace.prefix.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("  Index key bytes: \(indexKey.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("  Index key: \(indexKey)")

            // Write index entry
            transaction.setValue(indexValue, for: indexKey)
        }

        // Read back in a new transaction
        try await database.withTransaction { transaction in

            let indexSubspace = subspace.subspace("I")
            let indexNameSubspace = indexSubspace.subspace("product_by_category")
            let rangeSubspace = indexNameSubspace.subspace("Electronics")
            let (begin, end) = rangeSubspace.range()

            print("\n🔍 Reading index entries:")
            print("  Begin key: \(begin.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("  End key: \(end.map { String(format: "%02x", $0) }.joined(separator: " "))")

            var count = 0
            for try await (key, _) in transaction.getRange(begin: begin, end: end) {
                count += 1
                print("  Found entry \(count):")
                print("    Key bytes: \(key.map { String(format: "%02x", $0) }.joined(separator: " "))")
                print("    Key: \(key)")
            }

            print("\n✅ Total entries found: \(count)")
            #expect(count == 1, "Should find 1 index entry")
        }

        // Cleanup
        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("Debug: RecordStore save with index")
    func testRecordStoreSaveWithIndex() async throws {
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_debug_store_\(UUID().uuidString)".utf8))

        // Create schema with index
        let categoryIndex = Index(
            name: "product_by_category",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "category"),
            recordTypes: ["Product"]
        )
        let schema = Schema([Product.self], indexes: [categoryIndex])

        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: database, subspace: subspace.subspace("stats"))
        )

        // Enable index
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        try await indexStateManager.enable("product_by_category")
        try await indexStateManager.makeReadable("product_by_category")

        let product = Product(
            productID: 1,
            name: "Laptop",
            price: 1500,
            category: "Electronics",
            inStock: true
        )

        print("\n📦 Saving product via RecordStore...")
        try await store.save(product)

        // Check if record was saved
        let loaded = try await store.record(for: Tuple(1))
        print("  Record saved: \(loaded != nil)")

        // Check index entries manually
        try await database.withTransaction { transaction in

            let indexSubspace = subspace.subspace("I")
            let indexNameSubspace = indexSubspace.subspace("product_by_category")
            let rangeSubspace = indexNameSubspace.subspace("Electronics")
            let (begin, end) = rangeSubspace.range()

            print("\n🔍 Checking index entries:")
            print("  Index subspace: /I/product_by_category/Electronics/")
            print("  Begin: \(begin.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("  End: \(end.map { String(format: "%02x", $0) }.joined(separator: " "))")

            var count = 0
            for try await (key, _) in transaction.getRange(begin: begin, end: end) {
                count += 1
                print("  Entry \(count): \(key.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }

            print("\n✅ Index entries found: \(count)")
            #expect(count == 1, "Should have 1 index entry for Electronics")
        }

        // Cleanup
        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }
}
