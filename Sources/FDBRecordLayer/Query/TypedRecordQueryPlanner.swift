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
internal struct TypedRecordQueryPlanner<Record: Recordable> {
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
    internal init(
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
    internal func plan(query: TypedRecordQuery<Record>) async throws -> any TypedQueryPlan<Record> {
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

        // OPTIMIZATION: Pre-filtering for Range queries (Proposal 3)
        // Extract Range filters and calculate per-field intersection windows
        // **CRITICAL**: Different Range fields must have separate windows
        let rangeFilters = extractRangeFilters(from: andFilter)
        var intersectionWindows: [String: RangeWindow] = [:]

        logger.debug("Range pre-filtering: Extracted Range filters", metadata: [
            "count": "\(rangeFilters.count)",
            "fields": "\(rangeFilters.map { $0.fieldName }.joined(separator: ", "))"
        ])

        // ✅ Apply window optimization for ANY Range filters (including single-sided)
        if !rangeFilters.isEmpty {
            // Calculate intersection window for each field
            // Returns nil if ANY field has contradictory (disjoint) Range conditions
            guard let windows = calculateRangeIntersectionWindows(rangeFilters) else {
                // ✅ FIX: Contradictory Range conditions detected (e.g., period.overlaps(jan) AND period.overlaps(feb))
                // Query is logically inconsistent and cannot match any records
                logger.info("Range pre-filtering: Contradictory Range conditions detected, returning EmptyPlan", metadata: [
                    "rangeFilters": "\(rangeFilters.count)"
                ])
                return TypedEmptyPlan<Record>()
            }
            intersectionWindows = windows

            logger.debug("Range pre-filtering: Intersection windows calculated", metadata: [
                "rangeFilters": "\(rangeFilters.count)",
                "fields": "\(intersectionWindows.keys.sorted().joined(separator: ", "))"
            ])
            // Log each field's window
            for (fieldName, window) in intersectionWindows.sorted(by: { $0.key < $1.key }) {
                logger.debug("Range pre-filtering: Field window", metadata: [
                    "fieldName": "\(fieldName)",
                    "window": "[\(window.lowerBound), \(window.upperBound))"
                ])
            }
        }

        // Need at least 2 indexable filters for intersection
        guard allIndexableFilters.count >= 2 else {
            logger.debug("IntersectionPlan: Not enough indexable filters", metadata: [
                "count": "\(allIndexableFilters.count)"
            ])
            return nil
        }

        // ✅ Phase 2: Handle Range filters with partial index support
        // Use specialized method for Range filters to support lowerBound-only or upperBound-only indexes
        var rangePlans: [any TypedQueryPlan<Record>] = []        // Separate: Range plans (not PK-sorted)
        var pkSortedPlans: [any TypedQueryPlan<Record>] = []     // Separate: PK-sorted plans
        var unmatchedFilters: [any TypedQueryComponent<Record>] = []

        if !rangeFilters.isEmpty {
            // Use planRangeQueryWithPartialIndexes for all Range filters
            let (rangeChildPlans, rangeUnmatchedFilters) = planRangeQueryWithPartialIndexes(
                rangeFilters: rangeFilters,
                availableIndexes: applicableIndexes,
                intersectionWindows: intersectionWindows
            )

            rangePlans.append(contentsOf: rangeChildPlans)
            unmatchedFilters.append(contentsOf: rangeUnmatchedFilters)

            logger.debug("IntersectionPlan: Range filters processed", metadata: [
                "rangePlans": "\(rangeChildPlans.count)",
                "rangeUnmatchedFilters": "\(rangeUnmatchedFilters.count)"
            ])
        }

        // Process non-Range filters using existing loop
        let nonRangeFilters = allIndexableFilters.filter { filter in
            !isRangeCompatibleFilter(filter)
        }

        for filter in nonRangeFilters {
            // Find matching index
            var found = false
            for index in applicableIndexes {
                if let matchResult = try matchFilterWithIndex(filter: filter, index: index, window: nil) {
                    pkSortedPlans.append(matchResult.plan)
                    logger.debug("IntersectionPlan: Matched non-Range filter with index", metadata: [
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
                logger.debug("IntersectionPlan: No index found for non-Range filter", metadata: [
                    "filterType": "\(type(of: filter))"
                ])
                unmatchedFilters.append(filter)
            }
        }

        let totalChildPlans = rangePlans.count + pkSortedPlans.count

        logger.debug("IntersectionPlan: Matching complete", metadata: [
            "rangePlans": "\(rangePlans.count)",
            "pkSortedPlans": "\(pkSortedPlans.count)",
            "totalChildPlans": "\(totalChildPlans)",
            "unmatchedFilters": "\(unmatchedFilters.count)"
        ])

        // Create intersection plan if we have at least 2 indexes
        guard totalChildPlans >= 2 else {
            logger.debug("IntersectionPlan: Not enough child plans", metadata: [
                "count": "\(totalChildPlans)"
            ])
            return nil
        }

        // Get entity and build primary key expression
        guard let entity = schema.entity(named: recordName) else {
            logger.warning("Entity not found", metadata: ["recordType": "\(recordName)"])
            return nil
        }

        // OPTIMIZATION (Phase 3): Selectivity-based plan ordering
        // Sort Range plans and PK-sorted plans separately by selectivity
        let sortedRangePlans = try await sortPlansBySelectivity(
            childPlans: rangePlans,
            filters: allIndexableFilters
        )

        let sortedPKSortedPlans = try await sortPlansBySelectivity(
            childPlans: pkSortedPlans,
            filters: allIndexableFilters
        )

        // HYBRID INTERSECTION STRATEGY:
        // 1. If both Range plans and PK-sorted plans exist:
        //    - Hash-intersect Range plans first (O(min(n_range)) memory)
        //    - Sorted-merge the result with PK-sorted plans (O(1) memory)
        // 2. If only Range plans: Hash intersection
        // 3. If only PK-sorted plans: Sorted-merge intersection
        let intersectionPlan: any TypedQueryPlan<Record>

        if !sortedRangePlans.isEmpty && !sortedPKSortedPlans.isEmpty {
            // Hybrid intersection: Range plans (hash) + PK-sorted plans (sorted-merge)
            logger.debug("IntersectionPlan: Using hybrid intersection strategy", metadata: [
                "rangePlans": "\(sortedRangePlans.count)",
                "pkSortedPlans": "\(sortedPKSortedPlans.count)"
            ])

            // Step 1: Hash-intersect Range plans
            let rangeIntersection = TypedIntersectionPlan(
                childPlans: sortedRangePlans,
                primaryKeyExpression: entity.primaryKeyExpression,
                requiresPKSort: false  // Hash-based intersection
            )

            // Step 2: Sorted-merge range intersection result with PK-sorted plans
            intersectionPlan = TypedIntersectionPlan(
                childPlans: [rangeIntersection] + sortedPKSortedPlans,
                primaryKeyExpression: entity.primaryKeyExpression,
                requiresPKSort: true  // Sorted-merge intersection
            )
        } else if !sortedRangePlans.isEmpty {
            // Only Range plans: Hash intersection
            logger.debug("IntersectionPlan: Using hash intersection (Range plans only)", metadata: [
                "rangePlans": "\(sortedRangePlans.count)"
            ])

            intersectionPlan = TypedIntersectionPlan(
                childPlans: sortedRangePlans,
                primaryKeyExpression: entity.primaryKeyExpression,
                requiresPKSort: false  // Hash-based intersection
            )
        } else {
            // Only PK-sorted plans: Sorted-merge intersection
            logger.debug("IntersectionPlan: Using sorted-merge intersection (PK-sorted plans only)", metadata: [
                "pkSortedPlans": "\(sortedPKSortedPlans.count)"
            ])

            intersectionPlan = TypedIntersectionPlan(
                childPlans: sortedPKSortedPlans,
                primaryKeyExpression: entity.primaryKeyExpression,
                requiresPKSort: true  // Sorted-merge intersection
            )
        }

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
        index: Index,
        window: RangeWindow? = nil
    ) throws -> IndexMatchResult? {
        // Try simple field filter first
        if let fieldFilter = filter as? TypedFieldQueryComponent<Record> {
            return try matchSimpleFilter(fieldFilter: fieldFilter, index: index, window: window)
        }

        // Try KeyExpression-based filter (for Range boundaries)
        if let keyExprFilter = filter as? TypedKeyExpressionQueryComponent<Record> {
            return try matchKeyExpressionFilter(keyExprFilter: keyExprFilter, index: index, window: window)
        }

        // Try AND filter for compound index matching
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            return try matchCompoundFilter(andFilter: andFilter, index: index, window: window)
        }

        // OR and other complex filters not supported for single-index plans
        return nil
    }

    /// Match a simple field filter with an index
    private func matchSimpleFilter(
        fieldFilter: TypedFieldQueryComponent<Record>,
        index: Index,
        window: RangeWindow? = nil
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
                endValues: endValues,
                window: window
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
                endValues: endValues,
                window: window
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
        index: Index,
        window: RangeWindow? = nil
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
                endValues: endValues,
                window: window
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
                endValues: endValues,
                window: window
            )

            // No remaining filter - fully matched by index
            return IndexMatchResult(plan: plan, remainingFilter: nil)
        }

        return nil
    }

    /// Match an AND filter with a compound index
    private func matchCompoundFilter(
        andFilter: TypedAndQueryComponent<Record>,
        index: Index,
        window: RangeWindow? = nil
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
            endValues: endValues,
            window: window
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
            return intValue + 1

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
        endValues: [any TupleElement],
        window: RangeWindow? = nil
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
                "recordType": "\(recordName)",
                "window": window != nil ? "[\(window!.lowerBound), \(window!.upperBound))" : "none"
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
                    recordName: recordName,
                    window: window
                )
            }

