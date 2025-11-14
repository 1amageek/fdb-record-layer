import Testing
import Foundation
import FDBRecordLayer

// MARK: - Test Types

@Recordable
struct UserWithIndexes {
    #PrimaryKey<UserWithIndexes>([\.userID])
    #Index<UserWithIndexes>([\.email])
    #Index<UserWithIndexes>([\.city, \.state])

    var userID: Int64
    var email: String
    var city: String
    var state: String
}

@Recordable
struct UserWithUniqueIndex {
    #PrimaryKey<UserWithUniqueIndex>([\.userID])
    #Unique<UserWithUniqueIndex>([\.email])

    var userID: Int64
    var email: String
    var name: String
}

@Recordable
struct UserWithoutIndexes {
    #PrimaryKey<UserWithoutIndexes>([\.userID])

    var userID: Int64
    var name: String
}

// MARK: - Tests

@Suite("Index Collection Tests")
struct IndexCollectionTests {

    @Test("IndexDefinitions generation from #Index macros")
    func indexDefinitionsGeneration() throws {
        // Test that @Recordable macro generates indexDefinitions property
        let indexDefs = UserWithIndexes.indexDefinitions

        #expect(indexDefs.count == 2, "Should have 2 index definitions")

        // Check email index
        let emailIndex = indexDefs.first { $0.fields == ["email"] }
        #expect(emailIndex != nil, "Email index should exist")
        #expect(emailIndex?.name == "UserWithIndexes_email_index")
        #expect(emailIndex?.recordType == "UserWithIndexes")
        #expect(emailIndex?.unique == false, "Email index should not be unique")

        // Check composite index
        let cityStateIndex = indexDefs.first { $0.fields == ["city", "state"] }
        #expect(cityStateIndex != nil, "City-state index should exist")
        #expect(cityStateIndex?.name == "UserWithIndexes_city_state_index")
        #expect(cityStateIndex?.recordType == "UserWithIndexes")
        #expect(cityStateIndex?.unique == false, "City-state index should not be unique")
    }

    @Test("Unique index definition from #Unique macro")
    func uniqueIndexDefinition() throws {
        // Test that #Unique macro generates IndexDefinition with unique=true
        let indexDefs = UserWithUniqueIndex.indexDefinitions

        #expect(indexDefs.count == 1, "Should have 1 index definition")

        let emailIndex = indexDefs.first
        #expect(emailIndex != nil, "Email index should exist")
        #expect(emailIndex?.name == "UserWithUniqueIndex_email_unique")
        #expect(emailIndex?.recordType == "UserWithUniqueIndex")
        #expect(emailIndex?.unique == true, "Email index should be unique")
    }

    @Test("No index definitions for types without macros")
    func noIndexDefinitions() throws {
        // Test that types without #Index/#Unique return empty array
        let indexDefs = UserWithoutIndexes.indexDefinitions

        #expect(indexDefs.count == 0, "Should have no index definitions")
    }

    @Test("Schema collects indexes from indexDefinitions")
    func schemaCollectsIndexes() throws {
        // Test that Schema collects indexes from indexDefinitions
        let schema = Schema([UserWithIndexes.self])

        #expect(schema.indexes.count == 2, "Schema should collect 2 indexes")

        // Check that indexes were converted correctly
        let emailIndex = schema.indexes.first { $0.name == "UserWithIndexes_email_index" }
        #expect(emailIndex != nil, "Email index should be in schema")
        #expect(emailIndex?.type == .value)
        #expect(emailIndex?.recordTypes == Set(["UserWithIndexes"]))

        let cityStateIndex = schema.indexes.first { $0.name == "UserWithIndexes_city_state_index" }
        #expect(cityStateIndex != nil, "City-state index should be in schema")
        #expect(cityStateIndex?.type == .value)
        #expect(cityStateIndex?.recordTypes == Set(["UserWithIndexes"]))
    }

    @Test("Schema index lookup by name")
    func schemaIndexLookup() throws {
        // Test that schema.index(named:) works correctly
        let schema = Schema([UserWithIndexes.self])

        let emailIndex = schema.index(named: "UserWithIndexes_email_index")
        #expect(emailIndex != nil, "Should find email index by name")

        let cityStateIndex = schema.index(named: "UserWithIndexes_city_state_index")
        #expect(cityStateIndex != nil, "Should find city-state index by name")

        let nonexistent = schema.index(named: "nonexistent_index")
        #expect(nonexistent == nil, "Should return nil for nonexistent index")
    }

    @Test("Schema indexes filtered by record type")
    func schemaIndexesForRecordType() throws {
        // Test that schema.indexes(for:) returns correct indexes
        let schema = Schema([UserWithIndexes.self])

        let userIndexes = schema.indexes(for: "UserWithIndexes")
        #expect(userIndexes.count == 2, "Should return 2 indexes for UserWithIndexes")

        let otherIndexes = schema.indexes(for: "NonexistentType")
        #expect(otherIndexes.count == 0, "Should return no indexes for nonexistent type")
    }

    @Test("Multiple types with indexes")
    func multipleTypesWithIndexes() throws {
        // Test that Schema collects indexes from multiple types
        let schema = Schema([
            UserWithIndexes.self,
            UserWithUniqueIndex.self,
            UserWithoutIndexes.self
        ])

        // UserWithIndexes: 2 indexes
        // UserWithUniqueIndex: 1 index
        // UserWithoutIndexes: 0 indexes
        #expect(schema.indexes.count == 3, "Schema should collect all indexes from all types")

        // Check that indexes are properly filtered by record type
        let userWithIndexesIndexes = schema.indexes(for: "UserWithIndexes")
        #expect(userWithIndexesIndexes.count == 2)

        let userWithUniqueIndexIndexes = schema.indexes(for: "UserWithUniqueIndex")
        #expect(userWithUniqueIndexIndexes.count == 1)

        let userWithoutIndexesIndexes = schema.indexes(for: "UserWithoutIndexes")
        #expect(userWithoutIndexesIndexes.count == 0)
    }

    @Test("Manual indexes merged with macro-declared indexes")
    func manualIndexesMergedWithMacroIndexes() throws {
        // Test that manually provided indexes are merged with macro-declared indexes
        let manualIndex = Index(
            name: "manual_index",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "name"),
            recordTypes: Set(["UserWithIndexes"])
        )

        let schema = Schema([UserWithIndexes.self], indexes: [manualIndex])

        // 2 macro-declared + 1 manual = 3 total
        #expect(schema.indexes.count == 3, "Should merge manual and macro-declared indexes")

        let manualFound = schema.index(named: "manual_index")
        #expect(manualFound != nil, "Manual index should be in schema")

        let macroFound = schema.index(named: "UserWithIndexes_email_index")
        #expect(macroFound != nil, "Macro-declared index should be in schema")
    }
}
