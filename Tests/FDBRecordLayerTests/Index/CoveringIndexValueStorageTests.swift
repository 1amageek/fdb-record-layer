import Testing
import Foundation
 import FDBRecordCore
import Synchronization
@testable import FoundationDB
@testable import FDBRecordLayer

// MARK: - Test Record Type (defined outside suite for macro compatibility)

@Recordable
struct CoveringTestUser {#PrimaryKey<CoveringTestUser>([\.userID])

    
    var userID: Int64
    var name: String
    var email: String
    var city: String
    var age: Int32
}

/// Tests for Covering Index value storage (Phase 2A)
///
/// Test Coverage:
/// 1. Covering field values stored in index value
/// 2. Non-covering index still stores empty value (backward compatible)
/// 3. Multiple covering fields packed as Tuple
/// 4. Covering fields evaluated correctly via RecordAccess
/// 5. Index value format matches expected Tuple encoding
@Suite("Covering Index Value Storage Tests", .serialized)
struct CoveringIndexValueStorageTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Helper Functions

    private func setupDatabase() async throws -> (any DatabaseProtocol, Subspace) {
        let database = try FDBClient.openDatabase()

        // Clear test data
        let testSubspace = Subspace(prefix: [0xFE, 0xFF] + "covering_value_test".data(using: .utf8)!)
        try await database.withTransaction { transaction in
            transaction.clearRange(beginKey: testSubspace.prefix, endKey: testSubspace.prefix + [0xFF])
        }

        return (database, testSubspace)
    }

    // MARK: - Tests: Covering Field Value Storage

    @Test("Covering index stores field values in index value")
    func coveringIndexStoresFieldValues() async throws {
        let (database, testSubspace) = try await setupDatabase()

        // Create covering index: indexed on city, covers name and email
        let coveringIndex = Index.covering(
            named: "user_by_city_covering",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "email")
            ],
            recordTypes: ["CoveringTestUser"]
        )

        let indexSubspace = testSubspace.subspace("I").subspace(coveringIndex.name)
        let recordSubspace = testSubspace.subspace("R")

        // Create index maintainer
        let maintainer = GenericValueIndexMaintainer<CoveringTestUser>(
            index: coveringIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        let user = CoveringTestUser(
            userID: 1,
            name: "Alice",
            email: "alice@example.com",
            city: "Tokyo",
            age: 30
        )

        let recordAccess = GenericRecordAccess<CoveringTestUser>()

        // Update index
        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: nil,
                newRecord: user,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Verify index entry
        try await database.withTransaction { transaction in
            // Expected key: <indexSubspace><city><userID>
            let expectedKey = indexSubspace.pack(Tuple("Tokyo", Int64(1)))

            guard let indexValue = try await transaction.getValue(for: expectedKey, snapshot: true) else {
                Issue.record("Index entry not found")
                return
            }

            // Verify index value is not empty (covering index)
            #expect(!indexValue.isEmpty, "Covering index should have non-empty value")

            // Unpack and verify covering field values
            let coveringTuple = try Tuple.unpack(from: indexValue)
            #expect(coveringTuple.count == 2, "Should have 2 covering fields")

            // Verify covering field values
            let storedName = coveringTuple[0] as? String
            let storedEmail = coveringTuple[1] as? String

            #expect(storedName == "Alice")
            #expect(storedEmail == "alice@example.com")
        }
    }

    @Test("Non-covering index stores empty value (backward compatible)")
    func nonCoveringIndexStoresEmptyValue() async throws {
        let (database, testSubspace) = try await setupDatabase()

        // Create regular index (no covering fields)
        let regularIndex = Index.value(
            named: "user_by_city",
            on: FieldKeyExpression(fieldName: "city"),
            recordTypes: ["CoveringTestUser"]
        )

        let indexSubspace = testSubspace.subspace("I").subspace(regularIndex.name)
        let recordSubspace = testSubspace.subspace("R")

        let maintainer = GenericValueIndexMaintainer<CoveringTestUser>(
            index: regularIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        let user = CoveringTestUser(
            userID: 1,
            name: "Bob",
            email: "bob@example.com",
            city: "Osaka",
            age: 25
        )

        let recordAccess = GenericRecordAccess<CoveringTestUser>()

        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: nil,
                newRecord: user,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Verify index entry has empty value
        try await database.withTransaction { transaction in
            let expectedKey = indexSubspace.pack(Tuple("Osaka", Int64(1)))

            guard let indexValue = try await transaction.getValue(for: expectedKey, snapshot: true) else {
                Issue.record("Index entry not found")
                return
            }

            // Non-covering index should have empty value
            #expect(indexValue.isEmpty, "Non-covering index should have empty value")
        }
    }

    @Test("Multiple covering fields stored in correct order")
    func multipleCoveringFieldsInOrder() async throws {
        let (database, testSubspace) = try await setupDatabase()

        // Create covering index with 3 covering fields
        let coveringIndex = Index.covering(
            named: "user_by_city_multi_covering",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "email"),
                FieldKeyExpression(fieldName: "age")
            ],
            recordTypes: ["CoveringTestUser"]
        )

        let indexSubspace = testSubspace.subspace("I").subspace(coveringIndex.name)
        let recordSubspace = testSubspace.subspace("R")

        let maintainer = GenericValueIndexMaintainer<CoveringTestUser>(
            index: coveringIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        let user = CoveringTestUser(
            userID: 2,
            name: "Charlie",
            email: "charlie@example.com",
            city: "Kyoto",
            age: 28
        )

        let recordAccess = GenericRecordAccess<CoveringTestUser>()

        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: nil,
                newRecord: user,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Verify covering fields stored in correct order
        try await database.withTransaction { transaction in
            let expectedKey = indexSubspace.pack(Tuple("Kyoto", Int64(2)))

            guard let indexValue = try await transaction.getValue(for: expectedKey, snapshot: true) else {
                Issue.record("Index entry not found")
                return
            }

            let coveringTuple = try Tuple.unpack(from: indexValue)
            #expect(coveringTuple.count == 3)

            // Verify order: name, email, age
            #expect(coveringTuple[0] as? String == "Charlie")
            #expect(coveringTuple[1] as? String == "charlie@example.com")
            // Note: Int32 is serialized as Int64 in Tuple encoding
            #expect(coveringTuple[2] as? Int64 == 28)
        }
    }

    @Test("Covering index with composite key stores covering fields")
    func compositeKeyCoveringIndex() async throws {
        let (database, testSubspace) = try await setupDatabase()

        // Create covering index with composite key (city + age)
        let compositeExpr = ConcatenateKeyExpression(children: [
            FieldKeyExpression(fieldName: "city"),
            FieldKeyExpression(fieldName: "age")
        ])

        let coveringIndex = Index.covering(
            named: "user_by_city_age_covering",
            on: compositeExpr,
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "email")
            ],
            recordTypes: ["CoveringTestUser"]
        )

        let indexSubspace = testSubspace.subspace("I").subspace(coveringIndex.name)
        let recordSubspace = testSubspace.subspace("R")

        let maintainer = GenericValueIndexMaintainer<CoveringTestUser>(
            index: coveringIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        let user = CoveringTestUser(
            userID: 3,
            name: "Diana",
            email: "diana@example.com",
            city: "Nagoya",
            age: 35
        )

        let recordAccess = GenericRecordAccess<CoveringTestUser>()

        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: nil,
                newRecord: user,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Verify index structure
        try await database.withTransaction { transaction in
            // Key: <indexSubspace><city><age><userID>
            let expectedKey = indexSubspace.pack(Tuple("Nagoya", 35, Int64(3)))

            guard let indexValue = try await transaction.getValue(for: expectedKey, snapshot: true) else {
                Issue.record("Index entry not found")
                return
            }

            // Value: Tuple(name, email)
            let coveringTuple = try Tuple.unpack(from: indexValue)
            #expect(coveringTuple.count == 2)
            #expect(coveringTuple[0] as? String == "Diana")
            #expect(coveringTuple[1] as? String == "diana@example.com")
        }
    }

    @Test("Updating record updates covering field values")
    func updateRecordUpdatesCoveringValues() async throws {
        let (database, testSubspace) = try await setupDatabase()

        let coveringIndex = Index.covering(
            named: "user_by_city_update_test",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "email")
            ],
            recordTypes: ["CoveringTestUser"]
        )

        let indexSubspace = testSubspace.subspace("I").subspace(coveringIndex.name)
        let recordSubspace = testSubspace.subspace("R")

        let maintainer = GenericValueIndexMaintainer<CoveringTestUser>(
            index: coveringIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        let recordAccess = GenericRecordAccess<CoveringTestUser>()

        // Initial user
        let oldUser = CoveringTestUser(
            userID: 4,
            name: "Eve",
            email: "eve@example.com",
            city: "Fukuoka",
            age: 27
        )

        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: nil,
                newRecord: oldUser,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Updated user (name and email changed)
        let newUser = CoveringTestUser(
            userID: 4,
            name: "Evelyn",
            email: "evelyn@newdomain.com",
            city: "Fukuoka",
            age: 27
        )

        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: oldUser,
                newRecord: newUser,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Verify updated covering values
        try await database.withTransaction { transaction in
            let expectedKey = indexSubspace.pack(Tuple("Fukuoka", Int64(4)))

            guard let indexValue = try await transaction.getValue(for: expectedKey, snapshot: true) else {
                Issue.record("Index entry not found after update")
                return
            }

            let coveringTuple = try Tuple.unpack(from: indexValue)

            // Should have updated values
            #expect(coveringTuple[0] as? String == "Evelyn")
            #expect(coveringTuple[1] as? String == "evelyn@newdomain.com")
        }
    }

    @Test("Deleting record removes covering index entry")
    func deleteRecordRemovesCoveringEntry() async throws {
        let (database, testSubspace) = try await setupDatabase()

        let coveringIndex = Index.covering(
            named: "user_by_city_delete_test",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [
                FieldKeyExpression(fieldName: "name")
            ],
            recordTypes: ["CoveringTestUser"]
        )

        let indexSubspace = testSubspace.subspace("I").subspace(coveringIndex.name)
        let recordSubspace = testSubspace.subspace("R")

        let maintainer = GenericValueIndexMaintainer<CoveringTestUser>(
            index: coveringIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        let user = CoveringTestUser(
            userID: 5,
            name: "Frank",
            email: "frank@example.com",
            city: "Sapporo",
            age: 40
        )

        let recordAccess = GenericRecordAccess<CoveringTestUser>()

        // Create index entry
        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: nil,
                newRecord: user,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Delete index entry
        try await database.withTransaction { transaction in
            try await maintainer.updateIndex(
                oldRecord: user,
                newRecord: nil,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        // Verify entry removed
        try await database.withTransaction { transaction in
            let expectedKey = indexSubspace.pack(Tuple("Sapporo", Int64(5)))
            let indexValue = try await transaction.getValue(for: expectedKey, snapshot: true)

            #expect(indexValue == nil, "Index entry should be removed")
        }
    }
}
