# OnlineIndexScrubber 設計書

## 概要

OnlineIndexScrubberは、インデックスとレコード間の一貫性を検証し、オプションで修復するコンポーネントです。ダウンタイムなしにオンラインで実行可能で、大規模データセットに対してもバッチ処理で対応できます。

### 目的

1. **一貫性検証**: レコードとインデックスエントリの対応を検証
2. **問題検出**: 以下の2種類の不整合を検出
   - **Dangling entries**: インデックスエントリは存在するがレコードが存在しない
   - **Missing entries**: レコードは存在するがインデックスエントリが存在しない
3. **自動修復**: オプションで検出した問題を修復
4. **オンライン実行**: ダウンタイムなしで実行可能
5. **再開可能**: RangeSetで進行状況を追跡、中断から再開可能

### 発生原因

インデックスの不整合は以下のような状況で発生します：

- **オンラインインデックス構築中のエラー**: トランザクション失敗や部分的な書き込み
- **ソフトウェアバグ**: IndexMaintainerのバグによる不正なインデックス更新
- **データ破損**: ディスク障害やネットワーク問題
- **手動データ修正**: 直接データを変更した場合
- **スキーマ進化の問題**: インデックス定義変更時の移行エラー

---

## アーキテクチャ

### システム構成

```
┌─────────────────────────────────────────────────────────┐
│              OnlineIndexScrubber                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────────┐    ┌──────────────┐                 │
│  │  Scrubbing   │    │  Progress    │                 │
│  │  Engine      │◄──►│  Tracker     │                 │
│  └──────┬───────┘    └──────────────┘                 │
│         │                                              │
│         ▼                                              │
│  ┌──────────────────────────────────────┐             │
│  │     Issue Detector                   │             │
│  ├──────────────────────────────────────┤             │
│  │ • DanglingEntryDetector              │             │
│  │ • MissingEntryDetector               │             │
│  └──────┬───────────────────────────────┘             │
│         │                                              │
│         ▼                                              │
│  ┌──────────────────────────────────────┐             │
│  │     Issue Repairer (Optional)        │             │
│  ├──────────────────────────────────────┤             │
│  │ • Remove dangling entries            │             │
│  │ • Add missing entries                │             │
│  └──────────────────────────────────────┘             │
│                                                         │
└─────────────────────────────────────────────────────────┘
                         │
                         ▼
         ┌───────────────────────────────┐
         │     RangeSet                  │
         │  (Progress Persistence)       │
         └───────────────────────────────┘
```

### 2フェーズスキャンアプローチ

#### Phase 1: Index Entries Scan
インデックスエントリをスキャンし、各エントリに対応するレコードが存在するか確認します。

```
Index Entry → Primary Key → Record Lookup
                                ↓
                         Record Exists?
                         ├─ Yes: OK
                         └─ No: Dangling Entry
```

**検出**: Dangling entries（孤立したインデックスエントリ）
**修復**: インデックスエントリを削除

#### Phase 2: Records Scan
レコードをスキャンし、各レコードに対応するインデックスエントリが存在するか確認します。

```
Record → Extract Field Values → Build Index Key → Index Lookup
                                                        ↓
                                                Index Entry Exists?
                                                ├─ Yes: OK
                                                └─ No: Missing Entry
```

**検出**: Missing entries（欠落したインデックスエントリ）
**修復**: インデックスエントリを追加

---

## コアコンポーネント

### 1. ScrubberConfiguration

スクラビング動作を制御する設定。

