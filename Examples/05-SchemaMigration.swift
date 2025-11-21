// Example 05: Schema Migration
// This example demonstrates migrating from Schema v1 (no indexes) to
// Schema v2 (with email index) using MigrationManager.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Schema V1 (Initial)

protocol SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
}

@Recordable
struct UserV1 {
    #PrimaryKey<UserV1>([\.userID])

    var userID: Int64
    var email: String
    var name: String
}

// MARK: - Schema V2 (With Email Index)

protocol SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
}

@Recordable
struct UserV2 {
    #PrimaryKey<UserV2>([\.userID])
    #Index<UserV2>([\.email], name: "user_by_email")  // New index

    var userID: Int64
    var email: String
    var name: String
}

// MARK: - Example Usage

@main
struct SchemaMigrationExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let subspace = Subspace(prefix: Tuple("examples", "migration", "users").pack())

        // MARK: - Step 1: Start with Schema V1

        print("📦 Creating Schema V1 (no indexes)...")
        let schemaV1 = Schema([UserV1.self], version: Schema.Version(1, 0, 0))
        let storeV1 = RecordStore<UserV1>(
            database: database,
            subspace: subspace,
            schema: schemaV1,
            statisticsManager: NullStatisticsManager()
        )

        // Insert sample users with V1 schema
        print("\n📝 Inserting users with Schema V1...")
        for i in 1...20 {
            let user = UserV1(
                userID: Int64(i),
                email: "user\(i)@example.com",
                name: "User \(i)"
            )
            try await storeV1.save(user)
        }
        print("✅ Inserted 20 users")

        // MARK: - Step 2: Define Migration

        print("\n🔄 Preparing migration from v1 to v2...")

        let migration_1_to_2 = Migration(
            fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
            toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
            description: "Add email index"
        ) { context in
            let emailIndex = Index(
                name: "user_by_email",
                type: .value,
                rootExpression: FieldKeyExpression(fieldName: "email")
            )
            // OnlineIndexer will build the index in batches
            try await context.addIndex(emailIndex)
        }

        // MARK: - Step 3: Execute Migration

        let schemaV2 = Schema([UserV2.self], version: Schema.Version(2, 0, 0))
        let storeV2 = RecordStore<UserV2>(
            database: database,
            subspace: subspace,
            schema: schemaV2,
            statisticsManager: NullStatisticsManager()
        )

        let manager = MigrationManager(
            database: database,
            schema: schemaV2,
            migrations: [migration_1_to_2],
            store: storeV2
        )

        // Check current version
        if let currentVersion = try await manager.getCurrentVersion() {
            print("📌 Current schema version: \(currentVersion)")
        } else {
            print("📌 No schema version recorded (first migration)")
        }

        // Execute migration
        print("\n🏗️ Executing migration to v2.0.0...")
        try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))
        print("✅ Migration to v2 complete")

        // MARK: - Step 4: Verify New Index

        print("\n🔍 Querying users by email (using new index)...")
        let users = try await storeV2.query()
            .where(\.email, .equals, "user5@example.com")
            .execute()

        for user in users {
            print("  - Found: \(user.name) (\(user.email))")
        }

        // Check final version
        if let finalVersion = try await manager.getCurrentVersion() {
            print("\n📌 Final schema version: \(finalVersion)")
        }

        print("\n🎉 Schema migration example completed!")
    }
}
