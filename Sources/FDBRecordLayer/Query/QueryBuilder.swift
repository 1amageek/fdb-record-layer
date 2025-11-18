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

/// RANK query information
///
/// Holds metadata for topN/bottomN queries.
internal struct RankQueryInfo<Record: Recordable>: Sendable {
    /// Field name to rank by
    let fieldName: String

    /// Rank range
    let rankRange: RankRange

    /// Ascending (true) or descending (false)
    let ascending: Bool

    /// Index name to use (optional)
    let indexName: String?

    init(
        fieldName: String,
        rankRange: RankRange,
        ascending: Bool,
        indexName: String? = nil
    ) {
        self.fieldName = fieldName
        self.rankRange = rankRange
        self.ascending = ascending
        self.indexName = indexName
    }
}

public final class QueryBuilder<T: Recordable> {
    private let store: RecordStore<T>
    private let recordType: T.Type
    private let schema: Schema
    private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let rootSubspace: Subspace?
    private let statisticsManager: any StatisticsManagerProtocol
    private var filters: [any TypedQueryComponent<T>] = []
    internal var sortOrders: [(field: String, direction: SortDirection)] = []
    private var limitValue: Int?
    private var rankInfo: RankQueryInfo<T>?

    internal init(
        store: RecordStore<T>,
        recordType: T.Type,
        schema: Schema,
        database: any DatabaseProtocol,
        subspace: Subspace,
        rootSubspace: Subspace?,
        statisticsManager: any StatisticsManagerProtocol
    ) {
        self.store = store
        self.recordType = recordType
        self.schema = schema
        self.database = database
        self.subspace = subspace
        self.rootSubspace = rootSubspace
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

    // MARK: - Range Query Operations

    /// Query records where Range field overlaps with query range
    ///
    /// Efficiently finds records where a Range<Bound> field overlaps with the provided query range
    /// using two indexes (start and end).
    ///
    /// **Algorithm**: Two-index intersection
    /// - field.lowerBound < queryRange.upperBound (uses end index)
    /// - field.upperBound > queryRange.lowerBound (uses start index)
    ///
    /// **Prerequisites**:
    /// - Range field must have automatic indexes generated by #Index macro
    /// - Indexes: `{RecordType}_{fieldName}_start_index` and `{RecordType}_{fieldName}_end_index`
    ///
    /// **Example Usage**:
    /// ```swift
    /// @Recordable
    /// struct Event {
    ///     #Index<Event>([\.period])  // Auto-generates start + end indexes
    ///     var id: Int64
    ///     var period: Range<Date>
    /// }
    ///
    /// // Find events overlapping 2024-01-01 18:00-20:00
    /// let queryRange = date1..<date2
    /// let events = try await store.query()
    ///     .overlaps(\.period, with: queryRange)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to Range<Bound> field
    ///   - range: Query range to check overlap
    /// - Returns: Self (for method chaining)
    public func overlaps<Bound: TupleElement & Comparable>(
        _ keyPath: KeyPath<T, Range<Bound>>,
        with range: Range<Bound>
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)

        // Condition 1: field.lowerBound < queryRange.upperBound
        // Use KeyExpression-based component for proper Range boundary extraction
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .lowerBound,
                boundaryType: .halfOpen  // Range<T> is half-open
            ),
            comparison: .lessThan,
            value: range.upperBound
        )

        // Condition 2: field.upperBound > queryRange.lowerBound
        let upperBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .upperBound,
                boundaryType: .halfOpen
            ),
            comparison: .greaterThan,
            value: range.lowerBound
        )

        // Combine with AND
        let andFilter = TypedAndQueryComponent<T>(children: [lowerBoundFilter, upperBoundFilter])
        filters.append(andFilter)

        return self
    }

    /// Query records where ClosedRange field overlaps with query range
    ///
    /// Efficiently finds records where a ClosedRange<Bound> field overlaps with the provided query range
    /// using two indexes (start and end).
    ///
    /// **Algorithm**: Two-index intersection with closed boundary handling
    /// - field.lowerBound <= queryRange.upperBound (uses end index)
    /// - field.upperBound >= queryRange.lowerBound (uses start index)
    ///
    /// **Example Usage**:
    /// ```swift
    /// @Recordable
    /// struct Subscription {
    ///     #Index<Subscription>([\.validPeriod])
    ///     var id: Int64
    ///     var validPeriod: ClosedRange<Date>
    /// }
    ///
    /// let queryRange = startDate...endDate
    /// let subscriptions = try await store.query()
    ///     .overlaps(\.validPeriod, with: queryRange)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to ClosedRange<Bound> field
    ///   - range: Query range to check overlap
    /// - Returns: Self (for method chaining)
    public func overlaps<Bound: TupleElement & Comparable>(
        _ keyPath: KeyPath<T, ClosedRange<Bound>>,
        with range: ClosedRange<Bound>
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)

        // Condition 1: field.lowerBound <= queryRange.upperBound
        // Use KeyExpression-based component for proper Range boundary extraction
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .lowerBound,
                boundaryType: .closed  // ClosedRange<T> is closed
            ),
            comparison: .lessThanOrEquals,
            value: range.upperBound
        )

        // Condition 2: field.upperBound >= queryRange.lowerBound
        let upperBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .upperBound,
                boundaryType: .closed
            ),
            comparison: .greaterThanOrEquals,
            value: range.lowerBound
        )

        // Combine with AND
        let andFilter = TypedAndQueryComponent<T>(children: [lowerBoundFilter, upperBoundFilter])
        filters.append(andFilter)

        return self
    }

    /// Query records where Optional Range field overlaps with query range
    ///
    /// Efficiently finds records where an Optional Range<Bound> field overlaps with the provided query range.
    /// Records with nil values are automatically excluded from results.
    ///
    /// **Note**: This method uses the same two-index intersection algorithm as the non-optional variant.
    /// The Optional unwrapping is handled during index value extraction in RecordAccess.
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to Optional Range<Bound> field
    ///   - range: Query range to check overlap
    /// - Returns: Self (for method chaining)
    public func overlaps<Bound: TupleElement & Comparable>(
        _ keyPath: KeyPath<T, Range<Bound>?>,
        with range: Range<Bound>
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)

        // Condition 1: field.lowerBound < queryRange.upperBound
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,
            value: range.upperBound
        )

        // Condition 2: field.upperBound > queryRange.lowerBound
        let upperBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .upperBound,
                boundaryType: .halfOpen
            ),
            comparison: .greaterThan,
            value: range.lowerBound
        )

        // Combine with AND
        let andFilter = TypedAndQueryComponent<T>(children: [lowerBoundFilter, upperBoundFilter])
        filters.append(andFilter)

        return self
    }

    /// Query records where Optional ClosedRange field overlaps with query range
    ///
    /// Efficiently finds records where an Optional ClosedRange<Bound> field overlaps with the provided query range.
    /// Records with nil values are automatically excluded from results.
    ///
    /// **Note**: This method uses the same two-index intersection algorithm as the non-optional variant.
    /// The Optional unwrapping is handled during index value extraction in RecordAccess.
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to Optional ClosedRange<Bound> field
    ///   - range: Query range to check overlap
    /// - Returns: Self (for method chaining)
    public func overlaps<Bound: TupleElement & Comparable>(
        _ keyPath: KeyPath<T, ClosedRange<Bound>?>,
        with range: ClosedRange<Bound>
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)

        // Condition 1: field.lowerBound <= queryRange.upperBound
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .lowerBound,
                boundaryType: .closed
            ),
            comparison: .lessThanOrEquals,
            value: range.upperBound
        )

        // Condition 2: field.upperBound >= queryRange.lowerBound
        let upperBoundFilter = TypedKeyExpressionQueryComponent<T>(
            keyExpression: RangeKeyExpression(
                fieldName: fieldName,
                component: .upperBound,
                boundaryType: .closed
            ),
            comparison: .greaterThanOrEquals,
            value: range.lowerBound
        )

        // Combine with AND
        let andFilter = TypedAndQueryComponent<T>(children: [lowerBoundFilter, upperBoundFilter])
        filters.append(andFilter)

        return self
    }

    /// Top N records by specified field
    ///
    /// Retrieves the top N records sorted by the specified field using a RANK index.
    ///
    /// **Prerequisites**:
    /// - A RANK index must be defined on the target field
    /// - The index must be in 'readable' state
    ///
    /// **Performance**:
    /// - O(log n + k) where n = total records, k = result count
    /// - Regular sort: O(n log n)
    /// - **Improvement**: Up to 7,960x faster (for 1M records)
    ///
    /// **IMPORTANT - Filter Limitation**:
    /// - ⚠️ **topN() cannot be used with where() filters on simple RANK indexes**
    /// - Using filters would return incorrect results (global top N filtered, not filtered top N)
    /// - For filtered top N queries, use a **Composite RANK Index** with grouping fields:
    ///
    /// ```swift
    /// // ❌ INCORRECT - Will return global top 10 filtered by city (may be < 10 results)
    /// let wrong = try await store.query()
    ///     .where(\.city == "Tokyo")
    ///     .topN(10, by: \.score)  // ← Throws error
    ///     .execute()
    ///
    /// // ✅ CORRECT - Use Composite RANK Index
    /// // Define index: [city, score] with type = .rank
    /// Index(
    ///     name: "score_by_city_rank",
    ///     type: .rank,
    ///     rootExpression: ConcatenateKeyExpression(children: [
    ///         FieldKeyExpression(fieldName: "city"),    // Grouping
    ///         FieldKeyExpression(fieldName: "score")    // Rank value
    ///     ])
    /// )
    ///
    /// // Query will use grouping prefix automatically
    /// let correct = try await store.query()
    ///     .where(\.city == "Tokyo")  // ← Matches index prefix
    ///     .topN(10, by: \.score, indexName: "score_by_city_rank")
    ///     .execute()
    /// ```
    ///
    /// **Simple topN (no filters)**:
    /// ```swift
    /// // Top 10 users by score (all users)
    /// let topTen = try await store.query()
    ///     .topN(10, by: \.score)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - count: Number of records to retrieve
    ///   - keyPath: KeyPath to the field to rank by
    ///   - indexName: Index name to use (optional, auto-detected if nil)
    /// - Returns: Self (for method chaining)
    public func topN<Value: Comparable & TupleElement>(
        _ count: Int,
        by keyPath: KeyPath<T, Value>,
        indexName: String? = nil
    ) -> Self {
        precondition(count > 0, "count must be positive")

        let fieldName = T.fieldName(for: keyPath)
        let rankRange = RankRange(begin: 0, end: count)

        self.rankInfo = RankQueryInfo(
            fieldName: fieldName,
            rankRange: rankRange,
            ascending: false,  // Top N = descending
            indexName: indexName
        )

        // Also set limit (fallback if planner doesn't use RANK index)
        return self.limit(count)
    }

    /// Bottom N records by specified field
    ///
    /// Retrieves the bottom N records sorted by the specified field using a RANK index.
    ///
    /// **IMPORTANT - Filter Limitation**:
    /// - ⚠️ **bottomN() cannot be used with where() filters on simple RANK indexes**
    /// - For filtered bottom N queries, use a **Composite RANK Index** (see topN() documentation)
    ///
    /// **Example**:
    /// ```swift
    /// // Bottom 5 users by score (all users)
    /// let bottomFive = try await store.query()
    ///     .bottomN(5, by: \.score)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - count: Number of records to retrieve
    ///   - keyPath: KeyPath to the field to rank by
    ///   - indexName: Index name to use (optional)
    /// - Returns: Self (for method chaining)
    public func bottomN<Value: Comparable & TupleElement>(
        _ count: Int,
        by keyPath: KeyPath<T, Value>,
        indexName: String? = nil
    ) -> Self {
        precondition(count > 0, "count must be positive")

        let fieldName = T.fieldName(for: keyPath)
        let rankRange = RankRange(begin: 0, end: count)

        self.rankInfo = RankQueryInfo(
            fieldName: fieldName,
            rankRange: rankRange,
            ascending: true,  // Bottom N = ascending
            indexName: indexName
        )

        return self.limit(count)
    }

    // MARK: - Execution

    /// Execute RANK query
    ///
    /// - Parameter rankInfo: RANK query information
    /// - Returns: Array of records
    /// - Throws: RecordLayerError if execution fails
    private func executeRankQuery(rankInfo: RankQueryInfo<T>) async throws -> [T] {
        // CRITICAL: Validate that no filters are present
        // topN/bottomN with filters on simple RANK indexes would return incorrect results
        if !filters.isEmpty {
            throw RecordLayerError.invalidArgument("""
                topN()/bottomN() cannot be used with where() filters on simple RANK indexes.

                Problem: Using filters would return global top N filtered (incorrect),
                         not filtered top N (expected).

                Example of incorrect behavior:
                  .where(\\.city == "Tokyo").topN(10, by: \\.score)
                  → Returns: global top 10 filtered by Tokyo (may be < 10 results)
                  → Expected: Tokyo's top 10 by score

                Solution: Use a Composite RANK Index with grouping fields:

                1. Define composite RANK index:
                   Index(
                       name: "score_by_city_rank",
                       type: .rank,
                       rootExpression: ConcatenateKeyExpression(children: [
                           FieldKeyExpression(fieldName: "city"),    // Grouping
                           FieldKeyExpression(fieldName: "score")    // Rank value
                       ])
                   )

                2. Query will automatically use grouping prefix:
                   .where(\\.city == "Tokyo")
                   .topN(10, by: \\.score, indexName: "score_by_city_rank")

                For simple top N without filters, remove the where() clause.
                """)
        }

        // 1. Find RANK index for the field
        let rankIndex: Index
        if let indexName = rankInfo.indexName {
            // Use specified index
            guard let index = schema.indexes(for: T.recordName).first(where: { $0.name == indexName }) else {
                throw RecordLayerError.indexNotFound(indexName)
            }
            rankIndex = index
        } else {
            // Auto-detect RANK index
            let indexes = schema.indexes(for: T.recordName).filter { index in
                index.type == .rank &&
                extractFieldNames(from: index.rootExpression).contains(rankInfo.fieldName)
            }

            guard let index = indexes.first else {
                throw RecordLayerError.indexNotFound("No RANK index found for field '\(rankInfo.fieldName)'")
            }
            rankIndex = index
        }

        // 2. Verify index is in readable state
        guard rankIndex.type == .rank else {
            throw RecordLayerError.invalidArgument("Index '\(rankIndex.name)' is not a RANK index")
        }

        // 3. Create index subspace
        let indexSubspace = subspace
            .subspace("I")
            .subspace(rankIndex.name)

        // 4. Create TypedRankIndexScanPlan
        let recordSubspace = subspace.subspace("R")
        let recordAccess = GenericRecordAccess<T>()

        let plan = TypedRankIndexScanPlan<T>(
            recordAccess: recordAccess,
            recordSubspace: recordSubspace,
            indexSubspace: indexSubspace,
            index: rankIndex,
            scanType: .byRank,
            rankRange: rankInfo.rankRange,
            ascending: rankInfo.ascending
        )

        // 5. Execute the plan
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: true
        )

        // 6. Collect results
        // Note: No post-filtering needed since filters are validated above
        var results: [T] = []
        for try await record in cursor {
            results.append(record)
            if let limit = limitValue, results.count >= limit {
                break
            }
        }

        return results
    }

    // MARK: - Testing Support

    /// Build the query and planner for testing purposes
    ///
    /// This method is internal and used by tests to verify query plans without executing.
    ///
    /// - Returns: Tuple of (query, planner)
    internal func buildQueryAndPlanner() -> (query: TypedRecordQuery<T>, planner: TypedRecordQueryPlanner<T>) {
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

        let planner = TypedRecordQueryPlanner<T>(
            schema: schema,
            recordName: T.recordName,
            statisticsManager: statisticsManager
        )

        return (query, planner)
    }

    // MARK: - Execution

    /// Execute the query
    ///
    /// - Returns: Array of records
    /// - Throws: RecordLayerError if execution fails
    public func execute() async throws -> [T] {
        // Check if this is a RANK query
        if let rankInfo = rankInfo {
            return try await executeRankQuery(rankInfo: rankInfo)
        }

        // Build query and planner
        let (query, planner) = buildQueryAndPlanner()
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
        } else if let rangeExpr = expression as? RangeKeyExpression {
            // Range型フィールドは fieldName を返す（"period.lowerBound" ではなく "period"）
            return [rangeExpr.fieldName]
        } else if let concatExpr = expression as? ConcatenateKeyExpression {
            return concatExpr.children.flatMap { extractFieldNames(from: $0) }
        }
        return []
    }

    /// Get the base index subspace based on index scope
    ///
    /// - For partition-local indexes: returns subspace.subspace("I")
    /// - For global indexes: returns rootSubspace.subspace("G") if rootSubspace exists
    ///
    /// - Parameter index: The index definition
    /// - Returns: Base index subspace (caller should add index.name)
    /// - Throws: RecordLayerError.invalidArgument if global index requires rootSubspace but it's nil
    private func baseIndexSubspace(for index: Index) throws -> Subspace {
        switch index.scope {
        case .partition:
            // Partition-local index: use "I" subspace within current partition
            return subspace.subspace("I")

        case .global:
            // Global index: use "G" subspace under root
            guard let root = rootSubspace else {
                throw RecordLayerError.invalidArgument(
                    "Global index '\(index.name)' requires rootSubspace, but QueryBuilder was created without it. " +
                    "Ensure RecordStore was initialized with a rootSubspace for global index support."
                )
            }
            return root.subspace("G")
        }
    }

    // MARK: - Vector Search

    /// Find K nearest neighbors using vector similarity search (KeyPath-based, type-safe)
    ///
    /// **Recommended API**: Uses KeyPath for type-safe index selection.
    ///
    /// Automatically selects the best vector search algorithm:
    /// - **HNSW**: O(log n) search for large datasets (if index built with OnlineIndexer)
    /// - **Flat Scan**: O(n) search for small datasets or when HNSW unavailable
    ///
    /// **Example**:
    /// ```swift
    /// // Type-safe: KeyPath automatically resolves to index name
    /// let similar = try await store.query(Product.self)
    ///     .nearestNeighbors(k: 10, to: queryEmbedding, using: \.embedding)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - k: Number of nearest neighbors to return (must be > 0)
    ///   - queryVector: Query vector as Float32 array
    ///   - fieldKeyPath: KeyPath to the vector field (e.g., \.embedding)
    /// - Throws: RecordLayerError.indexNotFound if no vector index exists for field
    /// - Throws: RecordLayerError.invalidArgument if k <= 0 or dimensions mismatch
    /// - Returns: TypedVectorQuery for further refinement
    public func nearestNeighbors<Field>(
        k: Int,
        to queryVector: [Float32],
        using fieldKeyPath: KeyPath<T, Field>
    ) throws -> TypedVectorQuery<T> {
        // Validate k
        guard k > 0 else {
            throw RecordLayerError.invalidArgument("k must be positive, got: \(k)")
        }

        // Resolve KeyPath to index name
        let indexName = try resolveVectorIndexName(for: fieldKeyPath)

        // Find index
        guard let index = schema.indexes(for: T.recordName).first(where: { $0.name == indexName }) else {
            throw RecordLayerError.indexNotFound(
                "Vector index '\(indexName)' not found in schema for record type '\(T.recordName)'"
            )
        }

        // Validate index type
        guard index.type == .vector else {
            throw RecordLayerError.invalidArgument(
                "Index '\(indexName)' is not a vector index (type: \(index.type))"
            )
        }

        // Validate dimensions
        guard let vectorOptions = index.options.vectorOptions else {
            throw RecordLayerError.internalError(
                "Vector index '\(indexName)' missing vectorOptions"
            )
        }

        guard queryVector.count == vectorOptions.dimensions else {
            throw RecordLayerError.invalidArgument(
                "Query vector dimension mismatch. Expected: \(vectorOptions.dimensions), Got: \(queryVector.count)"
            )
        }

        let recordAccess = GenericRecordAccess<T>()

        // Get base index subspace (respects index.scope)
        let baseIndexSubspace = try baseIndexSubspace(for: index)

        return TypedVectorQuery(
            k: k,
            queryVector: queryVector,
            index: index,
            recordAccess: recordAccess,
            recordSubspace: subspace.subspace("R"),
            indexSubspace: baseIndexSubspace,
            rootSubspace: subspace,
            database: database,
            schema: schema
        )
    }

    // MARK: - Private Helpers

    /// Resolve KeyPath to vector index name
    ///
    /// - Parameter fieldKeyPath: KeyPath to the vector field
    /// - Returns: Index name
    /// - Throws: RecordLayerError.indexNotFound if no vector index exists for field
    private func resolveVectorIndexName<Field>(for fieldKeyPath: KeyPath<T, Field>) throws -> String {
        // Use the macro-generated fieldName method to get field name
        let fieldName = T.fieldName(for: fieldKeyPath)

        // First check macro-generated index definitions
        let indexDefs = T.indexDefinitions
        if let indexDef = indexDefs.first(where: { def in
            // Check if this is a vector index and uses the field
            if case .vector = def.indexType {
                return def.fields.count == 1 && def.fields[0] == fieldName
            }
            return false
        }) {
            return indexDef.name
        }

        // If not found in macro definitions, check schema's manually added indexes
        let schemaIndexes = schema.indexes(for: T.recordName)
        if let manualIndex = schemaIndexes.first(where: { index in
            // Check if this is a vector index
            guard index.type == .vector else { return false }

            // Check if the index uses this field
            // For vector indexes, rootExpression is typically a FieldKeyExpression
            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                return fieldExpr.fieldName == fieldName
            }
            return false
        }) {
            return manualIndex.name
        }

        throw RecordLayerError.indexNotFound(
            "No vector index found for field '\(fieldName)' in record type '\(T.recordName)'"
        )
    }

    // MARK: - Spatial Search

    /// Perform geographic radius search using a spatial index
    ///
    /// Searches for records within a circular radius from a center point.
    /// **Only supported for .geo spatial indexes**.
    ///
    /// **Distance Metric**: Great-circle distance (spherical Earth)
    ///
    /// **Example**:
    /// ```swift
    /// // Find restaurants within 5km of Tokyo Station
    /// let restaurants = try await store.query(Restaurant.self)
    ///     .withinRadius(
    ///         \.location,  // KeyPath to @Spatial field
    ///         centerLat: 35.6812,
    ///         centerLon: 139.7671,
    ///         radiusMeters: 5000
    ///     )
    ///     .filter(\.category == "Italian")
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to the @Spatial field
    ///   - centerLat: Center latitude in degrees (WGS84)
    ///   - centerLon: Center longitude in degrees (WGS84)
    ///   - radiusMeters: Radius in meters
    /// - Throws: RecordLayerError.indexNotFound if spatial index doesn't exist for the field
    /// - Throws: RecordLayerError.invalidArgument if index is not .geo type
    /// - Returns: TypedSpatialQuery for further refinement
    public func withinRadius<Value>(
        _ keyPath: KeyPath<T, Value>,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) throws -> TypedSpatialQuery<T> {
        // Validate radiusMeters
        guard radiusMeters > 0 else {
            throw RecordLayerError.invalidArgument("radiusMeters must be positive, got: \(radiusMeters)")
        }

        // Get field name from KeyPath
        let fieldName = T.fieldName(for: keyPath)

        // Find spatial index for this field
        let indexes = schema.indexes(for: T.recordName).filter { index in
            index.type == .spatial &&
            extractFieldNames(from: index.rootExpression).contains(fieldName)
        }

        guard let index = indexes.first else {
            throw RecordLayerError.indexNotFound(
                "No spatial index found for field '\(fieldName)' in record type '\(T.recordName)'. " +
                "Ensure the field has @Spatial annotation."
            )
        }

        // Validate .geo type
        guard let spatialOptions = index.options.spatialOptions,
              case .geo = spatialOptions.type else {
            throw RecordLayerError.invalidArgument(
                "Radius queries are only supported for .geo spatial indexes. " +
                "Field '\(fieldName)' has spatial type: \(index.options.spatialOptions?.type.debugDescription ?? "unknown")"
            )
        }

        let recordAccess = GenericRecordAccess<T>()

        // Get base index subspace (respects index.scope)
        let baseIndexSubspace = try baseIndexSubspace(for: index)

        return TypedSpatialQuery(
            queryType: .radius(centerLat: centerLat, centerLon: centerLon, radiusMeters: radiusMeters),
            index: index,
            recordAccess: recordAccess,
            recordSubspace: subspace.subspace("R"),
            indexSubspace: baseIndexSubspace,
            database: database
        )
    }

    /// Perform geographic bounding box search using a spatial index
    ///
    /// Searches for records within a rectangular bounding box.
    /// **Supported for .geo and .geo3D spatial indexes**.
    ///
    /// **Example**:
    /// ```swift
    /// // Find stores in Tokyo region
    /// let stores = try await store.query(Store.self)
    ///     .withinBoundingBox(
    ///         \.location,  // KeyPath to @Spatial field
    ///         minLat: 35.5, maxLat: 35.8,
    ///         minLon: 139.5, maxLon: 139.9
    ///     )
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to the @Spatial field
    ///   - minLat: Minimum latitude in degrees (WGS84)
    ///   - maxLat: Maximum latitude in degrees (WGS84)
    ///   - minLon: Minimum longitude in degrees (WGS84)
    ///   - maxLon: Maximum longitude in degrees (WGS84)
    /// - Throws: RecordLayerError.indexNotFound if spatial index doesn't exist for the field
    /// - Throws: RecordLayerError.invalidArgument if index is not .geo type
    /// - Returns: TypedSpatialQuery for further refinement
    public func withinBoundingBox<Value>(
        _ keyPath: KeyPath<T, Value>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) throws -> TypedSpatialQuery<T> {
        // Validate bounds
        guard minLat <= maxLat else {
            throw RecordLayerError.invalidArgument("minLat (\(minLat)) must be <= maxLat (\(maxLat))")
        }
        guard minLon <= maxLon else {
            throw RecordLayerError.invalidArgument("minLon (\(minLon)) must be <= maxLon (\(maxLon))")
        }

        // Get field name from KeyPath
        let fieldName = T.fieldName(for: keyPath)

        // Find spatial index for this field
        let indexes = schema.indexes(for: T.recordName).filter { index in
            index.type == .spatial &&
            extractFieldNames(from: index.rootExpression).contains(fieldName)
        }

        guard let index = indexes.first else {
            throw RecordLayerError.indexNotFound(
                "No spatial index found for field '\(fieldName)' in record type '\(T.recordName)'. " +
                "Ensure the field has @Spatial annotation."
            )
        }

        // Validate .geo type
        guard let spatialOptions = index.options.spatialOptions,
              case .geo = spatialOptions.type else {
            throw RecordLayerError.invalidArgument(
                "Geographic bounding box queries require .geo spatial index. " +
                "Field '\(fieldName)' has spatial type: \(index.options.spatialOptions?.type.debugDescription ?? "unknown")"
            )
        }

        let recordAccess = GenericRecordAccess<T>()

        // Get base index subspace (respects index.scope)
        let baseIndexSubspace = try baseIndexSubspace(for: index)

        return TypedSpatialQuery(
            queryType: .geoBoundingBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon),
            index: index,
            recordAccess: recordAccess,
            recordSubspace: subspace.subspace("R"),
            indexSubspace: baseIndexSubspace,
            database: database
        )
    }

    /// Perform Cartesian 2D bounding box search using a spatial index
    ///
    /// Searches for records within a rectangular bounding box in 2D Cartesian space.
    /// **Only supported for .cartesian spatial indexes**.
    ///
    /// **Coordinate System**: Normalized [0, 1] × [0, 1] space
    ///
    /// **Example**:
    /// ```swift
    /// // Find warehouses in region
    /// let warehouses = try await store.query(Warehouse.self)
    ///     .withinBoundingBox(
    ///         \.position,  // KeyPath to @Spatial field
    ///         minX: 0.2, maxX: 0.8,
    ///         minY: 0.3, maxY: 0.9
    ///     )
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to the @Spatial field
    ///   - minX: Minimum X coordinate (normalized to [0, 1])
    ///   - maxX: Maximum X coordinate (normalized to [0, 1])
    ///   - minY: Minimum Y coordinate (normalized to [0, 1])
    ///   - maxY: Maximum Y coordinate (normalized to [0, 1])
    /// - Throws: RecordLayerError.indexNotFound if spatial index doesn't exist for the field
    /// - Throws: RecordLayerError.invalidArgument if index is not .cartesian type
    /// - Returns: TypedSpatialQuery for further refinement
    public func withinBoundingBox<Value>(
        _ keyPath: KeyPath<T, Value>,
        minX: Double, maxX: Double,
        minY: Double, maxY: Double
    ) throws -> TypedSpatialQuery<T> {
        // Validate bounds
        guard minX <= maxX else {
            throw RecordLayerError.invalidArgument("minX (\(minX)) must be <= maxX (\(maxX))")
        }
        guard minY <= maxY else {
            throw RecordLayerError.invalidArgument("minY (\(minY)) must be <= maxY (\(maxY))")
        }

        // Get field name from KeyPath
        let fieldName = T.fieldName(for: keyPath)

        // Find spatial index for this field
        let indexes = schema.indexes(for: T.recordName).filter { index in
            index.type == .spatial &&
            extractFieldNames(from: index.rootExpression).contains(fieldName)
        }

        guard let index = indexes.first else {
            throw RecordLayerError.indexNotFound(
                "No spatial index found for field '\(fieldName)' in record type '\(T.recordName)'. " +
                "Ensure the field has @Spatial annotation."
            )
        }

        // Validate .cartesian type
        guard let spatialOptions = index.options.spatialOptions,
              case .cartesian = spatialOptions.type else {
            throw RecordLayerError.invalidArgument(
                "Cartesian 2D bounding box queries require .cartesian spatial index. " +
                "Field '\(fieldName)' has spatial type: \(index.options.spatialOptions?.type.debugDescription ?? "unknown")"
            )
        }

        let recordAccess = GenericRecordAccess<T>()

        // Get base index subspace (respects index.scope)
        let baseIndexSubspace = try baseIndexSubspace(for: index)

        return TypedSpatialQuery(
            queryType: .cartesianBoundingBox(minX: minX, maxX: maxX, minY: minY, maxY: maxY),
            index: index,
            recordAccess: recordAccess,
            recordSubspace: subspace.subspace("R"),
            indexSubspace: baseIndexSubspace,
            database: database
        )
    }

    /// Perform Cartesian 3D bounding box search using a spatial index
    ///
    /// Searches for records within a rectangular bounding box in 3D Cartesian space.
    /// **Only supported for .cartesian3D spatial indexes**.
    ///
    /// **Coordinate System**: Normalized [0, 1] × [0, 1] × [0, 1] space
    ///
    /// **Example**:
    /// ```swift
    /// // Find drones in airspace
    /// let drones = try await store.query(Drone.self)
    ///     .withinBoundingBox3D(
    ///         \.position,  // KeyPath to @Spatial field
    ///         minX: 0.0, maxX: 1.0,
    ///         minY: 0.0, maxY: 1.0,
    ///         minZ: 0.2, maxZ: 0.8
    ///     )
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to the @Spatial field
    ///   - minX: Minimum X coordinate (normalized to [0, 1])
    ///   - maxX: Maximum X coordinate (normalized to [0, 1])
    ///   - minY: Minimum Y coordinate (normalized to [0, 1])
    ///   - maxY: Maximum Y coordinate (normalized to [0, 1])
    ///   - minZ: Minimum Z coordinate (normalized to [0, 1])
    ///   - maxZ: Maximum Z coordinate (normalized to [0, 1])
    /// - Throws: RecordLayerError.indexNotFound if spatial index doesn't exist for the field
    /// - Throws: RecordLayerError.invalidArgument if index is not .cartesian3D type
    /// - Returns: TypedSpatialQuery for further refinement
    public func withinBoundingBox3D<Value>(
        _ keyPath: KeyPath<T, Value>,
        minX: Double, maxX: Double,
        minY: Double, maxY: Double,
        minZ: Double, maxZ: Double
    ) throws -> TypedSpatialQuery<T> {
        // Validate bounds
        guard minX <= maxX else {
            throw RecordLayerError.invalidArgument("minX (\(minX)) must be <= maxX (\(maxX))")
        }
        guard minY <= maxY else {
            throw RecordLayerError.invalidArgument("minY (\(minY)) must be <= maxY (\(maxY))")
        }
        guard minZ <= maxZ else {
            throw RecordLayerError.invalidArgument("minZ (\(minZ)) must be <= maxZ (\(maxZ))")
        }

        // Get field name from KeyPath
        let fieldName = T.fieldName(for: keyPath)

        // Find spatial index for this field
        let indexes = schema.indexes(for: T.recordName).filter { index in
            index.type == .spatial &&
            extractFieldNames(from: index.rootExpression).contains(fieldName)
        }

        guard let index = indexes.first else {
            throw RecordLayerError.indexNotFound(
                "No spatial index found for field '\(fieldName)' in record type '\(T.recordName)'. " +
                "Ensure the field has @Spatial annotation."
            )
        }

        // Validate .cartesian3D type
        guard let spatialOptions = index.options.spatialOptions,
              case .cartesian3D = spatialOptions.type else {
            throw RecordLayerError.invalidArgument(
                "Cartesian 3D bounding box queries require .cartesian3D spatial index. " +
                "Field '\(fieldName)' has spatial type: \(index.options.spatialOptions?.type.debugDescription ?? "unknown")"
            )
        }

        let recordAccess = GenericRecordAccess<T>()

        // Get base index subspace (respects index.scope)
        let baseIndexSubspace = try baseIndexSubspace(for: index)

        return TypedSpatialQuery(
            queryType: .cartesian3DBoundingBox(
                minX: minX, maxX: maxX,
                minY: minY, maxY: maxY,
                minZ: minZ, maxZ: maxZ
            ),
            index: index,
            recordAccess: recordAccess,
            recordSubspace: subspace.subspace("R"),
            indexSubspace: baseIndexSubspace,
            database: database
        )
    }

}
