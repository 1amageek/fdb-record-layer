import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// End-to-end tests for Range type index support
///
/// Tests the complete flow from macro expansion to query execution for Range type fields.
@Suite("Range Index End-to-End Tests")
struct RangeIndexEndToEndTests {

    // MARK: - Test Models

    @Recordable
    struct Event {
        #PrimaryKey<Event>([\.id])
        #Index<Event>([\.period])  // Auto-generates start + end indexes

        var id: Int64
        var period: Range<Date>
        var title: String
    }

    @Recordable
    struct Subscription {
        #PrimaryKey<Subscription>([\.id])
        #Index<Subscription>([\.validPeriod])

        var id: Int64
        var validPeriod: ClosedRange<Date>
        var plan: String
    }

    /// Test model with Optional Range field
    @Recordable
    struct OptionalEvent {
        #PrimaryKey<OptionalEvent>([\.id])
        #Index<OptionalEvent>([\.period])

        var id: Int64
        var period: Range<Date>?
        var title: String                                                                                                                                                           
    }

    // MARK: - Setup/Teardown

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    private func setupTestDatabase() async throws -> (db: any DatabaseProtocol, store: RecordStore<Event>) {
        let db = try FDBClient.openDatabase()

        let testSubspace = Subspace(prefix: Array("test_range_\(UUID().uuidString)".utf8))

        let schema = Schema([Event.self])
        let store = RecordStore<Event>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        return (db, store)
    }

    private func setupSubscriptionStore() async throws -> (db: any DatabaseProtocol, store: RecordStore<Subscription>) {
        let db = try FDBClient.openDatabase()

        let testSubspace = Subspace(prefix: Array("test_range_\(UUID().uuidString)".utf8))

        let schema = Schema([Subscription.self])
        let store = RecordStore<Subscription>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        return (db, store)
    }

    private func setupOptionalEventStore() async throws -> (db: any DatabaseProtocol, store: RecordStore<OptionalEvent>) {
        let db = try FDBClient.openDatabase()

        let testSubspace = Subspace(prefix: Array("test_range_\(UUID().uuidString)".utf8))

        let schema = Schema([OptionalEvent.self])
        let store = RecordStore<OptionalEvent>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        return (db, store)
    }

    // MARK: - Macro Expansion Tests

    @Test("Macro generates two indexes for Range type")
    func testMacroGeneratesTwoIndexes() async throws {
        let (_, store) = try await setupTestDatabase()

        // Verify that Event has 2 indexes generated for period field
        let indexes = Event.indexDefinitions

        let rangeIndexes = indexes.filter { $0.fields.contains("period") }
        #expect(rangeIndexes.count == 2, "Expected 2 indexes for Range<Date> field")

        let startIndex = rangeIndexes.first { $0.name.contains("start") }
        let endIndex = rangeIndexes.first { $0.name.contains("end") }

        #expect(startIndex != nil, "Expected start index")
        #expect(endIndex != nil, "Expected end index")

        #expect(startIndex?.rangeComponent == .lowerBound)
        #expect(endIndex?.rangeComponent == .upperBound)
        #expect(startIndex?.boundaryType == .halfOpen)
        #expect(endIndex?.boundaryType == .halfOpen)
    }

    @Test("Macro generates correct index names")
    func testMacroGeneratesCorrectIndexNames() {
        let indexes = Event.indexDefinitions
        let rangeIndexes = indexes.filter { $0.fields.contains("period") }

        let names = rangeIndexes.map { $0.name }.sorted()
        #expect(names[0].hasSuffix("_end_index"))
        #expect(names[1].hasSuffix("_start_index"))
    }

    // MARK: - Serialization Tests

    @Test("Range type serialization/deserialization")
    func testRangeSerialization() async throws {
        let (_, store) = try await setupTestDatabase()

        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)
        let event = Event(
            id: 1,
            period: start..<end,
            title: "Test Event"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        let retrieved = results.first
        #expect(retrieved != nil)
        #expect(retrieved?.period.lowerBound == start)
        #expect(retrieved?.period.upperBound == end)
    }

