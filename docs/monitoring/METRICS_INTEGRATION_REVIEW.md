# メトリクス統合レビューと改善提案

> **⚠️ OBSOLETE - このドキュメントは古くなっています**
>
> このドキュメントは初期の設計レビューであり、古いAPI設計（recordTypeパラメータ付き）を含んでいます。
>
> **最新の設計とドキュメント**は以下を参照してください：
> - [METRICS_AND_LOGGING.md](../METRICS_AND_LOGGING.md) - 現在の設計とベストプラクティス
> - MetricsRecorder.swift - 最新のプロトコル定義
> - SwiftMetricsRecorder.swift - 最新の実装
>
> **主な変更点**:
> - recordTypeパラメータを削除（Metrics = 集約、Logs = 詳細の原則）
> - 構造化ログによる詳細追跡
> - メモリ効率の改善

**作成日**: 2025-01-06
**ステータス**: ~~レビュー結果と改善提案~~ **OBSOLETE (2025-01-06時点)**

---

## エグゼクティブサマリー

現在のメトリクス実装は**OnlineIndexScrubberのみ**に限定されており、DB全体の運用可視化には不十分です。また、swift-metricsの使用は独自実装に偏っており、Prometheusなどのバックエンドとの統合が未検証です。

**採用した設計パターン**: **Protocol Injection + Null Object Pattern**

**コア方針**:
1. **RecordStore/QueryPlanner/OnlineIndexerなどコアクラスは`MetricsRecorder`プロトコルにのみ依存**
   - 具体的な収集先（swift-metrics、自前ロガー等）はすべて外部注入に任せる
2. **メトリクスが不要ならNullMetricsRecorderを注入（デフォルト）**
   - 呼び出し側は既存APIのまま利用可能で、オーバーヘッドも最小
3. **エラー時・成功時の計測を共通パターンで実装**
   - `do`/`catch`または`defer`で時間計測・エラー記録を必ず通るようにする
4. **RecordLayerコアは具体的なMetricsフレームワークに依存しない**
   - `MetricsBootstrap`等の初期化はアプリケーション側で実施

**アーキテクチャ**:
1. **MetricsRecorderプロトコル**: メトリクス収集のインターフェース（必要なメソッドのみ定義）
2. **NullMetricsRecorder**: 空実装（デフォルト、ゼロコスト）
3. **SwiftMetricsRecorder**: swift-metricsベースの具体実装（オプション）
4. **コンストラクタ注入**: `metricsRecorder`パラメータ追加（デフォルト: `NullMetricsRecorder()`）

**推奨アクション**:
1. 🔴 **最優先（Week 1）**: Protocol定義とRecordStore統合
   - `MetricsRecorder`プロトコル実装
   - `NullMetricsRecorder`、`SwiftMetricsRecorder`実装
   - RecordStoreに`metricsRecorder`プロパティ追加（デフォルト: NullMetricsRecorder）
2. 🔴 **高優先（Week 2）**: Prometheus統合
   - `MetricsBootstrap`実装
   - HTTPエンドポイント（/metrics）
   - 互換性検証テスト
3. 🟡 **中優先（Week 3-4）**: 追加コンポーネント統合とダッシュボード
   - QueryPlanner、OnlineIndexerへの統合
   - Grafanaダッシュボード構築

**この設計の利点**:
- ✅ **依存性逆転**: 具体的なMetricsフレームワークではなく、プロトコルに依存
- ✅ **SRP維持**: メトリクスロジックは`MetricsRecorder`実装に隔離
- ✅ **ゼロコスト抽象化**: デフォルトの`NullMetricsRecorder`はコンパイラ最適化で消える
- ✅ **最小限の変更**: RecordStore等に1プロパティ追加のみ
- ✅ **パフォーマンス**: 直接呼び出しでオーバーヘッド最小
- ✅ **柔軟性**: swift-metrics、Prometheus、カスタム実装を自由に選択可能

**実装期間**: 合計4週間

---

## 現状分析

### 1. メトリクス実装状況

#### ✅ 実装済み: OnlineIndexScrubber

**メトリクスタイプ**:
- `Counter`: entriesScanned, recordsScanned, danglingEntries, missingEntries, skipped
- `Timer`: batchDuration
- `Gauge`: progress

**ラベル（dimensions）**:
- `index_name`: インデックス名
- `record_type`: レコード型
- `phase`: phase1/phase2/index_scan/record_scan
- `issue_type`: dangling_entry/missing_entry
- `reason`: スキップ理由

**評価**: ✅ 適切に実装されている

#### ❌ 未実装: 主要コンポーネント

| コンポーネント | 現状 | 必要なメトリクス |
|--------------|------|----------------|
| **RecordStore** | Loggerのみ | CRUD操作数、レイテンシー、エラー率 |
| **QueryPlanner** | なし | クエリプラン生成時間、プランキャッシュヒット率 |
| **IndexManager** | なし | インデックス更新数、更新レイテンシー |
| **OnlineIndexer** | Loggerのみ | 構築進捗、スループット、リトライ回数 |
| **RecordContext/Transaction** | なし | トランザクション数、コミット/ロールバック率、競合数 |
| **StatisticsManager** | なし | 統計更新頻度、ヒストグラム精度 |

### 2. swift-metrics使用状況

#### 現在の実装パターン

```swift
// OnlineIndexScrubberの例
private let entriesScannedCounter: Counter

init() {
    self.entriesScannedCounter = Counter(
        label: "fdb_scrubber_entries_scanned_total",
        dimensions: [("index_name", indexName), ("record_type", recordType)]
    )
}

// 使用
entriesScannedCounter.increment(by: Int64(scannedCount))
```

**評価**:
- ✅ **良い点**: dimensionsを使用してラベリング
- ✅ **良い点**: メトリクス名が明確（`fdb_*_total`パターン）
- ⚠️ **懸念点**: メトリクスバックエンドの初期化がない
- ❌ **問題点**: Prometheusとの統合が未検証

### 3. 依存関係

```swift
// Package.swift
.package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
.package(url: "https://github.com/MrLotU/SwiftPrometheus.git", from: "1.0.0"),
```

**評価**:
- ✅ swift-metricsとSwiftPrometheusの両方が依存関係に含まれる
- ❌ SwiftPrometheusが実際には使われていない（dead dependency）
- ❌ メトリクスバックエンドのセットアップコードがない

