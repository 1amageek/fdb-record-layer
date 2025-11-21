// Example 07: Vector Search with HNSW Circuit Breaker
// Demonstrates:
// - Automatic HNSW index rebuild
// - Circuit breaker pattern for error handling
// - Automatic fallback to flat scan
// - Health tracking and recovery

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])
    #Index<Product>(
        [\.embedding],
        name: "product_embedding_hnsw",
        type: .vector(VectorIndexOptions(
            dimensions: 384,
            metric: .cosine,
            strategy: .hnswBatch
        ))
    )

    var productID: Int64
    var name: String
    var category: String
    var embedding: [Float32]
}

// MARK: - Example

@main
struct VectorSearchExample {
    static func main() async throws {
        print("🔍 Example 07: Vector Search with HNSW Circuit Breaker\n")

        // Create context with vector index
        let context = try await ExampleContext(
            name: "VectorSearch",
            recordType: Product.self
        )

        try await context.run { store in
            // MARK: - Insert Products

            print("1️⃣ Inserting products with embeddings...")
            let products = [
                Product(productID: 1, name: "Wireless Headphones", category: "Electronics", embedding: randomEmbedding()),
                Product(productID: 2, name: "Bluetooth Speaker", category: "Electronics", embedding: randomEmbedding()),
                Product(productID: 3, name: "USB Cable", category: "Electronics", embedding: randomEmbedding()),
                Product(productID: 4, name: "Desk Lamp", category: "Furniture", embedding: randomEmbedding()),
                Product(productID: 5, name: "Office Chair", category: "Furniture", embedding: randomEmbedding())
            ]

            for product in products {
                try await store.save(product)
            }
            print("✅ Inserted \(products.count) products\n")

            // MARK: - Scenario 1: Build HNSW Index

            print("2️⃣ Building HNSW index...")

            // ✅ Automatic index rebuild (safe for multiple runs)
            try await context.rebuildHNSWIndex(indexName: "product_embedding_hnsw")

            print()

            // MARK: - Scenario 2: Normal HNSW Search

            print("3️⃣ Normal HNSW search (healthy state)...")
            let queryEmbedding = products[0].embedding

            let results1 = try await store.query(Product.self)
                .nearestNeighbors(k: 3, to: queryEmbedding, using: \.embedding)
                .execute()

            print("✅ Found \(results1.count) similar products:")
            for (product, distance) in results1 {
                print("   - \(product.name) (distance: \(String(format: "%.4f", distance)))")
            }
            print()

            // MARK: - Scenario 3: Simulate HNSW Failure

            print("4️⃣ Simulating HNSW failure (disable index)...")
            let indexStateManager = IndexStateManager(
                database: context.database,
                subspace: context.subspace.subspace("state")
            )
            try await indexStateManager.disable("product_embedding_hnsw")
            print("   ⚠️ Index disabled (simulating failure)")
            print()

            // MARK: - Scenario 4: Automatic Fallback

            print("5️⃣ Query with circuit breaker (automatic fallback)...")
            let results2 = try await store.query(Product.self)
                .nearestNeighbors(k: 3, to: queryEmbedding, using: \.embedding)
                .execute()

            print("✅ Circuit breaker activated, used flat scan fallback")
            print("✅ Found \(results2.count) products (slower but still works):")
            for (product, distance) in results2 {
                print("   - \(product.name) (distance: \(String(format: "%.4f", distance)))")
            }
            print()

            // MARK: - Scenario 5: Check Health Status

            print("6️⃣ Checking HNSW health status...")
            context.checkHNSWHealth(indexName: "product_embedding_hnsw")
            print()

            // MARK: - Scenario 6: Rebuild and Recovery

            print("7️⃣ Rebuilding HNSW index (recovery)...")
            try await context.rebuildHNSWIndex(indexName: "product_embedding_hnsw")
            print()

            // MARK: - Scenario 7: HNSW Works Again

            print("8️⃣ Query after recovery (HNSW restored)...")
            let results3 = try await store.query(Product.self)
                .nearestNeighbors(k: 3, to: queryEmbedding, using: \.embedding)
                .execute()

            print("✅ HNSW search successful (O(log n) performance restored)")
            print("✅ Found \(results3.count) products:")
            for (product, distance) in results3 {
                print("   - \(product.name) (distance: \(String(format: "%.4f", distance)))")
            }
            print()

            // MARK: - Final Health Check

            print("9️⃣ Final health status:")
            context.checkHNSWHealth(indexName: "product_embedding_hnsw")
            print()
        }

        print("🎉 Example completed!")
        print("\n💡 Demonstrated features:")
        print("   ✅ HNSW index automatic rebuild")
        print("   ✅ Circuit breaker pattern for error handling")
        print("   ✅ Automatic fallback to flat scan on failure")
        print("   ✅ Health tracking and diagnostics")
        print("   ✅ Recovery after rebuild")
        print("\n📖 Try running multiple times:")
        print("   swift run 07-VectorSearch-Refactored  # Works every time!")
        print("   EXAMPLE_CLEANUP=false swift run 07-VectorSearch-Refactored  # Debug mode")
        print("\n🔧 Key implementation details:")
        print("   • HNSWIndexHealthTracker tracks success/failure count")
        print("   • Circuit breaker activates after 1 failure (configurable)")
        print("   • Cooldown period: 5 minutes before retry (configurable)")
        print("   • rebuildHNSWIndex() resets health tracker automatically")
    }

    static func randomEmbedding() -> [Float32] {
        (0..<384).map { _ in Float32.random(in: -1...1) }
    }
}
