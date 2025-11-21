import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordCore
@testable import FDBRecordLayer

@Suite("Vector Post-Filter Tests")
struct VectorPostFilterTests {

    // MARK: - Test Model

    @Recordable
    struct Product {
        #PrimaryKey<Product>([\.productID])

        var productID: Int64
        var name: String
        var category: String
        var embedding: [Float32]
    }

    // MARK: - Helper Functions

    private func setupDatabase() throws -> any DatabaseProtocol {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized - this is fine
        }
        return try FDBClient.openDatabase()
    }

    private func createStore(database: any DatabaseProtocol) async throws -> RecordStore<Product> {
        // Create vector index manually
        let vectorIndex = Index(
            name: "Product_embedding_index",
            type: .vector,
            rootExpression: FieldKeyExpression(fieldName: "embedding"),
            recordTypes: Set(["Product"]),
            options: IndexOptions(vectorOptions: VectorIndexOptions(dimensions: 3, metric: .cosine))
        )

        // Create schema with flatScan strategy
        let schema = Schema(
            [Product.self],
            indexes: [vectorIndex],
            indexConfigurations: [
                IndexConfiguration(
                    indexName: "Product_embedding_index",
                    vectorStrategy: .flatScan
                )
            ]
        )

        // Create RecordStore with unique subspace
        let testSubspace = Subspace(prefix: Tuple("test", "vector_post_filter", UUID().uuidString).pack())
        let store = RecordStore<Product>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Enable and mark index as readable
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: testSubspace
        )

        try await indexStateManager.enable("Product_embedding_index")
        try await indexStateManager.makeReadable("Product_embedding_index")

        return store
    }

    private func insertProducts(store: RecordStore<Product>) async throws {
        // Insert 20 products:
        // - 5 in "Electronics" (25% selectivity)
        // - 5 in "Books" (25% selectivity)
        // - 10 in "Other" (50% selectivity)

        let products: [Product] = [
            // Electronics (25%)
            Product(productID: 1, name: "Laptop", category: "Electronics", embedding: [0.1, 0.2, 0.3]),
            Product(productID: 2, name: "Phone", category: "Electronics", embedding: [0.15, 0.25, 0.35]),
            Product(productID: 3, name: "Tablet", category: "Electronics", embedding: [0.2, 0.3, 0.4]),
            Product(productID: 4, name: "Monitor", category: "Electronics", embedding: [0.25, 0.35, 0.45]),
            Product(productID: 5, name: "Keyboard", category: "Electronics", embedding: [0.3, 0.4, 0.5]),

            // Books (25%)
            Product(productID: 6, name: "Novel", category: "Books", embedding: [0.4, 0.5, 0.6]),
            Product(productID: 7, name: "Textbook", category: "Books", embedding: [0.45, 0.55, 0.65]),
            Product(productID: 8, name: "Magazine", category: "Books", embedding: [0.5, 0.6, 0.7]),
            Product(productID: 9, name: "Comic", category: "Books", embedding: [0.55, 0.65, 0.75]),
            Product(productID: 10, name: "Dictionary", category: "Books", embedding: [0.6, 0.7, 0.8]),

            // Other (50%)
            Product(productID: 11, name: "Chair", category: "Furniture", embedding: [0.11, 0.21, 0.31]),
            Product(productID: 12, name: "Desk", category: "Furniture", embedding: [0.12, 0.22, 0.32]),
            Product(productID: 13, name: "Lamp", category: "Furniture", embedding: [0.13, 0.23, 0.33]),
            Product(productID: 14, name: "Rug", category: "Furniture", embedding: [0.14, 0.24, 0.34]),
            Product(productID: 15, name: "Pillow", category: "Furniture", embedding: [0.16, 0.26, 0.36]),
            Product(productID: 16, name: "Shirt", category: "Clothing", embedding: [0.17, 0.27, 0.37]),
            Product(productID: 17, name: "Pants", category: "Clothing", embedding: [0.18, 0.28, 0.38]),
            Product(productID: 18, name: "Shoes", category: "Clothing", embedding: [0.19, 0.29, 0.39]),
            Product(productID: 19, name: "Hat", category: "Clothing", embedding: [0.21, 0.31, 0.41]),
            Product(productID: 20, name: "Jacket", category: "Clothing", embedding: [0.22, 0.32, 0.42]),
        ]

        for product in products {
            try await store.save(product)
        }
    }

    // MARK: - Tests

    @Test("Post-filter ensures k results with 25% selectivity (Electronics)")
    func testPostFilterWith25PercentSelectivity() async throws {
        let database = try setupDatabase()
        let store = try await createStore(database: database)

        try await insertProducts(store: store)

        // Query: k=10, filter for "Electronics" (5 out of 20 = 25% selectivity)
        // Expected: Should return 5 results (all Electronics products)
        let queryEmbedding: [Float32] = [0.1, 0.2, 0.3]

        let results = try await store.query()
            .nearestNeighbors(k: 10, to: queryEmbedding, using: \.embedding)
            .filter(TypedFieldQueryComponent<Product>(
                fieldName: "category",
                comparison: .equals,
                value: "Electronics"
            ))
            .execute()

        #expect(results.count == 5, "Should return all 5 Electronics products")

        // Verify all results are Electronics
        for (product, _) in results {
            #expect(product.category == "Electronics", "All results should be Electronics")
        }
    }

    @Test("Post-filter ensures k results with Books category")
    func testPostFilterWithBooksCategory() async throws {
        let database = try setupDatabase()
        let store = try await createStore(database: database)

        try await insertProducts(store: store)

        // Query: k=10, filter for "Books" (5 out of 20 = 25% selectivity)
        // Expected: Should return 5 results (all Books products)
        let queryEmbedding: [Float32] = [0.4, 0.5, 0.6]

        let results = try await store.query()
            .nearestNeighbors(k: 10, to: queryEmbedding, using: \.embedding)
            .filter(TypedFieldQueryComponent<Product>(
                fieldName: "category",
                comparison: .equals,
                value: "Books"
            ))
            .execute()

        #expect(results.count == 5, "Should return all 5 Books products")

        // Verify all results are Books
        for (product, _) in results {
            #expect(product.category == "Books", "All results should be Books")
        }
    }

    @Test("Post-filter without filter returns exactly k results")
    func testNoFilterReturnsExactlyK() async throws {
        let database = try setupDatabase()
        let store = try await createStore(database: database)

        try await insertProducts(store: store)

        // Query: k=10, no filter
        // Expected: Should return exactly 10 results
        let queryEmbedding: [Float32] = [0.1, 0.2, 0.3]

        let results = try await store.query()
            .nearestNeighbors(k: 10, to: queryEmbedding, using: \.embedding)
            .execute()

        #expect(results.count == 10, "Should return exactly 10 results")
    }

    @Test("Post-filter with k > total matching records returns all matches")
    func testPostFilterWithKGreaterThanTotalMatches() async throws {
        let database = try setupDatabase()
        let store = try await createStore(database: database)

        try await insertProducts(store: store)

        // Query: k=100, filter for "Electronics" (only 5 match)
        // Expected: Should return 5 results (all available Electronics)
        let queryEmbedding: [Float32] = [0.1, 0.2, 0.3]

        let results = try await store.query()
            .nearestNeighbors(k: 100, to: queryEmbedding, using: \.embedding)
            .filter(TypedFieldQueryComponent<Product>(
                fieldName: "category",
                comparison: .equals,
                value: "Electronics"
            ))
            .execute()

        #expect(results.count == 5, "Should return all 5 Electronics products (< k)")
    }

    @Test("Post-filter loop terminates with maxAttempts")
    func testPostFilterLoopTerminatesWithMaxAttempts() async throws {
        let database = try setupDatabase()
        let store = try await createStore(database: database)

        // Insert only 1 product
        let product = Product(
            productID: 1,
            name: "Laptop",
            category: "Electronics",
            embedding: [0.1, 0.2, 0.3]
        )
        try await store.save(product)

        // Query: k=100, filter for "Electronics" (only 1 match)
        // Expected: Should return 1 result and terminate (not infinite loop)
        let queryEmbedding: [Float32] = [0.1, 0.2, 0.3]

        let results = try await store.query()
            .nearestNeighbors(k: 100, to: queryEmbedding, using: \.embedding)
            .filter(TypedFieldQueryComponent<Product>(
                fieldName: "category",
                comparison: .equals,
                value: "Electronics"
            ))
            .execute()

        #expect(results.count == 1, "Should return 1 result and terminate")
    }
}