---

## 問題点の詳細

### 問題1: Single Responsibility Principle (SRP) 違反の懸念

**影響**: メトリクス機能の追加方法によってはコアロジックとメトリクスが混在し、保守性が低下する可能性

**❌ アンチパターン例**: Metricsフレームワークに直接依存

```swift
// ❌ アンチパターン: RecordStoreが具体的なMetricsフレームワークに依存
public final class RecordStore {
    private let database: any DatabaseProtocol
    private let metaData: RecordMetaData

    // 具体的な実装に依存（Metrics型に密結合）
    private let saveCounter: Counter  // ← swift-metricsに直接依存
    private let saveTimer: Timer      // ← swift-metricsに直接依存

    func save<T: Recordable>(_ record: T) async throws {
        let start = DispatchTime.now()
        defer {
            saveTimer.recordNanoseconds(...)
            saveCounter.increment()
        }
        try await actualSave(record)
    }
}
```

**問題点**:
- ✗ RecordStoreが具体的なMetricsフレームワーク（swift-metrics）に密結合
- ✗ メトリクスフレームワークを変更する場合、RecordStoreも変更が必要
- ✗ メトリクスなしでテストする場合でもMetricsフレームワークが必要
- ✗ メトリクス変数がRecordStoreのプロパティを汚染

**✅ 正しいアプローチ**: Protocol Injection + Null Object Pattern

```swift
// ✅ 正しい設計: プロトコルに依存し、デフォルトはNull Object
public protocol MetricsRecorder: Sendable {
    func recordSave(recordType: String, duration: UInt64)
    func recordFetch(recordType: String, duration: UInt64)
    func recordDelete(recordType: String, duration: UInt64)
    func recordError(operation: String, recordType: String, errorType: String)
}

// Null Object Pattern: デフォルト実装（何もしない）
public struct NullMetricsRecorder: MetricsRecorder {
    public func recordSave(recordType: String, duration: UInt64) {}
    public func recordFetch(recordType: String, duration: UInt64) {}
    public func recordDelete(recordType: String, duration: UInt64) {}
    public func recordError(operation: String, recordType: String, errorType: String) {}
}

// RecordStoreはプロトコルに依存（具体実装から分離）
public final class RecordStore {
    private let database: any DatabaseProtocol
    private let metaData: RecordMetaData

    // プロトコルに依存（抽象化）、デフォルトはNull Object
    private let metricsRecorder: any MetricsRecorder

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        statisticsManager: any StatisticsManagerProtocol,
        metricsRecorder: any MetricsRecorder = NullMetricsRecorder(),  // デフォルト
        logger: Logger? = nil
    ) {
        self.database = database
        self.metaData = metaData
        self.metricsRecorder = metricsRecorder
        // ...
    }

    public func save<T: Recordable>(_ record: T) async throws {
        let start = DispatchTime.now()

        do {
            // ストレージロジック（本来の責務）
            try await actualSave(record)

            // メトリクス記録（オプショナル、プロトコル経由）
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordSave(recordType: T.recordTypeName, duration: duration)
        } catch {
            metricsRecorder.recordError(
                operation: "save",
                recordType: T.recordTypeName,
                errorType: String(describing: type(of: error))
            )
            throw error
        }
    }
}
```

**この設計の利点**:
- ✅ **依存性逆転**: RecordStoreは抽象（Protocol）に依存、具体実装に非依存
- ✅ **SRP維持**: メトリクスロジックは`MetricsRecorder`実装に隔離
- ✅ **ゼロコスト**: `NullMetricsRecorder`はメトリクス不要時のオーバーヘッドなし
- ✅ **テスト容易**: モック`MetricsRecorder`で簡単にテスト可能
- ✅ **柔軟性**: swift-metrics、Prometheus、カスタム実装など自由に選択

### 問題2: メトリクス範囲が限定的

**影響**: 本番環境での運用監視が困難

**具体例**:
```
❌ クエリのパフォーマンス問題を検出できない
   → クエリ実行時間、プラン選択の適切性が不明

❌ インデックスのホットスポットを検出できない
   → どのインデックスが頻繁に使われているか不明

❌ トランザクション競合の頻度がわからない
   → 楽観的並行性制御の問題を検出できない

❌ CRUD操作のスループットがわからない
   → システムの負荷状況が不明
```

### 問題3: Prometheusとの統合未検証

**影響**: メトリクスを可視化できない

**問題の詳細**:
1. **メトリクスバックエンドの初期化がない**
   ```swift
   // 必要だが欠けているコード
   import SwiftPrometheus

   // アプリケーション起動時
   let prometheusClient = PrometheusClient()
   MetricsSystem.bootstrap(prometheusClient)
   ```

2. **HTTPエンドポイントの欠如**
   - Prometheusがスクレイプする `/metrics` エンドポイントがない
   - メトリクスをエクスポートする仕組みがない

3. **互換性の未検証**
   - dimensionsがPrometheusのlabelsに正しくマッピングされるか不明
   - メトリクス名がPrometheusの命名規則に準拠しているか未確認

### 問題4: 独自拡張への偏り

**影響**: 標準的な監視スタックとの統合が困難

**具体的な問題**:
1. **カスタムメトリクス初期化パターン**
   - 各クラスが独自にCounter/Timer/Gaugeを初期化
   - 再利用可能なメトリクスファクトリーがない

2. **ラベリング戦略の不統一**
   - `dimensions`の使い方が統一されていない
   - 必須ラベル（例: `service_name`, `instance`）の欠如

3. **メトリクス命名の一貫性**
   - `fdb_scrubber_*` パターンのみ使用
   - 他のコンポーネント用の命名規則が未定義

---

## 改善提案

### 公式設計パターン: Protocol Injection + Null Object Pattern

**設計原則**:
1. **Protocol Injection**: メトリクス収集インターフェースをプロトコルとして定義し、コンストラクタから注入
2. **Null Object Pattern**: メトリクス不要時のデフォルト実装（何もしない）
3. **Dependency Inversion Principle**: 具体的なMetricsフレームワークではなく、抽象（Protocol）に依存

**実装ガイドライン**:
- コアクラス（RecordStore、QueryPlanner等）は`MetricsRecorder`プロトコルにのみ依存
- 具体的な収集先（swift-metrics、カスタム実装）は外部から注入
- `MetricsBootstrap`等の初期化処理は**アプリケーション側で実施**（RecordLayerコアからは呼ばない）
- エラー時・成功時の計測を`do`/`catch`または`defer`で共通パターン化

