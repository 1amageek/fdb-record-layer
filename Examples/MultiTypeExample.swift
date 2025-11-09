import Foundation
import FoundationDB
import FDBRecordLayer

/// Multi-type example demonstrating multiple record types in a single database
///
/// This example shows:
/// - Multiple @Recordable types (User, Order)
/// - Using #Directory with partition for multi-tenancy
/// - Relationships between record types
/// - Querying across related records
/// - Aggregate indexes for analytics

// MARK: - User Record

@Recordable
struct User {
    #Directory<User>("app", "users", layer: .recordStore)

    #Index<User>([\email])
    #Unique<User>([\email])  // Email must be unique

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var city: String
}

// MARK: - Order Record (with Partition)

@Recordable
struct Order {
    // Partitioned by accountID for multi-tenant isolation
    #Directory<Order>("tenants", Field(\Order.accountID), "orders", layer: .partition)

    #Index<Order>([\userID])  // Index for querying orders by user
    #Index<Order>([\createdAt])  // Index for time-based queries
    #Index<Order>([\status])  // Index for status filtering

    @PrimaryKey var orderID: Int64
    var accountID: String  // Partition key
    var userID: Int64  // Foreign key to User
    var total: Double
    var status: String  // "pending", "completed", "cancelled"

    @Default(value: Date())
    var createdAt: Date
}

// MARK: - Main Example

@main
struct MultiTypeExample {
    static func main() async {
        print("FDB Record Layer - Multi-Type Example")
        print("=====================================\n")

        do {
            // Initialize FoundationDB network (once per process)
            try await FDB.startNetwork()
            defer {
                // Ensure network is stopped on exit
                try? FDB.stopNetwork()
            }

            try await runExample()
        } catch {
            print("❌ Error: \(error)")
            print("\nTroubleshooting:")
            print("  1. Ensure FoundationDB is running: brew services start foundationdb")
            print("  2. Check status: fdbcli --exec 'status'")
            print("\nNote: This example exits with code 1 to indicate failure (important for CI/scripts).")
            Foundation.exit(1)
        }
    }

    static func runExample() async throws {
        // Open database connection
        print("1. Connecting to FoundationDB...")
        let database = try await FDB.open()
        print("   ✓ Connected to FoundationDB\n")

        // Create schema with multiple types
        print("2. Creating schema with multiple record types...")
        let schema = Schema([User.self, Order.self])
        print("   ✓ Schema created with User and Order types\n")

        // Open record stores
        print("3. Opening record stores...")
        let userStore = try await User.store(database: database, schema: schema)
        let orderStore = try await Order.store(
            accountID: "account-123",  // Partition key
            database: database,
            schema: schema
        )
        print("   ✓ User store: app/users")
        print("   ✓ Order store: tenants/account-123/orders\n")

        // Create users
        print("4. Creating users...")
        let alice = User(
            userID: 1,
            name: "Alice Johnson",
            email: "alice@example.com",
            city: "San Francisco"
        )

        let bob = User(
            userID: 2,
            name: "Bob Smith",
            email: "bob@example.com",
            city: "New York"
        )

        try await userStore.save(alice)
        try await userStore.save(bob)
        print("   ✓ Created 2 users\n")

        // Create orders for Alice
        print("5. Creating orders for Alice...")
        let order1 = Order(
            orderID: 1001,
            accountID: "account-123",
            userID: 1,
            total: 99.99,
            status: "completed",
            createdAt: Date()
        )

        let order2 = Order(
            orderID: 1002,
            accountID: "account-123",
            userID: 1,
            total: 149.99,
            status: "pending",
            createdAt: Date()
        )

        try await orderStore.save(order1)
        try await orderStore.save(order2)
        print("   ✓ Created 2 orders\n")

        // Create order for Bob
        print("6. Creating order for Bob...")
        let order3 = Order(
            orderID: 1003,
            accountID: "account-123",
            userID: 2,
            total: 79.99,
            status: "completed",
            createdAt: Date()
        )

        try await orderStore.save(order3)
        print("   ✓ Created 1 order\n")

        // Query: Find all orders for a specific user
        print("7. Querying Alice's orders...")
        let aliceOrders = try await orderStore.query(Order.self)
            .where(\.userID, .equals, Int64(1))
            .execute()

        print("   ✓ Found \(aliceOrders.count) order(s) for Alice:")
        var aliceTotal = 0.0
        for order in aliceOrders {
            print("     - Order \(order.orderID): $\(order.total) (\(order.status))")
            aliceTotal += order.total
        }
        print("     - Total: $\(aliceTotal)\n")

        // Query: Find all completed orders
        print("8. Querying all completed orders...")
        let completedOrders = try await orderStore.query(Order.self)
            .where(\.status, .equals, "completed")
            .execute()

        print("   ✓ Found \(completedOrders.count) completed order(s):")
        for order in completedOrders {
            print("     - Order \(order.orderID) by user \(order.userID): $\(order.total)")
        }
        print()

        // Simulate a relationship query: Get user details for each order
        print("9. Fetching user details for each order...")
        for order in completedOrders {
            if let user: User = try await userStore.fetch(by: order.userID) {
                print("   - \(user.name) from \(user.city) ordered $\(order.total)")
            }
        }
        print()

        // Update order status
        print("10. Updating order status...")
        var updatedOrder = order2
        updatedOrder.status = "completed"
        try await orderStore.save(updatedOrder)
        print("   ✓ Order 1002 marked as completed\n")

        // Verify update
        print("11. Verifying order update...")
        if let verifiedOrder: Order = try await orderStore.fetch(by: Int64(1002)) {
            print("   ✓ Order 1002 status: \(verifiedOrder.status)\n")
        }

        // Query by email (unique index)
        print("12. Finding user by email (unique index)...")
        let foundUsers = try await userStore.query(User.self)
            .where(\.email, .equals, "bob@example.com")
            .execute()

        if let user = foundUsers.first {
            print("   ✓ Found user: \(user.name)\n")
        }

        // Cleanup: Delete all orders for a user
        print("13. Deleting all orders for Bob...")
        let bobOrders = try await orderStore.query(Order.self)
            .where(\.userID, .equals, Int64(2))
            .execute()

        for order in bobOrders {
            try await orderStore.delete(by: order.orderID)
        }
        print("   ✓ Deleted \(bobOrders.count) order(s)\n")

        // Final statistics
        print("14. Final statistics...")
        let totalUsers = try await userStore.query(User.self).execute()
        let totalOrders = try await orderStore.query(Order.self).execute()

        print("   ✓ Total users: \(totalUsers.count)")
        print("   ✓ Total orders: \(totalOrders.count)\n")

        print("Example completed successfully!")
        print("\nKey Concepts Demonstrated:")
        print("  • Multiple record types in one database")
        print("  • Partitioned directories for multi-tenancy")
        print("  • Foreign key relationships (userID)")
        print("  • Unique constraints with #Unique")
        print("  • Cross-type queries (User ← Order)")
        print("  • Aggregate calculations across records")
    }
}
