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
    /// - Returns: Estimated query cost
    public func estimateCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        // Fetch statistics once at the top level (async-safe pattern)
        let tableStats = try? await statisticsManager.getTableStatistics(
            recordType: recordType
        )

        return try await estimatePlanCost(
            plan,
            recordType: recordType,
            tableStats: tableStats
        )
    }

    // MARK: - Plan Cost Estimation

    /// Internal estimation with pre-fetched statistics
    private func estimatePlanCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?
    ) async throws -> QueryCost {
        if let scanPlan = plan as? TypedFullScanPlan<Record> {
            return try await estimateFullScanCost(
                scanPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else if let indexPlan = plan as? TypedIndexScanPlan<Record> {
            return try await estimateIndexScanCost(
                indexPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else if let intersectionPlan = plan as? TypedIntersectionPlan<Record> {
            return try await estimateIntersectionCost(
                intersectionPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else if let unionPlan = plan as? TypedUnionPlan<Record> {
            return try await estimateUnionCost(
                unionPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else if let limitPlan = plan as? TypedLimitPlan<Record> {
            return try await estimateLimitCost(
                limitPlan,
                recordType: recordType,
                tableStats: tableStats
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
        tableStats: TableStatistics?
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
            estimatedRows: max(Int64(estimatedRows), QueryCost.minEstimatedRows)
        )
    }

    // MARK: - Index Scan Cost

    private func estimateIndexScanCost<Record: Sendable>(
        _ plan: TypedIndexScanPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?
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
            estimatedRows: max(Int64(estimatedRows), QueryCost.minEstimatedRows)
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
        tableStats: TableStatistics?
    ) async throws -> QueryCost {
        guard let tableStats = tableStats, tableStats.rowCount > 0 else {
            return QueryCost.defaultIntersection
        }

        // Estimate cost of each child
        var childCosts: [QueryCost] = []
        for child in plan.childPlans {
            let cost = try await estimatePlanCost(
                child,
                recordType: recordType,
                tableStats: tableStats
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
            estimatedRows: max(Int64(estimatedRows), QueryCost.minEstimatedRows)
        )
    }

    // MARK: - Union Cost

    private func estimateUnionCost<Record: Sendable>(
        _ plan: TypedUnionPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?
    ) async throws -> QueryCost {
        // Union cost: sum of all children (with potential overlap)
        var totalIoCost = 0.0
        var totalCpuCost = 0.0
        var totalRows: Int64 = 0

        for child in plan.childPlans {
            let cost = try await estimatePlanCost(
                child,
                recordType: recordType,
                tableStats: tableStats
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
            estimatedRows: max(adjustedRows, QueryCost.minEstimatedRows)
        )
    }

    // MARK: - Limit Cost

    private func estimateLimitCost<Record: Sendable>(
        _ plan: TypedLimitPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?
    ) async throws -> QueryCost {
        let childCost = try await estimatePlanCost(
            plan.child,
            recordType: recordType,
            tableStats: tableStats
        )

        // Guard against zero rows
        guard childCost.estimatedRows > 0 else {
            return QueryCost(ioCost: 0, cpuCost: 0, estimatedRows: 0)
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
            estimatedRows: min(Int64(plan.limit), childCost.estimatedRows)
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

    /// Total cost (weighted sum, I/O dominates)
    public var totalCost: Double {
        return ioCost + cpuCost * 0.1
    }

    public init(ioCost: Double, cpuCost: Double, estimatedRows: Int64) {
        self.ioCost = max(0, ioCost)
        self.cpuCost = max(0, cpuCost)
        self.estimatedRows = max(estimatedRows, Self.minEstimatedRows)
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
