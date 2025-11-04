import Foundation

/// Utilities for converting RecordQuery to TypedRecordQuery
///
/// This module provides conversion functions to bridge between the non-type-safe
/// RecordQuery (used by RecordStore API) and the type-safe TypedRecordQuery
/// (used by TypedRecordQueryPlanner).

// MARK: - Query Conversion

extension RecordQuery {
    /// Convert to TypedRecordQuery
    ///
    /// - Parameters:
    ///   - recordTypeName: The expected record type name
    /// - Returns: TypedRecordQuery for the specified record type
    /// - Throws: RecordLayerError if query references multiple record types
    public func toTypedQuery<Record: Sendable>(
        recordTypeName: String
    ) throws -> TypedRecordQuery<Record> {
        // Verify this query is for a single record type
        guard recordTypes.count == 1, recordTypes.contains(recordTypeName) else {
            throw RecordLayerError.internalError(
                "Cannot convert multi-type query to TypedRecordQuery. " +
                "Query types: \(recordTypes), expected: \(recordTypeName)"
            )
        }

        // Convert filter
        let typedFilter: (any TypedQueryComponent<Record>)? = try filter.map { component in
            try component.toTypedComponent()
        }

        // Convert sort (not yet implemented - requires TypedKeyExpression conversion)
        let typedSort: [TypedSortKey<Record>]? = nil

        return TypedRecordQuery(
            filter: typedFilter,
            sort: typedSort,
            limit: limit
        )
    }
}

// MARK: - QueryComponent Conversion

extension QueryComponent {
    /// Convert to TypedQueryComponent
    ///
    /// - Returns: Type-safe query component
    /// - Throws: RecordLayerError if conversion fails
    func toTypedComponent<Record: Sendable>() throws -> any TypedQueryComponent<Record> {
        if let fieldComponent = self as? FieldQueryComponent {
            return fieldComponent.toTypedComponent()
        } else if let andComponent = self as? AndQueryComponent {
            return try andComponent.toTypedComponent()
        } else if let orComponent = self as? OrQueryComponent {
            return try orComponent.toTypedComponent()
        } else if let notComponent = self as? NotQueryComponent {
            return try notComponent.toTypedComponent()
        } else {
            throw RecordLayerError.internalError("Unknown QueryComponent type: \(type(of: self))")
        }
    }
}

extension FieldQueryComponent {
    func toTypedComponent<Record: Sendable>() -> TypedFieldQueryComponent<Record> {
        let typedComparison: TypedFieldQueryComponent<Record>.Comparison
        switch comparison {
        case .equals:
            typedComparison = .equals
        case .notEquals:
            typedComparison = .notEquals
        case .lessThan:
            typedComparison = .lessThan
        case .lessThanOrEquals:
            typedComparison = .lessThanOrEquals
        case .greaterThan:
            typedComparison = .greaterThan
        case .greaterThanOrEquals:
            typedComparison = .greaterThanOrEquals
        case .startsWith:
            typedComparison = .startsWith
        case .contains:
            typedComparison = .contains
        }

        return TypedFieldQueryComponent(
            fieldName: fieldName,
            comparison: typedComparison,
            value: value
        )
    }
}

extension AndQueryComponent {
    func toTypedComponent<Record: Sendable>() throws -> TypedAndQueryComponent<Record> {
        let typedChildren = try children.map { try $0.toTypedComponent() as any TypedQueryComponent<Record> }
        return TypedAndQueryComponent(children: typedChildren)
    }
}

extension OrQueryComponent {
    func toTypedComponent<Record: Sendable>() throws -> TypedOrQueryComponent<Record> {
        let typedChildren = try children.map { try $0.toTypedComponent() as any TypedQueryComponent<Record> }
        return TypedOrQueryComponent(children: typedChildren)
    }
}

extension NotQueryComponent {
    func toTypedComponent<Record: Sendable>() throws -> TypedNotQueryComponent<Record> {
        let typedChild = try child.toTypedComponent() as any TypedQueryComponent<Record>
        return TypedNotQueryComponent(child: typedChild)
    }
}