```swift
/// Configuration for OnlineIndexScrubber
public struct ScrubberConfiguration: Sendable {
    /// Maximum number of entries to scan per transaction
    /// デフォルト: 10,000
    /// トランザクション時間制限（5秒）を超えないよう調整
    public let entriesScanLimit: Int

    /// Whether to repair detected issues
    /// デフォルト: false（検出のみ、修復しない）
    /// 注意: 本番環境では慎重に有効化
    public let allowRepair: Bool

    /// Maximum number of warnings to log
    /// デフォルト: 100
    /// ログの肥大化を防ぐための制限
    public let logWarningsLimit: Int

    /// Whether to log detailed progress
    /// デフォルト: true
    public let enableProgressLogging: Bool

    /// Progress log interval (in seconds)
    /// デフォルト: 10.0秒
    public let progressLogIntervalSeconds: Double

    /// Maximum number of retries on transient errors
    /// デフォルト: 10
    public let maxRetries: Int

    /// Retry delay (in milliseconds)
    /// デフォルト: 100ms
    public let retryDelayMillis: Int

    /// Preset configurations
    public static let `default` = ScrubberConfiguration(
        entriesScanLimit: 10_000,
        allowRepair: false,
        logWarningsLimit: 100,
        enableProgressLogging: true,
        progressLogIntervalSeconds: 10.0,
        maxRetries: 10,
        retryDelayMillis: 100
    )

    /// Conservative configuration (for production)
    public static let conservative = ScrubberConfiguration(
        entriesScanLimit: 5_000,      // Smaller batches
        allowRepair: false,            // Detection only
        logWarningsLimit: 50,
        enableProgressLogging: true,
        progressLogIntervalSeconds: 30.0,
        maxRetries: 5,
        retryDelayMillis: 200
    )

    /// Aggressive configuration (for maintenance windows)
    public static let aggressive = ScrubberConfiguration(
        entriesScanLimit: 20_000,     // Larger batches
        allowRepair: true,             // Auto-repair enabled
        logWarningsLimit: 500,
        enableProgressLogging: true,
        progressLogIntervalSeconds: 5.0,
        maxRetries: 20,
        retryDelayMillis: 50
    )
}
```

### 2. ScrubberResult

スクラビング操作の結果を表すデータ構造。

```swift
/// Result of scrubbing operation
public struct ScrubberResult: Sendable {
    /// Total number of index entries scanned
    public let entriesScanned: Int

    /// Number of dangling entries detected
    /// (Index entry exists but record does not)
    public let danglingEntriesDetected: Int

    /// Number of dangling entries repaired
    /// (Only > 0 if allowRepair = true)
    public let danglingEntriesRepaired: Int

    /// Number of missing entries detected
    /// (Record exists but index entry does not)
    public let missingEntriesDetected: Int

    /// Number of missing entries repaired
    /// (Only > 0 if allowRepair = true)
    public let missingEntriesRepaired: Int

    /// Total time taken (in seconds)
    public let timeElapsed: Double

    /// Whether scrubbing completed successfully
    public let completed: Bool

    /// Health status based on detected issues
    public var healthStatus: HealthStatus {
        if danglingEntriesDetected == 0 && missingEntriesDetected == 0 {
            return .healthy
        } else if danglingEntriesDetected < 10 && missingEntriesDetected < 10 {
            return .warning
        } else {
            return .critical
        }
    }

    public enum HealthStatus: String, Sendable {
        case healthy = "HEALTHY"
        case warning = "WARNING"
        case critical = "CRITICAL"
    }
}
```

### 3. ScrubberIssue

検出された問題を表す列挙型。

```swift
/// Represents a detected issue during scrubbing
public enum ScrubberIssue: Sendable {
    /// Index entry exists but record does not
    case danglingEntry(
        indexKey: FDB.Bytes,
        primaryKey: Tuple,
        indexedValues: [any TupleElement]
    )

    /// Record exists but index entry does not
    case missingEntry(
        recordKey: FDB.Bytes,
        primaryKey: Tuple,
        indexedValues: [any TupleElement]
    )

    /// Human-readable description
    public var description: String {
        switch self {
        case .danglingEntry(_, let primaryKey, let values):
            return "Dangling entry: primaryKey=\(primaryKey), values=\(values)"
        case .missingEntry(_, let primaryKey, let values):
            return "Missing entry: primaryKey=\(primaryKey), values=\(values)"
        }
    }
}
```

---

## OnlineIndexScrubber API

### 基本API

