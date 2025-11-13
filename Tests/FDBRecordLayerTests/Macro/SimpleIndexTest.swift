import Testing
import Foundation
@testable import FDBRecordLayer

/// Simple test to verify macro expansion
@Recordable
struct SimpleUser {
    #Index<SimpleUser>([\.email])
    #PrimaryKey<SimpleUser>([\.id])

    

    var id: Int64
    var email: String
}

/// Test variadic arguments
@Recordable
struct VariadicUser {
    #Index<VariadicUser>([\.email], [\.username])
    #PrimaryKey<VariadicUser>([\.id])

    

    var id: Int64
    var email: String
    var username: String
}

@Suite("Simple Index Test")
struct SimpleIndexTest {
    @Test("Check if indexDefinitions exist")
    func testIndexDefinitionsExist() {
        // Check if indexDefinitions property exists
        let indexes = SimpleUser.indexDefinitions
        print("Number of indexes: \(indexes.count)")
        #expect(indexes.count == 1)

        for (index, idx) in indexes.enumerated() {
            print("Index \(index): name=\(idx.name), fields=\(idx.fields), unique=\(idx.unique)")
        }
    }

    @Test("Check variadic arguments")
    func testVariadicArguments() {
        let indexes = VariadicUser.indexDefinitions
        print("Number of variadic indexes: \(indexes.count)")
        #expect(indexes.count == 2)

        // Should have email and username indexes
        let emailIndex = indexes.first(where: { $0.fields == ["email"] })
        let usernameIndex = indexes.first(where: { $0.fields == ["username"] })

        #expect(emailIndex != nil)
        #expect(usernameIndex != nil)
    }
}
