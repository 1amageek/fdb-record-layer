import Foundation
import FoundationDB
import Logging

/// Enhanced query planner with cost-based optimization
///
/// TypedRecordQueryPlanner is the next-generation query planner that uses
/// cost-based optimization to select the best execution plan. It generates
/// multiple candidate plans and selects the one with minimum estimated cost.
///
/// **Key Features:**
/// - Cost-based plan selection using statistics
/// - Multiple candidate plan generation with budget control
/// - Heuristic fallback when statistics unavailable
/// - Plan caching for repeated queries
/// - Sort-aware index selection
/// - AND/OR query optimization
///
/// **Usage:**
/// ```swift
/// let planner = TypedRecordQueryPlanner(
///     schema: schema,
///     recordName: "User",
///     statisticsManager: statsManager
/// )
///
/// let query = TypedRecordQuery<User>(filter: \.email == "test@example.com", limit: 10)
/// let plan = try await planner.plan(query: query)
/// ```
public struct TypedRecordQueryPlanner<Record: Recordable> {
    // MARK: - Properties

    private let schema: Schema
    private let recordName: String
    private let statisticsManager: any StatisticsManagerProtocol
    private let costEstimator: CostEstimator
    private let planCache: PlanCache<Record>
    private let config: PlanGenerationConfig
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize query planner with cost-based optimization
    ///
    /// - Parameters:
    ///   - schema: Schema containing entity and index definitions
    ///   - recordName: The record type being queried
    ///   - statisticsManager: Statistics manager for cost estimation
    ///   - planCache: Optional plan cache (creates default if nil)
    ///   - config: Plan generation configuration (default: .default)
    ///   - logger: Optional logger (creates default if nil)
    public init(
        schema: Schema,
        recordName: String,
        statisticsManager: any StatisticsManagerProtocol,
        planCache: PlanCache<Record>? = nil,
        config: PlanGenerationConfig = .default,
        logger: Logger? = nil
    ) {
        self.schema = schema
        self.recordName = recordName
        self.statisticsManager = statisticsManager
        self.costEstimator = CostEstimator(statisticsManager: statisticsManager)
        self.planCache = planCache ?? PlanCache<Record>()
        self.config = config
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.planner")
    }

    // MARK: - Public API

    /// Plan query execution with cost-based optimization
    ///
    /// This is the main entry point for query planning. It:
    /// 1. Checks plan cache
    /// 2. Checks metadata version (invalidates cache if changed)
    /// 3. Tries cost-based optimization with statistics
    /// 4. Falls back to heuristics if no statistics
    /// 5. Caches the result
    ///
    /// - Parameter query: The typed query to plan
    /// - Returns: The optimal execution plan
    /// - Throws: RecordLayerError if planning fails
    public func plan(query: TypedRecordQuery<Record>) async throws -> any TypedQueryPlan<Record> {
        // DEBUG: Log available indexes for this record type
        let applicableIndexes = schema.indexes(for: recordName)
        logger.debug("Available indexes for record type", metadata: [
            "recordType": "\(recordName)",
            "indexCount": "\(applicableIndexes.count)",
            "indexes": "\(applicableIndexes.map { "\($0.name):\(type(of: $0.rootExpression))" }.joined(separator: ", "))"
        ])

        // Check cache (synchronous access with Mutex)
        if let cachedPlan = planCache.get(query: query) {
            logger.debug("Plan cache hit", metadata: [
                "recordType": "\(recordName)"
            ])
            return cachedPlan
        }

        logger.debug("Plan cache miss, generating new plan", metadata: [
            "recordType": "\(recordName)"
        ])

        // Fetch table statistics
        let tableStats = try? await statisticsManager.getTableStatistics(recordType: recordName)

        var basePlan: any TypedQueryPlan<Record>

        if let tableStats = tableStats, tableStats.rowCount > 0 {
            // Path 1: Cost-based optimization with statistics
            logger.debug("Using cost-based optimization (statistics available)")
            basePlan = try await planWithStatistics(query, tableStats: tableStats)
        } else {
            // Path 2: Heuristic-based optimization without statistics
            logger.info("Using heuristic optimization (no statistics)", metadata: [
                "recordType": "\(recordName)",
                "recommendation": "Run: StatisticsManager.collectStatistics(recordType: \"\(recordName)\")"
            ])
            basePlan = try await planWithHeuristics(query)
        }

        // Add sort plan if needed
        let finalPlan = try addSortIfNeeded(plan: basePlan, query: query)

        // Estimate cost for caching
        let cost = try await costEstimator.estimateCost(finalPlan, recordType: recordName)

        // Cache result (synchronous access with Mutex)
        planCache.put(query: query, plan: finalPlan, cost: cost)

        logger.debug("Plan generated and cached", metadata: [
            "estimatedRows": "\(cost.estimatedRows)",
            "totalCost": "\(cost.totalCost)"
        ])

        return finalPlan
    }

    // MARK: - Cost-Based Planning

    /// Plan query with statistics-based cost estimation
    ///
    /// Generates multiple candidate plans and selects the one with minimum cost.
    ///
    /// - Parameters:
    ///   - query: The query to plan
    ///   - tableStats: Table statistics for cost estimation
    /// - Returns: The optimal plan
    /// - Throws: RecordLayerError if planning fails
    private func planWithStatistics(
        _ query: TypedRecordQuery<Record>,
        tableStats: TableStatistics
    ) async throws -> any TypedQueryPlan<Record> {
        // Generate candidate plans with budget control
        let candidates = try await generateCandidatePlans(query, tableStats: tableStats)

        logger.debug("Generated candidate plans", metadata: [
            "count": "\(candidates.count)"
        ])

        // Estimate costs for each candidate (including sort cost if applicable)
        var costsWithPlans: [(plan: any TypedQueryPlan<Record>, cost: QueryCost)] = []

        for plan in candidates {
            let cost = try await costEstimator.estimateCost(
                plan,
                recordType: recordName,
                sortKeys: query.sort,
                schema: schema
            )
            costsWithPlans.append((plan, cost))

            logger.trace("Candidate plan cost", metadata: [
                "planType": "\(type(of: plan))",
                "estimatedRows": "\(cost.estimatedRows)",
                "totalCost": "\(cost.totalCost)",
                "needsSort": "\(cost.needsSort)"
            ])
        }

        // Select plan with minimum cost
        guard let optimal = costsWithPlans.min(by: { $0.cost < $1.cost }) else {
            throw RecordLayerError.internalError("No candidate plans generated")
        }

        logger.debug("Selected optimal plan", metadata: [
            "planType": "\(type(of: optimal.plan))",
            "estimatedRows": "\(optimal.cost.estimatedRows)",
            "totalCost": "\(optimal.cost.totalCost)"
        ])

        return optimal.plan
    }

    /// Plan query with heuristics (no statistics available)
    ///
    /// Uses simple heuristics to select a plan:
    /// 1. Unique index on equality → guaranteed optimal
    /// 2. Any matching index → likely better than full scan
    /// 3. Fall back to full scan
    ///
    /// - Parameter query: The query to plan
    /// - Returns: A reasonable plan
    /// - Throws: RecordLayerError if planning fails
    private func planWithHeuristics(
        _ query: TypedRecordQuery<Record>
    ) async throws -> any TypedQueryPlan<Record> {
        // Rule 1: Unique index on equality → guaranteed optimal
        if let uniquePlan = try findUniqueIndexPlan(query.filter) {
            logger.debug("Selected unique index plan (heuristic)", metadata: [
                "planType": "TypedIndexScanPlan"
            ])
            return uniquePlan
        }

        // Rule 2: IN predicate → use InJoinPlan
        if let filter = query.filter {
            let inJoinPlans = try await generateInJoinPlansWithExtractor(
                filter: filter,
                tableStats: nil
            )
            if let firstInJoinPlan = inJoinPlans.first {
                logger.debug("Selected IN join plan (heuristic)", metadata: [
                    "planType": "TypedInJoinPlan"
                ])
                return firstInJoinPlan
            }
        }

        // Rule 3: AND filter → try intersection plan
        if let andFilter = query.filter as? TypedAndQueryComponent<Record> {
            if let intersectionPlan = try await generateIntersectionPlan(andFilter) {
                logger.debug("Selected intersection plan (heuristic)", metadata: [
                    "planType": "TypedIntersectionPlan"
                ])
                return intersectionPlan
            }
        }

        // Rule 4: Any index match → likely better than full scan
        if let indexPlan = try findFirstIndexPlan(query.filter) {
            logger.debug("Selected first matching index plan (heuristic)", metadata: [
                "planType": "TypedIndexScanPlan"
            ])
            return indexPlan
        }

        // Rule 5: Fall back to full scan
        logger.debug("Selected full scan plan (heuristic fallback)", metadata: [
            "planType": "TypedFullScanPlan"
        ])

        return TypedFullScanPlan(
            filter: query.filter,
            expectedRecordType: recordName
        )
    }

