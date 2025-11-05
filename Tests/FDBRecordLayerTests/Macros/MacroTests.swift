import Testing
import Foundation
@testable import FDBRecordLayer

// MARK: - Test Types

/// Basic test user type
@Recordable
struct TestUser {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32
}

/// Test type with compound primary key
@Recordable
struct TestTenantUser {
    @PrimaryKey var tenantID: String
    @PrimaryKey var userID: Int64
    var name: String
}

/// Test type with transient field
@Recordable
struct TestUserWithTransient {
    @PrimaryKey var userID: Int64
    var name: String

    @Transient var isLoggedIn: Bool = false
}

/// Test product type
@Recordable
struct TestProduct {
    @PrimaryKey var productID: Int64
    var name: String
    var price: Int64
}

/// Test order type
@Recordable
struct TestOrder {
    @PrimaryKey var orderID: Int64
    var customerID: Int64
    var total: Int64
}

// MARK: - Test Suite

/// Test suite for macro-generated code
///
/// These tests verify that the @Recordable and related macros correctly generate
/// the necessary protocol conformances and methods.
@Suite("Macro Tests")
struct MacroTests {

    /// Test basic @Recordable macro with simple types
    @Test("Recordable macro generates basic conformance")
    func testRecordableBasic() throws {
        // Verify record type name
        #expect(TestUser.recordTypeName == "TestUser")

        // Verify primary key fields
        #expect(TestUser.primaryKeyFields == ["userID"])

        // Verify all fields
        #expect(TestUser.allFields == ["userID", "name", "email", "age"])

        // Verify field numbers
        #expect(TestUser.fieldNumber(for: "userID") == 1)
        #expect(TestUser.fieldNumber(for: "name") == 2)
        #expect(TestUser.fieldNumber(for: "email") == 3)
        #expect(TestUser.fieldNumber(for: "age") == 4)

        // Test serialization and deserialization
        let user = TestUser(userID: 123, name: "Alice", email: "alice@example.com", age: 30)
        let data = try user.toProtobuf()
        #expect(!data.isEmpty)

        let decoded = try TestUser.fromProtobuf(data)
        #expect(decoded.userID == 123)
        #expect(decoded.name == "Alice")
        #expect(decoded.email == "alice@example.com")
        #expect(decoded.age == 30)
    }

    /// Test @Recordable with compound primary key
    @Test("Recordable macro with compound primary key")
    func testCompoundPrimaryKey() throws {
        // Verify primary key fields
        #expect(TestTenantUser.primaryKeyFields == ["tenantID", "userID"])

        // Test primary key extraction
        let user = TestTenantUser(tenantID: "tenant1", userID: 123, name: "Bob")
        let primaryKey = user.extractPrimaryKey()
        #expect(primaryKey.count == 2)
    }

    /// Test @Transient macro
    @Test("Transient fields are excluded")
    func testTransientFields() throws {
        // Verify transient field is not in allFields
        #expect(!TestUserWithTransient.allFields.contains("isLoggedIn"))
        #expect(TestUserWithTransient.allFields == ["userID", "name"])
    }

    /// Test field extraction
    @Test("Field extraction works correctly")
    func testFieldExtraction() {
        let product = TestProduct(productID: 456, name: "Widget", price: 1999)

        let nameField = product.extractField("name")
        #expect(nameField.count == 1)

        let priceField = product.extractField("price")
        #expect(priceField.count == 1)

        let unknownField = product.extractField("unknown")
        #expect(unknownField.isEmpty)
    }

    /// Test KeyPath-based field name resolution
    @Test("KeyPath field name resolution")
    func testKeyPathFieldNames() {
        #expect(TestOrder.fieldName(for: \TestOrder.orderID) == "orderID")
        #expect(TestOrder.fieldName(for: \TestOrder.customerID) == "customerID")
        #expect(TestOrder.fieldName(for: \TestOrder.total) == "total")
    }
}
