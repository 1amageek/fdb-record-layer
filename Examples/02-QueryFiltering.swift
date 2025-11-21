// Example 02: Query and Filtering
// This example demonstrates various query patterns including filtering,
// sorting, limits, and IN queries.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])
    #Index<Product>([\.category, \.price], name: "product_by_category_price")

    var productID: Int64
    var name: String
    var category: String
    var price: Double
    var inStock: Bool
}

// MARK: - Example Usage

@main
struct QueryFilteringExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([Product.self])
        let subspace = Subspace(prefix: Tuple("examples", "query", "products").pack())
        let store = RecordStore<Product>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        print("📦 RecordStore initialized")

        // Insert sample products
        let sampleProducts = [
            Product(productID: 1, name: "Laptop", category: "Electronics", price: 999.99, inStock: true),
            Product(productID: 2, name: "Mouse", category: "Electronics", price: 29.99, inStock: true),
            Product(productID: 3, name: "Desk", category: "Furniture", price: 299.99, inStock: false),
            Product(productID: 4, name: "Chair", category: "Furniture", price: 149.99, inStock: true),
            Product(productID: 5, name: "Keyboard", category: "Electronics", price: 79.99, inStock: true),
        ]

        for product in sampleProducts {
            try await store.save(product)
        }
        print("✅ Inserted \(sampleProducts.count) products")

        // MARK: - Basic Filters

        // Filter by category
        print("\n🔍 Electronics products:")
        let electronics = try await store.query()
            .where(\.category, .equals, "Electronics")
            .execute()
        for product in electronics {
            print("  - \(product.name): $\(product.price)")
        }

        // Filter by price range
        print("\n💰 Affordable products ($10-$100):")
        let affordableProducts = try await store.query()
            .where(\.price, .greaterThanOrEqual, 10.0)
            .where(\.price, .lessThanOrEqual, 100.0)
            .execute()
        for product in affordableProducts {
            print("  - \(product.name): $\(product.price)")
        }

        // Multiple conditions
        print("\n🛒 Available Electronics under $500:")
        let availableElectronics = try await store.query()
            .where(\.category, .equals, "Electronics")
            .where(\.inStock, .equals, true)
            .where(\.price, .lessThan, 500.0)
            .execute()
        for product in availableElectronics {
            print("  - \(product.name): $\(product.price)")
        }

        // MARK: - Sorting and Limits

        // Sort by price (ascending)
        print("\n⬆️ Cheapest Electronics (top 3):")
        let cheapest = try await store.query()
            .where(\.category, .equals, "Electronics")
            .orderBy(\.price, .ascending)
            .limit(3)
            .execute()
        for product in cheapest {
            print("  - \(product.name): $\(product.price)")
        }

        // Sort by price (descending)
        print("\n⬇️ Most expensive products (top 2):")
        let mostExpensive = try await store.query()
            .where(\.category, .equals, "Electronics")
            .orderBy(\.price, .descending)
            .limit(2)
            .execute()
        for product in mostExpensive {
            print("  - \(product.name): $\(product.price)")
        }

        // MARK: - IN Query

        print("\n📋 Products in specific categories:")
        let categories = ["Electronics", "Furniture"]
        let products = try await store.query()
            .where(\.category, .in, categories)
            .execute()
        for product in products {
            print("  - \(product.name) (\(product.category)): $\(product.price)")
        }

        print("\n🎉 Query and filtering example completed!")
    }
}