---

### Phase 1: Protocolと基本実装（1週間）

#### 1.1 MetricsRecorderプロトコルの定義

**優先度**: 🔴 最優先

**新規ファイル**: `Sources/FDBRecordLayer/Monitoring/MetricsRecorder.swift`

```swift
import Foundation

/// Protocol for recording metrics from FDB Record Layer components
///
/// This protocol provides an abstraction for metrics collection, allowing
/// different implementations (swift-metrics, Prometheus, custom, etc.) without
/// coupling core components to specific frameworks.
///
/// **Design Pattern**: Protocol Injection + Null Object Pattern
///
/// **Example**:
/// ```swift
/// // Null implementation (default, zero cost)
/// let nullRecorder = NullMetricsRecorder()
///
/// // SwiftMetrics implementation
/// let swiftRecorder = SwiftMetricsRecorder(component: "record_store")
///
/// // Inject into RecordStore
/// let store = RecordStore(..., metricsRecorder: swiftRecorder)
/// ```
///
/// **将来の拡張性**:
/// - 新しいメソッドを追加する場合は、`extension MetricsRecorder`でデフォルト実装を提供し、
///   既存の実装への影響を最小化すること
/// - 例: `extension MetricsRecorder { func recordNewMetric(...) {} }`
public protocol MetricsRecorder: Sendable {
    // MARK: - RecordStore Metrics

    /// Record a save operation
    func recordSave(recordType: String, duration: UInt64)

    /// Record a fetch operation
    func recordFetch(recordType: String, duration: UInt64)

    /// Record a delete operation
    func recordDelete(recordType: String, duration: UInt64)

    /// Record an error
    func recordError(operation: String, recordType: String, errorType: String)

    // MARK: - QueryPlanner Metrics

    /// Record query plan generation
    func recordQueryPlan(recordType: String, duration: UInt64, planType: String)

    /// Record plan cache hit
    func recordPlanCacheHit(recordType: String)

    /// Record plan cache miss
    func recordPlanCacheMiss(recordType: String)

    // MARK: - OnlineIndexer Metrics

    /// Record indexer batch progress
    func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64)

    /// Record indexer retry
    func recordIndexerRetry(indexName: String, reason: String)

    /// Record indexer progress
    func recordIndexerProgress(indexName: String, progress: Double)
}

// MARK: - Future Extensions Pattern

// 将来メソッドを追加する場合の例：
// extension MetricsRecorder {
//     func recordNewMetric(param: String) {
//         // デフォルトは何もしない（既存実装への影響なし）
//     }
// }
```

**実装上の補足**:

`MetricsRecorder`は現在`Sendable`のみを継承していますが、
`any MetricsRecorder`による値型の保持が気になる場合は、
`AnyObject`制約を追加することも検討できます：

```swift
// オプション: 参照型のみに制限する場合
public protocol MetricsRecorder: AnyObject, Sendable {
    // ...
}
```

**メリット**:
- `weak`参照が可能になり、循環参照を回避できる
- 値型（struct）の意図しないコピーを防止

**デメリット**:
- `NullMetricsRecorder`を`class`にする必要がある（現在は`struct`）
- 値型の実装が不可能になる

**推奨**: 現時点では`Sendable`のみで十分。将来的に循環参照の問題が発生した場合に`AnyObject`を追加検討。

#### 1.2 NullMetricsRecorder（Null Object Pattern）

**優先度**: 🔴 最優先

**同ファイル内に追加**: `Sources/FDBRecordLayer/Monitoring/MetricsRecorder.swift`

```swift
/// Null implementation of MetricsRecorder (does nothing)
///
/// This is the default implementation used when metrics are not needed.
/// Compiler optimizations can eliminate these no-op calls entirely.
///
/// **Usage**:
/// ```swift
/// // Default: no metrics overhead
/// let store = RecordStore(...) // uses NullMetricsRecorder by default
/// ```
public struct NullMetricsRecorder: MetricsRecorder {
    public init() {}

    // MARK: - RecordStore Metrics

    public func recordSave(recordType: String, duration: UInt64) {}
    public func recordFetch(recordType: String, duration: UInt64) {}
    public func recordDelete(recordType: String, duration: UInt64) {}
    public func recordError(operation: String, recordType: String, errorType: String) {}

    // MARK: - QueryPlanner Metrics

    public func recordQueryPlan(recordType: String, duration: UInt64, planType: String) {}
    public func recordPlanCacheHit(recordType: String) {}
    public func recordPlanCacheMiss(recordType: String) {}

    // MARK: - OnlineIndexer Metrics

    public func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64) {}
    public func recordIndexerRetry(indexName: String, reason: String) {}
    public func recordIndexerProgress(indexName: String, progress: Double) {}
}
```

#### 1.3 SwiftMetricsRecorder実装

**優先度**: 🔴 高

**新規ファイル**: `Sources/FDBRecordLayer/Monitoring/SwiftMetricsRecorder.swift`

```swift
import Metrics
import Foundation

/// SwiftMetrics-based implementation of MetricsRecorder
///
/// This implementation uses the swift-metrics framework to record metrics.
/// All metrics follow Prometheus naming conventions.
///
/// **Example**:
/// ```swift
/// let recorder = SwiftMetricsRecorder(
///     service: "my_app",
///     component: "record_store"
/// )
/// let store = RecordStore(..., metricsRecorder: recorder)
/// ```
public struct SwiftMetricsRecorder: MetricsRecorder {
    private let baseDimensions: [(String, String)]

    // RecordStore metrics
    private let saveCounter: Counter
    private let fetchCounter: Counter
    private let deleteCounter: Counter
    private let saveTimer: Timer
    private let fetchTimer: Timer
    private let deleteTimer: Timer
    private let errorCounter: Counter

    // QueryPlanner metrics
    private let queryPlanCounter: Counter
    private let queryPlanTimer: Timer
    private let planCacheHitCounter: Counter
    private let planCacheMissCounter: Counter

    // OnlineIndexer metrics
    private let indexerBatchCounter: Counter
    private let indexerBatchTimer: Timer
    private let indexerRetryCounter: Counter
    private let indexerProgressGauge: Gauge

