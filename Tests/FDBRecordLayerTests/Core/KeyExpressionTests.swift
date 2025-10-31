import Testing
@testable import FDBRecordLayer

@Suite("KeyExpression Tests")
struct KeyExpressionTests {
    @Test("FieldKeyExpression evaluates existing field")
    func fieldKeyExpression() {
        let expression = FieldKeyExpression(fieldName: "name")
        let record: [String: Any] = ["name": "Alice", "age": 30]

        let result = expression.evaluate(record: record)

        #expect(result.count == 1)
        #expect(result[0] as? String == "Alice")
        #expect(expression.columnCount == 1)
    }

    @Test("FieldKeyExpression returns empty string for missing field")
    func fieldKeyExpressionMissingField() {
        let expression = FieldKeyExpression(fieldName: "email")
        let record: [String: Any] = ["name": "Alice"]

        let result = expression.evaluate(record: record)

        #expect(result.count == 1)
        #expect(result[0] as? String == "")
    }

    @Test("ConcatenateKeyExpression combines multiple fields")
    func concatenateKeyExpression() {
        let expr1 = FieldKeyExpression(fieldName: "firstName")
        let expr2 = FieldKeyExpression(fieldName: "lastName")
        let concat = ConcatenateKeyExpression(children: [expr1, expr2])

        let record: [String: Any] = ["firstName": "Alice", "lastName": "Smith"]

        let result = concat.evaluate(record: record)

        #expect(result.count == 2)
        #expect(result[0] as? String == "Alice")
        #expect(result[1] as? String == "Smith")
        #expect(concat.columnCount == 2)
    }

    @Test("LiteralKeyExpression returns constant value")
    func literalKeyExpression() {
        let expression = LiteralKeyExpression(value: "constant")
        let record: [String: Any] = [:]

        let result = expression.evaluate(record: record)

        #expect(result.count == 1)
        #expect(result[0] as? String == "constant")
    }

    @Test("EmptyKeyExpression returns empty array")
    func emptyKeyExpression() {
        let expression = EmptyKeyExpression()
        let record: [String: Any] = ["name": "Alice"]

        let result = expression.evaluate(record: record)

        #expect(result.count == 0)
        #expect(expression.columnCount == 0)
    }

    @Test("NestExpression evaluates nested field")
    func nestExpression() {
        let childExpr = FieldKeyExpression(fieldName: "street")
        let nestExpr = NestExpression(parentField: "address", child: childExpr)

        let record: [String: Any] = [
            "name": "Alice",
            "address": ["street": "Main St", "city": "NYC"]
        ]

        let result = nestExpr.evaluate(record: record)

        #expect(result.count == 1)
        #expect(result[0] as? String == "Main St")
    }

    @Test("NestExpression returns empty string for missing parent field")
    func nestExpressionMissingParent() {
        let childExpr = FieldKeyExpression(fieldName: "street")
        let nestExpr = NestExpression(parentField: "address", child: childExpr)

        let record: [String: Any] = ["name": "Alice"]

        let result = nestExpr.evaluate(record: record)

        #expect(result.count == 1)
        #expect(result[0] as? String == "")
    }
}
