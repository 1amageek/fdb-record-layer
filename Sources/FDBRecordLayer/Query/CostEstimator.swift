import Foundation

/// Cost estimator for query execution plans
///
/// Uses statistics-based cost estimation to predict the execution cost
/// of different query plans. The cost model considers:
/// - I/O cost (key-value reads from FoundationDB)
/// - CPU cost (deserialization, filtering)
/// - Estimated result size
public struct CostEstimator: Sendable {
    private let statisticsManager: any StatisticsManagerProtocol

    /// Cost constants (tunable based on benchmarking)
    private let ioReadCost: Double = 1.0
    private let cpuDeserializeCost: Double = 0.1
    private let cpuFilterCost: Double = 0.05

    public init(statisticsManager: any StatisticsManagerProtocol) {
        self.statisticsManager = statisticsManager
    }

    // MARK: - Public API

    /// Estimate total cost of a query plan
    ///
    /// - Parameters:
    ///   - plan: The execution plan
    ///   - recordType: The record type name
    ///   - sortKeys: Optional sort requirements to determine if sorting is needed
    ///   - schema: Optional schema to check if plan satisfies sort order
    /// - Returns: Estimated query cost
    internal func estimateCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String,
        sortKeys: [TypedSortKey<Record>]? = nil,
        schema: Schema? = nil
    ) async throws -> QueryCost {
        // Fetch statistics once at the top level (async-safe pattern)
        let tableStats = try? await statisticsManager.getTableStatistics(
            recordType: recordType
        )

        // Determine if this plan will need sorting
        let needsSort = determineNeedsSort(
            plan: plan,
            sortKeys: sortKeys,
            recordType: recordType,
            schema: schema
        )

        return try await estimatePlanCost(
            plan,
            recordType: recordType,
            tableStats: tableStats,
            needsSort: needsSort
        )
    }

    // MARK: - Sort Detection

    /// Determine if a plan will need sorting
    ///
    /// Only index scans can provide natural sort order. Other plan types
    /// (full scan, union, intersection, limit) require explicit sorting.
    ///
    /// - Parameters:
    ///   - plan: The query plan
    ///   - sortKeys: Required sort order
    ///   - recordType: Record type name
    ///   - schema: Schema to look up index definitions
    /// - Returns: true if plan will need TypedSortPlan wrapper
    private func determineNeedsSort<Record: Sendable>(
        plan: any TypedQueryPlan<Record>,
        sortKeys: [TypedSortKey<Record>]?,
        recordType: String,
        schema: Schema?
    ) -> Bool {
        // No sort required
        guard let sortKeys = sortKeys, !sortKeys.isEmpty else {
            return false
        }

        // No schema - assume sorting needed (conservative)
        guard let schema = schema else {
            return true
        }

        // Only index scans can provide natural sort order
        guard let indexScan = plan as? TypedIndexScanPlan<Record> else {
            return true  // Full scan, union, etc. need sorting
        }

        // Check if index provides the required sort order
        return !indexSatisfiesSort(
            indexName: indexScan.indexName,
            sortKeys: sortKeys,
            recordType: recordType,
            schema: schema
        )
    }

    /// Check if an index naturally provides the required sort order
    private func indexSatisfiesSort<Record: Sendable>(
        indexName: String,
        sortKeys: [TypedSortKey<Record>],
        recordType: String,
        schema: Schema
    ) -> Bool {
        // Get index definition
        guard let index = schema.indexes(for: recordType)
            .first(where: { $0.name == indexName }) else {
            return false
        }

        // Extract index fields from root expression
        let indexFields = extractFieldNames(from: index.rootExpression)

        // Check if index fields match sort keys in order
        guard indexFields.count >= sortKeys.count else {
            return false
        }

        for (i, sortKey) in sortKeys.enumerated() {
            guard i < indexFields.count,
                  indexFields[i] == sortKey.fieldName else {
                return false
            }

            // Check sort direction
            // FoundationDB VALUE indexes are always in ascending order
            // If descending sort is required, we need in-memory sorting
            if !sortKey.ascending {
                return false
            }
        }

        return true
    }

    /// Extract field names from a key expression
    private func extractFieldNames(from expression: any KeyExpression) -> [String] {
        if let field = expression as? FieldKeyExpression {
            return [field.fieldName]
        } else if let concat = expression as? ConcatenateKeyExpression {
            return concat.children.flatMap { extractFieldNames(from: $0) }
        }
        return []
    }

    // MARK: - Plan Cost Estimation

    /// Internal estimation with pre-fetched statistics
    private func estimatePlanCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?,
        needsSort: Bool
    ) async throws -> QueryCost {
        if let scanPlan = plan as? TypedFullScanPlan<Record> {
            return try await estimateFullScanCost(
                scanPlan,
                recordType: recordType,
                tableStats: tableStats,
                needsSort: needsSort
            )
        } else if let indexPlan = plan as? TypedIndexScanPlan<Record> {
            return try await estimateIndexScanCost(
                indexPlan,
                recordType: recordType,
                tableStats: tableStats,
                needsSort: needsSort
            )
        } else if let intersectionPlan = plan as? TypedIntersectionPlan<Record> {
            return try await estimateIntersectionCost(
                intersectionPlan,
                recordType: recordType,
                tableStats: tableStats,
                needsSort: needsSort
            )
        } else if let unionPlan = plan as? TypedUnionPlan<Record> {
            return try await estimateUnionCost(
                unionPlan,
                recordType: recordType,
                tableStats: tableStats,
                needsSort: needsSort
            )
        } else if let limitPlan = plan as? TypedLimitPlan<Record> {
            return try await estimateLimitCost(
                limitPlan,
                recordType: recordType,
                tableStats: tableStats,
                needsSort: needsSort
            )
        } else {
            // Unknown plan type
            return QueryCost.unknown
        }
    }

    // MARK: - Full Scan Cost

    private func estimateFullScanCost<Record: Sendable>(
        _ plan: TypedFullScanPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?,
        needsSort: Bool
    ) async throws -> QueryCost {
        guard let tableStats = tableStats, tableStats.rowCount > 0 else {
            return QueryCost.defaultFullScan
        }

        var estimatedRows = Double(tableStats.rowCount)

        // Apply filter selectivity if present
        if let filter = plan.filter {
            let selectivity = try await statisticsManager.estimateSelectivity(
                filter: filter,
                recordType: recordType
            )
            // Ensure selectivity is in valid range
            let validSelectivity = max(Double.epsilon, min(1.0, selectivity))
            estimatedRows *= validSelectivity
        }

        // Full scan reads all rows
        let ioCost = Double(tableStats.rowCount) * ioReadCost

        // CPU cost: deserialize + filter evaluation
        let cpuCost = Double(tableStats.rowCount) * (cpuDeserializeCost + cpuFilterCost)

        return QueryCost(
            ioCost: ioCost,
            cpuCost: cpuCost,
            estimatedRows: max(Int64(estimatedRows), QueryCost.minEstimatedRows),
            needsSort: needsSort
        )
    }

    // MARK: - Index Scan Cost

    private func estimateIndexScanCost<Record: Sendable>(
        _ plan: TypedIndexScanPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?,
        needsSort: Bool
    ) async throws -> QueryCost {
        guard let tableStats = tableStats, tableStats.rowCount > 0 else {
            return QueryCost.defaultIndexScan
        }

        // Get index statistics
        let indexStats = try? await statisticsManager.getIndexStatistics(
            indexName: plan.indexName
        )

        // Estimate selectivity based on index range
        var selectivity = estimateIndexRangeSelectivity(
            beginValues: plan.beginValues,
            endValues: plan.endValues,
            indexStats: indexStats,
            tableStats: tableStats
        )

        // Apply additional filter selectivity if present
        if let filter = plan.filter {
            let filterSelectivity = try await statisticsManager.estimateSelectivity(
                filter: filter,
                recordType: recordType
            )
            selectivity *= max(Double.epsilon, min(1.0, filterSelectivity))
        }

        let estimatedRows = Double(tableStats.rowCount) * selectivity

        // I/O cost: index scan + record lookups
        let indexIoCost = estimatedRows * ioReadCost
        let recordIoCost = estimatedRows * ioReadCost
        let totalIoCost = indexIoCost + recordIoCost

        // CPU cost: deserialize + filter
        let cpuCost = estimatedRows * (cpuDeserializeCost + cpuFilterCost)

        return QueryCost(
            ioCost: totalIoCost,
            cpuCost: cpuCost,
            estimatedRows: max(Int64(estimatedRows), QueryCost.minEstimatedRows),
            needsSort: needsSort
        )
    }

    /// Estimate selectivity of an index range
    private func estimateIndexRangeSelectivity(
        beginValues: [any TupleElement],
        endValues: [any TupleElement],
        indexStats: IndexStatistics?,
        tableStats: TableStatistics
    ) -> Double {
        // If we have index statistics with histogram, use it
        if let indexStats = indexStats,
           let histogram = indexStats.histogram,
           !beginValues.isEmpty || !endValues.isEmpty {

            // For simplicity, use first value
            if !beginValues.isEmpty && !endValues.isEmpty {
                let beginValue = ComparableValue(beginValues[0])
                let endValue = ComparableValue(endValues[0])

                // Estimate range selectivity
                if beginValue == endValue {
                    // Equality
                    return histogram.estimateSelectivity(
                        comparison: .equals,
                        value: beginValue
                    )
                } else {
                    // Range query - use histogram's direct range estimation
                    return histogram.estimateRangeSelectivity(
                        min: beginValue,
                        max: endValue,
                        minInclusive: true,
                        maxInclusive: false
                    )
                }
            }
        }

        // No statistics or empty range: use heuristic
        if beginValues.isEmpty && endValues.isEmpty {
            return 1.0  // Full range
        } else if beginValues.isEmpty || endValues.isEmpty {
            return 0.5  // Half range
        } else {
            return 0.1  // Selective range
        }
    }

    // MARK: - Intersection Cost

    private func estimateIntersectionCost<Record: Sendable>(
        _ plan: TypedIntersectionPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?,
        needsSort: Bool
    ) async throws -> QueryCost {
        guard let tableStats = tableStats, tableStats.rowCount > 0 else {
            return QueryCost.defaultIntersection
        }

        // Estimate cost of each child (children don't need sort themselves)
        var childCosts: [QueryCost] = []
        for child in plan.childPlans {
            let cost = try await estimatePlanCost(
                child,
                recordType: recordType,
                tableStats: tableStats,
                needsSort: false  // Child plans don't need sorting
            )
            childCosts.append(cost)
        }

        // Sort children by estimated rows (smallest first)
        childCosts.sort { $0.estimatedRows < $1.estimatedRows }

        // Intersection I/O cost: sum of all child I/O
        let totalIoCost = childCosts.reduce(0.0) { $0 + $1.ioCost }

        // Result selectivity: product of individual selectivities (independence assumption)
        let totalSelectivity = childCosts.reduce(1.0) { result, cost in
            guard tableStats.rowCount > 0 else { return result }
            let selectivity = Double(cost.estimatedRows).safeDivide(
                by: Double(tableStats.rowCount),
                default: 1.0
            )
            return result * max(Double.epsilon, selectivity)
        }

        let estimatedRows = Double(tableStats.rowCount) * totalSelectivity

        // CPU cost: intersection processing (proportional to smallest child)
        let smallestChildRows = childCosts.first?.estimatedRows ?? 0
        let cpuCost = Double(smallestChildRows) * cpuFilterCost * Double(plan.childPlans.count)

        return QueryCost(
            ioCost: totalIoCost,
            cpuCost: cpuCost,
            estimatedRows: max(Int64(estimatedRows), QueryCost.minEstimatedRows),
            needsSort: needsSort  // Intersection result might need sorting
        )
    }

    // MARK: - Union Cost

    private func estimateUnionCost<Record: Sendable>(
        _ plan: TypedUnionPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?,
        needsSort: Bool
    ) async throws -> QueryCost {
        // Union cost: sum of all children (with potential overlap)
        var totalIoCost = 0.0
        var totalCpuCost = 0.0
        var totalRows: Int64 = 0

        for child in plan.childPlans {
            let cost = try await estimatePlanCost(
                child,
                recordType: recordType,
                tableStats: tableStats,
                needsSort: false  // Child plans don't need sorting
            )
            totalIoCost += cost.ioCost
            totalCpuCost += cost.cpuCost
            totalRows += cost.estimatedRows
        }

        // Account for potential duplicates (reduce by 10%)
        let deduplicationFactor = 0.9
        let adjustedRows = Int64(Double(totalRows) * deduplicationFactor)

        return QueryCost(
            ioCost: totalIoCost,
            cpuCost: totalCpuCost,
            estimatedRows: max(adjustedRows, QueryCost.minEstimatedRows),
            needsSort: needsSort  // Union result might need sorting
        )
    }

    // MARK: - Limit Cost

    private func estimateLimitCost<Record: Sendable>(
        _ plan: TypedLimitPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?,
        needsSort: Bool
    ) async throws -> QueryCost {
        let childCost = try await estimatePlanCost(
            plan.child,
            recordType: recordType,
            tableStats: tableStats,
            needsSort: needsSort  // Pass through sort requirement to child
        )

        // Guard against zero rows
        guard childCost.estimatedRows > 0 else {
            return QueryCost(ioCost: 0, cpuCost: 0, estimatedRows: 0, needsSort: needsSort)
        }

        // Limit reduces cost proportionally
        let limitFactor = min(
            1.0,
            Double(plan.limit).safeDivide(
                by: Double(childCost.estimatedRows),
                default: 1.0
            )
        )

        return QueryCost(
            ioCost: childCost.ioCost * limitFactor,
            cpuCost: childCost.cpuCost * limitFactor,
            estimatedRows: min(Int64(plan.limit), childCost.estimatedRows),
            needsSort: needsSort  // Limit doesn't change sort requirement
        )
    }
}

