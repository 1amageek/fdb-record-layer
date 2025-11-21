// HNSWIndexHealthTracker.swift
// Circuit breaker pattern for HNSW vector search with automatic fallback

import Foundation
import Synchronization
import Logging

/// Tracks HNSW index health and manages automatic fallback to flat scan
///
/// **Circuit Breaker Pattern**:
/// - `healthy`: HNSW is working normally
/// - `failed`: HNSW failed, automatically falls back to flat scan
/// - `retrying`: Attempting to use HNSW again after cooldown period
///
/// **Usage**:
/// ```swift
/// // Check before query
/// let (shouldUse, reason) = hnswHealthTracker.shouldUseHNSW(indexName: "my_index")
/// if shouldUse {
///     // Use HNSW
///     try await hnswMaintainer.search(...)
///     hnswHealthTracker.recordSuccess(indexName: "my_index")
/// } else {
///     // Use flat scan fallback
///     logger.warning("Fallback: \(reason)")
///     try await flatMaintainer.search(...)
/// }
/// ```
///
/// **Thread Safety**: Uses `Mutex` for concurrent access from multiple queries
public final class HNSWIndexHealthTracker: Sendable {
    // MARK: - Types

    /// Health state for a single HNSW index
    private struct IndexHealth: Sendable {
        var state: State
        var consecutiveFailures: Int
        var lastFailureTime: Date?
        var lastSuccessTime: Date?
        var totalFailures: Int
        var totalSuccesses: Int

        enum State: Sendable, CustomStringConvertible {
            case healthy              // HNSW is working
            case failed               // HNSW failed, using fallback
            case retrying             // Attempting to use HNSW again

            var description: String {
                switch self {
                case .healthy: return "healthy"
                case .failed: return "failed"
                case .retrying: return "retrying"
                }
            }
        }
    }

    /// Configuration for circuit breaker behavior
    public struct Config: Sendable {
        /// Number of consecutive failures before entering failed state
        let failureThreshold: Int

        /// Cooldown period (seconds) before attempting retry
        let retryDelaySeconds: TimeInterval

        /// Maximum number of retry attempts before giving up
        let maxRetries: Int

        public init(
            failureThreshold: Int = 1,
            retryDelaySeconds: TimeInterval = 300,
            maxRetries: Int = 3
        ) {
            self.failureThreshold = failureThreshold
            self.retryDelaySeconds = retryDelaySeconds
            self.maxRetries = maxRetries
        }

        /// Default configuration: fail after 1 error, retry after 5 minutes
        public static let `default` = Config(
            failureThreshold: 1,
            retryDelaySeconds: 300,
            maxRetries: 3
        )

        /// Aggressive configuration: fail immediately, retry after 1 minute
        public static let aggressive = Config(
            failureThreshold: 1,
            retryDelaySeconds: 60,
            maxRetries: 5
        )

        /// Lenient configuration: tolerate 3 failures, retry after 10 minutes
        public static let lenient = Config(
            failureThreshold: 3,
            retryDelaySeconds: 600,
            maxRetries: 2
        )
    }

    // MARK: - Properties

    /// Thread-safe storage for index health states
    private let healthStates: Mutex<[String: IndexHealth]>

    /// Circuit breaker configuration
    private let config: Config

    /// Logger for diagnostics
    private let logger: Logger

    // MARK: - Initialization

    public init(config: Config = .default, logger: Logger? = nil) {
        self.config = config
        self.healthStates = Mutex([:])
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.hnsw.health")
    }

    // MARK: - Public API

    /// Record a successful HNSW search
    ///
    /// Resets consecutive failure count and transitions to healthy state.
    ///
    /// - Parameter indexName: Name of the HNSW index
    public func recordSuccess(indexName: String) {
        healthStates.withLock { states in
            var health = states[indexName] ?? IndexHealth(
                state: .healthy,
                consecutiveFailures: 0,
                lastFailureTime: nil,
                lastSuccessTime: nil,
                totalFailures: 0,
                totalSuccesses: 0
            )

            health.state = .healthy
            health.consecutiveFailures = 0
            health.lastSuccessTime = Date()
            health.totalSuccesses += 1

            states[indexName] = health

            logger.debug("HNSW success for '\(indexName)': \(health.totalSuccesses) total successes")
        }
    }

