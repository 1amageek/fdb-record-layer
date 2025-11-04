import Foundation
import FoundationDB
import FDBRecordLayer
import SwiftProtobuf

/// Simple example demonstrating SwiftData-style Record Layer API
///
/// This example shows:
/// - Creating metadata with array-based initialization
/// - Using Index factory methods (.value, .count)
/// - RecordContext for single operations (automatic transactions)
/// - Transaction API for multiple atomic operations
/// - New SwiftData-style context-based API
///
/// Before running:
/// 1. Generate Swift code from User.proto:
///    protoc --swift_out=. User.proto
/// 2. Ensure FoundationDB is running locally
@main
struct SimpleExample {
    static func main() async throws {
        print("FDB Record Layer - Swift-Style API Example")
        print("==============================================\n")

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

        // Create record store with RecordAccess
        print("3. Creating record store...")

        // Create field extractor with mappings for User fields
        let userFieldExtractor = ProtobufFieldExtractor<User>(
            extractors: [
                "user_id": { user in [user.userID] },
                "name": { user in [user.name] },
                "email": { user in [user.email] },
                "age": { user in [user.age] }
            ]
        )

        let userAccess = ProtobufRecordAccess<User>(
            typeName: "User",
            fieldExtractor: userFieldExtractor
        )

        let recordStore = try RecordStore<User>(
            database: database,
            subspace: Subspace(rootPrefix: "example"),
            metaData: metaData,
            recordAccess: userAccess
        )
        print("   ✓ Record store created\n")

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

        // Create context (SwiftData-style)
        print("4. Creating record context...")
        let context = try await recordStore.createContext()
        print("   ✓ Context created\n")

        // Insert records using transaction API
        print("5. Inserting records (transaction API)...")
        try await context.transaction { transaction in
            try await transaction.save(alice)
            try await transaction.save(bob)
            try await transaction.save(charlie)
        }
        print("   ✓ Inserted 3 records in single transaction\n")

        // Load a record using single-operation API
        print("6. Loading record (automatic transaction)...")
        if let user = try await context.fetch(by: Tuple(Int64(1))) {
            print("   ✓ Record loaded:")
            print("     - ID: \(user.userID)")
            print("     - Name: \(user.name)")
            print("     - Email: \(user.email)")
            print("     - Age: \(user.age)\n")
        }

        // Query records
        print("7. Querying records (age >= 30)...")
        let query = RecordQuery(
            recordType: "User",
            filter: FieldQueryComponent(
                fieldName: "age",
                comparison: .greaterThanOrEquals,
                value: Int64(30)
            ),
            sort: [SortKey(expression: FieldKeyExpression(fieldName: "name"))]
        )

        let adults = try await context.transaction { transaction in
            try await transaction.fetch(query)
        }
        print("   Query results:")
        var count = 0
        for try await user in adults {
            count += 1
            print("     - \(user.name) (age: \(user.age), email: \(user.email))")
        }
        print("   ✓ Found \(count) record(s)\n")

        // Update and delete in a single transaction
        print("8. Update and delete (transaction API)...")
        try await context.transaction { transaction in
            // Update Bob's age
            var updatedBob = bob
            updatedBob.age = 26
            try await transaction.save(updatedBob)

            // Delete Charlie
            try await transaction.delete(at: Tuple(Int64(3)))

            print("   ✓ Updated 1 record, deleted 1 record")
        }
        print()

        // Verify deletion
        print("9. Verifying deletion...")
        let deletedUser = try await context.fetch(by: Tuple(Int64(3)))
        if deletedUser == nil {
            print("   ✓ Charlie successfully deleted\n")
        } else {
            print("   ⚠ Charlie still exists\n")
        }

        // Verify update
        print("10. Verifying update...")
        if let updatedBob = try await context.fetch(by: Tuple(Int64(2))) {
            print("   ✓ Bob's age updated: \(updatedBob.age)\n")
        }

        print("Example completed successfully!")
        print("\nKey Features of SwiftData-Style API:")
        print("  • RecordContext as main interface (like ModelContext)")
        print("  • createContext() to get a typed context")
        print("  • Single operations: context.fetch(), context.save(), context.delete()")
        print("  • Automatic transactions for single operations")
        print("  • Explicit transactions: context.transaction { transaction in }")
        print("  • Transaction object for multiple atomic operations")
        print("  • No context parameters - clean instance methods")
        print("  • Index factory methods (.value, .count, .sum, .rank)")
        print("  • Array-based metadata initialization")
    }
}
