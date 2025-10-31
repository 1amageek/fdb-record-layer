import Foundation

/// Production-ready type-safe query planner with cost-based optimization
///
/// This planner uses statistics, cost estimation, query rewriting, and plan caching
/// to generate efficient execution plans for queries.
public struct TypedRecordQueryPlannerV2<Record: Sendable> {
    public let recordType: TypedRecordType<Record>
    public let indexes: [TypedIndex<Record>]
    public let statisticsManager: StatisticsManager
    public let planCache: PlanCache<Record>

    // Configuration
    private let rewriterConfig: QueryRewriter<Record>.Config
    private let maxCandidatePlans: Int

    public init(
        recordType: TypedRecordType<Record>,
        indexes: [TypedIndex<Record>],
        statisticsManager: StatisticsManager,
        planCache: PlanCache<Record>? = nil,
        rewriterConfig: QueryRewriter<Record>.Config = .default,
        maxCandidatePlans: Int = 20
    ) {
        self.recordType = recordType
        self.indexes = indexes
        self.statisticsManager = statisticsManager
        self.planCache = planCache ?? PlanCache<Record>()
        self.rewriterConfig = rewriterConfig
        self.maxCandidatePlans = maxCandidatePlans
    }

    // MARK: - Public API

    /// Generate an optimized execution plan for a query
    ///
    /// - Parameter query: The query to plan
    /// - Returns: The optimized execution plan
    public func plan(_ query: TypedRecordQuery<Record>) async throws -> any TypedQueryPlan<Record> {
        // Step 1: Check plan cache
        if let cached = await planCache.get(query: query) {
            return cached
        }

        // Step 2: Rewrite query
        let rewriter = QueryRewriter<Record>(config: rewriterConfig)
        let rewrittenFilter = query.filter.map { rewriter.rewrite($0) }

        // Step 3: Generate candidate plans
        let candidatePlans = try await generateCandidatePlans(
            filter: rewrittenFilter,
            limit: query.limit
        )

        // Step 4: Estimate cost for each plan
        let costEstimator = CostEstimator(statisticsManager: statisticsManager)
        var planCosts: [(plan: any TypedQueryPlan<Record>, cost: QueryCost)] = []

        for plan in candidatePlans {
            let cost = try await costEstimator.estimateCost(
                plan,
                recordType: recordType.name
            )
            planCosts.append((plan, cost))
        }

        // Step 5: Select best plan
        guard let best = planCosts.min(by: { $0.cost < $1.cost }) else {
            // Fallback: full scan
            return TypedFullScanPlan(filter: rewrittenFilter)
        }

        // Step 6: Cache the plan
        await planCache.put(query: query, plan: best.plan, cost: best.cost)

        return best.plan
    }

    // MARK: - Plan Generation

    /// Generate all candidate execution plans
    private func generateCandidatePlans(
        filter: (any TypedQueryComponent<Record>)?,
        limit: Int?
    ) async throws -> [any TypedQueryPlan<Record>] {
        var plans: [any TypedQueryPlan<Record>] = []

        // Plan 1: Full scan (fallback)
        let fullScanPlan = TypedFullScanPlan(filter: filter)
        plans.append(fullScanPlan)

        guard let filter = filter else {
            return applyLimit(plans, limit: limit)
        }

        // Plan 2: Single index scans
        plans.append(contentsOf: generateIndexScans(filter: filter))

        // Plan 3: Intersection plans (for AND conditions)
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            if let intersectionPlan = try generateIntersectionPlan(andFilter: andFilter) {
                plans.append(intersectionPlan)
            }
        }