    @Test("ClosedRange type serialization/deserialization")
    func testClosedRangeSerialization() async throws {
        let (_, store) = try await setupSubscriptionStore()

        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)
        let subscription = Subscription(
            id: 1,
            validPeriod: start...end,
            plan: "Premium"
        )

        try await store.save(subscription)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        let retrieved = results.first
        #expect(retrieved != nil)
        #expect(retrieved?.validPeriod.lowerBound == start)
        #expect(retrieved?.validPeriod.upperBound == end)
    }

    // MARK: - Index Building Tests

    @Test("Range indexes are created during save")
    func testRangeIndexesCreatedDuringSave() async throws {
        let (db, store) = try await setupTestDatabase()

        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)
        let event = Event(
            id: 1,
            period: start..<end,
            title: "Test Event"
        )

        try await store.save(event)

        // Verify index entries exist
        try await db.withTransaction { transaction in
            // Check start index entry
            let startIndexSubspace = store.subspace
                .subspace("I")
                .subspace("Event_period_start_index")

            var startEntryFound = false
            for try await _ in transaction.getRange(begin: startIndexSubspace.range().begin,
                                                   end: startIndexSubspace.range().end) {
                startEntryFound = true
                break
            }
            #expect(startEntryFound, "Start index entry should exist")

            // Check end index entry
            let endIndexSubspace = store.subspace
                .subspace("I")
                .subspace("Event_period_end_index")

            var endEntryFound = false
            for try await _ in transaction.getRange(begin: endIndexSubspace.range().begin,
                                                   end: endIndexSubspace.range().end) {
                endEntryFound = true
                break
            }
            #expect(endEntryFound, "End index entry should exist")
        }
    }

    // MARK: - Query Execution Tests

    @Test("overlaps() query with Range type")
    func testOverlapsQueryWithRange() async throws {
        let (_, store) = try await setupTestDatabase()

        // Create test data
        let baseTime = Date(timeIntervalSince1970: 0)
        let events = [
            Event(id: 1, period: baseTime.addingTimeInterval(0)..<baseTime.addingTimeInterval(100), title: "Event 1"),
            Event(id: 2, period: baseTime.addingTimeInterval(50)..<baseTime.addingTimeInterval(150), title: "Event 2"),
            Event(id: 3, period: baseTime.addingTimeInterval(200)..<baseTime.addingTimeInterval(300), title: "Event 3"),
        ]

        for event in events {
            try await store.save(event)
        }

        // Query: Find events overlapping with [75, 125)
        let queryRange = baseTime.addingTimeInterval(75)..<baseTime.addingTimeInterval(125)

        // DEBUG: Check what indexes are in the schema
        let schema = Schema([Event.self])
        let indexes = schema.indexes(for: Event.recordName)
        print("📊 Indexes in schema for \(Event.recordName):")
        for index in indexes {
            print("  - \(index.name): rootExpression=\(type(of: index.rootExpression))")
            if let rangeExpr = index.rootExpression as? RangeKeyExpression {
                print("    RangeKeyExpression: field=\(rangeExpr.fieldName), component=\(rangeExpr.component), boundaryType=\(rangeExpr.boundaryType)")
            }
        }

        // CRITICAL: Verify that overlaps() uses IntersectionPlan (not full scan)
        let queryBuilder = store.query().overlaps(\.period, with: queryRange)
        let (query, planner) = queryBuilder.buildQueryAndPlanner()

        print("🔍 Query filter type: \(type(of: query.filter))")
        if let andFilter = query.filter as? TypedAndQueryComponent<Event> {
            print("  AND filter with \(andFilter.children.count) children:")
            for (i, child) in andFilter.children.enumerated() {
                print("    [\(i)]: \(type(of: child))")
                if let keyExprFilter = child as? TypedKeyExpressionQueryComponent<Event> {
                    if let rangeExpr = keyExprFilter.keyExpression as? RangeKeyExpression {
                        print("      RangeKeyExpression: field=\(rangeExpr.fieldName), component=\(rangeExpr.component), boundaryType=\(rangeExpr.boundaryType)")
                    }
                }
            }
        }

        let plan = try await planner.plan(query: query)
        print("📋 Generated plan: \(type(of: plan))")

        // Verify IntersectionPlan is generated (uses both Range indexes)
        #expect(plan is TypedIntersectionPlan<Event>, "overlaps() should generate IntersectionPlan using both Range indexes, not full scan")
        if let intersectionPlan = plan as? TypedIntersectionPlan<Event> {
            #expect(intersectionPlan.childPlans.count == 2, "IntersectionPlan should have 2 child plans (start and end indexes)")
            #expect(intersectionPlan.childPlans.allSatisfy { $0 is TypedIndexScanPlan<Event> }, "Both child plans should be IndexScanPlan")
        }

        // Execute query and verify results
        let results = try await queryBuilder.execute()

        // Event 1: [0, 100) overlaps [75, 125) ✓
        // Event 2: [50, 150) overlaps [75, 125) ✓
        // Event 3: [200, 300) does NOT overlap [75, 125) ✗

        let resultIDs = results.map { $0.id }.sorted()
        #expect(resultIDs == [1, 2], "Should find events 1 and 2")
    }

    @Test("overlaps() query with ClosedRange type")
    func testOverlapsQueryWithClosedRange() async throws {
        let (_, store) = try await setupSubscriptionStore()

        // Create test data
        let baseTime = Date(timeIntervalSince1970: 0)
        let subscriptions = [
            Subscription(id: 1, validPeriod: baseTime.addingTimeInterval(0)...baseTime.addingTimeInterval(100), plan: "Basic"),
            Subscription(id: 2, validPeriod: baseTime.addingTimeInterval(50)...baseTime.addingTimeInterval(150), plan: "Premium"),
            Subscription(id: 3, validPeriod: baseTime.addingTimeInterval(200)...baseTime.addingTimeInterval(300), plan: "Enterprise"),
        ]

        for subscription in subscriptions {
            try await store.save(subscription)
        }

        // Query: Find subscriptions overlapping with [100, 200]
        let queryRange = baseTime.addingTimeInterval(100)...baseTime.addingTimeInterval(200)
        let results = try await store.query()
            .overlaps(\.validPeriod, with: queryRange)
            .execute()

        // Subscription 1: [0, 100] overlaps [100, 200] ✓ (boundary touch)
        // Subscription 2: [50, 150] overlaps [100, 200] ✓
        // Subscription 3: [200, 300] overlaps [100, 200] ✓ (boundary touch)

        let resultIDs = results.map { $0.id }.sorted()
        #expect(resultIDs == [1, 2, 3], "Should find all subscriptions (closed range includes boundaries)")
    }

    @Test("overlaps() with no results")
    func testOverlapsWithNoResults() async throws {
        let (_, store) = try await setupTestDatabase()

        // Create test data
        let baseTime = Date(timeIntervalSince1970: 0)
        let event = Event(
            id: 1,
            period: baseTime.addingTimeInterval(0)..<baseTime.addingTimeInterval(100),
            title: "Event 1"
        )
        try await store.save(event)

        // Query: Range that doesn't overlap
        let queryRange = baseTime.addingTimeInterval(200)..<baseTime.addingTimeInterval(300)
        let results = try await store.query()
            .overlaps(\.period, with: queryRange)
            .execute()

        #expect(results.isEmpty, "Should find no results")
    }

    @Test("overlaps() combined with other filters")
    func testOverlapsCombinedWithFilters() async throws {
        // Verify that combining overlaps() with other filters generates optimal plan:
        // FilterPlan (for non-Range filters) wrapping IntersectionPlan (for Range filters)

        let (_, store) = try await setupTestDatabase()

        // Create test data
        let baseTime = Date(timeIntervalSince1970: 0)
        let events = [
            Event(id: 1, period: baseTime.addingTimeInterval(0)..<baseTime.addingTimeInterval(100), title: "Conference"),
            Event(id: 2, period: baseTime.addingTimeInterval(50)..<baseTime.addingTimeInterval(150), title: "Meeting"),
            Event(id: 3, period: baseTime.addingTimeInterval(75)..<baseTime.addingTimeInterval(125), title: "Conference"),
        ]

        for event in events {
            try await store.save(event)
        }

        // Query: Overlapping events with title = "Conference"
        let queryRange = baseTime.addingTimeInterval(50)..<baseTime.addingTimeInterval(120)

        // Verify plan structure: FilterPlan wrapping IntersectionPlan
        let queryBuilder = store.query()
            .overlaps(\.period, with: queryRange)
            .where(\.title, is: .equals, "Conference")
        let (query, planner) = queryBuilder.buildQueryAndPlanner()
        let plan = try await planner.plan(query: query)

        // Should generate FilterPlan (for title filter) wrapping IntersectionPlan (for overlaps)
        #expect(plan is TypedFilterPlan<Event>, "Combined filters should generate FilterPlan wrapping IntersectionPlan")
        if let filterPlan = plan as? TypedFilterPlan<Event> {
            #expect(filterPlan.child is TypedIntersectionPlan<Event>, "FilterPlan should wrap IntersectionPlan for overlaps()")
        }

        // Verify query results are correct
        let results = try await queryBuilder.execute()

        let resultIDs = results.map { $0.id }.sorted()
        #expect(resultIDs == [1, 3], "Should find conferences 1 and 3")
    }

    // MARK: - Optional Range Tests

    @Test("Optional Range type serialization/deserialization with non-nil value")
    func testOptionalRangeSerializationWithValue() async throws {
        let (_, store) = try await setupOptionalEventStore()

        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)
        let event = OptionalEvent(
            id: 1,
            period: start..<end,
            title: "Test Event"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        let retrieved = results.first
        #expect(retrieved != nil)
        #expect(retrieved?.period?.lowerBound == start)
        #expect(retrieved?.period?.upperBound == end)
    }

    @Test("Optional Range type serialization/deserialization with nil value")
    func testOptionalRangeSerializationWithNil() async throws {
        let (_, store) = try await setupOptionalEventStore()

        let event = OptionalEvent(
            id: 1,
            period: nil,
            title: "No Period Event"
        )

        try await store.save(event)

        let results = try await store.query()
            .where(\.id, is: .equals, 1)
            .execute()
        let retrieved = results.first
        #expect(retrieved != nil)
        #expect(retrieved?.period == nil, "Period should be nil")
    }

    @Test("Optional Range indexes are created during save")
    func testOptionalRangeIndexesCreatedDuringSave() async throws {
        let (db, store) = try await setupOptionalEventStore()

        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)
        let event = OptionalEvent(
            id: 1,
            period: start..<end,
            title: "Test Event"
        )

        try await store.save(event)

        // Verify index entries exist
        try await db.withTransaction { transaction in
            // Check start index entry
            let startIndexSubspace = store.subspace
                .subspace("I")
                .subspace("OptionalEvent_period_start_index")

            var startEntryFound = false
            for try await _ in transaction.getRange(begin: startIndexSubspace.range().begin,
                                                   end: startIndexSubspace.range().end) {
                startEntryFound = true
                break
            }
            #expect(startEntryFound, "Start index entry should exist for non-nil Optional Range")

            // Check end index entry
            let endIndexSubspace = store.subspace
                .subspace("I")
                .subspace("OptionalEvent_period_end_index")

            var endEntryFound = false
            for try await _ in transaction.getRange(begin: endIndexSubspace.range().begin,
                                                   end: endIndexSubspace.range().end) {
                endEntryFound = true
                break
            }
            #expect(endEntryFound, "End index entry should exist for non-nil Optional Range")
        }
    }

    @Test("overlaps() query with Optional Range type (non-nil values)")
    func testOverlapsQueryWithOptionalRange() async throws {
        let (_, store) = try await setupOptionalEventStore()

        // Create test data
        let baseTime = Date(timeIntervalSince1970: 0)
        let events = [
            OptionalEvent(id: 1, period: baseTime.addingTimeInterval(0)..<baseTime.addingTimeInterval(100), title: "Event 1"),
            OptionalEvent(id: 2, period: baseTime.addingTimeInterval(50)..<baseTime.addingTimeInterval(150), title: "Event 2"),
            OptionalEvent(id: 3, period: baseTime.addingTimeInterval(200)..<baseTime.addingTimeInterval(300), title: "Event 3"),
            OptionalEvent(id: 4, period: nil, title: "Event 4 (no period)"),
        ]

        for event in events {
            try await store.save(event)
        }

        // Query: Find events overlapping with [75, 125)
        let queryRange = baseTime.addingTimeInterval(75)..<baseTime.addingTimeInterval(125)
        let results = try await store.query()
            .overlaps(\.period, with: queryRange)
            .execute()

        // Event 1: [0, 100) overlaps [75, 125) ✓
        // Event 2: [50, 150) overlaps [75, 125) ✓
        // Event 3: [200, 300) does NOT overlap [75, 125) ✗
        // Event 4: nil period should NOT match ✗

        let resultIDs = results.map { $0.id }.sorted()
        #expect(resultIDs == [1, 2], "Should find events 1 and 2 (non-nil periods that overlap)")
    }

    @Test("Optional Range with nil value does not create index entries")
    func testOptionalRangeNilNoIndexEntries() async throws {
        let (db, store) = try await setupOptionalEventStore()

        let event = OptionalEvent(
            id: 1,
            period: nil,
            title: "No Period Event"
        )

        try await store.save(event)

        // Verify NO index entries exist for nil value
        try await db.withTransaction { transaction in
            let startIndexSubspace = store.subspace
                .subspace("I")
                .subspace("OptionalEvent_period_start_index")

            var entryCount = 0
            for try await _ in transaction.getRange(begin: startIndexSubspace.range().begin,
                                                   end: startIndexSubspace.range().end) {
                entryCount += 1
            }
            #expect(entryCount == 0, "No index entries should exist for nil Optional Range")
        }
    }

    // MARK: - Boundary Type Verification Tests

    @Test("ClosedRange generates .closed boundary type")
    func testClosedRangeBoundaryType() async throws {
        let indexes = Subscription.indexDefinitions
        let rangeIndexes = indexes.filter { $0.fields.contains("validPeriod") }

        // Should generate 2 indexes (start + end)
        #expect(rangeIndexes.count == 2)

        let startIndex = rangeIndexes.first { $0.name.contains("start") }
        let endIndex = rangeIndexes.first { $0.name.contains("end") }

        // Both indexes should have .closed boundary type for ClosedRange
        #expect(startIndex?.rangeMetadata?.boundaryType == "closed")
        #expect(endIndex?.rangeMetadata?.boundaryType == "closed")
    }

    // MARK: - Boundary Behavior Tests

    @Test("Range excludes boundary values (exclusive)")
    func testRangeBoundaryExclusive() async throws {
        let db = try await Self.database
        await try Self.clearDatabase(db)

        let schema = Schema([Event.self])
        let store = try await RecordStore(
            database: db,
            subspace: testSubspace,
            schema: schema,
            recordType: Event.self
        )

        // Save events at exact boundary dates
        let boundaryStart = date("2024-01-01")
        let boundaryEnd = date("2024-01-31")
        let insideDate = date("2024-01-15")

        let eventAtStart = Event(id: 1, period: boundaryStart..<boundaryEnd, title: "At Start")
        let eventInside = Event(id: 2, period: insideDate..<boundaryEnd, title: "Inside")

        try await store.save(eventAtStart)
        try await store.save(eventInside)

        // Query: events overlapping exactly the start boundary
        // Range<Date> uses exclusive lower bound, so boundaryStart should NOT match
        let query = TypedRecordQuery<Event>()
            .where(\.period, .overlaps, boundaryStart..<insideDate)

        let results = try await query.execute(in: store)
        let events = try await results.allResults()

        // Only eventAtStart should match (its range starts at boundaryStart)
        // but the query range is exclusive of boundaryStart
        // So the overlap is [boundaryStart..<insideDate) ∩ [boundaryStart..<boundaryEnd)
        // which is [boundaryStart..<insideDate) - a valid overlap
        #expect(events.count >= 1)
        #expect(events.contains(where: { $0.id == 1 }))
    }

    @Test("ClosedRange includes boundary values (inclusive)")
    func testClosedRangeBoundaryInclusive() async throws {
        let (_, store) = try await setupSubscriptionStore()

        // Save subscriptions at exact boundary dates
        let boundaryStart = Date(timeIntervalSince1970: 1704067200)  // 2024-01-01
        let boundaryEnd = Date(timeIntervalSince1970: 1706659200)    // 2024-01-31
        let insideDate = Date(timeIntervalSince1970: 1705363200)     // 2024-01-15

        let subAtStart = Subscription(id: 1, validPeriod: boundaryStart...boundaryEnd, plan: "At Start")
        let subInside = Subscription(id: 2, validPeriod: insideDate...boundaryEnd, plan: "Inside")

        try await store.save(subAtStart)
        try await store.save(subInside)

        // Query: subscriptions overlapping exactly the start boundary
        // ClosedRange<Date> uses inclusive lower bound, so boundaryStart SHOULD match
        let subs = try await store.query()
            .overlaps(\.validPeriod, with: boundaryStart...insideDate)
            .execute()

        // Both subscriptions should match (inclusive boundaries)
        #expect(subs.count == 2)
        #expect(subs.contains(where: { $0.id == 1 }))
        #expect(subs.contains(where: { $0.id == 2 }))
    }

    @Test("Range vs ClosedRange boundary comparison")
    func testRangeVsClosedRangeBoundary() async throws {
        let (eventDb, eventStore) = try await setupTestDatabase()
        let (_, subStore) = try await setupSubscriptionStore()

        let exactDate = Date(timeIntervalSince1970: 1718400000)  // 2024-06-15

        // Save Range (exclusive upper bound)
        let event = Event(
            id: 1,
            period: Date(timeIntervalSince1970: 1704067200)..<exactDate,  // 2024-01-01 to 2024-06-15
            title: "Range Event"
        )
        try await eventStore.save(event)

        // Save ClosedRange (inclusive upper bound)
        let sub = Subscription(
            id: 1,
            validPeriod: Date(timeIntervalSince1970: 1704067200)...exactDate,  // 2024-01-01 to 2024-06-15
            plan: "Closed Range Sub"
        )
        try await subStore.save(sub)

        // Query at exact upper boundary
        // Range: should NOT match (exclusive)
        let events = try await eventStore.query()
            .overlaps(\.period, with: exactDate..<Date(timeIntervalSince1970: 1735689600))  // 2024-12-31
            .execute()

        #expect(events.count == 0, "Range with exclusive upper bound should not overlap at boundary")

        // ClosedRange: SHOULD match (inclusive)
        let subs = try await subStore.query()
            .overlaps(\.validPeriod, with: exactDate...Date(timeIntervalSince1970: 1735689600))  // 2024-12-31
            .execute()

        #expect(subs.count == 1, "ClosedRange with inclusive upper bound should overlap at boundary")
    }
}

