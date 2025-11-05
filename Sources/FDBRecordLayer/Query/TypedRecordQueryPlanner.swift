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
///     metaData: metaData,
///     recordTypeName: "User",
///     statisticsManager: statsManager
/// )
///
/// let query = TypedRecordQuery<User>(filter: \.email == "test@example.com", limit: 10)
/// let plan = try await planner.plan(query: query)
/// ```
public struct TypedRecordQueryPlanner<Record: Sendable> {
    // MARK: - Properties

    private let metaData: RecordMetaData
    private let recordTypeName: String
    private let statisticsManager: any StatisticsManagerProtocol
    private let costEstimator: CostEstimator
    private let planCache: PlanCache<Record>
    private let config: PlanGenerationConfig
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize query planner with cost-based optimization
    ///
    /// - Parameters:
    ///   - metaData: Record metadata containing index definitions
    ///   - recordTypeName: The record type being queried
    ///   - statisticsManager: Statistics manager for cost estimation
    ///   - planCache: Optional plan cache (creates default if nil)
    ///   - config: Plan generation configuration (default: .default)
    ///   - logger: Optional logger (creates default if nil)
    public init(
        metaData: RecordMetaData,
        recordTypeName: String,
        statisticsManager: any StatisticsManagerProtocol,
        planCache: PlanCache<Record>? = nil,
        config: PlanGenerationConfig = .default,
        logger: Logger? = nil
    ) {
        self.metaData = metaData
        self.recordTypeName = recordTypeName
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
        // Check cache (synchronous access with Mutex)
        if let cachedPlan = planCache.get(query: query) {
            logger.debug("Plan cache hit", metadata: [
                "recordType": "\(recordTypeName)"
            ])
            return cachedPlan
        }

        logger.debug("Plan cache miss, generating new plan", metadata: [
            "recordType": "\(recordTypeName)"
        ])

        // Fetch table statistics
        let tableStats = try? await statisticsManager.getTableStatistics(recordType: recordTypeName)

        var basePlan: any TypedQueryPlan<Record>

        if let tableStats = tableStats, tableStats.rowCount > 0 {
            // Path 1: Cost-based optimization with statistics
            logger.debug("Using cost-based optimization (statistics available)")
            basePlan = try await planWithStatistics(query, tableStats: tableStats)
        } else {
            // Path 2: Heuristic-based optimization without statistics
            logger.info("Using heuristic optimization (no statistics)", metadata: [
                "recordType": "\(recordTypeName)",
                "recommendation": "Run: StatisticsManager.collectStatistics(recordType: \"\(recordTypeName)\")"
            ])
            basePlan = try await planWithHeuristics(query)
        }

        // Add sort plan if needed
        let finalPlan = try addSortIfNeeded(plan: basePlan, query: query)

        // Estimate cost for caching
        let cost = try await costEstimator.estimateCost(finalPlan, recordType: recordTypeName)

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
                recordType: recordTypeName,
                sortKeys: query.sort,
                metaData: metaData
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

        // Rule 2: Any index match → likely better than full scan
        if let indexPlan = try findFirstIndexPlan(query.filter) {
            logger.debug("Selected first matching index plan (heuristic)", metadata: [
                "planType": "TypedIndexScanPlan"
            ])
            return indexPlan
        }

        // Rule 3: Fall back to full scan
        logger.debug("Selected full scan plan (heuristic fallback)", metadata: [
            "planType": "TypedFullScanPlan"
        ])

        return TypedFullScanPlan(
            filter: query.filter,
            expectedRecordType: recordTypeName
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
            expectedRecordType: recordTypeName
        ))

        // Heuristic pruning: if unique index on equality, skip others
        if config.enableHeuristicPruning,
           let uniquePlan = try findUniqueIndexPlan(query.filter) {
            logger.debug("Short-circuit: unique index on equality found")
            return [uniquePlan]
        }