    /// Record a failed HNSW search
    ///
    /// Increments failure count and may transition to failed state.
    ///
    /// - Parameters:
    ///   - indexName: Name of the HNSW index
    ///   - error: The error that occurred
    public func recordFailure(indexName: String, error: Error) {
        healthStates.withLock { states in
            var health = states[indexName] ?? IndexHealth(
                state: .healthy,
                consecutiveFailures: 0,
                lastFailureTime: nil,
                lastSuccessTime: nil,
                totalFailures: 0,
                totalSuccesses: 0
            )

            health.consecutiveFailures += 1
            health.totalFailures += 1
            health.lastFailureTime = Date()

            if health.consecutiveFailures >= config.failureThreshold {
                health.state = .failed
                logger.warning("HNSW entered failed state for '\(indexName)': \(health.consecutiveFailures) consecutive failures")
            }

            states[indexName] = health

            logger.error("HNSW failure for '\(indexName)': \(error)")
        }
    }

    /// Check if HNSW should be used for this index
    ///
    /// Returns a tuple indicating whether to use HNSW and an optional reason string.
    ///
    /// **Decision Logic**:
    /// - `healthy`: Use HNSW
    /// - `failed`: Check if cooldown passed, if yes → retry, if no → skip
    /// - `retrying`: Use HNSW (give it another chance)
    ///
    /// - Parameter indexName: Name of the HNSW index
    /// - Returns: Tuple of (shouldUse, reason)
    public func shouldUseHNSW(indexName: String) -> (use: Bool, reason: String?) {
        return healthStates.withLock { states in
            guard let health = states[indexName] else {
                // No history, assume healthy
                return (true, nil)
            }

            switch health.state {
            case .healthy:
                return (true, nil)

            case .failed:
                // Check if cooldown period has passed
                if let lastFailure = health.lastFailureTime {
                    let elapsed = Date().timeIntervalSince(lastFailure)
                    if elapsed >= config.retryDelaySeconds {
                        // Attempt retry
                        states[indexName]?.state = .retrying
                        logger.info("HNSW retry attempt for '\(indexName)' after \(Int(elapsed))s cooldown")
                        return (true, "Retrying HNSW after \(Int(elapsed))s cooldown")
                    }
                }

                let reason = "HNSW failed \(health.consecutiveFailures) times (total: \(health.totalFailures)), using flat scan fallback"
                return (false, reason)

            case .retrying:
                return (true, "Retrying HNSW search")
            }
        }
    }

    /// Get diagnostic information for an index
    ///
    /// Returns a multi-line string with health statistics.
    ///
    /// - Parameter indexName: Name of the HNSW index
    /// - Returns: Formatted health information
    public func getHealthInfo(indexName: String) -> String {
        return healthStates.withLock { states in
            guard let health = states[indexName] else {
                return "No health data for index '\(indexName)'"
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .medium

            let lastFailure = health.lastFailureTime.map { dateFormatter.string(from: $0) } ?? "never"
            let lastSuccess = health.lastSuccessTime.map { dateFormatter.string(from: $0) } ?? "never"

            return """
            State: \(health.state)
            Consecutive failures: \(health.consecutiveFailures)
            Total failures: \(health.totalFailures)
            Total successes: \(health.totalSuccesses)
            Last failure: \(lastFailure)
            Last success: \(lastSuccess)
            """
        }
    }

    /// Reset health state for an index
    ///
    /// Call this after successfully rebuilding an HNSW index to mark it as healthy.
    ///
    /// - Parameter indexName: Name of the HNSW index
    public func reset(indexName: String) {
        healthStates.withLock { states in
            states[indexName] = IndexHealth(
                state: .healthy,
                consecutiveFailures: 0,
                lastFailureTime: nil,
                lastSuccessTime: Date(),
                totalFailures: 0,
                totalSuccesses: 0
            )

            logger.info("Reset HNSW health tracker for '\(indexName)'")
        }
    }

    /// Get current state for an index
    ///
    /// - Parameter indexName: Name of the HNSW index
    /// - Returns: Current health state, or nil if no history
    public func getState(indexName: String) -> String? {
        return healthStates.withLock { states in
            states[indexName]?.state.description
        }
    }

    /// Clear all health data
    ///
    /// Useful for testing or resetting the entire tracker.
    public func clearAll() {
        healthStates.withLock { states in
            states.removeAll()
        }
        logger.info("Cleared all HNSW health data")
    }
}

/// Global shared instance for production use
///
/// **Usage**:
/// ```swift
/// if hnswHealthTracker.shouldUseHNSW(indexName: "my_index").use {
///     // Use HNSW
/// } else {
///     // Use flat scan
/// }
/// ```
public let hnswHealthTracker = HNSWIndexHealthTracker()
