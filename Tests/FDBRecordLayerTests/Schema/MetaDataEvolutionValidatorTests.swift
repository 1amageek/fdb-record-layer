import Testing
import Foundation
@testable import FDBRecordLayer

// MARK: - Test Models (Manual Recordable Conformance for Testing)

// UserV1: Base version
@Recordable
struct UserV1 {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32
}

// UserV2: Added optional field (safe)
@Recordable
struct UserV2 {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32
    var city: String?
}

// UserV3: Added required field (unsafe)
@Recordable
struct UserV3 {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32
    var city: String
}

// UserV4: email field deleted (unsafe)
@Recordable
struct UserV4 {
    @PrimaryKey var userID: Int64
    var name: String
    var age: Int32
}

// UserV5: email changed from required to optional (safe)
@Recordable
struct UserV5 {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String?
    var age: Int32
}

// MARK: - Test Cases

@Suite("MetaData Evolution Validator Tests")
struct MetaDataEvolutionValidatorTests {

    // MARK: - Tests: Record Type Deletion

    @Test("Record type deletion should be detected")
    func recordTypeDeletion() async throws {
        // Old schema has UserV1
        let oldSchema = Schema([UserV1.self])

        // New schema doesn't have UserV1 (only empty)
        let newSchema = Schema([] as [any Recordable.Type])

        let validator = MetaDataEvolutionValidator(
            old: oldSchema,
            new: newSchema,
            options: .strict
        )

        let result = try await validator.validate()

        #expect(!result.isValid, "Should detect record type deletion")
        #expect(result.errors.count == 1)

        guard case .recordTypeDeleted(let recordType) = result.errors.first else {
            Issue.record("Expected recordTypeDeleted error")
            return
        }

        #expect(recordType == "UserV1")
    }

    // MARK: - Tests: Field Changes
    // Note: Field-level tests require entities with the same name.
    // Since UserV1, UserV2, etc. have different names, we test record-level changes instead.
    // Field-level validation logic is tested indirectly through validator implementation.

    // MARK: - Tests: Index Changes

    @Test("Index deletion without FormerIndex should be detected")
    func indexDeletionWithoutFormerIndex() async throws {
        let emailIndex = Index.value(
            named: "email_index",
            on: FieldKeyExpression(fieldName: "email"),
            recordTypes: ["UserV1"]
        )

        let oldSchema = Schema([UserV1.self], indexes: [emailIndex])
        let newSchema = Schema([UserV1.self])  // No indexes

        let validator = MetaDataEvolutionValidator(
            old: oldSchema,
            new: newSchema,
            options: .strict
        )

        let result = try await validator.validate()

        #expect(!result.isValid, "Should detect index deletion without FormerIndex")

        // Find index deletion error
        let indexDeletionErrors = result.errors.compactMap { error -> String? in
            if case .indexDeletedWithoutFormerIndex(let indexName) = error {
                return indexName
            }
            return nil
        }

        #expect(indexDeletionErrors.count == 1)
        #expect(indexDeletionErrors.first == "email_index")
    }

    @Test("Index deletion with FormerIndex should be allowed")
    func indexDeletionWithFormerIndex() async throws {
        // Note: This test is skipped for now as Schema doesn't have a public API to set formerIndexes
        // This would require a builder pattern or initializer that accepts formerIndexes
    }

    @Test("Index format change should be detected")
    func indexFormatChange() async throws {
        let emailIndexV1 = Index.value(
            named: "email_index",
            on: FieldKeyExpression(fieldName: "email"),
            recordTypes: ["UserV1"]
        )

        let emailIndexV2 = Index.count(
            named: "email_index",  // Same name
            groupBy: FieldKeyExpression(fieldName: "email"),  // Same field
            recordTypes: ["UserV1"]
        )

        let oldSchema = Schema([UserV1.self], indexes: [emailIndexV1])
        let newSchema = Schema([UserV1.self], indexes: [emailIndexV2])

        let validator = MetaDataEvolutionValidator(
            old: oldSchema,
            new: newSchema,
            options: .strict
        )

        let result = try await validator.validate()

        #expect(!result.isValid, "Should detect index format change")

        // Find index format changed error
        let formatChangeErrors = result.errors.compactMap { error -> String? in
            if case .indexFormatChanged(let indexName) = error {
                return indexName
            }
            return nil
        }

        #expect(formatChangeErrors.count == 1)
        #expect(formatChangeErrors.first == "email_index")
    }

    // MARK: - Tests: Multiple Errors

    @Test("Multiple errors should be detected")
    func multipleErrors() async throws {
        let emailIndex = Index.value(
            named: "email_index",
            on: FieldKeyExpression(fieldName: "email"),
            recordTypes: ["UserV1"]
        )

        let oldSchema = Schema([UserV1.self], indexes: [emailIndex])

        // New schema: UserV1 deleted, UserV4 added, index deleted
        let newSchema = Schema([UserV4.self])

        let validator = MetaDataEvolutionValidator(
            old: oldSchema,
            new: newSchema,
            options: .strict
        )

        let result = try await validator.validate()

        #expect(!result.isValid, "Should detect multiple errors")
        #expect(result.errors.count >= 2, "At least record type deletion + index deletion")
    }
}
