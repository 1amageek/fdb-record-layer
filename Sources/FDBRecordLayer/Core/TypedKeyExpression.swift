import Foundation

/// Protocol for type-safe key expressions
///
/// TypedKeyExpression works with a specific record type and uses FieldAccessor
/// for type-safe field extraction.
public protocol TypedKeyExpression<Record>: Sendable {
    associatedtype Record: Sendable

    /// Evaluate the expression on a record
    /// - Parameters:
    ///   - record: The record to evaluate
    ///   - accessor: The field accessor to use
    /// - Returns: An array of tuple elements representing the key
    func evaluate<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> [any TupleElement] where A.Record == Record

    /// Number of columns this expression produces
    var columnCount: Int { get }
}

// MARK: - Field Key Expression

/// Expression that extracts a single field from a record
public struct TypedFieldKeyExpression<Record: Sendable>: TypedKeyExpression {
    public let fieldName: String

    public init(fieldName: String) {
        self.fieldName = fieldName
    }

    public func evaluate<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> [any TupleElement] where A.Record == Record {
        guard let value = accessor.extractField(fieldName, from: record) else {
            // Return empty string for nil values
            return [""]
        }
        return [value]
    }

    public var columnCount: Int { 1 }
}

// MARK: - Concatenate Key Expression

/// Expression that combines multiple expressions into a single key
public struct TypedConcatenateKeyExpression<Record: Sendable>: TypedKeyExpression {
    public let children: [any TypedKeyExpression<Record>]

    public init(children: [any TypedKeyExpression<Record>]) {
        self.children = children
    }

    public func evaluate<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> [any TupleElement] where A.Record == Record {
        return children.flatMap { $0.evaluate(record: record, accessor: accessor) }
    }

    public var columnCount: Int {
        return children.reduce(0) { $0 + $1.columnCount }
    }
}

// MARK: - Literal Key Expression

/// Expression that always returns a literal value
public struct TypedLiteralKeyExpression<Record: Sendable, T: TupleElement>: TypedKeyExpression {
    public let value: T

    public init(value: T) {
        self.value = value
    }

    public func evaluate<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> [any TupleElement] where A.Record == Record {
        return [value]
    }

    public var columnCount: Int { 1 }
}

// MARK: - Empty Key Expression

/// Expression that returns an empty key
public struct TypedEmptyKeyExpression<Record: Sendable>: TypedKeyExpression {
    public init() {}

    public func evaluate<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> [any TupleElement] where A.Record == Record {
        return []
    }

    public var columnCount: Int { 0 }
}
