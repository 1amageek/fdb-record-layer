import Foundation

// MARK: - ScrubberResult

/// Scrubber execution result (minimal)
///
/// Check the metrics system for detailed statistics.
/// - Prometheus Query: `fdb_scrubber_*{index="your_index_name"}`
public struct ScrubberResult: Sendable {
    /// Health flag
    ///
    /// `true` if no issues were detected in the index.
    /// `false` if issues were detected or scanning was terminated early.
    public let isHealthy: Bool

    /// Successful completion flag
    ///
    /// `true` if Phase 1 and Phase 2 were fully executed.
    /// `false` if terminated early due to error.
    public let completedSuccessfully: Bool

    /// Execution summary (includes partial progress)
    public let summary: ScrubberSummary

    /// Reason for early termination (nil if completed successfully)
    public let terminationReason: String?

    /// Error information (only when error occurred)
    ///
    /// **Note**: Even when an error occurs, partial progress is recorded in summary.
    public let error: (any Error)?

    public init(
        isHealthy: Bool,
        completedSuccessfully: Bool,
        summary: ScrubberSummary,
        terminationReason: String? = nil,
        error: (any Error)? = nil
    ) {
        self.isHealthy = isHealthy
        self.completedSuccessfully = completedSuccessfully
        self.summary = summary
        self.terminationReason = terminationReason
        self.error = error
    }
}

// MARK: - ScrubberSummary

/// Scrubber execution summary information
public struct ScrubberSummary: Sendable {
    /// Execution time (seconds)
    public let timeElapsed: TimeInterval

    /// Number of scanned index entries
    public let entriesScanned: Int

    /// Number of scanned records
    public let recordsScanned: Int

    // MARK: - Detailed Issue Breakdown

    /// Dangling entries detected (Phase 1)
    public let danglingEntriesDetected: Int

    /// Dangling entries repaired (Phase 1)
    public let danglingEntriesRepaired: Int

    /// Missing entries detected (Phase 2)
    public let missingEntriesDetected: Int

    /// Missing entries repaired (Phase 2)
    public let missingEntriesRepaired: Int

    // MARK: - Aggregated Totals

    /// Total number of detected issues
    ///
    /// - Dangling entries
    /// - Missing entries
    public let issuesDetected: Int

    /// Number of repaired issues
    ///
    /// Will be non-zero only when `configuration.allowRepair=true`.
    public let issuesRepaired: Int

    /// Index name (hint for metrics queries)
    public let indexName: String

    public init(
        timeElapsed: TimeInterval,
        entriesScanned: Int,
        recordsScanned: Int,
        danglingEntriesDetected: Int,
        danglingEntriesRepaired: Int,
        missingEntriesDetected: Int,
        missingEntriesRepaired: Int,
        indexName: String
    ) {
        self.timeElapsed = timeElapsed
        self.entriesScanned = entriesScanned
        self.recordsScanned = recordsScanned
        self.danglingEntriesDetected = danglingEntriesDetected
        self.danglingEntriesRepaired = danglingEntriesRepaired
        self.missingEntriesDetected = missingEntriesDetected
        self.missingEntriesRepaired = missingEntriesRepaired
        self.issuesDetected = danglingEntriesDetected + missingEntriesDetected
        self.issuesRepaired = danglingEntriesRepaired + missingEntriesRepaired
        self.indexName = indexName
    }

    /// Hint for metrics system
    ///
    /// Shows how to check detailed statistics.
    public var metricsHint: String {
        """
        For detailed statistics, query the metrics system:

        Prometheus Examples:
        - fdb_scrubber_entries_scanned_total{index="\(indexName)"}
        - fdb_scrubber_issues_total{index="\(indexName)",type="dangling_entry"}
        - fdb_scrubber_skipped_total{index="\(indexName)",reason="deserialization_failure"}
        - fdb_scrubber_progress_ratio{index="\(indexName)"}

        Grafana Dashboard: http://grafana:3000/d/fdb-scrubber
        """
    }
}
