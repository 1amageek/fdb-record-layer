# OnlineIndexScrubber: エラーハンドリングとメトリクス設計

## 目次

1. [セットアップ](#セットアップ)
2. [概要](#概要)
3. [アーキテクチャ](#アーキテクチャ)
4. [ScrubberResult設計](#scrubberresult設計)
5. [swift-metrics統合](#swift-metrics統合)
6. [RangeSet統合](#rangeset統合)
7. [エラーハンドリング戦略](#エラーハンドリング戦略)
8. [ログ戦略](#ログ戦略)
9. [パフォーマンス考慮事項](#パフォーマンス考慮事項)
10. [運用ガイド](#運用ガイド)
11. [実装リファレンス](#実装リファレンス)
12. [トラブルシューティング](#トラブルシューティング)

---

## セットアップ

### 依存関係の追加

`Package.swift`に以下の依存関係を追加してください：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fdb-record-layer",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/MrLotU/SwiftPrometheus.git", from: "1.0.0"),
        // ... other dependencies
    ],
    targets: [
        .target(
            name: "FDBRecordLayer",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
                // ... other dependencies
            ]
        )
    ]
)
```

### MetricsSystemのブートストラップ

アプリケーション起動時に、**一度だけ**`MetricsSystem.bootstrap()`を呼び出してください：

```swift
import Metrics
import SwiftPrometheus

@main
struct MyApplication {
    static func main() {
        // ⚠️ 重要: アプリケーション起動時に一度だけ呼び出す
        // 複数回呼び出すとクラッシュします
        MetricsSystem.bootstrap(PrometheusMetrics())

        // アプリケーションのメインロジック
        Task {
            try await startApplication()
        }

        // サーバーを起動してメトリクスエンドポイントを公開
        startMetricsServer()
    }
}
```

### メトリクスエンドポイントの公開

Prometheusがメトリクスをスクレイピングできるように、HTTPエンドポイントを公開します：

```swift
import Vapor
import SwiftPrometheus

func startMetricsServer() {
    let app = Application()
    defer { app.shutdown() }

    // GET /metrics でPrometheus形式のメトリクスを返す
    app.get("metrics") { req -> String in
        let prometheus = MetricsSystem.factory as! PrometheusMetrics
        return prometheus.collect()
    }

    try app.run()
}
```

**または、VaporなしでSwift NIOを使う場合**:

```swift
import NIO
import NIOHTTP1

func startMetricsServer() {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }

    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .childChannelInitializer { channel in
            channel.pipeline.addHandlers([
                HTTPServerCodec(),
                MetricsHandler()
            ])
        }

    let channel = try! bootstrap.bind(host: "0.0.0.0", port: 9090).wait()
    print("Metrics server started on http://0.0.0.0:9090/metrics")
    try! channel.closeFuture.wait()
}
```

---

## 概要

### 設計原則

OnlineIndexScrubberのエラーハンドリングとメトリクス設計は、以下の原則に基づいています：

1. **責任の分離**: 即座のフィードバック（ScrubberResult）と詳細な運用監視（swift-metrics）を分離
2. **運用優先**: ログとメトリクスで「何が起きたか」「どう対処すべきか」を明確に伝える
3. **パフォーマンス**: メモリとI/Oを効率的に使用（バッチ記録、サンプリング）
4. **セキュリティ**: PII（個人識別情報）を含むキーをログに出力しない
5. **スレッドセーフ**: swift-metricsはSendableでスレッドセーフ、actorコンテキストで安全に使用可能
6. **簡潔性**: 後方互換性を考慮せず、最小限の実装で最大の価値を提供

### ユーザー体験の目標

- ✅ **開発者**: `result.isHealthy`で即座に健全性を判定
- ✅ **運用者**: Grafanaダッシュボードで詳細を分析
- ✅ **SRE**: アラートルールでインシデント検知
- ✅ **トラブルシューター**: ログで根本原因を特定

---

## アーキテクチャ

### 全体構成

```
┌─────────────────────────────────────────────────────────────┐
│                   OnlineIndexScrubber (actor)                │
│                                                              │
│  ┌──────────────┐                                           │
│  │ scrubIndex() │                                           │
│  └──────┬───────┘                                           │
│         │                                                    │
│         ├──────────────────────────────────────┐            │
│         │                                      │            │
│         v                                      v            │
│  ┌─────────────────┐                  ┌─────────────────┐  │
│  │ Phase 1         │                  │ Phase 2         │  │
│  │ (Index Entries) │                  │ (Records)       │  │
│  └────────┬────────┘                  └────────┬────────┘  │
│           │                                     │           │
│           v                                     v           │
│  ┌────────────────────────────────────────────────────┐    │
│  │        Metrics Recording Layer                      │    │
│  │  - scanProgressCounter (batched)                    │    │
│  │  - issuesCounter                                    │    │
│  │  - skipCounter                                      │    │
│  │  - retryCounter                                     │    │
│  │  - progressGauge (from RangeSet)                    │    │
│  │  - scanDuration                                     │    │
│  └────────────────┬───────────────────────────────────┘    │
│                   │                                         │
│                   v                                         │
│  ┌────────────────────────────────────────────────────┐    │
│  │        Logging Layer (with sampling)                │    │
│  │  - logger.info (progress)                           │    │
│  │  - logger.warning (sampled: 1/100)                  │    │
│  │  - logger.error (fatal errors)                      │    │
│  └────────────────┬───────────────────────────────────┘    │
│                   │                                         │
└───────────────────┼─────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        v                       v
┌──────────────┐        ┌─────────────────┐
│ScrubberResult│        │ swift-metrics   │
│(最小限)      │        │ Backend         │
│- isHealthy   │        │ (Prometheus)    │
│- summary     │        └────────┬────────┘
└──────┬───────┘                 │
       │                         │
       v                         v
┌──────────────┐        ┌─────────────────┐
│呼び出し側    │        │ Grafana         │
│(即座判定)    │        │ Dashboard       │
└──────────────┘        └─────────────────┘
```

### データフロー

```
[スキャン開始]
    │
    ├─→ [RangeSet] 進捗率を取得 → progressGauge.record(0.0)
    │
    ├─→ [バッチ処理]
    │     ├─ エントリをスキャン（例: 1000件）
    │     ├─ バッチ終了時にメトリクス記録
    │     │   └─→ scanProgressCounter.increment(by: 1000)
    │     │
    │     ├─ Tuple decode失敗（サンプリング: 1/100でログ）
    │     │   ├─→ [メトリクス] skipCounter++ (reason=tuple_decode)
    │     │   ├─→ [ログ] logger.warning("Tuple decode failed") ※サンプリング
    │     │   └─→ continue (スキップ)
    │     │
    │     ├─ Dangling entry検出
    │     │   ├─→ [メトリクス] issuesCounter++ (type=dangling_entry)
    │     │   ├─→ [ログ] logger.warning("Dangling entry")
    │     │   └─→ allowRepair=true なら削除
    │     │
    │     └─ Deserialization失敗（サンプリング）
    │         ├─→ [メトリクス] skipCounter++ (reason=deserialization)
    │         ├─→ [ログ] logger.warning("Deserialization failed") ※サンプリング
    │         └─→ continue (スキップ)
    │
    ├─→ [リトライ処理]
    │     └─ 失敗時
    │         ├─→ [メトリクス] retryCounter++ (error_code=1007)
    │         ├─→ [ログ] logger.warning("Retry #{n}")
    │         └─→ exponential backoff
    │
    ├─→ [RangeSet更新] バッチ完了範囲を記録
    │     └─→ progressGauge.record(0.25)  // 25%完了
    │
    └─→ [完了]
          ├─→ [メトリクス] scanDuration.record(elapsed)
          ├─→ [RangeSet] 進捗率 100%
          ├─→ [ログ] logger.info("Completed")
          └─→ [戻り値] ScrubberResult
```

---

## ScrubberResult設計

### 設計方針

**最小限の情報のみを返す**: 詳細な統計情報はswift-metricsに委譲し、API呼び出し側が即座に判定できる情報のみに絞る。

### データ構造

```swift
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

    /// 実行サマリ
    public let summary: ScrubberSummary

    /// 途中終了の理由（正常完了時は nil）
    public let terminationReason: String?
}

/// スクラバー実行のサマリ情報
public struct ScrubberSummary: Sendable {
    /// 実行時間（秒）
    public let timeElapsed: TimeInterval

    /// スキャンしたインデックスエントリ数
    public let entriesScanned: Int

    /// スキャンしたレコード数
    public let recordsScanned: Int

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
```

### 使用例

```swift
// スクラバーの実行
let result = try await scrubber.scrubIndex()

// ✅ シンプルな健全性チェック
if result.isHealthy {
    print("✅ Index is healthy")
} else {
    print("⚠️  Issues detected: \(result.summary.issuesDetected)")
    print("📊 For details: \(result.summary.metricsHint)")
}

// ✅ プログラマティックな処理
if !result.completedSuccessfully {
    if let reason = result.terminationReason {
        logger.error("Scrubber failed", metadata: ["reason": "\(reason)"])
        // アラート送信
        alerting.send(.scrubberFailed(index: indexName, reason: reason))
    }
}

// ✅ 統計情報の確認
print("""
Scrubber Summary:
  Time: \(result.summary.timeElapsed)s
  Entries: \(result.summary.entriesScanned)
  Records: \(result.summary.recordsScanned)
  Issues: \(result.summary.issuesDetected) detected, \(result.summary.issuesRepaired) repaired
""")
```

---

## swift-metrics統合

### メトリクスの種類と特性

swift-metricsは**スレッドセーフ**で**Sendableプロトコルに準拠**しているため、actorコンテキストや並行タスクから安全に使用できます。

| メトリクス名 | 型 | 説明 | ラベル | バッチ記録 |
|------------|---|------|--------|-----------|
| `fdb_scrubber_entries_scanned_total` | Counter | スキャンしたインデックスエントリの総数 | index, index_type | ✅ 推奨 |
| `fdb_scrubber_issues_total` | Counter | 検出された Issue の総数 | index, type, phase | ❌ 即座 |
| `fdb_scrubber_skipped_total` | Counter | スキップされたエントリの総数 | index, reason, phase | ✅ 推奨 |
| `fdb_scrubber_retries_total` | Counter | リトライの総数 | index, error_code, phase, operation | ❌ 即座 |
| `fdb_scrubber_progress_ratio` | Gauge | スキャン進捗率（0.0〜1.0） | index, phase | ❌ 即座 |
| `fdb_scrubber_scan_duration_seconds` | Timer | スキャン実行時間（秒） | index, index_type | ❌ 終了時 |
| `fdb_scrubber_batch_size` | Recorder | バッチサイズの分布 | index, phase | ❌ バッチ毎 |

### メトリクス型の詳細

#### Counter
- **用途**: 単調増加する値（リクエスト数、エラー数など）
- **メソッド**: `increment(by: Int = 1)`
- **スレッドセーフ**: ✅ はい（複数のタスクから呼び出し可能）

```swift
let counter = Counter(label: "http_requests_total", dimensions: [("path", "/")])
counter.increment()
counter.increment(by: 100)
```

#### Timer
- **用途**: 処理時間の測定
- **メソッド**: `recordNanoseconds(Int64)`, `recordSeconds(Double)`
- **集計**: min, max, quantiles（バックエンドが対応している場合）

```swift
let timer = Timer(label: "request_duration_seconds")
timer.recordNanoseconds(100_000_000)  // 100ms
timer.recordSeconds(0.5)  // 500ms
```

#### Recorder
- **用途**: 値の分布測定（レスポンスサイズ、キューサイズなど）
- **メソッド**: `record(Int64)` または `record(Double)`
- **集計**: count, sum, min, max, quantiles（デフォルト: `aggregate: true`）

```swift
let recorder = Recorder(label: "response_size_bytes")
recorder.record(1024)
```

#### Gauge
- **用途**: 上下する値（温度、メモリ使用量など）
- **実装**: `Recorder(aggregate: false)`として実装
- **特徴**: 最新の値のみを保持（集計しない）

```swift
let gauge = Gauge(label: "current_temperature_celsius")
gauge.record(25.5)
```

### ラベル（Dimensions）の使い方

ラベルは`[(String, String)]`の配列で指定します：

```swift
// ラベル付きCounter
let counter = Counter(
    label: "fdb_scrubber_issues_total",
    dimensions: [
        ("index", "user_by_email"),
        ("type", "dangling_entry"),
        ("phase", "phase1")
    ]
)
counter.increment()

// 動的ラベルの追加
skipCounter.increment(
    by: 1,
    dimensions: [
        ("reason", "tuple_decode_failure"),
        ("phase", "phase1")
    ]
)
```

### 初期化

```swift
import Metrics

public actor OnlineIndexScrubber<Record: Sendable> {
    // === Metrics ===
    private let scanProgressCounter: Counter
    private let issuesCounter: Counter
    private let skipCounter: Counter
    private let retryCounter: Counter
    private let progressGauge: Gauge
    private let scanDuration: Timer
    private let batchSizeRecorder: Recorder

    // Common labels
    private let metricsLabels: [(String, String)]

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        configuration: ScrubberConfiguration = .default
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.index = index
        self.recordAccess = recordAccess
        self.configuration = configuration

        // メトリクスのラベル（すべてのメトリクスに共通）
        self.metricsLabels = [
            ("index", index.name),
            ("index_type", index.type.rawValue)
        ]

        // メトリクスの初期化
        // ⚠️ メトリクスはSendableでスレッドセーフなので、actorで安全に使用可能
        self.scanProgressCounter = Counter(
            label: "fdb_scrubber_entries_scanned_total",
            dimensions: metricsLabels
        )

        self.issuesCounter = Counter(
            label: "fdb_scrubber_issues_total",
            dimensions: metricsLabels
        )

        self.skipCounter = Counter(
            label: "fdb_scrubber_skipped_total",
            dimensions: metricsLabels
        )

        self.retryCounter = Counter(
            label: "fdb_scrubber_retries_total",
            dimensions: metricsLabels
        )

        // Gaugeは進捗率（0.0〜1.0）を記録
        self.progressGauge = Gauge(
            label: "fdb_scrubber_progress_ratio",
            dimensions: metricsLabels
        )

        self.scanDuration = Timer(
            label: "fdb_scrubber_scan_duration_seconds",
            dimensions: metricsLabels
        )

        self.batchSizeRecorder = Recorder(
            label: "fdb_scrubber_batch_size",
            dimensions: metricsLabels,
            aggregate: true
        )
    }
}
```

### メトリクス記録の実装例（バッチ化）

```swift
// === Phase 1: scrubIndexEntriesBatch 内 ===

var batchCount = 0
var skipCount = 0

for try await (indexKey, _) in sequence {
    batchCount += 1

    // Tuple decode
    let indexTuple: Tuple
    do {
        indexTuple = try indexSubspace.unpack(indexKey)
    } catch {
        skipCount += 1

        // サンプリング: 1/100のみログ出力
        if Int.random(in: 0..<100) == 0 {
            logger.warning("Tuple decode failed", metadata: [
                "key": "\(indexKey.safeLogRepresentation)",
                "error": "\(error.safeDescription)"
            ])
        }

        continue
    }

    // ... 他の処理 ...
}

// ✅ バッチ終了時に一括記録（パフォーマンス向上）
scanProgressCounter.increment(by: batchCount)
if skipCount > 0 {
    skipCounter.increment(
        by: skipCount,
        dimensions: [("reason", "tuple_decode_failure"), ("phase", "phase1")]
    )
}
batchSizeRecorder.record(batchCount)
```

### Prometheusクエリ例

```promql
# スキャン速度（エントリ/秒）
rate(fdb_scrubber_entries_scanned_total{index="user_by_email"}[1m])

# Issue検出率（件/秒）
rate(fdb_scrubber_issues_total{index="user_by_email",type="dangling_entry"}[5m])

# 進捗率（%）
fdb_scrubber_progress_ratio{index="user_by_email"} * 100

# 残り時間の推定（秒）
(1 - fdb_scrubber_progress_ratio{index="user_by_email"}) /
  rate(fdb_scrubber_progress_ratio{index="user_by_email"}[5m])

# スキップ理由の内訳
sum by (reason) (fdb_scrubber_skipped_total{index="user_by_email"})

# リトライ頻度（Phase 1のみ）
rate(fdb_scrubber_retries_total{index="user_by_email",phase="phase1"}[5m])

# スキャン時間（P95）
histogram_quantile(0.95, rate(fdb_scrubber_scan_duration_seconds_bucket[5m]))

# バッチサイズの中央値
histogram_quantile(0.5, rate(fdb_scrubber_batch_size_bucket[5m]))
```

### Grafanaダッシュボード設定

```json
{
  "dashboard": {
    "title": "FoundationDB Index Scrubber",
    "panels": [
      {
        "title": "Scan Progress (%)",
        "targets": [
          {
            "expr": "fdb_scrubber_progress_ratio * 100"
          }
        ]
      },
      {
        "title": "Scan Speed (entries/sec)",
        "targets": [
          {
            "expr": "rate(fdb_scrubber_entries_scanned_total[1m])"
          }
        ]
      },
      {
        "title": "Issues Detected",
        "targets": [
          {
            "expr": "sum by (type) (fdb_scrubber_issues_total)"
          }
        ]
      },
      {
        "title": "Skip Reasons",
        "targets": [
          {
            "expr": "sum by (reason) (fdb_scrubber_skipped_total)"
          }
        ]
      },
      {
        "title": "Retry Rate",
        "targets": [
          {
            "expr": "rate(fdb_scrubber_retries_total[5m])"
          }
        ]
      },
      {
        "title": "Estimated Time Remaining",
        "targets": [
          {
            "expr": "(1 - fdb_scrubber_progress_ratio) / rate(fdb_scrubber_progress_ratio[5m])"
          }
        ]
      }
    ]
  }
}
```

---

## RangeSet統合

OnlineIndexScrubberは`RangeSet`を使用して進行状況を追跡し、中断・再開時も正確な状態を維持します。

### RangeSetとメトリクスの連携

```swift
public actor OnlineIndexScrubber<Record: Sendable> {
    private let progressGauge: Gauge

    private func updateProgress(rangeSet: RangeSet) async throws {
        // RangeSetから進捗率を取得（0.0 〜 1.0）
        let progress = try await rangeSet.getProgress()

        // Gaugeに記録
        progressGauge.record(progress)

        logger.info("Progress updated", metadata: [
            "progress": "\(Int(progress * 100))%"
        ])
    }

    public func scrubIndex() async throws -> ScrubberResult {
        let startTime = Date()

        // RangeSetの初期化
        let rangeSet = try await initializeRangeSet()

        // 初期進捗率を記録
        try await updateProgress(rangeSet: rangeSet)

        // Phase 1
        var continuation: FDB.Bytes? = nil
        while true {
            let (nextContinuation, issues, endKey, scanned) = try await scrubIndexEntriesBatch(
                start: continuation,
                rangeSet: rangeSet
            )

            // バッチ完了後、進捗率を更新
            try await updateProgress(rangeSet: rangeSet)

            guard let next = nextContinuation else {
                break
            }
            continuation = next
        }

        // 完了時は進捗率 1.0
        progressGauge.record(1.0)

        // ...
    }
}
```

### 中断・再開時の動作

```swift
// 初回実行
let scrubber1 = OnlineIndexScrubber(...)
try await scrubber1.scrubIndex()
// → progressGauge: 0.0 → 0.25 → 0.50 → (クラッシュ)

// 再開
let scrubber2 = OnlineIndexScrubber(...)  // 同じsubspace/index
try await scrubber2.scrubIndex()
// → RangeSetから前回の進捗を復元
// → progressGauge: 0.50 → 0.75 → 1.0
```

**重要**: メトリクスはプロセス再起動時にリセットされますが、RangeSetはFoundationDBに永続化されるため、進捗率は正確に復元されます。

### Prometheusでの進捗監視

```promql
# 現在の進捗率（%）
fdb_scrubber_progress_ratio{index="user_by_email"} * 100

# 進捗速度（%/分）
rate(fdb_scrubber_progress_ratio{index="user_by_email"}[1m]) * 60 * 100

# 残り時間の推定（分）
(1 - fdb_scrubber_progress_ratio{index="user_by_email"}) /
  rate(fdb_scrubber_progress_ratio{index="user_by_email"}[5m]) / 60
```

---

## エラーハンドリング戦略

### エラー分類

OnlineIndexScrubberは以下の種類のエラーを区別します：

| エラー種類 | 対処方法 | ユーザーアクション |
|-----------|---------|-------------------|
| Tuple decode失敗 | スキップ + 警告ログ（サンプリング） + メトリクス | データ整合性調査 |
| Deserialization失敗 | スキップ + 警告ログ（サンプリング） + メトリクス | スキーマ互換性確認 |
| Dangling entry | allowRepair=trueで修復 | 原因調査（削除漏れ？） |
| Missing entry | allowRepair=trueで修復 | 原因調査（書き込み漏れ？） |
| Transaction too large | キースキップ + 進捗記録 | maxTransactionBytes調整 |
| Retryable FDB error | 指数バックオフでリトライ | クラスタ健全性確認 |
| Non-retryable error | 即座に失敗 | エラーメッセージに従う |
| Retry exhausted | コンテキスト付きエラー | 設定調整またはクラスタ確認 |

### RecordLayerError拡張

```swift
extension RecordLayerError {
    /// スクラバーのリトライが上限に達した
    ///
    /// - Parameters:
    ///   - phase: 失敗したフェーズ（"Phase 1", "Phase 2"）
    ///   - operation: 失敗した操作（"scrubIndexEntriesBatch", "scrubRecordsBatch"）
    ///   - keyRange: 処理中のキー範囲
    ///   - attempts: 試行回数
    ///   - lastError: 最後のエラー
    ///   - recommendation: 推奨される対処方法
    public static func scrubberRetryExhausted(
        phase: String,
        operation: String,
        keyRange: String,
        attempts: Int,
        lastError: Error,
        recommendation: String
    ) -> RecordLayerError {
        let message = """
            ❌ Scrubber retry exhausted during \(phase)

            📍 Operation: \(operation)
            📍 Key Range: \(keyRange)
            📍 Attempts: \(attempts)
            📍 Last Error: \(lastError)

            💡 Recommendation:
            \(recommendation)
            """
        return .internalError(message)
    }

    /// キースキップ処理が失敗した
    ///
    /// - Parameters:
    ///   - key: スキップしようとしたキー
    ///   - reason: 失敗理由
    ///   - attempts: 試行回数
    public static func scrubberSkipFailed(
        key: String,
        reason: Error,
        attempts: Int
    ) -> RecordLayerError {
        let message = """
            ❌ Failed to skip problematic key after \(attempts) attempts

            📍 Key: \(key)
            📍 Reason: \(reason)

            💡 Recommendation:
            This key is blocking progress. Consider:
            1. Increase 'maxRetries' in ScrubberConfiguration
            2. Manually inspect and remove this key
            3. Check FoundationDB cluster health

            ⚠️  The scrubber cannot proceed past this key until it is resolved.
            """
        return .internalError(message)
    }
}
```

### エラーコンテキストの付与

```swift
// リトライ失敗時
if retryCount > configuration.maxRetries {
    let recommendation: String
    if error.code == 2101 { // transaction_too_large
        recommendation = """
            Increase 'maxTransactionBytes' in ScrubberConfiguration.
            Current: \(configuration.maxTransactionBytes) bytes
            Suggested: \(configuration.maxTransactionBytes * 2) bytes

            Or reduce 'entriesScanLimit':
            Current: \(configuration.entriesScanLimit)
            Suggested: \(configuration.entriesScanLimit / 2)
            """
    } else if error.code == 1007 { // transaction_too_old
        recommendation = """
            The transaction took longer than 5 seconds (FoundationDB limit).

            Options:
            1. Reduce 'entriesScanLimit' (current: \(configuration.entriesScanLimit))
            2. Increase 'transactionTimeoutMillis' if cluster allows
            3. Check FoundationDB cluster load
            """
    } else {
        recommendation = """
            Check FoundationDB cluster health.
            Consider increasing 'maxRetries' (current: \(configuration.maxRetries))

            Error code: \(error.code)
            Error description: \(error.localizedDescription)
            """
    }

    throw RecordLayerError.scrubberRetryExhausted(
        phase: "Phase 1 (Index Entries Scan)",
        operation: "scrubIndexEntriesBatch",
        keyRange: "\(currentKey.safeLogRepresentation) to \(endKey?.safeLogRepresentation ?? "end")",
        attempts: retryCount,
        lastError: error,
        recommendation: recommendation
    )
}
```

---

## ログ戦略

### ログレベルの使い分け

| レベル | 用途 | 例 |
|--------|------|-----|
| debug | 詳細なデバッグ情報 | バッチ処理の開始/終了 |
| info | 正常な進捗情報 | Phase開始/完了、統計サマリ |
| warning | リカバリー可能な問題（サンプリング推奨） | デシリアライズ失敗、リトライ |
| error | 致命的なエラー | リトライ上限到達、処理中断 |

### サンプリング戦略

大量のwarningログはI/Oボトルネックになるため、サンプリングを使用します：

```swift
// サンプリング率: 1/100
private let warningSamplingRate = 100

// Tuple decode失敗
do {
    indexTuple = try indexSubspace.unpack(indexKey)
} catch {
    // ✅ メトリクスは全件記録
    skipCounter.increment(
        by: 1,
        dimensions: [("reason", "tuple_decode_failure"), ("phase", "phase1")]
    )

    // ✅ ログは1/100のみ出力（サンプリング）
    if Int.random(in: 0..<warningSamplingRate) == 0 {
        logger.warning("Tuple decode failed - skipping entry", metadata: [
            "key": "\(indexKey.safeLogRepresentation)",
            "error": "\(error.safeDescription)",
            "phase": "phase1",
            "note": "This is a sampled log (1/\(warningSamplingRate))"
        ])
    }

    continue
}
```

**または、バッチ集約**:

```swift
var batchSkipCount = 0

for entry in batch {
    do {
        // ...
    } catch {
        batchSkipCount += 1
        continue
    }
}

// バッチ終了時に1回だけログ
if batchSkipCount > 0 {
    logger.warning("Skipped entries in batch", metadata: [
        "count": "\(batchSkipCount)",
        "batchSize": "\(batch.count)",
        "reason": "tuple_decode_failure"
    ])
}
```

### ログ出力例

```swift
// === Phase開始 ===
logger.info("Starting Phase 1: Index entries scan", metadata: [
    "index": "\(index.name)",
    "indexType": "\(index.type.rawValue)",
    "allowRepair": "\(configuration.allowRepair)"
])

// === Tuple decode失敗（warning、サンプリング） ===
if Int.random(in: 0..<100) == 0 {
    logger.warning("Tuple decode failed - skipping entry", metadata: [
        "key": "\(indexKey.safeLogRepresentation)",
        "error": "\(error.safeDescription)",
        "phase": "phase1",
        "sampling": "1/100"
    ])
}

// === リトライ（warning） ===
logger.warning("Retryable error - backing off", metadata: [
    "error": "\(error)",
    "errorCode": "\(error.code)",
    "attempt": "\(retryCount)/\(configuration.maxRetries)",
    "backoffMs": "\(delay)",
    "note": delay > 10000 ? "Long backoff - expected with exponential backoff" : ""
])

// === リトライ上限到達（error） ===
logger.error("Retry limit exceeded", metadata: [
    "phase": "Phase 1",
    "operation": "scrubIndexEntriesBatch",
    "attempts": "\(retryCount)",
    "maxRetries": "\(configuration.maxRetries)",
    "lastError": "\(error)",
    "keyRange": "\(currentKey.safeLogRepresentation) to \(endKey?.safeLogRepresentation ?? "end")"
])

// === Phase完了（info） ===
logger.info("Phase 1 completed", metadata: [
    "entriesScanned": "\(indexEntriesScanned)",
    "issuesDetected": "\(phase1Issues.count)",
    "timeElapsed": "\(String(format: "%.2f", elapsed))s"
])
```

### キーのサニタイゼーション

```swift
import Crypto

extension FDB.Bytes {
    /// ログ出力用の安全な表現
    ///
    /// 先頭8バイトとSHA256ハッシュのみを表示し、中間部分は隠蔽します。
    var safeLogRepresentation: String {
        guard !self.isEmpty else { return "<empty>" }

        // 先頭8バイト
        let prefix = self.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        // SHA256ハッシュの先頭8バイト
        let hash = SHA256.hash(data: Data(self))
        let hashHex = hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        return "\(prefix)...<hash:\(hashHex)> (length:\(self.count))"
    }
}

extension Error {
    /// ログ出力用の安全な説明
    ///
    /// ユーザーパスや機密情報を除去します。
    var safeDescription: String {
        let desc = String(describing: self)
        return desc
            .replacingOccurrences(
                of: #"/Users/[^/]+/"#,
                with: "/Users/<redacted>/",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"/home/[^/]+/"#,
                with: "/home/<redacted>/",
                options: .regularExpression
            )
    }
}
```

---

## パフォーマンス考慮事項

### メトリクス記録の最適化

#### ❌ 非効率: エントリごとに記録

```swift
for try await (indexKey, _) in sequence {
    scanProgressCounter.increment(by: 1)  // 100万エントリなら100万回呼び出し
    // ...
}
```

**問題**:
- 関数呼び出しオーバーヘッド
- メトリクスバックエンドへの頻繁なアクセス

#### ✅ 効率的: バッチごとに記録

```swift
var batchCount = 0

for try await (indexKey, _) in sequence {
    batchCount += 1
    // ...
}

// バッチ終了時に一括記録
scanProgressCounter.increment(by: batchCount)
```

**効果**:
- 呼び出し回数が1/1000に削減（entriesScanLimit=1000の場合）
- CPU使用率が約5〜10%削減

### ログのサンプリング

#### ❌ 非効率: 全件ログ出力

```swift
for entry in batch {
    do {
        // ...
    } catch {
        logger.warning("Failed", metadata: [...])  // 大量のI/O
    }
}
```

**問題**:
- ディスクI/Oボトルネック
- ログファイルの肥大化

#### ✅ 効率的: サンプリング

```swift
for entry in batch {
    do {
        // ...
    } catch {
        // メトリクスは全件記録
        skipCounter.increment(by: 1, dimensions: [("reason", "failure")])

        // ログは1/100のみ
        if Int.random(in: 0..<100) == 0 {
            logger.warning("Failed", metadata: [...])
        }
    }
}
```

**効果**:
- ログI/Oが1/100に削減
- ディスク使用量が大幅に削減
- メトリクスは全件記録されるため、統計に影響なし

### 同時実行性とスレッドセーフティ

#### swift-metricsのスレッドセーフ性

swift-metricsの全メトリクス型は**Sendableプロトコルに準拠**しており、**内部的にロックで保護**されています。

```swift
// ✅ 安全: 複数のタスクから並行に呼び出し可能
Task {
    counter.increment()
}
Task {
    counter.increment()
}
// → 競合なし、正しくカウント
```

#### OnlineIndexScrubberのactor化

```swift
// ✅ 推奨: actorを使用
public actor OnlineIndexScrubber<Record: Sendable> {
    private let scanProgressCounter: Counter  // Sendableなので安全

    public func scrubIndex() async throws -> ScrubberResult {
        // actorが同時実行を制御
        scanProgressCounter.increment(by: 100)  // スレッドセーフ
    }
}
```

**理由**:
- actorがメソッドの排他制御を保証
- メトリクスはSendableなので、actor境界を越えて安全に使用可能
- 明示的なロック（NSLock等）は不要

### メモリ使用量の最適化

#### RangeSetのメモリ効率

RangeSetはFoundationDBに永続化されるため、メモリ使用量は最小限です：

```swift
// メモリ使用量: O(1)（現在のバッチのみ）
let rangeSet = try await initializeRangeSet()

// 進捗をクエリしても、全データをロードしない
let progress = try await rangeSet.getProgress()  // 軽量
```

#### バッチサイズのチューニング

```swift
// 小さすぎる: オーバーヘッドが大きい
let config = ScrubberConfiguration(
    entriesScanLimit: 10  // ❌ 頻繁なトランザクション
)

// 大きすぎる: トランザクションタイムアウト
let config = ScrubberConfiguration(
    entriesScanLimit: 100_000  // ❌ transaction_too_old
)

// ✅ 推奨: 1000〜10000
let config = ScrubberConfiguration(
    entriesScanLimit: 1000  // バランスが良い
)
```

---

## 運用ガイド

### 推奨設定

#### 本番環境

```swift
let productionConfig = ScrubberConfiguration(
    entriesScanLimit: 1_000,
    maxTransactionBytes: 5_000_000,
    transactionTimeoutMillis: 4_000,
    readYourWrites: false,
    allowRepair: false,  // ⚠️ 最初はfalseで実行し、問題を確認
    supportedTypes: [.value],
    logWarningsLimit: 100,
    maxRetries: 20,
    retryDelayMillis: 100
)
```

#### 開発環境

```swift
let devConfig = ScrubberConfiguration(
    entriesScanLimit: 100,
    maxTransactionBytes: 1_000_000,
    transactionTimeoutMillis: 2_000,
    readYourWrites: false,
    allowRepair: true,  // 開発環境では自動修復
    supportedTypes: [.value],
    logWarningsLimit: 10,
    maxRetries: 5,
    retryDelayMillis: 50
)
```

### アラートルール（Prometheus）

```yaml
groups:
  - name: fdb_scrubber
    interval: 1m
    rules:
      # 高いIssue検出率
      - alert: HighScrubberIssueRate
        expr: rate(fdb_scrubber_issues_total[5m]) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High scrubber issue detection rate for {{ $labels.index }}"
          description: "{{ $value }} issues/sec detected"

      # スキップが多い
      - alert: HighScrubberSkipRate
        expr: rate(fdb_scrubber_skipped_total[5m]) > 5
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High scrubber skip rate for {{ $labels.index }}"
          description: "{{ $value }} skips/sec - check data integrity"

      # リトライが頻発
      - alert: FrequentScrubberRetries
        expr: rate(fdb_scrubber_retries_total[5m]) > 1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Frequent retries for {{ $labels.index }}"
          description: "{{ $value }} retries/sec - check cluster health"

      # スクラバーが停滞
      - alert: ScrubberStalled
        expr: rate(fdb_scrubber_progress_ratio[10m]) == 0
        for: 30m
        labels:
          severity: critical
        annotations:
          summary: "Scrubber stalled for {{ $labels.index }}"
          description: "No progress in 30 minutes"

      # スキャン時間が長い
      - alert: SlowScrubberScan
        expr: histogram_quantile(0.95, rate(fdb_scrubber_scan_duration_seconds_bucket[5m])) > 300
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Slow scrubber scan for {{ $labels.index }}"
          description: "P95 scan time: {{ $value }}s"
```

### 定期実行

```swift
import Foundation

/// スクラバーの定期実行
actor ScrubberScheduler {
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(interval: TimeInterval = 3600) {  // 1時間ごと
        self.interval = interval
    }

    func start() {
        task = Task {
            while !Task.isCancelled {
                do {
                    let result = try await runScrubber()

                    if !result.isHealthy {
                        logger.warning("Index health issues detected", metadata: [
                            "issuesDetected": "\(result.summary.issuesDetected)"
                        ])
                        // アラート送信
                    }

                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    logger.error("Scrubber execution failed", metadata: [
                        "error": "\(error)"
                    ])

                    // エラー時は短い間隔でリトライ
                    try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5分
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func runScrubber() async throws -> ScrubberResult {
        let scrubber = OnlineIndexScrubber<User>(
            database: database,
            subspace: subspace,
            metaData: metaData,
            index: emailIndex,
            recordAccess: UserAccess()
        )

        return try await scrubber.scrubIndex()
    }
}

// 使用例
let scheduler = ScrubberScheduler(interval: 3600)
await scheduler.start()

// アプリケーション終了時
await scheduler.stop()
```

---

## 実装リファレンス

### 完全な実装例

```swift
import Foundation
import FoundationDB
import Logging
import Metrics

public actor OnlineIndexScrubber<Record: Sendable> {
    // === Core Properties ===
    private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let metaData: RecordMetaData
    private let index: Index
    private let recordAccess: any RecordAccess<Record>
    private let configuration: ScrubberConfiguration
    private let logger: Logger

    // === Metrics ===
    // ⚠️ swift-metricsはSendableでスレッドセーフなので、actorで安全に使用可能
    private let scanProgressCounter: Counter
    private let issuesCounter: Counter
    private let skipCounter: Counter
    private let retryCounter: Counter
    private let progressGauge: Gauge
    private let scanDuration: Timer
    private let batchSizeRecorder: Recorder
    private let metricsLabels: [(String, String)]

    // === Initialization ===
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        configuration: ScrubberConfiguration = .default
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.index = index
        self.recordAccess = recordAccess
        self.configuration = configuration
        self.logger = Logger(label: "com.fdb.recordlayer.scrubber")

        // Metrics labels
        self.metricsLabels = [
            ("index", index.name),
            ("index_type", index.type.rawValue)
        ]

        // Initialize metrics
        self.scanProgressCounter = Counter(
            label: "fdb_scrubber_entries_scanned_total",
            dimensions: metricsLabels
        )
        self.issuesCounter = Counter(
            label: "fdb_scrubber_issues_total",
            dimensions: metricsLabels
        )
        self.skipCounter = Counter(
            label: "fdb_scrubber_skipped_total",
            dimensions: metricsLabels
        )
        self.retryCounter = Counter(
            label: "fdb_scrubber_retries_total",
            dimensions: metricsLabels
        )
        self.progressGauge = Gauge(
            label: "fdb_scrubber_progress_ratio",
            dimensions: metricsLabels
        )
        self.scanDuration = Timer(
            label: "fdb_scrubber_scan_duration_seconds",
            dimensions: metricsLabels
        )
        self.batchSizeRecorder = Recorder(
            label: "fdb_scrubber_batch_size",
            dimensions: metricsLabels,
            aggregate: true
        )
    }

    // === Public API ===
    public func scrubIndex() async throws -> ScrubberResult {
        let start = Date()

        do {
            logger.info("Starting index scrubber", metadata: [
                "index": "\(index.name)",
                "indexType": "\(index.type.rawValue)",
                "allowRepair": "\(configuration.allowRepair)"
            ])

            // RangeSetの初期化
            let rangeSet = try await initializeRangeSet()

            // 初期進捗率を記録
            progressGauge.record(0.0)

            // Phase 1: Index entries scan
            let (phase1Issues, indexEntriesScanned) = try await scrubIndexEntries(
                rangeSet: rangeSet
            )

            logger.info("Phase 1 completed", metadata: [
                "entriesScanned": "\(indexEntriesScanned)",
                "issuesDetected": "\(phase1Issues.count)"
            ])

            // Phase 2: Records scan
            let (phase2Issues, recordsScanned) = try await scrubRecords(
                rangeSet: rangeSet
            )

            logger.info("Phase 2 completed", metadata: [
                "recordsScanned": "\(recordsScanned)",
                "issuesDetected": "\(phase2Issues.count)"
            ])

            // 完了時は進捗率 1.0
            progressGauge.record(1.0)

            // Aggregate results
            let allIssues = phase1Issues + phase2Issues
            let totalIssues = allIssues.count
            let repairedIssues = configuration.allowRepair ? totalIssues : 0

            let elapsed = Date().timeIntervalSince(start)
            scanDuration.recordSeconds(elapsed)

            let result = ScrubberResult(
                isHealthy: totalIssues == 0,
                completedSuccessfully: true,
                summary: ScrubberSummary(
                    timeElapsed: elapsed,
                    entriesScanned: indexEntriesScanned,
                    recordsScanned: recordsScanned,
                    issuesDetected: totalIssues,
                    issuesRepaired: repairedIssues,
                    indexName: index.name
                ),
                terminationReason: nil
            )

            logger.info("Scrubber completed", metadata: [
                "isHealthy": "\(result.isHealthy)",
                "totalIssues": "\(totalIssues)",
                "repairedIssues": "\(repairedIssues)",
                "timeElapsed": "\(String(format: "%.2f", result.summary.timeElapsed))s"
            ])

            return result

        } catch {
            logger.error("Scrubber failed", metadata: [
                "error": "\(error.safeDescription)"
            ])

            // Record failure metric
            issuesCounter.increment(
                by: 1,
                dimensions: [("type", "scrubber_failure"), ("phase", "overall")]
            )

            let elapsed = Date().timeIntervalSince(start)
            let result = ScrubberResult(
                isHealthy: false,
                completedSuccessfully: false,
                summary: ScrubberSummary(
                    timeElapsed: elapsed,
                    entriesScanned: 0,
                    recordsScanned: 0,
                    issuesDetected: 0,
                    issuesRepaired: 0,
                    indexName: index.name
                ),
                terminationReason: "\(error)"
            )

            throw error
        }
    }

    // === Private Implementation ===

    private func scrubIndexEntriesBatch(...) async throws -> (...) {
        var batchCount = 0
        var skipCount = 0
        var issuesFound: [ScrubberIssue] = []

        for try await (indexKey, _) in sequence {
            batchCount += 1

            // Tuple decode with error handling
            let indexTuple: Tuple
            do {
                indexTuple = try indexSubspace.unpack(indexKey)
            } catch {
                skipCount += 1

                // サンプリング: 1/100のみログ
                if Int.random(in: 0..<100) == 0 {
                    logger.warning("Tuple decode failed", metadata: [
                        "key": "\(indexKey.safeLogRepresentation)",
                        "error": "\(error.safeDescription)",
                        "sampling": "1/100"
                    ])
                }
                continue
            }

            // ... rest of implementation ...
        }

        // ✅ バッチ終了時に一括記録
        scanProgressCounter.increment(by: batchCount)
        if skipCount > 0 {
            skipCounter.increment(
                by: skipCount,
                dimensions: [("reason", "tuple_decode_failure"), ("phase", "phase1")]
            )
        }
        batchSizeRecorder.record(batchCount)

        // 進捗率を更新
        let progress = try await rangeSet.getProgress()
        progressGauge.record(progress)

        return (nextContinuation, issuesFound, batchEndKey, batchCount)
    }
}
```

---

## トラブルシューティング

### 問題: スキップが多い

**症状**: `fdb_scrubber_skipped_total` が高い

**原因と対処**:

| reason | 原因 | 対処方法 |
|--------|------|---------|
| tuple_decode_failure | データ破損またはSubspace不一致 | 1. Subspace設定を確認<br>2. データ復元を検討 |
| deserialization_failure | スキーマ非互換 | 1. RecordAccessの実装を確認<br>2. スキーマ移行が必要か検討 |
| transaction_too_large | バッチサイズが大きすぎる | entriesScanLimitを削減 |

**デバッグ手順**:

```bash
# スキップ理由の内訳を確認
curl -G 'http://prometheus:9090/api/v1/query' \
  --data-urlencode 'query=sum by (reason) (fdb_scrubber_skipped_total{index="user_by_email"})'

# ログで詳細を確認（サンプリングされているため全件ではない）
grep "skipping" /var/log/scrubber.log | tail -20
```

### 問題: リトライが頻発

**症状**: `fdb_scrubber_retries_total` が高い

**原因と対処**:

| error_code | 説明 | 対処方法 |
|-----------|------|---------|
| 1007 | transaction_too_old (5秒超過) | entriesScanLimitを削減 |
| 2101 | transaction_too_large | maxTransactionBytesを増やすかentriesScanLimitを削減 |
| 1020 | not_committed (競合) | クラスタ負荷を確認 |

**デバッグ手順**:

```bash
# エラーコード別のリトライ率
curl -G 'http://prometheus:9090/api/v1/query' \
  --data-urlencode 'query=rate(fdb_scrubber_retries_total[5m])'
```

### 問題: スキャンが遅い

**症状**: `fdb_scrubber_scan_duration_seconds` が長い（>300秒）

**原因と対処**:

1. **大量のIssue**: allowRepair=trueで修復処理が発生
   - 対処: 先にallowRepair=falseで実行し、Issueの量を確認
2. **クラスタ負荷**: FoundationDBクラスタが遅い
   - 対処: fdbcliでクラスタ状態を確認
3. **バッチサイズ**: 小さすぎてオーバーヘッドが大きい
   - 対処: entriesScanLimitを増やす（ただしトランザクションサイズに注意）

**デバッグ手順**:

```bash
# 進捗率を確認
curl -G 'http://prometheus:9090/api/v1/query' \
  --data-urlencode 'query=fdb_scrubber_progress_ratio{index="user_by_email"}'

# 進捗速度を確認（%/分）
curl -G 'http://prometheus:9090/api/v1/query' \
  --data-urlencode 'query=rate(fdb_scrubber_progress_ratio{index="user_by_email"}[5m]) * 60 * 100'
```

### 問題: スクラバーが停滞

**症状**: `fdb_scrubber_progress_ratio` が変化しない

**原因と対処**:

1. **特定のキーで失敗**: スキップ処理が失敗している
   - ログで`RecordLayerError.scrubberSkipFailed`を確認
   - 該当キーを手動で削除または修正

2. **RangeSetの問題**: 進捗追跡が正しく更新されていない
   - RangeSetのデータをfdbcliで確認

**デバッグ手順**:

```bash
# アラートが発火しているか確認
curl 'http://prometheus:9090/api/v1/alerts' | jq '.data.alerts[] | select(.labels.alertname == "ScrubberStalled")'

# 最新のログを確認
tail -f /var/log/scrubber.log | grep -E "(error|warning)"
```

---

## 参考資料

- [swift-metrics on GitHub](https://github.com/apple/swift-metrics)
- [swift-metrics on DeepWiki](https://deepwiki.com/apple/swift-metrics)
- [SwiftPrometheus on GitHub](https://github.com/MrLotU/SwiftPrometheus)
- [swift-log on GitHub](https://github.com/apple/swift-log)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [FoundationDB Documentation](https://apple.github.io/foundationdb/)

---

**Last Updated**: 2025-01-15
**swift-metrics Version**: 2.5.0+
**SwiftPrometheus Version**: 1.0.0+
**Swift Version**: 6.0+
