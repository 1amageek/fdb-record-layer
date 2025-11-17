import Testing
import Foundation
@testable import FDBRecordLayer

/// Test record type for end-to-end tests
@Recordable
struct E2EProduct {
    #Index<E2EProduct>([\.category])
    #Index<E2EProduct>([\.price])
    #Index<E2EProduct>([\.region])
    #PrimaryKey<E2EProduct>([\.productID])

    

    var productID: Int64
    var name: String
    var category: String
    var price: Int
    var region: String
}

/// End-to-end tests for IN join plan generation
///
/// Verifies that TypedRecordQueryPlanner:
/// 1. Detects IN predicates using InExtractor
/// 2. Generates TypedInJoinPlan for IN queries
/// 3. Builds correct remaining filters
/// 4. Handles multiple IN predicates on the same field correctly
@Suite("IN Join Planner End-to-End Tests", .tags(.e2e, .slow))
struct InJoinPlannerEndToEndTests {

    // MARK: - Helper Methods

    func createSchema() -> Schema {
        return Schema(
            [E2EProduct.self],
            version: Schema.Version(1, 0, 0)
        )
    }

    func createPlanner() -> TypedRecordQueryPlanner<E2EProduct> {
        let schema = createSchema()
        let statsManager = MockStatisticsManager()
        return TypedRecordQueryPlanner<E2EProduct>(
            schema: schema,
            recordName: E2EProduct.recordName,
            statisticsManager: statsManager
        )
    }

    // MARK: - End-to-End Tests

    @Test("Planner generates InJoinPlan for single IN predicate")
    func testPlannerGeneratesInJoinPlanForSingleIn() async throws {
        let planner = createPlanner()

        // Query: category IN ["Electronics", "Books"]
        let query = TypedRecordQuery<E2EProduct>(
            filter: TypedInQueryComponent<E2EProduct>(
                fieldName: "category",
                values: ["Electronics", "Books"]
            )
        )

        let plan = try await planner.plan(query: query)

        // Verify plan is InJoinPlan (no remaining filter, so not wrapped in FilterPlan)
        #expect(plan is TypedInJoinPlan<E2EProduct>, "Expected TypedInJoinPlan for IN query")

        if let inJoinPlan = plan as? TypedInJoinPlan<E2EProduct> {
            // Verify field name
            #expect(inJoinPlan.fieldName == "category")

            // Verify IN values
            #expect(inJoinPlan.values.count == 2)

            // Verify index name
            #expect(inJoinPlan.indexName.contains("category"))
        }
    }

    @Test("Planner generates InJoinPlan with remaining filter")
    func testPlannerGeneratesInJoinPlanWithRemainingFilter() async throws {
        let planner = createPlanner()

        // Query: category IN ["Electronics", "Books"] AND price > 1000
        let categoryIn = TypedInQueryComponent<E2EProduct>(
            fieldName: "category",
            values: ["Electronics", "Books"]
        )
        let priceFilter = TypedFieldQueryComponent<E2EProduct>(
            fieldName: "price",
            comparison: .greaterThan,
            value: 1000
        )
        let query = TypedRecordQuery<E2EProduct>(
            filter: TypedAndQueryComponent<E2EProduct>(children: [categoryIn, priceFilter])
        )

        let plan = try await planner.plan(query: query)

        // Verify plan is FilterPlan wrapping InJoinPlan
        #expect(
            plan is TypedFilterPlan<E2EProduct>,
            "Expected TypedFilterPlan wrapping InJoinPlan"
        )

        if let filterPlan = plan as? TypedFilterPlan<E2EProduct> {
            // Verify child is InJoinPlan
            #expect(
                filterPlan.child is TypedInJoinPlan<E2EProduct>,
                "Child should be TypedInJoinPlan"
            )

            if let inJoinPlan = filterPlan.child as? TypedInJoinPlan<E2EProduct> {
                // Verify IN values
                #expect(inJoinPlan.values.count == 2)
                #expect(inJoinPlan.fieldName == "category")
            }

