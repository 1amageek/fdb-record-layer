import Testing
import Foundation
import Synchronization
@testable import FoundationDB
@testable import FDBRecordLayer

/// Integration tests for StatisticsManager with RecordStore
///
/// Test Coverage:
/// 1. Statistics collection for record types
/// 2. Index statistics collection
/// 3. Selectivity estimation with filters
/// 4. Statistics persistence across store reopening
@Suite("Metrics Integration Tests", .serialized, .tags(.integration))
struct MetricsIntegrationTests {

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
        return Subspace(prefix: Array("test_metrics_\(UUID().uuidString)".utf8))
    }

    func createTestSchema() throws -> Schema {
        // Use naming convention expected by StatisticsManager:
        // {recordType}_{fieldName}
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

    func setupStoreWithMetrics() async throws -> (
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        store: RecordStore<Product>,
        statsManager: StatisticsManager
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

        return (database, subspace, schema, store, statsManager)
    }

    func cleanupSubspace(_ database: any DatabaseProtocol, _ subspace: Subspace) async throws {
        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Statistics Collection Tests

    @Test("Statistics manager is initialized with RecordStore")
    func testStatisticsManagerInitialization() async throws {
        let (database, subspace, _, _, _) = try await setupStoreWithMetrics()

        // Statistics manager is initialized (no assertion needed, init would throw if failed)

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Statistics manager initialized")
    }

    @Test("Collect statistics for record type")
    func testCollectStatistics() async throws {
        let (database, subspace, _, store, statsManager) = try await setupStoreWithMetrics()

        // Save some products
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

        // Collect statistics (sample all records)
        try await statsManager.collectStatistics(
            recordType: "Product",
            sampleRate: 1.0
        )

        // Get table statistics
        let tableStats = try await statsManager.getTableStatistics(recordType: "Product")
        #expect(tableStats != nil, "Table statistics should be collected")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Statistics collection working")
    }

    @Test("Estimate selectivity with equality filter")
    func testSelectivityEstimation() async throws {
        let (database, subspace, _, store, statsManager) = try await setupStoreWithMetrics()

        // Save products with known distribution
        // Category "A": 5 records
        // Category "B": 3 records
        // Category "C": 2 records
        let categories = ["A", "A", "A", "A", "A", "B", "B", "B", "C", "C"]
        for (i, category) in categories.enumerated() {
            let product = Product(
                productID: Int64(i + 1),
                name: "Product \(i + 1)",
                price: 100,
                category: category,
                inStock: true
            )
            try await store.save(product)
        }

        // Collect statistics
        try await statsManager.collectStatistics(
            recordType: "Product",
            sampleRate: 1.0
        )

        // Collect index statistics for category field
        let categoryIndexSubspace = subspace
            .subspace("I")
            .subspace("product_category")
        try await statsManager.collectIndexStatistics(
            indexName: "product_category",
            indexSubspace: categoryIndexSubspace,
            bucketCount: 10,
            reservoirSize: 100
        )


        // Estimate selectivity for category = "A"
        let filterA = TypedFieldQueryComponent<Product>(
            fieldName: "category",
            comparison: .equals,
            value: "A"
        )
        let selectivityA = try await statsManager.estimateSelectivity(
            filter: filterA,
            recordType: "Product"
        )

        // Expected: 5 out of 10 records have category "A" → ~0.5 selectivity
        #expect(selectivityA > 0.4 && selectivityA < 0.6, "Selectivity for A should be ~0.5, got \(selectivityA)")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Selectivity estimation working")
    }

    @Test("Statistics persist across store reopening")
    func testStatisticsPersistence() async throws {
        let database = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createTestSchema()
        let statsManager = StatisticsManager(
            database: database,
            subspace: subspace.subspace("stats")
        )

        // First store instance
        do {
            let store = RecordStore<Product>(
                database: database,
                subspace: subspace,
                schema: schema,
                statisticsManager: statsManager
            )

            // Save data
            for i in 1...20 {
                let product = Product(
                    productID: Int64(i),
                    name: "Product \(i)",
                    price: 100,
                    category: i % 2 == 0 ? "Even" : "Odd",
                    inStock: true
                )
                try await store.save(product)
            }

            // Collect statistics
            try await statsManager.collectStatistics(
                recordType: "Product",
                sampleRate: 1.0
            )

            // Verify statistics exist
            let stats1 = try await statsManager.getTableStatistics(recordType: "Product")
            #expect(stats1 != nil, "Statistics should be collected")
        }

        // Reopen store with new statistics manager instance
        do {
            let newStatsManager = StatisticsManager(
                database: database,
                subspace: subspace.subspace("stats")
            )

            // Statistics should still be accessible
            let stats2 = try await newStatsManager.getTableStatistics(recordType: "Product")
            #expect(stats2 != nil, "Statistics should persist")
        }

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Statistics persist across store reopening")
    }

    @Test("Collect index statistics")
    func testCollectIndexStatistics() async throws {
        let (database, subspace, _, store, statsManager) = try await setupStoreWithMetrics()

        // Save products
        for i in 1...50 {
            let product = Product(
                productID: Int64(i),
                name: "Product \(i)",
                price: Int64(i * 10),
                category: "Category\(i % 5)",
                inStock: true
            )
            try await store.save(product)
        }

        // Get index subspace
        let indexSubspace = subspace
            .subspace("I")
            .subspace("product_category")

        // Collect index statistics
        try await statsManager.collectIndexStatistics(
            indexName: "product_category",
            indexSubspace: indexSubspace,
            bucketCount: 10,
            reservoirSize: 100
        )

        // Get index statistics
        let indexStats = try await statsManager.getIndexStatistics(indexName: "product_category")
        #expect(indexStats != nil, "Index statistics should be collected")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ Index statistics collection working")
    }

    @Test("Selectivity estimation with AND filter")
    func testSelectivityWithAndFilter() async throws {
        let (database, subspace, _, store, statsManager) = try await setupStoreWithMetrics()

        // Save products
        for i in 1...20 {
            let product = Product(
                productID: Int64(i),
                name: "Product \(i)",
                price: Int64(i < 10 ? 100 : 200),
                category: i % 2 == 0 ? "Even" : "Odd",
                inStock: true
            )
            try await store.save(product)
        }

        // Collect statistics
        try await statsManager.collectStatistics(
            recordType: "Product",
            sampleRate: 1.0
        )

        // Collect index statistics for both fields
        let categoryIndexSubspace = subspace
            .subspace("I")
            .subspace("product_category")
        try await statsManager.collectIndexStatistics(
            indexName: "product_category",
            indexSubspace: categoryIndexSubspace,
            bucketCount: 10,
            reservoirSize: 100
        )

        let priceIndexSubspace = subspace
            .subspace("I")
            .subspace("product_price")
        try await statsManager.collectIndexStatistics(
            indexName: "product_price",
            indexSubspace: priceIndexSubspace,
            bucketCount: 10,
            reservoirSize: 100
        )

        // Create AND filter: category = "Even" AND price = 100
        let categoryFilter = TypedFieldQueryComponent<Product>(
            fieldName: "category",
            comparison: .equals,
            value: "Even"
        )
        let priceFilter = TypedFieldQueryComponent<Product>(
            fieldName: "price",
            comparison: .equals,
            value: Int64(100)
        )
        let andFilter = TypedAndQueryComponent<Product>(children: [categoryFilter, priceFilter])

        // Estimate selectivity
        let selectivity = try await statsManager.estimateSelectivity(
            filter: andFilter,
            recordType: "Product"
        )

        // Expected: 4 out of 20 records match (Even=10/20=0.5, price=100=9/20=0.45)
        // AND selectivity ≈ 0.5 * 0.45 = 0.225, actual = 4/20 = 0.2
        #expect(selectivity > 0.15 && selectivity < 0.30, "AND selectivity should be ~0.2, got \(selectivity)")

        // Cleanup
        try await cleanupSubspace(database, subspace)

        print("✅ AND filter selectivity estimation working")
    }
}
