// Example 03: Range Queries (including PartialRange)
// This example demonstrates querying with Range types and PartialRange types
// for event booking systems.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definition

@Recordable
struct Event {
    #PrimaryKey<Event>([\.eventID])
    #Index<Event>([\.availability.lowerBound], name: "event_by_start")
    #Index<Event>([\.availability.upperBound], name: "event_by_end")

    var eventID: Int64
    var name: String
    var availability: Range<Date>  // Start ~ End time
}

// MARK: - Example Usage

@main
struct RangeQueriesExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        let schema = Schema([Event.self])
        let subspace = Subspace(prefix: Tuple("examples", "range", "events").pack())
        let store = RecordStore<Event>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        print("📦 RecordStore initialized")

        // Create sample events
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: now)!
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: now)!

        let events = [
            Event(eventID: 1, name: "Past Event", availability: yesterday..<now),
            Event(eventID: 2, name: "Current Event", availability: yesterday..<tomorrow),
            Event(eventID: 3, name: "Future Event", availability: tomorrow..<nextWeek),
            Event(eventID: 4, name: "Long Event", availability: now..<nextMonth),
        ]

        for event in events {
            try await store.save(event)
        }
        print("✅ Inserted \(events.count) events")

        // MARK: - Range Queries

        // Events starting within next month
        print("\n📅 Events starting within next month:")
        let upcomingEvents = try await store.query()
            .overlaps(\.availability, with: now..<nextMonth)
            .execute()
        for event in upcomingEvents {
            print("  - \(event.name)")
        }

        // Events happening right now
        print("\n🔴 Currently happening events:")
        let currentEvents = try await store.query()
            .overlaps(\.availability, with: now...now)
            .execute()
        for event in currentEvents {
            print("  - \(event.name)")
        }

        // MARK: - PartialRange Queries

        // Future events (PartialRangeFrom: X...)
        print("\n⏭️ Events starting today or later:")
        let futureEvents = try await store.query()
            .overlaps(\.availability, with: now...)
            .execute()
        for event in futureEvents {
            print("  - \(event.name)")
        }

        // Past events (PartialRangeThrough: ...X)
        print("\n⏮️ Events ending today or earlier:")
        let pastEvents = try await store.query()
            .overlaps(\.availability, with: ...now)
            .execute()
        for event in pastEvents {
            print("  - \(event.name)")
        }

        // Events ending before tomorrow (PartialRangeUpTo: ..<X)
        print("\n⏪ Events ending before tomorrow:")
        let endingBeforeTomorrow = try await store.query()
            .overlaps(\.availability, with: ..<tomorrow)
            .execute()
        for event in endingBeforeTomorrow {
            print("  - \(event.name)")
        }

        print("\n🎉 Range queries example completed!")
    }
}
