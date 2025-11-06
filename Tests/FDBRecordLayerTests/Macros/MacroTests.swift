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

/// Test type with all primitive types
@Recordable
struct TestAllTypes {
    @PrimaryKey var id: Int64

    // Primitive types
    var int32Field: Int32
    var int64Field: Int64
    var uint32Field: UInt32
    var uint64Field: UInt64
    var boolField: Bool
    var stringField: String
    var dataField: Data
    var floatField: Float
    var doubleField: Double
}

/// Test type with optional fields
@Recordable
struct TestOptionalFields {
    @PrimaryKey var id: Int64

    // Optional primitives
    var optInt32: Int32?
    var optInt64: Int64?
    var optBool: Bool?
    var optString: String?
    var optFloat: Float?
    var optDouble: Double?
}

/// Test type with array fields
@Recordable
struct TestArrayFields {
    @PrimaryKey var id: Int64

    // Primitive arrays (packed repeated)
    var int32Array: [Int32]
    var int64Array: [Int64]
    var boolArray: [Bool]
    var floatArray: [Float]
    var doubleArray: [Double]

    // Length-delimited arrays (unpacked)
    var stringArray: [String]
    var dataArray: [Data]
}

/// Nested custom type
@Recordable
struct TestAddress {
    @PrimaryKey var id: Int64
    var street: String
    var city: String
}

/// Test type with nested custom type
@Recordable
struct TestUserWithAddress {
    @PrimaryKey var userID: Int64
    var name: String
    var address: TestAddress
}

/// Test type with optional array fields
@Recordable
struct TestOptionalArrayFields {
    @PrimaryKey var id: Int64

    // Optional primitive arrays
    var optInt32Array: [Int32]?
    var optInt64Array: [Int64]?
    var optBoolArray: [Bool]?
    var optStringArray: [String]?
    var optFloatArray: [Float]?
    var optDoubleArray: [Double]?
}

/// Test type with static subspace
@Recordable
struct TestGlobalConfig {
    #Subspace<TestGlobalConfig>("global/config")

    @PrimaryKey var key: String
    var value: String
}

/// Test type with single dynamic component
@Recordable
struct TestTenantConfig {
    #Subspace<TestTenantConfig>("tenants/{tenantID}/config")

    @PrimaryKey var key: String
    var tenantID: String
    var value: String
}

/// Test type with multiple dynamic components
@Recordable
struct TestMultiTenantUser {
    #Subspace<TestMultiTenantUser>("accounts/{accountID}/users")

    @PrimaryKey var userID: Int64
    var accountID: String
    var email: String
}

/// Test type with nested dynamic path
@Recordable
struct TestComment {
    #Subspace<TestComment>("accounts/{accountID}/posts/{postID}/comments")

    @PrimaryKey var commentID: Int64
    var accountID: String
    var postID: Int64
    var text: String
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

    // MARK: - Protobuf Serialization Tests

    /// Test serialization of all primitive types
    @Test("All primitive types round-trip")
    func testAllPrimitiveTypes() throws {
        let original = TestAllTypes(
            id: 1,
            int32Field: -42,
            int64Field: -9223372036854775807,
            uint32Field: 4294967295,
            uint64Field: 18446744073709551615,
            boolField: true,
            stringField: "Hello, Protobuf!",
            dataField: Data([0x01, 0x02, 0x03, 0x04]),
            floatField: 3.14,
            doubleField: 2.718281828
        )

        // Serialize
        let data = try original.toProtobuf()
        #expect(!data.isEmpty)

        // Deserialize
        let decoded = try TestAllTypes.fromProtobuf(data)

        // Verify all fields
        #expect(decoded.id == original.id)
        #expect(decoded.int32Field == original.int32Field)
        #expect(decoded.int64Field == original.int64Field)
        #expect(decoded.uint32Field == original.uint32Field)
        #expect(decoded.uint64Field == original.uint64Field)
        #expect(decoded.boolField == original.boolField)
        #expect(decoded.stringField == original.stringField)
        #expect(decoded.dataField == original.dataField)
        #expect(decoded.floatField == original.floatField)
        #expect(decoded.doubleField == original.doubleField)
    }

    /// Test serialization of optional fields with values
    @Test("Optional fields with values round-trip")
    func testOptionalFieldsWithValues() throws {
        let original = TestOptionalFields(
            id: 1,
            optInt32: 42,
            optInt64: 123456789,
            optBool: true,
            optString: "Optional String",
            optFloat: 1.23,
            optDouble: 4.56
        )

        let data = try original.toProtobuf()
        let decoded = try TestOptionalFields.fromProtobuf(data)

        #expect(decoded.id == original.id)
        #expect(decoded.optInt32 == 42)
        #expect(decoded.optInt64 == 123456789)
        #expect(decoded.optBool == true)
        #expect(decoded.optString == "Optional String")
        #expect(decoded.optFloat == 1.23)
        #expect(decoded.optDouble == 4.56)
    }

