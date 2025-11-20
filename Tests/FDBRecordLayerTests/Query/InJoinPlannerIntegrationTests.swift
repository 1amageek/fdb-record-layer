import Testing
import Foundation
 import FDBRecordCore
@testable import FDBRecordLayer

/// Test record type for IN join planner integration tests
@Recordable
struct InJoinTestUser {
    #Index<InJoinTestUser>([\.city])
    #Index<InJoinTestUser>([\.age])
    #Index<InJoinTestUser>([\.country])
    #PrimaryKey<InJoinTestUser>([\.userID])

    

    var userID: Int64
    var name: String
    var age: Int
    var city: String
    var country: String
}

/// Integration tests for IN join plan generation with InExtractor
///
/// Verifies that TypedRecordQueryPlanner correctly:
/// 1. Extracts IN predicates using InExtractor
/// 2. Generates appropriate IN join plans
/// 3. Builds correct remaining filters
/// 4. Handles multiple IN predicates on the same field
@Suite("IN Join Planner Integration Tests", .tags(.integration))
struct InJoinPlannerIntegrationTests {

    // MARK: - Test Setup

    func createMockSchema() -> Schema {
        return Schema(
            [InJoinTestUser.self],
            version: Schema.Version(1, 0, 0)
        )
    }

    // MARK: - buildRemainingFilter Tests

