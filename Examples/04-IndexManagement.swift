// Example 04: Index Management and Online Index Building
// This example demonstrates adding new indexes to existing data using
// OnlineIndexer for batch processing.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email], name: "user_by_email")
    // New index to be built online
    #Index<User>([\.registrationDate], name: "user_by_registration")

    var userID: Int64
    var email: String
    var name: String
    var registrationDate: Date
}

// MARK: - Example Usage

@main
struct IndexManagementExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([User.self])
        let subspace = Subspace(prefix: Tuple("examples", "index", "users").pack())
        let store = RecordStore<User>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        print("📦 RecordStore initialized")

        // Insert sample users (simulate existing data)
        print("\n📝 Inserting sample users...")
        let calendar = Calendar.current
        for i in 1...100 {
            let daysAgo = Int.random(in: 1...365)
            let registrationDate = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!

            let user = User(
                userID: Int64(i),
                email: "user\(i)@example.com",
                name: "User \(i)",
                registrationDate: registrationDate
            )
            try await store.save(user)

            if i % 20 == 0 {
                print("  ✅ Inserted \(i)/100 users")
            }
        }
        print("✅ Inserted 100 users")

        // MARK: - Online Index Building

        print("\n🏗️ Building index 'user_by_registration' online...")

        let onlineIndexer = OnlineIndexer(
            store: store,
            indexName: "user_by_registration",
            batchSize: 20,  // Process 20 records per transaction
            throttleDelayMs: 10  // 10ms delay between batches
        )

        // Build index in background
        let buildTask = Task {
            do {
                try await onlineIndexer.buildIndex()
                print("✅ Index built successfully")
            } catch {
                print("❌ Index build failed: \(error)")
            }
        }

        // Monitor progress
        let monitorTask = Task {
            while true {
                let (scanned, total, percentage) = try await onlineIndexer.getProgress()
                print("📊 Progress: \(scanned)/\(total) (\(Int(percentage * 100))%)")

                if percentage >= 1.0 {
                    break
                }

                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second
            }
        }

        // Wait for both tasks to complete
        _ = try await buildTask.value
        _ = try await monitorTask.value

        // MARK: - Verify Index

        print("\n🔍 Querying users registered in the last 30 days...")
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: Date())!

        let recentUsers = try await store.query()
            .where(\.registrationDate, .greaterThanOrEqual, thirtyDaysAgo)
            .orderBy(\.registrationDate, .descending)
            .limit(10)
            .execute()

        for user in recentUsers {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            print("  - \(user.name): registered on \(formatter.string(from: user.registrationDate))")
        }

        print("\n🎉 Index management example completed!")
    }
}
