import Testing
import Metrics
@testable import FDBRecordLayer

@Suite("SwiftMetricsRecorder Tests")
struct SwiftMetricsRecorderTests {

    @Test("SwiftMetricsRecorder initializes correctly")
    func testInitialization() {
        let recorder = SwiftMetricsRecorder(component: "test")

        // Test passes if initialization succeeds - verify by calling a metric method
        recorder.recordSave(duration: 1_000_000)
        // No crash = success
    }

    @Test("SwiftMetricsRecorder can record save metrics")
    func testRecordSave() {
        let recorder = SwiftMetricsRecorder(component: "test")

        // Should not crash when recording
        recorder.recordSave(duration: 1_000_000)
        recorder.recordSave(duration: 500_000)

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder can record fetch metrics")
    func testRecordFetch() {
        let recorder = SwiftMetricsRecorder(component: "test")

        recorder.recordFetch(duration: 300_000)
        recorder.recordFetch(duration: 200_000)

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder can record delete metrics")
    func testRecordDelete() {
        let recorder = SwiftMetricsRecorder(component: "test")

        recorder.recordDelete(duration: 400_000)
        recorder.recordDelete(duration: 250_000)

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder can record error metrics")
    func testRecordError() {
        let recorder = SwiftMetricsRecorder(component: "test")

        recorder.recordError(operation: "save", errorType: "FDBError")
        recorder.recordError(operation: "fetch", errorType: "NotFoundError")

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder can record query plan metrics")
    func testRecordQueryPlan() {
        let recorder = SwiftMetricsRecorder(component: "test")

        recorder.recordQueryPlan(duration: 2_000_000, planType: "index_scan")
        recorder.recordQueryPlan(duration: 1_500_000, planType: "full_scan")

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder can record plan cache metrics")
    func testRecordPlanCache() {
        let recorder = SwiftMetricsRecorder(component: "test")

        recorder.recordPlanCacheHit()
        recorder.recordPlanCacheMiss()

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder can record indexer metrics")
    func testRecordIndexer() {
        let recorder = SwiftMetricsRecorder(component: "test")

        recorder.recordIndexerBatch(indexName: "user_by_email", recordsProcessed: 1000, duration: 5_000_000)
        recorder.recordIndexerRetry(indexName: "user_by_email", reason: "transaction_too_old")
        recorder.recordIndexerProgress(indexName: "user_by_email", progress: 0.75)

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder can be used concurrently")
    func testConcurrentUsage() async {
        let recorder = SwiftMetricsRecorder(component: "test")

        // Test concurrent metric recording
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    recorder.recordSave(duration: UInt64(i * 1000))
                    recorder.recordFetch(duration: UInt64(i * 500))
                    recorder.recordDelete(duration: UInt64(i * 300))
                }
            }
        }

        // Test passes if no crash occurs
    }

    @Test("SwiftMetricsRecorder respects custom dimensions")
    func testCustomDimensions() {
        let recorder = SwiftMetricsRecorder(
            service: "custom_service",
            component: "custom_component",
            additionalDimensions: [("environment", "test"), ("version", "1.0")]
        )

        // Record some metrics
        recorder.recordSave(duration: 1_000_000)
        recorder.recordFetch(duration: 500_000)

        // Test passes if no crash occurs
        // Note: Actual dimension verification would require prometheus export testing
    }
}
