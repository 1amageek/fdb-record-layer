import Foundation
import FoundationDB
import FDBRecordLayer
import SwiftProtobuf

/// Simple example demonstrating FDB Record Layer API
///
/// This example shows:
/// - Creating metadata with array-based initialization
/// - Using Index factory methods (.value, .count)
/// - Type-safe RecordStore API with Recordable protocol
/// - Query builder with KeyPath-based filtering
/// - Cost-based query optimization with StatisticsManager
///
/// Before running:
/// 1. Generate Swift code from User.proto:
///    protoc --swift_out=. User.proto
/// 2. Ensure User+Recordable.swift exists (defines Recordable conformance)
/// 3. Ensure FoundationDB is running locally
@main
struct SimpleExample {
    static func main() async throws {
        print("FDB Record Layer - Type-Safe API Example")
        print("==========================================\n")

        // Initialize FoundationDB
        print("1. Initializing FoundationDB...")
        try await FDBClient.initialize()
        let database = try FDBClient.openDatabase()
        print("   ✓ Connected to FoundationDB\n")

        // Define metadata using Swift-style API
        print("2. Defining metadata...")
        let primaryKey = FieldKeyExpression(fieldName: "user_id")

        let userType = RecordType(
            name: "User",
            primaryKey: primaryKey,
            messageDescriptor: User.messageDescriptor
        )

        // Create metadata with array-based initialization
        let metaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: [
                // Factory methods for clean, Swift-style index creation
                .value("by_email", on: FieldKeyExpression(fieldName: "email")),
                .value("by_age", on: FieldKeyExpression(fieldName: "age")),
                .count("count_by_city", groupBy: FieldKeyExpression(fieldName: "city"))
            ],
            unionDescriptor: RecordTypeUnion.unionDescriptor
        )
        print("   ✓ Metadata created with 3 indexes\n")

        // Create record store
        print("3. Creating record store...")

        // Create StatisticsManager for cost-based query optimization
        let statsSubspace = Subspace(rootPrefix: "example_stats")
        let statisticsManager = StatisticsManager(
            database: database,
            subspace: statsSubspace
        )

        let recordStore = try RecordStore(
            database: database,
            subspace: Subspace(rootPrefix: "example"),
            metaData: metaData,
            statisticsManager: statisticsManager
        )
        print("   ✓ Record store created with statistics support\n")

        // Create sample users
        let alice = User.with {
            $0.userID = 1
            $0.name = "Alice"
            $0.email = "alice@example.com"
            $0.age = 30
        }

        let bob = User.with {
            $0.userID = 2
            $0.name = "Bob"
            $0.email = "bob@example.com"
            $0.age = 25
        }

        let charlie = User.with {
            $0.userID = 3
            $0.name = "Charlie"
            $0.email = "charlie@example.com"
            $0.age = 35
        }

        // Insert records
        print("4. Inserting records...")
        try await recordStore.save(alice)
        try await recordStore.save(bob)
        try await recordStore.save(charlie)
        print("   ✓ Inserted 3 records\n")

        // Load a record by primary key
        print("5. Loading record by primary key...")
        if let user = try await recordStore.fetch(User.self, by: Int64(1)) {
            print("   ✓ Record loaded:")
            print("     - ID: \(user.userID)")
            print("     - Name: \(user.name)")
            print("     - Email: \(user.email)")
            print("     - Age: \(user.age)\n")
        }

        // Query records using type-safe QueryBuilder
        print("6. Querying records (age >= 30)...")
        let adults = try await recordStore.query(User.self)
            .where(\.age, .greaterThanOrEquals, Int64(30))
            .execute()

        print("   Query results:")
        for user in adults {
            print("     - \(user.name) (age: \(user.age), email: \(user.email))")
        }
        print("   ✓ Found \(adults.count) record(s)\n")

        // Update a record
        print("7. Updating record...")
        var updatedBob = bob
        updatedBob.age = 26
        try await recordStore.save(updatedBob)
        print("   ✓ Updated Bob's age to 26\n")

        // Verify update
        print("8. Verifying update...")
        if let verifiedBob = try await recordStore.fetch(User.self, by: Int64(2)) {
            print("   ✓ Bob's age updated: \(verifiedBob.age)\n")
        }

        // Delete a record
        print("9. Deleting record...")
        try await recordStore.delete(User.self, by: Int64(3))
        print("   ✓ Deleted Charlie\n")

        // Verify deletion
        print("10. Verifying deletion...")
        let deletedUser = try await recordStore.fetch(User.self, by: Int64(3))
        if deletedUser == nil {
            print("   ✓ Charlie successfully deleted\n")
        } else {
            print("   ⚠ Charlie still exists\n")
        }

        print("Example completed successfully!")
        print("\nKey Features of Type-Safe API:")
        print("  • Recordable protocol for type safety")
        print("  • KeyPath-based query building")
        print("  • Automatic serialization/deserialization")
        print("  • Cost-based query optimization with StatisticsManager")
        print("  • Index factory methods (.value, .count, .sum, .rank)")
        print("  • Array-based metadata initialization")
    }
}
