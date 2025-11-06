import Foundation

// MARK: - ScrubberResult

/// スクラバー実行結果（最小限）
///
/// 詳細な統計情報はメトリクスシステムで確認してください。
/// - Prometheus Query: `fdb_scrubber_*{index="your_index_name"}`
public struct ScrubberResult: Sendable {
    /// 健全性フラグ
    ///
    /// `true` の場合、インデックスに問題は検出されませんでした。
    /// `false` の場合、Issue が検出されたか、スキャンが途中終了しました。
    public let isHealthy: Bool

    /// 正常完了フラグ
    ///
    /// `true` の場合、Phase 1 と Phase 2 が完全に実行されました。
    /// `false` の場合、エラーにより途中終了しました。
    public let completedSuccessfully: Bool

    /// 実行サマリ（部分進捗も含む）
    public let summary: ScrubberSummary

    /// 途中終了の理由（正常完了時は nil）
    public let terminationReason: String?

    /// エラー情報（エラーが発生した場合のみ）
    ///
    /// **Note**: エラー発生時でもsummaryには部分的な進捗が記録されています。
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

/// スクラバー実行のサマリ情報
public struct ScrubberSummary: Sendable {
    /// 実行時間（秒）
    public let timeElapsed: TimeInterval

    /// スキャンしたインデックスエントリ数
    public let entriesScanned: Int

    /// スキャンしたレコード数
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

    /// 検出された Issue の総数
    ///
    /// - Dangling entries
    /// - Missing entries
    public let issuesDetected: Int

    /// 修復された Issue の数
    ///
    /// `configuration.allowRepair=true` の場合のみ 0 以外になります。
    public let issuesRepaired: Int

    /// インデックス名（メトリクスクエリ用のヒント）
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

    /// メトリクスシステムへのヒント
    ///
    /// 詳細な統計情報を確認する方法を示します。
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