        // Generate single-index plans
        let indexPlans = try await generateSingleIndexPlans(query)

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
        if candidates.count < config.maxCandidatePlans {
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

        return candidates
    }

    /// Generate single-index scan plans for all applicable indexes
    ///
    /// - Parameter query: The query to plan
    /// - Returns: Array of index scan plans
    /// - Throws: RecordLayerError if generation fails
    private func generateSingleIndexPlans(
        _ query: TypedRecordQuery<Record>
    ) async throws -> [any TypedQueryPlan<Record>] {
        guard let filter = query.filter else {
            return []
        }

        var indexPlans: [any TypedQueryPlan<Record>] = []

        let applicableIndexes = metaData.getIndexesForRecordType(recordTypeName)

        for index in applicableIndexes {
            if let plan = try matchFilterWithIndex(filter: filter, index: index) {
                indexPlans.append(plan)
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
                // Get primary key expression from record type
                do {
                    let recordType = try metaData.getRecordType(recordTypeName)
                    let unionPlan = TypedUnionPlan(childPlans: branchPlans, primaryKeyExpression: recordType.primaryKey)
                    multiIndexPlans.append(unionPlan)
                } catch {
                    logger.warning("Record type not found", metadata: ["recordType": "\(recordTypeName)"])
                    return multiIndexPlans
                }
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
        let applicableIndexes = metaData.getIndexesForRecordType(recordTypeName)

        for index in applicableIndexes {
            if let plan = try matchFilterWithIndex(filter: branch, index: index) {
                return plan
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
    private func generateIntersectionPlan(
        _ andFilter: TypedAndQueryComponent<Record>
    ) async throws -> (any TypedQueryPlan<Record>)? {
        // Extract field filters
        var fieldFilters: [TypedFieldQueryComponent<Record>] = []
        for child in andFilter.children {
            if let fieldFilter = child as? TypedFieldQueryComponent<Record> {
                fieldFilters.append(fieldFilter)
            }
        }

        // Need at least 2 field filters for intersection
        guard fieldFilters.count >= 2 else {
            return nil
        }

        // Try to find index for each field filter
        var childPlans: [any TypedQueryPlan<Record>] = []
        let applicableIndexes = metaData.getIndexesForRecordType(recordTypeName)

        for fieldFilter in fieldFilters {
            // Find matching index
            var found = false
            for index in applicableIndexes {
                if let plan = try matchFilterWithIndex(filter: fieldFilter, index: index) {
                    childPlans.append(plan)
                    found = true
                    break
                }
            }

            if !found {
                // Cannot find index for this field, abort intersection
                return nil
            }
        }

        // Create intersection plan if we have at least 2 indexes
        if childPlans.count >= 2 {
            // Get primary key expression from record type
            do {
                let recordType = try metaData.getRecordType(recordTypeName)
                return TypedIntersectionPlan(childPlans: childPlans, primaryKeyExpression: recordType.primaryKey)
            } catch {
                logger.warning("Record type not found", metadata: ["recordType": "\(recordTypeName)"])
                return nil
            }
        }

        return nil
    }

    // MARK: - Index Matching

    /// Try to match a filter with a specific index
    ///
    /// Supports both simple and compound indexes with prefix matching.
    ///
    /// - Parameters:
    ///   - filter: The query filter
    ///   - index: The index to match against
    /// - Returns: Index scan plan if filter matches index, nil otherwise
    /// - Throws: RecordLayerError if matching fails
    private func matchFilterWithIndex(
        filter: any TypedQueryComponent<Record>,
        index: Index
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Try simple field filter first
        if let fieldFilter = filter as? TypedFieldQueryComponent<Record> {
            return try matchSimpleFilter(fieldFilter: fieldFilter, index: index)
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
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Check if index is on the same field (simple index)
        if let fieldExpr = index.rootExpression as? FieldKeyExpression {
            guard fieldExpr.fieldName == fieldFilter.fieldName else {
                return nil
            }

            // Generate key range for this comparison
            guard let (beginValues, endValues) = keyRange(for: fieldFilter) else {
                return nil
            }

            let primaryKeyLength = getPrimaryKeyLength()

            return TypedIndexScanPlan(
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                beginValues: beginValues,
                endValues: endValues,
                filter: fieldFilter,
                primaryKeyLength: primaryKeyLength
            )
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

            let primaryKeyLength = getPrimaryKeyLength()

            return TypedIndexScanPlan(
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                beginValues: beginValues,
                endValues: endValues,
                filter: fieldFilter,
                primaryKeyLength: primaryKeyLength
            )
        }

        return nil
    }

    /// Match an AND filter with a compound index
    private func matchCompoundFilter(
        andFilter: TypedAndQueryComponent<Record>,
        index: Index
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Only compound indexes can match AND filters
        guard let concatExpr = index.rootExpression as? ConcatenateKeyExpression else {
            return nil
        }

        // Extract field filters from AND children
        var fieldFilters: [TypedFieldQueryComponent<Record>] = []
        for child in andFilter.children {
            if let fieldFilter = child as? TypedFieldQueryComponent<Record> {
                fieldFilters.append(fieldFilter)
            } else {
                // Complex child (nested AND/OR) not supported for compound matching
                return nil
            }
        }

        // Try to match field filters with index fields in order
        var matchedFields: [TypedFieldQueryComponent<Record>] = []
        var unmatchedFilters: [any TypedQueryComponent<Record>] = []

        for (i, indexField) in concatExpr.children.enumerated() {
            guard let fieldExpr = indexField as? FieldKeyExpression else {
                break
            }

            // Find matching filter for this index field
            if let matchingFilter = fieldFilters.first(where: { $0.fieldName == fieldExpr.fieldName }) {
                matchedFields.append(matchingFilter)

                // Range comparison allowed only on last matched field
                if i < concatExpr.children.count - 1 && !matchingFilter.comparison.isEquality {
                    // Range on non-last field: stop matching
                    break
                }
            } else {
                // No filter for this index field: stop prefix matching
                break
            }
        }

        // Must match at least one field
        guard !matchedFields.isEmpty else {
            return nil
        }

        // Collect unmatched filters for post-filtering
        let matchedFieldNames = Set(matchedFields.map { $0.fieldName })
        for filter in fieldFilters {
            if !matchedFieldNames.contains(filter.fieldName) {
                unmatchedFilters.append(filter)
            }
        }

        // Build key range from matched fields
        var beginValues: [any TupleElement] = []
        var endValues: [any TupleElement] = []

        for (i, matchedFilter) in matchedFields.enumerated() {
            let isLastMatched = (i == matchedFields.count - 1)

            if matchedFilter.comparison.isEquality {
                // Equality: add exact value to both begin and end
                beginValues.append(matchedFilter.value)
                endValues.append(matchedFilter.value)
            } else if isLastMatched {
                // Range on last matched field
                guard let (rangeBegin, rangeEnd) = rangeValues(for: matchedFilter) else {
                    // rangeValues returns nil when boundary computation failed
                    // (e.g., age > Int64.max, score <= Int64.max).
                    // In this case, we cannot use the index optimization.
                    // Return nil to fall back to full scan or other optimization strategies.
                    logger.debug("Cannot compute safe range boundary for compound index", metadata: [
                        "index": "\(index.name)",
                        "field": "\(matchedFilter.fieldName)",
                        "comparison": "\(matchedFilter.comparison)"
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

        // Create combined filter for unmatched fields
        let combinedFilter: (any TypedQueryComponent<Record>)? = unmatchedFilters.isEmpty ? nil :
            (unmatchedFilters.count == 1 ? unmatchedFilters[0] :
                TypedAndQueryComponent(children: unmatchedFilters))

        let primaryKeyLength = getPrimaryKeyLength()

        return TypedIndexScanPlan(
            indexName: index.name,
            indexSubspaceTupleKey: index.subspaceTupleKey,
            beginValues: beginValues,
            endValues: endValues,
            filter: combinedFilter,
            primaryKeyLength: primaryKeyLength
        )
    }

    /// Generate key range for a field filter
    ///
    /// FoundationDB Range API:
    /// - beginSelector: .firstGreaterOrEqual(beginKey) → beginKey 以上（inclusive）
    /// - endSelector: .firstGreaterThan(endKey) → endKey より大きい（exclusive）
    /// Result: [beginKey, endKey) の半開区間
    ///
    /// For <= and >: 値を調整して inclusive/exclusive を正しく表現
    ///
    /// **CRITICAL**: Returns `nil` if boundary values cannot be safely computed.
    /// This prevents incorrect results at max/min values (e.g., `age > Int64.max`).
    private func keyRange(
        for fieldFilter: TypedFieldQueryComponent<Record>
    ) -> ([any TupleElement], [any TupleElement])? {
        switch fieldFilter.comparison {
        case .equals:
            // [value, value] with .firstGreaterOrEqual and .firstGreaterThan
            // → value だけを含む
            return ([fieldFilter.value], [fieldFilter.value])

        case .notEquals:
            return nil // Cannot optimize with index scan

        case .lessThan:
            // [min, value) with empty begin and .firstGreaterThan(value)
            // → value を含まない
            return ([], [fieldFilter.value])

        case .lessThanOrEquals:
            // [min, value] を実現するには endKey を value の次の値にする
            // .firstGreaterThan(nextValue) → value を含む
            //
            // If nextValue cannot be computed (e.g., value == Int64.max),
            // return nil to fall back to full scan
            guard let nextValue = nextTupleValue(fieldFilter.value) else {
                return nil
            }
            return ([], [nextValue])

        case .greaterThan:
            // (value, max] を実現するには beginKey を value の次の値にする
            // .firstGreaterOrEqual(nextValue) → value を含まない
            //
            // If nextValue cannot be computed (e.g., value == Int64.max),
            // return nil to indicate empty result set
            guard let nextValue = nextTupleValue(fieldFilter.value) else {
                return nil
            }
            return ([nextValue], [])

        case .greaterThanOrEquals:
            // [value, max] with .firstGreaterOrEqual(value)
            // → value を含む
            return ([fieldFilter.value], [])

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
            // <= の場合: endKey を value の次の値にする
            // If nextValue cannot be computed (e.g., Int64.max), return nil
            // to abort index optimization instead of creating incorrect full scan
            guard let nextValue = nextTupleValue(fieldFilter.value) else {
                return nil
            }
            return ([], [nextValue])

        case .greaterThan:
            // > の場合: beginKey を value の次の値にする
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

        let applicableIndexes = metaData.getIndexesForRecordType(recordTypeName)

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
                primaryKeyLength: getPrimaryKeyLength()
            )
        }

        return nil
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

        let applicableIndexes = metaData.getIndexesForRecordType(recordTypeName)

        for index in applicableIndexes {
            if let plan = try matchFilterWithIndex(filter: filter, index: index) {
                return plan
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
        guard let index = metaData.getIndexesForRecordType(recordTypeName)
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

            // Note: We assume ascending order for now
            // TODO: Support descending indexes
            guard sortKey.ascending else {
                return false // Descending not yet supported
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

        default:
            // Unknown type: cannot safely increment
            return nil
        }
    }

    private func getPrimaryKeyLength() -> Int {
        do {
            let recordType = try metaData.getRecordType(recordTypeName)

            if let concatExpr = recordType.primaryKey as? ConcatenateKeyExpression {
                return concatExpr.children.count
            } else {
                return 1
            }
        } catch {
            return 1  // Fallback to single-field primary key
        }
    }
}
