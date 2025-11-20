import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer
@testable import FDBRecordCore

/// Tests for PartialRange query boundary conditions (Bug Fix Verification)
///
/// These tests verify that unmatchedFilters use strict comparisons for "missing sides":
/// - PartialRangeFrom (X...): upperBound > X (not >=)
/// - PartialRangeThrough (...X): lowerBound < X (not <=)
/// - PartialRangeUpTo (..<X): lowerBound < X (not <=)
@Suite("PartialRange Boundary Tests", .tags(.integration))
struct PartialRangeBoundaryTests {

    // MARK: - Test Model

    @Recordable
    struct Event {
        #PrimaryKey<Event>([\.eventID])
        #Index<Event>([\.availability.lowerBound], name: "event_by_lowerBound")
        #Index<Event>([\.availability.upperBound], name: "event_by_upperBound")

        var eventID: Int64
        var name: String
        var availability: Range<Date>
    }

    // MARK: - Helper Methods

    private func initializeFDB() throws {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized
        }
    }

    private func createTestEvents() -> [Event] {
        return [
            // Event 1: [10, 20) - lowerBound = 10, upperBound = 20
            Event(
                eventID: 1,
                name: "Event1",
                availability: Date(timeIntervalSince1970: 10)..<Date(timeIntervalSince1970: 20)
            ),
            // Event 2: [15, 25) - lowerBound = 15, upperBound = 25
            Event(
                eventID: 2,
                name: "Event2",
                availability: Date(timeIntervalSince1970: 15)..<Date(timeIntervalSince1970: 25)
            ),
            // Event 3: [20, 30) - lowerBound = 20, upperBound = 30
            Event(
                eventID: 3,
                name: "Event3",
                availability: Date(timeIntervalSince1970: 20)..<Date(timeIntervalSince1970: 30)
            ),
            // Event 4: [25, 35) - lowerBound = 25, upperBound = 35
            Event(
                eventID: 4,
                name: "Event4",
                availability: Date(timeIntervalSince1970: 25)..<Date(timeIntervalSince1970: 35)
            ),
        ]
    }

    // MARK: - PartialRangeFrom Tests

    @Test("PartialRangeFrom: upperBound > X (strict, excludes upperBound == X)")
    func testPartialRangeFromExcludesBoundary() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([Event.self])
        let testSubspace = Subspace(prefix: Tuple("partial-range-test", UUID().uuidString).pack())
        let store = RecordStore<Event>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert test events
        let events = createTestEvents()
        for event in events {
            try await store.save(event)
        }

        // Query: overlaps with [20, ∞) (PartialRangeFrom)
        // Expected: Events with upperBound > 20
        // - Event 1: upperBound = 20 → EXCLUDED (strict >)
        // - Event 2: upperBound = 25 → INCLUDED
        // - Event 3: upperBound = 30 → INCLUDED
        // - Event 4: upperBound = 35 → INCLUDED
        let searchRange = Date(timeIntervalSince1970: 20)...
        let results = try await store.query()
            .overlaps(\.availability, with: searchRange)
            .execute()

        let resultIDs = Set(results.map { $0.eventID })

        // ✅ Critical assertion: Event 1 (upperBound == 20) must be EXCLUDED
        #expect(!resultIDs.contains(1), "Event 1 (upperBound == 20) should be excluded with strict '>' comparison")
        #expect(resultIDs.contains(2), "Event 2 (upperBound = 25) should be included")
        #expect(resultIDs.contains(3), "Event 3 (upperBound = 30) should be included")
        #expect(resultIDs.contains(4), "Event 4 (upperBound = 35) should be included")
        #expect(resultIDs.count == 3, "Should return exactly 3 events")
    }

    // MARK: - PartialRangeThrough Tests

    @Test("PartialRangeThrough: lowerBound < X (strict, excludes lowerBound == X)")
    func testPartialRangeThroughExcludesBoundary() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([Event.self])
        let testSubspace = Subspace(prefix: Tuple("partial-range-test", UUID().uuidString).pack())
        let store = RecordStore<Event>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert test events
        let events = createTestEvents()
        for event in events {
            try await store.save(event)
        }

        // Query: overlaps with (-∞, 20] (PartialRangeThrough)
        // Expected: Events with lowerBound < 20 (strict)
        // - Event 1: lowerBound = 10 → INCLUDED
        // - Event 2: lowerBound = 15 → INCLUDED
        // - Event 3: lowerBound = 20 → EXCLUDED (strict <)
        // - Event 4: lowerBound = 25 → EXCLUDED
        let searchRange = ...Date(timeIntervalSince1970: 20)
        let results = try await store.query()
            .overlaps(\.availability, with: searchRange)
            .execute()

        let resultIDs = Set(results.map { $0.eventID })

        // ✅ Critical assertion: Event 3 (lowerBound == 20) must be EXCLUDED
        #expect(resultIDs.contains(1), "Event 1 (lowerBound = 10) should be included")
        #expect(resultIDs.contains(2), "Event 2 (lowerBound = 15) should be included")
        #expect(!resultIDs.contains(3), "Event 3 (lowerBound == 20) should be excluded with strict '<' comparison")
        #expect(!resultIDs.contains(4), "Event 4 (lowerBound = 25) should be excluded")
        #expect(resultIDs.count == 2, "Should return exactly 2 events")
    }

    // MARK: - PartialRangeUpTo Tests

    @Test("PartialRangeUpTo: lowerBound < X (strict, excludes lowerBound == X)")
    func testPartialRangeUpToExcludesBoundary() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([Event.self])
        let testSubspace = Subspace(prefix: Tuple("partial-range-test", UUID().uuidString).pack())
        let store = RecordStore<Event>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert test events
        let events = createTestEvents()
        for event in events {
            try await store.save(event)
        }

        // Query: overlaps with (-∞, 20) (PartialRangeUpTo)
        // Expected: Events with lowerBound < 20 (strict)
        // - Event 1: lowerBound = 10 → INCLUDED
        // - Event 2: lowerBound = 15 → INCLUDED
        // - Event 3: lowerBound = 20 → EXCLUDED (strict <)
        // - Event 4: lowerBound = 25 → EXCLUDED
        let searchRange = ..<Date(timeIntervalSince1970: 20)
        let results = try await store.query()
            .overlaps(\.availability, with: searchRange)
            .execute()

        let resultIDs = Set(results.map { $0.eventID })

        // ✅ Critical assertion: Event 3 (lowerBound == 20) must be EXCLUDED
        #expect(resultIDs.contains(1), "Event 1 (lowerBound = 10) should be included")
        #expect(resultIDs.contains(2), "Event 2 (lowerBound = 15) should be included")
        #expect(!resultIDs.contains(3), "Event 3 (lowerBound == 20) should be excluded with strict '<' comparison")
        #expect(!resultIDs.contains(4), "Event 4 (lowerBound = 25) should be excluded")
        #expect(resultIDs.count == 2, "Should return exactly 2 events")
    }

    // MARK: - Edge Case: Multiple Boundary Points

    @Test("Multiple events at exact boundary point")
    func testMultipleEventsAtBoundary() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([Event.self])
        let testSubspace = Subspace(prefix: Tuple("partial-range-test", UUID().uuidString).pack())
        let store = RecordStore<Event>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Create multiple events with upperBound == 20
        let events = [
            Event(eventID: 1, name: "A", availability: Date(timeIntervalSince1970: 10)..<Date(timeIntervalSince1970: 20)),
            Event(eventID: 2, name: "B", availability: Date(timeIntervalSince1970: 15)..<Date(timeIntervalSince1970: 20)),
            Event(eventID: 3, name: "C", availability: Date(timeIntervalSince1970: 18)..<Date(timeIntervalSince1970: 20)),
            Event(eventID: 4, name: "D", availability: Date(timeIntervalSince1970: 20)..<Date(timeIntervalSince1970: 30)),
        ]

        for event in events {
            try await store.save(event)
        }

        // Query: overlaps with [20, ∞)
        // All events with upperBound == 20 should be excluded
        let searchRange = Date(timeIntervalSince1970: 20)...
        let results = try await store.query()
            .overlaps(\.availability, with: searchRange)
            .execute()

        let resultIDs = Set(results.map { $0.eventID })

        // ✅ All events with upperBound == 20 must be excluded
        #expect(!resultIDs.contains(1), "Event 1 (upperBound == 20) should be excluded")
        #expect(!resultIDs.contains(2), "Event 2 (upperBound == 20) should be excluded")
        #expect(!resultIDs.contains(3), "Event 3 (upperBound == 20) should be excluded")
        #expect(resultIDs.contains(4), "Event 4 (upperBound = 30) should be included")
        #expect(resultIDs.count == 1, "Should return exactly 1 event")
    }
}