    // MARK: - Candidate Plan Generation

    /// Generate candidate plans with budget control
    ///
    /// Generates multiple execution plans up to the configured limit:
    /// - Full scan (baseline)
    /// - Single-index plans (sorted by estimated selectivity)
    /// - Multi-index plans (intersection/union)
    ///
    /// - Parameters:
    ///   - query: The query to plan
    ///   - tableStats: Table statistics
    /// - Returns: Array of candidate plans
    /// - Throws: RecordLayerError if generation fails
    private func generateCandidatePlans(
        _ query: TypedRecordQuery<Record>,
        tableStats: TableStatistics
    ) async throws -> [any TypedQueryPlan<Record>] {
        var candidates: [any TypedQueryPlan<Record>] = []

        // Always add full scan (baseline)
        candidates.append(TypedFullScanPlan(
            filter: query.filter,
            expectedRecordType: recordName
        ))

        // Heuristic pruning: if unique index on equality, skip others
        if config.enableHeuristicPruning,
           let uniquePlan = try findUniqueIndexPlan(query.filter) {
            logger.debug("Short-circuit: unique index on equality found")
            return [uniquePlan]
        }

        // Generate single-index plans
        var indexPlans = try await generateSingleIndexPlans(query, tableStats: tableStats)

        // CRITICAL FIX: Use tableStats to prioritize most selective indexes
        // Sort index plans by estimated selectivity (lower = more selective = better)
        if let filter = query.filter {
            indexPlans = try await sortPlansBySelectivity(
                plans: indexPlans,
                filter: filter,
                tableStats: tableStats
            )

            logger.debug("Sorted index plans by selectivity", metadata: [
                "count": "\(indexPlans.count)"
            ])
        }

        // Add index plans (respecting budget)
        for plan in indexPlans.prefix(config.maxCandidatePlans - 1) {
            candidates.append(plan)

            if candidates.count >= config.maxCandidatePlans {
                logger.debug("Candidate plan budget reached", metadata: [
                    "count": "\(candidates.count)"
                ])
                break
            }
        }

        // Generate multi-index plans (intersection/union) if budget allows
        // Only generate if we have budget and stats suggest benefit
        if candidates.count < config.maxCandidatePlans {
            // Check if multi-index plans are worth it based on table size
            let shouldGenerateMultiIndex = tableStats.rowCount > 1000 || candidates.count < 3

            if shouldGenerateMultiIndex {
                let multiIndexPlans = try await generateMultiIndexPlans(query)

                for plan in multiIndexPlans {
                    candidates.append(plan)

                    if candidates.count >= config.maxCandidatePlans {
                        logger.debug("Candidate plan budget reached (with multi-index plans)", metadata: [
                            "count": "\(candidates.count)"
                        ])
                        break
                    }
                }
            }
        }

        return candidates
    }

    /// Sort query plans by estimated selectivity using statistics
    ///
    /// - Parameters:
    ///   - plans: Plans to sort
    ///   - filter: Query filter for selectivity estimation
    ///   - tableStats: Table statistics for estimation
    /// - Returns: Sorted plans (most selective first)
    private func sortPlansBySelectivity(
        plans: [any TypedQueryPlan<Record>],
        filter: any TypedQueryComponent<Record>,
        tableStats: TableStatistics
    ) async throws -> [any TypedQueryPlan<Record>] {
        // Estimate selectivity for each plan
        var planSelectivities: [(plan: any TypedQueryPlan<Record>, selectivity: Double)] = []

        for plan in plans {
            let selectivity: Double

            // Extract index name from plan (if it's an index scan)
            if let _ = plan as? TypedIndexScanPlan<Record> {
                // Use statistics to estimate selectivity
                selectivity = try await statisticsManager.estimateSelectivity(
                    filter: filter,
                    recordType: recordName
                )
            } else {
                // For other plan types, use default selectivity
                selectivity = 1.0 // Full scan = 100% selectivity
            }

            planSelectivities.append((plan: plan, selectivity: selectivity))
        }

        // Sort by selectivity (lower = more selective = better)
        planSelectivities.sort { $0.selectivity < $1.selectivity }

        logger.debug("Plan selectivities", metadata: [
            "selectivities": "\(planSelectivities.map { $0.selectivity })"
        ])

        return planSelectivities.map { $0.plan }
    }

    /// Generate single-index scan plans for all applicable indexes
    ///
    /// - Parameters:
    ///   - query: The query to plan
    ///   - tableStats: Optional table statistics for cost-based optimization
    /// - Returns: Array of index scan plans
    /// - Throws: RecordLayerError if generation fails
    private func generateSingleIndexPlans(
        _ query: TypedRecordQuery<Record>,
        tableStats: TableStatistics? = nil
    ) async throws -> [any TypedQueryPlan<Record>] {
        guard let filter = query.filter else {
            return []
        }

        var indexPlans: [any TypedQueryPlan<Record>] = []

        // Generate IN join plans using InExtractor (handles both top-level and nested)
        let extractedInPlans = try await generateInJoinPlansWithExtractor(
            filter: filter,
            tableStats: tableStats
        )
        indexPlans.append(contentsOf: extractedInPlans)

        let applicableIndexes = schema.indexes(for: recordName)

        for index in applicableIndexes {
            if let matchResult = try matchFilterWithIndex(filter: filter, index: index) {
                // Wrap with TypedFilterPlan if there are remaining predicates
                let finalPlan: any TypedQueryPlan<Record>
                if let remainingFilter = matchResult.remainingFilter {
                    finalPlan = TypedFilterPlan(
                        child: matchResult.plan,
                        filter: remainingFilter
                    )
                } else {
                    finalPlan = matchResult.plan
                }
                indexPlans.append(finalPlan)
            }
        }

        return indexPlans
    }

    /// Generate multi-index plans (intersection/union)
    ///
    /// Uses DNF conversion to normalize queries and generate plans
    /// that combine multiple indexes.
    ///
    /// - Parameter query: The query to plan
    /// - Returns: Array of multi-index plans
    /// - Throws: RecordLayerError if generation fails
    private func generateMultiIndexPlans(
        _ query: TypedRecordQuery<Record>
    ) async throws -> [any TypedQueryPlan<Record>] {
        guard let filter = query.filter else {
            return []
        }

        var multiIndexPlans: [any TypedQueryPlan<Record>] = []

        // Convert to DNF: (A AND B) OR (C AND D) OR ...
        let converter = DNFConverter<Record>(maxBranches: config.maxDNFBranches)
        let dnfFilter = try converter.convertToDNF(filter)

        // Check if filter is OR at top level (DNF form)
        if let orFilter = dnfFilter as? TypedOrQueryComponent<Record> {
            // Each OR branch can be optimized separately
            var branchPlans: [any TypedQueryPlan<Record>] = []

            for branch in orFilter.children {
                // Try to generate plan for this branch
                if let branchPlan = try await generatePlanForBranch(branch) {
                    branchPlans.append(branchPlan)
                }
            }

            // If all branches have plans, create union
            if branchPlans.count == orFilter.children.count {
                // Get entity and build primary key expression
                guard let entity = schema.entity(named: recordName) else {
                    logger.warning("Entity not found", metadata: ["recordType": "\(recordName)"])
                    return multiIndexPlans
                }

                // Use canonical primary key expression from entity
                let unionPlan = TypedUnionPlan(childPlans: branchPlans, primaryKeyExpression: entity.primaryKeyExpression)
                multiIndexPlans.append(unionPlan)
            }
        }

        // Check if filter is AND (can use intersection)
        if let andFilter = dnfFilter as? TypedAndQueryComponent<Record> {
            // Try to find multiple indexes for different fields
            if let intersectionPlan = try await generateIntersectionPlan(andFilter) {
                multiIndexPlans.append(intersectionPlan)
            }
        }

        return multiIndexPlans
    }

