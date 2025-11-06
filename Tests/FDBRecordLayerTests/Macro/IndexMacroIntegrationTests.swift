import Testing
import Foundation
@testable import FDBRecordLayer

// MARK: - Test Models (File Level)

/// User model with simple indexes
@Recordable
struct IndexMacroUser {
    #Unique<IndexMacroUser>([\.email])
    #Index<IndexMacroUser>([\.createdAt])
    #Index<IndexMacroUser>([\.country, \.city], name: "location_index")

    @PrimaryKey var userID: Int64
    var email: String
    var name: String
    var country: String
    var city: String
    var createdAt: Int64
}

/// Product model with nested field indexes
@Recordable
struct IndexMacroProduct {
    #Unique<IndexMacroProduct>([\.sku])
    #Index<IndexMacroProduct>([\.category])
    #Index<IndexMacroProduct>([\.price])

    @PrimaryKey var productID: Int64
    var sku: String
    var name: String
    var category: String
    var price: Double
}

/// Order model with multiple indexes
@Recordable
struct IndexMacroOrder {
    #Index<IndexMacroOrder>([\.userID])
    #Index<IndexMacroOrder>([\.status])
    #Index<IndexMacroOrder>([\.createdAt])
    #Index<IndexMacroOrder>([\.userID, \.status], name: "user_status_index")

    @PrimaryKey var orderID: Int64
    var userID: Int64
    var status: String
    var createdAt: Int64
    var totalAmount: Double
}

/// Model without indexes
@Recordable
struct IndexMacroSimpleModel {
    @PrimaryKey var id: Int64
    var value: String
}

/// Model with only unique indexes
@Recordable
struct IndexMacroUniqueModel {
    #Unique<IndexMacroUniqueModel>([\.username])
    #Unique<IndexMacroUniqueModel>([\.email])

    @PrimaryKey var id: Int64
    var username: String
    var email: String
}

/// Model with only regular indexes
@Recordable
struct IndexMacroIndexedModel {
    #Index<IndexMacroIndexedModel>([\.field1])
    #Index<IndexMacroIndexedModel>([\.field2])
    #Index<IndexMacroIndexedModel>([\.field3])

    @PrimaryKey var id: Int64
    var field1: String
    var field2: String
    var field3: String
}

// MARK: - Tests

/// Integration tests for #Index and #Unique macros with @Recordable
///
/// These tests verify that:
/// 1. #Index and #Unique can be used inside @Recordable structs
/// 2. @Recordable correctly detects and references IndexDefinition properties
/// 3. No circular reference errors occur
/// 4. IndexDefinitions are properly registered
@Suite("Index Macro Integration Tests")
struct IndexMacroIntegrationTests {

    // MARK: - Compilation Tests

    @Test("@Recordable struct with #Index/#Unique compiles successfully")
    func testCompilation() {
        // If this test runs, it means the macro expansion succeeded
        // No circular reference error occurred
        #expect(IndexMacroUser.recordName == "IndexMacroUser")
        #expect(IndexMacroProduct.recordName == "IndexMacroProduct")
        #expect(IndexMacroOrder.recordName == "IndexMacroOrder")
    }

    @Test("IndexDefinition static properties are generated")
    func testIndexDefinitionProperties() {
        // Verify that @Recordable generated indexDefinitions from #Index and #Unique
        let indexDefs = IndexMacroUser.indexDefinitions
        // Find email unique index
        let userEmailIndex = indexDefs.first { $0.name == "IndexMacroUser_email_unique" }!
        #expect(userEmailIndex.name == "IndexMacroUser_email_unique")
        #expect(userEmailIndex.unique == true)

        // Find createdAt index
        let userCreatedAtIndex = indexDefs.first { $0.name == "IndexMacroUser_createdAt_index" }!
        #expect(userCreatedAtIndex.name == "IndexMacroUser_createdAt_index")
        #expect(userCreatedAtIndex.unique == false)

        // Find location compound index
        let userLocationIndex = indexDefs.first { $0.name == "location_index" }!
        #expect(userLocationIndex.name == "location_index")
        #expect(userLocationIndex.unique == false)
    }

