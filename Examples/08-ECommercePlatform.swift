// Example 08: E-Commerce Platform
// This example demonstrates a complete e-commerce platform with products,
// orders, and multi-index queries.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definitions

@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])
    #Index<Product>([\.category, \.price], name: "product_by_category_price")
    #Index<Product>([\.seller, \.createdAt], name: "product_by_seller_date")

    var productID: Int64
    var name: String
    var description: String
    var category: String
    var price: Double
    var seller: String
    var stock: Int
    var createdAt: Date
}

@Recordable
struct Order {
    #PrimaryKey<Order>([\.orderID])
    #Index<Order>([\.userID, \.orderDate], name: "order_by_user_date")
    #Index<Order>([\.status], name: "order_by_status")

    var orderID: Int64
    var userID: Int64
    var items: [OrderItem]
    var totalAmount: Double
    var status: OrderStatus
    var orderDate: Date
}

struct OrderItem: Codable, Sendable {
    var productID: Int64
    var quantity: Int
    var price: Double
}

enum OrderStatus: String, Codable, Sendable {
    case pending, processing, shipped, delivered, cancelled
}

// MARK: - Example Usage

@main
struct ECommercePlatformExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        // Product store
        let productSchema = Schema([Product.self])
        let productSubspace = Subspace(prefix: Tuple("examples", "ecommerce", "products").pack())
        let productStore = RecordStore<Product>(
            database: database,
            subspace: productSubspace,
            schema: productSchema,
            statisticsManager: NullStatisticsManager()
        )

        // Order store
        let orderSchema = Schema([Order.self])
        let orderSubspace = Subspace(prefix: Tuple("examples", "ecommerce", "orders").pack())
        let orderStore = RecordStore<Order>(
            database: database,
            subspace: orderSubspace,
            schema: orderSchema,
            statisticsManager: NullStatisticsManager()
        )

        print("📦 E-Commerce platform initialized")

        // MARK: - Insert Sample Products

        print("\n📝 Inserting sample products...")
        let products = [
            Product(productID: 1, name: "Laptop", description: "High-performance laptop", category: "Electronics", price: 999.99, seller: "TechStore", stock: 10, createdAt: Date()),
            Product(productID: 2, name: "Mouse", description: "Wireless mouse", category: "Electronics", price: 29.99, seller: "TechStore", stock: 50, createdAt: Date()),
            Product(productID: 3, name: "Desk", description: "Ergonomic desk", category: "Furniture", price: 299.99, seller: "HomeGoods", stock: 5, createdAt: Date()),
            Product(productID: 4, name: "Chair", description: "Office chair", category: "Furniture", price: 149.99, seller: "HomeGoods", stock: 15, createdAt: Date()),
        ]

        for product in products {
            try await productStore.save(product)
        }
        print("✅ Inserted \(products.count) products")

        // MARK: - Category-based Product Search

        print("\n🔍 Searching for affordable Electronics ($10-$500)...")
        let affordableElectronics = try await productStore.query()
            .where(\.category, .equals, "Electronics")
            .where(\.price, .greaterThanOrEqual, 10.0)
            .where(\.price, .lessThanOrEqual, 500.0)
            .orderBy(\.price, .ascending)
            .limit(10)
            .execute()

        for product in affordableElectronics {
            print("  - \(product.name): $\(product.price) (Stock: \(product.stock))")
        }

        // MARK: - Create Order

        print("\n🛒 Creating order for user 1...")
        let order = Order(
            orderID: 1,
            userID: 1,
            items: [
                OrderItem(productID: 1, quantity: 1, price: 999.99),
                OrderItem(productID: 2, quantity: 2, price: 29.99),
            ],
            totalAmount: 1059.97,
            status: .pending,
            orderDate: Date()
        )

        try await orderStore.save(order)
        print("✅ Order created: ID=\(order.orderID), Total=$\(order.totalAmount)")

        // MARK: - User's Order History

        print("\n📜 Fetching order history for user 1...")
        let userOrders = try await orderStore.query()
            .where(\.userID, .equals, Int64(1))
            .orderBy(\.orderDate, .descending)
            .execute()

        for order in userOrders {
            print("  - Order #\(order.orderID): \(order.status.rawValue) - $\(order.totalAmount)")
        }

        // MARK: - Orders by Status

        print("\n📊 Pending orders:")
        let pendingOrders = try await orderStore.query()
            .where(\.status, .equals, OrderStatus.pending)
            .execute()

        for order in pendingOrders {
            print("  - Order #\(order.orderID) for user \(order.userID): $\(order.totalAmount)")
        }

        print("\n🎉 E-Commerce platform example completed!")
    }
}
