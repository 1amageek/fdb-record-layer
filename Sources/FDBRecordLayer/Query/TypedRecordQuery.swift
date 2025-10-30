import Foundation

/// A type-safe query for records
///
/// TypedRecordQuery defines what records to retrieve, with optional filtering,
/// sorting, and pagination. Works with a specific record type for type safety.
public struct TypedRecordQuery<Record: Sendable>: Sendable {
    // MARK: - Properties

    /// Filter predicate (nil = no filter)
    public let filter: (any TypedQueryComponent<Record>)?

    /// Sort keys (nil = no sorting, use natural order)
    public let sort: [TypedSortKey<Record>]?

    /// Maximum number of results (nil = no limit)
    public let limit: Int?

    // MARK: - Initialization

    /// Create a query with optional filter, sort, and limit
    public init(
        filter: (any TypedQueryComponent<Record>)? = nil,
        sort: [TypedSortKey<Record>]? = nil,
        limit: Int? = nil
    ) {
        self.filter = filter
        self.sort = sort
        self.limit = limit
    }
}

// MARK: - Sort Key

/// Type-safe sort key specification
public struct TypedSortKey<Record: Sendable>: Sendable {
    /// The expression to sort by
    public let expression: any TypedKeyExpression<Record>

    /// Whether to sort ascending (true) or descending (false)
    public let ascending: Bool

    public init(expression: any TypedKeyExpression<Record>, ascending: Bool = true) {
        self.expression = expression
        self.ascending = ascending
    }
}

// MARK: - Query Builder

extension TypedRecordQuery {
    /// Create a query with a filter
    public static func filter(_ filter: any TypedQueryComponent<Record>) -> TypedRecordQuery<Record> {
        return TypedRecordQuery(filter: filter)
    }

    /// Add a filter to the query
    public func filter(_ filter: any TypedQueryComponent<Record>) -> TypedRecordQuery<Record> {
        if let existingFilter = self.filter {
            // Combine with AND
            let andFilter = TypedAndQueryComponent(children: [existingFilter, filter])
            return TypedRecordQuery(filter: andFilter, sort: sort, limit: limit)
        } else {
            return TypedRecordQuery(filter: filter, sort: sort, limit: limit)
        }
    }

    /// Add sorting to the query
    public func sort(by expression: any TypedKeyExpression<Record>, ascending: Bool = true) -> TypedRecordQuery<Record> {
        let sortKey = TypedSortKey(expression: expression, ascending: ascending)
        var newSort = sort ?? []
        newSort.append(sortKey)
        return TypedRecordQuery(filter: filter, sort: newSort, limit: limit)
    }

    /// Add a limit to the query
    public func limit(_ limit: Int) -> TypedRecordQuery<Record> {
        return TypedRecordQuery(filter: filter, sort: sort, limit: limit)
    }
}