    @Test("@Recordable generates indexDefinitions property")
    func testIndexDefinitionsProperty() {
        // Verify that @Recordable generated the indexDefinitions property
        let userIndexes = IndexMacroUser.indexDefinitions
        #expect(userIndexes.count == 3)

        // Check that all indexes are included
        let indexNames = Set(userIndexes.map { $0.name })
        #expect(indexNames.contains("IndexMacroUser_email_unique"))
        #expect(indexNames.contains("IndexMacroUser_createdAt_index"))
        #expect(indexNames.contains("location_index"))
    }

    @Test("Product model indexes are correct")
    func testProductIndexes() {
        let productIndexes = IndexMacroProduct.indexDefinitions
        #expect(productIndexes.count == 3)

        let indexNames = Set(productIndexes.map { $0.name })
        #expect(indexNames.contains("IndexMacroProduct_sku_unique"))
        #expect(indexNames.contains("IndexMacroProduct_category_index"))
        #expect(indexNames.contains("IndexMacroProduct_price_index"))

        // Verify unique constraint
        let skuIndex = productIndexes.first { $0.name == "IndexMacroProduct_sku_unique" }
        #expect(skuIndex?.unique == true)

        let categoryIndex = productIndexes.first { $0.name == "IndexMacroProduct_category_index" }
        #expect(categoryIndex?.unique == false)
    }

    @Test("Order model with multiple indexes")
    func testOrderIndexes() {
        let orderIndexes = IndexMacroOrder.indexDefinitions
        #expect(orderIndexes.count == 4)

        let indexNames = Set(orderIndexes.map { $0.name })
        #expect(indexNames.contains("IndexMacroOrder_userID_index"))
        #expect(indexNames.contains("IndexMacroOrder_status_index"))
        #expect(indexNames.contains("IndexMacroOrder_createdAt_index"))
        #expect(indexNames.contains("user_status_index"))

        // Verify compound index
        let userStatusIndex = orderIndexes.first { $0.name == "user_status_index" }
        #expect(userStatusIndex?.fields == ["userID", "status"])
    }

    // MARK: - Schema Integration Tests

    @Test("Schema can register types with indexes")
    func testSchemaRegistration() {
        let schema = Schema([
            IndexMacroUser.self,
            IndexMacroProduct.self,
            IndexMacroOrder.self
        ])

        // Verify entities are registered
        #expect(schema.entities.count == 3)

        // Verify indexes are accessible
        let userEntity = schema.entity(for: IndexMacroUser.self)!
        // User has 1 unique + 2 regular indexes
        #expect(userEntity.indices.count == 2)
        #expect(userEntity.uniquenessConstraints.count == 1)

        let productEntity = schema.entity(for: IndexMacroProduct.self)!
        // Product has 1 unique + 2 regular indexes
        #expect(productEntity.indices.count == 2)
        #expect(productEntity.uniquenessConstraints.count == 1)

        let orderEntity = schema.entity(for: IndexMacroOrder.self)!
        // Order has 4 regular indexes
        #expect(orderEntity.indices.count == 4)
        #expect(orderEntity.uniquenessConstraints.count == 0)
    }

    @Test("IndexDefinitions have correct metadata")
    func testIndexMetadata() {
        let indexDefs = IndexMacroUser.indexDefinitions

        // Test unique constraint
        let emailIndex = indexDefs.first { $0.name == "IndexMacroUser_email_unique" }!
        #expect(emailIndex.unique == true)

        // Test non-unique indexes
        let createdAtIndex = indexDefs.first { $0.name == "IndexMacroUser_createdAt_index" }!
        #expect(createdAtIndex.unique == false)

        // Test compound index
        let locationIndex = indexDefs.first { $0.name == "location_index" }!
        #expect(locationIndex.name == "location_index")
    }

    // MARK: - Edge Cases

    @Test("Model without indexes works correctly")
    func testModelWithoutIndexes() {
        // Should compile without indexDefinitions property
        #expect(IndexMacroSimpleModel.recordName == "IndexMacroSimpleModel")
        #expect(IndexMacroSimpleModel.primaryKeyFields == ["id"])
    }

    @Test("Model with only unique indexes")
    func testModelWithOnlyUniqueIndexes() {
        let indexes = IndexMacroUniqueModel.indexDefinitions
        #expect(indexes.count == 2)
        #expect(indexes.allSatisfy { $0.unique == true })
    }

    @Test("Model with only regular indexes")
    func testModelWithOnlyRegularIndexes() {
        let indexes = IndexMacroIndexedModel.indexDefinitions
        #expect(indexes.count == 3)
        #expect(indexes.allSatisfy { $0.unique == false })
    }
}
