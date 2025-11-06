import Testing
import Foundation
import FoundationDB
import Synchronization
@testable import FDBRecordLayer

// MARK: - Mock MetricsRecorder

/// Mock metrics recorder for testing
final class MockMetricsRecorder: MetricsRecorder {
    struct RecordedMetric: Sendable {
        let duration: UInt64?
        let operation: String?
        let errorType: String?

        init(duration: UInt64? = nil, operation: String? = nil, errorType: String? = nil) {
            self.duration = duration
            self.operation = operation
            self.errorType = errorType
        }
    }

    private let _saves = Mutex<[RecordedMetric]>([])
    private let _fetches = Mutex<[RecordedMetric]>([])
    private let _deletes = Mutex<[RecordedMetric]>([])
    private let _errors = Mutex<[RecordedMetric]>([])

    var saves: [RecordedMetric] {
        _saves.withLock { $0 }
    }

    var fetches: [RecordedMetric] {
        _fetches.withLock { $0 }
    }

    var deletes: [RecordedMetric] {
        _deletes.withLock { $0 }
    }

    var errors: [RecordedMetric] {
        _errors.withLock { $0 }
    }

    func recordSave(duration: UInt64) {
        _saves.withLock {
            $0.append(RecordedMetric(duration: duration))
        }
    }

    func recordFetch(duration: UInt64) {
        _fetches.withLock {
            $0.append(RecordedMetric(duration: duration))
        }
    }

    func recordDelete(duration: UInt64) {
        _deletes.withLock {
            $0.append(RecordedMetric(duration: duration))
        }
    }

    func recordError(operation: String, errorType: String) {
        _errors.withLock {
            $0.append(RecordedMetric(operation: operation, errorType: errorType))
        }
    }

    // Query planner metrics (not tested in this suite)
    func recordQueryPlan(duration: UInt64, planType: String) {}
    func recordPlanCacheHit() {}
    func recordPlanCacheMiss() {}

    // Indexer metrics (not tested in this suite)
    func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64) {}
    func recordIndexerRetry(indexName: String, reason: String) {}
    func recordIndexerProgress(indexName: String, progress: Double) {}

    func reset() {
        _saves.withLock { $0.removeAll() }
        _fetches.withLock { $0.removeAll() }
        _deletes.withLock { $0.removeAll() }
        _errors.withLock { $0.removeAll() }
    }
}

// MARK: - RecordStore Metrics Integration Tests

