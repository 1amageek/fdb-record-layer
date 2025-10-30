import Foundation

/// Type-safe query planner for generating execution plans
///
/// The planner analyzes queries and selects the most efficient execution strategy.
public struct TypedRecordQueryPlanner<Record: Sendable> {
    public let recordType: TypedRecordType<Record>
    public let indexes: [TypedIndex<Record>]

    public init(recordType: TypedRecordType<Record>, indexes: [TypedIndex<Record>]) {
        self.recordType = recordType
        self.indexes = indexes
    }

    /// Generate an execution plan for a query
    /// - Parameter query: The query to plan
    /// - Returns: The execution plan
    public func plan(_ query: TypedRecordQuery<Record>) throws -> any TypedQueryPlan<Record> {
        // Simplified planning logic
        // In a real implementation, this would be much more sophisticated

        var basePlan: any TypedQueryPlan<Record>

        // Try to find a usable index
        if let filter = query.filter,
           let indexPlan = try? planIndexScan(filter: filter) {
            basePlan = indexPlan
        } else {
            // Fall back to full scan
            basePlan = TypedFullScanPlan(filter: query.filter)
        }

        // Apply limit if specified
        if let limit = query.limit {
            basePlan = TypedLimitPlan(child: basePlan, limit: limit)
        }

        return basePlan
    }

    // MARK: - Private Methods

    /// Try to plan an index scan for a filter
    private func planIndexScan(filter: any TypedQueryComponent<Record>) throws -> (any TypedQueryPlan<Record>)? {
        // Try to match the filter to an available index
        // This is a simplified implementation

        // Check if filter is a field comparison
        if let fieldFilter = filter as? TypedFieldQueryComponent<Record> {
            // Try to find an index on this field
            for index in indexes where index.type == .value {
                // Check if the index root expression matches the field
                if let fieldExpr = index.rootExpression as? TypedFieldKeyExpression<Record>,
                   fieldExpr.fieldName == fieldFilter.fieldName {

                    // Build the index scan range based on the comparison
                    let (beginValues, endValues) = buildIndexRange(
                        fieldFilter: fieldFilter,
                        fieldExpr: fieldExpr
                    )

                    return TypedIndexScanPlan(
                        index: index,
                        beginValues: beginValues,
                        endValues: endValues,
                        filter: filter,
                        primaryKeyLength: recordType.primaryKey.columnCount
                    )
                }
            }
        }

        // Check if filter is an AND component
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // Try to find the best index for any of the children
            for child in andFilter.children {
                if let plan = try? planIndexScan(filter: child) {
                    // Use this index scan and keep the full AND filter
                    return plan
                }
            }
        }

        return nil
    }

    /// Build index scan range from a field filter
    private func buildIndexRange(
        fieldFilter: TypedFieldQueryComponent<Record>,
        fieldExpr: TypedFieldKeyExpression<Record>
    ) -> (beginValues: [any TupleElement], endValues: [any TupleElement]) {
        let value = fieldFilter.value

        switch fieldFilter.comparison {
        case .equals:
            // Exact match: [value, value]
            return ([value], [value])

        case .lessThan:
            // Range: [MIN, value)
            return ([], [value])

        case .lessThanOrEquals:
            // Range: [MIN, value]
            // For inclusive end, use value with max suffix
            if let strValue = value as? String {
                return ([], [strValue + "\u{FFFF}"])
            } else {
                return ([], [value])
            }

        case .greaterThan:
            // Range: (value, MAX]
            // For exclusive start, add suffix
            if let strValue = value as? String {
                return ([strValue + "\u{FFFF}"], ["\u{FFFF}"])
            } else if let intValue = value as? Int64 {
                return ([intValue + 1], [Int64.max])
            } else {
                return ([value], [Int64.max])
            }

        case .greaterThanOrEquals:
            // Range: [value, MAX]
            return ([value], [Int64.max])

        case .startsWith:
            // For strings: [prefix, prefix + '\xFF')
            if let strValue = value as? String {
                let endValue = strValue + "\u{FFFF}"
                return ([strValue], [endValue])
            }
            return ([], [Int64.max])

        case .notEquals, .contains:
            // These cannot use index effectively, return full range
            return ([], [Int64.max])
        }
    }

    /// Estimate the cost of a plan
    /// - Parameter plan: The plan to evaluate
    /// - Returns: Estimated cost (lower is better)
    func estimateCost(_ plan: any TypedQueryPlan<Record>) -> Double {
        // Simplified cost estimation
        // In a real implementation, this would use statistics

        if plan is TypedFullScanPlan<Record> {
            return 1000000.0 // Full scans are expensive
        } else if plan is TypedIndexScanPlan<Record> {
            return 100.0 // Index scans are much cheaper
        } else if let limitPlan = plan as? TypedLimitPlan<Record> {
            // Limit reduces the cost proportionally
            let childCost = estimateCost(limitPlan.child)
            let limitFactor = Double(limitPlan.limit) / 1000.0
            return childCost * limitFactor
        }

        return 1000.0 // Default cost
    }
}