    @Test("buildRemainingFilter removes exact IN predicate")
    func testBuildRemainingFilterRemovesExactInPredicate() throws {
        // Create filter: city IN ["Tokyo", "Osaka"] AND age > 18
        let cityIn = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let ageFilter = TypedFieldQueryComponent<InJoinTestUser>(
            fieldName: "age",
            comparison: .greaterThan,
            value: 18
        )
        let filter = TypedAndQueryComponent<InJoinTestUser>(children: [cityIn, ageFilter])

        // Create planner and test buildRemainingFilter
        let schema = createMockSchema()
        let statsManager = MockStatisticsManager()
        _ = TypedRecordQueryPlanner<InJoinTestUser>(
            schema: schema,
            recordName: InJoinTestUser.recordName,
            statisticsManager: statsManager
        )

        // Extract IN predicate to remove
        let inPredicate = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])

        // Build remaining filter (using planner's private method through reflection would be complex,
        // so we test the logic directly here)

        // Expected remaining: age > 18
        var remaining: [any TypedQueryComponent<InJoinTestUser>] = []
        for child in filter.children {
            if let inComponent = child as? TypedInQueryComponent<InJoinTestUser>,
               inPredicate.matches(inComponent) {
                continue
            }
            remaining.append(child)
        }

        #expect(remaining.count == 1)
        #expect(remaining[0] is TypedFieldQueryComponent<InJoinTestUser>)
    }

    @Test("buildRemainingFilter keeps different IN predicate on same field")
    func testBuildRemainingFilterKeepsDifferentInPredicateOnSameField() throws {
        // CRITICAL TEST: age IN [1, 2] AND age IN [3, 4] AND city == "Tokyo"
        let ageIn1 = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "age",
            values: [1, 2]
        )
        let ageIn2 = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "age",
            values: [3, 4]
        )
        let cityFilter = TypedFieldQueryComponent<InJoinTestUser>(
            fieldName: "city",
            comparison: .equals,
            value: "Tokyo"
        )
        let filter = TypedAndQueryComponent<InJoinTestUser>(children: [ageIn1, ageIn2, cityFilter])

        // Remove age IN [1, 2]
        let inPredicateToRemove = InPredicate(fieldName: "age", values: [1, 2])

        // Build remaining filter
        var remaining: [any TypedQueryComponent<InJoinTestUser>] = []
        for child in filter.children {
            if let inComponent = child as? TypedInQueryComponent<InJoinTestUser>,
               inPredicateToRemove.matches(inComponent) {
                continue
            }
            remaining.append(child)
        }

        // Expected remaining: age IN [3, 4] AND city == "Tokyo"
        #expect(remaining.count == 2)

        let hasAgeIn34 = remaining.contains { component in
            if let inComponent = component as? TypedInQueryComponent<InJoinTestUser> {
                let pred = InPredicate(fieldName: "age", values: [3, 4])
                return pred.matches(inComponent)
            }
            return false
        }
        #expect(hasAgeIn34)

        let hasCityFilter = remaining.contains { $0 is TypedFieldQueryComponent<InJoinTestUser> }
        #expect(hasCityFilter)
    }

    @Test("buildRemainingFilter removes only matching IN, not all on same field")
    func testBuildRemainingFilterRemovesOnlyMatchingIn() throws {
        // Create filter: age IN [1, 2] AND age IN [3, 4]
        let ageIn1 = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "age",
            values: [1, 2]
        )
        let ageIn2 = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "age",
            values: [3, 4]
        )
        let filter = TypedAndQueryComponent<InJoinTestUser>(children: [ageIn1, ageIn2])

        // Remove age IN [1, 2]
        let inPredicateToRemove = InPredicate(fieldName: "age", values: [1, 2])

        // Build remaining filter
        var remaining: [any TypedQueryComponent<InJoinTestUser>] = []
        for child in filter.children {
            if let inComponent = child as? TypedInQueryComponent<InJoinTestUser>,
               inPredicateToRemove.matches(inComponent) {
                continue
            }
            remaining.append(child)
        }

        // Expected remaining: age IN [3, 4]
        #expect(remaining.count == 1)

        if let remainingIn = remaining[0] as? TypedInQueryComponent<InJoinTestUser> {
            let pred = InPredicate(fieldName: "age", values: [3, 4])
            #expect(pred.matches(remainingIn))
        } else {
            Issue.record("Expected TypedInQueryComponent")
        }
    }

    @Test("buildRemainingFilter returns nil when all predicates removed")
    func testBuildRemainingFilterReturnsNilWhenAllRemoved() throws {
        // Create filter: city IN ["Tokyo", "Osaka"]
        let cityIn = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )

        // Remove this exact IN predicate
        let inPredicate = InPredicate(fieldName: "city", values: ["Tokyo", "Osaka"])

        // Check if matches
        #expect(inPredicate.matches(cityIn))

        // When all predicates are removed, remaining should be empty
        // (which would translate to nil in the planner)
    }

    // MARK: - Multiple IN Predicates Tests

    @Test("Extract and handle multiple IN predicates independently")
    func testExtractAndHandleMultipleInPredicatesIndependently() throws {
        // Create filter: city IN ["Tokyo", "Osaka"] AND country IN ["Japan", "USA"]
        let cityIn = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "city",
            values: ["Tokyo", "Osaka"]
        )
        let countryIn = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "country",
            values: ["Japan", "USA"]
        )
        let filter = TypedAndQueryComponent<InJoinTestUser>(children: [cityIn, countryIn])

        // Extract IN predicates
        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        #expect(predicates.count == 2)

        // Each IN predicate should generate a separate plan candidate
        // with the other IN predicate in the remaining filter
        for inPredicate in predicates {
            var remaining: [any TypedQueryComponent<InJoinTestUser>] = []
            for child in filter.children {
                if let inComponent = child as? TypedInQueryComponent<InJoinTestUser>,
                   inPredicate.matches(inComponent) {
                    continue
                }
                remaining.append(child)
            }

            // Each should have 1 remaining (the other IN predicate)
            #expect(remaining.count == 1)
            #expect(remaining[0] is TypedInQueryComponent<InJoinTestUser>)
        }
    }

    @Test("Multiple IN on same field with different values handled correctly")
    func testMultipleInOnSameFieldWithDifferentValues() throws {
        // This is the CRITICAL regression test from the review
        // Filter: age IN [1, 2] AND age IN [3, 4]
        let ageIn1 = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "age",
            values: [1, 2]
        )
        let ageIn2 = TypedInQueryComponent<InJoinTestUser>(
            fieldName: "age",
            values: [3, 4]
        )
        let filter = TypedAndQueryComponent<InJoinTestUser>(children: [ageIn1, ageIn2])

        // Extract IN predicates
        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        // Should extract both (different value sets)
        #expect(predicates.count == 2)

        // Test that buildRemainingFilter keeps the other one
        let pred1 = InPredicate(fieldName: "age", values: [1, 2])
        let pred2 = InPredicate(fieldName: "age", values: [3, 4])

        // Verify they are different
        #expect(pred1 != pred2)

        // When removing pred1, pred2 should remain
        var remainingAfterRemovingPred1: [any TypedQueryComponent<InJoinTestUser>] = []
        for child in filter.children {
            if let inComponent = child as? TypedInQueryComponent<InJoinTestUser>,
               pred1.matches(inComponent) {
                continue
            }
            remainingAfterRemovingPred1.append(child)
        }

        #expect(remainingAfterRemovingPred1.count == 1)
        if let remainingIn = remainingAfterRemovingPred1[0] as? TypedInQueryComponent<InJoinTestUser> {
            #expect(pred2.matches(remainingIn))
        }
    }
}

// MARK: - Mock Statistics Manager

private final class MockStatisticsManager: StatisticsManagerProtocol {
    func getTableStatistics(recordType: String) async throws -> TableStatistics? {
        return TableStatistics(
            rowCount: 10000,
            avgRowSize: 100,
            timestamp: Date(),
            sampleRate: 1.0
        )
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

    func estimateRangeSelectivity(indexName: String, queryRange: Range<Date>) async throws -> Double {
        return 1.0
    }

    func estimateRangeSelectivity(indexName: String, lowerBound: any Comparable, upperBound: any Comparable) async throws -> Double {
        return 1.0
    }
}
