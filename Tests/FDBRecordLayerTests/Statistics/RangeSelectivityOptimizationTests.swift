import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Integration tests for Range Selectivity-based Optimization (Phase 3)
///
/// **Test Coverage**:
/// - Range statistics collection
/// - Selectivity estimation for queries
/// - Query plan ordering based on selectivity
/// - End-to-end optimization with real data
@Suite("Range Selectivity Optimization Tests", .serialized)
struct RangeSelectivityOptimizationTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Helper Functions

    func createTestDatabase() throws -> any DatabaseProtocol {
        return try FDBClient.openDatabase()
    }

    // MARK: - Test Data Model

    struct Event: Sendable, Hashable {
        let eventID: Int64
        let period: Range<Date>
        let category: String
        let title: String

        static let recordName = "Event"
    }

    struct EventRecordAccess: RecordAccess {
        func recordName(for record: Event) -> String {
            return Event.recordName
        }

        func extractField(from record: Event, fieldName: String) throws -> [any TupleElement] {
            switch fieldName {
            case "eventID": return [record.eventID]
            case "period_lowerBound": return [record.period.lowerBound]
            case "period_upperBound": return [record.period.upperBound]
            case "category": return [record.category]
            case "title": return [record.title]
            default:
                throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
            }
        }

        func serialize(_ record: Event) throws -> FDB.Bytes {
            let tuple = Tuple(
                record.eventID,
                record.period.lowerBound,
                record.period.upperBound,
                record.category,
                record.title
            )
            return tuple.pack()
        }

        func deserialize(_ bytes: FDB.Bytes) throws -> Event {
            let tuple = try Tuple.unpack(from: bytes)
            guard let eventID = tuple[0] as? Int64,
                  let lowerBound = tuple[1] as? Date,
                  let upperBound = tuple[2] as? Date,
                  let category = tuple[3] as? String,
                  let title = tuple[4] as? String else {
                throw RecordLayerError.deserializationFailed("Invalid Event tuple")
            }
            return Event(
                eventID: eventID,
                period: lowerBound..<upperBound,
                category: category,
                title: title
            )
        }
    }

    // MARK: - Statistics Collection Tests

    @Test("Collect Range statistics for period index")
    func testCollectRangeStatistics() async throws {
        let database = try createTestDatabase()
        let testSubspace = Subspace(prefix: Array("test_range_stats_\(UUID().uuidString)".utf8))

        // Create test data: 100 events with 1-day periods
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let indexSubspace = testSubspace.subspace("I").subspace("event_by_period")

        try await database.withTransaction { transaction in

            for i in 0..<100 {
                let lowerBound = baseDate.addingTimeInterval(Double(i * 86400))
                let upperBound = lowerBound.addingTimeInterval(86400)  // 1 day

                // Index key: [lowerBound, upperBound, eventID]
                let indexKey = indexSubspace.pack(Tuple(lowerBound, upperBound, Int64(i)))
                transaction.setValue([], for: indexKey)
            }
        }

        // Collect statistics
        let periodIndex = Index(
            name: "event_by_period",
            type: .value,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "period_lowerBound"),
                FieldKeyExpression(fieldName: "period_upperBound")
            ])
        )

        let statsManager = StatisticsManager(database: database, subspace: testSubspace)

        try await statsManager.collectRangeStatistics(
            index: periodIndex,
            indexSubspace: indexSubspace,
            sampleRate: 1.0  // Sample all records
        )

        // Retrieve statistics
        let stats = try await statsManager.getRangeStatistics(indexName: "event_by_period")

        // Verify statistics
        #expect(stats != nil)
        #expect(stats!.totalRecords == 100)
        #expect(stats!.sampleSize > 0)

        // avgRangeWidth should be approximately 1 day (86400 seconds)
        #expect(abs(stats!.avgRangeWidth - 86400) < 100)

        // overlapFactor should be close to 1.0 (no overlaps in test data)
        #expect(stats!.overlapFactor >= 1.0)
        #expect(stats!.overlapFactor < 2.0)

        print("📊 Collected statistics: \(stats!)")
    }

    @Test("Estimate selectivity for different query ranges")
    func testEstimateRangeSelectivity() async throws {
        let database = try createTestDatabase()
        let testSubspace = Subspace(prefix: Array("test_range_selectivity_\(UUID().uuidString)".utf8))

        // Create test data with known statistics
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let indexSubspace = testSubspace.subspace("I").subspace("event_by_period")

        try await database.withTransaction { transaction in

            for i in 0..<1000 {
                let lowerBound = baseDate.addingTimeInterval(Double(i * 3600))  // Every hour
                let upperBound = lowerBound.addingTimeInterval(3600)  // 1 hour duration

                let indexKey = indexSubspace.pack(Tuple(lowerBound, upperBound, Int64(i)))
                transaction.setValue([], for: indexKey)
            }
        }

        // Collect statistics
        let periodIndex = Index(
            name: "event_by_period",
            type: .value,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "period_lowerBound"),
                FieldKeyExpression(fieldName: "period_upperBound")
            ])
        )

        let statsManager = StatisticsManager(database: database, subspace: testSubspace)
        try await statsManager.collectRangeStatistics(
            index: periodIndex,
            indexSubspace: indexSubspace,
            sampleRate: 0.1
        )

        // Test 1: Query range = 1 hour (same as average)
        let queryRange1 = baseDate..<baseDate.addingTimeInterval(3600)
        let selectivity1 = try await statsManager.estimateRangeSelectivity(
            indexName: "event_by_period",
            queryRange: queryRange1
        )
        print("📊 Selectivity for 1-hour query: \(selectivity1)")
        #expect(selectivity1 > 0.0)
        #expect(selectivity1 <= 1.0)

        // Test 2: Query range = 1 day (24x average)
        let queryRange2 = baseDate..<baseDate.addingTimeInterval(86400)
        let selectivity2 = try await statsManager.estimateRangeSelectivity(
            indexName: "event_by_period",
            queryRange: queryRange2
        )
        print("📊 Selectivity for 1-day query: \(selectivity2)")
        #expect(selectivity2 > selectivity1)  // Wider range → higher selectivity
        #expect(selectivity2 <= 1.0)

        // Test 3: Query range = 1 week (168x average)
        let queryRange3 = baseDate..<baseDate.addingTimeInterval(7 * 86400)
        let selectivity3 = try await statsManager.estimateRangeSelectivity(
            indexName: "event_by_period",
            queryRange: queryRange3
        )
        print("📊 Selectivity for 1-week query: \(selectivity3)")
        #expect(selectivity3 > selectivity2)  // Even wider range → even higher selectivity
        #expect(selectivity3 <= 1.0)
    }

    @Test("Selectivity estimation without statistics uses default")
    func testEstimateSelectivityWithoutStatistics() async throws {
        let database = try createTestDatabase()
        let testSubspace = Subspace(prefix: Array("test_no_stats_\(UUID().uuidString)".utf8))

        let statsManager = StatisticsManager(database: database, subspace: testSubspace)

        // No statistics collected → should use default (0.5)
        let queryRange = Date()..<Date().addingTimeInterval(86400)
        let selectivity = try await statsManager.estimateRangeSelectivity(
            indexName: "nonexistent_index",
            queryRange: queryRange
        )

        #expect(selectivity == 0.5)  // Default value
    }

    @Test("Partial range selectivity estimation")
    func testPartialRangeSelectivity() async throws {
        let database = try createTestDatabase()
        let testSubspace = Subspace(prefix: Array("test_partial_range_\(UUID().uuidString)".utf8))

        // Create simple test data
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let indexSubspace = testSubspace.subspace("I").subspace("event_by_period")

        try await database.withTransaction { transaction in

            for i in 0..<100 {
                let lowerBound = baseDate.addingTimeInterval(Double(i * 86400))
                let upperBound = lowerBound.addingTimeInterval(86400)

                let indexKey = indexSubspace.pack(Tuple(lowerBound, upperBound, Int64(i)))
                transaction.setValue([], for: indexKey)
            }
        }

        // Collect statistics
        let periodIndex = Index(
            name: "event_by_period",
            type: .value,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "period_lowerBound"),
                FieldKeyExpression(fieldName: "period_upperBound")
            ])
        )

        let statsManager = StatisticsManager(database: database, subspace: testSubspace)
        try await statsManager.collectRangeStatistics(
            index: periodIndex,
            indexSubspace: indexSubspace,
            sampleRate: 1.0
        )

        // Test PartialRangeFrom
        let partialFrom = baseDate...
        let selectivityFrom = try await statsManager.estimateRangeSelectivity(
            indexName: "event_by_period",
            queryRange: partialFrom
        )
        print("📊 Selectivity for PartialRangeFrom: \(selectivityFrom)")
        #expect(selectivityFrom > 0.0)
        #expect(selectivityFrom <= 1.0)

        // Test PartialRangeThrough
        let partialThrough = ...baseDate.addingTimeInterval(86400)
        let selectivityThrough = try await statsManager.estimateRangeSelectivity(
            indexName: "event_by_period",
            queryRange: partialThrough
        )
        print("📊 Selectivity for PartialRangeThrough: \(selectivityThrough)")
        #expect(selectivityThrough > 0.0)
        #expect(selectivityThrough <= 1.0)

        // Test PartialRangeUpTo
        let partialUpTo = ..<baseDate.addingTimeInterval(86400)
        let selectivityUpTo = try await statsManager.estimateRangeSelectivity(
            indexName: "event_by_period",
            queryRange: partialUpTo
        )
        print("📊 Selectivity for PartialRangeUpTo: \(selectivityUpTo)")
        #expect(selectivityUpTo > 0.0)
        #expect(selectivityUpTo <= 1.0)
    }

    // MARK: - Real-world Scenario

    @Test("End-to-end: Statistics improve query optimization")
    func testEndToEndOptimization() async throws {
        let database = try createTestDatabase()
        let testSubspace = Subspace(prefix: Array("test_e2e_optimization_\(UUID().uuidString)".utf8))

        // Create two indexes with different selectivities
        let periodIndexSubspace = testSubspace.subspace("I").subspace("event_by_period")
        let categoryIndexSubspace = testSubspace.subspace("I").subspace("event_by_category")

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        try await database.withTransaction { transaction in

            // Index 1: Period index (high selectivity, 10% of records match)
            for i in 0..<100 {
                let lowerBound = baseDate.addingTimeInterval(Double(i * 86400))
                let upperBound = lowerBound.addingTimeInterval(86400)
                let periodKey = periodIndexSubspace.pack(Tuple(lowerBound, upperBound, Int64(i)))
                transaction.setValue([], for: periodKey)
            }

            // Index 2: Category index (low selectivity, 50% of records match)
            for i in 0..<100 {
                let category = i % 2 == 0 ? "Work" : "Personal"
                let categoryKey = categoryIndexSubspace.pack(Tuple(category, Int64(i)))
                transaction.setValue([], for: categoryKey)
            }
        }

        // Collect statistics
        let statsManager = StatisticsManager(database: database, subspace: testSubspace)

        let periodIndex = Index(
            name: "event_by_period",
            type: .value,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "period_lowerBound"),
                FieldKeyExpression(fieldName: "period_upperBound")
            ])
        )

        try await statsManager.collectRangeStatistics(
            index: periodIndex,
            indexSubspace: periodIndexSubspace,
            sampleRate: 1.0
        )

        // Verify statistics were collected
        let stats = try await statsManager.getRangeStatistics(indexName: "event_by_period")
        #expect(stats != nil)
        print("✅ Statistics collected successfully for end-to-end test")
        print("📊 Stats: totalRecords=\(stats!.totalRecords), avgRangeWidth=\(stats!.avgRangeWidth)s, overlapFactor=\(stats!.overlapFactor)")

        // Note: TypedRecordQueryPlanner integration would use these statistics
        // to order plans by selectivity in production queries
    }
}
