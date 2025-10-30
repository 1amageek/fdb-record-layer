import Foundation
import FoundationDB
import FDBRecordLayer

/// Simple example demonstrating basic record store usage
@main
struct SimpleExample {
    static func main() async throws {
        print("FDB Record Layer - Simple Example")
        print("===================================\n")

        // Initialize FoundationDB
        print("1. Initializing FoundationDB...")
        try await FDBClient.initialize()
        let database = try FDBClient.openDatabase()
        print("   ✓ Connected to FoundationDB\n")

        // Define metadata
        print("2. Defining metadata...")
        let primaryKey = FieldKeyExpression(fieldName: "id")

        let userType = RecordType(
            name: "User",
            primaryKey: primaryKey
        )

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let metaData = try RecordMetaDataBuilder()
            .setVersion(1)
            .addRecordType(userType)
            .addIndex(emailIndex)
            .build()
        print("   ✓ Metadata created\n")

        // Create record store
        print("3. Creating record store...")
        let recordStore = RecordStore<[String: Any]>(
            database: database,
            subspace: Subspace(rootPrefix: "example"),
            metaData: metaData,
            serializer: DictionarySerializer()
        )
        print("   ✓ Record store created\n")

        // Insert a record
        print("4. Inserting a record...")
        let user: [String: Any] = [
            "_type": "User",
            "id": Int64(1),
            "name": "Alice",
            "email": "alice@example.com",
            "age": Int64(30)
        ]

        try await database.withRecordContext { context in
            try await recordStore.saveRecord(user, context: context)
            print("   ✓ Record inserted\n")
        }

        // Load the record
        print("5. Loading record by primary key...")
        let loaded = try await database.withRecordContext { context in
            try await recordStore.loadRecord(primaryKey: Tuple(Int64(1)), context: context)
        }

        if let loaded = loaded {
            print("   ✓ Record loaded:")
            print("     - Name: \(loaded["name"] ?? "N/A")")
            print("     - Email: \(loaded["email"] ?? "N/A")")
            print("     - Age: \(loaded["age"] ?? "N/A")\n")
        }

        // Query records
        print("6. Querying records...")
        let query = RecordQuery(
            recordType: "User",
            filter: FieldQueryComponent(
                fieldName: "age",
                comparison: .greaterThanOrEquals,
                value: Int64(18)
            )
        )

        try await database.withRecordContext { context in
            let planner = RecordQueryPlanner(metaData: metaData)
            let plan = try planner.plan(query)
            let cursor = try await plan.execute(
                subspace: recordStore.subspace,
                serializer: DictionarySerializer(),
                context: context
            )

            print("   Query results:")
            var count = 0
            for try await record in cursor {
                count += 1
                print("     - \(record["name"] ?? "N/A") (\(record["email"] ?? "N/A"))")
            }
            print("   ✓ Found \(count) record(s)\n")
        }

        print("Example completed successfully!")
    }
}
