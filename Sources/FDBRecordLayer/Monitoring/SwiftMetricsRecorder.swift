import Foundation
import Metrics

/// Swift-metrics implementation of MetricsRecorder
///
/// This implementation provides **component-level aggregate metrics** using the
/// `swift-metrics` framework, which can be exported to Prometheus, StatsD, etc.
///
/// **Design Principle**: Metrics = Aggregation, Logs = Details
/// - This recorder tracks **aggregate counts and durations** at the component level
/// - For **record-type-specific** analysis, use structured logging (see MetricsRecorder protocol docs)
///
/// **Prerequisites**:
/// - Application must call `MetricsSystem.bootstrap()` before creating this recorder
/// - Typically done in `main.swift` or application initialization
///
/// **Basic Usage**:
/// ```swift
/// // In main.swift or application startup
/// import Metrics
/// import SwiftPrometheus
///
/// let client = PrometheusClient()
/// MetricsSystem.bootstrap(client)
///
/// // Create recorder for component-level metrics
/// let recorder = SwiftMetricsRecorder(component: "record_store")
/// let store = RecordStore(
///     database: db,
///     subspace: subspace,
///     metaData: metaData,
///     statisticsManager: statsManager,
///     metricsRecorder: recorder
/// )
/// ```
///
/// **For Record-Type-Specific Metrics** (Optional):
/// Create separate RecordStore instances with different components:
/// ```swift
/// let userRecorder = SwiftMetricsRecorder(component: "user_records")
/// let userStore = RecordStore(..., metricsRecorder: userRecorder)
///
/// let orderRecorder = SwiftMetricsRecorder(component: "order_records")
/// let orderStore = RecordStore(..., metricsRecorder: orderRecorder)
/// ```
///
/// **Metrics Naming Conventions**:
/// - Counters: `fdb_<metric>_total` (e.g., `fdb_record_save_total`)
/// - Timers: `fdb_<metric>_duration_seconds`
/// - Gauges: `fdb_<metric>_<unit>`
///
/// **Labels** (Dimensions):
/// - `service`: "fdb_record_layer" (fixed at init)
/// - `component`: Component name (fixed at init, e.g., "record_store", "user_records")
/// - `index_name`: Index name (for indexer metrics only)
///
/// **Why No Dynamic Record-Type Labels?**
/// swift-metrics requires all dimensions to be fixed at metric creation time.
/// Dynamic labels per-call would require creating N×M metric instances (N record types × M metrics),
/// which wastes memory for non-essential observability. Use structured logging for detailed analysis.
public final class SwiftMetricsRecorder: MetricsRecorder {
    // MARK: - Properties

    private let component: String
    private let baseDimensions: [(String, String)]

    // MARK: - RecordStore Metrics

    private let saveCounter: Counter
    private let saveTimer: Timer
    private let fetchCounter: Counter
    private let fetchTimer: Timer
    private let deleteCounter: Counter
    private let deleteTimer: Timer
    private let errorCounter: Counter

    // MARK: - QueryPlanner Metrics

    private let queryPlanCounter: Counter
    private let queryPlanTimer: Timer
    private let planCacheHitCounter: Counter
    private let planCacheMissCounter: Counter

    // MARK: - OnlineIndexer Metrics

    private let indexerBatchCounter: Counter
    private let indexerBatchTimer: Timer
    private let indexerRetryCounter: Counter
    private let indexerProgressGauge: Gauge

    // MARK: - Initialization

    /// Initialize SwiftMetricsRecorder
    ///
    /// - Parameters:
    ///   - service: Service name (default: "fdb_record_layer")
    ///   - component: Component name (e.g., "record_store", "query_planner")
    ///   - additionalDimensions: Additional labels to add to all metrics
    public init(
        service: String = "fdb_record_layer",
        component: String,
        additionalDimensions: [(String, String)] = []
    ) {
        self.component = component
        self.baseDimensions = [
            ("service", service),
            ("component", component)
        ] + additionalDimensions

        // Initialize RecordStore metrics
        self.saveCounter = Counter(
            label: "fdb_record_save_total",
            dimensions: baseDimensions
        )
        self.saveTimer = Timer(
            label: "fdb_record_save_duration_seconds",
            dimensions: baseDimensions
        )
        self.fetchCounter = Counter(
            label: "fdb_record_fetch_total",
            dimensions: baseDimensions
        )
        self.fetchTimer = Timer(
            label: "fdb_record_fetch_duration_seconds",
            dimensions: baseDimensions
        )
        self.deleteCounter = Counter(
            label: "fdb_record_delete_total",
            dimensions: baseDimensions
        )
        self.deleteTimer = Timer(
            label: "fdb_record_delete_duration_seconds",
            dimensions: baseDimensions
        )
        self.errorCounter = Counter(
            label: "fdb_record_error_total",
            dimensions: baseDimensions
        )

        // Initialize QueryPlanner metrics
        self.queryPlanCounter = Counter(
            label: "fdb_query_plan_total",
            dimensions: baseDimensions
        )
        self.queryPlanTimer = Timer(
            label: "fdb_query_plan_duration_seconds",
            dimensions: baseDimensions
        )
        self.planCacheHitCounter = Counter(
            label: "fdb_plan_cache_hit_total",
            dimensions: baseDimensions
        )
        self.planCacheMissCounter = Counter(
            label: "fdb_plan_cache_miss_total",
            dimensions: baseDimensions
        )

        // Initialize OnlineIndexer metrics
        self.indexerBatchCounter = Counter(
            label: "fdb_indexer_batch_total",
            dimensions: baseDimensions
        )
        self.indexerBatchTimer = Timer(
            label: "fdb_indexer_batch_duration_seconds",
            dimensions: baseDimensions
        )
        self.indexerRetryCounter = Counter(
            label: "fdb_indexer_retry_total",
            dimensions: baseDimensions
        )
        self.indexerProgressGauge = Gauge(
            label: "fdb_indexer_progress_ratio",
            dimensions: baseDimensions
        )
    }

    // MARK: - RecordStore Metrics

    public func recordSave(duration: UInt64) {
        saveCounter.increment()
        saveTimer.recordNanoseconds(duration)
    }

    public func recordFetch(duration: UInt64) {
        fetchCounter.increment()
        fetchTimer.recordNanoseconds(duration)
    }

    public func recordDelete(duration: UInt64) {
        deleteCounter.increment()
        deleteTimer.recordNanoseconds(duration)
    }

    public func recordError(operation: String, errorType: String) {
        errorCounter.increment()
    }

    // MARK: - QueryPlanner Metrics

    public func recordQueryPlan(duration: UInt64, planType: String) {
        queryPlanCounter.increment()
        queryPlanTimer.recordNanoseconds(duration)
    }

    public func recordPlanCacheHit() {
        planCacheHitCounter.increment()
    }

    public func recordPlanCacheMiss() {
        planCacheMissCounter.increment()
    }

    // MARK: - OnlineIndexer Metrics

    public func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64) {
        indexerBatchCounter.increment(by: recordsProcessed)
        indexerBatchTimer.recordNanoseconds(duration)
    }

    public func recordIndexerRetry(indexName: String, reason: String) {
        indexerRetryCounter.increment()
    }

    public func recordIndexerProgress(indexName: String, progress: Double) {
        indexerProgressGauge.record(progress)
    }
}
