# Metrics and Logging Architecture

## Design Philosophy: Separation of Concerns

This document explains the architectural decision to separate **Metrics** and **Logging** in the FDB Record Layer, and how to use each effectively.

## Core Principle

**Metrics = Aggregation, Logs = Details**

- **Metrics**: Lightweight, high-frequency, aggregate values for dashboards and alerts
- **Logs**: Detailed, structured, contextual information for debugging and analysis

## Why This Separation?

### The Problem with Dynamic Metrics

Initially, we considered tracking `recordType` in metrics (e.g., `fdb_record_save_total{recordType="User"}`). However, this approach has fundamental issues:

1. **Memory waste**: Creating N×M metric instances (N record types × M metrics) wastes memory for non-essential observability
2. **swift-metrics constraint**: The framework requires all dimensions to be fixed at metric creation time, making dynamic labels inefficient
3. **Cardinality explosion**: In production systems with many record types, this creates an explosion of time-series data

### The Solution: Metrics vs Logs Separation

```swift
// Metrics: Component-level aggregation
metricsRecorder.recordSave(duration: duration)
// → Prometheus: fdb_record_save_total{component="record_store"}

// Logs: Request-level details
logger.trace("Record saved", metadata: [
    "recordType": "User",
    "duration_ns": "\(duration)",
    "operation": "save"
])
// → Loki: {app="fdb"} | json | recordType="User" | avg(duration_ns)
```

## Implementation

### MetricsRecorder Protocol

The `MetricsRecorder` protocol provides **component-level aggregate metrics**:

```swift
public protocol MetricsRecorder: Sendable {
    // RecordStore Metrics (no recordType parameter)
    func recordSave(duration: UInt64)
    func recordFetch(duration: UInt64)
    func recordDelete(duration: UInt64)
    func recordError(operation: String, errorType: String)

    // QueryPlanner Metrics
    func recordQueryPlan(duration: UInt64, planType: String)
    func recordPlanCacheHit()
    func recordPlanCacheMiss()

    // OnlineIndexer Metrics (indexName is pre-defined and limited)
    func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64)
    func recordIndexerRetry(indexName: String, reason: String)
    func recordIndexerProgress(indexName: String, progress: Double)
}
```

### SwiftMetricsRecorder Implementation

The `SwiftMetricsRecorder` uses `swift-metrics` framework with **fixed dimensions**:

```swift
public final class SwiftMetricsRecorder: MetricsRecorder {
    private let component: String
    private let baseDimensions: [(String, String)]

    // Pre-initialized metrics with fixed dimensions
    private let saveCounter: Counter
    private let saveTimer: Timer
    // ...

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

        // Initialize metrics with fixed dimensions
        self.saveCounter = Counter(
            label: "fdb_record_save_total",
            dimensions: baseDimensions
        )
        // ...
    }

    public func recordSave(duration: UInt64) {
        saveCounter.increment()
        saveTimer.recordNanoseconds(duration)
    }
}
```

### RecordStore Integration

RecordStore integrates both metrics and structured logging:

```swift
public func save<T: Recordable>(_ record: T) async throws {
    let start = DispatchTime.now()

    do {
        // ... perform save operation ...

        let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds

        // Record aggregate metrics (component-level)
        metricsRecorder.recordSave(duration: duration)

        // Record structured log with details (request-level)
        logger.trace("Record saved", metadata: [
            "recordType": "\(T.recordTypeName)",
            "duration_ns": "\(duration)",
            "operation": "save"
        ])
    } catch {
        // Record error metrics
        metricsRecorder.recordError(
            operation: "save",
            errorType: String(reflecting: Swift.type(of: error))
        )

        // Record detailed error log
        logger.error("Failed to save record", metadata: [
            "recordType": "\(T.recordTypeName)",
            "operation": "save",
            "error": "\(error)"
        ])

        throw error
    }
}
```

## Usage Patterns

### Pattern 1: Component-Level Monitoring

For general monitoring of RecordStore performance across all record types:

```swift
let recorder = SwiftMetricsRecorder(component: "record_store")
let store = RecordStore(
    database: db,
    subspace: subspace,
    metaData: metaData,
    statisticsManager: statsManager,
    metricsRecorder: recorder
)

// Metrics will aggregate all operations across all record types
```

**Prometheus Query**:
```promql
# Total save operations per second
rate(fdb_record_save_total{component="record_store"}[5m])

# Average save duration
rate(fdb_record_save_duration_seconds_sum{component="record_store"}[5m])
  / rate(fdb_record_save_duration_seconds_count{component="record_store"}[5m])
```

### Pattern 2: Record-Type-Specific Monitoring

For fine-grained monitoring of specific record types, create separate RecordStore instances:

```swift
// Separate metrics for User records
let userRecorder = SwiftMetricsRecorder(component: "user_records")
let userStore = RecordStore(
    database: db,
    subspace: userSubspace,
    metaData: metaData,
    statisticsManager: statsManager,
    metricsRecorder: userRecorder
)

// Separate metrics for Order records
let orderRecorder = SwiftMetricsRecorder(component: "order_records")
let orderStore = RecordStore(
    database: db,
    subspace: orderSubspace,
    metaData: metaData,
    statisticsManager: statsManager,
    metricsRecorder: orderRecorder
)
```

**Prometheus Query**:
```promql
# User save operations
rate(fdb_record_save_total{component="user_records"}[5m])

# Order save operations
rate(fdb_record_save_total{component="order_records"}[5m])
```

### Pattern 3: Log-Based Analysis

For ad-hoc analysis of specific record types or detailed debugging, use structured logs:

