import Foundation
import FoundationDB

/// Type-safe query builder
///
/// QueryBuilder provides a type-safe query API for Recordable types.
/// Uses KeyPaths to specify fields and construct type-checked filter conditions.
///
/// **Example Usage**:
/// ```swift
/// let userStore: RecordStore<User> = ...
///
/// // Simple equality comparison
/// let users = try await userStore.query()
///     .where(\.email, .equals, "alice@example.com")
///     .execute()
///
/// // Multiple conditions
/// let tokyoUsers = try await userStore.query()
///     .where(\.country, .equals, "Japan")
///     .where(\.city, .equals, "Tokyo")
///     .limit(10)
///     .execute()
/// ```
/// Sort direction for ORDER BY
public enum SortDirection: Sendable {
    case ascending
    case descending
}

public final class QueryBuilder<T: Recordable> {
    private let store: RecordStore<T>
    private let recordType: T.Type
    private let schema: Schema
    private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let statisticsManager: any StatisticsManagerProtocol
    private var filters: [any TypedQueryComponent<T>] = []
    internal var sortOrders: [(field: String, direction: SortDirection)] = []
    private var limitValue: Int?

    internal init(
        store: RecordStore<T>,
        recordType: T.Type,
        schema: Schema,
        database: any DatabaseProtocol,
        subspace: Subspace,
        statisticsManager: any StatisticsManagerProtocol
    ) {
        self.store = store
        self.recordType = recordType
        self.schema = schema
        self.database = database
        self.subspace = subspace
        self.statisticsManager = statisticsManager
    }

    // MARK: - Query Construction

    /// Add a filter condition
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to the field
    ///   - comparison: Comparison operator
    ///   - value: Comparison value
    /// - Returns: Self (for method chaining)
    public func `where`<Value: TupleElement>(
        _ keyPath: KeyPath<T, Value>,
        is comparison: TypedFieldQueryComponent<T>.Comparison,
        _ value: Value
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        let filter = TypedFieldQueryComponent<T>(
            fieldName: fieldName,
            comparison: comparison,
            value: value
        )
        filters.append(filter)
        return self
    }

    /// Add a filter condition (Predicate version)
    ///
    /// Adds a filter condition using operator overloading.
    ///
    /// **Example Usage**:
    /// ```swift
    /// let users = try await store.query()
    ///     .where(\.email == "alice@example.com")
    ///     .where(\.age > 18 && \.city == "Tokyo")
    ///     .execute()
    /// ```
    ///
    /// - Parameter predicate: Predicate condition
    /// - Returns: Self (for method chaining)
    public func `where`(_ predicate: Predicate<T>) -> Self {
        filters.append(predicate.component)
        return self
    }

    /// Set sort order
    ///
    /// **Example Usage**:
    /// ```swift
    /// let users = try await store.query()
    ///     .orderBy(\.createdAt, .descending)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to the field to sort by
    ///   - direction: Sort direction (default: .ascending)
    /// - Returns: Self (for method chaining)
    public func orderBy<Value: TupleElement & Comparable>(
        _ keyPath: KeyPath<T, Value>,
        _ direction: SortDirection = .ascending
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        sortOrders.append((field: fieldName, direction: direction))
        return self
    }

    /// Set result limit
    ///
    /// - Parameter limit: Maximum number of records to fetch
    /// - Returns: Self (for method chaining)
    public func limit(_ limit: Int) -> Self {
        self.limitValue = limit
        return self
    }

    // MARK: - Execution

    /// Execute the query
    ///
    /// - Returns: Array of records
    /// - Throws: RecordLayerError if execution fails
    public func execute() async throws -> [T] {
        // Build TypedRecordQuery
        let filter: (any TypedQueryComponent<T>)? = filters.isEmpty ? nil : (filters.count == 1 ? filters[0] : TypedAndQueryComponent<T>(children: filters))

        // Convert sort orders to TypedSortKey
        let sortKeys: [TypedSortKey<T>]? = sortOrders.isEmpty ? nil : sortOrders.map { order in
            TypedSortKey<T>(fieldName: order.field, ascending: order.direction == .ascending)
        }

        let query = TypedRecordQuery<T>(
            filter: filter,
            sort: sortKeys,
            limit: limitValue
        )

        // Use QueryPlanner to create optimal execution plan
        // Use real StatisticsManager for cost-based optimization
        let planner = TypedRecordQueryPlanner<T>(
            schema: schema,
            recordName: T.recordName,
            statisticsManager: statisticsManager
        )
        let plan = try await planner.plan(query: query)

        // Execute the plan
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let recordAccess = GenericRecordAccess<T>()
        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: true
        )