    /// Generate plan for a single DNF branch (AND clause)
    private func generatePlanForBranch(
        _ branch: any TypedQueryComponent<Record>
    ) async throws -> (any TypedQueryPlan<Record>)? {
        // Try to match with index (may be compound)
        let applicableIndexes = schema.indexes(for: recordName)

        for index in applicableIndexes {
            if let matchResult = try matchFilterWithIndex(filter: branch, index: index) {
                // Wrap with TypedFilterPlan if there are remaining predicates
                if let remainingFilter = matchResult.remainingFilter {
                    return TypedFilterPlan(
                        child: matchResult.plan,
                        filter: remainingFilter
                    )
                } else {
                    return matchResult.plan
                }
            }
        }

        // Try intersection plan if branch is AND
        if let andFilter = branch as? TypedAndQueryComponent<Record> {
            return try await generateIntersectionPlan(andFilter)
        }

        // No plan found
        return nil
    }

    /// Generate intersection plan for AND filter
    ///
    /// Strategy:
    /// 1. First, try to match the entire AND filter with compound indexes
    /// 2. If partial match with simple remaining predicates, return single index + filter plan
    /// 3. Otherwise, fall back to single-field matching and create intersection plan
    private func generateIntersectionPlan(
        _ andFilter: TypedAndQueryComponent<Record>
    ) async throws -> (any TypedQueryPlan<Record>)? {
        let applicableIndexes = schema.indexes(for: recordName)

        // Phase 1: Try to match entire AND filter with compound indexes
        // This maximizes compound index utilization
        for index in applicableIndexes {
            if let matchResult = try matchFilterWithIndex(filter: andFilter, index: index) {
                // Check if we have a partial match with remaining predicates
                if let remainingFilter = matchResult.remainingFilter {
                    // Count how many field filters remain
                    let remainingFieldCount = countFieldFilters(in: remainingFilter)

                    // If only 0-1 field filters remain, use single index + filter plan
                    // This is better than creating an intersection plan
                    if remainingFieldCount < 2 {
                        return TypedFilterPlan(
                            child: matchResult.plan,
                            filter: remainingFilter
                        )
                    }
                    // Otherwise, continue to try other compound indexes or fall back
                } else {
                    // Complete match: return the index plan directly
                    return matchResult.plan
                }
            }
        }

        // Phase 2: Fall back to single-field matching for intersection plan
        // Separate indexable filters from other complex predicates
        var fieldFilters: [TypedFieldQueryComponent<Record>] = []
        var keyExprFilters: [TypedKeyExpressionQueryComponent<Record>] = []
        var nonFieldPredicates: [any TypedQueryComponent<Record>] = []

        // Flatten nested AND conditions to extract all indexable filters
        // This handles cases like overlaps() which generates TypedAnd(children: [lowerBound, upperBound])
        let flattenedChildren = flattenAndFilters(andFilter.children)

        for child in flattenedChildren {
            if let fieldFilter = child as? TypedFieldQueryComponent<Record> {
                fieldFilters.append(fieldFilter)
            } else if let keyExprFilter = child as? TypedKeyExpressionQueryComponent<Record> {
                keyExprFilters.append(keyExprFilter)
            } else {
                // Collect non-field predicates (NOT, OR) for post-filtering
                // Note: Nested AND filters are already flattened above
                nonFieldPredicates.append(child)
            }
        }

        // Collect all indexable filters
        let allIndexableFilters: [any TypedQueryComponent<Record>] = fieldFilters + keyExprFilters

        logger.debug("IntersectionPlan Phase 2", metadata: [
            "fieldFilters": "\(fieldFilters.count)",
            "keyExprFilters": "\(keyExprFilters.count)",
            "allIndexableFilters": "\(allIndexableFilters.count)"
        ])

        // Need at least 2 indexable filters for intersection
        guard allIndexableFilters.count >= 2 else {
            logger.debug("IntersectionPlan: Not enough indexable filters", metadata: [
                "count": "\(allIndexableFilters.count)"
            ])
            return nil
        }

        // Try to find index for each indexable filter
        var childPlans: [any TypedQueryPlan<Record>] = []
        var unmatchedFilters: [any TypedQueryComponent<Record>] = []

        for filter in allIndexableFilters {
            // Find matching index
            var found = false
            for index in applicableIndexes {
                if let matchResult = try matchFilterWithIndex(filter: filter, index: index) {
                    childPlans.append(matchResult.plan)
                    logger.debug("IntersectionPlan: Matched filter with index", metadata: [
                        "indexName": "\(index.name)"
                    ])

                    // If the match has remaining predicates, add them to non-field predicates
                    if let remainingFilter = matchResult.remainingFilter {
                        nonFieldPredicates.append(remainingFilter)
                    }

                    found = true
                    break
                }
            }

            if !found {
                // Cannot find index for this filter, add to unmatched
                logger.debug("IntersectionPlan: No index found for filter", metadata: [
                    "filterType": "\(type(of: filter))"
                ])
                unmatchedFilters.append(filter)
            }
        }

        logger.debug("IntersectionPlan: Matching complete", metadata: [
            "childPlans": "\(childPlans.count)",
            "unmatchedFilters": "\(unmatchedFilters.count)"
        ])

        // Create intersection plan if we have at least 2 indexes
        guard childPlans.count >= 2 else {
            logger.debug("IntersectionPlan: Not enough child plans", metadata: [
                "count": "\(childPlans.count)"
            ])
            return nil
        }

        // Get entity and build primary key expression
        guard let entity = schema.entity(named: recordName) else {
            logger.warning("Entity not found", metadata: ["recordType": "\(recordName)"])
            return nil
        }

        // Use canonical primary key expression from entity
        let intersectionPlan = TypedIntersectionPlan(
            childPlans: childPlans,
            primaryKeyExpression: entity.primaryKeyExpression
        )

        // Combine all remaining predicates (non-field predicates + unmatched filters)
        var allRemainingPredicates: [any TypedQueryComponent<Record>] = nonFieldPredicates
        allRemainingPredicates.append(contentsOf: unmatchedFilters)

        // Wrap with TypedFilterPlan if there are remaining predicates
        if !allRemainingPredicates.isEmpty {
            let remainingFilter: any TypedQueryComponent<Record> = {
                if allRemainingPredicates.count == 1 {
                    return allRemainingPredicates[0]
                } else {
                    return TypedAndQueryComponent(children: allRemainingPredicates)
                }
            }()

            return TypedFilterPlan(
                child: intersectionPlan,
                filter: remainingFilter
            )
        }

        return intersectionPlan
    }

    /// Count the number of indexable filters (field filters + key expression filters) in a query component
    ///
    /// CRITICAL: Must count both TypedFieldQueryComponent AND TypedKeyExpressionQueryComponent
    /// to correctly determine if IntersectionPlan generation is worthwhile.
    ///
    /// **Before**: Only counted TypedFieldQueryComponent
    /// - Problem: Range conditions (TypedKeyExpressionQueryComponent) weren't counted
    /// - Result: "0 remaining filters" when only Range conditions remained
    /// - Consequence: Early return prevented IntersectionPlan generation
    ///
    /// **After**: Counts both types
    /// - Allows IntersectionPlan for pure Range queries (e.g., overlaps())
    private func countFieldFilters(in component: any TypedQueryComponent<Record>) -> Int {
        if component is TypedFieldQueryComponent<Record> {
            return 1
        } else if component is TypedKeyExpressionQueryComponent<Record> {
            // CRITICAL: Count Range filters to enable IntersectionPlan for overlaps() queries
            return 1
        } else if let andComponent = component as? TypedAndQueryComponent<Record> {
            return andComponent.children.reduce(0) { count, child in
                count + countFieldFilters(in: child)
            }
        } else if let orComponent = component as? TypedOrQueryComponent<Record> {
            return orComponent.children.reduce(0) { count, child in
                count + countFieldFilters(in: child)
            }
        } else if let notComponent = component as? TypedNotQueryComponent<Record> {
            return countFieldFilters(in: notComponent.child)
        }
        return 0
    }

    // MARK: - Index Matching

    /// Result of matching a filter with an index
    ///
    /// Contains the generated plan and any remaining predicates that were not satisfied by the index.
    private struct IndexMatchResult {
        let plan: any TypedQueryPlan<Record>
        let remainingFilter: (any TypedQueryComponent<Record>)?
    }

