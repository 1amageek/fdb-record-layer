// Example 01: Basic CRUD Operations
// This example demonstrates creating, reading, updating, and deleting records
// with FDB Record Layer.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email], name: "user_by_email")
    #Index<User>([\.createdAt], name: "user_by_created_at")

    var userID: Int64
    var email: String
    var name: String
    var createdAt: Date
}

// MARK: - Example Usage

@main
struct CRUDOperationsExample {
    static func main() async throws {
        // 1. FDBNetwork initialization
        try FDBNetwork.shared.initialize(version: 710)

        // 2. Database connection
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        // 3. Schema definition
        let schema = Schema([User.self])

        // 4. RecordStore creation
        let subspace = Subspace(prefix: Tuple("examples", "crud", "users").pack())
        let store = RecordStore<User>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        print("📦 RecordStore initialized")

        // MARK: - Create

        let newUser = User(
            userID: 1,
            email: "alice@example.com",
            name: "Alice",
            createdAt: Date()
        )

        try await store.save(newUser)
        print("✅ User created: ID=\(newUser.userID), name=\(newUser.name)")

        // MARK: - Read

        // Read by primary key
        if let user = try await store.record(for: 1) {
            print("📖 Found user by ID: \(user.name)")
        }

        // Search by index
        let users = try await store.query()
            .where(\.email, .equals, "alice@example.com")
            .execute()

        for user in users {
            print("🔍 Found user by email: \(user.name)")
        }

        // MARK: - Update

        // Fetch existing user
        var user = try await store.record(for: 1)!

        // Update field
        user.name = "Alice Smith"

        // Save (updates if same ID)
        try await store.save(user)
        print("✏️ User updated: \(user.name)")

        // MARK: - Delete

        // Delete by primary key
        try await store.delete(for: 1)
        print("🗑️ User deleted")

        // Verify deletion
        let deletedUser = try await store.record(for: 1)
        if deletedUser == nil {
            print("✅ User successfully deleted")
        }

        print("\n🎉 CRUD operations example completed!")
    }
}
