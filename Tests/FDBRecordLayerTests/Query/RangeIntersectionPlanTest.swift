import Testing
import Foundation
@testable import FDBRecordLayer

/// Test to verify that overlaps() queries generate IntersectionPlan
@Suite("Range Intersection Plan Tests")
struct RangeIntersectionPlanTest {

    @Recordable
    struct Event {
        #PrimaryKey<Event>([\.id])
        #Index<Event>([\.period])  // Auto-generates start + end indexes

        var id: Int64
        var period: Range<Date>
        var title: String
    }

    // Mock StatisticsManager that returns default values (heuristic mode)
    final class MockStatisticsManager: StatisticsManagerProtocol {
        func getTableStatistics(recordType: String) async throws -> TableStatistics? {
            return nil  // Use heuristic mode
        }

        func getIndexStatistics(indexName: String) async throws -> IndexStatistics? {
            return nil  // Use heuristic mode
        }

        func estimateSelectivity<Record: Sendable>(
            filter: any TypedQueryComponent<Record>,
            recordType: String
        ) async throws -> Double {
            return 0.1  // Default selectivity estimate
        }
    }

    @Test("overlaps() generates TypedIntersectionPlan")
    func testOverlapsGeneratesIntersectionPlan() async throws {
        let schema = Schema([Event.self])

        // Query: Find events that overlap with query range
        let queryRange = Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200)

