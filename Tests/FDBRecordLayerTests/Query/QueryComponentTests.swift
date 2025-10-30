import XCTest
@testable import FDBRecordLayer

final class QueryComponentTests: XCTestCase {
    func testFieldQueryComponentEquals() {
        let component = FieldQueryComponent(
            fieldName: "name",
            comparison: .equals,
            value: "Alice"
        )

        let match: [String: Any] = ["name": "Alice", "age": 30]
        let noMatch: [String: Any] = ["name": "Bob", "age": 25]

        XCTAssertTrue(component.matches(record: match))
        XCTAssertFalse(component.matches(record: noMatch))
    }

    func testFieldQueryComponentLessThan() {
        let component = FieldQueryComponent(
            fieldName: "age",
            comparison: .lessThan,
            value: Int64(30)
        )

        let match: [String: Any] = ["name": "Alice", "age": Int64(25)]
        let noMatch: [String: Any] = ["name": "Bob", "age": Int64(35)]

        XCTAssertTrue(component.matches(record: match))
        XCTAssertFalse(component.matches(record: noMatch))
    }

    func testFieldQueryComponentStartsWith() {
        let component = FieldQueryComponent(
            fieldName: "email",
            comparison: .startsWith,
            value: "alice"
        )

        let match: [String: Any] = ["email": "alice@example.com"]
        let noMatch: [String: Any] = ["email": "bob@example.com"]

        XCTAssertTrue(component.matches(record: match))
        XCTAssertFalse(component.matches(record: noMatch))
    }

    func testAndQueryComponent() {
        let comp1 = FieldQueryComponent(fieldName: "age", comparison: .greaterThan, value: Int64(18))
        let comp2 = FieldQueryComponent(fieldName: "age", comparison: .lessThan, value: Int64(65))
        let andComp = AndQueryComponent(children: [comp1, comp2])

        let match: [String: Any] = ["age": Int64(30)]
        let noMatch1: [String: Any] = ["age": Int64(10)]
        let noMatch2: [String: Any] = ["age": Int64(70)]

        XCTAssertTrue(andComp.matches(record: match))
        XCTAssertFalse(andComp.matches(record: noMatch1))
        XCTAssertFalse(andComp.matches(record: noMatch2))
    }

    func testOrQueryComponent() {
        let comp1 = FieldQueryComponent(fieldName: "city", comparison: .equals, value: "NYC")
        let comp2 = FieldQueryComponent(fieldName: "city", comparison: .equals, value: "SF")
        let orComp = OrQueryComponent(children: [comp1, comp2])

        let match1: [String: Any] = ["city": "NYC"]
        let match2: [String: Any] = ["city": "SF"]
        let noMatch: [String: Any] = ["city": "LA"]

        XCTAssertTrue(orComp.matches(record: match1))
        XCTAssertTrue(orComp.matches(record: match2))
        XCTAssertFalse(orComp.matches(record: noMatch))
    }

    func testNotQueryComponent() {
        let inner = FieldQueryComponent(fieldName: "active", comparison: .equals, value: true)
        let notComp = NotQueryComponent(child: inner)

        let match: [String: Any] = ["active": false]
        let noMatch: [String: Any] = ["active": true]

        XCTAssertTrue(notComp.matches(record: match))
        XCTAssertFalse(notComp.matches(record: noMatch))
    }
}
