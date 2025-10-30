import Foundation

/// Protocol for query filter components
///
/// QueryComponents define predicates for filtering records.
public protocol QueryComponent: Sendable {
    /// Check if a record matches this component
    /// - Parameter record: The record to test
    /// - Returns: true if the record matches
    func matches(record: [String: Any]) -> Bool
}

// MARK: - Field Query Component

/// Field comparison component
public struct FieldQueryComponent: QueryComponent {
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

    public func matches(record: [String: Any]) -> Bool {
        guard let fieldValue = record[fieldName] else {
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

    private func areEqual(_ lhs: Any, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr == rhsStr
        } else if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
            return lhsInt == rhsInt
        } else if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int64 {
            return Int64(lhsInt) == rhsInt
        } else if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
            return lhsBool == rhsBool
        }
        return false
    }

    private func compareLessThan(_ lhs: Any, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr < rhsStr
        } else if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
            return lhsInt < rhsInt
        } else if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int64 {
            return Int64(lhsInt) < rhsInt
        }
        return false
    }

    private func checkStartsWith(_ lhs: Any, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr.hasPrefix(rhsStr)
        }
        return false
    }

    private func checkContains(_ lhs: Any, _ rhs: any TupleElement) -> Bool {
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr.contains(rhsStr)
        }
        return false
    }
}

// MARK: - AND Component

/// AND component (all children must match)
public struct AndQueryComponent: QueryComponent {
    public let children: [any QueryComponent]

    public init(children: [any QueryComponent]) {
        self.children = children
    }

    public func matches(record: [String: Any]) -> Bool {
        return children.allSatisfy { $0.matches(record: record) }
    }
}

// MARK: - OR Component

/// OR component (at least one child must match)
public struct OrQueryComponent: QueryComponent {
    public let children: [any QueryComponent]

    public init(children: [any QueryComponent]) {
        self.children = children
    }

    public func matches(record: [String: Any]) -> Bool {
        return children.contains { $0.matches(record: record) }
    }
}

// MARK: - NOT Component

/// NOT component (inverts child)
public struct NotQueryComponent: QueryComponent {
    public let child: any QueryComponent

    public init(child: any QueryComponent) {
        self.child = child
    }

    public func matches(record: [String: Any]) -> Bool {
        return !child.matches(record: record)
    }
}
