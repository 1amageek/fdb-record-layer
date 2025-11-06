import Testing
@testable import FDBRecordLayer

@Suite("MetaDataEvolutionValidator Tests")
struct MetaDataEvolutionValidatorTests {

    // MARK: - Record Type Validation Tests

    @Test("Record type removal is detected")
    func recordTypeRemovalDetected() throws {
        // Old metadata with two record types
        let oldUserType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )
        let oldOrderType = RecordType(
            name: "Order",
            primaryKey: FieldKeyExpression(fieldName: "orderID")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [oldUserType, oldOrderType],
            indexes: []
        )

        // New metadata with only User type (Order removed)
        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [oldUserType],
            indexes: []
        )

        // Validate
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        let result = validator.validate()

        #expect(!result.isValid)
        #expect(result.errorCount == 1)
        #expect(result.errors.first?.category == .recordTypeRemoved)
        #expect(result.errors.first?.recordTypeName == "Order")
    }

    @Test("Record type addition is allowed")
    func recordTypeAdditionAllowed() throws {
        // Old metadata with one record type
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: []
        )

        // New metadata with additional record type
        let orderType = RecordType(
            name: "Order",
            primaryKey: FieldKeyExpression(fieldName: "orderID")
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType, orderType],
            indexes: []
        )

        // Validate
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        let result = validator.validate()

        #expect(result.isValid)
        #expect(result.errorCount == 0)
    }

    // MARK: - Primary Key Validation Tests

    @Test("Primary key change is detected")
    func primaryKeyChangeDetected() throws {
        // Old metadata with single-field primary key
        let oldUserType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [oldUserType],
            indexes: []
        )

        // New metadata with composite primary key
        let newUserType = RecordType(
            name: "User",
            primaryKey: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "tenantID"),
                FieldKeyExpression(fieldName: "userID")
            ])
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [newUserType],
            indexes: []
        )

        // Validate
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        let result = validator.validate()

        #expect(!result.isValid)
        #expect(result.errors.contains { $0.category == .primaryKeyChanged })
    }

    // MARK: - Index Validation Tests

    @Test("Index removal without FormerIndex is detected")
    func indexRemovalWithoutFormerIndexDetected() throws {
        // Old metadata with index
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: [emailIndex]
        )

        // New metadata without index and no FormerIndex
        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: []
        )

        // Validate
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        let result = validator.validate()

        #expect(!result.isValid)
        #expect(result.errors.first?.category == .indexRemovedWithoutFormer)
        #expect(result.errors.first?.indexName == "user_by_email")
    }

    @Test("Index removal with FormerIndex is allowed")
    func indexRemovalWithFormerIndexAllowed() throws {
        // Old metadata with index
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: [emailIndex]
        )

        // New metadata with FormerIndex
        let formerIndex = FormerIndex(
            name: "user_by_email",
            addedVersion: 1,
            removedVersion: 2
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: [],
            formerIndexes: [formerIndex]
        )

        // Validate
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        let result = validator.validate()

        #expect(result.isValid)
        #expect(result.errorCount == 0)
    }

    @Test("Index type change without allowRebuild is detected")
    func indexTypeChangeWithoutAllowRebuildDetected() throws {
        // Old metadata with value index
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let ageIndex = Index(
            name: "user_by_age",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "age")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: [ageIndex]
        )

        // New metadata with count index (different type)
        let countIndex = Index(
            name: "user_by_age",
            type: .count,
            rootExpression: FieldKeyExpression(fieldName: "age")
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: [countIndex]
        )

        // Validate without allowing rebuilds
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData,
            allowIndexRebuilds: false
        )

        let result = validator.validate()

        #expect(!result.isValid)
        #expect(result.errors.first?.category == .indexFormatChanged)
    }

    @Test("Index type change with allowRebuild is allowed")
    func indexTypeChangeWithAllowRebuildAllowed() throws {
        // Old metadata with value index
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let ageIndex = Index(
            name: "user_by_age",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "age")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: [ageIndex]
        )

        // New metadata with count index (different type)
        let countIndex = Index(
            name: "user_by_age",
            type: .count,
            rootExpression: FieldKeyExpression(fieldName: "age")
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: [countIndex]
        )

        // Validate with allowing rebuilds
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData,
            allowIndexRebuilds: true
        )

        let result = validator.validate()

        #expect(result.isValid)
        #expect(result.errorCount == 0)
    }

    // MARK: - FormerIndex Conflict Tests

    @Test("New index conflicts with FormerIndex")
    func newIndexConflictsWithFormerIndex() throws {
        // Old metadata with former index
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let formerIndex = FormerIndex(
            name: "old_email_index",
            addedVersion: 1,
            removedVersion: 2
        )

        let oldMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: [],
            formerIndexes: [formerIndex]
        )

        // New metadata tries to reuse the former index name
        let newEmailIndex = Index(
            name: "old_email_index",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let newMetaData = try RecordMetaData(
            version: 3,
            recordTypes: [userType],
            indexes: [newEmailIndex],
            formerIndexes: [formerIndex]
        )

        // Validate
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        let result = validator.validate()

        #expect(!result.isValid)
        #expect(result.errors.contains { $0.category == .formerIndexConflict })
    }

    // MARK: - Version Validation Tests

    @Test("Version must not decrease")
    func versionMustNotDecrease() throws {
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let oldMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: []
        )

        let newMetaData = try RecordMetaData(
            version: 1,  // Lower version
            recordTypes: [userType],
            indexes: []
        )

        // Should throw error during initialization
        #expect(throws: RecordLayerError.self) {
            try MetaDataEvolutionValidator(
                oldMetaData: oldMetaData,
                newMetaData: newMetaData
            )
        }
    }

    // MARK: - Convenience Method Tests

    @Test("Static validateEvolution method works")
    func staticValidateEvolutionMethod() throws {
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: []
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: []
        )

        let result = try MetaDataEvolutionValidator.validateEvolution(
            from: oldMetaData,
            to: newMetaData
        )

        #expect(result.isValid)
    }

    @Test("validateAndThrow does not throw on valid evolution")
    func validateAndThrowDoesNotThrow() throws {
        // Valid evolution
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: []
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: []
        )

        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        // Should not throw
        #expect(throws: Never.self) {
            try validator.validateAndThrow()
        }
    }

    @Test("validateAndThrow throws on invalid evolution")
    func validateAndThrowThrows() throws {
        // Invalid evolution (record type removed)
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let orderType = RecordType(
            name: "Order",
            primaryKey: FieldKeyExpression(fieldName: "orderID")
        )

        let oldMetaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType, orderType],
            indexes: []
        )

        let newMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],  // Order removed
            indexes: []
        )

        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        // Should throw
        #expect(throws: MetaDataEvolutionValidator.ValidationError.self) {
            try validator.validateAndThrow()
        }
    }

    // MARK: - FormerIndex Inheritance Tests (Critical Fixes)

    @Test("FormerIndex removal is detected", .tags(.critical))
    func formerIndexRemovalDetected() throws {
        // Version 1: Index exists
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let v1 = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: [emailIndex]
        )

        // Version 2: Index removed, FormerIndex added
        let formerIndex = FormerIndex(
            name: "user_by_email",
            addedVersion: 1,
            removedVersion: 2
        )

        let v2 = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: [],
            formerIndexes: [formerIndex]
        )

        // Version 3: FormerIndex REMOVED (should be error!)
        let v3 = try RecordMetaData(
            version: 3,
            recordTypes: [userType],
            indexes: [],
            formerIndexes: []  // FormerIndex removed
        )

        // Validate v1 -> v2 (should be valid)
        let validator12 = try MetaDataEvolutionValidator(
            oldMetaData: v1,
            newMetaData: v2
        )
        let result12 = validator12.validate()
        #expect(result12.isValid)

        // Validate v2 -> v3 (should be invalid - FormerIndex removed)
        let validator23 = try MetaDataEvolutionValidator(
            oldMetaData: v2,
            newMetaData: v3
        )
        let result23 = validator23.validate()
        #expect(!result23.isValid)
        #expect(result23.errors.contains { $0.category == .formerIndexRemoved })
        #expect(result23.errors.contains { error in
            error.indexName == "user_by_email" &&
            error.message.contains("was removed")
        })
    }

    @Test("FormerIndex version change is detected", .tags(.critical))
    func formerIndexVersionChangeDetected() throws {
        // Old metadata with FormerIndex
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let formerIndex = FormerIndex(
            name: "old_email_index",
            addedVersion: 1,
            removedVersion: 2
        )

        let oldMetaData = try RecordMetaData(
            version: 2,
            recordTypes: [userType],
            indexes: [],
            formerIndexes: [formerIndex]
        )

        // New metadata with modified FormerIndex (version changed)
        let modifiedFormerIndex = FormerIndex(
            name: "old_email_index",
            addedVersion: 1,
            removedVersion: 3  // Changed!
        )

        let newMetaData = try RecordMetaData(
            version: 3,
            recordTypes: [userType],
            indexes: [],
            formerIndexes: [modifiedFormerIndex]
        )

        // Validate
        let validator = try MetaDataEvolutionValidator(
            oldMetaData: oldMetaData,
            newMetaData: newMetaData
        )

        let result = validator.validate()
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.category == .formerIndexRemoved })
        #expect(result.errors.contains { error in
            error.message.contains("version changed")
        })
    }

    @Test("FormerIndex version validation works")
    func formerIndexVersionValidation() {
        // Valid: removedVersion >= addedVersion
        let validFormerIndex = FormerIndex(
            name: "test_index",
            addedVersion: 1,
            removedVersion: 5
        )
        #expect(validFormerIndex.addedVersion == 1)
        #expect(validFormerIndex.removedVersion == 5)

        // Valid: removedVersion == addedVersion (edge case)
        let edgeCaseFormerIndex = FormerIndex(
            name: "test_index",
            addedVersion: 3,
            removedVersion: 3
        )
        #expect(edgeCaseFormerIndex.addedVersion == 3)
        #expect(edgeCaseFormerIndex.removedVersion == 3)
    }

    @Test("removeIndexAsFormer method works correctly", .tags(.critical))
    func removeIndexAsFormerMethod() throws {
        // Create metadata with an index
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "userID")
        )

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let metaData = try RecordMetaData(
            version: 1,
            recordTypes: [userType],
            indexes: [emailIndex]
        )

        // Verify index exists
        #expect(throws: Never.self) {
            _ = try metaData.getIndex("user_by_email")
        }

        // Remove index as former
        try metaData.removeIndexAsFormer(
            indexName: "user_by_email",
            addedVersion: 1,
            removedVersion: 2
        )

        // Verify index is removed
        #expect(throws: RecordLayerError.self) {
            _ = try metaData.getIndex("user_by_email")
        }

        // Verify FormerIndex is added
        let formerIndex = metaData.getFormerIndex("user_by_email")
        #expect(formerIndex != nil)
        #expect(formerIndex?.name == "user_by_email")
        #expect(formerIndex?.addedVersion == 1)
        #expect(formerIndex?.removedVersion == 2)
    }

    @Test("FormerIndex.from method creates correct instance")
    func formerIndexFromMethod() {
        // Create an index
        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        // Create FormerIndex from index
        let formerIndex = FormerIndex.from(
            index: emailIndex,
            addedVersion: 1,
            removedVersion: 5
        )

        #expect(formerIndex.name == "user_by_email")
        #expect(formerIndex.addedVersion == 1)
        #expect(formerIndex.removedVersion == 5)
        #expect(formerIndex.formerName == nil)
    }
}

// MARK: - Test Tags

extension Tag {
    @Tag static var critical: Self
}