            // Verify remaining filter exists (price > 1000)
            #expect(
                filterPlan.filter is TypedFieldQueryComponent<E2EProduct>,
                "Remaining filter should be price comparison"
            )
        }
    }

    @Test("Planner handles multiple IN on same field with different values")
    func testPlannerHandlesMultipleInOnSameFieldCorrectly() async throws {
        let planner = createPlanner()

        // CRITICAL TEST: price IN [100, 200] AND price IN [300, 400]
        let priceIn1 = TypedInQueryComponent<E2EProduct>(
            fieldName: "price",
            values: [100, 200]
        )
        let priceIn2 = TypedInQueryComponent<E2EProduct>(
            fieldName: "price",
            values: [300, 400]
        )
        let query = TypedRecordQuery<E2EProduct>(
            filter: TypedAndQueryComponent<E2EProduct>(children: [priceIn1, priceIn2])
        )

        let plan = try await planner.plan(query: query)

        // Planner should generate FilterPlan wrapping InJoinPlan
        #expect(
            plan is TypedFilterPlan<E2EProduct>,
            "Expected TypedFilterPlan wrapping InJoinPlan"
        )

        if let filterPlan = plan as? TypedFilterPlan<E2EProduct> {
            // Verify child is InJoinPlan
            #expect(
                filterPlan.child is TypedInJoinPlan<E2EProduct>,
                "Child should be TypedInJoinPlan"
            )

            if let inJoinPlan = filterPlan.child as? TypedInJoinPlan<E2EProduct> {
                // One IN should be used for index scan
                #expect(inJoinPlan.values.count == 2)
                #expect(inJoinPlan.fieldName == "price")
            }

            // The other IN should remain in the filter
            #expect(
                filterPlan.filter is TypedInQueryComponent<E2EProduct>,
                "Remaining filter should be other IN predicate"
            )

            if let remainingIn = filterPlan.filter as? TypedInQueryComponent<E2EProduct> {
                #expect(remainingIn.fieldName == "price")
                #expect(remainingIn.values.count == 2)

                // Verify it's the OTHER IN predicate (not the one used for index scan)
                if let inJoinPlan = filterPlan.child as? TypedInJoinPlan<E2EProduct> {
                    let usedValues = inJoinPlan.values
                    let remainingValues = remainingIn.values

                    // They should be different value sets
                    let usedSet = Set(usedValues.map { String(describing: $0) })
                    let remainingSet = Set(remainingValues.map { String(describing: $0) })
                    #expect(usedSet != remainingSet, "Should use different IN predicates")
                }
            }
        }
    }

    @Test("Planner handles multiple IN on different fields")
    func testPlannerHandlesMultipleInOnDifferentFields() async throws {
        let planner = createPlanner()

        // Query: category IN ["Electronics"] AND region IN ["East", "West"]
        let categoryIn = TypedInQueryComponent<E2EProduct>(
            fieldName: "category",
            values: ["Electronics"]
        )
        let regionIn = TypedInQueryComponent<E2EProduct>(
            fieldName: "region",
            values: ["East", "West"]
        )
        let query = TypedRecordQuery<E2EProduct>(
            filter: TypedAndQueryComponent<E2EProduct>(children: [categoryIn, regionIn])
        )

        let plan = try await planner.plan(query: query)

        // Planner should generate FilterPlan wrapping InJoinPlan
        #expect(
            plan is TypedFilterPlan<E2EProduct>,
            "Expected TypedFilterPlan wrapping InJoinPlan"
        )

        if let filterPlan = plan as? TypedFilterPlan<E2EProduct> {
            // Verify child is InJoinPlan
            #expect(
                filterPlan.child is TypedInJoinPlan<E2EProduct>,
                "Child should be TypedInJoinPlan"
            )

            // Other IN should remain in filter
            #expect(
                filterPlan.filter is TypedInQueryComponent<E2EProduct>,
                "Remaining filter should be other IN predicate"
            )
        }
    }

    @Test("Planner generates InJoinPlan for complex filter")
    func testPlannerGeneratesInJoinPlanForComplexFilter() async throws {
        let planner = createPlanner()

        // Query: category IN ["Electronics", "Books"] AND price > 1000 AND region == "East"
        let categoryIn = TypedInQueryComponent<E2EProduct>(
            fieldName: "category",
            values: ["Electronics", "Books"]
        )
        let priceFilter = TypedFieldQueryComponent<E2EProduct>(
            fieldName: "price",
            comparison: .greaterThan,
            value: 1000
        )
        let regionFilter = TypedFieldQueryComponent<E2EProduct>(
            fieldName: "region",
            comparison: .equals,
            value: "East"
        )
        let query = TypedRecordQuery<E2EProduct>(
            filter: TypedAndQueryComponent<E2EProduct>(
                children: [categoryIn, priceFilter, regionFilter]
            )
        )

        let plan = try await planner.plan(query: query)

        // Verify plan is FilterPlan wrapping InJoinPlan
        #expect(
            plan is TypedFilterPlan<E2EProduct>,
            "Expected TypedFilterPlan wrapping InJoinPlan"
        )

        if let filterPlan = plan as? TypedFilterPlan<E2EProduct> {
            // Verify child is InJoinPlan
            #expect(
                filterPlan.child is TypedInJoinPlan<E2EProduct>,
                "Child should be TypedInJoinPlan"
            )

            if let inJoinPlan = filterPlan.child as? TypedInJoinPlan<E2EProduct> {
                // Verify IN values
                #expect(inJoinPlan.values.count == 2)
                #expect(inJoinPlan.fieldName == "category")
            }

            // Verify remaining filter exists (price > 1000 AND region == "East")
            #expect(
                filterPlan.filter is TypedAndQueryComponent<E2EProduct>,
                "Remaining filter should be AND of two conditions"
            )

            if let andFilter = filterPlan.filter as? TypedAndQueryComponent<E2EProduct> {
                #expect(andFilter.children.count == 2)
            }
        }
    }

    @Test("InExtractor correctly extracts IN from nested filters")
    func testInExtractorExtractsFromNestedFilters() async throws {
        // Query: (category IN ["Electronics"] AND price > 1000) AND region IN ["East"]
        let categoryIn = TypedInQueryComponent<E2EProduct>(
            fieldName: "category",
            values: ["Electronics"]
        )
        let priceFilter = TypedFieldQueryComponent<E2EProduct>(
            fieldName: "price",
            comparison: .greaterThan,
            value: 1000
        )
        let innerAnd = TypedAndQueryComponent<E2EProduct>(children: [categoryIn, priceFilter])

        let regionIn = TypedInQueryComponent<E2EProduct>(
            fieldName: "region",
            values: ["East"]
        )
        let outerAnd = TypedAndQueryComponent<E2EProduct>(children: [innerAnd, regionIn])

        // Extract IN predicates
        var extractor = InExtractor()
        try extractor.visit(outerAnd)

        let predicates = extractor.extractedInPredicates()

        // Should extract both IN predicates from nested structure
        #expect(predicates.count == 2)

        let categoryPredicate = predicates.first { $0.fieldName == "category" }
        let regionPredicate = predicates.first { $0.fieldName == "region" }

        #expect(categoryPredicate != nil, "Should extract category IN")
        #expect(regionPredicate != nil, "Should extract region IN")
    }
}

// MARK: - Mock Statistics Manager

private final class MockStatisticsManager: StatisticsManagerProtocol {
    func getTableStatistics(recordType: String) async throws -> TableStatistics? {
        // Return nil to force heuristic-based planning (IN join plan selection)
        return nil
    }

    func getIndexStatistics(indexName: String) async throws -> IndexStatistics? {
        return nil
    }

    func getRangeStatistics(indexName: String) async throws -> RangeIndexStatistics? {
        return nil
    }

    func estimateSelectivity<Record: Sendable>(
        filter: any TypedQueryComponent<Record>,
        recordType: String
    ) async throws -> Double {
        return 0.1
    }
}
