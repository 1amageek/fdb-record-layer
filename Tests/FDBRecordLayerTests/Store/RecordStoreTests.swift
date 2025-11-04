import Testing
import Foundation
import FoundationDB
@testable import FDBRecordLayer

@Suite("RecordStore Tests", .disabled("Needs rewriting for new Recordable-based API (Phase 1)"))
struct RecordStoreTests {

    // NOTE: This entire test suite needs to be rewritten for the new Recordable-based API.
    // The old dictionary-based API is no longer supported.
    // Tests are wrapped in #if false to prevent compilation errors.

#if false
    // MARK: - Test Helpers

    struct UserRecord: Codable, Equatable {
        let id: Int64
        let name: String
        let email: String
        let age: Int
    }

    func createTestStore() throws -> (RecordStore, any DatabaseProtocol, Subspace) {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(rootPrefix: "test_store_\(UUID().uuidString)")

        // Create metadata
        let primaryKey = FieldKeyExpression(fieldName: "id")
        let userType = RecordType(name: "User", primaryKey: primaryKey)

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email"),
            recordTypes: ["User"]
        )

        let ageIndex = Index(
            name: "user_by_age",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "age"),
            recordTypes: ["User"]
        )

        let metaData = try RecordMetaDataBuilder()
            .addRecordType(userType)
            .addIndex(emailIndex)
            .addIndex(ageIndex)
            .build()

        // Note: This test needs to be rewritten for the new Recordable-based API
        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData
        )

        return (store, db, subspace)
    }

    func cleanup(database: any DatabaseProtocol, subspace: Subspace) async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - CRUD Tests

    @Test("Save and load record")
    func saveAndLoadRecord() async throws {
        let (store, db, subspace) = try createTestStore()

        try await db.withRecordContext { context in
            let user: [String: Any] = [
                "_type": "User",
                "id": Int64(1),
                "name": "Alice",
                "email": "alice@example.com",
                "age": 30
            ]

            // Save record
            try await store.save(user, context: context)

            // Fetch record
            let primaryKey = Tuple(Int64(1))
            let loaded = try await store.fetch(primaryKey: primaryKey, context: context)

            #expect(loaded != nil)
            #expect(loaded?["name"] as? String == "Alice")
            #expect(loaded?["email"] as? String == "alice@example.com")
            #expect(loaded?["age"] as? Int == 30)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Fetch non-existent record returns nil")
    func fetchNonExistentRecord() async throws {
        let (store, db, subspace) = try createTestStore()

        try await db.withRecordContext { context in
            let primaryKey = Tuple(Int64(999))
            let loaded = try await store.fetch(primaryKey: primaryKey, context: context)

            #expect(loaded == nil)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Update existing record")
    func updateExistingRecord() async throws {
        let (store, db, subspace) = try createTestStore()

        try await db.withRecordContext { context in
            // Save initial record
            let user: [String: Any] = [
                "_type": "User",
                "id": Int64(2),
                "name": "Bob",
                "email": "bob@example.com",
                "age": 25
            ]
            try await store.save(user, context: context)

            // Update record (same primary key, different values)
            let updatedUser: [String: Any] = [
                "_type": "User",
                "id": Int64(2),
                "name": "Bob Smith",
                "email": "bob.smith@example.com",
                "age": 26
            ]
            try await store.save(updatedUser, context: context)

            // Fetch and verify
            let primaryKey = Tuple(Int64(2))
            let loaded = try await store.fetch(primaryKey: primaryKey, context: context)

            #expect(loaded?["name"] as? String == "Bob Smith")
            #expect(loaded?["email"] as? String == "bob.smith@example.com")
            #expect(loaded?["age"] as? Int == 26)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Delete record")
    func deleteRecord() async throws {
        let (store, db, subspace) = try createTestStore()

        try await db.withRecordContext { context in
            // Save record
            let user: [String: Any] = [
                "_type": "User",
                "id": Int64(3),
                "name": "Charlie",
                "email": "charlie@example.com",
                "age": 35
            ]
            try await store.save(user, context: context)

            // Verify it exists
            let primaryKey = Tuple(Int64(3))
            let loaded1 = try await store.fetch(primaryKey: primaryKey, context: context)
            #expect(loaded1 != nil)

            // Delete record
            try await store.delete(primaryKey: primaryKey, context: context)

            // Verify it's deleted
            let loaded2 = try await store.fetch(primaryKey: primaryKey, context: context)
            #expect(loaded2 == nil)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Delete non-existent record does not throw")
    func deleteNonExistentRecord() async throws {
        let (store, db, subspace) = try createTestStore()

        try await db.withRecordContext { context in
            let primaryKey = Tuple(Int64(999))

            // Should not throw
            try await store.delete(primaryKey: primaryKey, context: context)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Save multiple records in same transaction")
    func saveMultipleRecords() async throws {
        let (store, db, subspace) = try createTestStore()

        try await db.withRecordContext { context in
            // Save multiple records
            for i in 10..<15 {
                let user: [String: Any] = [
                    "_type": "User",
                    "id": Int64(i),
                    "name": "User\(i)",
                    "email": "user\(i)@example.com",
                    "age": 20 + i
                ]
                try await store.save(user, context: context)
            }

            // Verify all records exist
            for i in 10..<15 {
                let primaryKey = Tuple(Int64(i))
                let loaded = try await store.fetch(primaryKey: primaryKey, context: context)
                #expect(loaded != nil)
                #expect(loaded?["name"] as? String == "User\(i)")
            }
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Multiple saves in same transaction are visible to each other")
    func multipleСavesInTransaction() async throws {
        let (store, db, subspace) = try createTestStore()

        try await db.withRecordContext { context in
            // Save first record
            let user1: [String: Any] = [
                "_type": "User",
                "id": Int64(100),
                "name": "User100",
                "email": "user100@example.com",
                "age": 40
            ]
            try await store.save(user1, context: context)

            // Should be visible in same transaction
            let primaryKey1 = Tuple(Int64(100))
            let loaded1 = try await store.fetch(primaryKey: primaryKey1, context: context)
            #expect(loaded1 != nil)
            #expect(loaded1?["name"] as? String == "User100")

            // Save second record
            let user2: [String: Any] = [
                "_type": "User",
                "id": Int64(101),
                "name": "User101",
                "email": "user101@example.com",
                "age": 45
            ]
            try await store.save(user2, context: context)

            // Both should be visible
            let primaryKey2 = Tuple(Int64(101))
            let loaded2 = try await store.fetch(primaryKey: primaryKey2, context: context)
            #expect(loaded2 != nil)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Record with complex primary key")
    func complexPrimaryKey() async throws {
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(rootPrefix: "test_complex_key_\(UUID().uuidString)")

        // Create metadata with compound primary key
        let primaryKey = ConcatenateKeyExpression(children: [
            FieldKeyExpression(fieldName: "tenantId"),
            FieldKeyExpression(fieldName: "userId")
        ])

        let userType = RecordType(name: "TenantUser", primaryKey: primaryKey)

        let metaData = try RecordMetaDataBuilder()
            .addRecordType(userType)
            .build()

        // Note: This test needs to be rewritten for the new Recordable-based API
        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData
        )

        try await db.withRecordContext { context in
            let user: [String: Any] = [
                "_type": "TenantUser",
                "tenantId": "tenant1",
                "userId": Int64(123),
                "name": "Multi Key User"
            ]

            // Save with compound key
            try await store.save(user, context: context)

            // Fetch with compound key
            let compoundKey = Tuple("tenant1", Int64(123))
            let loaded = try await store.fetch(primaryKey: compoundKey, context: context)

            #expect(loaded != nil)
            #expect(loaded?["name"] as? String == "Multi Key User")
        }

        try await cleanup(database: db, subspace: subspace)
    }
#endif // false
}