```swift
/// Online index consistency checker and repairer
///
/// Validates that index entries correspond to actual records and vice versa.
/// Can detect and optionally repair:
/// 1. Dangling entries: Index entries without corresponding records
/// 2. Missing entries: Records without corresponding index entries
///
/// **Example Usage**:
/// ```swift
/// let scrubber = try await OnlineIndexScrubber(
///     database: database,
///     subspace: subspace,
///     metaData: metaData,
///     index: emailIndex,
///     recordAccess: recordAccess,
///     configuration: .default
/// )
///
/// let result = try await scrubber.scrubIndex()
///
/// print("Scanned: \(result.entriesScanned)")
/// print("Dangling: \(result.danglingEntriesDetected)")
/// print("Missing: \(result.missingEntriesDetected)")
/// print("Health: \(result.healthStatus)")
/// ```
///
/// **Design Note**: Uses factory method pattern instead of async init
/// (async initializers are not supported in Swift)
public final class OnlineIndexScrubber<Record: Sendable>: Sendable {

    // MARK: - Properties

    private let database: FDB.Database
    private let subspace: Subspace
    private let metaData: RecordMetaData
    private let index: Index
    private let recordAccess: any RecordAccess<Record>
    private let configuration: ScrubberConfiguration

    // MARK: - Private Initialization

    /// Private initializer - use create() factory method instead
    private init(
        database: FDB.Database,
        subspace: Subspace,
        metaData: RecordMetaData,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        configuration: ScrubberConfiguration
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.index = index
        self.recordAccess = recordAccess
        self.configuration = configuration
    }

    // MARK: - Factory Method

    /// Create and validate a new index scrubber
    ///
    /// - Parameters:
    ///   - database: FoundationDB database
    ///   - subspace: Record store subspace
    ///   - metaData: Record metadata
    ///   - index: Index to scrub
    ///   - recordAccess: Record access for field extraction
    ///   - configuration: Scrubber configuration
    /// - Returns: Validated scrubber instance
    /// - Throws: RecordLayerError if validation fails
    public static func create(
        database: FDB.Database,
        subspace: Subspace,
        metaData: RecordMetaData,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        configuration: ScrubberConfiguration = .default
    ) async throws -> OnlineIndexScrubber<Record>

    // MARK: - Public API

    /// Scrub the entire index
    ///
    /// Performs a full scan of both index entries and records to detect
    /// and optionally repair any inconsistencies.
    ///
    /// **Process**:
    /// 1. Phase 1: Scan index entries → detect dangling entries
    /// 2. Phase 2: Scan records → detect missing entries
    /// 3. Return ScrubberResult with statistics
    ///
    /// **Resumability**:
    /// Uses RangeSet to track progress. If interrupted, subsequent calls
    /// will resume from the last completed range.
    ///
    /// - Returns: ScrubberResult with statistics
    /// - Throws: RecordLayerError on failures
    public func scrubIndex() async throws -> ScrubberResult

    /// Scrub a specific range of the index
    ///
    /// Useful for:
    /// - Testing on a subset of data
    /// - Scrubbing specific key ranges
    /// - Parallel scrubbing across multiple ranges
    ///
    /// - Parameters:
    ///   - startKey: Start of the range (inclusive)
    ///   - endKey: End of the range (exclusive)
    /// - Returns: ScrubberResult for the specified range
    /// - Throws: RecordLayerError on failures
    public func scrubIndexRange(
        startKey: Tuple,
        endKey: Tuple
    ) async throws -> ScrubberResult

    /// Get current scrubbing progress
    ///
    /// - Returns: Tuple of (entriesScanned, totalEstimate, progress)
    ///   - entriesScanned: Number of entries scanned so far
    ///   - totalEstimate: Estimated total (nil if unavailable)
    ///   - progress: Progress percentage (0.0 to 1.0)
    public func getProgress() async throws -> (Int, Int?, Double)

    /// Reset progress tracking
    ///
    /// Clears the RangeSet, forcing a full rescan on next scrubIndex() call.
    ///
    /// **Warning**: Use with caution. This will restart scrubbing from scratch.
    public func resetProgress() async throws
}
```

### 内部メソッド

```swift
extension OnlineIndexScrubber {

    // MARK: - Phase 1: Index Entries Scan

    /// Scan all index entries and check if corresponding records exist
    ///
    /// **Algorithm**:
    /// 1. Get index key range
    /// 2. Iterate through index entries in batches
    /// 3. For each entry:
    ///    a. Extract primary key from index key
    ///    b. Check if record exists
    ///    c. If not, log dangling entry
    ///    d. If allowRepair, delete index entry
    /// 4. Mark processed ranges in RangeSet
    private func scrubIndexEntries() async throws