    /// Test serialization of optional fields with nil values
    @Test("Optional fields with nil values round-trip")
    func testOptionalFieldsWithNil() throws {
        let original = TestOptionalFields(
            id: 2,
            optInt32: nil,
            optInt64: nil,
            optBool: nil,
            optString: nil,
            optFloat: nil,
            optDouble: nil
        )

        let data = try original.toProtobuf()
        let decoded = try TestOptionalFields.fromProtobuf(data)

        #expect(decoded.id == original.id)
        #expect(decoded.optInt32 == nil)
        #expect(decoded.optInt64 == nil)
        #expect(decoded.optBool == nil)
        #expect(decoded.optString == nil)
        #expect(decoded.optFloat == nil)
        #expect(decoded.optDouble == nil)
    }

    /// Test serialization of array fields (packed repeated)
    @Test("Array fields (packed repeated) round-trip")
    func testArrayFields() throws {
        let original = TestArrayFields(
            id: 1,
            int32Array: [1, -2, 3, -4, 5],
            int64Array: [100, 200, 300],
            boolArray: [true, false, true, false],
            floatArray: [1.1, 2.2, 3.3],
            doubleArray: [10.01, 20.02, 30.03],
            stringArray: ["alpha", "beta", "gamma"],
            dataArray: [Data([0x01]), Data([0x02, 0x03]), Data([0x04, 0x05, 0x06])]
        )

        let data = try original.toProtobuf()
        let decoded = try TestArrayFields.fromProtobuf(data)

        #expect(decoded.id == original.id)
        #expect(decoded.int32Array == original.int32Array)
        #expect(decoded.int64Array == original.int64Array)
        #expect(decoded.boolArray == original.boolArray)
        #expect(decoded.floatArray == original.floatArray)
        #expect(decoded.doubleArray == original.doubleArray)
        #expect(decoded.stringArray == original.stringArray)
        #expect(decoded.dataArray == original.dataArray)
    }

    /// Test serialization with empty arrays
    @Test("Empty arrays round-trip")
    func testEmptyArrays() throws {
        let original = TestArrayFields(
            id: 2,
            int32Array: [],
            int64Array: [],
            boolArray: [],
            floatArray: [],
            doubleArray: [],
            stringArray: [],
            dataArray: []
        )

        let data = try original.toProtobuf()
        let decoded = try TestArrayFields.fromProtobuf(data)

        #expect(decoded.id == original.id)
        #expect(decoded.int32Array.isEmpty)
        #expect(decoded.int64Array.isEmpty)
        #expect(decoded.boolArray.isEmpty)
        #expect(decoded.floatArray.isEmpty)
        #expect(decoded.doubleArray.isEmpty)
        #expect(decoded.stringArray.isEmpty)
        #expect(decoded.dataArray.isEmpty)
    }

    /// Test serialization with nested custom types
    @Test("Nested custom types round-trip")
    func testNestedCustomTypes() throws {
        let address = TestAddress(
            id: 1,
            street: "123 Main St",
            city: "San Francisco"
        )

        let original = TestUserWithAddress(
            userID: 100,
            name: "John Doe",
            address: address
        )

        let data = try original.toProtobuf()
        let decoded = try TestUserWithAddress.fromProtobuf(data)

        #expect(decoded.userID == original.userID)
        #expect(decoded.name == original.name)
        #expect(decoded.address.id == address.id)
        #expect(decoded.address.street == address.street)
        #expect(decoded.address.city == address.city)
    }

    /// Test wire type correctness for different types
    @Test("Wire types are correct")
    func testWireTypes() throws {
        // This test verifies that different types use the correct wire types
        // by checking the encoded bytes

        // Int32 should use wire type 0 (varint)
        let user = TestUser(userID: 1, name: "Test", email: "test@test.com", age: 25)
        let data = try user.toProtobuf()

        // Field 4 (age: Int32) should have tag = (4 << 3) | 0 = 32
        #expect(data.contains(32)) // Tag for field 4 with wire type 0

        // String should use wire type 2 (length-delimited)
        // Field 2 (name: String) should have tag = (2 << 3) | 2 = 18
        #expect(data.contains(18)) // Tag for field 2 with wire type 2
    }

    /// Test edge cases
    @Test("Edge cases - zero values")
    func testZeroValues() throws {
        let original = TestAllTypes(
            id: 0, // Zero primary key
            int32Field: 0,
            int64Field: 0,
            uint32Field: 0,
            uint64Field: 0,
            boolField: false,
            stringField: "",
            dataField: Data(),
            floatField: 0.0,
            doubleField: 0.0
        )

        let data = try original.toProtobuf()
        let decoded = try TestAllTypes.fromProtobuf(data)

        #expect(decoded.id == 0)
        #expect(decoded.int32Field == 0)
        #expect(decoded.boolField == false)
        #expect(decoded.stringField == "")
        #expect(decoded.dataField.isEmpty)
    }

