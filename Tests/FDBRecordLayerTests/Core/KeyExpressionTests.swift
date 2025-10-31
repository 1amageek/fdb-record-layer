import XCTest
@testable import FDBRecordLayer

final class KeyExpressionTests: XCTestCase {
    func testFieldKeyExpression() {
        let expression = FieldKeyExpression(fieldName: "name")
        let record: [String: Any] = ["name": "Alice", "age": 30]

        let result = expression.evaluate(record: record)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0] as? String, "Alice")
        XCTAssertEqual(expression.columnCount, 1)
    }

    func testFieldKeyExpressionMissingField() {
        let expression = FieldKeyExpression(fieldName: "email")
        let record: [String: Any] = ["name": "Alice"]

        let result = expression.evaluate(record: record)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0] as? String, "")
    }

    func testConcatenateKeyExpression() {
        let expr1 = FieldKeyExpression(fieldName: "firstName")
        let expr2 = FieldKeyExpression(fieldName: "lastName")
        let concat = ConcatenateKeyExpression(children: [expr1, expr2])

        let record: [String: Any] = ["firstName": "Alice", "lastName": "Smith"]

        let result = concat.evaluate(record: record)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0] as? String, "Alice")
        XCTAssertEqual(result[1] as? String, "Smith")
        XCTAssertEqual(concat.columnCount, 2)
    }

    func testLiteralKeyExpression() {
        let expression = LiteralKeyExpression(value: "constant")
        let record: [String: Any] = [:]

        let result = expression.evaluate(record: record)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0] as? String, "constant")
    }

    func testEmptyKeyExpression() {
        let expression = EmptyKeyExpression()
        let record: [String: Any] = ["name": "Alice"]

        let result = expression.evaluate(record: record)

        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(expression.columnCount, 0)
    }

    func testNestExpression() {
        let childExpr = FieldKeyExpression(fieldName: "street")
        let nestExpr = NestExpression(parentField: "address", child: childExpr)

        let record: [String: Any] = [
            "name": "Alice",
            "address": ["street": "Main St", "city": "NYC"]
        ]

        let result = nestExpr.evaluate(record: record)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0] as? String, "Main St")
    }

    func testNestExpressionMissingParent() {
        let childExpr = FieldKeyExpression(fieldName: "street")
        let nestExpr = NestExpression(parentField: "address", child: childExpr)

        let record: [String: Any] = ["name": "Alice"]

        let result = nestExpr.evaluate(record: record)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0] as? String, "")
    }
}
