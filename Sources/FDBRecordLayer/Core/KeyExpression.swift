import Foundation

/// Protocol for expressions that extract key values from records
///
/// KeyExpressions are used to define primary keys and index keys.
/// They use the Visitor pattern to extract values from records through RecordAccess.
public protocol KeyExpression: Sendable {
    /// Number of columns this expression produces
    var columnCount: Int { get }
}

// MARK: - Field Key Expression

/// Expression that extracts a single field from a record
public struct FieldKeyExpression: KeyExpression {
    public let fieldName: String

    public init(fieldName: String) {
        self.fieldName = fieldName
    }

    public var columnCount: Int { 1 }
}

// MARK: - Concatenate Key Expression

/// Expression that combines multiple expressions into a single key
public struct ConcatenateKeyExpression: KeyExpression {
    public let children: [KeyExpression]

    public init(children: [KeyExpression]) {
        self.children = children
    }

    public var columnCount: Int {
        return children.reduce(0) { $0 + $1.columnCount }
    }
}

// MARK: - Literal Key Expression

/// Expression that always returns a literal value
public struct LiteralKeyExpression<T: TupleElement>: KeyExpression {
    public let value: T

    public init(value: T) {
        self.value = value
    }

    public var columnCount: Int { 1 }
}

// MARK: - Empty Key Expression

/// Expression that returns an empty key
public struct EmptyKeyExpression: KeyExpression {
    public init() {}

    public var columnCount: Int { 0 }
}

// MARK: - Nest Expression

/// Expression that evaluates a child expression on a nested field
public struct NestExpression: KeyExpression {
    public let parentField: String
    public let child: KeyExpression

    public init(parentField: String, child: KeyExpression) {
        self.parentField = parentField
        self.child = child
    }

    public var columnCount: Int {
        return child.columnCount
    }
}
