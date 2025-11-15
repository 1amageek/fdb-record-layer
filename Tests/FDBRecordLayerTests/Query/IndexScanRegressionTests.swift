import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Regression tests for critical index scan fixes
///
/// Test Coverage:
/// 1. Index scans with equality predicates (beginValues == endValues)
/// 2. Index scans with range predicates
/// 3. Multi-valued field filtering with ANY semantics
///
/// These tests prevent regression of bugs fixed in January 2025:
/// - Critical: TypedIndexScanPlan range construction returning empty results
/// - Critical: Multi-valued fields only checking first element
@Suite("Index Scan Regression Tests", .serialized)
struct IndexScanRegressionTests {

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
        let category: String
        let price: Int64
        let tags: [String]  // Multi-valued field
        let inStock: Bool

        // Explicit CodingKeys with intValue for Protobuf field numbers
        enum CodingKeys: String, CodingKey {
            case productID
            case name
            case category
            case price
            case tags
            case inStock

            var intValue: Int? {
                switch self {
                case .productID: return 1
                case .name: return 2
                case .category: return 3
                case .price: return 4
                case .tags: return 5
                case .inStock: return 6
                }
            }

            init?(intValue: Int) {
                switch intValue {
                case 1: self = .productID
                case 2: self = .name
                case 3: self = .category
                case 4: self = .price
                case 5: self = .tags
                case 6: self = .inStock
                default: return nil
                }
            }
        }

