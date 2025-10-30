import Foundation

/// Protocol for type-safe query filter components
///
/// TypedQueryComponent works with a specific record type for type safety.
public protocol TypedQueryComponent<Record>: Sendable {
    associatedtype Record: Sendable

    /// Check if a record matches this component
    /// - Parameters:
    ///   - record: The record to test
    ///   - accessor: The field accessor
    /// - Returns: true if the record matches
    func matches<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> Bool where A.Record == Record
}

// MARK: - Field Query Component

/// Field comparison component
public struct TypedFieldQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let fieldName: String
    public let comparison: Comparison
    public let value: any TupleElement

    public enum Comparison: Sendable {
        case equals
        case notEquals
        case lessThan
        case lessThanOrEquals
        case greaterThan
        case greaterThanOrEquals
        case startsWith
        case contains
    }

    public init(
        fieldName: String,
        comparison: Comparison,
        value: any TupleElement
    ) {
        self.fieldName = fieldName
        self.comparison = comparison
        self.value = value
    }

    public func matches<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> Bool where A.Record == Record {
        guard let fieldValue = accessor.extractField(fieldName, from: record) else {
            return false
        }

        switch comparison {
        case .equals:
            return areEqual(fieldValue, value)
        case .notEquals:
            return !areEqual(fieldValue, value)
        case .lessThan:
            return compareLessThan(fieldValue, value)
        case .lessThanOrEquals:
            return compareLessThan(fieldValue, value) || areEqual(fieldValue, value)
        case .greaterThan:
            return !compareLessThan(fieldValue, value) && !areEqual(fieldValue, value)
        case .greaterThanOrEquals:
            return !compareLessThan(fieldValue, value)
        case .startsWith:
            return checkStartsWith(fieldValue, value)
        case .contains:
            return checkContains(fieldValue, value)
        }
    }

    // MARK: - Private Helpers

    private func areEqual(_ lhs: any TupleElement, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr == rhsStr
        } else if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
            return lhsInt == rhsInt
        } else if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int64 {
            return Int64(lhsInt) == rhsInt
        } else if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
            return lhsBool == rhsBool
        } else if let lhsDouble = lhs as? Double, let rhsDouble = rhs as? Double {
            return lhsDouble == rhsDouble
        } else if let lhsFloat = lhs as? Float, let rhsFloat = rhs as? Float {
            return lhsFloat == rhsFloat
        }
        return false
    }

    private func compareLessThan(_ lhs: any TupleElement, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr < rhsStr
        } else if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
            return lhsInt < rhsInt
        } else if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int64 {
            return Int64(lhsInt) < rhsInt
        } else if let lhsDouble = lhs as? Double, let rhsDouble = rhs as? Double {
            return lhsDouble < rhsDouble
        } else if let lhsFloat = lhs as? Float, let rhsFloat = rhs as? Float {
            return lhsFloat < rhsFloat
        }
        return false
    }

    private func checkStartsWith(_ lhs: any TupleElement, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr.hasPrefix(rhsStr)
        }
        return false
    }

    private func checkContains(_ lhs: any TupleElement, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr.contains(rhsStr)
        }
        return false
    }
}

// MARK: - AND Component

/// AND component (all children must match)
public struct TypedAndQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let children: [any TypedQueryComponent<Record>]

    public init(children: [any TypedQueryComponent<Record>]) {
        self.children = children
    }

    public func matches<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> Bool where A.Record == Record {
        return children.allSatisfy { $0.matches(record: record, accessor: accessor) }
    }
}

// MARK: - OR Component

/// OR component (at least one child must match)
public struct TypedOrQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let children: [any TypedQueryComponent<Record>]

    public init(children: [any TypedQueryComponent<Record>]) {
        self.children = children
    }

    public func matches<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> Bool where A.Record == Record {
        return children.contains { $0.matches(record: record, accessor: accessor) }
    }
}

// MARK: - NOT Component

/// NOT component (inverts child)
public struct TypedNotQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let child: any TypedQueryComponent<Record>

    public init(child: any TypedQueryComponent<Record>) {
        self.child = child
    }

    public func matches<A: FieldAccessor>(
        record: Record,
        accessor: A
    ) -> Bool where A.Record == Record {
        return !child.matches(record: record, accessor: accessor)
    }
}

// MARK: - Convenience Builders

extension TypedFieldQueryComponent {
    /// Create an equals comparison
    public static func equals(_ fieldName: String, _ value: any TupleElement) -> TypedFieldQueryComponent<Record> {
        return TypedFieldQueryComponent(fieldName: fieldName, comparison: .equals, value: value)
    }

    /// Create a not equals comparison
    public static func notEquals(_ fieldName: String, _ value: any TupleElement) -> TypedFieldQueryComponent<Record> {
        return TypedFieldQueryComponent(fieldName: fieldName, comparison: .notEquals, value: value)
    }

    /// Create a less than comparison
    public static func lessThan(_ fieldName: String, _ value: any TupleElement) -> TypedFieldQueryComponent<Record> {
        return TypedFieldQueryComponent(fieldName: fieldName, comparison: .lessThan, value: value)
    }

    /// Create a greater than comparison
    public static func greaterThan(_ fieldName: String, _ value: any TupleElement) -> TypedFieldQueryComponent<Record> {
        return TypedFieldQueryComponent(fieldName: fieldName, comparison: .greaterThan, value: value)
    }
}
