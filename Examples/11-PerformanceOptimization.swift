// Example 11: Performance Optimization
// This example demonstrates performance optimization techniques including
// StatisticsManager, batch operations, and composite index strategies.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])
    // Composite index (category + price) for efficient multi-field queries
    #Index<Product>([\.category, \.price], name: "product_by_category_price")
    // Single index for category-only queries
    #Index<Product>([\.category], name: "product_by_category")

    var productID: Int64
    var name: String
    var category: String
    var price: Double
}

// MARK: - Helper Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Example Usage

@main
struct PerformanceOptimizationExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([Product.self])
        let subspace = Subspace(prefix: Tuple("examples", "performance", "products").pack())

        // MARK: - With StatisticsManager

        print("📊 Using StatisticsManager for query optimization...")

        let statsSubspace = Subspace(prefix: Tuple("examples", "performance", "stats").pack())
        let statisticsManager = StatisticsManager(
            database: database,
            subspace: statsSubspace
        )

        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: statisticsManager
        )

        print("✅ RecordStore with StatisticsManager initialized")

        // MARK: - Batch Insert

        print("\n🚀 Inserting 1000 products using batch operations...")

        let products = (1...1000).map { i in
            Product(
                productID: Int64(i),
                name: "Product \(i)",
                category: ["Electronics", "Furniture", "Clothing", "Books"][i % 4],
                price: Double.random(in: 10...1000)
            )
        }

        let startTime = Date()

        // Batch size: 100 records per transaction
        let batchSize = 100
        for (index, batch) in products.chunked(into: batchSize).enumerated() {
            try await database.withTransaction { transaction in
                for product in batch {
                    try await store.save(product)
                }
            }

            if (index + 1) % 5 == 0 {
                print("  ✅ Processed \((index + 1) * batchSize)/\(products.count) products")
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        print("✅ Inserted \(products.count) products in \(String(format: "%.2f", duration))s")
        print("   Throughput: \(String(format: "%.0f", Double(products.count) / duration)) products/sec")

        // MARK: - Collect Statistics

        print("\n📈 Collecting index statistics...")

        let categoryPriceIndex = schema.indexes.first { $0.name == "product_by_category_price" }!
        try await statisticsManager.collectStatistics(
            index: categoryPriceIndex,
            sampleRate: 0.01  // 1% sampling
        )

        print("✅ Statistics collected")

        // MARK: - Optimized Queries

        // ✅ Composite index is utilized (efficient)
        print("\n🔍 Query 1: Affordable Electronics (<$500)")
        let query1Start = Date()

        let affordableElectronics = try await store.query()
            .where(\.category, .equals, "Electronics")
            .where(\.price, .lessThan, 500.0)
            .execute()

        let query1Duration = Date().timeIntervalSince(query1Start)
        print("   Results: \(affordableElectronics.count) products")
        print("   Query time: \(String(format: "%.3f", query1Duration))s")
        print("   ✅ Using composite index: product_by_category_price")

        // ⚠️ Composite index cannot be used (category not specified)
        print("\n🔍 Query 2: Expensive products (>$800)")
        let query2Start = Date()

        let expensiveProducts = try await store.query()
            .where(\.price, .greaterThan, 800.0)
            .execute()

        let query2Duration = Date().timeIntervalSince(query2Start)
        print("   Results: \(expensiveProducts.count) products")
        print("   Query time: \(String(format: "%.3f", query2Duration))s")
        print("   ⚠️ Composite index not used (full scan)")

        // MARK: - Index Strategy Comparison

        print("\n📋 Index Strategy Summary:")
        print("   Composite Index (category + price):")
        print("     ✅ Efficient for: category + price range queries")
        print("     ❌ Cannot be used for: price-only queries")
        print("   Single Index (category):")
        print("     ✅ Efficient for: category-only queries")
        print("     ✅ More flexible but less specific")

        // MARK: - Transaction Size Considerations

        print("\n⚠️  Transaction Size Limits:")
        print("   - Maximum duration: 5 seconds")
        print("   - Maximum size: 10 MB")
        print("   - Batch operations keep transactions small and fast")
        print("   - Use appropriate batch size based on record size")

        print("\n🎉 Performance optimization example completed!")
    }
}
