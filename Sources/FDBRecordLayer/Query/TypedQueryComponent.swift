import Foundation

/// Protocol for type-safe query filter components
///
/// TypedQueryComponent works with a specific record type for type safety.
public protocol TypedQueryComponent<Record>: Sendable {
    associatedtype Record: Sendable

    /// Check if a record matches this component
    /// - Parameters:
    ///   - record: The record to test
    ///   - recordAccess: The record access for field extraction
    /// - Returns: true if the record matches
    /// - Throws: RecordLayerError if field extraction fails
    func matches(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> Bool
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

        /// Check if this comparison is an equality check
        public var isEquality: Bool {
            return self == .equals
        }
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

    public func matches(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> Bool {
        let fieldValues = try recordAccess.extractField(from: record, fieldName: fieldName)

        guard let fieldValue = fieldValues.first else {
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

    public func matches(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> Bool {
        return try children.allSatisfy { try $0.matches(record: record, recordAccess: recordAccess) }
    }
}

// MARK: - OR Component

/// OR component (at least one child must match)
public struct TypedOrQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let children: [any TypedQueryComponent<Record>]

    public init(children: [any TypedQueryComponent<Record>]) {
        self.children = children
    }

    public func matches(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> Bool {
        return try children.contains { try $0.matches(record: record, recordAccess: recordAccess) }
    }
}

// MARK: - NOT Component

/// NOT component (inverts child)
public struct TypedNotQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let child: any TypedQueryComponent<Record>

    public init(child: any TypedQueryComponent<Record>) {
        self.child = child
    }

    public func matches(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> Bool {
        return !(try child.matches(record: record, recordAccess: recordAccess))
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