    /// Recursively flatten nested AND filters
    ///
    /// Handles cases like overlaps() which generates:
    /// ```
    /// TypedAnd(children: [
    ///   TypedKeyExpressionQueryComponent(lowerBound < queryEnd),
    ///   TypedKeyExpressionQueryComponent(upperBound > queryBegin)
    /// ])
    /// ```
    ///
    /// This function extracts the inner filters so they can be individually matched with indexes.
    ///
    /// - Parameter children: Array of query components
    /// - Returns: Flattened array where nested AND filters are expanded
    private func flattenAndFilters(_ children: [any TypedQueryComponent<Record>]) -> [any TypedQueryComponent<Record>] {
        var result: [any TypedQueryComponent<Record>] = []

        for child in children {
            if let nestedAnd = child as? TypedAndQueryComponent<Record> {
                // Recursively flatten nested AND filters
                result.append(contentsOf: flattenAndFilters(nestedAnd.children))
            } else {
                // Keep non-AND filters as-is
                result.append(child)
            }
        }

        return result
    }

    /// Try to match a filter with a specific index
    ///
    /// Supports both simple and compound indexes with prefix matching.
    /// Returns both the index scan plan and any predicates that were not satisfied by the index.
    ///
    /// - Parameters:
    ///   - filter: The query filter
    ///   - index: The index to match against
    /// - Returns: IndexMatchResult containing plan and remaining predicates, or nil if no match
    /// - Throws: RecordLayerError if matching fails
    private func matchFilterWithIndex(
        filter: any TypedQueryComponent<Record>,
        index: Index
    ) throws -> IndexMatchResult? {
        // Try simple field filter first
        if let fieldFilter = filter as? TypedFieldQueryComponent<Record> {
            return try matchSimpleFilter(fieldFilter: fieldFilter, index: index)
        }

        // Try KeyExpression-based filter (for Range boundaries)
        if let keyExprFilter = filter as? TypedKeyExpressionQueryComponent<Record> {
            return try matchKeyExpressionFilter(keyExprFilter: keyExprFilter, index: index)
        }

        // Try AND filter for compound index matching
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            return try matchCompoundFilter(andFilter: andFilter, index: index)
        }