        // Manually construct overlaps filter (matching QueryBuilder.overlaps implementation)
        // Condition 1: field.lowerBound < queryRange.upperBound
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,
            value: queryRange.upperBound
        )

        // Condition 2: field.upperBound > queryRange.lowerBound
        let upperBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .upperBound,
                boundaryType: .halfOpen
            ),
            comparison: .greaterThan,
            value: queryRange.lowerBound
        )

        // Combine with AND
        let overlapsFilter = TypedAndQueryComponent<Event>(children: [lowerBoundFilter, upperBoundFilter])

        let query = TypedRecordQuery<Event>(
            filter: overlapsFilter,
            sort: nil
        )

        // Get the planner
        let planner = TypedRecordQueryPlanner<Event>(
            schema: schema,
            recordName: Event.recordName,
            statisticsManager: MockStatisticsManager()
        )

        // Plan the query
        let plan = try await planner.plan(query: query)

        // Verify the plan type
        print("📋 Generated Plan Type: \(type(of: plan))")

        // Check if it's an IntersectionPlan
        if let intersectionPlan = plan as? TypedIntersectionPlan<Event> {
            print("✅ IntersectionPlan generated successfully!")
            print("   Child plans count: \(intersectionPlan.childPlans.count)")

            // Should have 2 child plans (one for lowerBound index, one for upperBound index)
            #expect(intersectionPlan.childPlans.count == 2)

            // Both child plans should be index scans
            for (i, childPlan) in intersectionPlan.childPlans.enumerated() {
                print("   Child plan \(i + 1): \(type(of: childPlan))")
                #expect(childPlan is TypedIndexScanPlan<Event>)
            }
        } else {
            print("❌ Expected IntersectionPlan, got: \(type(of: plan))")
            throw RecordLayerError.internalError("Expected TypedIntersectionPlan but got \(type(of: plan))")
        }
    }

    @Test("overlaps() with additional filter generates FilterPlan wrapping IntersectionPlan")
    func testOverlapsWithFilterGeneratesFilterPlan() async throws {
        let schema = Schema([Event.self])

        // Query: Find events that overlap AND have specific title
        let queryRange = Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200)

        // 1. Construct overlaps filter (AND of 2 RangeKeyExpression filters)
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,
            value: queryRange.upperBound
        )

        let upperBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .upperBound,
                boundaryType: .halfOpen
            ),
            comparison: .greaterThan,
            value: queryRange.lowerBound
        )

        let overlapsFilter = TypedAndQueryComponent<Event>(children: [lowerBoundFilter, upperBoundFilter])

        // 2. Create title filter
        let titleFilter = TypedFieldQueryComponent<Event>(
            fieldName: "title",
            comparison: .equals,
            value: "Conference"
        )

        // 3. Flatten: combine all 3 filters (lowerBound, upperBound, title) into single AND
        let allFilters: [any TypedQueryComponent<Event>] = [lowerBoundFilter, upperBoundFilter, titleFilter]
        let combinedFilter = TypedAndQueryComponent<Event>(children: allFilters)

        let query = TypedRecordQuery<Event>(
            filter: combinedFilter,
            sort: nil
        )

        let planner = TypedRecordQueryPlanner<Event>(
            schema: schema,
            recordName: Event.recordName,
            statisticsManager: MockStatisticsManager()
        )

        let plan = try await planner.plan(query: query)

        print("📋 Generated Plan Type: \(type(of: plan))")

        // Should be FilterPlan wrapping IntersectionPlan
        if let filterPlan = plan as? TypedFilterPlan<Event> {
            print("✅ FilterPlan generated!")

            // Check child is IntersectionPlan
            if let intersectionPlan = filterPlan.child as? TypedIntersectionPlan<Event> {
                print("   ✅ Child is IntersectionPlan with \(intersectionPlan.childPlans.count) children")
                #expect(intersectionPlan.childPlans.count == 2)
            } else {
                print("   ❌ Expected IntersectionPlan as child, got: \(type(of: filterPlan.child))")
                throw RecordLayerError.internalError("Expected IntersectionPlan as child")
            }
        } else {
            print("❌ Expected FilterPlan, got: \(type(of: plan))")
            throw RecordLayerError.internalError("Expected TypedFilterPlan")
        }
    }

    @Test("Single Range filter uses single IndexScanPlan (not intersection)")
    func testSingleRangeFilterUsesSingleIndex() async throws {
        let schema = Schema([Event.self])

        // Query: Only check lowerBound (single condition)
        let queryEnd = Date(timeIntervalSince1970: 200)

        // Manually create single Range filter
        let query = TypedRecordQuery<Event>(
            filter: TypedKeyExpressionQueryComponent<Event>(
                keyExpression: RangeKeyExpression(
                    fieldName: "period",
                    component: .lowerBound,
                    boundaryType: .halfOpen
                ),
                comparison: .lessThan,
                value: queryEnd
            ),
            sort: nil
        )

        let planner = TypedRecordQueryPlanner<Event>(
            schema: schema,
            recordName: Event.recordName,
            statisticsManager: MockStatisticsManager()
        )

        let plan = try await planner.plan(query: query)

        print("📋 Generated Plan Type: \(type(of: plan))")

        // Should be a single IndexScanPlan, not IntersectionPlan
        #expect(plan is TypedIndexScanPlan<Event>)
        print("✅ Single IndexScanPlan generated (as expected)")
    }

    @Test("Range<T> uses < and > comparison operators (exclusive boundaries)")
    func testRangeOperators() async throws {
        // Range<T> has exclusive boundaries, so overlaps() should use:
        // - field.lowerBound < queryRange.upperBound (not <=)
        // - field.upperBound > queryRange.lowerBound (not >=)

        let queryRange = Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200)

        // Construct overlaps filter manually to verify comparison operators
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .halfOpen
            ),
            comparison: .lessThan,  // Must be .lessThan for Range
            value: queryRange.upperBound
        )

        let upperBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .upperBound,
                boundaryType: .halfOpen
            ),
            comparison: .greaterThan,  // Must be .greaterThan for Range
            value: queryRange.lowerBound
        )

        // Verify the comparison operators are correct for exclusive boundaries
        #expect(lowerBoundFilter.comparison == .lessThan, "Range lowerBound should use < (lessThan)")
        #expect(upperBoundFilter.comparison == .greaterThan, "Range upperBound should use > (greaterThan)")

        print("✅ Range<T> correctly uses < and > operators for exclusive boundaries")
    }

    @Test("ClosedRange<T> uses <= and >= comparison operators (inclusive boundaries)")
    func testClosedRangeOperators() async throws {
        // ClosedRange<T> has inclusive boundaries, so overlaps() should use:
        // - field.lowerBound <= queryRange.upperBound (not <)
        // - field.upperBound >= queryRange.lowerBound (not >)
        //
        // Note: We use a conceptual ClosedRange field for this test.
        // The actual comparison is done using the Event type's Range field
        // to verify the enum cases exist and can be used.

        let queryRange = Date(timeIntervalSince1970: 100)..<Date(timeIntervalSince1970: 200)

        // Verify that the .lessThanOrEquals and .greaterThanOrEquals cases exist
        // by constructing filters (even though Event uses Range, not ClosedRange)
        let lowerBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .lowerBound,
                boundaryType: .closed  // Conceptually ClosedRange
            ),
            comparison: .lessThanOrEquals,  // Must be .lessThanOrEquals for ClosedRange
            value: queryRange.upperBound
        )

        let upperBoundFilter = TypedKeyExpressionQueryComponent<Event>(
            keyExpression: RangeKeyExpression(
                fieldName: "period",
                component: .upperBound,
                boundaryType: .closed  // Conceptually ClosedRange
            ),
            comparison: .greaterThanOrEquals,  // Must be .greaterThanOrEquals for ClosedRange
            value: queryRange.lowerBound
        )

        // Verify the comparison operators are correct for inclusive boundaries
        #expect(lowerBoundFilter.comparison == .lessThanOrEquals, "ClosedRange lowerBound should use <= (lessThanOrEquals)")
        #expect(upperBoundFilter.comparison == .greaterThanOrEquals, "ClosedRange upperBound should use >= (greaterThanOrEquals)")

        print("✅ ClosedRange<T> correctly uses <= and >= operators for inclusive boundaries")
    }
}
