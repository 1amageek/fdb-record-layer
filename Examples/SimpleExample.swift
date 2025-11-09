import Foundation
import FoundationDB
import FDBRecordLayer

/// Simple example demonstrating FDB Record Layer with Macro API
///
/// This example shows:
/// - Using @Recordable macro for type-safe record definitions
/// - Using #Directory for directory path specification
/// - Using #Index for index definitions
/// - Basic CRUD operations
/// - Type-safe query API
///
/// Before running:
/// 1. Ensure FoundationDB is running locally:
///    brew services start foundationdb
/// 2. No Protobuf files needed - macros generate everything!

// MARK: - Record Definition with Macros

@Recordable
struct User {
    // Directory path: app/users
    #Directory<User>("app", "users", layer: .recordStore)

    // Indexes
    #Index<User>([\email])
    #Index<User>([\age])

    // Primary key
    @PrimaryKey var userID: Int64

    // Fields
    var name: String
    var email: String
    var age: Int32

    // Default value for createdAt
    @Default(value: Date())
    var createdAt: Date
}

// MARK: - Main Example

@main
struct SimpleExample {
    static func main() async {
        print("FDB Record Layer - Macro API Example")
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
            exit(1)
        }
    }

    static func runExample() async throws {
        // Open database connection
        print("1. Connecting to FoundationDB...")
        let database = try await FDB.open()
        print("   ✓ Connected to FoundationDB\n")

        // Create schema
        print("2. Creating schema...")
        let schema = Schema([User.self])
        print("   ✓ Schema created with User type\n")

        // Open record store using generated method
        print("3. Opening record store...")
        let store = try await User.store(database: database, schema: schema)
        print("   ✓ Record store opened at: app/users\n")

        // Create sample users
        print("4. Creating sample records...")
        let alice = User(
            userID: 1,
            name: "Alice",
            email: "alice@example.com",
            age: 30,
            createdAt: Date()
        )

        let bob = User(
            userID: 2,
            name: "Bob",
            email: "bob@example.com",
            age: 25,
            createdAt: Date()
        )

        let charlie = User(
            userID: 3,
            name: "Charlie",
            email: "charlie@example.com",
            age: 35,
            createdAt: Date()
        )

        // Save records
        print("5. Saving records...")
        try await store.save(alice)
        try await store.save(bob)
        try await store.save(charlie)
        print("   ✓ Saved 3 records\n")

        // Load by primary key
        print("6. Loading record by primary key (userID = 1)...")
        if let user: User = try await store.fetch(by: Int64(1)) {
            print("   ✓ Found user:")
            print("     - ID: \(user.userID)")
            print("     - Name: \(user.name)")
            print("     - Email: \(user.email)")
            print("     - Age: \(user.age)\n")
        }

        // Query by email index
        print("7. Querying by email (bob@example.com)...")
        let bobResults = try await store.query(User.self)
            .where(\.email, .equals, "bob@example.com")
            .execute()

        if let foundBob = bobResults.first {
            print("   ✓ Found user: \(foundBob.name) (ID: \(foundBob.userID))\n")
        }

        // Query by age range
        print("8. Querying users aged 30 or older...")
        let adults = try await store.query(User.self)
            .where(\.age, .greaterThanOrEquals, Int32(30))
            .execute()

        print("   ✓ Found \(adults.count) user(s):")
        for user in adults {
            print("     - \(user.name) (age: \(user.age))")
        }
        print()

        // Update a record
        print("9. Updating Bob's age...")
        var updatedBob = bob
        updatedBob.age = 26
        try await store.save(updatedBob)
        print("   ✓ Updated Bob's age to 26\n")

        // Verify update
        print("10. Verifying update...")
        if let verifiedBob: User = try await store.fetch(by: Int64(2)) {
            print("   ✓ Bob's age is now: \(verifiedBob.age)\n")
        }

        // Delete a record
        print("11. Deleting Charlie...")
        try await store.delete(by: Int64(3))
        print("   ✓ Deleted user ID 3\n")

        // Verify deletion
        print("12. Verifying deletion...")
        let deletedUser: User? = try await store.fetch(by: Int64(3))
        if deletedUser == nil {
            print("   ✓ Charlie successfully deleted\n")
        } else {
            print("   ⚠ Charlie still exists\n")
        }

        // Count remaining users
        print("13. Counting remaining users...")
        let allUsers = try await store.query(User.self).execute()
        print("   ✓ Total users: \(allUsers.count)\n")

        print("Example completed successfully!")
        print("\nKey Features of Macro API:")
        print("  • @Recordable - No manual Protobuf files needed")
        print("  • #Directory - Type-safe directory paths")
        print("  • #Index - Declarative index definitions")
        print("  • @PrimaryKey - Explicit primary key marking")
        print("  • @Default - Default value support")
        print("  • Type-safe queries with KeyPath-based filtering")
        print("  • Automatic store() method generation")
    }
}
