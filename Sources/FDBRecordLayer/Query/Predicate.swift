import Foundation

/// Query predicate for operator overloading
///
/// Predicate wraps TypedQueryComponent to enable operator overloading syntax:
///
/// ```swift
/// let users = try await store.query()
///     .where(\.email == "alice@example.com")
///     .where(\.age > 18 && \.city == "Tokyo")
///     .execute()
/// ```
public struct Predicate<Record: Recordable>: Sendable {
    internal let component: any TypedQueryComponent<Record>

    internal init(_ component: any TypedQueryComponent<Record>) {
        self.component = component
    }
}

// MARK: - Logical Operators

extension Predicate {
    /// Logical AND operator
    public static func && (lhs: Self, rhs: Self) -> Self {
        Predicate(TypedAndQueryComponent<Record>(children: [lhs.component, rhs.component]))
    }

    /// Logical OR operator
    public static func || (lhs: Self, rhs: Self) -> Self {
        Predicate(TypedOrQueryComponent<Record>(children: [lhs.component, rhs.component]))
    }

    /// Logical NOT operator
    public static prefix func ! (predicate: Self) -> Self {
        Predicate(TypedNotQueryComponent<Record>(child: predicate.component))
    }
}

// MARK: - KeyPath Operator Overloading
//
// Swift does not allow KeyPath to conform to Sendable, so we define
// global operators directly on KeyPath types.

// MARK: - Comparison Operators (Equatable)

/// Equality operator for KeyPath
public func == <Root: Recordable, Value: TupleElement & Equatable>(
    lhs: KeyPath<Root, Value>,
    rhs: Value
) -> Predicate<Root> {
    let fieldName = Root.fieldName(for: lhs)
    let component = TypedFieldQueryComponent<Root>(
        fieldName: fieldName,
        comparison: .equals,
        value: rhs
    )
    return Predicate(component)
}

/// Inequality operator for KeyPath
public func != <Root: Recordable, Value: TupleElement & Equatable>(
    lhs: KeyPath<Root, Value>,
    rhs: Value
) -> Predicate<Root> {
    let fieldName = Root.fieldName(for: lhs)
    let component = TypedFieldQueryComponent<Root>(
        fieldName: fieldName,
        comparison: .notEquals,
        value: rhs
    )
    return Predicate(component)
}

// MARK: - Comparison Operators (Comparable)

/// Less than operator for KeyPath
public func < <Root: Recordable, Value: TupleElement & Comparable>(
    lhs: KeyPath<Root, Value>,
    rhs: Value
) -> Predicate<Root> {
    let fieldName = Root.fieldName(for: lhs)
    let component = TypedFieldQueryComponent<Root>(
        fieldName: fieldName,
        comparison: .lessThan,
        value: rhs
    )
    return Predicate(component)
}

/// Less than or equal operator for KeyPath
public func <= <Root: Recordable, Value: TupleElement & Comparable>(
    lhs: KeyPath<Root, Value>,
    rhs: Value
) -> Predicate<Root> {
    let fieldName = Root.fieldName(for: lhs)
    let component = TypedFieldQueryComponent<Root>(
        fieldName: fieldName,
        comparison: .lessThanOrEquals,
        value: rhs
    )
    return Predicate(component)
}

/// Greater than operator for KeyPath
public func > <Root: Recordable, Value: TupleElement & Comparable>(
    lhs: KeyPath<Root, Value>,
    rhs: Value
) -> Predicate<Root> {
    let fieldName = Root.fieldName(for: lhs)
    let component = TypedFieldQueryComponent<Root>(
        fieldName: fieldName,
        comparison: .greaterThan,
        value: rhs
    )
    return Predicate(component)
}

/// Greater than or equal operator for KeyPath
public func >= <Root: Recordable, Value: TupleElement & Comparable>(
    lhs: KeyPath<Root, Value>,
    rhs: Value
) -> Predicate<Root> {
    let fieldName = Root.fieldName(for: lhs)
    let component = TypedFieldQueryComponent<Root>(
        fieldName: fieldName,
        comparison: .greaterThanOrEquals,
        value: rhs
    )
    return Predicate(component)
}

// MARK: - String-specific Operators

extension KeyPath where Root: Recordable, Value == String {
    /// Check if string starts with prefix
    public func hasPrefix(_ prefix: String) -> Predicate<Root> {
        let fieldName = Root.fieldName(for: self)
        let component = TypedFieldQueryComponent<Root>(
            fieldName: fieldName,
            comparison: .startsWith,
            value: prefix
        )
        return Predicate(component)
    }

    /// Check if string contains substring
    public func contains(_ substring: String) -> Predicate<Root> {
        let fieldName = Root.fieldName(for: self)
        let component = TypedFieldQueryComponent<Root>(
            fieldName: fieldName,
            comparison: .contains,
            value: substring
        )
        return Predicate(component)
    }
}