        // OR and other complex filters not supported for single-index plans
        return nil
    }

    /// Match a simple field filter with an index
    private func matchSimpleFilter(
        fieldFilter: TypedFieldQueryComponent<Record>,
        index: Index
    ) throws -> IndexMatchResult? {
        // Check if index is on the same field (simple index)
        if let fieldExpr = index.rootExpression as? FieldKeyExpression {
            guard fieldExpr.fieldName == fieldFilter.fieldName else {
                return nil
            }

            // Generate key range for this comparison
            guard let (beginValues, endValues) = keyRange(for: fieldFilter) else {
                return nil
            }

            let plan = createIndexScanPlan(
                index: index,
                beginValues: beginValues,
                endValues: endValues
            )

            // No remaining filter - fully matched by index
            return IndexMatchResult(plan: plan, remainingFilter: nil)
        }

        // Check if index is compound and first field matches
        if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
            guard let firstField = concatExpr.children.first as? FieldKeyExpression,
                  firstField.fieldName == fieldFilter.fieldName else {
                return nil
            }

            // Prefix match on compound index
            guard let (beginValues, endValues) = keyRange(for: fieldFilter) else {
                return nil
            }

            let plan = createIndexScanPlan(
                index: index,
                beginValues: beginValues,
                endValues: endValues
            )

            // No remaining filter - fully matched by index
            return IndexMatchResult(plan: plan, remainingFilter: nil)
        }

        return nil
    }

    /// Match a KeyExpression-based filter with an index
    ///
    /// This handles TypedKeyExpressionQueryComponent filters, which include
    /// RangeKeyExpression for Range boundary comparisons.
    ///
    /// **Example**: `period.lowerBound < queryEnd`
    /// - KeyExpression: RangeKeyExpression(fieldName: "period", component: .lowerBound)
    /// - Index: "event_by_period_start" with RangeKeyExpression(.lowerBound)
    ///
    /// - Parameters:
    ///   - keyExprFilter: KeyExpression-based filter
    ///   - index: Index to match against
    /// - Returns: IndexMatchResult if matched, nil otherwise
    private func matchKeyExpressionFilter(
        keyExprFilter: TypedKeyExpressionQueryComponent<Record>,
        index: Index
    ) throws -> IndexMatchResult? {
        // Extract RangeKeyExpression if present
        guard let rangeExpr = keyExprFilter.keyExpression as? RangeKeyExpression else {
            // Other KeyExpression types not yet supported
            logger.debug("KeyExpressionFilter: Not a RangeKeyExpression", metadata: [
                "filterType": "\(type(of: keyExprFilter.keyExpression))",
                "index": "\(index.name)"
            ])
            return nil
        }

        logger.debug("Attempting to match RangeKeyExpression filter", metadata: [
            "filter_field": "\(rangeExpr.fieldName)",
            "filter_component": "\(rangeExpr.component)",
            "filter_boundaryType": "\(rangeExpr.boundaryType)",
            "index": "\(index.name)",
            "index_rootExpression": "\(type(of: index.rootExpression))"
        ])

        // Check if index uses the same RangeKeyExpression
        if let indexRangeExpr = index.rootExpression as? RangeKeyExpression {
            logger.debug("Index has RangeKeyExpression", metadata: [
                "index_field": "\(indexRangeExpr.fieldName)",
                "index_component": "\(indexRangeExpr.component)",
                "index_boundaryType": "\(indexRangeExpr.boundaryType)"
            ])

            // CRITICAL: Only match fieldName + component (NOT boundaryType)
            //
            // **Design Rationale**:
            // - Physical indexes are created with .halfOpen regardless of Range/ClosedRange
            // - Query filters have .closed for ClosedRange, .halfOpen for Range
            // - Comparing boundaryType would reject valid index matches
            // - Comparison operators (.lessThan vs .lessThanOrEquals) handle inclusive/exclusive
            //
            // **Example**:
            // - Index: RangeKeyExpression("period", .lowerBound, .halfOpen)
            // - ClosedRange query: RangeKeyExpression("period", .lowerBound, .closed)
            // - Should match! Operator handles boundary semantics.
            guard indexRangeExpr.fieldName == rangeExpr.fieldName,
                  indexRangeExpr.component == rangeExpr.component else {
                logger.debug("❌ RangeKeyExpression mismatch", metadata: [
                    "reason": "fieldName or component mismatch"
                ])
                return nil
            }

            logger.debug("✅ RangeKeyExpression matched!", metadata: [
                "index": "\(index.name)"
            ])

            // Generate key range for this comparison
            guard let (beginValues, endValues) = keyRange(for: keyExprFilter) else {
                return nil
            }

            let plan = createIndexScanPlan(
                index: index,
                beginValues: beginValues,
                endValues: endValues
            )

            // No remaining filter - fully matched by index
            return IndexMatchResult(plan: plan, remainingFilter: nil)
        }

        // Check if index is compound and first field matches
        if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
            // CRITICAL: Only match fieldName + component (NOT boundaryType) - same rationale as above
            guard let firstRangeExpr = concatExpr.children.first as? RangeKeyExpression,
                  firstRangeExpr.fieldName == rangeExpr.fieldName,
                  firstRangeExpr.component == rangeExpr.component else {
                return nil
            }

            // Prefix match on compound index
            guard let (beginValues, endValues) = keyRange(for: keyExprFilter) else {
                return nil
            }

            let plan = createIndexScanPlan(
                index: index,
                beginValues: beginValues,
                endValues: endValues
            )

            // No remaining filter - fully matched by index
            return IndexMatchResult(plan: plan, remainingFilter: nil)
        }

        return nil
    }

    /// Match an AND filter with a compound index
    private func matchCompoundFilter(
        andFilter: TypedAndQueryComponent<Record>,
        index: Index
    ) throws -> IndexMatchResult? {
        // Only compound indexes can match AND filters
        guard let concatExpr = index.rootExpression as? ConcatenateKeyExpression else {
            return nil
        }

        // Separate indexable filters from other complex predicates
        var fieldFilters: [TypedFieldQueryComponent<Record>] = []
        var keyExprFilters: [TypedKeyExpressionQueryComponent<Record>] = []
        var nonFieldPredicates: [any TypedQueryComponent<Record>] = []

        for child in andFilter.children {
            if let fieldFilter = child as? TypedFieldQueryComponent<Record> {
                fieldFilters.append(fieldFilter)
            } else if let keyExprFilter = child as? TypedKeyExpressionQueryComponent<Record> {
                keyExprFilters.append(keyExprFilter)
            } else {
                // Collect non-field predicates (NOT, nested AND/OR) for post-filtering
                nonFieldPredicates.append(child)
            }
        }

        // Try to match filters with index fields in order
        // CRITICAL: Use ObjectIdentifier for reference equality to avoid false positives
        // when multiple filters of the same type exist (e.g., two TypedKeyExpressionQueryComponent)
        var matchedFilters: [any TypedQueryComponent<Record>] = []
        var matchedFilterIdentities: Set<ObjectIdentifier> = []

        for (i, indexField) in concatExpr.children.enumerated() {
            var foundMatch = false

            // Try to match FieldKeyExpression
            if let fieldExpr = indexField as? FieldKeyExpression {
                // Find first unmatched filter for this field
                if let matchingFilter = fieldFilters.first(where: { filter in
                    !matchedFilterIdentities.contains(ObjectIdentifier(filter as AnyObject)) &&
                    filter.fieldName == fieldExpr.fieldName
                }) {
                    matchedFilters.append(matchingFilter)
                    matchedFilterIdentities.insert(ObjectIdentifier(matchingFilter as AnyObject))
                    foundMatch = true

                    // Range comparison allowed only on last matched field
                    if i < concatExpr.children.count - 1 && !matchingFilter.comparison.isEquality {
                        // Range on non-last field: stop matching
                        break
                    }
                }
            }

            // Try to match RangeKeyExpression
            if !foundMatch, let rangeExpr = indexField as? RangeKeyExpression {
                // Find first unmatched filter for this range expression
                // CRITICAL: Only match fieldName + component (NOT boundaryType) - same rationale as matchKeyExpressionFilter
                if let matchingFilter = keyExprFilters.first(where: { filter in
                    guard !matchedFilterIdentities.contains(ObjectIdentifier(filter as AnyObject)),
                          let filterRangeExpr = filter.keyExpression as? RangeKeyExpression else {
                        return false
                    }
                    return filterRangeExpr.fieldName == rangeExpr.fieldName &&
                           filterRangeExpr.component == rangeExpr.component
                }) {
                    matchedFilters.append(matchingFilter)
                    matchedFilterIdentities.insert(ObjectIdentifier(matchingFilter as AnyObject))
                    foundMatch = true

                    // Range comparison allowed only on last matched field
                    if i < concatExpr.children.count - 1 && !matchingFilter.comparison.isEquality {
                        // Range on non-last field: stop matching
                        break
                    }
                }
            }

            if !foundMatch {
                // No filter for this index field: stop prefix matching
                break
            }
        }

        // Must match at least one field
        guard !matchedFilters.isEmpty else {
            return nil
        }

        // Compute unmatched filters using ObjectIdentifier for reference equality
        var unmatchedFilters: [any TypedQueryComponent<Record>] = []
        for filter in fieldFilters {
            if !matchedFilterIdentities.contains(ObjectIdentifier(filter as AnyObject)) {
                unmatchedFilters.append(filter)
            }
        }
        for filter in keyExprFilters {
            if !matchedFilterIdentities.contains(ObjectIdentifier(filter as AnyObject)) {
                unmatchedFilters.append(filter)
            }
        }

        // Build key range from matched filters
        var beginValues: [any TupleElement] = []
        var endValues: [any TupleElement] = []

        for (i, matchedFilter) in matchedFilters.enumerated() {
            let isLastMatched = (i == matchedFilters.count - 1)

            // Handle TypedFieldQueryComponent
            if let fieldFilter = matchedFilter as? TypedFieldQueryComponent<Record> {
                if fieldFilter.comparison.isEquality {
                    // Equality: add exact value to both begin and end
                    beginValues.append(fieldFilter.value)
                    endValues.append(fieldFilter.value)
                } else if isLastMatched {
                    // Range on last matched field
                    guard let (rangeBegin, rangeEnd) = rangeValues(for: fieldFilter) else {
                        logger.debug("Cannot compute safe range boundary for compound index", metadata: [
                            "index": "\(index.name)",
                            "field": "\(fieldFilter.fieldName)",
                            "comparison": "\(fieldFilter.comparison)"
                        ])
                        return nil
                    }

                    beginValues.append(contentsOf: rangeBegin)
                    endValues.append(contentsOf: rangeEnd)
                } else {
                    // Range on non-last field: shouldn't reach here due to check above
                    return nil
                }
            }
            // Handle TypedKeyExpressionQueryComponent
            else if let keyExprFilter = matchedFilter as? TypedKeyExpressionQueryComponent<Record> {
                if keyExprFilter.comparison.isEquality {
                    // Equality: add exact value to both begin and end
                    beginValues.append(keyExprFilter.value)
                    endValues.append(keyExprFilter.value)
                } else if isLastMatched {
                    // Range on last matched field
                    guard let (rangeBegin, rangeEnd) = rangeValues(for: keyExprFilter) else {
                        logger.debug("Cannot compute safe range boundary for compound index", metadata: [
                            "index": "\(index.name)",
                            "keyExpression": "\(keyExprFilter.keyExpression)",
                            "comparison": "\(keyExprFilter.comparison)"
                        ])
                        return nil
                    }

                    beginValues.append(contentsOf: rangeBegin)
                    endValues.append(contentsOf: rangeEnd)
                } else {
                    // Range on non-last field: shouldn't reach here due to check above
                    return nil
                }
            }
        }

        // Combine unmatched field filters with non-field predicates for post-filtering
        let allRemainingPredicates = unmatchedFilters + nonFieldPredicates

        let remainingFilter: (any TypedQueryComponent<Record>)? = {
            if allRemainingPredicates.isEmpty {
                return nil
            } else if allRemainingPredicates.count == 1 {
                return allRemainingPredicates[0]
            } else {
                return TypedAndQueryComponent(children: allRemainingPredicates)
            }
        }()

        let plan = createIndexScanPlan(
            index: index,
            beginValues: beginValues,
            endValues: endValues
        )

        return IndexMatchResult(plan: plan, remainingFilter: remainingFilter)
    }

    /// Generate key range for a field filter
    ///
    /// FoundationDB Range API (used by TypedQueryPlan):
    /// - beginSelector: .firstGreaterOrEqual(beginKey) → beginKey or greater (inclusive)
    /// - endSelector: .firstGreaterOrEqual(endKey) → endKey or greater (endKey itself is exclusive)
    /// Result: Half-open interval [beginKey, endKey)
    ///
    /// For <= and >: Adjust values to correctly express inclusive/exclusive
    ///
    /// **CRITICAL**: Returns `nil` if boundary values cannot be safely computed.
    /// This prevents incorrect results at max/min values (e.g., `age > Int64.max`).
    private func keyRange(
        for fieldFilter: TypedFieldQueryComponent<Record>
    ) -> ([any TupleElement], [any TupleElement])? {
        switch fieldFilter.comparison {
        case .equals:
            // [value, value] with .firstGreaterOrEqual(begin) and .firstGreaterOrEqual(end)
            // → Includes only value (TypedQueryPlan appends 0xFF to endKey for equality)
            return ([fieldFilter.value], [fieldFilter.value])

        case .notEquals:
            return nil // Cannot optimize with index scan

        case .lessThan:
            // [min, value) with empty begin and .firstGreaterOrEqual(value)
            // → Does not include value (endKey is exclusive)
            return ([], [fieldFilter.value])

        case .lessThanOrEquals:
            // To achieve [min, value], set endKey to the next value after value
            // .firstGreaterOrEqual(nextValue) → Includes value (nextValue is exclusive)
            //
            // If nextValue cannot be computed (e.g., value == Int64.max),
            // return nil to fall back to full scan
            guard let nextValue = nextTupleValue(fieldFilter.value) else {
                return nil
            }
            return ([], [nextValue])

        case .greaterThan:
            // To achieve (value, max], set beginKey to the next value after value
            // .firstGreaterOrEqual(nextValue) → Does not include value
            //
            // If nextValue cannot be computed (e.g., value == Int64.max),
            // return nil to indicate empty result set
            guard let nextValue = nextTupleValue(fieldFilter.value) else {
                return nil
            }
            return ([nextValue], [])

        case .greaterThanOrEquals:
            // [value, max] with .firstGreaterOrEqual(value)
            // → Includes value
            return ([fieldFilter.value], [])

        case .startsWith, .contains:
            return nil // String operations not yet optimized
        }
    }

    /// Generate key range for a KeyExpression-based filter
    ///
    /// This handles TypedKeyExpressionQueryComponent filters, currently supporting
    /// RangeKeyExpression for Range boundary comparisons.
    ///
    /// **Example**: `period.lowerBound < queryEnd`
    /// - Generates: ([], [queryEnd]) for index scan [min, queryEnd)
    ///
    /// **Design**: Same boundary logic as keyRange(for: TypedFieldQueryComponent)
    /// to ensure consistent behavior across all filter types.
    ///
    /// - Parameter keyExprFilter: KeyExpression-based filter
    /// - Returns: Tuple of (beginValues, endValues), or nil if boundary cannot be computed
    private func keyRange(
        for keyExprFilter: TypedKeyExpressionQueryComponent<Record>
    ) -> ([any TupleElement], [any TupleElement])? {
        // Currently only RangeKeyExpression is supported
        guard keyExprFilter.keyExpression is RangeKeyExpression else {
            return nil
        }

        // Use the same comparison logic as TypedFieldQueryComponent
        switch keyExprFilter.comparison {
        case .equals:
            return ([keyExprFilter.value], [keyExprFilter.value])

        case .notEquals:
            return nil // Cannot optimize with index scan

        case .lessThan:
            return ([], [keyExprFilter.value])

        case .lessThanOrEquals:
            guard let nextValue = nextTupleValue(keyExprFilter.value) else {
                return nil
            }
            return ([], [nextValue])

        case .greaterThan:
            guard let nextValue = nextTupleValue(keyExprFilter.value) else {
                return nil
            }
            return ([nextValue], [])

        case .greaterThanOrEquals:
            return ([keyExprFilter.value], [])

        case .startsWith, .contains:
            return nil // String operations not yet optimized
        }
    }

    /// Generate range values for a field filter (for compound indexes)
    ///
    /// Same range boundary logic as keyRange(), propagating nil when boundary
    /// computation fails (e.g., value > Int64.max).
    ///
    /// - Returns: Tuple of (beginValues, endValues), or nil if boundary cannot be computed safely
    private func rangeValues(
        for fieldFilter: TypedFieldQueryComponent<Record>
    ) -> ([any TupleElement], [any TupleElement])? {
        switch fieldFilter.comparison {
        case .equals:
            return ([fieldFilter.value], [fieldFilter.value])

        case .lessThan:
            return ([], [fieldFilter.value])

        case .lessThanOrEquals:
            // For <=: Set endKey to the next value after value
            // If nextValue cannot be computed (e.g., Int64.max), return nil
            // to abort index optimization instead of creating incorrect full scan
            guard let nextValue = nextTupleValue(fieldFilter.value) else {
                return nil
            }
            return ([], [nextValue])

        case .greaterThan:
            // For >: Set beginKey to the next value after value
            // If nextValue cannot be computed (e.g., Int64.max), return nil
            // to abort index optimization instead of creating incorrect full scan
            guard let nextValue = nextTupleValue(fieldFilter.value) else {
                return nil
            }
            return ([nextValue], [])

        case .greaterThanOrEquals:
            return ([fieldFilter.value], [])

        default:
            return nil  // Unsupported operations
        }
    }

    /// Generate range values for a KeyExpression-based filter (for compound indexes)
    ///
    /// Same range boundary logic as rangeValues(for: TypedFieldQueryComponent),
    /// currently supporting RangeKeyExpression.
    ///
    /// - Parameter keyExprFilter: KeyExpression-based filter
    /// - Returns: Tuple of (beginValues, endValues), or nil if boundary cannot be computed safely
    private func rangeValues(
        for keyExprFilter: TypedKeyExpressionQueryComponent<Record>
    ) -> ([any TupleElement], [any TupleElement])? {
        // Currently only RangeKeyExpression is supported
        guard keyExprFilter.keyExpression is RangeKeyExpression else {
            return nil
        }

        switch keyExprFilter.comparison {
        case .equals:
            return ([keyExprFilter.value], [keyExprFilter.value])

        case .lessThan:
            return ([], [keyExprFilter.value])

        case .lessThanOrEquals:
            guard let nextValue = nextTupleValue(keyExprFilter.value) else {
                return nil
            }
            return ([], [nextValue])

        case .greaterThan:
            guard let nextValue = nextTupleValue(keyExprFilter.value) else {
                return nil
            }
            return ([nextValue], [])

        case .greaterThanOrEquals:
            return ([keyExprFilter.value], [])

        default:
            return nil  // Unsupported operations
        }
    }

    // MARK: - Heuristic Helpers

    /// Find unique index plan if applicable
    ///
    /// If filter is equality on a unique index field, return that plan.
    /// This is guaranteed to be optimal (returns 0 or 1 row).
    ///
    /// - Parameter filter: The query filter
    /// - Returns: Unique index plan if found, nil otherwise
    /// - Throws: RecordLayerError if matching fails
    private func findUniqueIndexPlan(
        _ filter: (any TypedQueryComponent<Record>)?
    ) throws -> (any TypedQueryPlan<Record>)? {
        guard let fieldFilter = filter as? TypedFieldQueryComponent<Record>,
              fieldFilter.comparison == .equals else {
            return nil
        }

        let applicableIndexes = schema.indexes(for: recordName)

        for index in applicableIndexes {
            // Check if index is unique
            guard index.options.unique else { continue }

            // Check if index matches filter field
            guard let fieldExpr = index.rootExpression as? FieldKeyExpression,
                  fieldExpr.fieldName == fieldFilter.fieldName else {
                continue
            }

            // Found unique index on equality!
            return TypedIndexScanPlan(
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                beginValues: [fieldFilter.value],
                endValues: [fieldFilter.value],
                filter: nil,  // No additional filtering needed
                primaryKeyLength: getPrimaryKeyLength(),
                recordName: recordName
            )
        }

        return nil
    }

    /// Generate IN join plan if applicable
    ///
    /// If filter is an IN predicate on a field with an index, return a TypedInJoinPlan.
    /// This executes multiple index scans (one per IN value) and unions the results.
    ///
    /// **Supported index types**:
    /// - Simple field index: `field`
    /// - Compound index prefix match: `(field, other_field, ...)` where field is the first component
    ///
    /// **Value count constraints**:
    /// - Minimum: 2 values (single value uses regular index scan)
    /// - Maximum: config.maxInValues (default: 100)
    /// - Exceeding max falls back to full scan with filter
    ///
    /// - Parameter filter: The query filter
    /// - Returns: IN join plan if found, nil otherwise
    /// - Throws: RecordLayerError if matching fails
    private func generateInJoinPlan(
        filter: any TypedQueryComponent<Record>
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Check if filter is an IN predicate
        guard let inFilter = filter as? TypedInQueryComponent<Record> else {
            return nil
        }

        // Need at least 2 values to make IN join worthwhile
        guard inFilter.values.count >= 2 else {
            return nil
        }

        // Check max IN values limit (too many values → full scan is better)
        guard inFilter.values.count <= config.maxInValues else {
            logger.debug("IN predicate has too many values, falling back to full scan", metadata: [
                "valueCount": "\(inFilter.values.count)",
                "maxInValues": "\(config.maxInValues)",
                "recommendation": "Consider using config.aggressive for higher limit, or refactor query"
            ])
            return nil
        }

        let applicableIndexes = schema.indexes(for: recordName)

        // Find an index on the IN field (simple or compound with prefix match)
        for index in applicableIndexes {
            let matchesField: Bool

            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                // Simple field index
                matchesField = fieldExpr.fieldName == inFilter.fieldName
            } else if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
                // Compound index: check if first field matches
                if let firstField = concatExpr.children.first as? FieldKeyExpression {
                    matchesField = firstField.fieldName == inFilter.fieldName
                } else {
                    matchesField = false
                }
            } else {
                matchesField = false
            }

            guard matchesField else {
                continue
            }

            // Found index with IN field - create IN join plan
            return TypedInJoinPlan<Record>(
                fieldName: inFilter.fieldName,
                values: inFilter.values,
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                primaryKeyLength: getPrimaryKeyLength(),
                recordName: recordName
            )
        }

        return nil
    }

    /// Generate IN join plans using InExtractor (handles nested IN predicates)
    ///
    /// This method uses InExtractor to find IN predicates nested within AND/OR/NOT components.
    /// It supports cost-based judgment to decide whether IN join optimization is beneficial.
    ///
    /// - Parameters:
    ///   - filter: The query filter to analyze
    ///   - tableStats: Optional table statistics for cost-based judgment
    /// - Returns: Array of IN join plans (may be empty)
    /// - Throws: RecordLayerError if extraction fails
    private func generateInJoinPlansWithExtractor(
        filter: any TypedQueryComponent<Record>,
        tableStats: TableStatistics?
    ) async throws -> [any TypedQueryPlan<Record>] {
        // Extract all IN predicates using InExtractor
        var extractor = InExtractor()
        try extractor.visit(filter)

        let inPredicates = extractor.extractedInPredicates()

        guard !inPredicates.isEmpty else {
            return []
        }

        logger.debug("Found IN predicates", metadata: [
            "count": "\(inPredicates.count)"
        ])

        var plans: [any TypedQueryPlan<Record>] = []

        // Generate IN join plan for each IN predicate
        for inPredicate in inPredicates {
            // Validate IN predicate
            guard inPredicate.valueCount >= 2 else {
                continue
            }

            guard inPredicate.valueCount <= config.maxInValues else {
                logger.debug("IN predicate has too many values, skipping", metadata: [
                    "field": "\(inPredicate.fieldName)",
                    "valueCount": "\(inPredicate.valueCount)",
                    "maxInValues": "\(config.maxInValues)"
                ])
                continue
            }

            // Find index for this field
            guard let index = try findIndexForField(inPredicate.fieldName) else {
                logger.debug("No index found for IN field, skipping", metadata: [
                    "field": "\(inPredicate.fieldName)"
                ])
                continue
            }

            // Cost-based judgment (if statistics available)
            if let tableStats = tableStats {
                let shouldUse = try await shouldUseInJoinPlan(
                    inPredicate: inPredicate,
                    index: index,
                    tableStats: tableStats
                )

                if !shouldUse {
                    logger.debug("IN join not beneficial, skipping", metadata: [
                        "field": "\(inPredicate.fieldName)",
                        "valueCount": "\(inPredicate.valueCount)"
                    ])
                    continue
                }
            }

            // Create IN join plan
            let inJoinPlan = TypedInJoinPlan<Record>(
                fieldName: inPredicate.fieldName,
                values: inPredicate.values,
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                primaryKeyLength: getPrimaryKeyLength(),
                recordName: recordName
            )

            // Build remaining filter (remove IN predicate from original filter)
            let remainingFilter = try buildRemainingFilter(
                original: filter,
                removing: inPredicate
            )

            // Wrap with TypedFilterPlan if there are remaining predicates
            if let remainingFilter = remainingFilter {
                let filterPlan = TypedFilterPlan<Record>(
                    child: inJoinPlan,
                    filter: remainingFilter
                )
                plans.append(filterPlan)
            } else {
                plans.append(inJoinPlan)
            }

            logger.debug("Generated IN join plan", metadata: [
                "field": "\(inPredicate.fieldName)",
                "valueCount": "\(inPredicate.valueCount)",
                "indexName": "\(index.name)",
                "hasRemainingFilter": "\(remainingFilter != nil)"
            ])
        }

        return plans
    }

    /// Find index for a specific field
    ///
    /// - Parameter fieldName: Field name to find index for
    /// - Returns: First matching index if found, nil otherwise
    /// - Throws: Never
    private func findIndexForField(_ fieldName: String) throws -> Index? {
        let applicableIndexes = schema.indexes(for: recordName)

        for index in applicableIndexes {
            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                // Simple field index
                if fieldExpr.fieldName == fieldName {
                    return index
                }
            } else if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
                // Compound index: check if first field matches
                if let firstField = concatExpr.children.first as? FieldKeyExpression {
                    if firstField.fieldName == fieldName {
                        return index
                    }
                }
            }
        }

        return nil
    }

    /// Cost-based judgment for IN join optimization
    ///
    /// Decides whether using IN join plan is beneficial compared to full scan.
    ///
    /// - Parameters:
    ///   - inPredicate: The IN predicate to evaluate
    ///   - index: The index to use
    ///   - tableStats: Table statistics
    /// - Returns: true if IN join is beneficial, false otherwise
    /// - Throws: Never
    private func shouldUseInJoinPlan(
        inPredicate: InPredicate,
        index: Index,
        tableStats: TableStatistics
    ) async throws -> Bool {
        // Heuristic: IN join is beneficial if:
        // 1. Number of values < table size / 10
        // 2. Index exists (already checked)
        // 3. Not too many values (already checked by maxInValues)

        let valueCount = inPredicate.valueCount
        let tableSize = tableStats.rowCount

        // If table is small, IN join may not be worth it
        if tableSize < 1000 {
            return valueCount < 10
        }

        // For larger tables, use selectivity estimate
        let estimatedSelectivity = Double(valueCount) / Double(tableSize)

        // If IN predicate is very selective (< 10%), use IN join
        if estimatedSelectivity < 0.1 {
            return true
        }

        // If moderately selective (< 50%) and not too many values, use IN join
        if estimatedSelectivity < 0.5 && valueCount < 50 {
            return true
        }

        // Otherwise, full scan may be better
        return false
    }

    /// Build remaining filter after removing IN predicate
    ///
    /// Creates a new filter that excludes the matched IN predicate.
    /// **CRITICAL**: Compares both field name AND value set to avoid removing wrong IN predicates.
    ///
    /// **Example**:
    /// ```swift
    /// // Original: age IN [1,2] AND age IN [3,4] AND city == "Tokyo"
    /// // Removing: age IN [1,2]
    /// // Result: age IN [3,4] AND city == "Tokyo"  ✅ Correct!
    /// ```
    ///
    /// - Parameters:
    ///   - original: Original filter component
    ///   - inPredicate: IN predicate to remove (must match field name AND values)
    /// - Returns: Remaining filter if any, nil if all predicates consumed
    /// - Throws: Never
    private func buildRemainingFilter(
        original: any TypedQueryComponent<Record>,
        removing inPredicate: InPredicate
    ) throws -> (any TypedQueryComponent<Record>)? {
        // If original is the IN predicate itself, check if it matches exactly
        if let inComponent = original as? TypedInQueryComponent<Record> {
            // CRITICAL: Compare both field name AND values
            if inPredicate.matches(inComponent) {
                return nil  // This is the IN predicate we're removing
            } else {
                return original  // Different IN predicate, keep it
            }
        }

        // If original is AND, remove matching IN predicate and rebuild
        if let andComponent = original as? TypedAndQueryComponent<Record> {
            var remaining: [any TypedQueryComponent<Record>] = []

            for child in andComponent.children {
                // Skip ONLY if this child matches the exact IN predicate (field name AND values)
                if let inComponent = child as? TypedInQueryComponent<Record>,
                   inPredicate.matches(inComponent) {
                    continue  // This is the exact IN predicate we're removing
                }
                remaining.append(child)
            }

            // Return remaining predicates
            if remaining.isEmpty {
                return nil
            } else if remaining.count == 1 {
                return remaining[0]
            } else {
                return TypedAndQueryComponent<Record>(children: remaining)
            }
        }

        // For OR/NOT, keep original (post-filtering will handle it)
        return original
    }

    /// Find first matching index plan
    ///
    /// Returns the first index that matches the filter, without cost comparison.
    /// Used as heuristic when statistics are unavailable.
    ///
    /// - Parameter filter: The query filter
    /// - Returns: First matching index plan if found, nil otherwise
    /// - Throws: RecordLayerError if matching fails
    private func findFirstIndexPlan(
        _ filter: (any TypedQueryComponent<Record>)?
    ) throws -> (any TypedQueryPlan<Record>)? {
        guard let filter = filter else { return nil }

        let applicableIndexes = schema.indexes(for: recordName)

        for index in applicableIndexes {
            if let matchResult = try matchFilterWithIndex(filter: filter, index: index) {
                // Wrap with TypedFilterPlan if there are remaining predicates
                if let remainingFilter = matchResult.remainingFilter {
                    return TypedFilterPlan(
                        child: matchResult.plan,
                        filter: remainingFilter
                    )
                } else {
                    return matchResult.plan
                }
            }
        }

        return nil
    }

    // MARK: - Sort Support

    /// Add sort plan if the query requires sorting and the base plan doesn't provide it
    private func addSortIfNeeded(
        plan: any TypedQueryPlan<Record>,
        query: TypedRecordQuery<Record>
    ) throws -> any TypedQueryPlan<Record> {
        // No sort required
        guard let sortKeys = query.sort, !sortKeys.isEmpty else {
            return plan
        }

        // Check if plan already satisfies sort order
        if planSatisfiesSort(plan: plan, sortKeys: sortKeys) {
            logger.debug("Plan already satisfies sort order")
            return plan
        }

        // Wrap with sort plan
        logger.debug("Adding TypedSortPlan to satisfy sort order")

        let sortFields = sortKeys.map { sortKey in
            TypedSortPlan<Record>.SortField(
                fieldName: sortKey.fieldName,
                ascending: sortKey.ascending
            )
        }

        return TypedSortPlan(
            childPlan: plan,
            sortFields: sortFields
        )
    }

    /// Check if a plan satisfies the required sort order
    private func planSatisfiesSort(
        plan: any TypedQueryPlan<Record>,
        sortKeys: [TypedSortKey<Record>]
    ) -> Bool {
        // Only index scans can provide sort order
        guard let indexScan = plan as? TypedIndexScanPlan<Record> else {
            return false
        }

        // Get index definition
        guard let index = schema.indexes(for: recordName)
            .first(where: { $0.name == indexScan.indexName }) else {
            return false
        }

        // Extract index fields
        let indexFields: [String]
        if let fieldExpr = index.rootExpression as? FieldKeyExpression {
            indexFields = [fieldExpr.fieldName]
        } else if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
            indexFields = concatExpr.children.compactMap { expr in
                (expr as? FieldKeyExpression)?.fieldName
            }
        } else {
            return false
        }

        // Check if sort keys match index field order
        for (i, sortKey) in sortKeys.enumerated() {
            guard i < indexFields.count else {
                return false // More sort keys than index fields
            }

            guard indexFields[i] == sortKey.fieldName else {
                return false // Field mismatch
            }

            // Technical limitation: Descending indexes require reverse scan support
            //
            // FoundationDB supports reverse range scans via the `reverse` parameter in
            // fdb_transaction_get_range(). However, fdb-swift-bindings currently does not
            // expose this parameter in its public API.
            //
            // Once fdb-swift-bindings adds reverse parameter support to getRange():
            // 1. Remove this guard clause
            // 2. Add `reverse: Bool` parameter to TypedIndexScanPlan
            // 3. Pass `reverse: !sortKey.ascending` to getRange() call
            //
            // See: https://github.com/apple/foundationdb/blob/main/fdbclient/NativeAPI.actor.cpp
            // (fdb_transaction_get_range has reverse parameter)
            guard sortKey.ascending else {
                return false // Descending not supported due to fdb-swift-bindings limitation
            }
        }

        return true
    }

    // MARK: - Utility

    /// Compute the "next" tuple value for range boundaries
    ///
    /// For <= and > comparisons, we need to adjust the boundary value to correctly
    /// express inclusive/exclusive ranges with FoundationDB's half-open interval API.
    ///
    /// **CRITICAL**: This function returns `nil` when the value cannot be safely incremented.
    /// This prevents incorrect query results at boundary values (e.g., `age > Int64.max`
    /// should return empty set, not `>= Int64.max`).
    ///
    /// When `nil` is returned, the caller should fall back to full scan with filtering
    /// instead of using index optimization.
    ///
    /// Strategy:
    /// - Int64: value + 1, or `nil` if value == Int64.max
    /// - Int: value + 1, or `nil` if value == Int.max
    /// - Double: nextUp, or `nil` if value.nextUp == .infinity
    /// - Float: nextUp, or `nil` if value.nextUp == .infinity
    /// - Bool: `true` if value == false, or `nil` if value == true (max bool)
    /// - String: Append null byte (conservative, may over-approximate)
    ///
    /// - Parameter value: The tuple element to increment
    /// - Returns: The next tuple value, or `nil` if increment is not safe
    private func nextTupleValue(_ value: any TupleElement) -> (any TupleElement)? {
        switch value {
        case let int64Value as Int64:
            // Cannot increment Int64.max safely
            guard int64Value < Int64.max else {
                return nil
            }
            return int64Value + 1

        case let intValue as Int:
            // Cannot increment Int.max safely
            guard intValue < Int.max else {
                return nil
            }
            return Int64(intValue) + 1

        case let doubleValue as Double:
            // Cannot increment if already at infinity
            let next = doubleValue.nextUp
            guard !next.isInfinite else {
                return nil
            }
            return next

        case let floatValue as Float:
            // Cannot increment if already at infinity
            let next = floatValue.nextUp
            guard !next.isInfinite else {
                return nil
            }
            return next

        case let boolValue as Bool:
            // true is the maximum bool value, cannot increment
            guard !boolValue else {
                return nil
            }
            return true

        case let stringValue as String:
            // For strings, append null byte as conservative approximation
            // This works for most practical cases
            return stringValue + "\u{0000}"

        case let dateValue as Date:
            // For Date, use smallest practical increment
            //
            // **Precision Considerations**:
            // - Date (Foundation) uses TimeInterval (Double) which has ~52 bits of precision
            // - For dates near Unix epoch (2000s), Double can represent microseconds accurately
            // - For extreme dates (far past/future), precision degrades to milliseconds or worse
            // - We use 1 microsecond as a safe increment that works for practical date ranges
            //
            // **Why 1 microsecond**:
            // - Small enough to preserve query semantics (> becomes >= with negligible difference)
            // - Large enough to be reliably represented in Double for reasonable date ranges
            // - Aligns with common database timestamp precision (e.g., PostgreSQL microseconds)
            //
            // **Limitations**:
            // - Queries with sub-microsecond precision requirements may need custom handling
            // - Extreme dates (billions of years from epoch) may lose precision
            return dateValue.addingTimeInterval(0.000001)  // 1 microsecond

        default:
            // Unknown type: cannot safely increment
            return nil
        }
    }

    private func getPrimaryKeyLength() -> Int {
        // Get entity from schema
        guard let entity = schema.entity(named: recordName) else {
            return 1  // Fallback to single-field primary key
        }

        // Return number of primary key fields
        return entity.primaryKeyFields.count
    }

    /// Create an index scan plan (covering or regular)
    ///
    /// Determines whether to use a covering index scan based on:
    /// 1. Index has covering fields (index.isCovering || index.coveringFields != nil)
    /// 2. Record type supports reconstruction (Record.supportsReconstruction)
    ///
    /// - Parameters:
    ///   - index: The index to scan
    ///   - beginValues: Begin key values
    ///   - endValues: End key values
    /// - Returns: TypedCoveringIndexScanPlan if covering index applicable, TypedIndexScanPlan otherwise
    private func createIndexScanPlan(
        index: Index,
        beginValues: [any TupleElement],
        endValues: [any TupleElement]
    ) -> any TypedQueryPlan<Record> {
        let primaryKeyLength = getPrimaryKeyLength()

        // Check covering index conditions:
        // 1. Index has covering fields (not nil AND not empty)
        // 2. Record type implements reconstruct() (via @Recordable macro)
        // ✅ BUG FIX #9: Guard against empty coveringFields array
        let isCoveringIndex = (index.coveringFields?.isEmpty == false)
        let supportsReconstruction = Record.supportsReconstruction

        if isCoveringIndex && supportsReconstruction {
            // Use covering index scan (no getValue() calls)
            logger.debug("Using covering index scan", metadata: [
                "indexName": "\(index.name)",
                "recordType": "\(recordName)"
            ])

            guard let entity = schema.entity(named: recordName) else {
                logger.warning("Entity not found for covering index, falling back to regular scan", metadata: [
                    "recordType": "\(recordName)"
                ])
                // Fallback to regular index scan
                return TypedIndexScanPlan<Record>(
                    indexName: index.name,
                    indexSubspaceTupleKey: index.subspaceTupleKey,
                    beginValues: beginValues,
                    endValues: endValues,
                    filter: nil,
                    primaryKeyLength: primaryKeyLength,
                    recordName: recordName
                )
            }

            return TypedCoveringIndexScanPlan<Record>(
                index: index,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                beginValues: beginValues,
                endValues: endValues,
                filter: nil,
                primaryKeyExpression: entity.primaryKeyExpression
            )
        } else {
            // Use regular index scan (requires getValue() for non-indexed fields)
            if isCoveringIndex && !supportsReconstruction {
                logger.debug("Covering index available but reconstruction not supported, using regular scan", metadata: [
                    "indexName": "\(index.name)",
                    "recordType": "\(recordName)",
                    "recommendation": "Add @Recordable macro to enable covering index optimization"
                ])
            }

            return TypedIndexScanPlan<Record>(
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                beginValues: beginValues,
                endValues: endValues,
                filter: nil,
                primaryKeyLength: primaryKeyLength,
                recordName: recordName
            )
        }
    }
}