            return TypedCoveringIndexScanPlan<Record>(
                index: index,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                beginValues: beginValues,
                endValues: endValues,
                filter: nil,
                primaryKeyExpression: entity.primaryKeyExpression,
                window: window
            )
        } else {
            // Use regular index scan (requires getValue() for non-indexed fields)
            if isCoveringIndex && !supportsReconstruction {
                logger.debug("Covering index available but reconstruction not supported, using regular scan", metadata: [
                    "indexName": "\(index.name)",
                    "recordType": "\(recordName)",
                    "recommendation": "Add @Recordable macro to enable covering index optimization",
                    "window": window != nil ? "[\(window!.lowerBound), \(window!.upperBound))" : "none"
                ])
            }

            return TypedIndexScanPlan<Record>(
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                beginValues: beginValues,
                endValues: endValues,
                filter: nil,
                primaryKeyLength: primaryKeyLength,
                recordName: recordName,
                window: window
            )
        }
    }

    // MARK: - Range Pre-filtering (Proposal 3)

    /// Information about a Range filter extracted from query
    private struct RangeFilterInfo {
        let fieldName: String
        let lowerBound: (any TupleElement & Comparable)?  // ✅ Optional: supports PartialRange
        let upperBound: (any TupleElement & Comparable)?  // ✅ Optional: supports PartialRange
        let boundaryType: BoundaryType  // ✅ Added: distinguishes Range vs ClosedRange
        let filter: any TypedQueryComponent<Record>

        /// Create Range<Date> if both bounds are Date (for backward compatibility)
        var dateRange: Range<Date>? {
            guard let lower = lowerBound as? Date,
                  let upper = upperBound as? Date else {
                return nil
            }
            return lower..<upper
        }
    }

    /// Check if a filter is Range-compatible (involves RangeKeyExpression)
    ///
    /// A filter is Range-compatible if it references a RangeKeyExpression,
    /// which means it operates on Range boundaries (.lowerBound or .upperBound).
    ///
    /// **Examples**:
    /// - ✅ Range-compatible: `event.period.lowerBound < endDate`
    /// - ✅ Range-compatible: `event.period.upperBound > startDate`
    /// - ❌ Not Range-compatible: `event.title < "M"`
    /// - ❌ Not Range-compatible: `event.category == "Sports"`
    ///
    /// - Parameter filter: The filter to check
    /// - Returns: true if the filter involves RangeKeyExpression, false otherwise
    private func isRangeCompatibleFilter(_ filter: any TypedQueryComponent<Record>) -> Bool {
        // Check if this is a KeyExpression filter with RangeKeyExpression
        if let keyExprFilter = filter as? TypedKeyExpressionQueryComponent<Record>,
           keyExprFilter.keyExpression is RangeKeyExpression {
            return true
        }

        // Check if it's an AND/OR filter containing Range-compatible children
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            return andFilter.children.contains { isRangeCompatibleFilter($0) }
        }
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            return orFilter.children.contains { isRangeCompatibleFilter($0) }
        }

        return false
    }

    /// Extract field name from a Range-compatible filter
    ///
    /// Extracts the Range field name (e.g., "period", "availability") from a filter
    /// that involves RangeKeyExpression.
    ///
    /// **Examples**:
    /// - `event.period.lowerBound < endDate` → "period"
    /// - `event.availability.upperBound > startDate` → "availability"
    /// - AND/OR filters: returns field name from first Range-compatible child
    ///
    /// - Parameter filter: The filter to extract field name from
    /// - Returns: Field name if filter is Range-compatible, nil otherwise
    private func extractRangeFieldName(_ filter: any TypedQueryComponent<Record>) -> String? {
        // Check if this is a KeyExpression filter with RangeKeyExpression
        if let keyExprFilter = filter as? TypedKeyExpressionQueryComponent<Record>,
           let rangeExpr = keyExprFilter.keyExpression as? RangeKeyExpression {
            return rangeExpr.fieldName
        }

        // Check AND/OR filters recursively
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            for child in andFilter.children {
                if let fieldName = extractRangeFieldName(child) {
                    return fieldName
                }
            }
        }
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            for child in orFilter.children {
                if let fieldName = extractRangeFieldName(child) {
                    return fieldName
                }
            }
        }

        return nil
    }

    /// Extract Range<Date> filters from a query component
    ///
    /// This method analyzes the query filter to find Range overlaps conditions
    /// and extracts the actual Range<Date> values.
    ///
    /// **Supported patterns**:
    /// - Direct Range overlaps: `period.overlaps(queryRange)`
    /// - Generates: TypedAnd(lowerBound < queryEnd, upperBound > queryBegin)
    ///
    /// **Algorithm**:
    /// 1. Flatten AND filters
    /// 2. Find all Range boundary comparisons
    /// 3. Group by fieldName
    /// 4. For each field, try to match lowerBound/upperBound pairs
    /// 5. Reconstruct Range<Date> from matched pairs
    ///
    /// - Parameters:
    ///   - filter: Query filter to analyze
    /// - Returns: Array of extracted Range filters
    ///
    /// Extract TupleElement value from Any
    ///
    /// Supports only types that conform to both TupleElement and Comparable:
    /// Date, Int, Int64, Int32, UInt64, Double, Float, String
    ///
    /// - Parameter value: The value to extract
    /// - Returns: The value as both TupleElement and Comparable, or nil if not supported
    private func extractTupleElementValue(from value: Any) -> (any TupleElement & Comparable)? {
        // TupleElement types that are also Comparable
        if let date = value as? Date { return date }
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return int64 }
        if let int32 = value as? Int32 { return int32 }
        if let uint64 = value as? UInt64 { return uint64 }
        if let double = value as? Double { return double }
        if let float = value as? Float { return float }
        if let string = value as? String { return string }

        // Note: Int16, Int8, UInt, UInt32, UInt16, UInt8 do NOT conform to TupleElement
        // If no common type matched, return nil
        return nil
    }

    private func extractRangeFilters(
        from filter: any TypedQueryComponent<Record>
    ) -> [RangeFilterInfo] {
        var rangeFilters: [RangeFilterInfo] = []

        // If filter is AND, check children for Range patterns
        guard let andFilter = filter as? TypedAndQueryComponent<Record> else {
            logger.trace("extractRangeFilters: Filter is not AND, returning empty")
            return rangeFilters
        }

        logger.trace("extractRangeFilters: Processing AND filter with \(andFilter.children.count) children")

        // Flatten nested AND filters
        let flatChildren = flattenAndFilters(andFilter.children)

        // Group Range boundary comparisons by fieldName
        // Key: fieldName, Value: (component, comparison, value, filter)
        var boundaryComparisons: [String: [(RangeComponent, TypedFieldQueryComponent<Record>.Comparison, any TupleElement & Comparable, any TypedQueryComponent<Record>)]] = [:]

        for child in flatChildren {
            // Check if this is a Range boundary comparison
            guard let keyExprFilter = child as? TypedKeyExpressionQueryComponent<Record>,
                  let rangeExpr = keyExprFilter.keyExpression as? RangeKeyExpression,
                  let tupleValue = extractTupleElementValue(from: keyExprFilter.value) else {
                continue
            }

            logger.trace("Found Range boundary filter", metadata: [
                "field": "\(rangeExpr.fieldName)",
                "component": "\(rangeExpr.component)",
                "comparison": "\(keyExprFilter.comparison)",
                "valueType": "\(type(of: tupleValue))"
            ])

            // Add to grouped comparisons
            if boundaryComparisons[rangeExpr.fieldName] == nil {
                boundaryComparisons[rangeExpr.fieldName] = []
            }
            boundaryComparisons[rangeExpr.fieldName]?.append((
                rangeExpr.component,
                keyExprFilter.comparison,
                tupleValue,
                child
            ))
        }

        // Try to reconstruct Range from boundary pairs (supports any Comparable type)
        for (fieldName, comparisons) in boundaryComparisons {
            // Find lowerBound < or <= queryEnd (supports both Range and ClosedRange)
            let lowerBoundComparisons = comparisons.filter {
                $0.0 == .lowerBound && ($0.1 == .lessThan || $0.1 == .lessThanOrEquals)
            }

            // Find upperBound > or >= queryBegin (supports both Range and ClosedRange)
            let upperBoundComparisons = comparisons.filter {
                $0.0 == .upperBound && ($0.1 == .greaterThan || $0.1 == .greaterThanOrEquals)
            }

            // Match pairs: lowerBound < queryEnd AND upperBound > queryBegin
            // Reconstruct: queryBegin..<queryEnd
            for lowerBoundComp in lowerBoundComparisons {
                let queryEnd = lowerBoundComp.2

                for upperBoundComp in upperBoundComparisons {
                    let queryBegin = upperBoundComp.2

                    // Validate that both bounds are the same type
                    let beginType = type(of: queryBegin)
                    let endType = type(of: queryEnd)
                    guard beginType == endType else {
                        logger.warning("Range bounds have different types", metadata: [
                            "field": "\(fieldName)",
                            "beginType": "\(beginType)",
                            "endType": "\(endType)"
                        ])
                        continue
                    }

                    // Validate Range (begin < end)
                    // Note: We can't directly compare existential `any Comparable` types
                    // So we use a helper to check if begin < end
                    var isValidRange = false
                    if let beginDate = queryBegin as? Date, let endDate = queryEnd as? Date {
                        isValidRange = beginDate < endDate
                    } else if let beginInt = queryBegin as? Int, let endInt = queryEnd as? Int {
                        isValidRange = beginInt < endInt
                    } else if let beginInt64 = queryBegin as? Int64, let endInt64 = queryEnd as? Int64 {
                        isValidRange = beginInt64 < endInt64
                    } else if let beginDouble = queryBegin as? Double, let endDouble = queryEnd as? Double {
                        isValidRange = beginDouble < endDouble
                    } else if let beginString = queryBegin as? String, let endString = queryEnd as? String {
                        isValidRange = beginString < endString
                    }

                    guard isValidRange else {
                        logger.warning("Invalid Range extracted (begin >= end)", metadata: [
                            "field": "\(fieldName)",
                            "begin": "\(queryBegin)",
                            "end": "\(queryEnd)"
                        ])
                        continue
                    }

                    // ✅ Detect BoundaryType based on comparison operators
                    let boundaryType: BoundaryType
                    if lowerBoundComp.1 == .lessThanOrEquals && upperBoundComp.1 == .greaterThanOrEquals {
                        boundaryType = .closed  // ClosedRange: lowerBound <= queryEnd && upperBound >= queryBegin
                    } else {
                        boundaryType = .halfOpen  // Range: lowerBound < queryEnd && upperBound > queryBegin
                    }

                    logger.debug("Extracted Range filter", metadata: [
                        "field": "\(fieldName)",
                        "beginValue": "\(queryBegin)",
                        "endValue": "\(queryEnd)",
                        "boundaryType": "\(boundaryType.rawValue)",
                        "valueType": "\(type(of: queryBegin))"
                    ])

                    // Create RangeFilterInfo
                    // Use the AND of both boundary filters as the composite filter
                    let compositeFilter = TypedAndQueryComponent(children: [
                        lowerBoundComp.3,
                        upperBoundComp.3
                    ])

                    rangeFilters.append(RangeFilterInfo(
                        fieldName: fieldName,
                        lowerBound: queryBegin,
                        upperBound: queryEnd,
                        boundaryType: boundaryType,  // ✅ Pass boundaryType
                        filter: compositeFilter
                    ))
                }
            }

            // ✅ Handle PartialRange: lowerBound only (PartialRangeFrom)
            if upperBoundComparisons.isEmpty && !lowerBoundComparisons.isEmpty {
                for lowerBoundComp in lowerBoundComparisons {
                    let queryEnd = lowerBoundComp.2
                    let boundaryType: BoundaryType = lowerBoundComp.1 == .lessThanOrEquals ? .closed : .halfOpen

                    logger.debug("Extracted PartialRangeFrom filter", metadata: [
                        "field": "\(fieldName)",
                        "endValue": "\(queryEnd)",
                        "boundaryType": "\(boundaryType.rawValue)"
                    ])

                    rangeFilters.append(RangeFilterInfo(
                        fieldName: fieldName,
                        lowerBound: nil,  // ✅ No lowerBound
                        upperBound: queryEnd,
                        boundaryType: boundaryType,
                        filter: lowerBoundComp.3
                    ))
                }
            }

            // ✅ Handle PartialRange: upperBound only (PartialRangeThrough/PartialRangeUpTo)
            if lowerBoundComparisons.isEmpty && !upperBoundComparisons.isEmpty {
                for upperBoundComp in upperBoundComparisons {
                    let queryBegin = upperBoundComp.2
                    let boundaryType: BoundaryType = upperBoundComp.1 == .greaterThanOrEquals ? .closed : .halfOpen

                    logger.debug("Extracted PartialRangeThrough/UpTo filter", metadata: [
                        "field": "\(fieldName)",
                        "beginValue": "\(queryBegin)",
                        "boundaryType": "\(boundaryType.rawValue)"
                    ])

                    rangeFilters.append(RangeFilterInfo(
                        fieldName: fieldName,
                        lowerBound: queryBegin,
                        upperBound: nil,  // ✅ No upperBound
                        boundaryType: boundaryType,
                        filter: upperBoundComp.3
                    ))
                }
            }
        }

        logger.trace("extractRangeFilters: Returning \(rangeFilters.count) Range filters", metadata: [
            "fields": "\(rangeFilters.map { $0.fieldName }.joined(separator: ", "))"
        ])

        return rangeFilters
    }

    /// Calculate intersection windows for multiple Range filters, grouped by field
    ///
    /// **CRITICAL**: Different Range fields (e.g., `period` and `availability`) must be
    /// handled separately. Each field gets its own intersection window.
    ///
    /// **IMPORTANT**: If ANY field has no valid intersection (e.g., disjoint ranges on the same field),
    /// the entire query result must be empty. This function returns `nil` in such cases.
    ///
    /// Uses RangeWindowCalculator to compute the intersection of multiple Range conditions
    /// for each field. If a field has only one Range filter, that Range is used as-is.
    ///
    /// **Example 1 (Valid)**:
    /// ```swift
    /// // Query: period.overlaps(range1) AND period.overlaps(range2) AND availability.overlaps(range3)
    /// // Input: [
    /// //   RangeFilterInfo(fieldName: "period", range: range1),
    /// //   RangeFilterInfo(fieldName: "period", range: range2),
    /// //   RangeFilterInfo(fieldName: "availability", range: range3)
    /// // ]
    /// // Output: [
    /// //   "period": intersection(range1, range2),
    /// //   "availability": range3
    /// // ]
    /// ```
    ///
    /// **Example 2 (Disjoint - Returns nil)**:
    /// ```swift
    /// // Query: period.overlaps(jan1to15) AND period.overlaps(feb1to28) AND availability.overlaps(mar1to31)
    /// // period ranges are disjoint → no record can satisfy both conditions → returns nil
    /// ```
    ///
    /// - Parameter rangeFilters: Array of Range filters to intersect
    /// - Returns: Dictionary mapping field name to intersection window for that field, or `nil` if
    ///            any field has disjoint ranges (contradictory conditions).
    private func calculateRangeIntersectionWindows(
        _ rangeFilters: [RangeFilterInfo]
    ) -> [String: RangeWindow]? {
        // Group filters by field name
        var filtersByField: [String: [RangeFilterInfo]] = [:]
        for filter in rangeFilters {
            if filtersByField[filter.fieldName] == nil {
                filtersByField[filter.fieldName] = []
            }
            filtersByField[filter.fieldName]?.append(filter)
        }

        // Calculate intersection for each field
        var windows: [String: RangeWindow] = [:]
        for (fieldName, filters) in filtersByField {
            if filters.count == 1 {
                // Single filter: use its range directly (only if both bounds present)
                let filter = filters[0]
                // ✅ Skip PartialRange (one-sided) - window optimization requires both bounds
                guard let lowerBound = filter.lowerBound,
                      let upperBound = filter.upperBound else {
                    // PartialRange: no window optimization, will use raw index scan
                    continue
                }

                // ✅ FIX: For ClosedRange, apply successor to upperBound
                let effectiveUpperBound: any Comparable & Sendable
                if filter.boundaryType == .closed {
                    // ClosedRange: [lower, upper] → Range: [lower, successor(upper))
                    // upperBound is already TupleElement & Comparable, cast is always safe
                    if let succ = successor(of: upperBound) {
                        effectiveUpperBound = succ as! (any Comparable & Sendable)
                    } else {
                        // Cannot compute successor, use original (may cause incorrect results)
                        effectiveUpperBound = upperBound
                    }
                } else {
                    // Range: already exclusive upper bound
                    effectiveUpperBound = upperBound
                }

                windows[fieldName] = RangeWindow(
                    lowerBound: lowerBound,
                    upperBound: effectiveUpperBound
                )
            } else {
                // Multiple filters: calculate intersection using type-specific comparison
                // All filters for a field must have the same type
                guard !filters.isEmpty else { continue }

                // Try to calculate intersection based on the type
                if let window = calculateIntersectionForComparableType(filters, fieldName: fieldName) {
                    windows[fieldName] = window
                } else {
                    // No intersection for this field → CONTRADICTORY CONDITIONS
                    logger.info("Range pre-filtering: Contradictory Range conditions on field, returning EmptyPlan", metadata: [
                        "fieldName": "\(fieldName)",
                        "filterCount": "\(filters.count)"
                    ])
                    return nil
                }
            }
        }

        return windows
    }

    /// Calculate intersection window for filters with a specific Comparable type
    private func calculateIntersectionForComparableType(
        _ filters: [RangeFilterInfo],
        fieldName: String
    ) -> RangeWindow? {
        guard !filters.isEmpty else { return nil }

        // Check if all filters have Date bounds
        if let dateRanges = extractTypedRanges(filters, as: Date.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(dateRanges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have Int bounds
        if let intRanges = extractTypedRanges(filters, as: Int.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(intRanges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have Int64 bounds
        if let int64Ranges = extractTypedRanges(filters, as: Int64.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(int64Ranges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have Double bounds
        if let doubleRanges = extractTypedRanges(filters, as: Double.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(doubleRanges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have String bounds
        if let stringRanges = extractTypedRanges(filters, as: String.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(stringRanges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have UInt64 bounds
        if let uint64Ranges = extractTypedRanges(filters, as: UInt64.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(uint64Ranges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have Float bounds
        if let floatRanges = extractTypedRanges(filters, as: Float.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(floatRanges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have UUID bounds
        if let uuidRanges = extractTypedRanges(filters, as: UUID.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(uuidRanges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Check if all filters have Versionstamp bounds
        if let versionstampRanges = extractTypedRanges(filters, as: Versionstamp.self) {
            if let intersection = RangeWindowCalculator.calculateIntersectionWindow(versionstampRanges) {
                return RangeWindow(intersection)
            }
            return nil
        }

        // Unsupported type or mixed types
        logger.trace("Range pre-filtering: Unsupported or mixed Comparable types", metadata: [
            "fieldName": "\(fieldName)",
            "filterCount": "\(filters.count)"
        ])
        return nil
    }

    /// Extract typed ranges if all filters have the same Comparable type
    private func extractTypedRanges<T: Comparable>(
        _ filters: [RangeFilterInfo],
        as type: T.Type
    ) -> [Range<T>]? {
        var ranges: [Range<T>] = []

        for filter in filters {
            guard let lower = filter.lowerBound as? T,
                  let upper = filter.upperBound as? T else {
                return nil  // Type mismatch
            }

            // ✅ FIX: For ClosedRange (boundaryType == .closed), we need to convert to Range
            // by computing successor(upper) to make the upper bound exclusive
            let effectiveUpper: T
            if filter.boundaryType == .closed {
                // ClosedRange: [lower, upper] → Range: [lower, successor(upper))
                // Cast to TupleElement for successor(), then cast result back to T
                if let upperAsTupleElement = upper as? any TupleElement,
                   let succ = successor(of: upperAsTupleElement) as? T {
                    effectiveUpper = succ
                } else {
                    // Cannot compute successor, use original (may cause incorrect results)
                    effectiveUpper = upper
                }
            } else {
                // Range: already exclusive upper bound
                effectiveUpper = upper
            }

            ranges.append(lower..<effectiveUpper)
        }

        return ranges.count == filters.count ? ranges : nil
    }

    // MARK: - Selectivity-Based Optimization (Phase 3)

    /// Sort child plans by selectivity (highest selectivity first)
    ///
    /// **Purpose**: Optimize IntersectionPlan execution order by executing the most
    /// selective (smallest result set) plan first. This reduces the number of records
    /// to check in subsequent plans.
    ///
    /// **Algorithm**:
    /// 1. Estimate selectivity for each plan using statistics
    /// 2. Sort plans in descending order of selectivity (highest = smallest result set)
    /// 3. Return sorted plans
    ///
    /// **Example**:
    /// ```
    /// // Before sorting:
    /// Plan A: category = "Electronics" (selectivity: 0.5, 10,000 records)
    /// Plan B: price > 1000 (selectivity: 0.01, 200 records)
    ///
    /// // After sorting:
    /// Plan B: price > 1000 (executes first, returns 200 records)
    /// Plan A: category = "Electronics" (filters 200 records, not 10,000)
    /// ```
    ///
    /// - Parameters:
    ///   - childPlans: Child plans to sort
    ///   - filters: Corresponding filters (for selectivity estimation)
    /// - Returns: Sorted child plans (highest selectivity first)
    private func sortPlansBySelectivity(
        childPlans: [any TypedQueryPlan<Record>],
        filters: [any TypedQueryComponent<Record>]
    ) async throws -> [any TypedQueryPlan<Record>] {
        // If we have <= 1 plan, no sorting needed
        guard childPlans.count > 1 else {
            return childPlans
        }

        // Create plan-selectivity pairs
        var planSelectivities: [(plan: any TypedQueryPlan<Record>, selectivity: Double)] = []

        for (index, plan) in childPlans.enumerated() {
            // Extract index name from plan (if it's an index scan plan)
            let indexName = extractIndexName(from: plan)

            // Get corresponding filter (if available)
            let filter = index < filters.count ? filters[index] : nil

            // Estimate selectivity
            let selectivity: Double
            if let indexName = indexName {
                // Try to get Range statistics for this index
                if let rangeStats = try? await statisticsManager.getRangeStatistics(indexName: indexName) {
                    // ✅ Phase 6: Use query range width for dynamic selectivity estimation
                    if let filter = filter {
                        // Extract Range filters to get actual query boundaries
                        let rangeFilters = extractRangeFilters(from: filter)

                        if rangeFilters.count == 1 {
                            let rangeFilter = rangeFilters[0]
                            // ✅ Only estimate selectivity if both bounds are present
                            if let lowerBound = rangeFilter.lowerBound,
                               let upperBound = rangeFilter.upperBound,
                               let dynamicSelectivity = try? await statisticsManager.estimateRangeSelectivity(
                                indexName: indexName,
                                lowerBound: lowerBound,
                                upperBound: upperBound
                            ) {
                                selectivity = dynamicSelectivity
                                logger.debug("Selectivity-based optimization: Using dynamic Range selectivity", metadata: [
                                    "indexName": "\(indexName)",
                                    "selectivity": "\(selectivity)"
                                ])
                            } else {
                                // Fallback to base selectivity if estimation fails
                                selectivity = rangeStats.selectivity
                                logger.debug("Selectivity-based optimization: Using base Range statistics", metadata: [
                                    "indexName": "\(indexName)",
                                    "selectivity": "\(selectivity)"
                                ])
                            }
                        } else {
                            // No single Range filter: use base selectivity
                            selectivity = rangeStats.selectivity
                            logger.debug("Selectivity-based optimization: Using base Range statistics (multiple ranges)", metadata: [
                                "indexName": "\(indexName)",
                                "selectivity": "\(selectivity)"
                            ])
                        }
                    } else {
                        // No query range extracted: use base selectivity
                        selectivity = rangeStats.selectivity
                        logger.debug("Selectivity-based optimization: Using base Range statistics (no filter)", metadata: [
                            "indexName": "\(indexName)",
                            "selectivity": "\(selectivity)"
                        ])
                    }
                } else if (try? await statisticsManager.getIndexStatistics(indexName: indexName)) != nil {
                    // Use regular index statistics
                    // Estimate based on histogram if available
                    selectivity = 0.1  // Conservative default
                    logger.debug("Selectivity-based optimization: Using index statistics", metadata: [
                        "indexName": "\(indexName)",
                        "selectivity": "\(selectivity)"
                    ])
                } else {
                    // No statistics: use heuristic
                    selectivity = 0.2
                    logger.debug("Selectivity-based optimization: No statistics, using heuristic", metadata: [
                        "indexName": "\(indexName)",
                        "selectivity": "\(selectivity)"
                    ])
                }
            } else {
                // Not an index scan plan (e.g., full scan): conservative estimate
                selectivity = 0.5
                logger.debug("Selectivity-based optimization: Non-index plan", metadata: [
                    "planType": "\(type(of: plan))",
                    "selectivity": "\(selectivity)"
                ])
            }

            planSelectivities.append((plan: plan, selectivity: selectivity))
        }

        // Sort by selectivity (highest first = smallest result set)
        // Higher selectivity means fewer results, so we want to execute it first
        planSelectivities.sort { $0.selectivity < $1.selectivity }

        logger.debug("Selectivity-based optimization: Sorted plans", metadata: [
            "planCount": "\(planSelectivities.count)",
            "selectivities": "\(planSelectivities.map { String(format: "%.4f", $0.selectivity) }.joined(separator: ", "))"
        ])

        return planSelectivities.map(\.plan)
    }

    /// Extract index name from a query plan
    ///
    /// - Parameter plan: Query plan
    /// - Returns: Index name if the plan is an index scan, otherwise nil
    private func extractIndexName(from plan: any TypedQueryPlan<Record>) -> String? {
        // TypedIndexScanPlan
        if let indexScanPlan = plan as? TypedIndexScanPlan<Record> {
            return indexScanPlan.indexName
        }

        // TypedCoveringIndexScanPlan
        if let coveringPlan = plan as? TypedCoveringIndexScanPlan<Record> {
            return coveringPlan.index.name
        }

        // TypedFilterPlan wrapping an index scan
        if let filterPlan = plan as? TypedFilterPlan<Record> {
            return extractIndexName(from: filterPlan.child)
        }

        return nil
    }

    // MARK: - Partial Range Index Support

    /// Handle Range queries where only one index (start_index OR end_index) is defined
    ///
    /// This method handles cases where developers have explicitly defined only `.lowerBound` or `.upperBound`
    /// indexes for a Range field. When only partial indexes exist:
    /// - If only start_index exists: Use it for the lowerBound condition, add upperBound to unmatchedFilters
    /// - If only end_index exists: Use it for the upperBound condition, add lowerBound to unmatchedFilters
    /// - If both exist: Create standard intersection plan
    /// - If neither exists: Add all conditions to unmatchedFilters
    ///
    /// - Parameters:
    ///   - rangeFilters: Extracted Range filters from the query
    ///   - availableIndexes: All indexes available for this record type
    ///   - intersectionWindows: Per-field intersection windows for pre-filtering optimization
    /// - Returns: Tuple of (childPlans: generated index scan plans, unmatchedFilters: remaining filters for post-processing)
    private func planRangeQueryWithPartialIndexes(
        rangeFilters: [RangeFilterInfo],
        availableIndexes: [Index],
        intersectionWindows: [String: RangeWindow]
    ) -> (childPlans: [any TypedQueryPlan<Record>], unmatchedFilters: [any TypedQueryComponent<Record>]) {
        var childPlans: [any TypedQueryPlan<Record>] = []
        var unmatchedFilters: [any TypedQueryComponent<Record>] = []

        for rangeFilter in rangeFilters {
            let fieldName = rangeFilter.fieldName

            // Find start_index (lowerBound component)
            let startIndex = availableIndexes.first { index in
                guard let rangeExpr = index.rootExpression as? RangeKeyExpression else { return false }
                return rangeExpr.fieldName == fieldName && rangeExpr.component == .lowerBound
            }

            // Find end_index (upperBound component)
            let endIndex = availableIndexes.first { index in
                guard let rangeExpr = index.rootExpression as? RangeKeyExpression else { return false }
                return rangeExpr.fieldName == fieldName && rangeExpr.component == .upperBound
            }

            // Handle 4 cases based on which indexes exist
            switch (startIndex, endIndex) {
            case (.some(let start), .some(let end)):
                // Case 1: Both indexes exist → standard intersection plan
                if let lowerBound = rangeFilter.lowerBound, let upperBound = rangeFilter.upperBound {
                    // start_index plan: lowerBound < queryEnd (or <= for ClosedRange)
                    let startPlan = createRangeIndexScanPlan(
                        index: start,
                        queryValue: upperBound,
                        comparison: rangeFilter.boundaryType == .closed ? .lessThanOrEquals : .lessThan,
                        component: .lowerBound,
                        window: intersectionWindows[fieldName]
                    )

                    // end_index plan: upperBound > queryBegin (or >= for ClosedRange)
                    let endPlan = createRangeIndexScanPlan(
                        index: end,
                        queryValue: lowerBound,
                        comparison: rangeFilter.boundaryType == .closed ? .greaterThanOrEquals : .greaterThan,
                        component: .upperBound,
                        window: intersectionWindows[fieldName]
                    )

                    childPlans.append(contentsOf: [startPlan, endPlan])
                }

            case (.some(let start), .none):
                // Case 2: Only start_index exists → use start plan + add end condition to unmatchedFilters
                if let upperBound = rangeFilter.upperBound {
                    // start_index plan: lowerBound < queryEnd
                    let startPlan = createRangeIndexScanPlan(
                        index: start,
                        queryValue: upperBound,
                        comparison: rangeFilter.boundaryType == .closed ? .lessThanOrEquals : .lessThan,
                        component: .lowerBound,
                        window: intersectionWindows[fieldName]
                    )
                    childPlans.append(startPlan)

                    // Add end condition to unmatchedFilters (will be applied as post-filter)
                    if let lowerBound = rangeFilter.lowerBound {
                        let endFilter = TypedKeyExpressionQueryComponent<Record>(
                            keyExpression: RangeKeyExpression(
                                fieldName: fieldName,
                                component: .upperBound,
                                boundaryType: rangeFilter.boundaryType
                            ),
                            comparison: rangeFilter.boundaryType == .closed ? .greaterThanOrEquals : .greaterThan,
                            value: lowerBound
                        )
                        unmatchedFilters.append(endFilter)
                    }
                } else {
                    // PartialRangeFrom (only lowerBound): use start_index + unmatchedFilter
                    // overlaps(period, lowerBound...) requires:
                    //   1. period.lowerBound >= lowerBound (use start_index to filter)
                    //   2. period.upperBound > lowerBound (add to unmatchedFilter)
                    if let lowerBound = rangeFilter.lowerBound {
                        // 1. start_index scan: period.lowerBound >= lowerBound
                        let startPlan = createRangeIndexScanPlan(
                            index: start,
                            queryValue: lowerBound,
                            comparison: rangeFilter.boundaryType == .closed ? .greaterThanOrEquals : .greaterThan,
                            component: .lowerBound,
                            window: intersectionWindows[fieldName]
                        )
                        childPlans.append(startPlan)

                        // 2. Add unmatchedFilter for period.upperBound > lowerBound
                        // ✅ BUG FIX: For PartialRangeFrom, unmatchedFilter must always use strict '>'
                        // because the upperBound side is open (not included in the range)
                        let endFilter = TypedKeyExpressionQueryComponent<Record>(
                            keyExpression: RangeKeyExpression(
                                fieldName: fieldName,
                                component: .upperBound,
                                boundaryType: .halfOpen  // ✅ Fixed: halfOpen = not included
                            ),
                            comparison: .greaterThan,  // ✅ Fixed: Always strict '>'
                            value: lowerBound
                        )
                        unmatchedFilters.append(endFilter)
                    }
                }

            case (.none, .some(let end)):
                // Case 3: Only end_index exists → use end plan + add start condition to unmatchedFilters
                if let lowerBound = rangeFilter.lowerBound {
                    // end_index plan: upperBound > queryBegin
                    let endPlan = createRangeIndexScanPlan(
                        index: end,
                        queryValue: lowerBound,
                        comparison: rangeFilter.boundaryType == .closed ? .greaterThanOrEquals : .greaterThan,
                        component: .upperBound,
                        window: intersectionWindows[fieldName]
                    )
                    childPlans.append(endPlan)

                    // Add start condition to unmatchedFilters (will be applied as post-filter)
                    if let upperBound = rangeFilter.upperBound {
                        let startFilter = TypedKeyExpressionQueryComponent<Record>(
                            keyExpression: RangeKeyExpression(
                                fieldName: fieldName,
                                component: .lowerBound,
                                boundaryType: rangeFilter.boundaryType
                            ),
                            comparison: rangeFilter.boundaryType == .closed ? .lessThanOrEquals : .lessThan,
                            value: upperBound
                        )
                        unmatchedFilters.append(startFilter)
                    }
                } else {
                    // PartialRangeThrough/UpTo (only upperBound): use end_index + unmatchedFilter
                    // overlaps(period, ...upperBound) requires:
                    //   1. period.upperBound <= upperBound (use end_index to filter)
                    //   2. period.lowerBound < upperBound (add to unmatchedFilter)
                    if let upperBound = rangeFilter.upperBound {
                        // 1. end_index scan: period.upperBound <= upperBound
                        let endPlan = createRangeIndexScanPlan(
                            index: end,
                            queryValue: upperBound,
                            comparison: rangeFilter.boundaryType == .closed ? .lessThanOrEquals : .lessThan,
                            component: .upperBound,
                            window: intersectionWindows[fieldName]
                        )
                        childPlans.append(endPlan)

                        // 2. Add unmatchedFilter for period.lowerBound < upperBound
                        // ✅ BUG FIX: For PartialRangeThrough/UpTo, unmatchedFilter must always use strict '<'
                        // because the lowerBound side is the "missing side" (not included in the range)
                        // - PartialRangeThrough (...X): rangeFilter is upperBound <= X, unmatchedFilter is lowerBound < X (strict)
                        // - PartialRangeUpTo (..<X): rangeFilter is upperBound < X, unmatchedFilter is lowerBound < X (strict)
                        let startFilter = TypedKeyExpressionQueryComponent<Record>(
                            keyExpression: RangeKeyExpression(
                                fieldName: fieldName,
                                component: .lowerBound,
                                boundaryType: .halfOpen  // ✅ Fixed: Always halfOpen for missing side
                            ),
                            comparison: .lessThan,  // ✅ Fixed: Always strict '<'
                            value: upperBound
                        )
                        unmatchedFilters.append(startFilter)
                    }
                }

            case (.none, .none):
                // Case 4: No indexes defined → add entire filter to unmatchedFilters (full scan with post-filter)
                unmatchedFilters.append(rangeFilter.filter)
            }
        }

        return (childPlans, unmatchedFilters)
    }

    /// Compute the successor of a value for Range boundary calculations
    ///
    /// This function returns the next representable value after the given value,
    /// which is useful for implementing <= as < successor(value).
    ///
    /// - Parameter value: The value to compute the successor for
    /// - Returns: The successor value, or nil if it cannot be computed
    private func successor(of value: any TupleElement) -> (any TupleElement)? {
        switch value {
        case let date as Date:
            // For Date, add 1 millisecond (FDB Tuple encoding uses millisecond precision)
            // Note: Date is stored as Int64 milliseconds in FDB Tuple encoding
            return date.addingTimeInterval(0.001)

        case let int64 as Int64:
            // For Int64, add 1 (unless at max value)
            guard int64 < Int64.max else { return nil }
            return int64 + 1

        case let int as Int:
            // Convert to Int64 and add 1
            let int64 = Int64(int)
            guard int64 < Int64.max else { return nil }
            return int64 + 1

        case let int32 as Int32:
            // Convert to Int64 and add 1
            return Int64(int32) + 1

        case let uint64 as UInt64:
            // For UInt64, add 1 (unless at max value)
            guard uint64 < UInt64.max else { return nil }
            return uint64 + 1

        case let double as Double:
            // For Double, use nextUp (next representable value)
            return double.nextUp

        case let float as Float:
            // For Float, use nextUp and convert to Double for consistency
            return Double(float.nextUp)

        case let string as String:
            // For String, append the smallest character (\0)
            // This gives us the next string in lexicographic order
            return string + "\u{0000}"

        default:
            // For other types, we cannot compute successor
            // Caller should fall back to post-filter approach
            return nil
        }
    }

    /// Create a TypedIndexScanPlan for a Range boundary component
    ///
    /// This helper creates an index scan plan for a single Range boundary (lowerBound or upperBound).
    /// The scan range is determined by the component and comparison operator:
    /// - lowerBound < value: Scan lowerBound index where lowerBound < value
    /// - upperBound > value: Scan upperBound index where upperBound > value
    ///
    /// - Parameters:
    ///   - index: The Range component index to scan (must have rangeComponent)
    ///   - queryValue: The comparison value from the query (TupleElement type)
    ///   - comparison: The comparison operator (.lessThan, .lessThanOrEquals, .greaterThan, .greaterThanOrEquals)
    ///   - component: The Range component being queried (.lowerBound or .upperBound)
    ///   - window: Optional intersection window for pre-filtering optimization
    /// - Returns: TypedIndexScanPlan configured for the Range boundary scan
    private func createRangeIndexScanPlan(
        index: Index,
        queryValue: any TupleElement,
        comparison: TypedFieldQueryComponent<Record>.Comparison,
        component: RangeComponent,
        window: RangeWindow?
    ) -> any TypedQueryPlan<Record> {
        let primaryKeyLength = getPrimaryKeyLength()

        // Determine scan range based on comparison operator
        let beginValues: [any TupleElement]
        let endValues: [any TupleElement]
        var postFilter: (any TypedQueryComponent<Record>)? = nil

        switch comparison {
        case .lessThan:
            // FDB endKey is exclusive, so this correctly implements <
            // Example: lowerBound < 2024-12-31 → scan lowerBound from MIN to 2024-12-31
            beginValues = []
            endValues = [queryValue]

        case .lessThanOrEquals:
            // FDB endKey is exclusive, so endValues = [queryValue] would only give us <
            // To implement <=, we need to include queryValue itself
            // Solution: Use successor(queryValue) as endKey, so scan becomes < successor(queryValue)
            // which is equivalent to <= queryValue
            beginValues = []
            if let successorValue = successor(of: queryValue) {
                endValues = [successorValue]
            } else {
                // Fallback: Use post-filter if successor cannot be computed
                endValues = []
                let boundaryType: BoundaryType = index.rootExpression is RangeKeyExpression
                    ? (index.rootExpression as! RangeKeyExpression).boundaryType
                    : .halfOpen
                postFilter = TypedKeyExpressionQueryComponent<Record>(
                    keyExpression: RangeKeyExpression(
                        fieldName: (index.rootExpression as? FieldKeyExpression)?.fieldName
                            ?? (index.rootExpression as? RangeKeyExpression)?.fieldName
                            ?? "",
                        component: component,
                        boundaryType: boundaryType
                    ),
                    comparison: .lessThanOrEquals,
                    value: queryValue
                )
            }

        case .greaterThan:
            // FDB beginKey is inclusive, so beginValues = [queryValue] would give us >=
            // To implement strict >, we scan from queryValue and filter
            // Solution: Scan >= queryValue, then post-filter to exclude queryValue itself
            beginValues = [queryValue]
            endValues = []

            // Add post-filter for strict > check
            let boundaryType: BoundaryType = index.rootExpression is RangeKeyExpression
                ? (index.rootExpression as! RangeKeyExpression).boundaryType
                : .halfOpen
            postFilter = TypedKeyExpressionQueryComponent<Record>(
                keyExpression: RangeKeyExpression(
                    fieldName: (index.rootExpression as? FieldKeyExpression)?.fieldName
                        ?? (index.rootExpression as? RangeKeyExpression)?.fieldName
                        ?? "",
                    component: component,
                    boundaryType: boundaryType
                ),
                comparison: .greaterThan,
                value: queryValue
            )

        case .greaterThanOrEquals:
            // FDB beginKey is inclusive, so this correctly implements >=
            // Example: upperBound >= 2024-01-01 → scan upperBound from 2024-01-01 to MAX
            beginValues = [queryValue]
            endValues = []

        default:
            // For other comparisons (equals, notEquals, etc.), use full scan
            beginValues = []
            endValues = []
        }

        // Create TypedIndexScanPlan with window and post-filter
        return TypedIndexScanPlan<Record>(
            indexName: index.name,
            indexSubspaceTupleKey: index.subspaceTupleKey,
            beginValues: beginValues,
            endValues: endValues,
            filter: postFilter,  // Apply post-filter for strict comparisons
            primaryKeyLength: primaryKeyLength,
            recordName: recordName,
            window: window
        )
    }
}
