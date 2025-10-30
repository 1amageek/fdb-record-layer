import Foundation

/// A query for records
///
/// RecordQuery defines what records to retrieve, with optional filtering,
/// sorting, and pagination.
public struct RecordQuery: Sendable {
    // MARK: - Properties

    /// Record types to query
    public let recordTypes: Set<String>

    /// Filter predicate (nil = no filter)
    public let filter: (any QueryComponent)?

    /// Sort keys (nil = no sorting, use natural order)
    public let sort: [SortKey]?

    /// Maximum number of results (nil = no limit)
    public let limit: Int?

    // MARK: - Initialization

    /// Create a query for a single record type
    public init(
        recordType: String,
        filter: (any QueryComponent)? = nil,
        sort: [SortKey]? = nil,
        limit: Int? = nil
    ) {
        self.recordTypes = [recordType]
        self.filter = filter
        self.sort = sort
        self.limit = limit
    }

    /// Create a query for multiple record types
    public init(
        recordTypes: Set<String>,
        filter: (any QueryComponent)? = nil,
        sort: [SortKey]? = nil,
        limit: Int? = nil
    ) {
        self.recordTypes = recordTypes
        self.filter = filter
        self.sort = sort
        self.limit = limit
    }
}

// MARK: - Sort Key

/// Sort key specification
public struct SortKey: Sendable {
    /// The expression to sort by
    public let expression: KeyExpression

    /// Whether to sort ascending (true) or descending (false)
    public let ascending: Bool

    public init(expression: KeyExpression, ascending: Bool = true) {
        self.expression = expression
        self.ascending = ascending
    }
}
