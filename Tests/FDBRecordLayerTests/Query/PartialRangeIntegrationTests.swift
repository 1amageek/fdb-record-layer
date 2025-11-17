import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Integration tests for PartialRange boundary extraction and serialization
///
/// Tests that the macro-generated extractRangeBoundary method correctly handles:
/// - PartialRangeFrom: only lowerBound extraction
/// - PartialRangeThrough/UpTo: only upperBound extraction
/// - Error throwing for invalid boundary access
@Suite("PartialRange Integration Tests", .tags(.integration))
struct PartialRangeIntegrationTests {

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - PartialRangeFrom Tests

    @Test("PartialRangeFrom: lowerBound extraction works")
    func testPartialRangeFromLowerBound() async throws {
        // Use the OpenEndEvent from PartialRangeMinimalTest (it compiles)
        let startDate = Date(timeIntervalSince1970: 1000)
        let event = PartialRangeMinimalTest.OpenEndEvent(
            id: 1,
            validFrom: startDate...,
            title: "Test"
        )

        let lowerBound = try event.extractRangeBoundary(fieldName: "validFrom", component: .lowerBound)
        #expect(lowerBound.count == 1, "Should extract 1 element for lowerBound")
        #expect((lowerBound[0] as? Date) == startDate, "lowerBound value should match")
    }

