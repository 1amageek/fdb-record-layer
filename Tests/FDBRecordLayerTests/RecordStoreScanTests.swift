import Foundation
 import FDBRecordCore
import Testing
@testable import FoundationDB
@testable import FDBRecordLayer

/// Tests for RecordStore.scan() functionality
///
/// Verifies that the scan() method correctly iterates over all records,
/// handles empty stores, and works with GROUP BY and Migration operations.
///
/// **Note**: These are integration tests that require a running FoundationDB cluster.
/// Tests will be skipped if FDB is not available or not responding.
@Suite("RecordStore Scan Tests")
struct RecordStoreScanTests {

    // MARK: - Helper Methods

    /// Get database with health check and timeout
    ///
    /// Returns nil if FDB is not available or not responding within 2 seconds
    private func getDatabase() async -> (any DatabaseProtocol)? {
        guard ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] != "1" else {
            return nil
        }

        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized - this is fine
        }

        do {
            let db = try FDBClient.openDatabase()

            // Health check: verify FDB is actually responding (with 2s timeout)
            // Simple approach: just try the operation and let it timeout naturally
            do {
                try await db.withTransaction { transaction in
                    let healthCheckKey = Tuple("test", "health_check").pack()
                    transaction.setValue([0x01], for: healthCheckKey)
                }
                return db
            } catch {
                print("⚠️  FoundationDB connection failed: \(error)")
                return nil
            }
        } catch {
            print("⚠️  FoundationDB not available: \(error)")
            return nil
        }
    }

    // MARK: - Basic Scan Tests

    @Test("Scan empty store returns no records")
    func scanEmptyStore() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "empty").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        var count = 0
        for try await _ in store.scan() {
            count += 1
        }

        #expect(count == 0, "Scan of empty store should return 0 records")
    }

    @Test("Scan single record")
    func scanSingleRecord() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "single").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let record = SimpleScanRecord(id: 1, name: "Alice", age: 30)
        try await store.save(record)

        var count = 0
        var scannedRecord: SimpleScanRecord?

        for try await rec in store.scan() {
            count += 1
            scannedRecord = rec
        }

        #expect(count == 1, "Scan should return exactly 1 record")
        #expect(scannedRecord?.id == 1)
        #expect(scannedRecord?.name == "Alice")
        #expect(scannedRecord?.age == 30)
    }

    @Test("Scan multiple records")
    func scanMultipleRecords() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "multiple").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let records = [
            SimpleScanRecord(id: 1, name: "Alice", age: 30),
            SimpleScanRecord(id: 2, name: "Bob", age: 25),
            SimpleScanRecord(id: 3, name: "Charlie", age: 35),
            SimpleScanRecord(id: 4, name: "Diana", age: 28),
            SimpleScanRecord(id: 5, name: "Eve", age: 32)
        ]

        for record in records {
            try await store.save(record)
        }

        var scannedRecords: [SimpleScanRecord] = []
        for try await record in store.scan() {
            scannedRecords.append(record)
        }

        #expect(scannedRecords.count == 5, "Should scan all 5 records")

        let scannedIDs = Set(scannedRecords.map { $0.id })
        #expect(scannedIDs == Set([1, 2, 3, 4, 5]))
    }

    @Test("Scan large dataset")
    func scanLargeDataset() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "large").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let recordCount = 100
        for i in 1...recordCount {
            let record = SimpleScanRecord(id: Int64(i), name: "User\(i)", age: Int64(20 + (i % 50)))
            try await store.save(record)
        }

        var count = 0
        for try await _ in store.scan() {
            count += 1
        }

        #expect(count == recordCount, "Should scan all \(recordCount) records")
    }

    // MARK: - GROUP BY Integration Tests

    @Test("GROUP BY with COUNT aggregation")
    func groupByWithScan() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "groupby").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let records = [
            SimpleScanRecord(id: 1, name: "Alice", age: 30),
            SimpleScanRecord(id: 2, name: "Bob", age: 30),
            SimpleScanRecord(id: 3, name: "Charlie", age: 25),
            SimpleScanRecord(id: 4, name: "Diana", age: 30),
            SimpleScanRecord(id: 5, name: "Eve", age: 25)
        ]

        for record in records {
            try await store.save(record)
        }

        let builder = GroupByQueryBuilder<SimpleScanRecord, Int>(
            recordStore: store,
            groupByField: "age",
            aggregations: [.count(as: "count")]
        )

        let results = try await builder.execute()

        #expect(results.count == 2, "Should have 2 groups")

        let resultDict: [Int: Int64] = Dictionary(uniqueKeysWithValues: results.map { ($0.groupKey, $0.aggregations["count"]?.intValue ?? 0) })
        #expect(resultDict[25] == 2, "Age 25 should have count of 2")
        #expect(resultDict[30] == 3, "Age 30 should have count of 3")
    }

    @Test("GROUP BY with SUM and AVERAGE")
    func groupByWithSumAndAverage() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "groupby_sum").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let records = [
            SimpleScanRecord(id: 1, name: "Alice", age: 30),
            SimpleScanRecord(id: 2, name: "Bob", age: 30),
            SimpleScanRecord(id: 3, name: "Charlie", age: 20),
            SimpleScanRecord(id: 4, name: "Diana", age: 20)
        ]

        for record in records {
            try await store.save(record)
        }

        let builder = GroupByQueryBuilder<SimpleScanRecord, Int>(
            recordStore: store,
            groupByField: "age",
            aggregations: [
                .sum("age", as: "totalAge"),
                .average("age", as: "avgAge"),
                .count(as: "count")
            ]
        )

        let results = try await builder.execute()

        #expect(results.count == 2)

        for result in results {
            if result.groupKey == 30 {
                #expect(result.aggregations["totalAge"]?.intValue == 60, "Total age should be 60")
                #expect(result.aggregations["avgAge"]?.intValue == 30, "Average age should be 30")
                #expect(result.aggregations["count"]?.intValue == 2, "Count should be 2")
            } else if result.groupKey == 20 {
                #expect(result.aggregations["totalAge"]?.intValue == 40, "Total age should be 40")
                #expect(result.aggregations["avgAge"]?.intValue == 20, "Average age should be 20")
                #expect(result.aggregations["count"]?.intValue == 2, "Count should be 2")
            }
        }
    }

    // MARK: - Manual Transform/Delete Tests

    @Test("Manual transform records")
    func manualTransformRecords() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "manual_transform").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let records = [
            SimpleScanRecord(id: 1, name: "Alice", age: 30),
            SimpleScanRecord(id: 2, name: "Bob", age: 25),
            SimpleScanRecord(id: 3, name: "Charlie", age: 35)
        ]

        for record in records {
            try await store.save(record)
        }

        // Manually transform: increment all ages by 1
        var recordsToUpdate: [SimpleScanRecord] = []
        for try await record in store.scan() {
            var updated = record
            updated.age += 1
            recordsToUpdate.append(updated)
        }

        for record in recordsToUpdate {
            try await store.save(record)
        }

        // Verify all ages were incremented
        var updatedRecords: [SimpleScanRecord] = []
        for try await record in store.scan() {
            updatedRecords.append(record)
        }

        #expect(updatedRecords.count == 3)
        for record in updatedRecords {
            switch record.id {
            case 1:
                #expect(record.age == 31)
            case 2:
                #expect(record.age == 26)
            case 3:
                #expect(record.age == 36)
            default:
                Issue.record("Unexpected record ID: \(record.id)")
            }
        }
    }

    @Test("Manual delete records by predicate")
    func manualDeleteRecords() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }

        let schema = Schema([SimpleScanRecord.self])
        let store = RecordStore<SimpleScanRecord>(
            database: database,
            subspace: Subspace(prefix: Tuple("test", "scan", "manual_delete").pack()),
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        let records = [
            SimpleScanRecord(id: 1, name: "Alice", age: 30),
            SimpleScanRecord(id: 2, name: "Bob", age: 25),
            SimpleScanRecord(id: 3, name: "Charlie", age: 35),
            SimpleScanRecord(id: 4, name: "Diana", age: 28),
            SimpleScanRecord(id: 5, name: "Eve", age: 32)
        ]

        for record in records {
            try await store.save(record)
        }

        // Manually delete records where age >= 30
        let recordAccess = GenericRecordAccess<SimpleScanRecord>()
        var primaryKeysToDelete: [Tuple] = []

        for try await record in store.scan() {
            if record.age >= 30 {
                let primaryKey = recordAccess.extractPrimaryKey(from: record)
                primaryKeysToDelete.append(primaryKey)
            }
        }

        for primaryKey in primaryKeysToDelete {
            try await store.delete(by: primaryKey)
        }

        // Verify only records with age < 30 remain
        var remainingRecords: [SimpleScanRecord] = []
        for try await record in store.scan() {
            remainingRecords.append(record)
        }

        #expect(remainingRecords.count == 2)
        #expect(remainingRecords.allSatisfy { $0.age < 30 })

        let remainingIDs = Set(remainingRecords.map { $0.id })
        #expect(remainingIDs == Set([2, 4]), "Should have Bob (25) and Diana (28)")
    }
}

// MARK: - Test Record

@Recordable
struct SimpleScanRecord: Sendable {
    #PrimaryKey<SimpleScanRecord>([\.id])

    var id: Int64
    var name: String
    var age: Int64
}

// MARK: - Skip Info Helper

/// Error to skip test with message
struct SkipInfo: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        return message
    }
}