    /// Scrub a batch of index entries within a single transaction
    ///
    /// - Parameters:
    ///   - context: Transaction context
    ///   - indexSubspace: Index subspace
    ///   - recordSubspace: Record subspace
    ///   - startKey: Start key for this batch
    ///   - endKey: End key for range
    ///   - warningCount: Current warning count (inout for limiting)
    /// - Returns: (continuation key, batch result)
    private func scrubIndexEntriesBatch(
        context: RecordContext,
        indexSubspace: Subspace,
        recordSubspace: Subspace,
        startKey: FDB.Bytes,
        endKey: FDB.Bytes,
        warningCount: inout Int
    ) async throws -> (continuation: FDB.Bytes?, result: BatchResult)

    // MARK: - Phase 2: Records Scan

    /// Scan all records and check if corresponding index entries exist
    ///
    /// **Algorithm**:
    /// 1. Get record key range
    /// 2. Iterate through records in batches
    /// 3. For each record:
    ///    a. Deserialize record
    ///    b. Extract indexed field values
    ///    c. Build expected index key
    ///    d. Check if index entry exists
    ///    e. If not, log missing entry
    ///    f. If allowRepair, insert index entry
    private func scrubRecords() async throws

    /// Scrub a batch of records within a single transaction
    ///
    /// - Parameters:
    ///   - context: Transaction context
    ///   - recordSubspace: Record subspace
    ///   - indexSubspace: Index subspace
    ///   - startKey: Start key for this batch
    ///   - endKey: End key for range
    ///   - warningCount: Current warning count (inout for limiting)
    /// - Returns: (continuation key, batch result)
    private func scrubRecordsBatch(
        context: RecordContext,
        recordSubspace: Subspace,
        indexSubspace: Subspace,
        startKey: FDB.Bytes,
        endKey: FDB.Bytes,
        warningCount: inout Int
    ) async throws -> (continuation: FDB.Bytes?, result: BatchResult)

    // MARK: - Helper Methods

    /// Extract primary key from index key
    ///
    /// Index key format: [index_subspace][indexed_values...][primary_key...]
    ///
    /// - Parameters:
    ///   - indexKey: Packed index key
    ///   - indexSubspace: Index subspace (for unpacking)
    /// - Returns: Primary key tuple
    /// - Throws: RecordLayerError if key format is invalid
    private func extractPrimaryKeyFromIndexKey(
        indexKey: FDB.Bytes,
        indexSubspace: Subspace
    ) throws -> Tuple

    /// Build index key from record
    ///
    /// - Parameters:
    ///   - record: Record to extract values from
    ///   - primaryKey: Primary key tuple
    /// - Returns: Expected index key
    /// - Throws: RecordLayerError on field extraction failure
    private func buildIndexKey(
        record: Record,
        primaryKey: Tuple
    ) throws -> FDB.Bytes
}
```

---

## データフロー

### Phase 1: Index Entries Scan

```
┌───────────────────────────────────────────────────────┐
│ 1. Initialize Index and Record Subspaces             │
│    indexSubspace = subspace                           │
│        .subspace(RecordStoreKeyspace.index)           │
│        .subspace(index.subspaceTupleKey) ✅           │
│    recordSubspace = subspace                          │
│        .subspace(RecordStoreKeyspace.record)          │
│    recordTypeNames = metaData.getRecordTypesForIndex │
└───────────────┬───────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────┐
│ 2. Batch Processing Loop                              │
│    while continuation != nil                          │
│      └─ Process batch (transaction)                   │
│         ├─ Scan index entries                         │
│         ├─ Update progress ✅ (BEFORE commit)         │
│         └─ Commit transaction                         │
└───────────────┬───────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────┐
│ 3. For each index entry in batch:                     │
│    indexKey → removePrefix → Tuple.decode()           │
│    → elementsArray.suffix(primaryKeyLength) ✅        │
│    (primaryKeyLength from RecordMetaData) ✅          │
└───────────────┬───────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────┐
│ 4. Record Lookup (check ALL record types) ✅         │
│    for recordTypeName in recordTypeNames:             │
│      typeSubspace = recordSubspace                    │
│          .subspace(recordTypeName) ✅                 │
│      recordKey = typeSubspace.pack(primaryKey)        │
│      if transaction.getValue(recordKey) != nil:       │
│        recordFound = true; break                      │
└───────────────┬───────────────────────────────────────┘
                │
                ├─ recordFound ──► OK
                │
                └─ !recordFound ──► Dangling Entry
                                     │
                                     ├─ Log warning
                                     │
                                     └─ if allowRepair:
                                        transaction.clear(indexKey)