    @Test("PartialRangeFrom: upperBound extraction throws error")
    func testPartialRangeFromUpperBoundThrows() async throws {
        let startDate = Date(timeIntervalSince1970: 1000)
        let event = PartialRangeMinimalTest.OpenEndEvent(
            id: 1,
            validFrom: startDate...,
            title: "Test"
        )

        #expect(throws: RecordLayerError.self) {
            try event.extractRangeBoundary(fieldName: "validFrom", component: .upperBound)
        }
    }

    @Test("PartialRangeFrom: serialization round-trip")
    func testPartialRangeFromSerialization() async throws {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_partial_from_serial_\(UUID().uuidString)".utf8))
        let schema = Schema([PartialRangeMinimalTest.OpenEndEvent.self])

        let store = RecordStore<PartialRangeMinimalTest.OpenEndEvent>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        let startDate = Date(timeIntervalSince1970: 1000)
        let event = PartialRangeMinimalTest.OpenEndEvent(
            id: 1,
            validFrom: startDate...,
            title: "Conference"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        #expect(results.count == 1, "Should find 1 event")
        let loaded = results.first
        #expect(loaded?.id == 1)
        #expect(loaded?.validFrom.lowerBound == startDate, "lowerBound should match")
        #expect(loaded?.title == "Conference")
    }

    // MARK: - PartialRangeThrough Tests

    @Test("PartialRangeThrough: upperBound extraction works")
    func testPartialRangeThroughUpperBound() async throws {
        let endDate = Date(timeIntervalSince1970: 2000)
        let event = PartialRangeMinimalTest.OpenStartEvent(
            id: 1,
            validThrough: ...endDate,
            title: "Test"
        )

        let upperBound = try event.extractRangeBoundary(fieldName: "validThrough", component: .upperBound)
        #expect(upperBound.count == 1, "Should extract 1 element for upperBound")
        #expect((upperBound[0] as? Date) == endDate, "upperBound value should match")
    }

    @Test("PartialRangeThrough: lowerBound extraction throws error")
    func testPartialRangeThroughLowerBoundThrows() async throws {
        let endDate = Date(timeIntervalSince1970: 2000)
        let event = PartialRangeMinimalTest.OpenStartEvent(
            id: 1,
            validThrough: ...endDate,
            title: "Test"
        )

        #expect(throws: RecordLayerError.self) {
            try event.extractRangeBoundary(fieldName: "validThrough", component: .lowerBound)
        }
    }

    @Test("PartialRangeThrough: serialization round-trip")
    func testPartialRangeThroughSerialization() async throws {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_partial_through_serial_\(UUID().uuidString)".utf8))
        let schema = Schema([PartialRangeMinimalTest.OpenStartEvent.self])

        let store = RecordStore<PartialRangeMinimalTest.OpenStartEvent>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        let endDate = Date(timeIntervalSince1970: 2000)
        let event = PartialRangeMinimalTest.OpenStartEvent(
            id: 1,
            validThrough: ...endDate,
            title: "Legacy event"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        #expect(results.count == 1, "Should find 1 event")
        let loaded = results.first
        #expect(loaded?.id == 1)
        #expect(loaded?.validThrough.upperBound == endDate, "upperBound should match")
        #expect(loaded?.title == "Legacy event")
    }

    // MARK: - PartialRangeUpTo Tests

    @Test("PartialRangeUpTo: upperBound extraction works")
    func testPartialRangeUpToUpperBound() async throws {
        let endDate = Date(timeIntervalSince1970: 3000)
        let event = PartialRangeMinimalTest.OpenStartExclusiveEvent(
            id: 1,
            validUpTo: ..<endDate,
            title: "Test"
        )

        let upperBound = try event.extractRangeBoundary(fieldName: "validUpTo", component: .upperBound)
        #expect(upperBound.count == 1, "Should extract 1 element for upperBound")
        #expect((upperBound[0] as? Date) == endDate, "upperBound value should match")
    }

    @Test("PartialRangeUpTo: lowerBound extraction throws error")
    func testPartialRangeUpToLowerBoundThrows() async throws {
        let endDate = Date(timeIntervalSince1970: 3000)
        let event = PartialRangeMinimalTest.OpenStartExclusiveEvent(
            id: 1,
            validUpTo: ..<endDate,
            title: "Test"
        )

        #expect(throws: RecordLayerError.self) {
            try event.extractRangeBoundary(fieldName: "validUpTo", component: .lowerBound)
        }
    }

    @Test("PartialRangeUpTo: serialization round-trip")
    func testPartialRangeUpToSerialization() async throws {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_partial_upto_serial_\(UUID().uuidString)".utf8))
        let schema = Schema([PartialRangeMinimalTest.OpenStartExclusiveEvent.self])

        let store = RecordStore<PartialRangeMinimalTest.OpenStartExclusiveEvent>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        let endDate = Date(timeIntervalSince1970: 3000)
        let event = PartialRangeMinimalTest.OpenStartExclusiveEvent(
            id: 1,
            validUpTo: ..<endDate,
            title: "Historical"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        #expect(results.count == 1, "Should find 1 event")
        let loaded = results.first
        #expect(loaded?.id == 1)
        #expect(loaded?.validUpTo.upperBound == endDate, "upperBound should match")
        #expect(loaded?.title == "Historical")
    }

    // MARK: - Edge Cases

    @Test("PartialRangeFrom with early epoch date")
    func testPartialRangeFromEarlyDate() async throws {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_partial_epoch_\(UUID().uuidString)".utf8))
        let schema = Schema([PartialRangeMinimalTest.OpenEndEvent.self])

        let store = RecordStore<PartialRangeMinimalTest.OpenEndEvent>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        let earlyDate = Date(timeIntervalSince1970: 0)  // 1970-01-01
        let event = PartialRangeMinimalTest.OpenEndEvent(
            id: 1,
            validFrom: earlyDate...,
            title: "Unix epoch start"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        let loaded = results.first
        #expect(loaded?.validFrom.lowerBound == earlyDate)
    }

    @Test("PartialRangeThrough with far future date")
    func testPartialRangeThroughFutureDate() async throws {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_partial_future_\(UUID().uuidString)".utf8))
        let schema = Schema([PartialRangeMinimalTest.OpenStartEvent.self])

        let store = RecordStore<PartialRangeMinimalTest.OpenStartEvent>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        let futureDate = Date(timeIntervalSince1970: Double(Int32.max))  // Year 2038
        let event = PartialRangeMinimalTest.OpenStartEvent(
            id: 1,
            validThrough: ...futureDate,
            title: "Far future"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        let loaded = results.first
        #expect(loaded?.validThrough.upperBound == futureDate)
    }
}
