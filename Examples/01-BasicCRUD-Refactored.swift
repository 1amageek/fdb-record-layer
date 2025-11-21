// Example 01: Basic CRUD Operations (Refactored with ExampleContext)
// This example demonstrates the improved infrastructure with:
// - Environment variable support for cluster configuration
// - Automatic data isolation and cleanup
// - Simplified setup code

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email], name: "user_by_email")

    var userID: Int64
    var name: String
    var email: String
    var age: Int

    @Default(value: Date())
    var createdAt: Date
}

// MARK: - Example

@main
struct BasicCRUDExample {
    static func main() async throws {
        print("📚 Example 01: Basic CRUD Operations (with ExampleContext)\n")

        // ✅ NEW: Use ExampleContext for simplified setup
        let context = try await ExampleContext(
            name: "BasicCRUD",
            recordType: User.self
        )

        // Automatically runs cleanup after completion
        try await context.run { store in
            // MARK: - Create

            print("1️⃣ Creating users...")
            let users = [
                User(userID: 1, name: "Alice", email: "alice@example.com", age: 30),
                User(userID: 2, name: "Bob", email: "bob@example.com", age: 25),
                User(userID: 3, name: "Charlie", email: "charlie@example.com", age: 35)
            ]

            for user in users {
                try await store.save(user)
            }
            print("✅ Created \(users.count) users\n")

            // MARK: - Read

            print("2️⃣ Reading user by primary key...")
            if let alice = try await store.record(for: 1) {
                print("✅ Found: \(alice.name) <\(alice.email)>\n")
            }

            print("3️⃣ Querying users by email...")
            let bobResults = try await store.query()
                .where(\.email, .equals, "bob@example.com")
                .execute()

            for user in bobResults {
                print("✅ Found: \(user.name)\n")
            }

            print("4️⃣ Querying users aged 30 or older...")
            let seniors = try await store.query()
                .where(\.age, .greaterThanOrEqual, 30)
                .execute()

            print("✅ Found \(seniors.count) users:")
            for user in seniors {
                print("   - \(user.name) (age: \(user.age))")
            }
            print()

            // MARK: - Update

            print("5️⃣ Updating Bob's age...")
            var bob = try await store.record(for: 2)!
            bob.age = 26
            try await store.save(bob)
            print("✅ Updated Bob's age to \(bob.age)\n")

            print("6️⃣ Verifying update...")
            let updatedBob = try await store.record(for: 2)!
            print("✅ Bob's age is now: \(updatedBob.age)\n")

            // MARK: - Delete

            print("7️⃣ Deleting Charlie...")
            try await store.delete(for: 3)
            print("✅ Deleted user ID 3\n")

            print("8️⃣ Verifying deletion...")
            let deletedUser = try await store.record(for: 3)
            if deletedUser == nil {
                print("✅ Charlie successfully deleted\n")
            }

            // MARK: - Count

            print("9️⃣ Counting remaining users...")
            let allUsers = try await store.query().execute()
            print("✅ Total users: \(allUsers.count)\n")
        }

        print("🎉 Example completed successfully!")
        print("\n💡 Key improvements:")
        print("   • Environment variable support (FDB_CLUSTER_FILE, etc.)")
        print("   • Automatic data isolation with unique Run ID")
        print("   • Automatic cleanup (disable with EXAMPLE_CLEANUP=false)")
        print("   • Simplified setup (no manual FDB initialization)")
        print("\n📖 Try running with different configurations:")
        print("   EXAMPLE_CLEANUP=false swift run 01-BasicCRUD-Refactored")
        print("   FDB_CLUSTER_FILE=~/custom.cluster swift run 01-BasicCRUD-Refactored")
    }
}
