import Foundation

/// Protocol for recording metrics from FDB Record Layer components
///
/// This protocol provides an abstraction for **component-level aggregate metrics**,
/// allowing different implementations (swift-metrics, Prometheus, custom, etc.) without
/// coupling core components to specific frameworks.
///
/// **Design Philosophy**:
/// - **Metrics**: Lightweight, high-frequency, aggregate values for dashboards and alerts
/// - **Logs**: Detailed, structured, contextual information for debugging and analysis
///
/// **Metrics vs Logs**:
/// ```swift
/// // Metrics: Component-level aggregation (this protocol)
/// metricsRecorder.recordSave(duration: duration)
/// // → Prometheus: fdb_record_save_total{component="record_store"}
///
/// // Logs: Request-level details (via Logger)
/// logger.trace("Record saved", metadata: [
///     "recordType": "User",
///     "duration_ns": "\(duration)"
/// ])
/// // → Loki: {app="fdb"} | json | recordType="User" | avg(duration_ns)
/// ```
///
/// **For record-type-specific metrics**:
/// Create separate RecordStore instances with different MetricsRecorder components:
/// ```swift
/// let userStore = RecordStore(..., metricsRecorder: SwiftMetricsRecorder(component: "user_records"))
/// let orderStore = RecordStore(..., metricsRecorder: SwiftMetricsRecorder(component: "order_records"))
/// ```
///
/// **Design Pattern**: Protocol Injection + Null Object Pattern
///
/// **Future Extensibility**:
/// - When adding new methods, provide default implementations via `extension MetricsRecorder`
///   to minimize impact on existing implementations
/// - Example: `extension MetricsRecorder { func recordNewMetric(...) {} }`
public protocol MetricsRecorder: Sendable {
    // MARK: - RecordStore Metrics

    /// Record a save operation (aggregate)
    ///
    /// - Parameter duration: Operation duration in nanoseconds
    ///
    /// **Note**: For record-type-specific metrics, use structured logging:
    /// ```swift
    /// logger.trace("Record saved", metadata: ["recordType": "User", "duration_ns": "\(duration)"])
    /// ```
    func recordSave(duration: UInt64)

    /// Record a fetch operation (aggregate)
    ///
    /// - Parameter duration: Operation duration in nanoseconds
    func recordFetch(duration: UInt64)

    /// Record a delete operation (aggregate)
    ///
    /// - Parameter duration: Operation duration in nanoseconds
    func recordDelete(duration: UInt64)

    /// Record an error (aggregate)
    ///
    /// - Parameters:
    ///   - operation: The operation that failed (e.g., "save", "fetch", "delete")
    ///   - errorType: The type of error that occurred
    ///
    /// **Note**: For detailed error context, use structured logging with full error details
    func recordError(operation: String, errorType: String)

    // MARK: - QueryPlanner Metrics

    /// Record query plan generation (aggregate)
    ///
    /// - Parameters:
    ///   - duration: Planning duration in nanoseconds
    ///   - planType: The type of plan generated (e.g., "index_scan", "full_scan")
    func recordQueryPlan(duration: UInt64, planType: String)

    /// Record plan cache hit (aggregate)
    func recordPlanCacheHit()

    /// Record plan cache miss (aggregate)
    func recordPlanCacheMiss()

    // MARK: - OnlineIndexer Metrics

    /// Record indexer batch progress
    ///
    /// - Parameters:
    ///   - indexName: Name of the index being built
    ///   - recordsProcessed: Number of records processed in this batch
    ///   - duration: Batch processing duration in nanoseconds
    func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64)

    /// Record indexer retry
    ///
    /// - Parameters:
    ///   - indexName: Name of the index being built
    ///   - reason: Reason for the retry (e.g., "transaction_too_old")
    func recordIndexerRetry(indexName: String, reason: String)

    /// Record indexer progress
    ///
    /// - Parameters:
    ///   - indexName: Name of the index being built
    ///   - progress: Progress ratio from 0.0 to 1.0
    func recordIndexerProgress(indexName: String, progress: Double)
}

// MARK: - Future Extensions Pattern

// Example of how to add new methods without breaking existing implementations:
// extension MetricsRecorder {
//     func recordNewMetric(param: String) {
//         // Default implementation does nothing (no-op)
//         // Existing implementations are not affected
//     }
// }

// MARK: - Null Object Pattern Implementation

/// Null Object implementation of MetricsRecorder
///
/// This implementation does nothing (no-op) for all metrics recording operations.
/// It serves as the default implementation when metrics collection is not needed.
///
/// **Zero-cost abstraction**: The Swift compiler optimizes away these empty function calls
/// at compile time, resulting in zero runtime overhead.
///
/// **Use cases**:
/// - Default behavior when metrics are not configured
/// - Testing environments where metrics are not needed
/// - Development environments where metrics overhead is undesirable
///
/// **Example**:
/// ```swift
/// // RecordStore uses NullMetricsRecorder by default
/// let store = RecordStore(
///     database: db,
///     subspace: subspace,
///     metaData: metaData,
///     statisticsManager: statsManager
///     // metricsRecorder parameter omitted → uses NullMetricsRecorder()
/// )
/// ```
public struct NullMetricsRecorder: MetricsRecorder {
    /// Initialize a null metrics recorder
    public init() {}

    // MARK: - RecordStore Metrics

    public func recordSave(duration: UInt64) {
        // No-op: Compiler optimizes this away
    }

    public func recordFetch(duration: UInt64) {
        // No-op: Compiler optimizes this away
    }

    public func recordDelete(duration: UInt64) {
        // No-op: Compiler optimizes this away
    }

    public func recordError(operation: String, errorType: String) {
        // No-op: Compiler optimizes this away
    }

    // MARK: - QueryPlanner Metrics

    public func recordQueryPlan(duration: UInt64, planType: String) {
        // No-op: Compiler optimizes this away
    }

    public func recordPlanCacheHit() {
        // No-op: Compiler optimizes this away
    }

    public func recordPlanCacheMiss() {
        // No-op: Compiler optimizes this away
    }

    // MARK: - OnlineIndexer Metrics

    public func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64) {
        // No-op: Compiler optimizes this away
    }

    public func recordIndexerRetry(indexName: String, reason: String) {
        // No-op: Compiler optimizes this away
    }

    public func recordIndexerProgress(indexName: String, progress: Double) {
        // No-op: Compiler optimizes this away
    }
}