```

### Phase 2: Records Scan

```
┌───────────────────────────────────────────────────────┐
│ 1. Initialize Index and Record Subspaces             │
│    indexSubspace = subspace                           │
│        .subspace(RecordStoreKeyspace.index)           │
│        .subspace(index.subspaceTupleKey) ✅           │
│    recordSubspace = subspace                          │
│        .subspace(RecordStoreKeyspace.record)          │
│        .subspace(recordTypeName) ✅                   │
│    primaryKeyLength = metaData                        │
│        .getPrimaryKeyFieldCount(recordTypeName) ✅    │
└───────────────┬───────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────┐
│ 2. Batch Processing Loop                              │
│    while continuation != nil                          │
│      └─ Process batch (transaction)                   │
│         ├─ Scan records                               │
│         ├─ Update progress ✅ (BEFORE commit)         │
│         └─ Commit transaction                         │
└───────────────┬───────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────┐
│ 3. For each record in batch:                          │
│    recordKey → removePrefix → Tuple.decode() ✅       │
│    → primaryKeyElements (already correct length) ✅   │
│                                                        │
│    recordBytes → deserialize() → record               │
│    indexedValues ← extractField(record, fieldName)    │
└───────────────┬───────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────┐
│ 4. Build Expected Index Key                           │
│    indexKey = indexSubspace.pack(                     │
│        Tuple(indexedValues + primaryKeyElements) ✅   │
│    )                                                   │
└───────────────┬───────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────┐
│ 5. Index Entry Lookup                                 │
│    indexBytes = transaction.getValue(indexKey)        │
└───────────────┬───────────────────────────────────────┘
                │
                ├─ indexBytes != nil ──► OK
                │
                └─ indexBytes == nil ──► Missing Entry
                                          │
                                          ├─ Log warning
                                          │
                                          └─ if allowRepair:
                                             transaction.set(indexKey, empty)
```

---

## 使用例

### 例1: 検出のみ（修復しない）

```swift
import FDBRecordLayer

// RecordStoreの準備
let recordStore = RecordStore(
    database: database,
    subspace: Subspace(rootPrefix: "users"),
    metaData: metaData
)

// インデックスの取得
let emailIndex = try metaData.getIndex(name: "user_by_email")

// Scrubberの作成（デフォルト設定: 修復なし）
let scrubber = try await OnlineIndexScrubber(
    database: database,
    subspace: recordStore.subspace,
    metaData: metaData,
    index: emailIndex,
    recordAccess: recordStore.recordAccess,
    configuration: .default  // allowRepair = false
)

// スクラビング実行
let result = try await scrubber.scrubIndex()

// 結果の確認
print("=== Scrubbing Results ===")
print("Entries scanned: \(result.entriesScanned)")
print("Dangling entries: \(result.danglingEntriesDetected)")
print("Missing entries: \(result.missingEntriesDetected)")
print("Health status: \(result.healthStatus)")
print("Time elapsed: \(String(format: "%.2f", result.timeElapsed))s")

// アラート判定
if result.healthStatus == .critical {
    print("⚠️ CRITICAL: Index has serious inconsistencies!")
    print("Consider running with allowRepair=true during maintenance window")
}
```

### 例2: 自動修復

```swift
// 修復を有効化した設定
let repairConfig = ScrubberConfiguration(
    entriesScanLimit: 10_000,
    allowRepair: true,          // 修復を有効化
    logWarningsLimit: 100,
    enableProgressLogging: true,
    progressLogIntervalSeconds: 10.0,
    maxRetries: 10,
    retryDelayMillis: 100
)

