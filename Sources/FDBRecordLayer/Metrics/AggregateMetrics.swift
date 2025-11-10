import Foundation
import Synchronization

/// Metrics for aggregate index queries (COUNT, SUM, MIN, MAX)
public final class AggregateMetrics: Sendable {
    private let metricsLock: Mutex<Metrics>

    private struct Metrics {
        var totalQueries: UInt64 = 0
        var successfulQueries: UInt64 = 0
        var failedQueries: UInt64 = 0
        var validationErrors: UInt64 = 0
        var totalQueryTime: TimeInterval = 0.0
        var minQueryTime: TimeInterval = .infinity
        var maxQueryTime: TimeInterval = 0.0

        // Per-index metrics
        var indexMetrics: [String: IndexMetrics] = [:]

        // Per-aggregate-type metrics
        var typeMetrics: [AggregateType: TypeMetrics] = [:]
    }

    private struct IndexMetrics {
        var queryCount: UInt64 = 0
        var totalTime: TimeInterval = 0.0
        var errors: UInt64 = 0
    }

    private struct TypeMetrics {
        var queryCount: UInt64 = 0
        var totalTime: TimeInterval = 0.0
        var errors: UInt64 = 0
    }

    public init() {
        self.metricsLock = Mutex(Metrics())
    }

    // MARK: - Recording

    /// Record a successful aggregate query
    public func recordQuery(
        indexName: String,
        aggregateType: AggregateType,
        duration: TimeInterval
    ) {
        metricsLock.withLock { metrics in
            metrics.totalQueries += 1
            metrics.successfulQueries += 1
            metrics.totalQueryTime += duration
            metrics.minQueryTime = min(metrics.minQueryTime, duration)
            metrics.maxQueryTime = max(metrics.maxQueryTime, duration)

            // Update index metrics
            var indexMetric = metrics.indexMetrics[indexName, default: IndexMetrics()]
            indexMetric.queryCount += 1
            indexMetric.totalTime += duration
            metrics.indexMetrics[indexName] = indexMetric

            // Update type metrics
            var typeMetric = metrics.typeMetrics[aggregateType, default: TypeMetrics()]
            typeMetric.queryCount += 1
            typeMetric.totalTime += duration
            metrics.typeMetrics[aggregateType] = typeMetric
        }
    }

    /// Record a failed aggregate query
    public func recordFailure(
        indexName: String,
        aggregateType: AggregateType,
        error: Error
    ) {
        metricsLock.withLock { metrics in
            metrics.totalQueries += 1
            metrics.failedQueries += 1

            // Update index metrics
            var indexMetric = metrics.indexMetrics[indexName, default: IndexMetrics()]
            indexMetric.errors += 1
            metrics.indexMetrics[indexName] = indexMetric

            // Update type metrics
            var typeMetric = metrics.typeMetrics[aggregateType, default: TypeMetrics()]
            typeMetric.errors += 1
            metrics.typeMetrics[aggregateType] = typeMetric

            // Check if it's a validation error
            if let recordLayerError = error as? RecordLayerError {
                switch recordLayerError {
                case .invalidArgument, .indexNotReady:
                    metrics.validationErrors += 1
                default:
                    break
                }
            }
        }
    }

    // MARK: - Snapshot

    /// Get current metrics snapshot
    public func getSnapshot() -> MetricsSnapshot {
        metricsLock.withLock { metrics in
            let avgQueryTime = metrics.totalQueries > 0
                ? metrics.totalQueryTime / Double(metrics.totalQueries)
                : 0.0

            let successRate = metrics.totalQueries > 0
                ? Double(metrics.successfulQueries) / Double(metrics.totalQueries)
                : 0.0

            // Convert index metrics
            let indexSnapshots = metrics.indexMetrics.map { (name, metric) -> (String, IndexSnapshot) in
                let avgTime = metric.queryCount > 0
                    ? metric.totalTime / Double(metric.queryCount)
                    : 0.0
                return (name, IndexSnapshot(
                    queryCount: metric.queryCount,
                    averageQueryTime: avgTime,
                    errors: metric.errors
                ))
            }

            // Convert type metrics
            let typeSnapshots = metrics.typeMetrics.map { (type, metric) -> (AggregateType, TypeSnapshot) in
                let avgTime = metric.queryCount > 0
                    ? metric.totalTime / Double(metric.queryCount)
                    : 0.0
                return (type, TypeSnapshot(
                    queryCount: metric.queryCount,
                    averageQueryTime: avgTime,
                    errors: metric.errors
                ))
            }

            return MetricsSnapshot(
                totalQueries: metrics.totalQueries,
                successfulQueries: metrics.successfulQueries,
                failedQueries: metrics.failedQueries,
                validationErrors: metrics.validationErrors,
                averageQueryTime: avgQueryTime,
                minQueryTime: metrics.minQueryTime == .infinity ? 0.0 : metrics.minQueryTime,
                maxQueryTime: metrics.maxQueryTime,
                successRate: successRate,
                indexMetrics: Dictionary(uniqueKeysWithValues: indexSnapshots),
                typeMetrics: Dictionary(uniqueKeysWithValues: typeSnapshots)
            )
        }
    }

    /// Reset all metrics
    public func reset() {
        metricsLock.withLock { metrics in
            metrics = Metrics()
        }
    }

    // MARK: - Snapshot Types

    public struct MetricsSnapshot: Sendable {
        public let totalQueries: UInt64
        public let successfulQueries: UInt64
        public let failedQueries: UInt64
        public let validationErrors: UInt64
        public let averageQueryTime: TimeInterval
        public let minQueryTime: TimeInterval
        public let maxQueryTime: TimeInterval
        public let successRate: Double
        public let indexMetrics: [String: IndexSnapshot]
        public let typeMetrics: [AggregateType: TypeSnapshot]
    }

    public struct IndexSnapshot: Sendable {
        public let queryCount: UInt64
        public let averageQueryTime: TimeInterval
        public let errors: UInt64
    }

    public struct TypeSnapshot: Sendable {
        public let queryCount: UInt64
        public let averageQueryTime: TimeInterval
        public let errors: UInt64
    }
}

// MARK: - CustomStringConvertible

extension AggregateMetrics.MetricsSnapshot: CustomStringConvertible {
    public var description: String {
        var lines: [String] = []
        lines.append("Aggregate Metrics Summary:")
        lines.append("  Total queries: \(totalQueries)")
        lines.append("  Successful: \(successfulQueries)")
        lines.append("  Failed: \(failedQueries)")
        lines.append("  Validation errors: \(validationErrors)")
        lines.append("  Success rate: \(String(format: "%.2f%%", successRate * 100))")
        lines.append("  Average query time: \(String(format: "%.4fs", averageQueryTime))")
        lines.append("  Min query time: \(String(format: "%.4fs", minQueryTime))")
        lines.append("  Max query time: \(String(format: "%.4fs", maxQueryTime))")

        if !indexMetrics.isEmpty {
            lines.append("\nPer-Index Metrics:")
            for (name, metric) in indexMetrics.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(name):")
                lines.append("    Queries: \(metric.queryCount)")
                lines.append("    Avg time: \(String(format: "%.4fs", metric.averageQueryTime))")
                lines.append("    Errors: \(metric.errors)")
            }
        }

        if !typeMetrics.isEmpty {
            lines.append("\nPer-Type Metrics:")
            for (type, metric) in typeMetrics.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append("  \(type.rawValue):")
                lines.append("    Queries: \(metric.queryCount)")
                lines.append("    Avg time: \(String(format: "%.4fs", metric.averageQueryTime))")
                lines.append("    Errors: \(metric.errors)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
