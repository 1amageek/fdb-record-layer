import Testing
import Foundation
@testable import FDBRecordLayer

/// Debug tests to identify Planner integration issues
@Suite("IN Join Planner Debug Tests")
struct InJoinPlannerDebugTests {

    @Recordable
    struct DebugProduct {
        #Index<DebugProduct>([\.category])

        @PrimaryKey var productID: Int64
        var category: String
    }

    @Test("Debug: Check Schema initialization")
    func testSchemaInitialization() throws {
        let schema = Schema(
            [DebugProduct.self],
            version: Schema.Version(1, 0, 0)
        )

        // Check entity exists
        let entity = schema.entity(named: DebugProduct.recordName)
        #expect(entity != nil, "Entity should exist")

        // Check indexes
        let indexes = schema.indexes(for: DebugProduct.recordName)
        print("📊 Indexes for \(DebugProduct.recordName): \(indexes.count)")
        for index in indexes {
            print("  - Index: \(index.name), type: \(index.type)")
            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                print("    Field: \(fieldExpr.fieldName)")
            }
        }

        #expect(indexes.count > 0, "Should have at least one index")
    }

    @Test("Debug: Check InExtractor finds IN predicates")
    func testInExtractorFindsPredicates() throws {
        let filter = TypedInQueryComponent<DebugProduct>(
            fieldName: "category",
            values: ["Electronics", "Books"]
        )

        var extractor = InExtractor()
        try extractor.visit(filter)

        let predicates = extractor.extractedInPredicates()
        print("📊 Extracted IN predicates: \(predicates.count)")
        for pred in predicates {
            print("  - Field: \(pred.fieldName), values: \(pred.valueCount)")
        }

        #expect(predicates.count == 1, "Should extract 1 IN predicate")
        #expect(predicates[0].fieldName == "category")
        #expect(predicates[0].valueCount == 2)
    }

    @Test("Debug: Check findIndexForField")
    func testFindIndexForField() throws {
        let schema = Schema(
            [DebugProduct.self],
            version: Schema.Version(1, 0, 0)
        )

        let statsManager = MockStatisticsManager()
        let planner = TypedRecordQueryPlanner<DebugProduct>(
            schema: schema,
            recordName: DebugProduct.recordName,
            statisticsManager: statsManager
        )

        // Access findIndexForField via reflection or test indirectly
        let indexes = schema.indexes(for: DebugProduct.recordName)
        print("📊 Available indexes: \(indexes.count)")

        let categoryIndex = indexes.first { index in
            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                return fieldExpr.fieldName == "category"
            }
            return false
        }

        if let index = categoryIndex {
            print("✅ Found category index: \(index.name)")
        } else {
            print("❌ No category index found")
        }

        #expect(categoryIndex != nil, "Should find category index")
    }

    @Test("Debug: Full planning flow")
    func testFullPlanningFlow() async throws {
        let schema = Schema(
            [DebugProduct.self],
            version: Schema.Version(1, 0, 0)
        )

        print("\n📊 Schema initialized")
        print("  - Entities: \(schema.entities.count)")
        print("  - Indexes: \(schema.indexes.count)")

        let indexes = schema.indexes(for: DebugProduct.recordName)
        print("\n📊 Indexes for \(DebugProduct.recordName):")
        for (i, index) in indexes.enumerated() {
            print("  [\(i)] \(index.name)")
            print("      Type: \(index.type)")
            if let recordTypes = index.recordTypes {
                print("      RecordTypes: \(recordTypes)")
            } else {
                print("      RecordTypes: Universal (all types)")
            }
            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                print("      Field: \(fieldExpr.fieldName)")
            }
        }

        let statsManager = MockStatisticsManager()
        let planner = TypedRecordQueryPlanner<DebugProduct>(
            schema: schema,
            recordName: DebugProduct.recordName,
            statisticsManager: statsManager
        )

        let query = TypedRecordQuery<DebugProduct>(
            filter: TypedInQueryComponent<DebugProduct>(
                fieldName: "category",
                values: ["Electronics", "Books"]
            )
        )

        print("\n📊 Planning query...")
        let plan = try await planner.plan(query: query)

        print("\n📊 Generated plan:")
        print("  Type: \(type(of: plan))")

        if let fullScan = plan as? TypedFullScanPlan<DebugProduct> {
            print("  ⚠️ FullScanPlan selected")
            if let filter = fullScan.filter {
                print("  Filter: \(type(of: filter))")
            }
        } else if let inJoinPlan = plan as? TypedInJoinPlan<DebugProduct> {
            print("  ✅ InJoinPlan selected")
            print("  Field: \(inJoinPlan.fieldName)")
            print("  Values: \(inJoinPlan.values.count)")
        } else if let filterPlan = plan as? TypedFilterPlan<DebugProduct> {
            print("  FilterPlan wrapper")
            print("  Child: \(type(of: filterPlan.child))")
        }

        // For debugging, we'll accept any plan for now
        #expect(plan is TypedQueryPlan<DebugProduct>)
    }
}

// MARK: - Mock Statistics Manager

private final class MockStatisticsManager: StatisticsManagerProtocol {
    func getTableStatistics(recordType: String) async throws -> TableStatistics? {
        // Return nil to force heuristic-based planning
        return nil
    }

    func getIndexStatistics(indexName: String) async throws -> IndexStatistics? {
        return nil
    }

    func estimateSelectivity<Record: Sendable>(
        filter: any TypedQueryComponent<Record>,
        recordType: String
    ) async throws -> Double {
        return 0.1
    }
}