        static var recordName: String { "Product" }
        static var primaryKeyFields: [String] { ["productID"] }
        static var allFields: [String] { ["productID", "name", "category", "price", "tags", "inStock"] }

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "productID": return 1
            case "name": return 2
            case "category": return 3
            case "price": return 4
            case "tags": return 5
            case "inStock": return 6
            default: return nil
            }
        }

        func extractField(_ fieldName: String) -> [any TupleElement] {
            switch fieldName {
            case "productID": return [productID]
            case "name": return [name]
            case "category": return [category]
            case "price": return [price]
            case "tags": return tags.map { $0 as any TupleElement }
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
        return Subspace(prefix: Array("test_index_regression_\(UUID().uuidString)".utf8))
    }

    func createTestSchema() throws -> Schema {
        // Create indexes that will be used in regression tests
        let categoryIndex = Index(
            name: "product_category",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "category"),
            recordTypes: ["Product"]
        )

        let priceIndex = Index(
            name: "product_price",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "price"),
            recordTypes: ["Product"]
        )

        return Schema([Product.self], indexes: [categoryIndex, priceIndex])
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
        let statsManager = StatisticsManager(
            database: database,
            subspace: subspace.subspace("stats")
        )

        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: statsManager
        )

        // Enable indexes
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        for indexName in ["product_category", "product_price"] {
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

    // MARK: - Regression Test 1: Equality Predicate Index Scans

    @Test("REGRESSION: Index scan with equality predicate returns results")
    func testIndexScanEqualityPredicate() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert test data
        let products = [
            Product(productID: 1, name: "iPhone", category: "Electronics", price: 999, tags: ["phone", "apple"], inStock: true),
            Product(productID: 2, name: "MacBook", category: "Electronics", price: 1999, tags: ["laptop", "apple"], inStock: true),
            Product(productID: 3, name: "Book", category: "Books", price: 20, tags: ["fiction"], inStock: true),
            Product(productID: 4, name: "Pen", category: "Stationery", price: 5, tags: ["writing"], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // CRITICAL TEST: Equality predicate should use index and return results
        // Previously failed because beginValues == endValues created empty range
        let electronics = try await store.query()
            .where(\.category, is: .equals, "Electronics")
            .execute()

        #expect(electronics.count == 2, "Should find exactly 2 Electronics products")
        #expect(electronics.allSatisfy { $0.category == "Electronics" }, "All results should be Electronics")

        // Verify specific products
        let productIDs = Set(electronics.map { $0.productID })
        #expect(productIDs.contains(1), "Should contain iPhone")
        #expect(productIDs.contains(2), "Should contain MacBook")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: Equality predicate index scan")
    }

    @Test("REGRESSION: Index scan with different equality values")
    func testIndexScanMultipleEqualityValues() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert diverse categories
        let products = [
            Product(productID: 1, name: "Item A", category: "A", price: 100, tags: [], inStock: true),
            Product(productID: 2, name: "Item B", category: "B", price: 200, tags: [], inStock: true),
            Product(productID: 3, name: "Item C", category: "C", price: 300, tags: [], inStock: true),
            Product(productID: 4, name: "Item A2", category: "A", price: 150, tags: [], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // Test each category
        for (category, expectedCount) in [("A", 2), ("B", 1), ("C", 1)] {
            let results = try await store.query()
                .where(\.category, is: .equals, category)
                .execute()

            #expect(results.count == expectedCount, "Category \(category) should have \(expectedCount) products")
            #expect(results.allSatisfy { $0.category == category }, "All results should match category \(category)")
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: Multiple equality values")
    }

    // MARK: - Regression Test 2: Range Predicate Index Scans

    @Test("REGRESSION: Index scan with range predicates returns correct results")
    func testIndexScanRangePredicates() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert products with various prices
        let products = [
            Product(productID: 1, name: "Item 1", category: "A", price: 100, tags: [], inStock: true),
            Product(productID: 2, name: "Item 2", category: "A", price: 200, tags: [], inStock: true),
            Product(productID: 3, name: "Item 3", category: "A", price: 300, tags: [], inStock: true),
            Product(productID: 4, name: "Item 4", category: "A", price: 400, tags: [], inStock: true),
            Product(productID: 5, name: "Item 5", category: "A", price: 500, tags: [], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // Test: price > 200
        let greaterThan200 = try await store.query()
            .where(\.price, is: .greaterThan, Int64(200))
            .execute()

        #expect(greaterThan200.count == 3, "Should find 3 products with price > 200")
        #expect(greaterThan200.allSatisfy { $0.price > 200 }, "All results should have price > 200")

        // Test: price >= 200
        let greaterOrEqual200 = try await store.query()
            .where(\.price, is: .greaterThanOrEquals, Int64(200))
            .execute()

        #expect(greaterOrEqual200.count == 4, "Should find 4 products with price >= 200")
        #expect(greaterOrEqual200.allSatisfy { $0.price >= 200 }, "All results should have price >= 200")

        // Test: price < 300
        let lessThan300 = try await store.query()
            .where(\.price, is: .lessThan, Int64(300))
            .execute()

        #expect(lessThan300.count == 2, "Should find 2 products with price < 300")
        #expect(lessThan300.allSatisfy { $0.price < 300 }, "All results should have price < 300")

        // Test: price <= 300
        let lessOrEqual300 = try await store.query()
            .where(\.price, is: .lessThanOrEquals, Int64(300))
            .execute()

        #expect(lessOrEqual300.count == 3, "Should find 3 products with price <= 300")
        #expect(lessOrEqual300.allSatisfy { $0.price <= 300 }, "All results should have price <= 300")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: Range predicate index scans")
    }

    // MARK: - Regression Test 3: Multi-Valued Field Filtering

    @Test("REGRESSION: Multi-valued field filtering with ANY semantics")
    func testMultiValuedFieldFiltering() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert products with various tags
        let products = [
            Product(productID: 1, name: "Swift Book", category: "Books", price: 50,
                   tags: ["swift", "programming", "ios"], inStock: true),
            Product(productID: 2, name: "Python Guide", category: "Books", price: 45,
                   tags: ["python", "programming"], inStock: true),
            Product(productID: 3, name: "iOS App", category: "Software", price: 99,
                   tags: ["ios", "mobile", "swift"], inStock: true),
            Product(productID: 4, name: "Android App", category: "Software", price: 79,
                   tags: ["android", "mobile"], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // CRITICAL TEST: Multi-valued field should check ALL elements (ANY semantics)
        // Previously only checked first element
        // Note: We fetch all products and test the internal filtering logic
        let allProducts = try await store.query().execute()

        // Create filter component to test ANY semantics
        let recordAccess = GenericRecordAccess<Product>()

        // Test filtering for "swift" tag
        var swiftProducts: [Product] = []
        for product in allProducts {
            let filter = TypedFieldQueryComponent<Product>(
                fieldName: "tags",
                comparison: .contains,
                value: "swift"
            )
            if try filter.matches(record: product, recordAccess: recordAccess) {
                swiftProducts.append(product)
            }
        }

        #expect(swiftProducts.count == 2, "Should find 2 products with 'swift' tag")

        // Verify that "swift" appears in tags (at any position)
        for product in swiftProducts {
            #expect(product.tags.contains("swift"), "Product \(product.name) should have 'swift' in tags")
        }

        // Verify specific products
        let productIDs = Set(swiftProducts.map { $0.productID })
        #expect(productIDs.contains(1), "Should contain Swift Book (swift at index 0)")
        #expect(productIDs.contains(3), "Should contain iOS App (swift at index 2)")

        // Test with tag at different positions
        var programmingProducts: [Product] = []
        for product in allProducts {
            let filter = TypedFieldQueryComponent<Product>(
                fieldName: "tags",
                comparison: .contains,
                value: "programming"
            )
            if try filter.matches(record: product, recordAccess: recordAccess) {
                programmingProducts.append(product)
            }
        }

        #expect(programmingProducts.count == 2, "Should find 2 products with 'programming' tag")

        var iosProducts: [Product] = []
        for product in allProducts {
            let filter = TypedFieldQueryComponent<Product>(
                fieldName: "tags",
                comparison: .contains,
                value: "ios"
            )
            if try filter.matches(record: product, recordAccess: recordAccess) {
                iosProducts.append(product)
            }
        }

        #expect(iosProducts.count == 2, "Should find 2 products with 'ios' tag")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: Multi-valued field filtering")
    }

    @Test("REGRESSION: Multi-valued field with equality semantics")
    func testMultiValuedFieldEquality() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert products
        let products = [
            Product(productID: 1, name: "Item 1", category: "A", price: 100,
                   tags: ["alpha", "beta", "gamma"], inStock: true),
            Product(productID: 2, name: "Item 2", category: "A", price: 200,
                   tags: ["delta", "epsilon"], inStock: true),
            Product(productID: 3, name: "Item 3", category: "A", price: 300,
                   tags: ["beta", "zeta"], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // Test equality with multi-valued field (ANY semantics)
        let allProducts = try await store.query().execute()
        let recordAccess = GenericRecordAccess<Product>()

        var betaProducts: [Product] = []
        for product in allProducts {
            let filter = TypedFieldQueryComponent<Product>(
                fieldName: "tags",
                comparison: .equals,
                value: "beta"
            )
            if try filter.matches(record: product, recordAccess: recordAccess) {
                betaProducts.append(product)
            }
        }

        #expect(betaProducts.count == 2, "Should find 2 products with 'beta' tag")

        for product in betaProducts {
            #expect(product.tags.contains("beta"), "Product should have 'beta' in tags")
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: Multi-valued field equality")
    }

    // MARK: - Edge Case Tests

    @Test("REGRESSION: Index scan with no matching results")
    func testIndexScanNoResults() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert products
        let products = [
            Product(productID: 1, name: "Item 1", category: "A", price: 100, tags: [], inStock: true),
            Product(productID: 2, name: "Item 2", category: "B", price: 200, tags: [], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // Query for non-existent category
        let results = try await store.query()
            .where(\.category, is: .equals, "NonExistent")
            .execute()

        #expect(results.isEmpty, "Should return empty array (not crash)")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: No matching results")
    }

    @Test("REGRESSION: Index scan with single result")
    func testIndexScanSingleResult() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert products with unique categories
        let products = [
            Product(productID: 1, name: "Unique Item", category: "Unique", price: 100, tags: [], inStock: true),
            Product(productID: 2, name: "Common Item", category: "Common", price: 200, tags: [], inStock: true),
            Product(productID: 3, name: "Common Item 2", category: "Common", price: 300, tags: [], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // Query for unique category (single result)
        let results = try await store.query()
            .where(\.category, is: .equals, "Unique")
            .execute()

        #expect(results.count == 1, "Should find exactly 1 result")
        #expect(results[0].productID == 1, "Should find the unique item")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: Single result")
    }

    @Test("REGRESSION: Empty tags array filtering")
    func testEmptyArrayFiltering() async throws {
        let (database, subspace, _, store) = try await setupStore()

        // Insert products with empty and non-empty tags
        let products = [
            Product(productID: 1, name: "No Tags", category: "A", price: 100, tags: [], inStock: true),
            Product(productID: 2, name: "Has Tags", category: "A", price: 200, tags: ["tag1"], inStock: true),
        ]

        for product in products {
            try await store.save(product)
        }

        // Query for tag in empty array (should not match)
        let allProducts = try await store.query().execute()
        let recordAccess = GenericRecordAccess<Product>()

        var matchedProducts: [Product] = []
        for product in allProducts {
            let filter = TypedFieldQueryComponent<Product>(
                fieldName: "tags",
                comparison: .contains,
                value: "nonexistent"
            )
            if try filter.matches(record: product, recordAccess: recordAccess) {
                matchedProducts.append(product)
            }
        }

        #expect(matchedProducts.isEmpty, "Should not match products with empty tags or missing tag")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ REGRESSION TEST PASSED: Empty array filtering")
    }
}
