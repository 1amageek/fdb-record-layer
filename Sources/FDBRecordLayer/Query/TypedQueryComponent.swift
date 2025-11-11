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

        guard !fieldValues.isEmpty else {
            return false
        }

        // CRITICAL FIX: For multi-valued fields (arrays), check ALL values
        // Use ANY semantics: return true if ANY element matches
        // This ensures predicates like "tags CONTAINS 'swift'" work correctly
        // even when 'swift' is not at index 0
        for fieldValue in fieldValues {
            let matches: Bool
            switch comparison {
            case .equals:
                matches = TupleComparison.areEqual(fieldValue, value)
            case .notEquals:
                matches = !TupleComparison.areEqual(fieldValue, value)
            case .lessThan:
                matches = TupleComparison.isLessThan(fieldValue, value)
            case .lessThanOrEquals:
                matches = TupleComparison.isLessThan(fieldValue, value) || TupleComparison.areEqual(fieldValue, value)
            case .greaterThan:
                matches = !TupleComparison.isLessThan(fieldValue, value) && !TupleComparison.areEqual(fieldValue, value)
            case .greaterThanOrEquals:
                matches = !TupleComparison.isLessThan(fieldValue, value)
            case .startsWith:
                matches = TupleComparison.startsWith(fieldValue, value)
            case .contains:
                matches = TupleComparison.contains(fieldValue, value)
            }

            if matches {
                return true // ANY semantics: return true if any element matches
            }
        }

        return false // No element matched
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

// MARK: - IN Component

/// IN component (field value in set)
///
/// Represents: field IN (value1, value2, value3, ...)
///
/// **Usage**:
/// ```swift
/// // age IN (20, 25, 30, 35)
/// let filter = TypedInQueryComponent<User>(
///     fieldName: "age",
///     values: [Int64(20), Int64(25), Int64(30), Int64(35)]
/// )
///
/// // Or using the convenience method
/// let filter = TypedInQueryComponent<User>.in("age", [20, 25, 30, 35])
/// ```
public struct TypedInQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let fieldName: String
    public let values: [any TupleElement]

    public init(fieldName: String, values: [any TupleElement]) {
        self.fieldName = fieldName
        self.values = values
    }

    public func matches(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> Bool {
        let fieldValues = try recordAccess.extractField(from: record, fieldName: fieldName)

        // For repeated/multi-valued fields, check if ANY extracted value is in the IN set
        // Example: tags IN ("swift", "fdb") → true if tags contains "swift" OR "fdb"
        for fieldValue in fieldValues {
            // Check if this field value matches any of the IN values
            for inValue in values {
                if TupleComparison.areEqual(fieldValue, inValue) {
                    return true
                }
            }
        }

        return false
    }
}

extension TypedInQueryComponent {
    /// Create an IN comparison
    ///
    /// - Parameters:
    ///   - fieldName: The field to check
    ///   - values: The values to match against
    /// - Returns: TypedInQueryComponent
    public static func `in`(_ fieldName: String, _ values: [any TupleElement]) -> TypedInQueryComponent<Record> {
        return TypedInQueryComponent(fieldName: fieldName, values: values)
    }
}
