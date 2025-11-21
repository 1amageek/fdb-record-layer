// Example 07: Vector Search (Product Recommendation)
// This example demonstrates using HNSW vector index for finding similar
// products based on embedding vectors.

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
    var description: String
    var embedding: [Float32]  // 384-dimensional embedding vector
}

// MARK: - Helper Functions

func generateMockEmbedding(seed: Int, dimensions: Int = 384) -> [Float32] {
    var embedding = [Float32]()
    var generator = SeededRandomNumberGenerator(seed: UInt64(seed))

    for _ in 0..<dimensions {
        embedding.append(Float32.random(in: -1...1, using: &generator))
    }

    // Normalize to unit vector
    let magnitude = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
    return embedding.map { $0 / magnitude }
}

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Example Usage

@main
struct VectorSearchExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([Product.self])
        let subspace = Subspace(prefix: Tuple("examples", "vector", "products").pack())
        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        print("📦 RecordStore initialized")

        // Insert sample products
        print("\n📝 Inserting sample products...")
        let products = [
            Product(productID: 1, name: "Wireless Headphones", description: "Bluetooth headphones with noise cancellation", embedding: generateMockEmbedding(seed: 1)),
            Product(productID: 2, name: "Bluetooth Earbuds", description: "Compact wireless earbuds", embedding: generateMockEmbedding(seed: 2)),
            Product(productID: 3, name: "Gaming Headset", description: "Wired headset for gaming", embedding: generateMockEmbedding(seed: 3)),
            Product(productID: 4, name: "USB Cable", description: "USB-C to USB-A cable", embedding: generateMockEmbedding(seed: 100)),
            Product(productID: 5, name: "Laptop Stand", description: "Adjustable aluminum laptop stand", embedding: generateMockEmbedding(seed: 200)),
        ]

        for product in products {
            try await store.save(product)
        }
        print("✅ Inserted \(products.count) products")

        // MARK: - Build HNSW Index

        print("\n🏗️ Building HNSW index...")
        let onlineIndexer = OnlineIndexer(
            store: store,
            indexName: "product_embedding_hnsw"
        )

        try await onlineIndexer.buildHNSWIndex()
        print("✅ HNSW index built successfully")

        // MARK: - Vector Search

        // Query: User interested in "wireless headphones"
        print("\n🔍 Finding similar products to 'Wireless Headphones'...")
        let queryEmbedding = generateMockEmbedding(seed: 1)  // Similar to product 1

        let similarProducts = try await store.query(Product.self)
            .nearestNeighbors(k: 3, to: queryEmbedding, using: \.embedding)
            .execute()

        for (product, distance) in similarProducts {
            let similarity = 1.0 - distance
            print("  - \(product.name)")
            print("    Similarity: \(String(format: "%.2f", similarity * 100))%")
        }

        // MARK: - Different Query

        print("\n🔍 Finding similar products to 'USB Cable'...")
        let cableEmbedding = generateMockEmbedding(seed: 100)  // Similar to product 4

        let cableSimilar = try await store.query(Product.self)
            .nearestNeighbors(k: 3, to: cableEmbedding, using: \.embedding)
            .execute()

        for (product, distance) in cableSimilar {
            let similarity = 1.0 - distance
            print("  - \(product.name)")
            print("    Similarity: \(String(format: "%.2f", similarity * 100))%")
        }

        print("\n🎉 Vector search example completed!")
    }
}
