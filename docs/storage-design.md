# FoundationDB Storage Design: 実装仕様

> **目的**: 実装時の参照ドキュメント。FDBキー構造、トランザクション制約、並行性制御の詳細仕様を定義

---

## 📋 目次

1. [FDBキー構造](#1-fdbキー構造)
2. [トランザクション制約と対策](#2-トランザクション制約と対策)
3. [並行性制御パターン](#3-並行性制御パターン)
4. [エラーハンドリング戦略](#4-エラーハンドリング戦略)
5. [パフォーマンス考慮事項](#5-パフォーマンス考慮事項)

---

## 1. FDBキー構造

### 1.1 全体構造

```
<rootSubspace>/
├── R/                          # レコードデータ
│   └── <recordType>/
│       └── <primaryKey>/
│           └── (empty) = <record-data>
│
├── I/                          # インデックスデータ
│   ├── <indexName>/
│   │   └── (インデックスタイプごとに異なる)
│   │
│   └── <indexName>/
│       └── ...
│
├── M/                          # メタデータ
│   ├── schema_version = <version>
│   ├── indexes/
│   │   └── <indexName> = <index-definition>
│   └── former_indexes/
│       └── <indexName> = <former-index-data>
│
└── S/                          # インデックス状態
    └── <indexName> = <state: disabled|writeOnly|readable>
```

### 1.2 レコードキー構造

**パターン**: ネストされたSubspace（階層的）

```swift
// キー構造
<rootSubspace>/R/<recordType>/<primaryKey>/(empty) = <record-data>

// 実装例
let recordSubspace = rootSubspace.subspace("R")
let typeSubspace = recordSubspace.subspace(Record.recordName)
let recordKey = typeSubspace.subspace(primaryKey).pack(Tuple())

// 例: User(id=123)
// キー: <root>/R/User/\x15{123}/\x00 = <protobuf-data>
```

**重要**: `subspace().subspace().pack(Tuple())`パターンを使用（フラットpack()ではない）

### 1.3 インデックスキー構造

#### 1.3.1 VALUE インデックス

**パターン**: フラットなpack()

```swift
// キー構造
<rootSubspace>/I/<indexName>/<indexValue>/<primaryKey> = []

// 実装例
let indexSubspace = rootSubspace.subspace("I").subspace(indexName)
let indexKey = indexSubspace.pack(TupleHelpers.toTuple(indexValues + primaryKeyValues))

// 例: user_by_email インデックス
// キー: <root>/I/user_by_email/\x02alice@example.com\x00/\x15{123} = []
```

**注意事項**:
- ✅ **MUST**: `indexSubspace.pack(tuple)` を使用（フラット）
- ❌ **NEVER**: `indexSubspace.subspace(tuple).pack(Tuple())` は使わない（ネスト）
- 理由: Range読み取りの効率化、インデックス値での自然なソート

#### 1.3.2 COUNT インデックス

**パターン**: アトミック操作

```swift
// キー構造
<rootSubspace>/I/<indexName>/<groupKey> = <count: Int64>

// 実装例
let indexSubspace = rootSubspace.subspace("I").subspace(indexName)
let countKey = indexSubspace.pack(TupleHelpers.toTuple(groupKeyValues))

// アトミック更新
transaction.atomicOp(
    key: countKey,
    param: withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) },
    mutationType: .add
)

// 例: user_count_by_city インデックス
// キー: <root>/I/user_count_by_city/\x02Tokyo\x00 = \x00\x00\x00\x00\x00\x00\x03\xE8 (1000)
```

**注意事項**:
- アトミック操作は読み取り不要（競合なし）
- Int64をlittle endianでエンコード

#### 1.3.3 SUM インデックス

**パターン**: COUNT と同じ（アトミック操作）

```swift
// キー構造
<rootSubspace>/I/<indexName>/<groupKey> = <sum: Int64>

// 実装例
let sumKey = indexSubspace.pack(TupleHelpers.toTuple(groupKeyValues))

// アトミック更新
transaction.atomicOp(
    key: sumKey,
    param: withUnsafeBytes(of: value.littleEndian) { Array($0) },
    mutationType: .add
)

// 例: salary_sum_by_dept インデックス
// キー: <root>/I/salary_sum_by_dept/\x02Engineering\x00 = <sum: Int64>
```

#### 1.3.4 MIN/MAX インデックス

**パターン**: VALUE インデックスと同じ構造

```swift
// キー構造
<rootSubspace>/I/<indexName>/<groupKey>/<value>/<primaryKey> = []

// 実装例
let indexSubspace = rootSubspace.subspace("I").subspace(indexName)
let indexKey = indexSubspace.pack(
    TupleHelpers.toTuple(groupKeyValues + [value] + primaryKeyValues)
)

// MIN取得: 最初のキー
let rangeSubspace = indexSubspace.pack(TupleHelpers.toTuple(groupKeyValues))
let selector = FDB.KeySelector.firstGreaterOrEqual(rangeSubspace)
let firstKey = try await transaction.getKey(selector: selector, snapshot: true)

// MAX取得: 最後のキー
var rangeEnd = rangeSubspace
rangeEnd.append(0xFF)
let selector = FDB.KeySelector.lastLessThan(rangeEnd)
let lastKey = try await transaction.getKey(selector: selector, snapshot: true)

// 例: amount_min_by_region インデックス
// キー: <root>/I/amount_min_by_region/\x02North\x00/\x15{100}/\x15{user123} = []
```

**注意事項**:
- キーは辞書順にソートされる
- O(log n) で最小値・最大値を取得可能
- Key Selectorを使用（Range読み取りではない）

#### 1.3.5 RANK インデックス

**パターン**: Skip-list ノード構造

```swift
// キー構造
<rootSubspace>/I/<indexName>/<groupKey>/rankedset/<level>/<nodeID> = <node-data>

// ノードデータ構造
struct RankedSetNode: Codable {
    let value: TupleElement
    let forward: [NodeID?]  // 各レベルへのポインタ
    let span: [Int]         // 各レベルでのスパン（要素数）
}

// 実装例
let rankedSetSubspace = indexSubspace
    .subspace(TupleHelpers.toTuple(groupKeyValues))
    .subspace("rankedset")

let nodeKey = rankedSetSubspace.pack(Tuple(level, nodeID))
let nodeData = try encoder.encode(node)
transaction.setValue(nodeData, for: nodeKey)

// 例: score_rank_by_game インデックス
// キー: <root>/I/score_rank_by_game/\x02game1\x00/rankedset/\x15{3}/\x15{node42} = <node-data>
```

**注意事項**:
- Skip-listは複数のFDBキーに分散保存
- レベルごとにキーを分ける
- ノードIDはUUIDまたはシーケンシャルID

### 1.4 メタデータキー構造

```swift
// スキーマバージョン
<rootSubspace>/M/schema_version = <Int64>

// インデックス定義
<rootSubspace>/M/indexes/<indexName> = <JSON: Index>

// FormerIndex（削除されたインデックス）
<rootSubspace>/M/former_indexes/<indexName> = <JSON: FormerIndex>

// インデックス状態
<rootSubspace>/S/<indexName> = <String: "disabled"|"writeOnly"|"readable">
```

### 1.5 進行状況追跡（RangeSet）

```swift
// キー構造
<rootSubspace>/progress/<operation>/<begin> = <end>

// 実装例
let progressSubspace = rootSubspace.subspace("progress").subspace(operationID)
let rangeKey = progressSubspace.pack(Tuple(begin))
transaction.setValue(end, for: rangeKey)

// 例: オンラインインデックス構築の進行状況
// キー: <root>/progress/build_email_index/\x02alice\x00 = \x02bob\x00
```

---

## 2. トランザクション制約と対策

### 2.1 制約一覧

| 制約項目 | デフォルト | クラスター側制限 | クライアント側設定 | 超過時のエラー |
|---------|-----------|----------------|------------------|---------------|
| **実行時間（クライアント）** | 5秒 | - | `.timeout`: 0.5秒〜無制限 | `transaction_timed_out` (1031) |
| **read-version window** | 5秒 | ❌ **5秒固定** | 変更不可 | `transaction_too_old` (1007) |
| **トランザクションサイズ** | 10MB | ❌ **10MB固定** | `.sizeLimit`: 10MB以下に制限可 | `transaction_too_large` (2101) |
| **キーサイズ** | 10KB | ❌固定 | 変更不可 | `key_too_large` (2102) |
| **値サイズ** | 100KB | ❌固定 | 変更不可 | `value_too_large` (2103) |

**重要な制約の理解**:

1. **read-version window（5秒）**: トランザクション開始から5秒以内にコミットする必要がある。これは**クラスター側の制限**であり、変更不可。
   - `.timeout`オプションはクライアント側のキャンセルタイマーのみを変更
   - 長時間処理が必要な場合は、複数トランザクションに分割する

2. **トランザクションサイズ（10MB）**: コミット時のデータサイズの**ハード制限**。
   - `.sizeLimit`オプションは10MB以下に**制限**することのみ可能（拡張は不可）
   - 大量書き込みは必ずバッチ処理で分割する

### 2.2 実装時の対策

#### 2.2.1 バッチ処理の基準

```swift
// バッチサイズの推奨値
struct BatchConfig {
    static let maxRecordsPerBatch = 1000      // レコード数
    static let maxBytesPerBatch = 5_000_000   // 5MB
    static let maxTimePerBatch: TimeInterval = 3.0  // 3秒
}

// 実装例: OnlineIndexer
func processBatch(records: [(key: FDB.Bytes, value: FDB.Bytes)]) async throws {
    var currentBatchSize = 0
    var currentBatch: [(key: FDB.Bytes, value: FDB.Bytes)] = []

    for (key, value) in records {
        currentBatch.append((key, value))
        currentBatchSize += key.count + value.count

        if currentBatch.count >= BatchConfig.maxRecordsPerBatch ||
           currentBatchSize >= BatchConfig.maxBytesPerBatch {
            // コミットしてリセット
            try await commitBatch(currentBatch)
            currentBatch = []
            currentBatchSize = 0
        }
    }

    // 残りをコミット
    if !currentBatch.isEmpty {
        try await commitBatch(currentBatch)
    }
}
```

#### 2.2.2 クライアント側タイムアウト設定

**重要**: `.timeout`オプションはクライアント側のキャンセルタイマーのみを設定します。read-version window（5秒）は変更できません。

```swift
// クライアント側のタイムアウトを短縮（早期失敗）
func setShortTimeout(transaction: TransactionProtocol) throws {
    let timeoutMs = Int64(1_000)  // 1秒
    try transaction.setOption(
        to: withUnsafeBytes(of: timeoutMs.littleEndian) { Array($0) },
        forOption: .timeout
    )
}

// 使用例: 短時間のトランザクション
try await database.withTransaction { transaction in
    try setShortTimeout(transaction: transaction)

    // 1秒以内に完了する操作
    let value = try await transaction.getValue(for: key, snapshot: false)
    // ...
}
```

#### 2.2.3 長時間Range読み取りの分割パターン

**read-version windowの5秒制限を超える場合は、複数トランザクションに分割する必要があります。**

```swift
// ✅ 推奨: 長時間Range読み取りを複数トランザクションに分割
func longRangeScan(
    database: any DatabaseProtocol,
    beginKey: FDB.Bytes,
    endKey: FDB.Bytes
) async throws -> [Record] {
    var allRecords: [Record] = []
    var continuationKey: FDB.Bytes? = beginKey

    while true {
        // 各トランザクションは5秒以内に完了
        let (batch, nextKey) = try await database.withTransaction { transaction in
            let begin = continuationKey ?? beginKey
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterOrEqual(endKey),
                limit: 1000,  // バッチサイズ制限
                snapshot: true  // 読み取り専用なのでsnapshot=true
            )

            var batchRecords: [Record] = []
            var lastKey: FDB.Bytes? = nil

            for try await (key, value) in sequence {
                batchRecords.append(try deserialize(value))
                lastKey = key

                if batchRecords.count >= 1000 { break }
            }

            // 次のキーを返す（lastKeyの次から開始）
            if let last = lastKey {
                var next = last
                next.append(0x00)  // 次のキー
                return (batchRecords, next)
            } else {
                return (batchRecords, nil)
            }
        }

        allRecords.append(contentsOf: batch)

        // 継続キーがなければ完了
        guard let next = nextKey else { break }
        continuationKey = next
    }

    return allRecords
}
```

**ポイント**:
- 各トランザクションは1000レコード単位でコミット
- 5秒以内に完了するバッチサイズを選択
- `snapshot: true` で読み取り専用モード（競合検知不要）

#### 2.2.4 トランザクションサイズの早期検出

**重要**: `.sizeLimit`オプションは10MB以下に制限することのみ可能です（拡張は不可）。

```swift
// クライアント側で早期にサイズ制限を検出（推奨: 5MB）
func setConservativeTransactionSize(transaction: TransactionProtocol) throws {
    let sizeLimit = Int64(5_000_000)  // 5MB（10MB未満）
    try transaction.setOption(
        to: withUnsafeBytes(of: sizeLimit.littleEndian) { Array($0) },
        forOption: .sizeLimit
    )
}

// 使用例: 大量書き込みは5MB単位でバッチ分割
func bulkWrite(records: [Record]) async throws {
    var currentBatch: [Record] = []
    var currentSize = 0

    for record in records {
        let size = estimateSize(record)

        if currentSize + size > 5_000_000 {
            // バッチをコミット
            try await commitBatch(currentBatch)
            currentBatch = []
            currentSize = 0
        }

        currentBatch.append(record)
        currentSize += size
    }

    // 残りをコミット
    if !currentBatch.isEmpty {
        try await commitBatch(currentBatch)
    }
}
```

**推奨事項**:
- 10MBを超える書き込みは**必ずバッチ処理**で分割
- 余裕を持って5MB単位でバッチ分割（ネットワークオーバーヘッド考慮）
- `.sizeLimit`は早期検出用（5MBに設定）

### 2.3 並行度制御

#### 2.3.1 UnionPlan の並行実行

**重要**: すべての子プランを並行実行する必要があります。

```swift
// ✅ 正しい実装: 全子プランを並行実行
let cursors = try await withThrowingTaskGroup(of: (Int, AnyTypedRecordCursor<Record>).self) { group in
    // すべての子プランをスケジュール
    for (index, child) in children.enumerated() {
        group.addTask {
            let cursor = try await child.execute(
                subspace: subspace,
                recordAccess: recordAccess,
                context: context,
                snapshot: snapshot
            )
            return (index, cursor)
        }
    }

    var results: [(Int, AnyTypedRecordCursor<Record>)] = []
    for try await result in group {
        results.append(result)
    }

    // インデックス順にソート
    return results.sorted(by: { $0.0 < $1.0 }).map { $0.1 }
}
```

**ポイント**:
- TaskGroupですべての子プランを並行実行
- FDBが内部でリソース管理を行うため、クライアント側での並行度制限は不要
- インデックス順を保持（結果の再現性）

#### 2.3.2 IntersectionPlan のストリーミング

```swift
// メモリ効率を考慮したストリーミング処理
struct IntersectionCursor<Record: Sendable>: TypedRecordCursor {
    // 全データをメモリに載せない
    // 各カーソルの現在位置のみ保持
    private var currentRecords: [Record?]  // 各カーソルの現在レコード

    public mutating func next() async throws -> Record? {
        // ストリーミング処理（メモリ使用量: O(カーソル数)）
        // ...
    }
}
```

---

## 3. 並行性制御パターン

### 3.1 final class + Mutex パターン

**重要**: このプロジェクトは `actor` を使用しない（スループット最適化のため）

```swift
import Synchronization

public final class ClassName<Record: Sendable>: Sendable {
    // 1. DatabaseProtocolは内部的にスレッドセーフ（Sendable準拠を信頼）
    private let database: any DatabaseProtocol

    // 2. 可変状態はMutexで保護
    private let stateLock: Mutex<MutableState>

    private struct MutableState {
        var counter: Int = 0
        var isRunning: Bool = false
    }

    public init(database: any DatabaseProtocol) {
        self.database = database
        self.stateLock = Mutex(MutableState())
    }

    // 3. withLockで状態アクセス（ロックスコープは最小限）
    public func operation() async throws {
        // ✅ ロック内で状態を読み取り
        let (count, shouldRun) = stateLock.withLock { state in
            state.counter += 1
            return (state.counter, state.isRunning)
        }

        // ❌ ロック内でI/Oを実行しない
        // stateLock.withLock { state in
        //     try await database.run { ... }  // デッドロックの危険
        // }

        // ✅ I/Oはロック外で実行
        try await database.withTransaction { transaction in
            // この間、他のタスクは getProgress() などを呼べる
        }

        // ✅ 再度ロックして状態を更新
        stateLock.withLock { state in
            state.counter += 1
        }
    }
}
```

**ガイドライン**:
1. ✅ `final class: Sendable` を使用（actorは使用しない）
2. ✅ `DatabaseProtocol`はSendable準拠を信頼（`nonisolated(unsafe)`は不要）
3. ✅ 可変状態は `Mutex<State>` で保護
4. ✅ ロックスコープは最小限（I/Oを含めない）
5. ❌ ロック内で `await` を使わない（デッドロックの危険）

**注意**: `nonisolated(unsafe)`は`actor`内でのみ有効です。`final class`では使用しません。

### 3.2 Copy-on-Write パターン

**用途**: RankedSet など値型のデータ構造

```swift
public struct RankedSet<Element: TupleElement & Comparable>: Sendable {
    // CoW（Copy-on-Write）により、不要なコピーを削減
    private var storage: RankedSetStorage

    private final class RankedSetStorage {
        var head: Node
        var count: Int
        // ...
    }

    public mutating func insert(_ value: Element) -> Int {
        // CoW: 他の参照がある場合のみコピー
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }

        // 変更を適用
        // ...
    }
}
```

---

## 4. エラーハンドリング戦略

### 4.1 FDBエラーの分類

```swift
public enum FDBErrorCategory {
    case retryable        // 自動リトライ可能
    case conflict         // 競合（冪等ならリトライ）
    case limit            // 制限超過（バッチ分割）
    case fatal            // 致命的エラー（中断）
}

extension FDBError {
    var category: FDBErrorCategory {
        switch code {
        // リトライ可能
        case 1007:  // transaction_too_old
            return .retryable
        case 1020:  // not_committed
            return .conflict
        case 1031:  // transaction_timed_out
            return .retryable

        // 制限超過
        case 2101:  // transaction_too_large
            return .limit
        case 2102:  // key_too_large
            return .limit
        case 2103:  // value_too_large
            return .limit

        // 致命的エラー
        case 1009:  // request_maybe_delivered
            return .fatal
        case 1021:  // commit_unknown_result
            return .fatal

        default:
            return .fatal
        }
    }
}
```

### 4.2 リトライ戦略

```swift
// withTransaction は自動的にリトライするが、
// 手動リトライが必要なケースもある

func executeWithRetry<T>(
    maxRetries: Int = 3,
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?

    for attempt in 0..<maxRetries {
        do {
            return try await operation()
        } catch let error as FDBError {
            lastError = error

            switch error.category {
            case .retryable, .conflict:
                // 指数バックオフ
                let delay = TimeInterval(pow(2.0, Double(attempt))) * 0.1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue

            case .limit:
                // バッチサイズを減らして再試行
                throw RecordLayerError.batchTooLarge(
                    "Reduce batch size and retry"
                )

            case .fatal:
                throw error
            }
        }
    }

    throw lastError ?? RecordLayerError.unknown
}
```

### 4.3 冪等性の確保

```swift
// 悪い例（非冪等）
func deposit(transaction: TransactionProtocol, accountID: String, amount: Int64) async throws {
    transaction.atomicOp(key: balanceKey, param: amountBytes, mutationType: .add)
    // 問題: リトライ時に重複入金の可能性
}

// 良い例（冪等）
func deposit(
    transaction: TransactionProtocol,
    accountID: String,
    depositID: String,  // ← 冪等性キー
    amount: Int64
) async throws {
    let depositKey = depositSubspace.pack(Tuple(accountID, "deposit", depositID))

    // 既に処理済みかチェック
    if let _ = try await transaction.getValue(for: depositKey, snapshot: false) {
        return  // 既に成功済み
    }

    // 処理を実行
    transaction.setValue(amountBytes, for: depositKey)
    transaction.atomicOp(key: balanceKey, param: amountBytes, mutationType: .add)
}
```

---

## 5. パフォーマンス考慮事項

### 5.1 Range読み取りの最適化

#### 5.1.1 ストリーミング処理（メモリ効率）

```swift
// ❌ 悪い例: 全データを一度に読み取る
let allRecords = try await transaction.getRange(
    beginSelector: .firstGreaterOrEqual(begin),
    endSelector: .firstGreaterOrEqual(end),
    snapshot: true
).collect()  // メモリ不足の危険

// ✅ 良い例: ストリーミング処理
for try await (key, value) in transaction.getRange(
    beginSelector: .firstGreaterOrEqual(begin),
    endSelector: .firstGreaterOrEqual(end),
    snapshot: true
) {
    // 1件ずつ処理（メモリ効率的）
    let record = try deserialize(value)
    try await process(record)
}
```

#### 5.1.2 長時間Range読み取りの分割

**read-version windowの5秒制限を超える場合**は、複数トランザクションに分割します。

詳細は [2.2.3 長時間Range読み取りの分割パターン](#223-長時間range読み取りの分割パターン) を参照してください。

**要点**:
- 各トランザクションは1000レコード単位でコミット
- 継続キーで次のトランザクションを開始
- `snapshot: true` で読み取り専用モード

### 5.2 snapshot パラメータの使い分け

```swift
// snapshot=true: 競合検知なし、読み取り専用
// - SnapshotCursor（トランザクション外の読み取り）
// - 統計情報の収集
// - バックグラウンドジョブ

let value = try await transaction.getValue(for: key, snapshot: true)

// snapshot=false: Serializable読み取り、競合検知あり
// - TransactionCursor（トランザクション内の読み取り）
// - 書き込みを伴う操作

try await database.withTransaction { transaction in
    let value = try await transaction.getValue(for: key, snapshot: false)
    // 同一トランザクション内の書き込みが見える
}
```

### 5.3 インデックスのプレフィックス圧縮

```swift
// インデックスキーは共通プレフィックスが多い
// 例: user_by_city インデックス
//   <root>/I/user_by_city/Tokyo/user1
//   <root>/I/user_by_city/Tokyo/user2
//   <root>/I/user_by_city/Tokyo/user3

// FDBは自動的にプレフィックス圧縮を行うため、
// ストレージ効率は良い

// 実装時の注意:
// - プレフィックスが長すぎる場合（>100バイト）は、
//   ハッシュ化を検討
let hashedPrefix = SHA256.hash(data: longPrefix).prefix(16)
```

### 5.4 Covering Index の効果

```swift
// 通常のインデックススキャン
// 1. インデックスからプライマリキーを取得
// 2. プライマリキーでレコードを取得（追加のI/O）

// Covering Index
// 1. インデックスからすべてのデータを取得（I/O 1回）

// 実装例
let indexFields = ["email", "name", "city"]  // Covering可能
let query = QueryBuilder<User>()
    .select(\.email, \.name, \.city)  // インデックスに含まれるフィールドのみ
    .where(\.email, is: .equals, "alice@example.com")
    .execute()

// → レコードフェッチなし（2-10倍高速化）
```

### 5.5 アトミック操作の活用

```swift
// COUNT/SUM インデックスはアトミック操作で更新
// - 読み取り不要（競合なし）
// - 高速（1回のネットワークRTT）

transaction.atomicOp(
    key: countKey,
    param: withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) },
    mutationType: .add
)

// 通常の読み取り→書き込みと比較
// ❌ 通常の方法（2回のRTT）
let current = try await transaction.getValue(for: key, snapshot: false)
let newValue = (current ?? 0) + 1
transaction.setValue(newValue, for: key)

// ✅ アトミック操作（1回のRTT）
transaction.atomicOp(key: key, param: delta, mutationType: .add)
```

---

## 6. 実装チェックリスト

### 6.1 新しいインデックスタイプを実装する場合

- [ ] キー構造を決定（フラット or ネスト？）
- [ ] エンコーディングパターンを選択（pack() or subspace()？）
- [ ] トランザクション制約を考慮（バッチ処理が必要か？）
- [ ] アトミック操作の可能性を検討
- [ ] Covering Index可能性を評価
- [ ] ストレージ効率を推定（キーサイズ、値サイズ）
- [ ] 並行性制御パターンを決定（Mutex? 楽観的ロック？）
- [ ] エラーハンドリング戦略を決定（リトライ? 冪等性?）
- [ ] パフォーマンステストを作成

### 6.2 新しいクエリプランを実装する場合

- [ ] メモリ使用量を推定（全データをロード? ストリーミング?）
- [ ] 並行度を決定（Sequential? Parallel?）
- [ ] snapshotパラメータの使い分け
- [ ] タイムアウト設定の必要性を評価
- [ ] エラーハンドリング（リトライ戦略）
- [ ] カーソル実装（Copy-on-Write?）
- [ ] パフォーマンステストを作成

### 6.3 オンライン操作を実装する場合

- [ ] バッチサイズを決定（レコード数、バイト数）
- [ ] 進行状況追跡（RangeSet）
- [ ] 再開可能性の確保
- [ ] トランザクション制限への対策
- [ ] エラーリカバリー戦略
- [ ] 並行実行の安全性（複数ビルダーの競合）
- [ ] パフォーマンスメトリクス（進捗率、速度）
- [ ] 統合テスト（中断→再開シナリオ）

---

## 7. デバッグ時の確認事項

### 7.1 インデックススキャンが0件を返す場合

```swift
// 1. キーエンコーディングの確認
print("Expected key: \(expectedKey.map { String(format: "%02x", $0) }.joined(separator: " "))")
print("Actual key:   \(actualKey.map { String(format: "%02x", $0) }.joined(separator: " "))")

// 2. \x05マーカーの有無を確認（ネストエンコーディングの誤用）
if actualKey.contains(0x05) {
    print("⚠️ Warning: Nested tuple encoding detected (should be flat)")
}

// 3. Tupleをアンパックして内容確認
if let unpacked = try? indexSubspace.unpack(actualKey) {
    print("Tuple count: \(unpacked.count)")
    for i in 0..<unpacked.count {
        if let element = unpacked[i] {
            print("[\(i)]: \(type(of: element)) = \(element)")
        }
    }
}

// 4. Range読み取りの境界を確認
print("Range begin: \(beginKey)")
print("Range end:   \(endKey)")
```

### 7.2 トランザクション制限エラーの場合

```swift
// エラー2101（transaction_too_large）
// → バッチサイズを減らす（5MB以下に）
// → 注意: 10MBはハード制限（拡張不可）

// エラー1007（transaction_too_old）
// → 複数トランザクションに分割
// → 注意: read-version windowは5秒固定（延長不可）

// エラー1031（transaction_timed_out）
// → クライアント側タイムアウトを延長（.timeout）
// → ただし5秒以内に完了する必要がある

// エラー2102/2103（key/value_too_large）
// → データを分割
// → インデックス値を切り詰める
```

---

**Last Updated**: 2025-01-11
**Version**: 1.1
**Status**: Phase 1-2 実装時の参照用

**変更履歴**:
- 2025-01-11 v1.1: トランザクション制約の誤りを修正（10MBハード制限、5秒read-version window）
- 2025-01-11 v1.1: UnionPlanの並行度制御バグ修正（セマフォベース実装）
- 2025-01-11 v1.1: `nonisolated(unsafe)`の誤用を修正
- 2025-01-11 v1.1: 長時間Range読み取りの分割パターンを追加
- 2025-01-11 v1.0: 初版作成
