import Testing
@testable import FDBRecordLayer

@Suite("NullMetricsRecorder Tests")
struct NullMetricsRecorderTests {

    @Test("NullMetricsRecorder does not crash on RecordStore metrics")
    func testRecordStoreMetrics() {
        let recorder = NullMetricsRecorder()

        // All methods should be callable without crashing
        recorder.recordSave(duration: 1_000_000)
        recorder.recordFetch(duration: 500_000)
        recorder.recordDelete(duration: 300_000)
        recorder.recordError(operation: "save", errorType: "TestError")

        // Test passes if no crash occurs
    }

    @Test("NullMetricsRecorder does not crash on QueryPlanner metrics")
    func testQueryPlannerMetrics() {
        let recorder = NullMetricsRecorder()

        // All methods should be callable without crashing
        recorder.recordQueryPlan(duration: 2_000_000, planType: "index_scan")
        recorder.recordPlanCacheHit()
        recorder.recordPlanCacheMiss()

        // Test passes if no crash occurs
    }

    @Test("NullMetricsRecorder does not crash on OnlineIndexer metrics")
    func testOnlineIndexerMetrics() {
        let recorder = NullMetricsRecorder()

        // All methods should be callable without crashing
        recorder.recordIndexerBatch(indexName: "user_by_email", recordsProcessed: 1000, duration: 5_000_000)
        recorder.recordIndexerRetry(indexName: "user_by_email", reason: "transaction_too_old")
        recorder.recordIndexerProgress(indexName: "user_by_email", progress: 0.75)

        // Test passes if no crash occurs
    }

    @Test("NullMetricsRecorder can be called repeatedly")
    func testRepeatedCalls() {
        let recorder = NullMetricsRecorder()

        // Call the same metric multiple times
        for i in 0..<1000 {
            recorder.recordSave(duration: UInt64(i))
            recorder.recordFetch(duration: UInt64(i))
            recorder.recordDelete(duration: UInt64(i))
        }

        // Test passes if no crash occurs and performance is acceptable
    }

    @Test("NullMetricsRecorder is Sendable")
    func testSendable() async {
        let recorder = NullMetricsRecorder()

        // Test that recorder can be used across concurrency boundaries
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    recorder.recordSave(duration: UInt64(i))
                }
            }
        }

        // Test passes if no crash occurs
    }
}
