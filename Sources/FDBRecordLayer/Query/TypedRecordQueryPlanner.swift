import Foundation
import FoundationDB

/// Query planner that chooses the best execution plan for a typed query
///
/// The TypedRecordQueryPlanner analyzes a TypedRecordQuery and selects the most
/// efficient execution plan based on available indexes and query filters.
///
/// **Planning Strategy:**
/// 1. Check if query filter can use an index
/// 2. If yes, create TypedIndexScanPlan
/// 3. If no, create TypedFullScanPlan
/// 4. Wrap with TypedLimitPlan if limit is specified
public struct TypedRecordQueryPlanner<Record: Sendable> {
    private let metaData: RecordMetaData
    private let recordTypeName: String

    /// Initialize query planner
    ///
    /// - Parameters:
    ///   - metaData: Record metadata containing index definitions
    ///   - recordTypeName: The record type being queried
    public init(metaData: RecordMetaData, recordTypeName: String) {
        self.metaData = metaData
        self.recordTypeName = recordTypeName
    }

    /// Plan query execution
    ///
    /// - Parameter query: The typed query to plan
    /// - Returns: The optimal execution plan
    public func plan(query: TypedRecordQuery<Record>) throws -> any TypedQueryPlan<Record> {
        var basePlan: any TypedQueryPlan<Record>

        // Try to find an index that can satisfy the filter
        if let indexPlan = try planIndexScan(filter: query.filter) {
            basePlan = indexPlan
        } else {
            // Fall back to full scan
            basePlan = TypedFullScanPlan(
                filter: query.filter,
                expectedRecordType: recordTypeName
            )
        }

        // Wrap with limit if specified
        if let limit = query.limit {
            basePlan = TypedLimitPlan(child: basePlan, limit: limit)
        }

        return basePlan
    }

    /// Try to create an index scan plan for the given filter
    ///
    /// - Parameter filter: The query filter
    /// - Returns: Index scan plan if a suitable index exists, nil otherwise
    private func planIndexScan(
        filter: (any TypedQueryComponent<Record>)?
    ) throws -> (any TypedQueryPlan<Record>)? {
        guard let filter = filter else {
            return nil
        }

        // Get the record type
        let recordType = try metaData.getRecordType(recordTypeName)

        // Get indexes that apply to this record type
        let applicableIndexes = metaData.getIndexesForRecordType(recordTypeName)

        // Try to match filter with available indexes
        for index in applicableIndexes {
            // Try to match filter with index
            if let plan = try matchFilterWithIndex(
                filter: filter,
                index: index,
                recordType: recordType
            ) {
                return plan
            }
        }

        return nil
    }

    /// Try to match a filter with a specific index
    ///
    /// - Parameters:
    ///   - filter: The query filter
    ///   - index: The index to match against
    ///   - recordType: The record type
    /// - Returns: Index scan plan if filter matches index, nil otherwise
    private func matchFilterWithIndex(
        filter: any TypedQueryComponent<Record>,
        index: Index,
        recordType: RecordType
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Only handle simple field comparisons for now
        // TODO: Support AND, OR, complex expressions
        guard let fieldFilter = filter as? TypedFieldQueryComponent<Record> else {
            return nil
        }

        // Check if index is on the same field
        guard let fieldExpr = index.rootExpression as? FieldKeyExpression else {
            return nil
        }

        guard fieldExpr.fieldName == fieldFilter.fieldName else {
            return nil
        }

        // Determine key range based on comparison type
        let (beginValues, endValues): ([any TupleElement], [any TupleElement])

        switch fieldFilter.comparison {
        case .equals:
            // Equals: scan from [value] to [value]
            beginValues = [fieldFilter.value]
            endValues = [fieldFilter.value]

        case .notEquals:
            // Not equals: cannot optimize with single index scan
            return nil

        case .lessThan:
            // Less than: scan from beginning to [value)
            beginValues = []
            endValues = [fieldFilter.value]

        case .lessThanOrEquals:
            // Less than or equals: scan from beginning to [value]
            beginValues = []
            endValues = [fieldFilter.value]

        case .greaterThan:
            // Greater than: scan from (value] to end
            // FDB doesn't have exclusive start, so we use value and skip it in filter
            beginValues = [fieldFilter.value]
            endValues = []

        case .greaterThanOrEquals:
            // Greater than or equals: scan from [value] to end
            beginValues = [fieldFilter.value]
            endValues = []

        case .startsWith, .contains:
            // String operations: not optimized yet
            return nil
        }

        // Get primary key length for extracting primary keys from index entries
        let primaryKeyLength: Int
        if let concatExpr = recordType.primaryKey as? ConcatenateKeyExpression {
            primaryKeyLength = concatExpr.children.count
        } else {
            primaryKeyLength = 1
        }

        // Create index scan plan
        let plan = TypedIndexScanPlan(
            indexName: index.name,
            indexSubspaceTupleKey: index.name,
            beginValues: beginValues,
            endValues: endValues,
            filter: filter,  // Still need filter for exact comparisons
            primaryKeyLength: primaryKeyLength
        )

        return plan
    }
}
