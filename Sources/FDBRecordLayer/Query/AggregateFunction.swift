import Foundation
import FoundationDB

// MARK: - Aggregation Value

/// Type-safe aggregation result value
///
/// Supports full type preservation for aggregation results, not limited to Int64.
/// This ensures correct precision for floating-point aggregations and supports
/// the full range of FoundationDB data types.
///
/// **Supported Types:**
/// - Integer: Int64
/// - Floating-point: Double
/// - Decimal: Decimal (high-precision arithmetic)
/// - String: String (for MIN/MAX on text fields)
/// - Timestamp: Date
/// - UUID: UUID
/// - Null: Represents absence of value
///
/// **Example:**
/// ```swift
/// let avgSalary: AggregationValue = .double(75000.50)
/// let totalSales: AggregationValue = .integer(1_000_000)
/// let latestDate: AggregationValue = .timestamp(Date())
///
/// // Type-safe extraction
/// if let salary = avgSalary.doubleValue {
///     print("Average salary: $\(salary)")
/// }
/// ```
public enum AggregationValue: Sendable, Equatable, Hashable {
    case null
    case integer(Int64)
    case double(Double)
    case decimal(Decimal)
    case string(String)
    case timestamp(Date)
    case uuid(UUID)

    // MARK: - Convenience Accessors

    /// Extract Int64 value, converting if necessary
    public var intValue: Int64? {
        switch self {
        case .integer(let value):
            return value
        case .double(let value):
            return Int64(value)
        case .decimal(let value):
            return Int64(truncating: value as NSDecimalNumber)
        default:
            return nil
        }
    }

    /// Extract Double value, converting if necessary
    public var doubleValue: Double? {
        switch self {
        case .integer(let value):
            return Double(value)
        case .double(let value):
            return value
        case .decimal(let value):
            return Double(truncating: value as NSDecimalNumber)
        default:
            return nil
        }
    }

    /// Extract Decimal value, converting if necessary
    public var decimalValue: Decimal? {
        switch self {
        case .integer(let value):
            return Decimal(value)
        case .double(let value):
            return Decimal(value)
        case .decimal(let value):
            return value
        default:
            return nil
        }
    }

    /// Extract String value
    public var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        default:
            return nil
        }
    }

    /// Extract Date value
    public var timestampValue: Date? {
        switch self {
        case .timestamp(let value):
            return value
        default:
            return nil
        }
    }

    /// Extract UUID value
    public var uuidValue: UUID? {
        switch self {
        case .uuid(let value):
            return value
        default:
            return nil
        }
    }

    /// Check if value is null
    public var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    // MARK: - Arithmetic Operations

    /// Add two aggregation values with type promotion
    ///
    /// **Type Promotion Rules:**
    /// - Int + Int → Int
    /// - Int + Double → Double
    /// - Double + Double → Double
    /// - Decimal + Decimal → Decimal
    /// - Other combinations → null
    public static func + (lhs: AggregationValue, rhs: AggregationValue) -> AggregationValue {
        switch (lhs, rhs) {
        case (.integer(let a), .integer(let b)):
            return .integer(a + b)
        case (.double(let a), .double(let b)):
            return .double(a + b)
        case (.decimal(let a), .decimal(let b)):
            return .decimal(a + b)
        case (.integer(let a), .double(let b)):
            return .double(Double(a) + b)
        case (.double(let a), .integer(let b)):
            return .double(a + Double(b))
        case (.integer(let a), .decimal(let b)):
            return .decimal(Decimal(a) + b)
        case (.decimal(let a), .integer(let b)):
            return .decimal(a + Decimal(b))
        default:
            return .null
        }
    }

    /// Subtract two aggregation values with type promotion
    public static func - (lhs: AggregationValue, rhs: AggregationValue) -> AggregationValue {
        switch (lhs, rhs) {
        case (.integer(let a), .integer(let b)):
            return .integer(a - b)
        case (.double(let a), .double(let b)):
            return .double(a - b)
        case (.decimal(let a), .decimal(let b)):
            return .decimal(a - b)
        case (.integer(let a), .double(let b)):
            return .double(Double(a) - b)
        case (.double(let a), .integer(let b)):
            return .double(a - Double(b))
        default:
            return .null
        }
    }

    /// Multiply two aggregation values with type promotion
    public static func * (lhs: AggregationValue, rhs: AggregationValue) -> AggregationValue {
        switch (lhs, rhs) {
        case (.integer(let a), .integer(let b)):
            return .integer(a * b)
        case (.double(let a), .double(let b)):
            return .double(a * b)
        case (.decimal(let a), .decimal(let b)):
            return .decimal(a * b)
        case (.integer(let a), .double(let b)):
            return .double(Double(a) * b)
        case (.double(let a), .integer(let b)):
            return .double(a * Double(b))
        default:
            return .null
        }
    }

    /// Divide two aggregation values with type promotion
    ///
    /// **Note:** Division by zero returns null
    public static func / (lhs: AggregationValue, rhs: AggregationValue) -> AggregationValue {
        switch (lhs, rhs) {
        case (.integer(let a), .integer(let b)):
            guard b != 0 else { return .null }
            // Integer division for backward compatibility
            return .integer(a / b)
        case (.double(let a), .double(let b)):
            guard b != 0 else { return .null }
            return .double(a / b)
        case (.decimal(let a), .decimal(let b)):
            guard b != 0 else { return .null }
            return .decimal(a / b)
        case (.integer(let a), .double(let b)):
            guard b != 0 else { return .null }
            return .double(Double(a) / b)
        case (.double(let a), .integer(let b)):
            guard b != 0 else { return .null }
            return .double(a / Double(b))
        default:
            return .null
        }
    }

    // MARK: - Comparison Operations

    /// Compare two aggregation values
    ///
    /// **Comparison Rules:**
    /// - Numeric types are compared by value with type promotion
    /// - String, UUID, Date are compared lexicographically
    /// - Null is less than all other values
    /// - Cross-type comparisons return false
    public static func < (lhs: AggregationValue, rhs: AggregationValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return false
        case (.null, _):
            return true
        case (_, .null):
            return false
        case (.integer(let a), .integer(let b)):
            return a < b
        case (.double(let a), .double(let b)):
            return a < b
        case (.decimal(let a), .decimal(let b)):
            return a < b
        case (.integer(let a), .double(let b)):
            return Double(a) < b
        case (.double(let a), .integer(let b)):
            return a < Double(b)
        case (.string(let a), .string(let b)):
            return a < b
        case (.timestamp(let a), .timestamp(let b)):
            return a < b
        case (.uuid(let a), .uuid(let b)):
            return a.uuidString < b.uuidString
        default:
            return false
        }
    }

    public static func > (lhs: AggregationValue, rhs: AggregationValue) -> Bool {
        return rhs < lhs
    }

    public static func <= (lhs: AggregationValue, rhs: AggregationValue) -> Bool {
        return lhs < rhs || lhs == rhs
    }

    public static func >= (lhs: AggregationValue, rhs: AggregationValue) -> Bool {
        return lhs > rhs || lhs == rhs
    }

    // MARK: - Serialization

    /// Pack aggregation value to FDB bytes
    public func pack() -> FDB.Bytes {
        switch self {
        case .null:
            return []
        case .integer(let value):
            return Tuple(value).pack()
        case .double(let value):
            return Tuple(value).pack()
        case .decimal(let value):
            // Store as string representation for precision
            return Tuple(value.description).pack()
        case .string(let value):
            return Tuple(value).pack()
        case .timestamp(let value):
            // Convert Date to Int64 (milliseconds since epoch)
            let milliseconds = Int64(value.timeIntervalSince1970 * 1000)
            return Tuple(milliseconds).pack()
        case .uuid(let value):
            // Store UUID as string
            return Tuple(value.uuidString).pack()
        }
    }

    /// Unpack aggregation value from FDB bytes
    ///
    /// **Note:** Type information is inferred from Tuple element type.
    /// Date and UUID are stored as Int64 and String respectively for compatibility.
    public static func unpack(from bytes: FDB.Bytes) throws -> AggregationValue {
        guard !bytes.isEmpty else {
            return .null
        }

        let tuple = try Tuple.unpack(from: bytes)
        guard tuple.count > 0 else {
            return .null
        }

        let element = tuple[0]

        if let int64 = element as? Int64 {
            return .integer(int64)
        } else if let double = element as? Double {
            return .double(double)
        } else if let string = element as? String {
            // Try to parse as UUID first
            if let uuid = UUID(uuidString: string) {
                return .uuid(uuid)
            }
            // Try to parse as Decimal
            if let decimal = Decimal(string: string) {
                return .decimal(decimal)
            }
            // Otherwise treat as string
            return .string(string)
        }

        return .null
    }
}

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

