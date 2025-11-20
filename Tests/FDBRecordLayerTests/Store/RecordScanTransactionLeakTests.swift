import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer
@testable import FDBRecordCore

/// Tests for RecordStore.scan() transaction leak prevention (Bug Fix Verification)
///
/// These tests verify that transactions are properly cleaned up when:
/// - Iterator is dropped mid-stream (early break)
/// - maxRecordsPerBatch is reached and iterator is dropped
/// - Scan completes naturally
@Suite("RecordScan Transaction Leak Tests", .tags(.integration))
struct RecordScanTransactionLeakTests {

    // MARK: - Test Model

    @Recordable
    struct TestRecord {
        #PrimaryKey<TestRecord>([\.id])
        var id: Int64
        var value: String
    }

    // MARK: - Helper Methods

    private func initializeFDB() throws {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized
        }
    }

    private func createTestRecords(count: Int) -> [TestRecord] {
        return (1...count).map { i in
            TestRecord(id: Int64(i), value: "Record \(i)")
        }
    }

    // MARK: - Transaction Cleanup Tests

    @Test("Iterator dropped mid-stream cleans up transaction (deinit)")
    func testIteratorDroppedMidStream() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([TestRecord.self])
        let testSubspace = Subspace(prefix: Tuple("scan-leak-test", UUID().uuidString).pack())
        let store = RecordStore<TestRecord>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert 100 records
        let records = createTestRecords(count: 100)
        for record in records {
            try await store.save(record)
        }

        // Scan and break early (drop iterator mid-stream)
        var scannedCount = 0
        for try await _ in store.scan() {
            scannedCount += 1
            if scannedCount >= 10 {
                // ✅ Break early - iterator dropped here
                // AsyncIterator.deinit should cancel the transaction
                break
            }
        }

        #expect(scannedCount == 10, "Should scan exactly 10 records before breaking")

        // Give a moment for deinit cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

        // Verify database is still usable (no leaked transactions blocking)
        let readAfter = try await store.query().execute()
        #expect(readAfter.count == 100, "Database should still be usable after iterator drop")

        // ✅ If transaction wasn't cleaned up, subsequent operations might be blocked
        // or we'd see timeout errors. This test verifies cleanup by checking database health.
    }

    @Test("maxRecordsPerBatch reached, then iterator dropped")
    func testMaxRecordsPerBatchThenDrop() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([TestRecord.self])
        let testSubspace = Subspace(prefix: Tuple("scan-leak-test", UUID().uuidString).pack())
        let store = RecordStore<TestRecord>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert 200 records (more than default batch size of 100)
        let records = createTestRecords(count: 200)
        for record in records {
            try await store.save(record)
        }

        // Scan and break after first batch completes
        // Default maxRecordsPerBatch is 100
        var scannedCount = 0
        for try await _ in store.scan() {
            scannedCount += 1
            if scannedCount >= 125 {
                // ✅ Break after default maxRecordsPerBatch (100) is exceeded
                // - First batch completes (100 records)
                // - Second batch starts, kvIterator is recreated
                // - Break at 125, iterator dropped with active transaction
                // - AsyncIterator.deinit should cancel the transaction
                break
            }
        }

        #expect(scannedCount == 125, "Should scan exactly 125 records (across 2 batches)")

        // Give a moment for deinit cleanup
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

        // Verify database is still usable
        let readAfter = try await store.query().execute()
        #expect(readAfter.count == 200, "Database should still be usable")
    }

    @Test("Natural scan completion cleans up transaction")
    func testNaturalScanCompletion() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([TestRecord.self])
        let testSubspace = Subspace(prefix: Tuple("scan-leak-test", UUID().uuidString).pack())
        let store = RecordStore<TestRecord>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert 50 records
        let records = createTestRecords(count: 50)
        for record in records {
            try await store.save(record)
        }

        // Scan all records to completion (natural end)
        var scannedCount = 0
        for try await _ in store.scan() {
            scannedCount += 1
        }

        #expect(scannedCount == 50, "Should scan all 50 records")

        // Verify database is still usable
        let readAfter = try await store.query().execute()
        #expect(readAfter.count == 50, "Database should still be usable")

        // ✅ Natural completion should clean up transaction via guard else branch
    }

    @Test("Multiple concurrent scans with early breaks")
    func testMultipleConcurrentScansWithBreaks() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([TestRecord.self])
        let testSubspace = Subspace(prefix: Tuple("scan-leak-test", UUID().uuidString).pack())
        let store = RecordStore<TestRecord>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert 100 records
        let records = createTestRecords(count: 100)
        for record in records {
            try await store.save(record)
        }

        // Launch multiple concurrent scans, each breaking early
        try await withThrowingTaskGroup(of: Int.self) { group in
            for taskID in 1...5 {
                group.addTask {
                    var count = 0
                    for try await _ in store.scan() {
                        count += 1
                        if count >= 10 * taskID {
                            break
                        }
                    }
                    return count
                }
            }

            // Wait for all tasks to complete
            var totalScanned = 0
            for try await count in group {
                totalScanned += count
            }

            // Expected: 10 + 20 + 30 + 40 + 50 = 150
            #expect(totalScanned == 150, "Total scanned across all tasks should be 150")
        }

        // Give a moment for all deinit cleanups
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 second

        // Verify database is still healthy after multiple concurrent scans
        let readAfter = try await store.query().execute()
        #expect(readAfter.count == 100, "Database should still be usable after concurrent scans")

        // ✅ All 5 iterators dropped with active transactions
        // All should be cleaned up via deinit
    }

    // MARK: - Edge Case: Empty Scan

    @Test("Empty scan (no records) cleans up transaction")
    func testEmptyScan() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([TestRecord.self])
        let testSubspace = Subspace(prefix: Tuple("scan-leak-test", UUID().uuidString).pack())
        let store = RecordStore<TestRecord>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // No records inserted
        var scannedCount = 0
        for try await _ in store.scan() {
            scannedCount += 1
        }

        #expect(scannedCount == 0, "Should scan 0 records")

        // Verify database is still usable
        try await store.save(TestRecord(id: 1, value: "Test"))
        let readAfter = try await store.query().execute()
        #expect(readAfter.count == 1, "Database should still be usable after empty scan")
    }

    // MARK: - Performance Test: No Timeout from Leaked Transactions

    @Test("Many early-break scans don't cause timeout")
    func testManyEarlyBreaksNoTimeout() async throws {
        try initializeFDB()
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        let schema = Schema([TestRecord.self])
        let testSubspace = Subspace(prefix: Tuple("scan-leak-test", UUID().uuidString).pack())
        let store = RecordStore<TestRecord>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Insert 1000 records
        let records = createTestRecords(count: 1000)
        for record in records {
            try await store.save(record)
        }

        // Perform 100 scans, each breaking after 5 records
        // If transactions aren't cleaned up, this would accumulate 100 leaked transactions
        // and cause resource exhaustion
        for iteration in 1...100 {
            var count = 0
            for try await _ in store.scan() {
                count += 1
                if count >= 5 {
                    break
                }
            }
            #expect(count == 5, "Iteration \(iteration) should scan 5 records")
        }

        // Give time for all deinit cleanups
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second

        // Verify database is still responsive (no timeout from leaked transactions)
        let readAfter = try await store.query().execute()
        #expect(readAfter.count == 1000, "Database should still be responsive after 100 early-break scans")

        // ✅ If transactions were leaked, this test would timeout or fail
        // because FDB has limits on concurrent transactions
    }
}