    /// Test optional array fields with values
    @Test("Optional array fields with values round-trip")
    func testOptionalArrayFieldsWithValues() throws {
        let original = TestOptionalArrayFields(
            id: 1,
            optInt32Array: [1, -2, 3, -4, 5],
            optInt64Array: [100, 200, 300],
            optBoolArray: [true, false, true],
            optStringArray: ["alpha", "beta", "gamma"],
            optFloatArray: [1.1, 2.2, 3.3],
            optDoubleArray: [10.01, 20.02, 30.03]
        )

        let data = try original.toProtobuf()
        let decoded = try TestOptionalArrayFields.fromProtobuf(data)

        #expect(decoded.id == original.id)
        #expect(decoded.optInt32Array == original.optInt32Array)
        #expect(decoded.optInt64Array == original.optInt64Array)
        #expect(decoded.optBoolArray == original.optBoolArray)
        #expect(decoded.optStringArray == original.optStringArray)
        #expect(decoded.optFloatArray == original.optFloatArray)
        #expect(decoded.optDoubleArray == original.optDoubleArray)
    }

    /// Test optional array fields with nil values
    @Test("Optional array fields with nil values round-trip")
    func testOptionalArrayFieldsWithNil() throws {
        let original = TestOptionalArrayFields(
            id: 2,
            optInt32Array: nil,
            optInt64Array: nil,
            optBoolArray: nil,
            optStringArray: nil,
            optFloatArray: nil,
            optDoubleArray: nil
        )

        let data = try original.toProtobuf()
        let decoded = try TestOptionalArrayFields.fromProtobuf(data)

        #expect(decoded.id == original.id)
        #expect(decoded.optInt32Array == nil)
        #expect(decoded.optInt64Array == nil)
        #expect(decoded.optBoolArray == nil)
        #expect(decoded.optStringArray == nil)
        #expect(decoded.optFloatArray == nil)
        #expect(decoded.optDoubleArray == nil)
    }

    /// Test optional array fields with empty arrays
    @Test("Optional array fields with empty arrays")
    func testOptionalArrayFieldsWithEmpty() throws {
        let original = TestOptionalArrayFields(
            id: 3,
            optInt32Array: [],
            optInt64Array: [],
            optBoolArray: [],
            optStringArray: [],
            optFloatArray: [],
            optDoubleArray: []
        )

        let data = try original.toProtobuf()
        let decoded = try TestOptionalArrayFields.fromProtobuf(data)

        #expect(decoded.id == original.id)
        // Empty arrays should remain nil after round-trip (Protobuf doesn't encode empty arrays)
        #expect(decoded.optInt32Array == nil)
        #expect(decoded.optInt64Array == nil)
        #expect(decoded.optBoolArray == nil)
        #expect(decoded.optStringArray == nil)
        #expect(decoded.optFloatArray == nil)
        #expect(decoded.optDoubleArray == nil)
    }

    // MARK: - Subspace Macro Tests

    /// Test static subspace generation
    @Test("#Subspace static path")
    func testStaticSubspace() {
        // Verify that TestGlobalConfig has a store(in:) method
        // Note: This is a compile-time test - if it compiles, the macro worked

        // The macro should generate (inside the struct):
        // static func store(in container: RecordContainer) -> RecordStore<TestGlobalConfig>

        // We can't actually test the runtime behavior without a RecordContainer,
        // but we can verify the method signature exists by checking it compiles
        let _: (RecordContainer) -> RecordStore<TestGlobalConfig> = TestGlobalConfig.store(in:)
    }

    /// Test single dynamic component
    @Test("#Subspace single dynamic component")
    func testSingleDynamicSubspace() {
        // Verify that TestTenantConfig has a store(in:tenantID:) method

        // The macro should generate (inside the struct):
        // static func store(
        //     in container: RecordContainer,
        //     tenantID: String
        // ) -> RecordStore<TestTenantConfig>

        let _: (RecordContainer, String) -> RecordStore<TestTenantConfig> = TestTenantConfig.store(in:tenantID:)
    }

    /// Test multiple dynamic components
    @Test("#Subspace multiple dynamic components")
    func testMultipleDynamicSubspace() {
        // Verify that TestMultiTenantUser has a store(in:accountID:) method

        // The macro should generate (inside the struct):
        // static func store(
        //     in container: RecordContainer,
        //     accountID: String
        // ) -> RecordStore<TestMultiTenantUser>

        let _: (RecordContainer, String) -> RecordStore<TestMultiTenantUser> = TestMultiTenantUser.store(in:accountID:)
    }

    /// Test nested dynamic path
    @Test("#Subspace nested dynamic path")
    func testNestedDynamicSubspace() {
        // Verify that TestComment has a store(in:accountID:postID:) method

        // The macro should generate (inside the struct):
        // static func store(
        //     in container: RecordContainer,
        //     accountID: String,
        //     postID: Int64
        // ) -> RecordStore<TestComment>

        let _: (RecordContainer, String, Int64) -> RecordStore<TestComment> = TestComment.store(in:accountID:postID:)
    }
}
