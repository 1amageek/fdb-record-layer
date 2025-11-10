import Foundation
import FoundationDB

// MARK: - Aggregate Function Protocol

/// Protocol for aggregate functions that can be executed on indexes
///
/// Aggregate functions provide a high-level API for querying aggregate indexes
/// (COUNT, SUM, MIN, MAX). They encapsulate the logic for retrieving aggregated
/// values from indexes.
///
/// **Usage:**
/// ```swift
/// // Count users by city
/// let count = try await store.evaluateAggregate(
///     .count(indexName: "user_count_by_city"),
///     recordType: "User",
///     groupBy: ["Tokyo"]
/// )
///
/// // Sum salaries by department
/// let total = try await store.evaluateAggregate(
///     .sum(indexName: "salary_by_dept"),
///     recordType: "Employee",
///     groupBy: ["Engineering"]
/// )
/// ```
public protocol AggregateFunction: Sendable {
    associatedtype Result: Sendable

    /// The name of the index to query
    var indexName: String { get }

    /// The type of aggregation
    var aggregateType: AggregateType { get }

    /// Evaluate the aggregate function
    /// - Parameters:
    ///   - index: The index definition
    ///   - subspace: The index subspace
    ///   - groupBy: The grouping values
    ///   - transaction: The transaction to use
    /// - Returns: The aggregated result
    func evaluate(
        index: Index,
        subspace: Subspace,
        groupBy: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Result
}

// MARK: - Aggregate Type

/// Types of aggregate operations
public enum AggregateType: String, Sendable {
    case count = "COUNT"
    case sum = "SUM"
    case min = "MIN"
    case max = "MAX"
    case avg = "AVG"
}

// MARK: - Count Function

/// Count aggregate function
///
/// Returns the count of records for a specific grouping.
///
/// **Example:**
/// ```swift
/// let userCount = try await store.evaluateAggregate(
///     .count(indexName: "user_count_by_city"),
///     recordType: "User",
///     groupBy: ["Tokyo"]
/// )
/// print("Tokyo users: \(userCount)")
/// ```
public struct CountFunction: AggregateFunction {
    public typealias Result = Int64

    public let indexName: String
    public let aggregateType: AggregateType = .count

    public init(indexName: String) {
        self.indexName = indexName
    }

    public func evaluate(
        index: Index,
        subspace: Subspace,
        groupBy: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        let groupingTuple = TupleHelpers.toTuple(groupBy)
        let countKey = subspace.pack(groupingTuple)

        guard let bytes = try await transaction.getValue(for: countKey) else {
            return 0
        }

        return TupleHelpers.bytesToInt64(bytes)
    }
}

// MARK: - Sum Function

/// Sum aggregate function
///
/// Returns the sum of values for a specific grouping.
///
/// **Example:**
/// ```swift
/// let totalSalary = try await store.evaluateAggregate(
///     .sum(indexName: "salary_by_dept"),
///     recordType: "Employee",
///     groupBy: ["Engineering"]
/// )
/// print("Total Engineering salary: \(totalSalary)")
/// ```
public struct SumFunction: AggregateFunction {
    public typealias Result = Int64

    public let indexName: String
    public let aggregateType: AggregateType = .sum

    public init(indexName: String) {
        self.indexName = indexName
    }

    public func evaluate(
        index: Index,
        subspace: Subspace,
        groupBy: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        let groupingTuple = TupleHelpers.toTuple(groupBy)
        let sumKey = subspace.pack(groupingTuple)

        guard let bytes = try await transaction.getValue(for: sumKey) else {
            return 0
        }

        return TupleHelpers.bytesToInt64(bytes)
    }
}

// MARK: - Min Function

/// Min aggregate function
///
/// Returns the minimum value for a specific grouping.
///
/// **Note:** Requires a MIN index to be defined.
///
/// **Index Structure:**
/// ```swift
/// let minIndex = Index(
///     name: "age_min_by_city",
///     type: .min,
///     rootExpression: ConcatenateKeyExpression(children: [
///         FieldKeyExpression(fieldName: "city"),  // grouping
///         FieldKeyExpression(fieldName: "age")     // min value
///     ])
/// )
/// ```
///
/// **Example:**
/// ```swift
/// let minAge = try await store.evaluateAggregate(
///     .min(indexName: "age_min_by_city"),
///     recordType: "User",
///     groupBy: ["Tokyo"]
/// )
/// print("Youngest Tokyo user: \(minAge)")
/// ```
public struct MinFunction: AggregateFunction {
    public typealias Result = Int64

    public let indexName: String
    public let aggregateType: AggregateType = .min

    public init(indexName: String) {
        self.indexName = indexName
    }

    public func evaluate(
        index: Index,
        subspace: Subspace,
        groupBy: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        return try await findMinValue(
            index: index,
            subspace: subspace,
            groupingValues: groupBy,
            transaction: transaction
        )
    }
}

// MARK: - Max Function

/// Max aggregate function
///
/// Returns the maximum value for a specific grouping.
///
/// **Note:** Requires a MAX index to be defined.
///
/// **Index Structure:**
/// ```swift
/// let maxIndex = Index(
///     name: "age_max_by_city",
///     type: .max,
///     rootExpression: ConcatenateKeyExpression(children: [
///         FieldKeyExpression(fieldName: "city"),  // grouping
///         FieldKeyExpression(fieldName: "age")     // max value
///     ])
/// )
/// ```
///
/// **Example:**
/// ```swift
/// let maxAge = try await store.evaluateAggregate(
///     .max(indexName: "age_max_by_city"),
///     recordType: "User",
///     groupBy: ["Tokyo"]
/// )
/// print("Oldest Tokyo user: \(maxAge)")
/// ```
public struct MaxFunction: AggregateFunction {
    public typealias Result = Int64

    public let indexName: String
    public let aggregateType: AggregateType = .max

    public init(indexName: String) {
        self.indexName = indexName
    }

    public func evaluate(
        index: Index,
        subspace: Subspace,
        groupBy: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        return try await findMaxValue(
            index: index,
            subspace: subspace,
            groupingValues: groupBy,
            transaction: transaction
        )
    }
}

// MARK: - Convenience Factories

extension AggregateFunction where Self == CountFunction {
    /// Create a count aggregate function
    public static func count(indexName: String) -> CountFunction {
        return CountFunction(indexName: indexName)
    }
}

extension AggregateFunction where Self == SumFunction {
    /// Create a sum aggregate function
    public static func sum(indexName: String) -> SumFunction {
        return SumFunction(indexName: indexName)
    }
}

extension AggregateFunction where Self == MinFunction {
    /// Create a min aggregate function
    public static func min(indexName: String) -> MinFunction {
        return MinFunction(indexName: indexName)
    }
}

extension AggregateFunction where Self == MaxFunction {
    /// Create a max aggregate function
    public static func max(indexName: String) -> MaxFunction {
        return MaxFunction(indexName: indexName)
    }
}
