import Testing
import Foundation
import FDBRecordCore
@testable import FoundationDB
@testable import FDBRecordLayer

// MARK: - Test Model
@Recordable
private struct EventSchedule {
    #PrimaryKey<EventSchedule>([\.id])
    #Index<EventSchedule>([\.eventTime.lowerBound])
    #Index<EventSchedule>([\.eventTime.upperBound])
    #Index<EventSchedule>([\.eventTimeClosed.lowerBound])
    #Index<EventSchedule>([\.eventTimeClosed.upperBound])
    #Index<EventSchedule>([\.capacity.lowerBound])
    #Index<EventSchedule>([\.capacity.upperBound])
    #Index<EventSchedule>([\.price.lowerBound])
    #Index<EventSchedule>([\.price.upperBound])

    var eventTime: Range<Date>
    var eventTimeClosed: ClosedRange<Date>
    var capacity: Range<Int>
    var price: ClosedRange<Double>
    var id: UUID
    var name: String
}

// MARK: - Integration Tests
@Suite("Range Query Integration Tests", .tags(.integration))
struct RangeQueryIntegrationTests {

    private func setupTestStore() async throws -> (db: any DatabaseProtocol, store: RecordStore<EventSchedule>) {
        // Initialize FDB network (only needed once, safe to call multiple times)
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized - this is fine for tests
        }
        let db = try FDBClient.openDatabase()
        // Use a unique subspace for each test run to ensure isolation, avoiding the need for a clear operation.
        let subspace = Subspace(prefix: Array("test_range_query_\(UUID().uuidString)".utf8))