        // Collect results
        var results: [T] = []
        for try await record in cursor {
            results.append(record)
            if let limit = limitValue, results.count >= limit {
                break
            }
        }

        return results
    }

    /// Get the first record
    ///
    /// - Returns: First record, or nil if none found
    /// - Throws: RecordLayerError if execution fails
    public func first() async throws -> T? {
        let originalLimit = limitValue
        limitValue = 1
        let results = try await execute()
        limitValue = originalLimit
        return results.first
    }

    /// Count records matching the query
    ///
    /// **Implementation**: Automatically uses COUNT index when available, otherwise falls back to full scan.
    ///
    /// **COUNT Index Optimization**:
    /// - Optimizes queries with equality filters that match a COUNT index grouping
    /// - Example: `.where(\.city == "Tokyo")` uses COUNT index grouped by `city`
    /// - Falls back to full scan for complex filters (OR, NOT, range comparisons)
    ///
    /// - Returns: Number of records
    /// - Throws: RecordLayerError if execution fails
    public func count() async throws -> Int {
        // Try COUNT index optimization
        if let countResult = try await tryCountIndexOptimization() {
            return countResult
        }

        // Fallback: fetch all and count
        let results = try await execute()
        return results.count
    }

    /// Try to optimize count using COUNT index
    private func tryCountIndexOptimization() async throws -> Int? {
        // Only optimize for simple equality filters
        guard !filters.isEmpty else { return nil }

        // Extract equality filters
        var equalityFilters: [(field: String, value: any TupleElement)] = []
        for filter in filters {
            if let fieldFilter = filter as? TypedFieldQueryComponent<T>,
               fieldFilter.comparison == .equals {
                equalityFilters.append((field: fieldFilter.fieldName, value: fieldFilter.value))
            } else {
                // Non-equality filter found, cannot use COUNT index
                return nil
            }
        }

        guard !equalityFilters.isEmpty else { return nil }

        // Get all COUNT indexes for this record type
        let allIndexes = schema.indexes(for: T.recordName)
        let countIndexes = allIndexes.filter { $0.type == .count }

        // Try to find a matching COUNT index
        for index in countIndexes {
            if let groupingValues = try matchCountIndex(
                index: index,
                equalityFilters: equalityFilters
            ) {
                // Use COUNT index
                let transaction = try database.createTransaction()
                defer { transaction.cancel() }

                let indexSubspace = subspace
                    .subspace("I")
                    .subspace(index.name)

                let maintainer = GenericCountIndexMaintainer<T>(
                    index: index,
                    subspace: indexSubspace
                )

                let count = try await maintainer.getCount(
                    groupingValues: groupingValues,
                    transaction: transaction
                )

                return Int(count)
            }
        }

        return nil
    }

    /// Check if equality filters match a COUNT index and extract grouping values
    private func matchCountIndex(
        index: Index,
        equalityFilters: [(field: String, value: any TupleElement)]
    ) throws -> [any TupleElement]? {
        // Extract field names from index expression
        let indexFields = extractFieldNames(from: index.rootExpression)

        // Check if filters exactly match index fields (in order)
        guard indexFields.count == equalityFilters.count else {
            return nil
        }

        var groupingValues: [any TupleElement] = []
        for indexField in indexFields {
            if let matchingFilter = equalityFilters.first(where: { $0.field == indexField }) {
                groupingValues.append(matchingFilter.value)
            } else {
                // Field not found in filters
                return nil
            }
        }

        // Verify order matches
        for (i, filter) in equalityFilters.enumerated() {
            if indexFields[i] != filter.field {
                return nil
            }
        }

        return groupingValues
    }

    /// Extract field names from a key expression
    private func extractFieldNames(from expression: any KeyExpression) -> [String] {
        if let fieldExpr = expression as? FieldKeyExpression {
            return [fieldExpr.fieldName]
        } else if let concatExpr = expression as? ConcatenateKeyExpression {
            return concatExpr.children.flatMap { extractFieldNames(from: $0) }
        }
        return []
    }
}