// MARK: - Average Function

/// Average aggregate function
///
/// Returns the average of values for a specific grouping.
///
/// **Note:** Requires an AVERAGE index to be defined, which maintains both
/// sum and count.
///
/// **Index Structure:**
/// ```swift
/// let avgIndex = Index(
///     name: "salary_avg_by_dept",
///     type: .average,
///     rootExpression: ConcatenateKeyExpression(children: [
///         FieldKeyExpression(fieldName: "department"),  // grouping
///         FieldKeyExpression(fieldName: "salary")       // averaged value
///     ])
/// )
/// ```
///
/// **Example:**
/// ```swift
/// let avgSalary = try await store.evaluateAggregate(
///     .average(indexName: "salary_avg_by_dept"),
///     recordType: "Employee",
///     groupBy: ["Engineering"]
/// )
/// print("Average Engineering salary: \(avgSalary)")
/// ```
public struct AverageFunction: AggregateFunction {
    public typealias Result = Double?

    public let indexName: String
    public let aggregateType: AggregateType = .avg

    public init(indexName: String) {
        self.indexName = indexName
    }

    public func evaluate(
        index: Index,
        subspace: Subspace,
        groupBy: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Double? {
        let groupingTuple = TupleHelpers.toTuple(groupBy)
        let sumKey = subspace.pack(Tuple([groupingTuple, "sum"]))
        let countKey = subspace.pack(Tuple([groupingTuple, "count"]))

        guard let sumBytes = try await transaction.getValue(for: sumKey),
              let countBytes = try await transaction.getValue(for: countKey) else {
            return nil
        }

        let sum = TupleHelpers.bytesToInt64(sumBytes)
        let count = TupleHelpers.bytesToInt64(countBytes)

        guard count > 0 else {
            return nil
        }

        return Double(sum) / Double(count)
    }
}

extension AggregateFunction where Self == AverageFunction {
    /// Create an average aggregate function
    public static func average(indexName: String) -> AverageFunction {
        return AverageFunction(indexName: indexName)
    }

    /// Create an average aggregate function (alias)
    public static func avg(indexName: String) -> AverageFunction {
        return AverageFunction(indexName: indexName)
    }
}