    public init(
        service: String = "fdb_record_layer",
        component: String
    ) {
        self.baseDimensions = [
            ("service", service),
            ("component", component)
        ]

        // Initialize RecordStore metrics
        self.saveCounter = Counter(
            label: "fdb_record_save_total",
            dimensions: baseDimensions
        )
        self.fetchCounter = Counter(
            label: "fdb_record_fetch_total",
            dimensions: baseDimensions
        )
        self.deleteCounter = Counter(
            label: "fdb_record_delete_total",
            dimensions: baseDimensions
        )
        self.saveTimer = Timer(
            label: "fdb_record_save_duration_seconds",
            dimensions: baseDimensions
        )
        self.fetchTimer = Timer(
            label: "fdb_record_fetch_duration_seconds",
            dimensions: baseDimensions
        )
        self.deleteTimer = Timer(
            label: "fdb_record_delete_duration_seconds",
            dimensions: baseDimensions
        )
        self.errorCounter = Counter(
            label: "fdb_record_errors_total",
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
            label: "fdb_query_plan_cache_hits_total",
            dimensions: baseDimensions
        )
        self.planCacheMissCounter = Counter(
            label: "fdb_query_plan_cache_misses_total",
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
            label: "fdb_indexer_retries_total",
            dimensions: baseDimensions
        )
        self.indexerProgressGauge = Gauge(
            label: "fdb_indexer_progress_ratio",
            dimensions: baseDimensions
        )
    }

    // MARK: - RecordStore Metrics

    public func recordSave(recordType: String, duration: UInt64) {
        saveTimer.recordNanoseconds(Int64(duration))
        saveCounter.increment(by: 1, [("record_type", recordType)])
    }

    public func recordFetch(recordType: String, duration: UInt64) {
        fetchTimer.recordNanoseconds(Int64(duration))
        fetchCounter.increment(by: 1, [("record_type", recordType)])
    }

    public func recordDelete(recordType: String, duration: UInt64) {
        deleteTimer.recordNanoseconds(Int64(duration))
        deleteCounter.increment(by: 1, [("record_type", recordType)])
    }

    public func recordError(operation: String, recordType: String, errorType: String) {
        errorCounter.increment(by: 1, [
            ("operation", operation),
            ("record_type", recordType),
            ("error_type", errorType)
        ])
    }

    // MARK: - QueryPlanner Metrics

    public func recordQueryPlan(recordType: String, duration: UInt64, planType: String) {
        queryPlanTimer.recordNanoseconds(Int64(duration))
        queryPlanCounter.increment(by: 1, [
            ("record_type", recordType),
            ("plan_type", planType)
        ])
    }

    public func recordPlanCacheHit(recordType: String) {
        planCacheHitCounter.increment(by: 1, [("record_type", recordType)])
    }

    public func recordPlanCacheMiss(recordType: String) {
        planCacheMissCounter.increment(by: 1, [("record_type", recordType)])
    }

    // MARK: - OnlineIndexer Metrics

    public func recordIndexerBatch(indexName: String, recordsProcessed: Int64, duration: UInt64) {
        indexerBatchTimer.recordNanoseconds(Int64(duration))
        indexerBatchCounter.increment(by: recordsProcessed, [("index_name", indexName)])
    }

    public func recordIndexerRetry(indexName: String, reason: String) {
        indexerRetryCounter.increment(by: 1, [
            ("index_name", indexName),
            ("reason", reason)
        ])
    }

    public func recordIndexerProgress(indexName: String, progress: Double) {
        indexerProgressGauge.record(progress, [("index_name", indexName)])
    }
}
```

**メトリクス一覧**:

| メトリクス名 | 型 | 説明 | ラベル |
|------------|-----|------|--------|
| `fdb_record_save_total` | Counter | 保存操作数 | `component`, `record_type` |
| `fdb_record_fetch_total` | Counter | 読み取り操作数 | `component`, `record_type` |
| `fdb_record_delete_total` | Counter | 削除操作数 | `component`, `record_type` |
| `fdb_record_save_duration_seconds` | Timer | 保存レイテンシー | `component`, `record_type` |
| `fdb_record_fetch_duration_seconds` | Timer | 読み取りレイテンシー | `component`, `record_type` |
| `fdb_record_delete_duration_seconds` | Timer | 削除レイテンシー | `component`, `record_type` |
| `fdb_record_errors_total` | Counter | エラー数 | `component`, `operation`, `record_type`, `error_type` |
| `fdb_query_plan_total` | Counter | クエリプラン生成数 | `component`, `record_type`, `plan_type` |
| `fdb_query_plan_duration_seconds` | Timer | プラン生成時間 | `component`, `record_type`, `plan_type` |
| `fdb_query_plan_cache_hits_total` | Counter | キャッシュヒット数 | `component`, `record_type` |
| `fdb_query_plan_cache_misses_total` | Counter | キャッシュミス数 | `component`, `record_type` |
| `fdb_indexer_batch_total` | Counter | インデックスバッチ処理レコード数 | `component`, `index_name` |
| `fdb_indexer_batch_duration_seconds` | Timer | バッチ処理時間 | `component`, `index_name` |
| `fdb_indexer_retries_total` | Counter | リトライ回数 | `component`, `index_name`, `reason` |
| `fdb_indexer_progress_ratio` | Gauge | 進捗率（0.0-1.0） | `component`, `index_name` |

#### 1.4 RecordStoreへの統合

**優先度**: 🔴 最優先

**変更ファイル**: `Sources/FDBRecordLayer/Store/RecordStore.swift`

```swift
public final class RecordStore: Sendable {
    // 既存のプロパティ
    nonisolated(unsafe) private let database: any DatabaseProtocol
    public let subspace: Subspace
    public let metaData: RecordMetaData
    private let logger: Logger
    private let statisticsManager: any StatisticsManagerProtocol

    // 追加: MetricsRecorder（デフォルトはNull Object）
    private let metricsRecorder: any MetricsRecorder

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        statisticsManager: any StatisticsManagerProtocol,
        metricsRecorder: any MetricsRecorder = NullMetricsRecorder(),  // デフォルト
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.statisticsManager = statisticsManager
        self.metricsRecorder = metricsRecorder
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.store")

