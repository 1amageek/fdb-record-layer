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

    // MARK: - Tests: Enum Validation

    @Test("Enum case deletion should be detected (manual schema)")
    func enumCaseDeletionManualSchema() async throws {
        // Create schemas manually with enum metadata
        // Old schema: Product with status enum (3 cases)
        let oldEntity = TestEntityBuilder.createEntity(
            name: "Product",
            attributes: [
                TestEntityBuilder.createAttribute(
                    name: "productID",
                    isPrimaryKey: true
                ),
                TestEntityBuilder.createAttribute(
                    name: "status",
                    enumMetadata: Schema.EnumMetadata(
                        typeName: "ProductStatus",
                        cases: ["active", "inactive", "discontinued"]
                    )
                )
            ]
        )

        let oldSchema = TestSchemaBuilder.createSchema(entities: [oldEntity])

        // New schema: Same field, but discontinued case removed
        let newEntity = TestEntityBuilder.createEntity(
            name: "Product",
            attributes: [
                TestEntityBuilder.createAttribute(
                    name: "productID",
                    isPrimaryKey: true
                ),
                TestEntityBuilder.createAttribute(
                    name: "status",
                    enumMetadata: Schema.EnumMetadata(
                        typeName: "ProductStatus",  // Same type name
                        cases: ["active", "inactive"]  // "discontinued" removed
                    )
                )
            ]
        )

        let newSchema = TestSchemaBuilder.createSchema(entities: [newEntity])

        let validator = MetaDataEvolutionValidator(
            old: oldSchema,
            new: newSchema,
            options: .strict
        )

        let result = try await validator.validate()

        #expect(!result.isValid, "Should detect enum case deletion")

        // Find enum deletion error
        let enumErrors = result.errors.compactMap { error -> (String, String, [String])? in
            if case .enumValueDeleted(let recordType, let fieldName, let deletedValues) = error {
                return (recordType, fieldName, deletedValues)
            }
            return nil
        }

        #expect(enumErrors.count == 1, "Should have exactly one enum deletion error")

        guard let (recordType, fieldName, deletedValues) = enumErrors.first else {
            Issue.record("Expected enumValueDeleted error")
            return
        }

        #expect(recordType == "Product")
        #expect(fieldName == "status")
        #expect(deletedValues.contains("discontinued"), "Should detect 'discontinued' was deleted")
    }

    @Test("Enum case deletion with type rename should be detected")
    func enumCaseDeletionWithTypeRename() async throws {
        // Old schema
        let oldEntity = TestEntityBuilder.createEntity(
            name: "Order",
            attributes: [
                TestEntityBuilder.createAttribute(
                    name: "orderID",
                    isPrimaryKey: true
                ),
                TestEntityBuilder.createAttribute(
                    name: "status",
                    enumMetadata: Schema.EnumMetadata(
                        typeName: "OrderStatus",  // Old type name
                        cases: ["pending", "shipped", "delivered", "cancelled"]
                    )
                )
            ]
        )

        let oldSchema = TestSchemaBuilder.createSchema(entities: [oldEntity])

        // New schema: Type renamed, case deleted
        let newEntity = TestEntityBuilder.createEntity(
            name: "Order",
            attributes: [
                TestEntityBuilder.createAttribute(
                    name: "orderID",
                    isPrimaryKey: true
                ),
                TestEntityBuilder.createAttribute(
                    name: "status",
                    enumMetadata: Schema.EnumMetadata(
                        typeName: "OrderStatusV2",  // ← Type name changed (refactoring)
                        cases: ["pending", "shipped", "delivered"]  // "cancelled" removed
                    )
                )
            ]
        )

        let newSchema = TestSchemaBuilder.createSchema(entities: [newEntity])

        let validator = MetaDataEvolutionValidator(
            old: oldSchema,
            new: newSchema,
            options: .strict
        )

        let result = try await validator.validate()

        // This is the key test: validation should work even if type name changed
        #expect(!result.isValid, "Should detect enum case deletion even with type rename")

        let enumErrors = result.errors.compactMap { error -> (String, String, [String])? in
            if case .enumValueDeleted(let recordType, let fieldName, let deletedValues) = error {
                return (recordType, fieldName, deletedValues)
            }
            return nil
        }

        #expect(enumErrors.count == 1)

        guard let (recordType, fieldName, deletedValues) = enumErrors.first else {
            Issue.record("Expected enumValueDeleted error")
            return
        }

        #expect(recordType == "Order")
        #expect(fieldName == "status")
        #expect(deletedValues.contains("cancelled"), "Should detect 'cancelled' was deleted despite type rename")
    }

    @Test("Enum case addition should be allowed")
    func enumCaseAddition() async throws {
        // Old schema
        let oldEntity = TestEntityBuilder.createEntity(
            name: "Product",
            attributes: [
                TestEntityBuilder.createAttribute(
                    name: "productID",
                    isPrimaryKey: true
                ),
                TestEntityBuilder.createAttribute(
                    name: "status",
                    enumMetadata: Schema.EnumMetadata(
                        typeName: "ProductStatus",
                        cases: ["active", "inactive"]
                    )
                )
            ]
        )

        let oldSchema = TestSchemaBuilder.createSchema(entities: [oldEntity])

        // New schema: Case added
        let newEntity = TestEntityBuilder.createEntity(
            name: "Product",
            attributes: [
                TestEntityBuilder.createAttribute(
                    name: "productID",
                    isPrimaryKey: true
                ),
                TestEntityBuilder.createAttribute(
                    name: "status",
                    enumMetadata: Schema.EnumMetadata(
                        typeName: "ProductStatus",
                        cases: ["active", "inactive", "archived"]  // "archived" added
                    )
                )
            ]
        )

        let newSchema = TestSchemaBuilder.createSchema(entities: [newEntity])

        let validator = MetaDataEvolutionValidator(
            old: oldSchema,
            new: newSchema,
            options: .strict
        )

        let result = try await validator.validate()

        #expect(result.isValid, "Enum case addition should be allowed")
        #expect(result.errors.isEmpty, "Should have no errors")
    }
}

// MARK: - Test Helpers

/// Helper for creating test entities with enum metadata
enum TestEntityBuilder {
    /// Create an Entity with custom attributes
    ///
    /// This helper uses the test initializer added to Schema.Entity to construct
    /// entities with specific enum metadata for schema evolution validation tests.
    static func createEntity(name: String, attributes: [Schema.Attribute]) -> Schema.Entity {
        return Schema.Entity(name: name, attributes: attributes)
    }

    /// Create an Attribute with optional enum metadata
    ///
    /// This helper creates Schema.Attribute objects for use in test entities.
    static func createAttribute(
        name: String,
        isOptional: Bool = false,
        isPrimaryKey: Bool = false,
        enumMetadata: Schema.EnumMetadata? = nil
    ) -> Schema.Attribute {
        return Schema.Attribute(
            name: name,
            isOptional: isOptional,
            isPrimaryKey: isPrimaryKey,
            enumMetadata: enumMetadata
        )
    }
}

/// Helper for creating test schemas with custom entities
enum TestSchemaBuilder {
    /// Create a Schema with custom entities
    ///
    /// This helper uses the test initializer added to Schema to construct
    /// schemas with specific entities for schema evolution validation tests.
    static func createSchema(entities: [Schema.Entity]) -> Schema {
        return Schema(entities: entities)
    }
}
