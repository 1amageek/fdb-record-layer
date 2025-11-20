import Testing
import FDBRecordCore
import FDBRecordLayer
import FoundationDB

@Suite("Directory Path Components Tests")
struct DirectoryPathComponentsTests {

    // Test model with #Directory macro
    @Recordable
    struct User {
        #Directory<User>("tenants", Field(\User.tenantID), "users", layer: .partition)
        #PrimaryKey<User>([\.userID])

        var tenantID: String
        var userID: Int64
        var name: String
    }

    // Test model without #Directory macro
    @Recordable
    struct Product {
        #PrimaryKey<Product>([\.productID])

        var productID: Int64
        var name: String
    }

    @Test("directoryPathComponents is generated correctly")
    func testDirectoryPathComponents() throws {
        // User should have directoryPathComponents
        let components = User.directoryPathComponents

        #expect(components.count == 3)

        // First element: Path("tenants")
        if let firstPath = components[0] as? Path {
            #expect(firstPath.value == "tenants")
        } else {
            Issue.record("First component should be Path")
        }

        // Second element: Field(\.tenantID)
        if let secondField = components[1] as? Field<User> {
            // Field contains a KeyPath, the cast itself verifies it exists
            _ = secondField.value  // Just acknowledge we have the value
        } else {
            Issue.record("Second component should be Field<User>")
        }

        // Third element: Path("users")
        if let thirdPath = components[2] as? Path {
            #expect(thirdPath.value == "users")
        } else {
            Issue.record("Third component should be Path")
        }
    }

    @Test("directoryLayerType is generated correctly")
    func testDirectoryLayerType() throws {
        // User should have .partition
        #expect(User.directoryLayerType == .partition)
    }

    @Test("Product without #Directory has default values")
    func testDefaultValues() throws {
        // Product should have empty directoryPathComponents
        #expect(Product.directoryPathComponents.isEmpty)

        // Product should have .recordStore (default)
        #expect(Product.directoryLayerType == .recordStore)
    }
}