        // 既存の初期化コード
        self.recordSubspace = subspace.subspace(Tuple("R"))
        self.indexSubspace = subspace.subspace(Tuple("I"))
    }

    public func save<T: Recordable>(_ record: T) async throws {
        let start = DispatchTime.now()

        do {
            // 既存の保存ロジック（変更なし）
            let recordAccess = GenericRecordAccess<T>()
            let bytes = try recordAccess.serialize(record)
            let primaryKey = recordAccess.extractPrimaryKey(from: record)

            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
            let key = typeSubspace.subspace(primaryKey).pack(Tuple())
            let tr = context.getTransaction()

            let oldRecord: T?
            if let existingBytes = try await tr.getValue(for: key, snapshot: false) {
                oldRecord = try recordAccess.deserialize(existingBytes)
            } else {
                oldRecord = nil
            }

            tr.setValue(bytes, for: key)

            let indexManager = IndexManager(metaData: metaData, subspace: indexSubspace)
            try await indexManager.updateIndexes(
                for: record,
                primaryKey: primaryKey,
                oldRecord: oldRecord,
                context: context,
                recordSubspace: recordSubspace
            )

            try await context.commit()

            // メトリクス記録（成功時）
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordSave(recordType: T.recordTypeName, duration: duration)

        } catch {
            // メトリクス記録（エラー時）
            metricsRecorder.recordError(
                operation: "save",
                recordType: T.recordTypeName,
                errorType: String(describing: type(of: error))
            )
            throw error
        }
    }

    public func fetch<T: Recordable>(
        _ type: T.Type,
        by primaryKey: any TupleElement
    ) async throws -> T? {
        let start = DispatchTime.now()

        do {
            // 既存の取得ロジック（変更なし）
            let recordAccess = GenericRecordAccess<T>()
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
            let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())
            let tr = context.getTransaction()

            guard let bytes = try await tr.getValue(for: key, snapshot: true) else {
                return nil
            }

            let result = try recordAccess.deserialize(bytes)

            // メトリクス記録（成功時）
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordFetch(recordType: T.recordTypeName, duration: duration)

            return result

        } catch {
            // メトリクス記録（エラー時）
            metricsRecorder.recordError(
                operation: "fetch",
                recordType: T.recordTypeName,
                errorType: String(describing: type(of: error))
            )
            throw error
        }
    }

    public func delete<T: Recordable>(
        _ type: T.Type,
        by primaryKey: any TupleElement
    ) async throws {
        let start = DispatchTime.now()

        do {
            // 既存の削除ロジック（変更なし）
            let recordAccess = GenericRecordAccess<T>()
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
            let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())
            let tr = context.getTransaction()

            let oldRecord: T?
            if let existingBytes = try await tr.getValue(for: key, snapshot: false) {
                oldRecord = try recordAccess.deserialize(existingBytes)
            } else {
                return
            }

            guard let record = oldRecord else {
                return
            }

            tr.clear(key: key)

            let indexManager = IndexManager(metaData: metaData, subspace: indexSubspace)
            try await indexManager.deleteIndexes(
                oldRecord: record,
                primaryKey: Tuple([primaryKey]),
                context: context,
                recordSubspace: recordSubspace
            )

            try await context.commit()

            // メトリクス記録（成功時）
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordDelete(recordType: T.recordTypeName, duration: duration)

        } catch {
            // メトリクス記録（エラー時）
            metricsRecorder.recordError(
                operation: "delete",
                recordType: T.recordTypeName,
                errorType: String(describing: type(of: error))
            )
            throw error
        }
    }
}
```

**変更のポイント**:
- ✅ 追加したのは`metricsRecorder`プロパティ1つだけ
- ✅ デフォルトは`NullMetricsRecorder()`でゼロコスト
- ✅ 既存のロジックは一切変更なし
- ✅ メトリクス呼び出しは各メソッドの最後に追加

#### 1.5 使用例

**新規ファイル**: `Examples/MetricsIntegrationExample.swift`

```swift
import FDBRecordLayer
import FoundationDB

// ケース1: メトリクスなし（デフォルト）
let storeWithoutMetrics = RecordStore(
    database: database,
    subspace: Subspace(rootPrefix: "records"),
    metaData: metaData,
    statisticsManager: statisticsManager
    // metricsRecorderを指定しない → NullMetricsRecorder使用
)

// ケース2: SwiftMetricsでメトリクス収集
let metricsRecorder = SwiftMetricsRecorder(component: "record_store")
let storeWithMetrics = RecordStore(
    database: database,
    subspace: Subspace(rootPrefix: "records"),
    metaData: metaData,
    statisticsManager: statisticsManager,
    metricsRecorder: metricsRecorder  // SwiftMetricsRecorder注入
)

// 透過的に使用 - メトリクスは自動的に記録される
try await storeWithMetrics.save(user)
let fetchedUser = try await storeWithMetrics.fetch(User.self, by: 1)
try await storeWithMetrics.delete(User.self, by: 1)

// ケース3: カスタムMetricsRecorder実装
struct LoggingMetricsRecorder: MetricsRecorder {
    func recordSave(recordType: String, duration: UInt64) {
        print("SAVE: \(recordType) took \(duration)ns")
    }
    // ... 他のメソッド実装
}

let loggingRecorder = LoggingMetricsRecorder()
let storeWithLogging = RecordStore(
    database: database,
    subspace: Subspace(rootPrefix: "records"),
    metaData: metaData,
    statisticsManager: statisticsManager,
    metricsRecorder: loggingRecorder
)
```

**Protocol Injectionの利点**:
- ✅ **最小限の変更**: RecordStoreに1プロパティ追加のみ
- ✅ **ゼロコスト抽象化**: デフォルトの`NullMetricsRecorder`はコンパイラ最適化で消える
- ✅ **柔軟性**: swift-metrics、Prometheus、カスタム実装を自由に選択
- ✅ **テスト容易性**: モック`MetricsRecorder`で簡単にテスト
- ✅ **依存性逆転**: RecordStoreは`MetricsRecorder`プロトコルに依存、具体実装には非依存

---

## 破壊的API変更

### 変更内容

メトリクス統合に伴い、以下のコアクラスのイニシャライザに`metricsRecorder`パラメータが追加されます：

**変更されるクラス**:
- `RecordStore`
- `QueryPlanner`（将来）
- `OnlineIndexer`（将来）

**変更例（RecordStore）**:
```swift
// 変更前
public init(
    database: any DatabaseProtocol,
    subspace: Subspace,
    metaData: RecordMetaData,
    statisticsManager: any StatisticsManagerProtocol,
    logger: Logger? = nil
)