**Grafana Loki Query**:
```logql
# Average duration by record type
{app="fdb"}
  | json
  | recordType="User"
  | unwrap duration_ns
  | avg by (recordType)

# Error rate by record type and operation
{app="fdb"}
  | json
  | level="error"
  | rate(1m) by (recordType, operation)

# 95th percentile duration for User saves
{app="fdb"}
  | json
  | recordType="User"
  | operation="save"
  | unwrap duration_ns
  | quantile_over_time(0.95, duration_ns[5m])
```

### Pattern 4: Hybrid Monitoring

Combine metrics and logs for comprehensive observability:

**Alerts** (Prometheus):
```yaml
# Alert on high error rate (component-level)
- alert: HighRecordStoreErrorRate
  expr: |
    rate(fdb_record_error_total{component="record_store"}[5m]) > 0.1
  annotations:
    summary: "RecordStore error rate is high"

# Alert on slow operations (component-level)
- alert: SlowRecordStoreSaves
  expr: |
    histogram_quantile(0.95,
      rate(fdb_record_save_duration_seconds_bucket{component="record_store"}[5m])
    ) > 0.1
  annotations:
    summary: "RecordStore saves are slow (p95 > 100ms)"
```

**Investigation** (Loki):
```logql
# When alert fires, investigate by record type
{app="fdb"}
  | json
  | operation="save"
  | duration_ns > 100000000  # > 100ms
  | line_format "{{.recordType}}: {{.duration_ns}}ns"
```

## Benefits of This Approach

### 1. Memory Efficiency

- **Fixed number of metrics**: O(M) where M = number of metrics
- **No dynamic label creation**: Avoids N×M metric instances
- **Predictable resource usage**: Memory footprint is constant regardless of record types

### 2. Performance

- **Metrics are fast**: Simple counter/timer updates with no allocation
- **Logs are structured**: Efficient JSON encoding with lazy evaluation
- **Log levels**: Can disable trace logs in production for performance

### 3. Flexibility

- **Component-level dashboards**: Quick overview of system health
- **Record-type-specific stores**: Fine-grained monitoring when needed
- **Log-based ad-hoc queries**: Detailed analysis without predefined metrics

### 4. Operational Simplicity

- **Fewer metrics to manage**: Reduced Prometheus/Grafana configuration
- **Lower cardinality**: Prevents time-series database bloat
- **Clear separation**: Easy to understand what goes where

## Best Practices

### 1. Use Metrics for Monitoring

✅ **DO**: Use metrics for dashboards and alerts
```swift
// Good: Component-level aggregation
metricsRecorder.recordSave(duration: duration)
```

❌ **DON'T**: Try to track every detail in metrics
```swift
// Bad: Trying to add dynamic labels
// This is not supported by the API anymore
metricsRecorder.recordSave(recordType: recordType, duration: duration)
```

### 2. Use Logs for Debugging

✅ **DO**: Use structured logs for detailed context
```swift
// Good: Rich contextual information
logger.trace("Record saved", metadata: [
    "recordType": "\(T.recordTypeName)",
    "duration_ns": "\(duration)",
    "operation": "save",
    "primaryKey": "\(primaryKey)"
])
```

❌ **DON'T**: Log everything at high log levels
```swift
// Bad: High-frequency logs at error level
logger.error("Record saved")  // Not an error!
```

### 3. Choose the Right Log Level

- **`trace`**: High-frequency operations (save, fetch, delete)
- **`debug`**: Low-frequency operations (query planning)
- **`info`**: Significant events (index build start/complete)
- **`warning`**: Recoverable issues (retry after conflict)
- **`error`**: Unrecoverable errors (unexpected failures)

### 4. Structure Your Metadata

Always include these fields in operation logs:
```swift
logger.trace("Record saved", metadata: [
    "recordType": "\(T.recordTypeName)",    // What type
    "duration_ns": "\(duration)",           // How long
    "operation": "save"                     // What operation
])
```

For errors, include:
```swift
logger.error("Failed to save record", metadata: [
    "recordType": "\(T.recordTypeName)",
    "operation": "save",
    "error": "\(error)",                    // Error details
    "errorType": "\(type(of: error))"       // Error type
])
```

## Migration Guide

If you have existing code that expects `recordType` in metrics:

### Before
```swift
metricsRecorder.recordSave(recordType: "User", duration: duration)
```

### After
```swift
// Metrics (component-level)
metricsRecorder.recordSave(duration: duration)

// Logs (record-level details)
logger.trace("Record saved", metadata: [
    "recordType": "User",
    "duration_ns": "\(duration)",
    "operation": "save"
])
```

### If you need record-type-specific metrics

Create separate RecordStore instances:
```swift
// Before: Single store with recordType in metrics
let store = RecordStore(..., metricsRecorder: recorder)
recorder.recordSave(recordType: "User", duration: duration)

// After: Separate stores with different components
let userStore = RecordStore(
    ...,
    metricsRecorder: SwiftMetricsRecorder(component: "user_records")
)
let orderStore = RecordStore(
    ...,
    metricsRecorder: SwiftMetricsRecorder(component: "order_records")
)
```

## Conclusion

The separation of Metrics and Logging provides:
- **Efficient resource usage**: Fixed number of metrics, no cardinality explosion
- **Clear architecture**: Metrics for aggregation, logs for details
- **Operational flexibility**: Component-level monitoring + log-based analysis
- **Swift-metrics compatibility**: Works within framework constraints

This design is well-reasoned, memory-efficient, and provides operators with low overhead while keeping the implementation simple and error-resistant.