let scrubber = try await OnlineIndexScrubber(
    database: database,
    subspace: recordStore.subspace,
    metaData: metaData,
    index: emailIndex,
    recordAccess: recordStore.recordAccess,
    configuration: repairConfig
)

// スクラビング＋修復
let result = try await scrubber.scrubIndex()

// 修復結果の確認
print("=== Repair Results ===")
print("Dangling entries repaired: \(result.danglingEntriesRepaired)")
print("Missing entries repaired: \(result.missingEntriesRepaired)")

if result.danglingEntriesRepaired > 0 || result.missingEntriesRepaired > 0 {
    print("✅ Index repaired successfully")
}
```

### 例3: 範囲指定スキャン

```swift
// 特定のキー範囲のみをスクラビング
let startKey = Tuple("a")  // "a"から始まるキー
let endKey = Tuple("b")    // "b"の前まで

let result = try await scrubber.scrubIndexRange(
    startKey: startKey,
    endKey: endKey
)

print("Range scrubbing completed: \(result.entriesScanned) entries")
```

### 例4: 進行状況の監視

```swift
// バックグラウンドでスクラビング実行
Task {
    do {
        let result = try await scrubber.scrubIndex()
        print("Scrubbing completed: \(result)")
    } catch {
        print("Scrubbing failed: \(error)")
    }
}

// 別のタスクで進行状況を監視
Task {
    while true {
        let (scanned, total, progress) = try await scrubber.getProgress()

        if let total = total {
            print("Progress: \(scanned)/\(total) (\(Int(progress * 100))%)")
        } else {
            print("Progress: \(scanned) entries scanned")
        }

        try await Task.sleep(nanoseconds: 5_000_000_000)  // 5秒待機
    }
}
```

### 例5: 定期的なヘルスチェック

```swift
/// 定期的にインデックスをチェックする関数
func scheduleIndexHealthCheck(
    database: FDB.Database,
    recordStore: RecordStore<User>,
    index: Index
) {
    // 1日に1回実行
    Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
        Task {
            do {
                let scrubber = try await OnlineIndexScrubber(
                    database: database,
                    subspace: recordStore.subspace,
                    metaData: recordStore.metaData,
                    index: index,
                    recordAccess: recordStore.recordAccess,
                    configuration: .conservative  // 本番用設定
                )

                let result = try await scrubber.scrubIndex()

                // アラート送信
                if result.healthStatus != .healthy {
                    sendAlert(
                        "Index health check failed",
                        details: """
                        Index: \(index.name)
                        Status: \(result.healthStatus)
                        Dangling: \(result.danglingEntriesDetected)
                        Missing: \(result.missingEntriesDetected)
                        """
                    )
                }
            } catch {
                print("Health check failed: \(error)")
            }
        }
    }
}
```

---

## 実装フェーズ

### Phase 1: 基礎実装（1週間）

**目標**: 基本構造とPhase 1（Index entries scan）の実装

**タスク**:
1. ✅ 設計ドキュメント作成
2. `ScrubberConfiguration`構造体実装
3. `ScrubberResult`構造体実装
4. `ScrubberIssue`列挙型実装
5. `OnlineIndexScrubber`基本構造
   - Initialization
   - RangeSet統合
   - Logger設定
6. Phase 1実装
   - `scrubIndexEntries()`
   - `scrubIndexEntriesBatch()`
   - `extractPrimaryKeyFromIndexKey()`
7. 基本的なUnit tests
   - Configuration tests
   - Result structure tests

**ファイル構成**:
```
Sources/FDBRecordLayer/Index/
├── OnlineIndexScrubber.swift         (メインクラス)
├── ScrubberConfiguration.swift       (設定)
├── ScrubberResult.swift              (結果)
└── ScrubberIssue.swift               (問題定義)

