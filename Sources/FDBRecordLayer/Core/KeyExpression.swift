import Foundation

/// Protocol for expressions that extract key values from records
///
/// KeyExpressions are used to define primary keys and index keys.
/// They evaluate a record (in a generic way) and return tuple elements.
public protocol KeyExpression: Sendable {
    /// Evaluate the expression on a record
    /// - Parameter record: The record to evaluate (as a dictionary for simplicity)
    /// - Returns: An array of tuple elements representing the key
    func evaluate(record: [String: Any]) -> [any TupleElement]

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

    public func evaluate(record: [String: Any]) -> [any TupleElement] {
        guard let value = record[fieldName] else {
            return [""]
        }

        // Convert value to TupleElement
        if let element = value as? any TupleElement {
            return [element]
        }

        // Try common conversions
        if let str = value as? String {
            return [str]
        } else if let int = value as? Int {
            return [Int64(int)]
        } else if let int64 = value as? Int64 {
            return [int64]
        } else if let bool = value as? Bool {
            return [bool]
        }

        // Fallback to nil for unsupported types
        return [""]
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

    public func evaluate(record: [String: Any]) -> [any TupleElement] {
        return children.flatMap { $0.evaluate(record: record) }
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

    public func evaluate(record: [String: Any]) -> [any TupleElement] {
        return [value]
    }

    public var columnCount: Int { 1 }
}

// MARK: - Empty Key Expression

/// Expression that returns an empty key
public struct EmptyKeyExpression: KeyExpression {
    public init() {}

    public func evaluate(record: [String: Any]) -> [any TupleElement] {
        return []
    }

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

    public func evaluate(record: [String: Any]) -> [any TupleElement] {
        guard let nestedRecord = record[parentField] as? [String: Any] else {
            // If parent field doesn't exist or isn't a nested record,
            // return nil for each column
            return Array(repeating: "", count: child.columnCount)
        }

        return child.evaluate(record: nestedRecord)
    }

    public var columnCount: Int {
        return child.columnCount
    }
}
