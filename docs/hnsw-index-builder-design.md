# HNSW Index Builder 設計書

**バージョン**: 1.2
**最終更新**: 2025-01-17
**ステータス**: Phase 1 完了 ✅

---

## 目次

1. [概要](#概要)
2. [Known Issues](#known-issues) ⚠️
3. [設計原則](#設計原則)
4. [アーキテクチャ](#アーキテクチャ)
5. [コンポーネント設計](#コンポーネント設計)
6. [実装仕様](#実装仕様)
7. [エラーハンドリング](#エラーハンドリング)
8. [実装チェックリスト](#実装チェックリスト)

---

## 概要

### 目的

HNSW インデックスの構築を手動で安全に実行できる機能を提供します。

**背景**:
- 本番の `RecordStore.save()` では軽量なフラットインデックスのみ維持
- 重い HNSW は必要なときだけ手動でビルド
- 開発/運用担当がコマンドまたは API を叩くだけで安全に HNSW を構築・再構築

**スコープ**:
- Phase 1: 基本機能（HNSWIndexBuilder、BuildOptions、状態管理）
- ~~Phase 2: CLI / 管理用 API~~（別設計）
- ~~Phase 3: 状態モニタリング~~（別設計）

---

## ✅ 解決済み課題（Phase 1実装時に発見・修正）

> **実装レビュー結果**（2025-01-17）
>
> Phase 1 実装完了後のコードレビューで、設計と実装の間に**4つの論理的矛盾**を発見し、すべて修正しました。

### ✅ Issue 1: IndexState管理の二重実行（解決済み）

**問題**:
- `HNSWIndexBuilder.build()` が `indexStateManager.enable()` / `makeReadable()` を呼び出していた
- `OnlineIndexer.buildHNSWIndex()` も `indexStateManager.enable()` / `makeReadable()` を呼び出す
- 状態遷移が2箇所で重複実行される

**影響**:
- 設計原則「責務の分離」に違反
- デバッグが困難（どちらで状態が変わったか不明）
- 冗長なトランザクション

**✅ 修正完了**（Java版Record Layerと同じパターン）:
```swift
// ✅ 修正後: HNSWIndexBuilderが状態遷移を完全に管理
HNSWIndexBuilder.build() {
    try await transitionToWriteOnly()         // ← Service Layerの責務
    try await indexer.buildHNSWIndex()        // ← Execution Layerは実行のみ
    try await transitionToReadable()          // ← Service Layerの責務
}

// ✅ 修正後: OnlineIndexerは状態遷移しない
OnlineIndexer.buildHNSWIndex() {
    // ✅ 削除完了: enable/makeReadableは呼び出さない
    try await assignLevelsToAllNodes()
    try await buildHNSWGraphLevelByLevel()
}
```

### ✅ Issue 2: createCheckpoint()にTODOが残存（解決済み）

**問題**:
```swift
// ❌ 現在の実装
private func createCheckpoint() async throws -> RangeCheckpoint {
    // TODO: Get actual last processed key from OnlineIndexer
    let lastKey = FDB.Bytes()  // Placeholder

    // TODO: Get actual processed count
    let processedRecords = 0  // Placeholder
}
```

**影響**:
- チェックポイントが常に空（再開機能が動作しない）
- ユーザー要求「TODOなしの完全実装」に違反

**✅ 修正完了**:
```swift
// ✅ 修正後: OnlineIndexerから実際の情報を取得
private func createCheckpoint() async throws -> RangeCheckpoint {
    guard let indexer = indexerLock.withLock({ $0 }) else {
        throw RecordLayerError.internalError("Cannot create checkpoint: indexer not available")
    }

    let (lastKey, processedCount, _) = try await indexer.getCurrentCheckpoint()

    return RangeCheckpoint(
        lastCompletedKey: lastKey,
        phase: phase,
        processedRecords: processedCount,
        timestamp: Date()
    )
}
```

### ✅ Issue 3: buildFinalStatistics()のmaxLevelがnil（解決済み）

**問題**:
```swift
// ❌ 現在の実装
private func buildFinalStatistics() async throws -> BuildStatistics {
    // ...
    let maxLevel: Int? = nil  // Placeholder
    return BuildStatistics(..., maxLevel: maxLevel)
}
```

**影響**:
- 統計情報が不完全（maxLevelは重要な指標）
- ユーザーがHNSWグラフの構造を把握できない

**✅ 修正完了**:
```swift
// ✅ 修正後: OnlineIndexerから実際のmaxLevelを取得
private func buildFinalStatistics() async throws -> BuildStatistics {
    // Get max level from HNSW index via indexer
    let maxLevel: Int?
    if let indexer = indexerLock.withLock({ $0 }) {
        let (_, _, level) = try await indexer.getCurrentCheckpoint()
        maxLevel = level
    } else {
        maxLevel = nil
    }

    return BuildStatistics(..., maxLevel: maxLevel)
}
```

### ✅ Issue 4: OnlineIndexerがローカル変数（解決済み）

**問題**:
```swift
// ❌ 現在の実装
public func build(options: HNSWBuildOptions = .init()) async throws -> BuildStatistics {
    let indexer = OnlineIndexer(...)  // ← ローカル変数
    try await indexer.buildHNSWIndex()
    // createCheckpoint()やbuildFinalStatistics()からアクセスできない！
}
```

**影響**:
- `createCheckpoint()` が OnlineIndexer の情報にアクセスできない
- `buildFinalStatistics()` が maxLevel を取得できない
- Issue 2 と Issue 3 の根本原因

**✅ 修正完了**:
```swift
// ✅ 修正後: OnlineIndexerをインスタンス変数として保持
public final class HNSWIndexBuilder<Record: Recordable>: Sendable {
    private let indexerLock: Mutex<OnlineIndexer<Record>?>

    public func build(options: HNSWBuildOptions = .init()) async throws -> BuildStatistics {
        let indexer = OnlineIndexer(...)
        indexerLock.withLock { $0 = indexer }

        defer {
            indexerLock.withLock { $0 = nil }
        }

        try await indexer.buildHNSWIndex()
        // ✅ createCheckpoint()やbuildFinalStatistics()からアクセス可能
    }
}
```

### ✅ 修正完了ステータス

| Issue | ステータス | 完了日 |
|-------|----------|-------|
| Issue 1: IndexState二重管理 | ✅ 完了 | 2025-01-17 |
| Issue 2: createCheckpoint()のTODO | ✅ 完了 | 2025-01-17 |
| Issue 3: maxLevelがnil | ✅ 完了 | 2025-01-17 |
| Issue 4: OnlineIndexerローカル変数 | ✅ 完了 | 2025-01-17 |

**実装の詳細**: `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayer/Index/HNSWIndexBuilder.swift`

---

## 設計原則

### 1. 既存アーキテクチャとの一貫性

```
既存コンポーネントの活用:
├─ OnlineIndexer.buildHNSWIndex()  ← ラップして使用
├─ IndexStateManager               ← 状態遷移管理
├─ RangeSet                        ← 進捗管理・再開機能
└─ Schema.getVectorStrategy()      ← 戦略設定の読み取り
```

### 2. 責務の分離

| レイヤー | 責務 | 実装コンポーネント |
|---------|------|------------------|
| **サービス層** | ビルド調整、**IndexState遷移**、エラーハンドリング | `HNSWIndexBuilder` |
| **実行層** | HNSW グラフ構築、バッチ処理（**状態遷移なし**） | `OnlineIndexer` |
| **永続化層** | Index state、進捗記録 | `IndexStateManager`, `RangeSet` |

**重要**:
- `OnlineIndexer` は**状態遷移を行わない** - `enable()` / `makeReadable()` は呼び出し側の責任
- `HNSWIndexBuilder` が**完全に状態を制御** - Java版Record Layerと同じパターン
- これにより、責務が明確になり、デバッグが容易になる

### 3. 安全性と再開可能性

- **冪等性**: 同じビルドを複数回実行しても安全
- **中断からの再開**: `RangeSet` による checkpoint 管理
- **状態の一貫性**: トランザクション境界での状態遷移

### 4. パフォーマンス最適化

- **バッチ処理**: トランザクション制限（5秒、10MB）を遵守
- **スロットル**: CPU/メモリ負荷の制御
- **並行性**: `final class + Mutex` パターンで高スループット

---

## アーキテクチャ

### システム構成

```
┌─────────────────────────────────────────────────────────┐
│                  HNSWIndexBuilder                       │
│  (サービス層: 状態管理、エラーハンドリング)                │
│                                                          │
│  ┌────────────────────────────────────────────┐        │
│  │ BuildState (Mutex保護)                     │        │
│  │  - notStarted                              │        │
│  │  - running(phase, progress)                │        │
│  │  - paused(checkpoint)                      │        │
│  │  - completed(stats)                        │        │
│  │  - failed(error, checkpoint)               │        │
│  └────────────────────────────────────────────┘        │
└───────────────────┬─────────────────────────────────────┘
                    │ build(options)
                    ▼
┌─────────────────────────────────────────────────────────┐
│                  OnlineIndexer                          │
│  (実行層: HNSW グラフ構築、バッチ処理)                    │
│                                                          │
│  ┌────────────────────────────────────────────┐        │
│  │ buildHNSWIndex(                            │        │
│  │   clearFirst,                              │        │
│  │   batchSize,                               │        │
│  │   throttleDelayMs,                         │        │
│  │   progressCallback                         │        │
│  │ )                                          │        │
│  └────────────────────────────────────────────┘        │
└───────────────────┬─────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
┌──────────────────┐   ┌──────────────────┐
│ IndexStateManager│   │    RangeSet      │
│ (状態遷移)        │   │ (進捗管理)        │
│                  │   │                  │
│ - disable()      │   │ - insertRange()  │
│ - enable()       │   │ - contains()     │
│ - makeReadable() │   │ - missingRanges()│
└──────────────────┘   └──────────────────┘
```

### フロー図

```
[開始]
   │
   ▼
[状態チェック: notStarted?]
   │ Yes
   ▼
[Index state → writeOnly]
   │
   ▼
[OnlineIndexer 作成]
   │
   ▼
[Phase 1: Level Assignment]
   │ progressCallback(levelAssignment, 0.0)
   ├─ assignLevelsToAllNodes()
   │ progressCallback(levelAssignment, 1.0)
   ▼
[Phase 2: Graph Construction]
   │ for level in maxLevel...0
   ├─ progressCallback(graphConstruction(level), progress)
   ├─ buildHNSWGraphAtLevel(level)
   └─ RangeSet.insertRange() ← checkpoint
   ▼
[成功?]
   │ Yes              │ No
   ▼                  ▼
[Index state      [checkpoint保存]
 → readable]          │
   │                  ▼
   ▼              [状態 → failed]
[状態 → completed]    │
   │                  ▼
   ▼              [エラーをスロー]
[BuildStatistics]
   │
   ▼
[終了]
```

---

## コンポーネント設計

### 1. HNSWBuildOptions

ビルド実行時の設定をまとめた構造体。

```swift
/// HNSW インデックス構築のオプション
///
/// **使用例**:
/// ```swift
/// let options = HNSWBuildOptions(
///     batchSize: 500,
///     throttleDelayMs: 20,
///     clearFirst: true
/// )
/// let stats = try await builder.build(options: options)
/// ```
public struct HNSWBuildOptions: Sendable, Codable {
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 基本設定
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// バッチサイズ: 1回のトランザクションで処理するレコード数
    ///
    /// **推奨値**:
    /// - 小規模データ（< 10,000 records）: 1000
    /// - 中規模データ（10,000 - 100,000）: 500
    /// - 大規模データ（> 100,000）: 100-200
    ///
    /// **注意**: トランザクション制限（5秒、10MB）を超えないよう調整
    public var batchSize: Int = 1000

    /// スロットル遅延（ミリ秒）: バッチ間の待機時間
    ///
    /// **推奨値**:
    /// - 低負荷環境: 10ms
    /// - 中負荷環境: 20-50ms
    /// - 高負荷環境: 100ms+
    ///
    /// **目的**: CPU/メモリ負荷の制御、他の処理への影響軽減
    public var throttleDelayMs: UInt64 = 10

    /// 既存インデックスをクリアしてから構築
    ///
    /// **用途**:
    /// - `true`: 完全な再構築（データ破損、構造変更時）
    /// - `false`: 中断からの再開（デフォルト）
    public var clearFirst: Bool = false

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 高度な設定（将来拡張用）
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Dry run モード: 実際のビルドを行わず、推定情報のみ返す
    ///
    /// **用途**: ビルド前の影響範囲確認、リソース見積もり
    public var dryRun: Bool = false

    /// 並列度: 複数バッチの並列処理（実験的機能）
    ///
    /// **注意**: 現在は未実装、将来のパフォーマンス最適化用
    public var concurrency: Int = 1

    /// タイムアウト（秒）: ビルド実行の上限時間
    ///
    /// **デフォルト**: 0（無制限）
    /// **推奨**: 大規模データでは適切な上限を設定
    public var timeoutSeconds: Int = 0

    /// 通知エンドポイント: 完了時の通知先（Slack webhook 等）
    ///
    /// **形式**: URL文字列（例: "https://hooks.slack.com/..."）
    public var notificationEndpoint: String? = nil

    /// リソース制限: CPU/メモリ使用率の上限（0.0-1.0）
    ///
    /// **デフォルト**: 0.8（80%）
    /// **用途**: 本番環境での他プロセスへの影響軽減
    public var resourceLimit: Double = 0.8

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Initializer
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    public init(
        batchSize: Int = 1000,
        throttleDelayMs: UInt64 = 10,
        clearFirst: Bool = false,
        dryRun: Bool = false,
        concurrency: Int = 1,
        timeoutSeconds: Int = 0,
        notificationEndpoint: String? = nil,
        resourceLimit: Double = 0.8
    ) {
        self.batchSize = batchSize
        self.throttleDelayMs = throttleDelayMs
        self.clearFirst = clearFirst
        self.dryRun = dryRun
        self.concurrency = concurrency
        self.timeoutSeconds = timeoutSeconds
        self.notificationEndpoint = notificationEndpoint
        self.resourceLimit = resourceLimit
    }
}
```

### 2. BuildState と BuildPhase

ビルド実行の状態を表現する enum。

```swift
/// HNSW インデックス構築の実行状態
///
/// **状態遷移**:
/// ```
/// notStarted → running → completed
///                 ↓
///              paused
///                 ↓
///              failed
/// ```
public enum BuildState: Sendable {
    /// 未開始
    case notStarted

    /// 実行中
    ///
    /// - Parameters:
    ///   - phase: 現在のフェーズ（Level Assignment / Graph Construction）
    ///   - progress: 進捗率（0.0 - 1.0）
    case running(phase: BuildPhase, progress: Double)

    /// 一時停止（中断）
    ///
    /// - Parameter checkpoint: 再開用のチェックポイント
    case paused(checkpoint: RangeCheckpoint)

    /// 完了
    ///
    /// - Parameter stats: ビルド統計情報
    case completed(stats: BuildStatistics)

    /// 失敗
    ///
    /// - Parameters:
    ///   - error: エラー情報
    ///   - checkpoint: 再開用のチェックポイント
    case failed(error: Error, checkpoint: RangeCheckpoint)
}

/// HNSW インデックス構築のフェーズ
///
/// **実行順序**:
/// 1. Level Assignment: 各ノードのレベルを割り当て（軽量、O(n)）
/// 2. Graph Construction: レベルごとにグラフを構築（重量、O(n log n)）
public enum BuildPhase: Sendable {
    /// Phase 1: レベル割当
    ///
    /// **処理内容**: 各レコードに HNSW レベルを確率的に割り当て
    /// **計算量**: O(n)
    /// **推定時間**: ~0.1ms/record
    case levelAssignment

    /// Phase 2: グラフ構築
    ///
    /// **処理内容**: レベルごとに近傍グラフを構築
    /// **計算量**: O(n log n)（M=16, efConstruction=200）
    /// **推定時間**: ~1ms/record
    ///
    /// - Parameters:
    ///   - level: 現在のレベル（0 = 最下層）
    ///   - totalLevels: 総レベル数
    case graphConstruction(level: Int, totalLevels: Int)
}
```

### 3. RangeCheckpoint

中断・再開用のチェックポイント情報。

```swift
/// HNSW インデックス構築の中断・再開用チェックポイント
///
/// **用途**:
/// - ビルド中断時に現在位置を保存
/// - 再開時に中断位置から継続
///
/// **実装**: RangeSet に基づく進捗管理
public struct RangeCheckpoint: Sendable, Codable {
    /// 最後に完了したキー範囲の終端
    ///
    /// **形式**: FDB.Bytes（Tuple.pack() の結果）
    public let lastCompletedKey: FDB.Bytes

    /// 現在のフェーズ
    public let phase: BuildPhase

    /// 処理済みレコード数
    public let processedRecords: Int

    /// チェックポイント作成時刻
    public let timestamp: Date

    public init(
        lastCompletedKey: FDB.Bytes,
        phase: BuildPhase,
        processedRecords: Int,
        timestamp: Date = Date()
    ) {
        self.lastCompletedKey = lastCompletedKey
        self.phase = phase
        self.processedRecords = processedRecords
        self.timestamp = timestamp
    }
}
```

### 4. BuildStatistics

ビルド完了時の統計情報。

```swift
/// HNSW インデックス構築の統計情報
///
/// **用途**:
/// - ビルド完了時のレポート
/// - パフォーマンス分析
/// - 次回ビルドの見積もり
public struct BuildStatistics: Sendable, Codable {
    /// 総レコード数
    public let totalRecords: Int

    /// 処理済みレコード数
    public let processedRecords: Int

    /// 経過時間（秒）
    public let elapsedTime: TimeInterval

    /// 推定残り時間（秒）
    ///
    /// **注意**: Dry run モードでのみ設定される
    public let estimatedTimeRemaining: TimeInterval?

    /// メモリ使用量（バイト）
    public let memoryUsage: UInt64

    /// 最大レベル数
    public let maxLevel: Int?

    /// 平均処理速度（records/sec）
    public var throughput: Double {
        elapsedTime > 0 ? Double(processedRecords) / elapsedTime : 0
    }

    public init(
        totalRecords: Int,
        processedRecords: Int,
        elapsedTime: TimeInterval,
        estimatedTimeRemaining: TimeInterval? = nil,
        memoryUsage: UInt64,
        maxLevel: Int? = nil
    ) {
        self.totalRecords = totalRecords
        self.processedRecords = processedRecords
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.memoryUsage = memoryUsage
        self.maxLevel = maxLevel
    }
}
```

### 5. HNSWIndexBuilder

HNSW インデックス構築のサービス層実装。

```swift
/// HNSW インデックス構築のサービス層
///
/// `OnlineIndexer.buildHNSWIndex()` をラップし、以下を提供:
/// - シンプルな API
/// - 状態管理（running, paused, completed, failed）
/// - エラーハンドリングと再開機能
///
/// **使用例**:
/// ```swift
/// let builder = HNSWIndexBuilder(
///     store: productStore,
///     indexName: "product_embedding",
///     database: database,
///     schema: schema
/// )
///
/// let options = HNSWBuildOptions(
///     batchSize: 500,
///     throttleDelayMs: 20
/// )
///
/// let stats = try await builder.build(options: options)
/// print("Completed: \(stats.processedRecords) records in \(stats.elapsedTime)s")
/// ```
///
/// **スレッドセーフティ**: `final class + Mutex` パターンで並行アクセスを保護
public final class HNSWIndexBuilder<Record: Recordable>: Sendable {
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Properties
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private let store: RecordStore<Record>
    private let indexName: String
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let schema: Schema

    /// 状態管理（Mutex で保護）
    private let stateLock: Mutex<BuildState>

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Initialization
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// HNSWIndexBuilder を初期化
    ///
    /// - Parameters:
    ///   - store: 対象の RecordStore
    ///   - indexName: 構築する HNSW インデックス名
    ///   - database: FoundationDB データベース
    ///   - schema: スキーマ定義
    public init(
        store: RecordStore<Record>,
        indexName: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) {
        self.store = store
        self.indexName = indexName
        self.database = database
        self.schema = schema
        self.stateLock = Mutex(.notStarted)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Public API
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// HNSW インデックスをビルド
    ///
    /// **実行フロー**:
    /// 1. Dry run チェック（options.dryRun = true の場合）
    /// 2. 状態確認（既に running の場合はエラー）
    /// 3. Index state を writeOnly に設定
    /// 4. OnlineIndexer でビルド実行
    /// 5. 成功時: Index state を readable に戻す
    /// 6. 失敗時: checkpoint 保存
    ///
    /// **エラー**:
    /// - `RecordLayerError.internalError("Build already in progress")`: 既に実行中
    /// - `RecordLayerError.indexNotFound`: インデックスが見つからない
    /// - その他: OnlineIndexer からのエラー
    ///
    /// - Parameter options: ビルドオプション
    /// - Returns: ビルド統計情報
    /// - Throws: ビルドエラー
    public func build(options: HNSWBuildOptions = .init()) async throws -> BuildStatistics {
        // 1. Dry run チェック
        if options.dryRun {
            return try await estimateBuild(options: options)
        }

        // 2. 状態をチェック（既に running の場合はエラー）
        try stateLock.withLock { state in
            if case .running = state {
                throw RecordLayerError.internalError("Build already in progress")
            }
        }

        // 3. Index state を writeOnly に設定
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: store.indexSubspace
        )
        try await indexStateManager.setState(index: indexName, state: .writeOnly)

        // 4. OnlineIndexer を作成
        let indexer = OnlineIndexer<Record>(
            database: database,
            schema: schema,
            recordStore: store,
            indexName: indexName
        )

        // 5. 進捗コールバック設定
        let progressCallback: (BuildPhase, Double) -> Void = { [weak self] phase, progress in
            self?.stateLock.withLock { state in
                state = .running(phase: phase, progress: progress)
            }
        }

        // 6. ビルド実行
        let startTime = Date()
        do {
            try await indexer.buildHNSWIndex(
                clearFirst: options.clearFirst,
                batchSize: options.batchSize,
                throttleDelayMs: options.throttleDelayMs,
                progressCallback: progressCallback
            )

            // 7. 成功: readable に戻す
            try await indexStateManager.setState(index: indexName, state: .readable)

            let stats = BuildStatistics(
                totalRecords: try await countRecords(),
                processedRecords: try await countRecords(),
                elapsedTime: Date().timeIntervalSince(startTime),
                estimatedTimeRemaining: nil,
                memoryUsage: getCurrentMemoryUsage(),
                maxLevel: try await getMaxLevel(indexer: indexer)
            )

            stateLock.withLock { state in
                state = .completed(stats: stats)
            }

            return stats

        } catch {
            // 8. 失敗: checkpoint 保存
            let checkpoint = try await indexer.getCurrentCheckpoint()
            stateLock.withLock { state in
                state = .failed(error: error, checkpoint: checkpoint)
            }
            throw error
        }
    }

    /// 現在の状態を取得
    ///
    /// **用途**: 外部からビルド進捗を監視
    ///
    /// - Returns: 現在のビルド状態
    public func getState() -> BuildState {
        return stateLock.withLock { $0 }
    }

    /// ビルドをキャンセル（将来実装）
    ///
    /// **注意**: 現在は未実装、OnlineIndexer にキャンセル機能が必要
    ///
    /// - Throws: キャンセルエラー
    public func cancel() async throws {
        // TODO: OnlineIndexer にキャンセル機能を追加
        throw RecordLayerError.internalError("Cancel not implemented yet")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Private Helpers
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// ビルド推定（Dry run）
    private func estimateBuild(options: HNSWBuildOptions) async throws -> BuildStatistics {
        let recordCount = try await countRecords()
        let estimatedTime = estimateBuildTime(recordCount: recordCount, options: options)

        return BuildStatistics(
            totalRecords: recordCount,
            processedRecords: 0,
            elapsedTime: 0,
            estimatedTimeRemaining: estimatedTime,
            memoryUsage: estimateMemoryUsage(recordCount: recordCount)
        )
    }

    /// レコード数をカウント
    private func countRecords() async throws -> Int {
        var count = 0
        for try await _ in store.scan() {
            count += 1
        }
        return count
    }

    /// ビルド時間を推定
    ///
    /// **計算式**:
    /// - Phase 1 (Level Assignment): ~0.1ms/record
    /// - Phase 2 (Graph Construction): ~1ms/record (M=16, efConstruction=200)
    /// - Throttle: (recordCount / batchSize) * throttleDelayMs
    private func estimateBuildTime(recordCount: Int, options: HNSWBuildOptions) -> TimeInterval {
        // Phase 1: レベル割当
        let phase1Time = Double(recordCount) * 0.0001

        // Phase 2: グラフ構築
        let phase2Time = Double(recordCount) * 0.001

        // スロットル
        let throttleTime = Double(recordCount / options.batchSize) * Double(options.throttleDelayMs) / 1000.0

        return phase1Time + phase2Time + throttleTime
    }

    /// メモリ使用量を推定
    ///
    /// **計算式**: ~15 bytes/vector (M=16, 384 dims)
    private func estimateMemoryUsage(recordCount: Int) -> UInt64 {
        return UInt64(recordCount) * 15
    }

    /// 現在のメモリ使用量を取得
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// 最大レベルを取得
    private func getMaxLevel(indexer: OnlineIndexer<Record>) async throws -> Int? {
        // OnlineIndexer から最大レベルを取得（実装が必要）
        return nil
    }
}
```

---

## 実装仕様

### OnlineIndexer への拡張

既存の `OnlineIndexer.buildHNSWIndex()` に進捗コールバックを追加します。

```swift
// OnlineIndexer.swift に追加

extension OnlineIndexer {
    /// HNSW インデックス構築（進捗コールバック付き）
    ///
    /// **拡張内容**:
    /// - 既存の buildHNSWIndex() に progressCallback パラメータを追加
    /// - Phase 1、Phase 2 の進捗を報告
    ///
    /// **後方互換性**: progressCallback はオプショナル、既存コードは影響なし
    ///
    /// - Parameters:
    ///   - clearFirst: 既存インデックスをクリアするか
    ///   - batchSize: バッチサイズ
    ///   - throttleDelayMs: スロットル遅延
    ///   - progressCallback: 進捗コールバック（オプション）
    /// - Throws: ビルドエラー
    public func buildHNSWIndex(
        clearFirst: Bool = false,
        batchSize: Int = 1000,
        throttleDelayMs: UInt64 = 10,
        progressCallback: ((BuildPhase, Double) -> Void)? = nil
    ) async throws {
        // Phase 1: Level assignment
        progressCallback?(.levelAssignment, 0.0)

        try await assignLevelsToAllNodes(
            batchSize: batchSize,
            throttleDelayMs: throttleDelayMs
        )

        progressCallback?(.levelAssignment, 1.0)

        // Phase 2: Graph construction
        let maxLevel = try await getMaxLevel(
            indexSubspace: indexSubspace,
            transaction: database.createTransaction()
        )

        for level in (0...maxLevel).reversed() {
            let progress = Double(maxLevel - level) / Double(maxLevel + 1)
            progressCallback?(.graphConstruction(level: level, totalLevels: maxLevel), progress)

            try await buildHNSWGraphAtLevel(
                level: level,
                batchSize: batchSize,
                throttleDelayMs: throttleDelayMs
            )
        }
    }

    /// 現在のチェックポイントを取得
    ///
    /// **実装**: RangeSet から最後の完了位置を取得
    ///
    /// - Returns: チェックポイント情報
    /// - Throws: チェックポイント取得エラー
    public func getCurrentCheckpoint() async throws -> RangeCheckpoint {
        let rangeSet = RangeSet(database: database, subspace: progressSubspace)

        // RangeSet から最後に完了したキー範囲を取得
        let transaction = try database.createTransaction()
        defer { transaction.cancel() }

        // 最後のエントリを取得
        let rangeKey = rangeSet.subspace.range()
        let sequence = transaction.getRange(
            beginSelector: .lastLessOrEqual(rangeKey.end),
            endSelector: .lastLessOrEqual(rangeKey.end),
            limit: 1,
            snapshot: true
        )

        var lastKey: FDB.Bytes = []
        for try await (key, _) in sequence {
            lastKey = key
        }

        return RangeCheckpoint(
            lastCompletedKey: lastKey,
            phase: .graphConstruction(level: 0, totalLevels: 0), // TODO: 実際のフェーズを記録
            processedRecords: 0, // TODO: 実際の処理済み数を記録
            timestamp: Date()
        )
    }
}
```

---

## エラーハンドリング

### エラー分類

| エラー種別 | 原因 | 対処法 |
|----------|------|-------|
| **RecordLayerError.internalError("Build already in progress")** | 既に実行中 | 既存ビルドの完了を待つ、または cancel() |
| **RecordLayerError.indexNotFound** | インデックスが見つからない | Schema にインデックスが定義されているか確認 |
| **RecordLayerError.transactionTooLarge** | バッチサイズが大きすぎる | batchSize を減らす（例: 1000 → 500） |
| **RecordLayerError.transactionTimedOut** | トランザクションが5秒超過 | batchSize を減らす、throttleDelayMs を増やす |

### リトライ戦略

```swift
// 自動リトライの例
func buildWithRetry(
    builder: HNSWIndexBuilder<Product>,
    options: HNSWBuildOptions,
    maxRetries: Int = 3
) async throws -> BuildStatistics {
    var lastError: Error?

    for attempt in 0..<maxRetries {
        do {
            return try await builder.build(options: options)
        } catch let error as FDBError where error.isRetryable {
            lastError = error
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // Exponential backoff
            try await Task.sleep(nanoseconds: delay)
            continue
        } catch {
            throw error
        }
    }

    throw lastError ?? RecordLayerError.internalError("Max retries exceeded")
}
```

### 復旧手順

#### ケース1: 一時的なエラー（ネットワーク断、タイムアウト）

```swift
// 中断から再開（clearFirst = false）
let stats = try await builder.build(
    options: HNSWBuildOptions(
        clearFirst: false  // ✅ 中断位置から再開
    )
)
```

#### ケース2: データ破損、構造変更

```swift
// 完全な再構築（clearFirst = true）
let stats = try await builder.build(
    options: HNSWBuildOptions(
        clearFirst: true  // ✅ 最初からやり直し
    )
)
```

---

## 実装チェックリスト

### Phase 1: 基本機能

- [x] **HNSWBuildOptions 実装**
  - [x] 基本プロパティ（batchSize, throttleDelayMs, clearFirst）
  - [x] 高度なプロパティ（dryRun, concurrency, timeout 等）
  - [x] Codable 準拠

- [x] **BuildState と BuildPhase 実装**
  - [x] enum 定義
  - [x] Sendable 準拠

- [x] **RangeCheckpoint 実装**
  - [x] 構造体定義
  - [x] Codable 準拠

- [x] **BuildStatistics 実装**
  - [x] 構造体定義
  - [x] throughput computed property
  - [x] Codable 準拠

- [x] **HNSWIndexBuilder 実装**
  - [x] Initializer
  - [x] build(options:) メソッド（⚠️ 修正中 - Issue 1, 4参照）
  - [x] getState() メソッド
  - [x] estimateBuild() メソッド（Dry run）
  - [x] countRecords() ヘルパー
  - [x] estimateBuildTime() ヘルパー
  - [x] estimateMemoryUsage() ヘルパー
  - [x] getCurrentMemoryUsage() ヘルパー

- [x] **OnlineIndexer 拡張**
  - [x] buildHNSWIndex() に progressCallback 追加（⚠️ 修正中 - Issue 1参照）
  - [x] getCurrentCheckpoint() 実装（⚠️ 修正中 - Issue 2参照）

### Phase 1.5: Known Issues修正（進行中）

- [ ] **Issue 1: IndexState二重管理の修正**
  - [ ] OnlineIndexer.buildHNSWIndex() から enable()/makeReadable() を削除
  - [ ] HNSWIndexBuilder.transitionToWriteOnly() メソッド追加
  - [ ] HNSWIndexBuilder.transitionToReadable() メソッド追加

- [ ] **Issue 2: createCheckpoint()の完全実装**
  - [ ] TODOコメントを削除
  - [ ] OnlineIndexer.getCurrentCheckpoint() から実際の情報を取得

- [ ] **Issue 3: buildFinalStatistics()の完全実装**
  - [ ] maxLevelをnilではなく実際の値に
  - [ ] OnlineIndexer.getMaxLevel() から情報を取得

- [ ] **Issue 4: OnlineIndexerインスタンス変数化**
  - [ ] indexerLock: Mutex<OnlineIndexer<Record>?> プロパティ追加
  - [ ] build() メソッドでindexerを保持
  - [ ] createCheckpoint() / buildFinalStatistics() からアクセス

- [ ] **OnlineIndexer.getProgress() 追加**
  - [ ] BuildProgress構造体定義
  - [ ] getProgress() メソッド実装
  - [ ] HNSWIndexBuilder から定期的にポーリング（オプション）

### テスト

- [ ] **HNSWIndexBuilder テスト**
  - [ ] build() 成功ケース
  - [ ] build() 失敗ケース（エラーハンドリング）
  - [ ] 状態遷移のテスト（notStarted → running → completed）
  - [ ] Dry run モードのテスト
  - [ ] 中断・再開のテスト（RangeCheckpoint）
  - [ ] 並行実行の排他制御テスト

- [ ] **統合テスト**
  - [ ] 小規模データ（100 records）
  - [ ] 中規模データ（10,000 records）
  - [ ] エラー注入テスト（ネットワーク断、タイムアウト）

### コードレビュー

- [ ] Index state 遷移は IndexStateManager を使用
- [ ] RangeSet による進捗管理を実装
- [ ] トランザクション制限（5秒、10MB）を遵守
- [ ] エラー時のクリーンアップ（state を元に戻す）
- [ ] メモリリークのチェック（長時間実行）
- [ ] 並行ビルドの排他制御
- [ ] ログレベルの適切な設定
- [ ] ドキュメント（コメント、使用例）

---

## 参考資料

- [HNSW Inline Indexing Protection](./hnsw_inline_indexing_protection.md)
- [Vector Search Optimization Design](./vector_search_optimization_design.md)
- [Vector Index Strategy Separation](./vector_index_strategy_separation_design.md)
- [Online Index Scrubber Design (Java)](https://github.com/FoundationDB/fdb-record-layer/blob/main/docs/OnlineIndexScrubber.md)

---

**Last Updated**: 2025-01-17
**Implementation Status**:
- ✅ Phase 1 設計完了
- ✅ Phase 1 実装完了
- 🔄 Phase 1.5 Known Issues修正中（4件）
  - Issue 1: IndexState二重管理
  - Issue 2: createCheckpoint()のTODO
  - Issue 3: maxLevelがnil
  - Issue 4: OnlineIndexerローカル変数