        // Plan 4: Union plans (for OR conditions in DNF)
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            if let unionPlan = try generateUnionPlan(orFilter: orFilter) {
                plans.append(unionPlan)
            }
        }

        // Limit number of candidates
        if plans.count > maxCandidatePlans {
            plans = Array(plans.prefix(maxCandidatePlans))
        }

        return applyLimit(plans, limit: limit)
    }

    /// Apply limit to all plans
    private func applyLimit(
        _ plans: [any TypedQueryPlan<Record>],
        limit: Int?
    ) -> [any TypedQueryPlan<Record>] {
        guard let limit = limit else {
            return plans
        }

        return plans.map { plan in
            TypedLimitPlan(child: plan, limit: limit)
        }
    }

    // MARK: - Index Scan Generation

    /// Generate index scan plans
    private func generateIndexScans(
        filter: any TypedQueryComponent<Record>
    ) -> [any TypedQueryPlan<Record>] {
        var plans: [any TypedQueryPlan<Record>] = []

        // Try each index with the filter
        for index in indexes where index.type == .value {
            if let plan = generateIndexScan(filter: filter, index: index) {
                plans.append(plan)
            }
        }

        // For AND conditions, try each child separately
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            for child in andFilter.children {
                for index in indexes where index.type == .value {
                    if let plan = generateIndexScan(filter: child, index: index) {
                        plans.append(plan)
                    }
                }
            }
        }

        return plans
    }

    /// Generate a single index scan plan
    private func generateIndexScan(
        filter: any TypedQueryComponent<Record>,
        index: TypedIndex<Record>
    ) -> (any TypedQueryPlan<Record>)? {
        // Check if filter matches index
        guard let fieldFilter = filter as? TypedFieldQueryComponent<Record>,
              let fieldExpr = index.rootExpression as? TypedFieldKeyExpression<Record>,
              fieldExpr.fieldName == fieldFilter.fieldName else {
            return nil
        }

        // Build index range
        let (beginValues, endValues) = buildIndexRange(fieldFilter: fieldFilter)

        return TypedIndexScanPlan(
            index: index,
            beginValues: beginValues,
            endValues: endValues,
            filter: filter,
            primaryKeyLength: recordType.primaryKey.columnCount
        )
    }

    /// Build index scan range from a field filter
    private func buildIndexRange(
        fieldFilter: TypedFieldQueryComponent<Record>
    ) -> (beginValues: [any TupleElement], endValues: [any TupleElement]) {
        let value = fieldFilter.value

        switch fieldFilter.comparison {
        case .equals:
            return ([value], [value])

        case .lessThan:
            return ([], [value])

        case .lessThanOrEquals:
            if let strValue = value as? String {
                return ([], [strValue + "\u{FFFF}"])
            }
            return ([], [value])

        case .greaterThan:
            if let strValue = value as? String {
                return ([strValue + "\u{FFFF}"], ["\u{FFFF}"])
            } else if let intValue = value as? Int64 {
                return ([intValue + 1], [Int64.max])
            }
            return ([value], [Int64.max])

        case .greaterThanOrEquals:
            return ([value], [Int64.max])

        case .startsWith:
            if let strValue = value as? String {
                return ([strValue], [strValue + "\u{FFFF}"])
            }
            return ([], [Int64.max])

        case .notEquals, .contains:
            return ([], [Int64.max])
        }
    }

    // MARK: - Intersection Plan Generation

    /// Generate intersection plan for AND conditions
    private func generateIntersectionPlan(
        andFilter: TypedAndQueryComponent<Record>
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Find index scans for each child
        var childPlans: [any TypedQueryPlan<Record>] = []

        for child in andFilter.children {
            for index in indexes where index.type == .value {
                if let plan = generateIndexScan(filter: child, index: index) {
                    childPlans.append(plan)
                    break // Use first matching index
                }
            }
        }

        // Need at least 2 index scans for intersection
        guard childPlans.count >= 2 else {
            return nil
        }

        return TypedIntersectionPlan(
            children: childPlans,
            comparisonKey: recordType.fieldNames
        )
    }

    // MARK: - Union Plan Generation

    /// Generate union plan for OR conditions
    private func generateUnionPlan(
        orFilter: TypedOrQueryComponent<Record>
    ) throws -> (any TypedQueryPlan<Record>)? {
        var childPlans: [any TypedQueryPlan<Record>] = []

        for child in orFilter.children {
            // Try to find index scan for each OR term
            var foundPlan: (any TypedQueryPlan<Record>)? = nil

            for index in indexes where index.type == .value {
                if let plan = generateIndexScan(filter: child, index: index) {
                    foundPlan = plan
                    break
                }
            }

            // Fallback to full scan if no index
            childPlans.append(foundPlan ?? TypedFullScanPlan(filter: child))
        }

        return TypedUnionPlan(children: childPlans)
    }

    // MARK: - Plan Cache Management

    /// Get plan cache statistics
    public func getCacheStats() async -> CacheStats {
        return await planCache.getStats()
    }

    /// Clear plan cache
    public func clearCache() async {
        await planCache.clear()
    }
}

// MARK: - TypedRecordType Extensions

extension TypedRecordType {
    /// Get primary key field names by extracting from key expression
    var fieldNames: [String] {
        return extractFieldNames(from: primaryKey)
    }

    /// Recursively extract field names from a key expression
    private func extractFieldNames(from expression: any TypedKeyExpression<Record>) -> [String] {
        // Try to cast to known expression types
        if let fieldExpr = expression as? TypedFieldKeyExpression<Record> {
            return [fieldExpr.fieldName]
        } else if let concatExpr = expression as? TypedConcatenateKeyExpression<Record> {
            return concatExpr.children.flatMap { extractFieldNames(from: $0) }
        } else {
            // For literal or empty expressions, return empty array
            // These don't contribute field names
            return []
        }
    }
}