// 変更後
public init(
    database: any DatabaseProtocol,
    subspace: Subspace,
    metaData: RecordMetaData,
    statisticsManager: any StatisticsManagerProtocol,
    metricsRecorder: any MetricsRecorder = NullMetricsRecorder(),  // ← 追加
    logger: Logger? = nil
)
```

### 後方互換性

**デフォルト引数により既存コードは変更不要**:
```swift
// 既存コード（変更なしで動作）
let store = RecordStore(
    database: db,
    subspace: subspace,
    metaData: metaData,
    statisticsManager: statsManager
)
// → 自動的にNullMetricsRecorder()が使用される
```

### NullMetricsRecorderの役割

**Null Object Pattern**により、メトリクスが不要な場合でもコードの変更は不要：

1. **デフォルト実装**: すべてのメソッドが何もしない（no-op）
2. **ゼロコスト**: コンパイラ最適化により実行時オーバーヘッドなし
3. **テスト容易性**: メトリクスなしでテストする場合でも自然に記述可能

**実装例**:
```swift
public struct NullMetricsRecorder: MetricsRecorder {
    public func recordSave(recordType: String, duration: UInt64) {
        // 何もしない - コンパイラ最適化で消える
    }
    // ... 他のメソッドも同様
}
```

### テスト方法

#### 1. NullMetricsRecorderのテスト

```swift
@Test("NullMetricsRecorder does not crash")
func testNullMetricsRecorder() {
    let recorder = NullMetricsRecorder()

    // すべてのメソッドが安全に呼び出せることを確認
    recorder.recordSave(recordType: "User", duration: 1000)
    recorder.recordFetch(recordType: "User", duration: 500)
    recorder.recordDelete(recordType: "User", duration: 300)
    recorder.recordError(operation: "save", recordType: "User", errorType: "TestError")

    // クラッシュしないことが成功
}
```

#### 2. モックMetricsRecorderでのテスト

```swift
final class MockMetricsRecorder: MetricsRecorder {
    var savedRecordTypes: [String] = []
    var errorCounts: [String: Int] = [:]

    func recordSave(recordType: String, duration: UInt64) {
        savedRecordTypes.append(recordType)
    }

    func recordError(operation: String, recordType: String, errorType: String) {
        let key = "\(operation):\(recordType)"
        errorCounts[key, default: 0] += 1
    }

    // ... 他のメソッド実装
}

@Test("RecordStore records metrics correctly")
func testRecordStoreMetrics() async throws {
    let mockRecorder = MockMetricsRecorder()
    let store = RecordStore(
        database: db,
        subspace: subspace,
        metaData: metaData,
        statisticsManager: statsManager,
        metricsRecorder: mockRecorder
    )

    try await store.save(user)

    #expect(mockRecorder.savedRecordTypes.contains("User"))
}
```

#### 3. 実際のメトリクス収集のテスト

```swift
@Test("SwiftMetricsRecorder integrates with swift-metrics")
func testSwiftMetricsRecorder() throws {
    // アプリケーション側で初期化（テスト用）
    MetricsBootstrap.bootstrap()

    let recorder = SwiftMetricsRecorder(component: "test")
    recorder.recordSave(recordType: "User", duration: 1_000_000_000)

    // Prometheusフォーマットでエクスポート
    let output = try MetricsBootstrap.prometheusMetrics()

    #expect(output.contains("fdb_record_save_total"))
    #expect(output.contains("record_type=\"User\""))
}
```

---

### Phase 2: Prometheus統合（1週間）

> **重要**: このフェーズで実装する内容は**すべてアプリケーション側の責務**です。
> RecordLayerコア（`Sources/FDBRecordLayer/`）は`MetricsRecorder`プロトコルにのみ依存し、
> Prometheusや`swift-metrics`といった具体的なフレームワークには依存しません。

#### 2.1 アプリケーション側のメトリクス初期化

**新規ファイル**: `Examples/MetricsBootstrap.swift`

> **注**: このファイルは`Examples/`ディレクトリに配置し、アプリケーション側で利用します。
> RecordLayerコアには含めません。

```swift
import Metrics
import SwiftPrometheus
import Foundation

/// Metrics system bootstrap for Prometheus integration (Application-side utility)
///
/// **使用方法**:
/// ```swift
/// // アプリケーション起動時（main.swift等）
/// MetricsBootstrap.bootstrap()
///
/// // RecordStore作成時にSwiftMetricsRecorderを注入
/// let recorder = SwiftMetricsRecorder()
/// let store = RecordStore(
///     database: db,
///     subspace: subspace,
///     metaData: metaData,
///     statisticsManager: statsManager,
///     metricsRecorder: recorder  // ← アプリ側で注入
/// )
/// ```
public enum MetricsBootstrap {
    private static var isBootstrapped = false

    /// Bootstrap metrics system with Prometheus backend
    ///
    /// **重要**: この関数はアプリケーション起動時に1回だけ呼び出します。
    /// RecordLayerコアからは呼び出しません。
    ///
    /// **Example**:
    /// ```swift
    /// // In main.swift or application initialization
    /// MetricsBootstrap.bootstrap()
    /// ```
    public static func bootstrap() {
        guard !isBootstrapped else { return }

        let client = PrometheusClient()
        MetricsSystem.bootstrap(client)

        isBootstrapped = true
    }

    /// Get Prometheus client for HTTP endpoint
    ///
    /// Use this to expose metrics via HTTP endpoint.
    ///
    /// **Example with Vapor**:
    /// ```swift
    /// app.get("metrics") { req in
    ///     let metrics = try MetricsBootstrap.prometheusMetrics()
    ///     return metrics
    /// }
    /// ```
    public static func prometheusMetrics() throws -> String {
        guard let factory = MetricsSystem.factory as? PrometheusClient else {
            throw MetricsError.notBootstrapped
        }

        return try factory.collect()
    }

    public enum MetricsError: Error {
        case notBootstrapped
    }
}
```

#### 2.2 HTTPエンドポイントの実装例

**新規ファイル**: `Examples/MetricsServer.swift`

```swift
import Vapor
import FDBRecordLayer

