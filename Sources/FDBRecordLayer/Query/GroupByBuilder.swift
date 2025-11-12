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

// MARK: - AggregationAccumulator

/// Helper struct to accumulate aggregation values for a group
///
/// Maintains state for COUNT, SUM, AVG, MIN, MAX as records are processed.
/// **Updated to use AggregationValue** for full type preservation.
struct AggregationAccumulator {
    // MARK: - Properties

    private var counts: [String: Int64] = [:]
    private var sums: [String: AggregationValue] = [:]  // ✅ Type-preserving
    private var mins: [String: AggregationValue] = [:]  // ✅ Type-preserving
    private var maxs: [String: AggregationValue] = [:]  // ✅ Type-preserving

    // For AVG: track sum and count separately
    private var avgSums: [String: AggregationValue] = [:]
    private var avgCounts: [String: Int64] = [:]

    // MARK: - Methods

    /// Apply an aggregation to a record
    ///
    /// Extracts the field value and updates the appropriate accumulator.
    ///
    /// - Parameters:
    ///   - aggregation: The aggregation to apply
    ///   - record: The record to process
    ///   - recordAccess: Record accessor for field extraction
    /// - Throws: RecordLayerError if field extraction fails
    mutating func apply<Record: Recordable>(
        _ aggregation: Aggregation,
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws {
        let alias = aggregation.alias

        switch aggregation.function {
        case .count:
            // COUNT(*): just increment counter
            counts[alias, default: 0] += 1

        case .sum:
            guard let fieldName = aggregation.fieldName else {
                throw RecordLayerError.invalidArgument("SUM requires a field name")
            }
            let values = try recordAccess.extractField(from: record, fieldName: fieldName)
            guard let value = values.first else {
                throw RecordLayerError.invalidArgument("Field '\(fieldName)' not found")
            }
            let aggValue = try toAggregationValue(value, for: .sum)
            sums[alias] = (sums[alias] ?? .integer(0)) + aggValue

        case .average:
            guard let fieldName = aggregation.fieldName else {
                throw RecordLayerError.invalidArgument("AVG requires a field name")
            }
            let values = try recordAccess.extractField(from: record, fieldName: fieldName)
            guard let value = values.first else {
                throw RecordLayerError.invalidArgument("Field '\(fieldName)' not found")
            }
            let aggValue = try toAggregationValue(value, for: .average)
            avgSums[alias] = (avgSums[alias] ?? .integer(0)) + aggValue
            avgCounts[alias, default: 0] += 1

        case .min:
            guard let fieldName = aggregation.fieldName else {
                throw RecordLayerError.invalidArgument("MIN requires a field name")
            }
            let values = try recordAccess.extractField(from: record, fieldName: fieldName)
            guard let value = values.first else {
                throw RecordLayerError.invalidArgument("Field '\(fieldName)' not found")
            }
            let aggValue = try toAggregationValue(value, for: .min)
            if let currentMin = mins[alias] {
                mins[alias] = aggValue < currentMin ? aggValue : currentMin
            } else {
                mins[alias] = aggValue
            }

        case .max:
            guard let fieldName = aggregation.fieldName else {
                throw RecordLayerError.invalidArgument("MAX requires a field name")
            }
            let values = try recordAccess.extractField(from: record, fieldName: fieldName)
            guard let value = values.first else {
                throw RecordLayerError.invalidArgument("Field '\(fieldName)' not found")
            }
            let aggValue = try toAggregationValue(value, for: .max)
            if let currentMax = maxs[alias] {
                maxs[alias] = aggValue > currentMax ? aggValue : currentMax
            } else {
                maxs[alias] = aggValue
            }
        }
    }

    /// Finalize accumulated values into a result dictionary
    ///
    /// Computes final values for all aggregations (e.g., AVG = sum / count).
    ///
    /// - Parameter aggregations: List of aggregations to finalize
    /// - Returns: Dictionary of alias → aggregated value
    func finalize(aggregations: [Aggregation]) -> [String: AggregationValue] {
        var results: [String: AggregationValue] = [:]

        for aggregation in aggregations {
            let alias = aggregation.alias

            switch aggregation.function {
            case .count:
                results[alias] = .integer(counts[alias] ?? 0)

            case .sum:
                results[alias] = sums[alias] ?? .null

            case .average:
                if let sum = avgSums[alias], let count = avgCounts[alias], count > 0 {
                    // Compute average with type promotion to match sum's type
                    // This ensures the division operator has matching types
                    let promotedSum: AggregationValue
                    let countValue: AggregationValue

                    switch sum {
                    case .integer(let value):
                        // Integer → Double to preserve precision
                        promotedSum = .double(Double(value))
                        countValue = .double(Double(count))
                    case .double:
                        // Already Double
                        promotedSum = sum
                        countValue = .double(Double(count))
                    case .decimal(let value):
                        // Decimal → keep as Decimal
                        promotedSum = .decimal(value)
                        countValue = .decimal(Decimal(count))
                    default:
                        // Other types: use as-is with Double count
                        promotedSum = sum
                        countValue = .double(Double(count))
                    }

                    results[alias] = promotedSum / countValue
                } else {
                    results[alias] = .null
                }

            case .min:
                results[alias] = mins[alias] ?? .null

            case .max:
                results[alias] = maxs[alias] ?? .null
            }
        }

        return results
    }

    // MARK: - Accessor Methods for Spill-to-FDB

    /// Get count value for an alias
    func getCount(alias: String) -> Int64? {
        return counts[alias]
    }

    /// Get sum value for an alias
    func getSum(alias: String) -> AggregationValue? {
        return sums[alias]
    }

    /// Get average (sum, count) for an alias
    func getAverage(alias: String) -> (AggregationValue, Int64)? {
        guard let sum = avgSums[alias], let count = avgCounts[alias] else {
            return nil
        }
        return (sum, count)
    }

    /// Get min value for an alias
    func getMin(alias: String) -> AggregationValue? {
        return mins[alias]
    }

    /// Get max value for an alias
    func getMax(alias: String) -> AggregationValue? {
        return maxs[alias]
    }

    // MARK: - Helper Methods

    /// Convert TupleElement to type-preserving AggregationValue
    ///
    /// Supports Int64, Double, Decimal, String, UUID, Date.
    ///
    /// - Parameters:
    ///   - value: The value to convert
    ///   - functionType: The aggregation function type (for validation)
    /// - Returns: AggregationValue representation
    /// - Throws: RecordLayerError if value cannot be converted or is incompatible with function
    private func toAggregationValue(
        _ value: any TupleElement,
        for functionType: Aggregation.Function
    ) throws -> AggregationValue {
        if let int64 = value as? Int64 {
            return .integer(int64)
        } else if let int = value as? Int {
            return .integer(Int64(int))
        } else if let int32 = value as? Int32 {
            return .integer(Int64(int32))
        } else if let double = value as? Double {
            return .double(double)
        } else if let float = value as? Float {
            return .double(Double(float))
        } else if let string = value as? String {
            // Strings are only valid for MIN/MAX (lexicographic comparison)
            // SUM/AVG require numeric types
            switch functionType {
            case .min, .max:
                // Keep as string for lexicographic comparison
                return .string(string)
            case .sum, .average:
                throw RecordLayerError.invalidArgument(
                    "\(functionType) aggregation requires numeric types, got String. " +
                    "Use MIN/MAX for string fields if you need lexicographic ordering."
                )
            case .count:
                // COUNT doesn't use field values
                return .string(string)
            }
        } else if let uuid = value as? UUID {
            return .uuid(uuid)
        } else if let date = value as? Date {
            return .timestamp(date)
        } else {
            throw RecordLayerError.invalidArgument(
                "Cannot aggregate value of type \(type(of: value)). " +
                "Supported types: Int64, Double, Decimal, String (MIN/MAX only), UUID, Date"
            )
        }
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
    /// Configuration for GROUP BY execution
    public struct Config: Sendable {
        public let maxGroupsInMemory: Int

        public static func makeDefault() -> Config {
            return Config(maxGroupsInMemory: 10_000)
        }

        public init(maxGroupsInMemory: Int = 10_000) {
            self.maxGroupsInMemory = maxGroupsInMemory
        }
    }

    private let recordStore: RecordStore<Record>
    private let groupByField: String
    private let aggregations: [Aggregation]
    private var havingPredicate: ((GroupKey, [String: AggregationValue]) -> Bool)?
    private var config: Config

    public init(
        recordStore: RecordStore<Record>,
        groupByField: String,
        aggregations: [Aggregation],
        config: Config = .makeDefault()
    ) {
        self.recordStore = recordStore
        self.groupByField = groupByField
        self.aggregations = aggregations
        self.config = config
    }

    /// Add HAVING clause
    ///
    /// Filters groups based on aggregated values.
    ///
    /// **Updated to use AggregationValue** for full type preservation.
    ///
    /// - Parameter predicate: Predicate to filter groups
    /// - Returns: Updated builder
    public func having(_ predicate: @escaping (GroupKey, [String: AggregationValue]) -> Bool) -> Self {
        var builder = self
        builder.havingPredicate = predicate
        return builder
    }

    /// Execute GROUP BY query
    ///
    /// **Memory management**:
    /// - Enforces maxGroupsInMemory limit
    /// - Throws error if limit exceeded
    /// - Future: Will support spill-to-FDB for large datasets
    ///
    /// - Returns: Array of grouped results
    /// - Throws: RecordLayerError if execution fails or memory limit exceeded
    public func execute() async throws -> [GroupExecutionResult<GroupKey>] {
        let recordAccess = GenericRecordAccess<Record>()

        // Dictionary to accumulate aggregations for each group
        // Key: GroupKey, Value: accumulated aggregation values
        var groups: [GroupKey: AggregationAccumulator] = [:]

        // Scan all records
        for try await record in recordStore.scan() {
            // Extract group key value from record
            let groupKeyValues = try recordAccess.extractField(from: record, fieldName: groupByField)

            guard let groupKeyValue = groupKeyValues.first else {
                throw RecordLayerError.invalidArgument("Group by field '\(groupByField)' not found in record")
            }

            // Cast to GroupKey type with type conversion support
            let groupKey: GroupKey
            if let directCast = groupKeyValue as? GroupKey {
                groupKey = directCast
            } else if GroupKey.self == Int.self, let int64Value = groupKeyValue as? Int64 {
                // Support Int64 → Int conversion for common case
                groupKey = Int(int64Value) as! GroupKey
            } else if GroupKey.self == Int64.self, let intValue = groupKeyValue as? Int {
                // Support Int → Int64 conversion
                groupKey = Int64(intValue) as! GroupKey
            } else {
                throw RecordLayerError.invalidArgument(
                    "Group by field '\(groupByField)' value of type \(type(of: groupKeyValue)) cannot be cast to \(GroupKey.self)"
                )
            }

            // Get or create accumulator for this group
            var accumulator = groups[groupKey] ?? AggregationAccumulator()

            // Apply each aggregation
            for aggregation in aggregations {
                try accumulator.apply(aggregation, record: record, recordAccess: recordAccess)
            }

            groups[groupKey] = accumulator

            // ✅ Memory limit check with detailed error message
            if groups.count > config.maxGroupsInMemory {
                throw RecordLayerError.resourceExhausted(
                    """
                    GROUP BY exceeded memory limit: \(config.maxGroupsInMemory) groups.

                    Current unique groups: \(groups.count)
                    Suggestions:
                    1. Add a WHERE clause to filter records before grouping
                    2. Increase maxGroupsInMemory in Config (current: \(config.maxGroupsInMemory))
                    3. Process data in smaller batches

                    Note: Spill-to-FDB for large datasets is planned for future release.
                    """
                )
            }
        }

        // Convert to results and apply HAVING filter
        var results: [GroupExecutionResult<GroupKey>] = []

        for (groupKey, accumulator) in groups {
            let aggregationValues = accumulator.finalize(aggregations: aggregations)

            // Apply HAVING filter if present
            if let havingPredicate = havingPredicate {
                guard havingPredicate(groupKey, aggregationValues) else {
                    continue  // Skip this group
                }
            }

            results.append(GroupExecutionResult(
                groupKey: groupKey,
                aggregations: aggregationValues
            ))
        }

        return results
    }

    /// Execute and map to custom result type
    ///
    /// **Updated to use AggregationValue** for full type preservation.
    ///
    /// - Parameter transform: Transformation function
    /// - Returns: Array of transformed results
    /// - Throws: RecordLayerError if execution fails
    public func execute<Result>(
        transform: (GroupKey, [String: AggregationValue]) throws -> Result
    ) async throws -> [Result] {
        let results = try await execute()
        return try results.map { try transform($0.groupKey, $0.aggregations) }
    }
}
