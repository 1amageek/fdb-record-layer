// HNSWIndexHealthTrackerTests.swift
// Tests for HNSW circuit breaker and health tracking

import Testing
import Foundation
@testable import FDBRecordLayer

@Suite("HNSW Index Health Tracker Tests")
struct HNSWIndexHealthTrackerTests {

    // MARK: - Basic Functionality Tests

    @Test("Initial state is healthy")
    func testInitialState() {
        let tracker = HNSWIndexHealthTracker()

        let (shouldUse, reason) = tracker.shouldUseHNSW(indexName: "test_index")

        #expect(shouldUse == true)
        #expect(reason == nil)
    }

    @Test("Record success marks index as healthy")
    func testRecordSuccess() {
        let tracker = HNSWIndexHealthTracker()

        tracker.recordSuccess(indexName: "test_index")

        let state = tracker.getState(indexName: "test_index")
        #expect(state == "healthy")

        let (shouldUse, _) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == true)
    }

    @Test("Record failure marks index as failed")
    func testRecordFailure() {
        let tracker = HNSWIndexHealthTracker(config: .default)

        struct TestError: Error {}
        tracker.recordFailure(indexName: "test_index", error: TestError())

        let state = tracker.getState(indexName: "test_index")
        #expect(state == "failed")

        let (shouldUse, reason) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == false)
        #expect(reason != nil)
    }

    // MARK: - Circuit Breaker Pattern Tests

    @Test("Circuit breaker activates after threshold failures")
    func testCircuitBreakerActivation() {
        let config = HNSWIndexHealthTracker.Config(
            failureThreshold: 3,
            retryDelaySeconds: 60,
            maxRetries: 2
        )
        let tracker = HNSWIndexHealthTracker(config: config)

        struct TestError: Error {}

        // First 2 failures: still healthy
        tracker.recordFailure(indexName: "test_index", error: TestError())
        var (shouldUse, _) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == true)  // Not yet threshold

        tracker.recordFailure(indexName: "test_index", error: TestError())
        (shouldUse, _) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == true)  // Not yet threshold

        // 3rd failure: circuit breaker activates
        tracker.recordFailure(indexName: "test_index", error: TestError())
        (shouldUse, _) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == false)  // Failed state

        let state = tracker.getState(indexName: "test_index")
        #expect(state == "failed")
    }

    @Test("Success after failure resets consecutive failure count")
    func testSuccessResetsConsecutiveFailures() {
        let tracker = HNSWIndexHealthTracker()

        struct TestError: Error {}

        // Record failure
        tracker.recordFailure(indexName: "test_index", error: TestError())
        var state = tracker.getState(indexName: "test_index")
        #expect(state == "failed")

        // Record success
        tracker.recordSuccess(indexName: "test_index")
        state = tracker.getState(indexName: "test_index")
        #expect(state == "healthy")

        let (shouldUse, _) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == true)
    }

    // MARK: - Retry Logic Tests

    @Test("Retry after cooldown period")
    func testRetryAfterCooldown() {
        let config = HNSWIndexHealthTracker.Config(
            failureThreshold: 1,
            retryDelaySeconds: 0.1,  // Very short for testing
            maxRetries: 3
        )
        let tracker = HNSWIndexHealthTracker(config: config)

        struct TestError: Error {}

        // Record failure
        tracker.recordFailure(indexName: "test_index", error: TestError())
        var (shouldUse, reason) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == false)  // Failed, cooldown not elapsed

        // Wait for cooldown
        Thread.sleep(forTimeInterval: 0.2)

        // Should retry
        (shouldUse, reason) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == true)  // Retrying
        #expect(reason?.contains("Retrying") == true)

        let state = tracker.getState(indexName: "test_index")
        #expect(state == "retrying")
    }

    @Test("No retry before cooldown elapses")
    func testNoRetryBeforeCooldown() {
        let config = HNSWIndexHealthTracker.Config(
            failureThreshold: 1,
            retryDelaySeconds: 10,  // Long cooldown
            maxRetries: 3
        )
        let tracker = HNSWIndexHealthTracker(config: config)

        struct TestError: Error {}

        tracker.recordFailure(indexName: "test_index", error: TestError())

        let (shouldUse, _) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == false)  // Still in cooldown
    }

    // MARK: - Configuration Tests

    @Test("Default configuration values")
    func testDefaultConfiguration() {
        let config = HNSWIndexHealthTracker.Config.default

        #expect(config.failureThreshold == 1)
        #expect(config.retryDelaySeconds == 300)
        #expect(config.maxRetries == 3)
    }

    @Test("Aggressive configuration")
    func testAggressiveConfiguration() {
        let config = HNSWIndexHealthTracker.Config.aggressive

        #expect(config.failureThreshold == 1)
        #expect(config.retryDelaySeconds == 60)
        #expect(config.maxRetries == 5)
    }

    @Test("Lenient configuration")
    func testLenientConfiguration() {
        let config = HNSWIndexHealthTracker.Config.lenient

        #expect(config.failureThreshold == 3)
        #expect(config.retryDelaySeconds == 600)
        #expect(config.maxRetries == 2)
    }

    // MARK: - Reset and Clear Tests

    @Test("Reset clears failure history")
    func testReset() {
        let tracker = HNSWIndexHealthTracker()

        struct TestError: Error {}

        // Record failure
        tracker.recordFailure(indexName: "test_index", error: TestError())
        var state = tracker.getState(indexName: "test_index")
        #expect(state == "failed")

        // Reset
        tracker.reset(indexName: "test_index")
        state = tracker.getState(indexName: "test_index")
        #expect(state == "healthy")

        let (shouldUse, _) = tracker.shouldUseHNSW(indexName: "test_index")
        #expect(shouldUse == true)
    }

    @Test("Clear all removes all index data")
    func testClearAll() {
        let tracker = HNSWIndexHealthTracker()

        tracker.recordSuccess(indexName: "index1")
        tracker.recordSuccess(indexName: "index2")

        var state1 = tracker.getState(indexName: "index1")
        var state2 = tracker.getState(indexName: "index2")
        #expect(state1 == "healthy")
        #expect(state2 == "healthy")

        // Clear all
        tracker.clearAll()

        state1 = tracker.getState(indexName: "index1")
        state2 = tracker.getState(indexName: "index2")
        #expect(state1 == nil)
        #expect(state2 == nil)
    }

    // MARK: - Diagnostic Information Tests

    @Test("Get health info returns formatted information")
    func testGetHealthInfo() {
        let tracker = HNSWIndexHealthTracker()

        tracker.recordSuccess(indexName: "test_index")

        let info = tracker.getHealthInfo(indexName: "test_index")

        #expect(info.contains("State: healthy"))
        #expect(info.contains("Consecutive failures: 0"))
        #expect(info.contains("Total failures: 0"))
        #expect(info.contains("Total successes: 1"))
    }

    @Test("Get health info for non-existent index")
    func testGetHealthInfoNonExistent() {
        let tracker = HNSWIndexHealthTracker()

        let info = tracker.getHealthInfo(indexName: "nonexistent_index")

        #expect(info.contains("No health data"))
    }

    // MARK: - Multiple Index Tests

    @Test("Multiple indexes tracked independently")
    func testMultipleIndexes() {
        let tracker = HNSWIndexHealthTracker()

        struct TestError: Error {}

        // Index1: success
        tracker.recordSuccess(indexName: "index1")

        // Index2: failure
        tracker.recordFailure(indexName: "index2", error: TestError())

        // Check states
        let (shouldUse1, _) = tracker.shouldUseHNSW(indexName: "index1")
        let (shouldUse2, _) = tracker.shouldUseHNSW(indexName: "index2")

        #expect(shouldUse1 == true)   // index1 is healthy
        #expect(shouldUse2 == false)  // index2 is failed
    }

    // MARK: - Statistics Tests

    @Test("Total success and failure counters")
    func testStatisticsCounters() {
        let tracker = HNSWIndexHealthTracker()

        struct TestError: Error {}

        // Record multiple successes and failures
        tracker.recordSuccess(indexName: "test_index")
        tracker.recordSuccess(indexName: "test_index")
        tracker.recordFailure(indexName: "test_index", error: TestError())

        let info = tracker.getHealthInfo(indexName: "test_index")

        #expect(info.contains("Total successes: 2"))
        #expect(info.contains("Total failures: 1"))
    }

    // MARK: - Thread Safety Tests (Conceptual)

    @Test("Concurrent access to same index")
    func testConcurrentAccess() async {
        let tracker = HNSWIndexHealthTracker()

        // Simulate concurrent operations
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    tracker.recordSuccess(indexName: "test_index")
                }
            }
        }

        let info = tracker.getHealthInfo(indexName: "test_index")
        #expect(info.contains("Total successes: 10"))
    }
}
