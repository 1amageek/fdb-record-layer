import Foundation

/// Grouped Query Result
///
/// Represents the result of a GROUP BY operation with aggregations.
///
/// **Example**:
/// ```swift
/// struct SalesByRegion: GroupedResult {
///     var region: String
///     var totalSales: Int64
///     var averagePrice: Double
///     var count: Int
/// }
/// ```
public protocol GroupedResult: Sendable {
    /// Group key type
    associatedtype GroupKey: Hashable & Sendable

    /// Initialize from group key and aggregated values
    init(groupKey: GroupKey, aggregations: [String: Int64])
}

/// GROUP BY Query
///
/// Represents a query with grouping and aggregations.
///
/// **Example**:
/// ```swift
/// let query = GroupByQuery<Sale, String>(
///     groupBy: "region",
///     aggregations: [
///         .sum("amount", as: "totalSales"),
///         .average("price", as: "averagePrice"),
///         .count(as: "count")
///     ]
/// )
/// ```
public struct GroupByQuery<Record: Sendable, GroupKey: Hashable & Sendable> {
    // MARK: - Properties

    /// Field to group by
    public let groupByField: String

    /// Aggregation functions to apply
    public let aggregations: [Aggregation]

    /// Optional HAVING clause
    public let having: ((GroupKey, [String: Int64]) -> Bool)?

    // MARK: - Initialization

    public init(
        groupBy: String,
        aggregations: [Aggregation],
        having: ((GroupKey, [String: Int64]) -> Bool)? = nil
    ) {
        self.groupByField = groupBy
        self.aggregations = aggregations
        self.having = having
    }
}

/// Aggregation Function
///
/// Defines an aggregation operation (COUNT, SUM, AVG, MIN, MAX).
public struct Aggregation: Sendable {
    // MARK: - Types

    public enum Function: String, Sendable {
        case count
        case sum
        case average
        case min
        case max
    }

    // MARK: - Properties

    /// Aggregation function
    public let function: Function

    /// Field to aggregate (nil for COUNT(*))
    public let fieldName: String?

    /// Result alias
    public let alias: String

    // MARK: - Initialization

    private init(function: Function, fieldName: String?, alias: String) {
        self.function = function
        self.fieldName = fieldName
        self.alias = alias
    }

    // MARK: - Factory Methods

    /// COUNT(*) aggregation
    ///
    /// - Parameter alias: Result alias (default: "count")
    /// - Returns: COUNT aggregation
    public static func count(as alias: String = "count") -> Aggregation {
        return Aggregation(function: .count, fieldName: nil, alias: alias)
    }

    /// SUM(field) aggregation
    ///
    /// - Parameters:
    ///   - fieldName: Field to sum
    ///   - alias: Result alias
    /// - Returns: SUM aggregation
    public static func sum(_ fieldName: String, as alias: String) -> Aggregation {
        return Aggregation(function: .sum, fieldName: fieldName, alias: alias)
    }

    /// AVG(field) aggregation
    ///
    /// - Parameters:
    ///   - fieldName: Field to average
    ///   - alias: Result alias
    /// - Returns: AVG aggregation
    public static func average(_ fieldName: String, as alias: String) -> Aggregation {
        return Aggregation(function: .average, fieldName: fieldName, alias: alias)
    }

    /// MIN(field) aggregation
    ///
    /// - Parameters:
    ///   - fieldName: Field to find minimum
    ///   - alias: Result alias
    /// - Returns: MIN aggregation
    public static func min(_ fieldName: String, as alias: String) -> Aggregation {
        return Aggregation(function: .min, fieldName: fieldName, alias: alias)
    }

    /// MAX(field) aggregation
    ///
    /// - Parameters:
    ///   - fieldName: Field to find maximum
    ///   - alias: Result alias
    /// - Returns: MAX aggregation
    public static func max(_ fieldName: String, as alias: String) -> Aggregation {
        return Aggregation(function: .max, fieldName: fieldName, alias: alias)
    }
}

/// Execution Result
///
/// Represents the result of a GROUP BY query execution.
public struct GroupExecutionResult<GroupKey: Hashable & Sendable>: Sendable {
    /// Group key
    public let groupKey: GroupKey

    /// Aggregated values
    public let aggregations: [String: Int64]

    public init(groupKey: GroupKey, aggregations: [String: Int64]) {
        self.groupKey = groupKey
        self.aggregations = aggregations
    }
}