Tests/FDBRecordLayerTests/Index/
└── OnlineIndexScrubberTests.swift    (テスト)
```

### Phase 2: Records scan実装（1週間）

**目標**: Phase 2（Records scan）とMissing entries検出

**タスク**:
1. Phase 2実装
   - `scrubRecords()`
   - `scrubRecordsBatch()`
   - `buildIndexKey()`
2. 修復ロジック実装
   - Dangling entries削除
   - Missing entriesの追加
3. 進行状況追跡
   - `getProgress()`実装
   - Progress logging
4. Integration tests
   - Dangling entries detection
   - Missing entries detection
   - Repair functionality

### Phase 3: テストと最適化（1週間）

**目標**: 包括的なテストとパフォーマンス最適化

**タスク**:
1. Edge cases tests
   - Empty index
   - Large datasets
   - Compound indexes
   - Multi-valued fields
2. Error handling tests
   - Transaction failures
   - RangeSet errors
   - Invalid index definitions
3. パフォーマンス最適化
   - Batch size tuning
   - Transaction timing
   - Memory usage optimization
4. ドキュメント整備
   - API documentation
   - Usage examples
   - Troubleshooting guide

---

## Java版Record Layerとの比較

### 機能比較

| 機能 | Java版 | Swift版（このプロジェクト） |
|------|--------|----------------------------|
| **Dangling entries検出** | ✅ あり | ✅ 実装予定 |
| **Missing entries検出** | ✅ あり | ✅ 実装予定 |
| **自動修復** | ✅ あり | ✅ 実装予定 |
| **進行状況追跡** | ✅ RangeSet使用 | ✅ RangeSet使用 |
| **再開可能** | ✅ あり | ✅ 実装予定 |
| **ログ制限** | ✅ あり | ✅ 実装予定 |
| **バッチ処理** | ✅ あり | ✅ 実装予定 |
| **並列実行** | ✅ 可能 | ✅ Swift Concurrency |

### アーキテクチャの違い

#### Java版
```java
OnlineIndexScrubber.Builder builder = OnlineIndexScrubber.newBuilder()
    .setDatabase(fdb)
    .setMetaData(metaData)
    .setIndex(index)
    .setSubspace(subspace)
    .setScrubbingPolicy(policy);

OnlineIndexScrubber scrubber = builder.build();
scrubber.scrubIndexAsync().join();
```

**特徴**:
- Builderパターン
- CompletableFuture
- 同期/非同期両方のAPI

#### Swift版（このプロジェクト）
```swift
let scrubber = try await OnlineIndexScrubber(
    database: database,
    subspace: subspace,
    metaData: metaData,
    index: index,
    recordAccess: recordAccess,
    configuration: .default
)

let result = try await scrubber.scrubIndex()
```

**特徴**:
- Actorモデル（スレッドセーフ）
- async/await（Swift Concurrency）
- 構造化並行性
- 型安全なエラーハンドリング

### 設計判断の違い

| 項目 | Java版 | Swift版 | 理由 |
|------|--------|---------|------|
| **並行性モデル** | CompletableFuture | Actor + async/await | Swift Concurrencyのベストプラクティス |
| **エラーハンドリング** | Exceptions | Result/throws | Swift型システムとの親和性 |
| **設定** | ScrubbingPolicy | ScrubberConfiguration | Swiftの値型（struct）活用 |
| **ログ** | SLF4J | swift-log | Swiftエコシステム標準 |
| **並列実行** | Executor | TaskGroup | 構造化並行性 |

---

## パフォーマンス考慮事項

### トランザクション時間制限

FoundationDBはトランザクション実行時間を**5秒**に制限しています。

**対策**:
- バッチサイズを適切に設定（デフォルト: 10,000エントリ）
- 大規模インデックスは複数トランザクションに分割
- RangeSetで進行状況を保存し、再開可能に

### メモリ使用量

**問題**: 大規模なバッチでメモリ消費が増加

**対策**:
- ストリーミング処理（AsyncSequence）
- バッチ完了後にメモリ解放
- 設定可能なバッチサイズ

### I/O最適化

**問題**: レコードルックアップが多数のI/O操作を発生

**対策**:
- パイプライニング（複数の非同期読み取りを並列実行）
- Snapshot読み取り（競合検出不要な場合）
- プリフェッチ（次のバッチのキーを事前取得）

### 本番環境での推奨設定

```swift
// 本番環境用の推奨設定
let productionConfig = ScrubberConfiguration(
    entriesScanLimit: 5_000,        // 小さめのバッチ
    allowRepair: false,              // まず検出のみ
    logWarningsLimit: 100,
    enableProgressLogging: true,
    progressLogIntervalSeconds: 30.0,
    maxRetries: 5,
    retryDelayMillis: 200
)