/// Example HTTP server for exposing Prometheus metrics
///
/// Run this to start a metrics server on port 9090:
/// ```
/// swift run MetricsServer
/// ```
@main
struct MetricsServer {
    static func main() async throws {
        // Bootstrap metrics
        MetricsBootstrap.bootstrap()

        // Create Vapor app
        let app = Application(.development)
        defer { app.shutdown() }

        // Metrics endpoint
        app.get("metrics") { req in
            let metrics = try MetricsBootstrap.prometheusMetrics()
            return metrics
        }

        // Health check endpoint
        app.get("health") { req in
            return ["status": "healthy"]
        }

        try app.run()
    }
}
```

#### 2.3 Prometheus設定例

**新規ファイル**: `Examples/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'fdb-record-layer'
    static_configs:
      - targets: ['localhost:9090']
    metrics_path: '/metrics'
```

#### 2.4 互換性検証テスト

**新規ファイル**: `Tests/FDBRecordLayerTests/Monitoring/PrometheusIntegrationTests.swift`

> **注**: これらのテストは、アプリケーション側のPrometheus統合が正しく動作することを検証します。
> RecordLayerコア自体はPrometheusに依存しないため、これらは統合テストとして扱います。

```swift
import Testing
import Metrics
import SwiftPrometheus
@testable import FDBRecordLayer

@Suite("Prometheus Integration Tests")
struct PrometheusIntegrationTests {

    @Test("Counter metrics are exported correctly")
    func testCounterExport() throws {
        // アプリケーション側の初期化をシミュレート
        MetricsBootstrap.bootstrap()

        let counter = Counter(
            label: "test_counter_total",
            dimensions: [("component", "test")]
        )
        counter.increment(by: 42)

        let output = try MetricsBootstrap.prometheusMetrics()

        #expect(output.contains("test_counter_total"))
        #expect(output.contains("component=\"test\""))
        #expect(output.contains("42"))
    }

    @Test("Timer metrics are exported correctly")
    func testTimerExport() throws {
        MetricsBootstrap.bootstrap()

        let timer = Timer(
            label: "test_timer_duration_seconds",
            dimensions: [("component", "test")]
        )
        timer.recordNanoseconds(1_000_000_000)  // 1 second

        let output = try MetricsBootstrap.prometheusMetrics()

        #expect(output.contains("test_timer_duration_seconds"))
        #expect(output.contains("component=\"test\""))
    }

    @Test("Gauge metrics are exported correctly")
    func testGaugeExport() throws {
        MetricsBootstrap.bootstrap()

        let gauge = Gauge(
            label: "test_gauge_ratio",
            dimensions: [("component", "test")]
        )
        gauge.record(0.75)

        let output = try MetricsBootstrap.prometheusMetrics()

        #expect(output.contains("test_gauge_ratio"))
        #expect(output.contains("component=\"test\""))
        #expect(output.contains("0.75"))
    }

    @Test("Dimensions are mapped to Prometheus labels")
    func testDimensionsMapping() throws {
        MetricsBootstrap.bootstrap()

        let counter = Counter(
            label: "test_dimensions_total",
            dimensions: [
                ("service", "record_layer"),
                ("component", "record_store"),
                ("operation", "save")
            ]
        )
        counter.increment()

        let output = try MetricsBootstrap.prometheusMetrics()

        #expect(output.contains("service=\"record_layer\""))
        #expect(output.contains("component=\"record_store\""))
        #expect(output.contains("operation=\"save\""))
    }
}
```

### Phase 3: メトリクス標準化（1週間）

> **注**: このフェーズは主にドキュメント整備です。
> RecordLayerコアは`MetricsRecorder`プロトコルにのみ依存し、
> メトリクスの命名や実装詳細は`SwiftMetricsRecorder`内で完結します。

#### 3.1 メトリクス命名規則

**新規ファイル**: `docs/monitoring/METRICS_NAMING_CONVENTIONS.md`

```markdown
# メトリクス命名規則

すべてのメトリクスは以下の規則に従う：

## 命名パターン

### Counter
- パターン: `fdb_{component}_{metric_name}_total`
- 例: `fdb_record_save_total`, `fdb_query_plan_total`

### Timer
- パターン: `fdb_{component}_{metric_name}_duration_seconds`
- 例: `fdb_record_save_duration_seconds`, `fdb_query_execution_duration_seconds`

### Gauge
- パターン: `fdb_{component}_{metric_name}_{unit}`
- 例: `fdb_indexer_progress_ratio`, `fdb_cache_size_bytes`

## 必須ラベル

すべてのメトリクスは以下のラベルを含む：

- `service`: "fdb_record_layer"（固定）
- `component`: コンポーネント名（record_store, query_planner, indexer, scrubberなど）

## オプショナルラベル

コンポーネントごとに追加：

- `record_type`: レコード型名
- `index_name`: インデックス名
- `operation`: 操作名（save, load, deleteなど）
- `error_type`: エラー型
```

#### 3.2 メトリクスドキュメント

**新規ファイル**: `docs/monitoring/METRICS_REFERENCE.md`

```markdown
# メトリクスリファレンス

## RecordStore Metrics

### fdb_record_save_total
- **Type**: Counter
- **Description**: 保存操作の総数
- **Labels**: component, record_type, operation

### fdb_record_save_duration_seconds
- **Type**: Timer
- **Description**: 保存操作のレイテンシー
- **Labels**: component, record_type

