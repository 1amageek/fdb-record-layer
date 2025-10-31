import Testing
@testable import FDBRecordLayer

@Suite("QueryComponent Tests")
struct QueryComponentTests {
    @Test("Field query component with equals comparison matches correctly")
    func fieldQueryComponentEquals() {
        let component = FieldQueryComponent(
            fieldName: "name",
            comparison: .equals,
            value: "Alice"
        )

        let match: [String: Any] = ["name": "Alice", "age": 30]
        let noMatch: [String: Any] = ["name": "Bob", "age": 25]

        #expect(component.matches(record: match))
        #expect(!component.matches(record: noMatch))
    }

    @Test("Field query component with lessThan comparison matches correctly")
    func fieldQueryComponentLessThan() {
        let component = FieldQueryComponent(
            fieldName: "age",
            comparison: .lessThan,
            value: Int64(30)
        )

        let match: [String: Any] = ["name": "Alice", "age": Int64(25)]
        let noMatch: [String: Any] = ["name": "Bob", "age": Int64(35)]

        #expect(component.matches(record: match))
        #expect(!component.matches(record: noMatch))
    }

    @Test("Field query component with startsWith comparison matches correctly")
    func fieldQueryComponentStartsWith() {
        let component = FieldQueryComponent(
            fieldName: "email",
            comparison: .startsWith,
            value: "alice"
        )

        let match: [String: Any] = ["email": "alice@example.com"]
        let noMatch: [String: Any] = ["email": "bob@example.com"]

        #expect(component.matches(record: match))
        #expect(!component.matches(record: noMatch))
    }

    @Test("AND query component matches only when all children match")
    func andQueryComponent() {
        let comp1 = FieldQueryComponent(fieldName: "age", comparison: .greaterThan, value: Int64(18))
        let comp2 = FieldQueryComponent(fieldName: "age", comparison: .lessThan, value: Int64(65))
        let andComp = AndQueryComponent(children: [comp1, comp2])

        let match: [String: Any] = ["age": Int64(30)]
        let noMatch1: [String: Any] = ["age": Int64(10)]
        let noMatch2: [String: Any] = ["age": Int64(70)]

        #expect(andComp.matches(record: match))
        #expect(!andComp.matches(record: noMatch1))
        #expect(!andComp.matches(record: noMatch2))
    }

    @Test("OR query component matches when any child matches")
    func orQueryComponent() {
        let comp1 = FieldQueryComponent(fieldName: "city", comparison: .equals, value: "NYC")
        let comp2 = FieldQueryComponent(fieldName: "city", comparison: .equals, value: "SF")
        let orComp = OrQueryComponent(children: [comp1, comp2])

        let match1: [String: Any] = ["city": "NYC"]
        let match2: [String: Any] = ["city": "SF"]
        let noMatch: [String: Any] = ["city": "LA"]

        #expect(orComp.matches(record: match1))
        #expect(orComp.matches(record: match2))
        #expect(!orComp.matches(record: noMatch))
    }

    @Test("NOT query component negates child result")
    func notQueryComponent() {
        let inner = FieldQueryComponent(fieldName: "active", comparison: .equals, value: true)
        let notComp = NotQueryComponent(child: inner)

        let match: [String: Any] = ["active": false]
        let noMatch: [String: Any] = ["active": true]

        #expect(notComp.matches(record: match))
        #expect(!notComp.matches(record: noMatch))
    }
}