// メンテナンスウィンドウ用の設定
let maintenanceConfig = ScrubberConfiguration(
    entriesScanLimit: 20_000,       // 大きなバッチ
    allowRepair: true,               // 修復を有効化
    logWarningsLimit: 500,
    enableProgressLogging: true,
    progressLogIntervalSeconds: 5.0,
    maxRetries: 20,
    retryDelayMillis: 50
)
```

---

## トラブルシューティング

### 問題1: トランザクションタイムアウト

**症状**: `transaction_too_old` (1007) エラー

**原因**: バッチサイズが大きすぎて5秒を超過

**解決策**:
```swift
// バッチサイズを減らす
let config = ScrubberConfiguration(
    entriesScanLimit: 2_000,  // 10,000 → 2,000
    // ... 他の設定
)
```

### 問題2: 大量のDangling entries

**症状**: 数千のDangling entriesが検出される

**原因**:
- オンラインインデックス構築の失敗
- IndexMaintainerのバグ
- データ破損

**解決策**:
1. まず検出のみで実行し、範囲を確認
2. 原因を特定（ログ、メトリクスを確認）
3. メンテナンスウィンドウで修復実行
```swift
let repairConfig = ScrubberConfiguration(
    entriesScanLimit: 10_000,
    allowRepair: true,  // 修復を有効化
    // ...
)
```

### 問題3: スクラビングが遅い

**症状**: 大規模インデックスで数時間かかる

**解決策**:
1. バッチサイズを増やす（トランザクション時間に注意）
2. 並列スクラビング
```swift
// 範囲を分割して並列実行
await withTaskGroup(of: ScrubberResult.self) { group in
    for range in keyRanges {
        group.addTask {
            try await scrubber.scrubIndexRange(
                startKey: range.start,
                endKey: range.end
            )
        }
    }

    for await result in group {
        print("Range completed: \(result)")
    }
}
```

---

## 今後の拡張

### 1. 並列スクラビング

キー範囲を分割し、複数のScrubberを並列実行：

```swift
public struct ParallelScrubber {
    public func scrubIndexParallel(
        parallelism: Int
    ) async throws -> ScrubberResult
}
```

### 2. 統計情報との統合

StatisticsManagerから推定エントリ数を取得し、進行状況の精度を向上：

```swift
let totalEstimate = try await statisticsManager.getIndexCardinality(index)
let progress = Double(scanned) / Double(totalEstimate)
```

### 3. 選択的スクラビング

特定の条件に一致するエントリのみをスクラビング：

```swift
public func scrubIndexWhere(
    predicate: (Record) throws -> Bool
) async throws -> ScrubberResult
```

### 4. レポート生成

詳細なレポートをJSON/HTML形式で出力：

```swift
public func generateReport(
    format: ReportFormat
) async throws -> String
```

---

## 参考資料

### Java版Record Layer
- [OnlineIndexScrubber.java](https://github.com/FoundationDB/fdb-record-layer/blob/main/fdb-record-layer-core/src/main/java/com/apple/foundationdb/record/provider/foundationdb/OnlineIndexScrubber.java)
- [OnlineIndexScrubberTest.java](https://github.com/FoundationDB/fdb-record-layer/blob/main/fdb-record-layer-core/src/test/java/com/apple/foundationdb/record/provider/foundationdb/OnlineIndexScrubberTest.java)

### FoundationDBドキュメント
- [Transaction Limits](https://apple.github.io/foundationdb/known-limitations.html#transaction-limits)
- [Best Practices](https://apple.github.io/foundationdb/developer-guide.html#best-practices)

### このプロジェクトの関連ファイル
- `Sources/FDBRecordLayer/Index/OnlineIndexer.swift` - オンラインインデックス構築の参考実装
- `Sources/FDBRecordLayer/Index/RangeSet.swift` - 進行状況追跡
- `CLAUDE.md` - FoundationDB使い方ガイド

---

**Last Updated**: 2025-01-15
**Status**: Design Phase
**Author**: Claude (Anthropic)
**Review Status**: Pending Implementation