// MARK: - Query Cost

/// Represents the estimated cost of a query execution plan
public struct QueryCost: Sendable, Comparable {
    /// I/O cost (number of key-value reads)
    public let ioCost: Double

    /// CPU cost (processing overhead)
    public let cpuCost: Double

    /// Estimated number of result rows
    public let estimatedRows: Int64

    /// Whether this plan requires in-memory sorting
    public let needsSort: Bool

    /// Total cost (weighted sum, I/O dominates)
    ///
    /// Includes sort cost when needsSort is true.
    /// Sort cost is O(n log n) where n is estimatedRows.
    public var totalCost: Double {
        var cost = ioCost + cpuCost * 0.1

        if needsSort {
            // O(n log n) sort cost with coefficient
            // Use max(1.0) to avoid log(0)
            let n = Double(estimatedRows)
            let sortCost = n * log2(max(n, 1.0)) * 0.01
            cost += sortCost
        }

        return cost
    }

    public init(ioCost: Double, cpuCost: Double, estimatedRows: Int64, needsSort: Bool = false) {
        self.ioCost = max(0, ioCost)
        self.cpuCost = max(0, cpuCost)
        self.estimatedRows = max(estimatedRows, Self.minEstimatedRows)
        self.needsSort = needsSort
    }

    // MARK: - Comparable

    public static func < (lhs: QueryCost, rhs: QueryCost) -> Bool {
        return lhs.totalCost < rhs.totalCost
    }

    // MARK: - Default Costs

    /// Minimum estimated rows to avoid zero
    public static let minEstimatedRows: Int64 = 1

    /// Default cost for unknown plan types
    public static let unknown = QueryCost(
        ioCost: 1_000_000,
        cpuCost: 100_000,
        estimatedRows: 1_000_000
    )

    /// Default cost for full scan (no statistics)
    public static let defaultFullScan = QueryCost(
        ioCost: 1_000_000,
        cpuCost: 100_000,
        estimatedRows: 1_000_000
    )

    /// Default cost for index scan (no statistics)
    public static let defaultIndexScan = QueryCost(
        ioCost: 10_000,
        cpuCost: 1_000,
        estimatedRows: 10_000
    )

    /// Default cost for intersection (no statistics)
    public static let defaultIntersection = QueryCost(
        ioCost: 5_000,
        cpuCost: 500,
        estimatedRows: 1_000
    )

    /// Default cost for union (no statistics)
    public static let defaultUnion = QueryCost(
        ioCost: 20_000,
        cpuCost: 2_000,
        estimatedRows: 20_000
    )
}
