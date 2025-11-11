import Foundation

/// GROUP BY Result Builder
///
/// Provides a SwiftUI-style declarative syntax for GROUP BY queries.
///
/// **Example**:
/// ```swift
/// let builder = GroupByQueryBuilder<Sale, String>(
///     recordStore: store,
///     groupByField: "region",
///     aggregations: [
///         .sum("amount", as: "totalSales"),
///         .average("price", as: "avgPrice"),
///         .count(as: "orderCount")
///     ]
/// )
/// let results = try await builder
///     .having { groupKey, aggregations in
///         (aggregations["totalSales"] ?? 0) > 10000
///     }
///     .execute()
/// ```
@resultBuilder
public struct GroupByBuilder {
    // MARK: - Result Builder Methods

    /// Build a single aggregation
    public static func buildBlock(_ aggregation: Aggregation) -> [Aggregation] {
        return [aggregation]
    }

    /// Build multiple aggregations
    public static func buildBlock(_ aggregations: Aggregation...) -> [Aggregation] {
        return aggregations
    }

    /// Build array of aggregations
    public static func buildArray(_ components: [[Aggregation]]) -> [Aggregation] {
        return components.flatMap { $0 }
    }

    /// Build optional aggregation
    public static func buildOptional(_ component: [Aggregation]?) -> [Aggregation] {
        return component ?? []
    }

    /// Build either branch
    public static func buildEither(first component: [Aggregation]) -> [Aggregation] {
        return component
    }

    /// Build second either branch
    public static func buildEither(second component: [Aggregation]) -> [Aggregation] {
        return component
    }

    /// Build limited availability
    public static func buildLimitedAvailability(_ component: [Aggregation]) -> [Aggregation] {
        return component
    }
}

// MARK: - Aggregation DSL Components

/// COUNT(*) aggregation component for GROUP BY
public struct GBCount: Sendable {
    let aggregation: Aggregation

    /// Initialize COUNT aggregation
    ///
    /// - Parameter alias: Result alias (default: "count")
    public init(as alias: String = "count") {
        self.aggregation = .count(as: alias)
    }
}

/// SUM(field) aggregation component for GROUP BY
public struct GBSum: Sendable {
    let aggregation: Aggregation

    /// Initialize SUM aggregation
    ///
    /// - Parameters:
    ///   - field: Field to sum
    ///   - alias: Result alias
    public init(_ field: String, as alias: String) {
        self.aggregation = .sum(field, as: alias)
    }
}

/// AVG(field) aggregation component for GROUP BY
public struct GBAverage: Sendable {
    let aggregation: Aggregation

    /// Initialize AVG aggregation
    ///
    /// - Parameters:
    ///   - field: Field to average
    ///   - alias: Result alias
    public init(_ field: String, as alias: String) {
        self.aggregation = .average(field, as: alias)
    }
}

/// MIN(field) aggregation component for GROUP BY
public struct GBMin: Sendable {
    let aggregation: Aggregation

    /// Initialize MIN aggregation
    ///
    /// - Parameters:
    ///   - field: Field to find minimum
    ///   - alias: Result alias
    public init(_ field: String, as alias: String) {
        self.aggregation = .min(field, as: alias)
    }
}

/// MAX(field) aggregation component for GROUP BY
public struct GBMax: Sendable {
    let aggregation: Aggregation

    /// Initialize MAX aggregation
    ///
    /// - Parameters:
    ///   - field: Field to find maximum
    ///   - alias: Result alias
    public init(_ field: String, as alias: String) {
        self.aggregation = .max(field, as: alias)
    }
}

// MARK: - GroupByBuilder Extensions

extension GroupByBuilder {
    /// Build GBCount component
    public static func buildExpression(_ expression: GBCount) -> Aggregation {
        return expression.aggregation
    }

    /// Build GBSum component
    public static func buildExpression(_ expression: GBSum) -> Aggregation {
        return expression.aggregation
    }

    /// Build GBAverage component
    public static func buildExpression(_ expression: GBAverage) -> Aggregation {
        return expression.aggregation
    }

    /// Build GBMin component
    public static func buildExpression(_ expression: GBMin) -> Aggregation {
        return expression.aggregation
    }

    /// Build GBMax component
    public static func buildExpression(_ expression: GBMax) -> Aggregation {
        return expression.aggregation
    }
}

// MARK: - GroupByQueryBuilder

/// Builder for GROUP BY queries with fluent API
///
/// Provides HAVING clause and execution methods.
///
/// **Example**:
/// ```swift
/// let builder = GroupByQueryBuilder<User, String>(
///     recordStore: store,
///     groupByField: "region",
///     aggregations: [
///         .sum("amount", as: "totalSales"),
///         .average("price", as: "avgPrice"),
///         .count(as: "orderCount")
///     ]
/// )
/// let results = try await builder
///     .having { groupKey, aggregations in
///         (aggregations["totalSales"] ?? 0) > 10000
///     }
///     .execute()
/// ```
public struct GroupByQueryBuilder<Record: Recordable, GroupKey: Hashable & Sendable> {
    private let recordStore: RecordStore<Record>
    private let groupByField: String
    private let aggregations: [Aggregation]
    private var havingPredicate: ((GroupKey, [String: Int64]) -> Bool)?

    public init(
        recordStore: RecordStore<Record>,
        groupByField: String,
        aggregations: [Aggregation]
    ) {
        self.recordStore = recordStore
        self.groupByField = groupByField
        self.aggregations = aggregations
    }

    /// Add HAVING clause
    ///
    /// Filters groups based on aggregated values.
    ///
    /// - Parameter predicate: Predicate to filter groups
    /// - Returns: Updated builder
    public func having(_ predicate: @escaping (GroupKey, [String: Int64]) -> Bool) -> Self {
        var builder = self
        builder.havingPredicate = predicate
        return builder
    }

    /// Execute GROUP BY query
    ///
    /// - Returns: Array of grouped results
    /// - Throws: RecordLayerError if execution fails
    public func execute() async throws -> [GroupExecutionResult<GroupKey>] {
        throw RecordLayerError.internalError(
            """
            GROUP BY execution not yet implemented.

            Missing requirement: RecordStore.scan() method for record iteration.

            Current status:
            - RecordAccess is available (GenericRecordAccess<Record>)
            - RecordStore can fetch individual records
            - Missing: Method to iterate all records of a type

            Alternative: Low-level range scan of recordSubspace is possible but requires
            manual deserialization and filtering logic.

            Future implementation:
            1. Implement RecordStore.scan() -> AsyncSequence<Record>
            2. Scan all records and extract groupByField value using RecordAccess
            3. Cast groupByField value to GroupKey type
            4. Accumulate aggregations for each group:
               - COUNT: increment counter
               - SUM: add field value (extract via RecordAccess)
               - AVG: track sum and count
               - MIN/MAX: track min/max value
            5. Apply HAVING clause filter (using havingPredicate)
            6. Return GroupExecutionResult array
            """
        )
    }

    /// Execute and map to custom result type
    ///
    /// - Parameter transform: Transformation function
    /// - Returns: Array of transformed results
    /// - Throws: RecordLayerError if execution fails
    public func execute<Result>(
        transform: (GroupKey, [String: Int64]) throws -> Result
    ) async throws -> [Result] {
        let results = try await execute()
        return try results.map { try transform($0.groupKey, $0.aggregations) }
    }
}