// TODO: Re-enable when TestUser is available
/*
@Suite("RecordStore Metrics Integration Tests")
struct RecordStoreMetricsIntegrationTests {

    @Test("RecordStore with NullMetricsRecorder works correctly")
    func testNullMetricsRecorder() async throws {
        let (db, subspace, metaData, statsManager) = try setupTestEnvironment()

        // Create RecordStore with default NullMetricsRecorder
        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: statsManager
            // metricsRecorder omitted → uses NullMetricsRecorder()
        )

        let testUser = TestUser.with {
            $0.userID = 1
            $0.name = "Alice"
            $0.email = "alice@example.com"
        }

        // These operations should work without crashing
        try await store.save(testUser)
        let fetched = try await store.fetch(TestUser.self, by: Int64(1))
        #expect(fetched != nil)

        try await store.delete(TestUser.self, by: Int64(1))

        // Test passes if no crash occurs
    }

    @Test("RecordStore records save metrics correctly")
    func testRecordSaveMetrics() async throws {
        let (db, subspace, metaData, statsManager) = try setupTestEnvironment()
        let mockRecorder = MockMetricsRecorder()

        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: statsManager,
            metricsRecorder: mockRecorder
        )

        let testUser = TestUser.with {
            $0.userID = 2
            $0.name = "Bob"
            $0.email = "bob@example.com"
        }

        try await store.save(testUser)

        // Verify metrics were recorded
        let saves = mockRecorder.saves
        #expect(saves.count == 1)
        #expect(saves[0].duration != nil)
        #expect(saves[0].duration! > 0)
    }

    @Test("RecordStore records fetch metrics correctly")
    func testRecordFetchMetrics() async throws {
        let (db, subspace, metaData, statsManager) = try setupTestEnvironment()
        let mockRecorder = MockMetricsRecorder()

        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: statsManager,
            metricsRecorder: mockRecorder
        )

        // Save a record first
        let testUser = TestUser.with {
            $0.userID = 3
            $0.name = "Carol"
            $0.email = "carol@example.com"
        }
        try await store.save(testUser)

        mockRecorder.reset()

        // Fetch the record
        _ = try await store.fetch(TestUser.self, by: Int64(3))

        // Verify metrics were recorded
        let fetches = mockRecorder.fetches
        #expect(fetches.count == 1)
        #expect(fetches[0].duration != nil)
        #expect(fetches[0].duration! > 0)
    }

    @Test("RecordStore records fetch metrics for non-existent record")
    func testRecordFetchMetricsNonExistent() async throws {
        let (db, subspace, metaData, statsManager) = try setupTestEnvironment()
        let mockRecorder = MockMetricsRecorder()

        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: statsManager,
            metricsRecorder: mockRecorder
        )

        // Fetch non-existent record
        let result = try await store.fetch(TestUser.self, by: Int64(999))
        #expect(result == nil)

        // Verify metrics were still recorded
        let fetches = mockRecorder.fetches
        #expect(fetches.count == 1)
        #expect(fetches[0].duration != nil)
    }

    @Test("RecordStore records delete metrics correctly")
    func testRecordDeleteMetrics() async throws {
        let (db, subspace, metaData, statsManager) = try setupTestEnvironment()
        let mockRecorder = MockMetricsRecorder()

        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: statsManager,
            metricsRecorder: mockRecorder
        )

        // Save a record first
        let testUser = TestUser.with {
            $0.userID = 4
            $0.name = "Dave"
            $0.email = "dave@example.com"
        }
        try await store.save(testUser)

        mockRecorder.reset()

        // Delete the record
        try await store.delete(TestUser.self, by: Int64(4))

        // Verify metrics were recorded
        let deletes = mockRecorder.deletes
        #expect(deletes.count == 1)
        #expect(deletes[0].duration != nil)
        #expect(deletes[0].duration! > 0)
    }

    @Test("RecordStore records multiple operations")
    func testMultipleOperations() async throws {
        let (db, subspace, metaData, statsManager) = try setupTestEnvironment()
        let mockRecorder = MockMetricsRecorder()

        let store = RecordStore(
            database: db,
            subspace: subspace,
            metaData: metaData,
            statisticsManager: statsManager,
            metricsRecorder: mockRecorder
        )

        // Perform multiple operations
        for i in 10...14 {
            let testUser = TestUser.with {
                $0.userID = Int64(i)
                $0.name = "User\(i)"
                $0.email = "user\(i)@example.com"
            }
            try await store.save(testUser)
        }

        // Fetch some records
        _ = try await store.fetch(TestUser.self, by: Int64(10))
        _ = try await store.fetch(TestUser.self, by: Int64(11))

        // Delete a record
        try await store.delete(TestUser.self, by: Int64(12))

        // Verify metrics
        #expect(mockRecorder.saves.count == 5)
        #expect(mockRecorder.fetches.count == 2)
        #expect(mockRecorder.deletes.count == 1)

        // All metrics should have valid durations
        for save in mockRecorder.saves {
            #expect(save.duration! > 0)
        }
        for fetch in mockRecorder.fetches {
            #expect(fetch.duration! > 0)
        }
        for delete in mockRecorder.deletes {
            #expect(delete.duration! > 0)
        }
    }

    // MARK: - Test Helpers

    private func setupTestEnvironment() throws -> (any DatabaseProtocol, Subspace, RecordMetaData, any StatisticsManagerProtocol) {
        let db = try FDB.selectAPIVersion(710).createDatabase()
        let testID = UUID().uuidString
        let subspace = Subspace(rootPrefix: "test_metrics_\(testID)")

        let metaData = RecordMetaData()

        let statsManager = NullStatisticsManager()

        return (db, subspace, metaData, statsManager)
    }
}
*/