...（全メトリクスの詳細ドキュメント）
```

### Phase 4: ダッシュボード構築（1週間）

#### 4.1 Grafanaダッシュボード

**新規ファイル**: `Examples/grafana-dashboard.json`

```json
{
  "dashboard": {
    "title": "FDB Record Layer - Overview",
    "panels": [
      {
        "title": "CRUD Operations Rate",
        "targets": [
          {
            "expr": "rate(fdb_record_save_total[5m])",
            "legendFormat": "Save - {{record_type}}"
          },
          {
            "expr": "rate(fdb_record_load_total[5m])",
            "legendFormat": "Load - {{record_type}}"
          }
        ]
      },
      {
        "title": "Query Performance",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(fdb_query_execution_duration_seconds_bucket[5m]))",
            "legendFormat": "p95 latency"
          }
        ]
      },
      {
        "title": "Index Operations",
        "targets": [
          {
            "expr": "rate(fdb_indexer_records_processed_total[5m])",
            "legendFormat": "Records/sec - {{index_name}}"
          }
        ]
      }
    ]
  }
}
```

---

## 実装計画

### タイムライン（Protocol Injectionベース）

| Phase | タスク | 期間 | 優先度 |
|-------|--------|------|--------|
| **Phase 1** | Protocol定義と基本実装 | 1週間 | 🔴 最優先 |
| | 1.1 MetricsRecorderプロトコル定義 | 1日 | 🔴 |
| | 1.2 NullMetricsRecorder実装 | 0.5日 | 🔴 |
| | 1.3 SwiftMetricsRecorder実装 | 2日 | 🔴 |
| | 1.4 RecordStoreへの統合 | 1日 | 🔴 |
| | 1.5 QueryPlannerへの統合 | 0.5日 | 🟡 |
| | 1.6 OnlineIndexerへの統合 | 1日 | 🟡 |
| **Phase 2** | Prometheus統合とHTTPエンドポイント | 1週間 | 🔴 高 |
| | 2.1 MetricsBootstrap実装 | 1日 | 🔴 |
| | 2.2 HTTPエンドポイント（Vapor例） | 2日 | 🔴 |
| | 2.3 Prometheus設定と統合テスト | 2日 | 🔴 |
| **Phase 3** | メトリクス標準化とドキュメント | 1週間 | 🟡 中 |
| | 3.1 メトリクス命名規則文書化 | 2日 | 🟡 |
| | 3.2 メトリクスリファレンス作成 | 3日 | 🟡 |
| **Phase 4** | Grafanaダッシュボード構築 | 1週間 | 🟡 中 |
| | 4.1 ダッシュボードJSON作成 | 2日 | 🟡 |
| | 4.2 アラートルール設定 | 2日 | 🟡 |
| | 4.3 ドキュメント整備 | 1日 | 🟡 |

**合計**: 4週間

**Protocol Injectionの利点**:
- コンポーネント本体の変更が最小限（1プロパティ追加のみ）
- 既存コードへの影響を最小化しつつ、メトリクス機能を追加可能

### リソース

- 開発者: 1名（フルタイム）
- レビュアー: 1名（パートタイム）

### 実装の優先順位

1. **🔴 最優先**: MetricsRecorderプロトコルとRecordStore統合
   - RecordStoreは最も頻繁に使用されるコンポーネント
   - 基本的なCRUD操作のメトリクスが即座に取得可能

2. **🔴 高**: Prometheus統合
   - メトリクス収集だけでなく、可視化まで実現
   - 本番環境で即座に使える状態にする

3. **🟡 中**: QueryPlannerとOnlineIndexer統合
   - RecordStoreメトリクスだけでも運用可能
   - 段階的に追加可能

4. **🟡 中**: Grafanaダッシュボード
   - Prometheusで基本的な可視化は可能
   - ダッシュボードは運用フィードバックを得てから最適化

---

## 期待される効果

### 運用上のメリット

1. **問題の早期検出**
   - クエリのパフォーマンス劣化を即座に検出
   - インデックスのホットスポットを特定
   - トランザクション競合の頻度を監視

2. **キャパシティプランニング**
   - CRUD操作のスループットトレンド
   - ストレージ使用量の予測
   - スケーリングの適切なタイミング判断

3. **SLO/SLI管理**
   - クエリレイテンシーの99パーセンタイル監視
   - エラー率のトラッキング
   - 可用性の測定

### 技術的メリット

1. **標準化されたメトリクス**
   - 命名規則の統一
   - ラベル戦略の一貫性
   - 再利用可能なファクトリーパターン

2. **Prometheus統合**
   - 業界標準の監視スタック
   - Grafanaとのシームレスな統合
   - アラート設定の容易さ

3. **デバッグの効率化**
   - メトリクスベースのトラブルシューティング
   - パフォーマンスボトルネックの特定
   - 本番環境での可視性向上

---

## 次のアクション（Protocol Injectionベース）

### Phase 1: 即座に実施（1週間）

**基盤となるProtocol定義**:
1. [ ] `MetricsRecorder`プロトコル定義（Sources/FDBRecordLayer/Monitoring/MetricsRecorder.swift）
2. [ ] `NullMetricsRecorder`実装（同ファイル内）
3. [ ] `SwiftMetricsRecorder`実装（Sources/FDBRecordLayer/Monitoring/SwiftMetricsRecorder.swift）

**RecordStore統合**:
4. [ ] RecordStoreに`metricsRecorder`プロパティ追加
5. [ ] `save()`メソッドにメトリクス呼び出し追加
6. [ ] `fetch()`メソッドにメトリクス呼び出し追加
7. [ ] `delete()`メソッドにメトリクス呼び出し追加

**テスト**:
8. [ ] NullMetricsRecorderのユニットテスト
9. [ ] SwiftMetricsRecorderのユニットテスト
10. [ ] RecordStore統合テスト（メトリクスあり/なし）

### Phase 2: 短期（1-2週間）

**Prometheus統合（アプリケーション側）**:
11. [ ] `MetricsBootstrap.swift`実装（Examples/に配置）
12. [ ] Prometheus互換性検証テスト
13. [ ] HTTPエンドポイント実装例（Vapor、Examples/に配置）
14. [ ] Prometheus設定例（prometheus.yml、Examples/に配置）

**ドキュメント**:
15. [ ] 使用例ドキュメント（Examples/MetricsIntegrationExample.swift）
16. [ ] メトリクスリファレンス（docs/monitoring/METRICS_REFERENCE.md）

### Phase 3-4: 中期（2-3週間）

**追加統合**:
17. [ ] QueryPlannerへのメトリクス統合
18. [ ] OnlineIndexerへのメトリクス統合

**ダッシュボード**:
19. [ ] Grafanaダッシュボード作成（Examples/grafana-dashboard.json）
20. [ ] アラートルール定義

**標準化**:
21. [ ] メトリクス命名規則文書化（docs/monitoring/METRICS_NAMING_CONVENTIONS.md）
22. [ ] ベストプラクティスガイド作成

---

## 参考資料

- [swift-metrics Documentation](https://github.com/apple/swift-metrics)
- [SwiftPrometheus Documentation](https://github.com/MrLotU/SwiftPrometheus)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/naming/)
- [Grafana Dashboard Best Practices](https://grafana.com/docs/grafana/latest/best-practices/)

---

**作成者**: Claude Code
**最終更新**: 2025-01-06
**ステータス**: レビュー済み、実装待ち