        let schema = Schema([EventSchedule.self])
        let store = RecordStore<EventSchedule>(
            database: db,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )
        return (db, store)
    }

    private func setupTestData(store: RecordStore<EventSchedule>) async throws {
        let now = Date()

        // Debug: Check type of literal 0
        let range0 = 0..<50
        print("DEBUG: range0.lowerBound type = \(type(of: range0.lowerBound))")
        let range100 = 100..<200
        print("DEBUG: range100.lowerBound type = \(type(of: range100.lowerBound))")

        let schedules = [
            EventSchedule(eventTime: now..<(now.addingTimeInterval(3600)), eventTimeClosed: now...now.addingTimeInterval(3600), capacity: 100..<200, price: 50.0...100.0, id: UUID(), name: "Tech Conference"),
            EventSchedule(eventTime: now.addingTimeInterval(1800)..<(now.addingTimeInterval(5400)), eventTimeClosed: now.addingTimeInterval(1800)...now.addingTimeInterval(5400), capacity: 150..<250, price: 75.0...125.0, id: UUID(), name: "Music Festival"),
            EventSchedule(eventTime: now.addingTimeInterval(7200)..<(now.addingTimeInterval(10800)), eventTimeClosed: now.addingTimeInterval(7200)...now.addingTimeInterval(10800), capacity: 0..<50, price: 200.0...300.0, id: UUID(), name: "Art Exhibition"),
        ]

        // CRITICAL DEBUG: Test extractRangeBoundary directly
        print("\n=== Testing extractRangeBoundary directly ===")
        for schedule in schedules {
            let lowerBoundValues = try schedule.extractRangeBoundary(fieldName: "capacity", component: .lowerBound)
            let upperBoundValues = try schedule.extractRangeBoundary(fieldName: "capacity", component: .upperBound)

            print("  \(schedule.name):")
            print("    capacity = \(schedule.capacity)")
            print("    lowerBound values: \(lowerBoundValues)")
            if let first = lowerBoundValues.first {
                print("      type: \(type(of: first))")
                print("      value: \(first)")
            }
            print("    upperBound values: \(upperBoundValues)")
            if let first = upperBoundValues.first {
                print("      type: \(type(of: first))")
                print("      value: \(first)")
            }
        }

        for schedule in schedules {
            try await store.save(schedule)
        }
    }

    @Test("Overlaps query on Range<Date> works")
    func testOverlapsRangeDate() async throws {
        let (_, store) = try await setupTestStore()
        try await setupTestData(store: store)
        let now = Date()
        let queryRange = now.addingTimeInterval(3000)..<now.addingTimeInterval(4000)

        let query = store.query().overlaps(\.eventTime, with: queryRange)
        
        let results = try await query.execute().map(\.name)
        #expect(results.count == 2)
        #expect(results.contains("Tech Conference"))
        #expect(results.contains("Music Festival"))
    }

    @Test("Overlaps query on ClosedRange<Date> works")
    func testOverlapsClosedRangeDate() async throws {
        let (_, store) = try await setupTestStore()
        try await setupTestData(store: store)
        let now = Date()
        let queryRange = now.addingTimeInterval(500)...now.addingTimeInterval(1000)

        let query = store.query().overlaps(\.eventTimeClosed, with: queryRange)
        
        let results = try await query.execute().map(\.name)
        #expect(results.count == 1)
        #expect(results.contains("Tech Conference"))
    }

    @Test("Overlaps query on Range<Int> works")
    func testOverlapsRangeInt() async throws {
        let (_, store) = try await setupTestStore()
        try await setupTestData(store: store)
        let queryRange = 175..<225

        // Debug: Print test data
        print("=== Test Data ===")
        let allRecords = try await store.query().execute()
        for record in allRecords {
            print("  \(record.name): capacity=\(record.capacity)")
        }

        // Check what indexes exist
        print("\n=== Available Indexes ===")
        let schema = store.schema
        let indexes = schema.indexes(for: "EventSchedule")
        for index in indexes {
            print("  \(index.name): \(index.type), rootExpr=\(type(of: index.rootExpression))")
        }

        // Debug: Test each record manually against the conditions
        print("\n=== Manual Filter Test ===")
        for record in allRecords {
            let lowerBound = record.capacity.lowerBound
            let upperBound = record.capacity.upperBound
            let queryLower = queryRange.lowerBound
            let queryUpper = queryRange.upperBound

            // overlaps condition: lowerBound < queryUpper AND upperBound > queryLower
            let cond1 = lowerBound < queryUpper
            let cond2 = upperBound > queryLower
            let shouldMatch = cond1 && cond2

            print("  \(record.name): \(record.capacity)")
            print("    lowerBound(\(lowerBound)) < queryUpper(\(queryUpper))? \(cond1)")
            print("    upperBound(\(upperBound)) > queryLower(\(queryLower))? \(cond2)")
            print("    Should match? \(shouldMatch)")
        }

        // Debug: Check index entries directly
        print("\n=== Index Entries ===")
        let db = store.database
        try await db.withTransaction { transaction in
            let indexSubspace = store.indexSubspace

            // Check capacity_start_index
            print("capacity_start_index entries:")
            let startIndexSubspace = indexSubspace.subspace("EventSchedule_capacity_start_index")
            let (startBegin, startEnd) = startIndexSubspace.range()
            for try await (key, _) in transaction.getRange(
                beginSelector: .firstGreaterOrEqual(startBegin),
                endSelector: .firstGreaterOrEqual(startEnd),
                snapshot: true
            ) {
                let unpacked = try startIndexSubspace.unpack(key)
                print("  Key: \(unpacked.count) elements")
                for i in 0..<unpacked.count {
                    if let elem = unpacked[i] {
                        print("    [\(i)]: \(elem) (type: \(type(of: elem)))")
                    }
                }
            }

            // Check capacity_end_index
            print("\ncapacity_end_index entries:")
            let endIndexSubspace = indexSubspace.subspace("EventSchedule_capacity_end_index")
            let (endBegin, endEnd) = endIndexSubspace.range()
            for try await (key, _) in transaction.getRange(
                beginSelector: .firstGreaterOrEqual(endBegin),
                endSelector: .firstGreaterOrEqual(endEnd),
                snapshot: true
            ) {
                let unpacked = try endIndexSubspace.unpack(key)
                print("  Key: \(unpacked.count) elements")
                for i in 0..<unpacked.count {
                    if let elem = unpacked[i] {
                        print("    [\(i)]: \(elem) (type: \(type(of: elem)))")
                    }
                }
            }
        }

        let query = store.query().overlaps(\.capacity, with: queryRange)

        print("\n=== Query: overlaps(capacity, with: \(queryRange)) ===")

        let results = try await query.execute()

        print("\n=== Results ===")
        for record in results {
            print("  \(record.name): capacity=\(record.capacity)")
        }

        let names = results.map(\.name)
        print("\n=== Result Names: \(names) ===")

        #expect(results.count == 2)
        #expect(names.contains("Tech Conference"))
        #expect(names.contains("Music Festival"))
    }

    @Test("Overlaps query on ClosedRange<Double> works")
    func testOverlapsClosedRangeDouble() async throws {
        let (_, store) = try await setupTestStore()
        try await setupTestData(store: store)
        let queryRange = 90.0...110.0

        let query = store.query().overlaps(\.price, with: queryRange)
        
        let results = try await query.execute().map(\.name)
        #expect(results.count == 2)
        #expect(results.contains("Tech Conference"))
        #expect(results.contains("Music Festival"))
    }
}
