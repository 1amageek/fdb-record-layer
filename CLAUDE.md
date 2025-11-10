# FoundationDB Record Layer 開発ガイド

## 目次

### Part 1: FoundationDB基礎
### Part 2: fdb-swift-bindings API
### Part 3: Swift並行性パターン
### Part 4: Record Layer設計

---

## Part 1: FoundationDB基礎

### FoundationDBとは

分散トランザクショナルKey-Valueストア：
- **ACID保証**、**順序付きKey-Value**、**楽観的並行性制御**
- キーは辞書順でソート、コミット時に競合検出
- トランザクション制限: キー≤10KB、値≤100KB、トランザクション≤10MB、実行時間≤5秒

### コアアーキテクチャ

**主要コンポーネント**:

| コンポーネント | 役割 |
|--------------|------|
| **Cluster Controller** | クラスタ監視とロール割り当て |
| **Master** | トランザクション調整、バージョン管理 |
| **Commit Proxy** | コミットリクエスト処理、競合検出 |
| **GRV Proxy** | 読み取りバージョン提供 |
| **Resolver** | トランザクション間の競合検出 |
| **Transaction Log (TLog)** | コミット済みトランザクションの永続化 |
| **Storage Server** | データ保存（MVCC、バージョン管理） |

**トランザクション処理フロー**:

1. 読み取り: GRV Proxy → 読み取りバージョン取得 → Storage Serverから直接読み取り
2. 書き込み: Commit Proxy → 競合検出 → TLogへ書き込み → Storage Serverへ非同期更新

**snapshotパラメータ**:

| パラメータ | 動作 | 用途 |
|-----------|------|------|
| `snapshot: true` | 競合検知なし | SnapshotCursor（トランザクション外） |
| `snapshot: false` | Serializable読み取り、競合検知あり | TransactionCursor（トランザクション内） |

```swift
// TransactionCursor: トランザクション内
try await database.withTransaction { transaction in
    let value = try await transaction.getValue(for: key, snapshot: false)
    // 同一トランザクション内の書き込みが見える、競合を検知
}

// SnapshotCursor: トランザクション外
let value = try await transaction.getValue(for: key, snapshot: true)
// 読み取り専用、競合検知不要、パフォーマンス最適
```

### 標準レイヤー

**Tuple Layer**: 型安全なエンコーディング、辞書順保持
```swift
let key = Tuple("California", "Los Angeles")
let packed = key.pack()  // バイト列に変換
```

**Subspace Layer**: 名前空間の分離
```swift
let app = Subspace(prefix: Tuple("myapp").pack())
let users = app["users"]
```

**Directory Layer**: 階層管理、短いプレフィックスへのマッピング
```swift
let dir = try await directoryLayer.createOrOpen(path: ["app", "users"])
```

### トランザクション制限

**サイズ制限**:

| 項目 | デフォルト | 設定可能 |
|------|-----------|---------|
| キーサイズ | 最大10KB | ❌ |
| 値サイズ | 最大100KB | ❌ |
| トランザクションサイズ | 10MB | ✅ |
| 実行時間 | 5秒 | ✅（タイムアウト） |

**制限の設定**:
```swift
// トランザクションサイズ制限
try transaction.setOption(to: withUnsafeBytes(of: Int64(50_000_000).littleEndian) { Array($0) },
                          forOption: .sizeLimit)  // 50MB

// タイムアウト設定
try transaction.setOption(to: withUnsafeBytes(of: Int64(3000).littleEndian) { Array($0) },
                          forOption: .timeout)  // 3秒
```

### データモデリングパターン

**パターン1: シンプルインデックス**

プライマリデータに対して属性ベースのインデックスを作成：

```swift
// プライマリデータ: (main, userID) = (name, zipcode)
transaction.setValue(Tuple(name, zipcode).pack(), for: mainSubspace.pack(Tuple(userID)))

// インデックス: (index, zipcode, userID) = ''
transaction.setValue([], for: indexSubspace.pack(Tuple(zipcode, userID)))

// ZIPコードで検索
let (begin, end) = indexSubspace.range(from: Tuple(zipcode), to: Tuple(zipcode, "\xFF"))
for try await (key, _) in transaction.getRange(
    beginSelector: .firstGreaterOrEqual(begin),
    endSelector: .firstGreaterOrEqual(end),
    snapshot: false
) {
    let tuple = try indexSubspace.unpack(key)
    let userID = tuple[1]  // 2番目の要素
}
```

**パターン2: 複合インデックス**

複数の属性でソート・フィルタリング：

```swift
// インデックスキー: (index, city, age, userID) = ''
let indexKey = indexSubspace.pack(Tuple("Tokyo", 25, userID))
transaction.setValue([], for: indexKey)

// 都市と年齢範囲で検索
let (begin, end) = indexSubspace.range(
    from: Tuple("Tokyo", 18),
    to: Tuple("Tokyo", 65)
)
```

**パターン3: カバリングインデックス**

インデックスから直接データ取得（プライマリデータへのアクセス不要）：

```swift
// カバリングインデックス: (index, zipcode, userID) = (name, otherData)
transaction.setValue(Tuple(name, otherData).pack(),
                     for: indexSubspace.pack(Tuple(zipcode, userID)))

// 1回のRange読み取りで完結
for try await (key, value) in transaction.getRange(...) {
    let data = try Tuple.unpack(from: value)
    let name = data[0] as? String
}
```

### エラーハンドリング

```swift
public struct FDBError: Error {
    public let code: Int32
    public var isRetryable: Bool
}

// 主要なエラー
// 1007: transaction_too_old（5秒超過）
// 1020: not_committed（競合、自動リトライ）
// 1021: commit_unknown_result（冪等な場合のみリトライ）
// 1031: transaction_timed_out（タイムアウト制限）
// 2101: transaction_too_large（サイズ制限超過）
```

**冪等性の確保**:
```swift
// 悪い例（非冪等）
func deposit(transaction: TransactionProtocol, accountID: String, amount: Int64) async throws {
    transaction.atomicOp(key: balanceKey, param: amountBytes, mutationType: .add)
    // 問題: リトライ時に重複入金の可能性
}

// 良い例（冪等）
func deposit(transaction: TransactionProtocol, accountID: String, depositID: String, amount: Int64) async throws {
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

## Part 2: fdb-swift-bindings API

### DatabaseProtocol と TransactionProtocol

```swift
public protocol DatabaseProtocol {
    func createTransaction() throws -> Transaction
    func withTransaction<T: Sendable>(
        _ operation: (TransactionProtocol) async throws -> T
    ) async throws -> T
}

public protocol TransactionProtocol: Sendable {
    func getValue(for key: FDB.Bytes, snapshot: Bool) async throws -> FDB.Bytes?
    func setValue(_ value: FDB.Bytes, for key: FDB.Bytes)
    func clear(key: FDB.Bytes)
    func clearRange(beginKey: FDB.Bytes, endKey: FDB.Bytes)
    func getRange(beginSelector: FDB.KeySelector, endSelector: FDB.KeySelector, snapshot: Bool) -> FDB.AsyncKVSequence
    func atomicOp(key: FDB.Bytes, param: FDB.Bytes, mutationType: FDB.MutationType)
    func commit() async throws -> Bool
}
```

### Tuple

```swift
// サポート型: String, Int64, Bool, Float, Double, UUID, Bytes, Tuple, Versionstamp
let tuple = Tuple(userID, "alice@example.com")
let packed = tuple.pack()
let elements = try Tuple.unpack(from: packed)

// 注意: Tuple equality is based on encoded bytes
Tuple(0.0) != Tuple(-0.0)  // true
```

### Subspace

```swift
let root = Subspace(prefix: Tuple("app").pack())
let records = root["records"]
let indexes = root["indexes"]

// キー操作
let key = records.pack(Tuple(123))
let tuple = try records.unpack(key)

// Range読み取り
let (begin, end) = records.range()
for try await (k, v) in transaction.getRange(
    beginSelector: .firstGreaterOrEqual(begin),
    endSelector: .firstGreaterOrEqual(end),
    snapshot: false
) { }

// range() vs prefixRange()
// range(): (prefix + [0x00], prefix + [0xFF]) - Tuple-encodedデータ用
// prefixRange(): (prefix, strinc(prefix)) - Raw binaryプレフィックス用
```

### DirectoryLayer

```swift
public final class DirectoryLayer: Sendable {
    public func createOrOpen(path: [String], type: DirectoryType?) async throws -> DirectorySubspace
    public func create(path: [String], type: DirectoryType?, prefix: FDB.Bytes?) async throws -> DirectorySubspace
    public func open(path: [String]) async throws -> DirectorySubspace?
    public func move(oldPath: [String], newPath: [String]) async throws -> DirectorySubspace
    public func remove(path: [String]) async throws -> Bool
    public func exists(path: [String]) async throws -> Bool
}

// DirectoryType
public enum DirectoryType {
    case partition  // 独立した名前空間、マルチテナント向け
    case custom(String)
}
```

**使用例**:
```swift
let dir = try await directoryLayer.createOrOpen(
    path: ["tenants", accountID, "orders"],
    type: .partition
)
let recordStore = RecordStore(database: database, subspace: dir.subspace, metaData: metaData)
```

---

## Part 3: Swift並行性パターン

### final class + Mutex パターン

**重要**: このプロジェクトは `actor` を使用せず、`final class: Sendable` + `Mutex` パターンを採用。

**理由**: スループット最適化
- actorはシリアライズされた実行 → 低スループット
- Mutexは細粒度ロック → 高い並行性
- データベースI/O中も他のタスクを実行可能

**実装パターン**:
```swift
import Synchronization

public final class ClassName<Record: Sendable>: Sendable {
    // 1. DatabaseProtocolは内部的にスレッドセーフ
    nonisolated(unsafe) private let database: any DatabaseProtocol

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

    // 3. withLockで状態アクセス
    public func operation() async throws {
        let count = stateLock.withLock { state in
            state.counter += 1
            return state.counter
        }

        try await database.run { transaction in
            // I/O中、他のタスクは getProgress() などを呼べる
        }
    }
}
```

**ガイドライン**:
1. ✅ `final class: Sendable` を使用（actorは使用しない）
2. ✅ `DatabaseProtocol` には `nonisolated(unsafe)` を使用
3. ✅ 可変状態は `Mutex<State>` で保護
4. ✅ ロックスコープは最小限（I/Oを含めない）

---

## Part 4: Record Layer設計

### インデックス状態管理

**3状態遷移**: disabled → writeOnly → readable

```swift
public enum IndexState: String, Sendable {
    case disabled   // 維持されず、クエリ不可
    case writeOnly  // 維持されるがクエリ不可（構築中）
    case readable   // 完全に構築され、クエリ可能
}
```

### RangeSet（進行状況追跡）

オンライン操作（インデックス構築、スクラビング）の進行状況を追跡する仕組み：

```swift
public final class RangeSet: Sendable {
    // 完了したRange（閉区間）を記録
    // キー: (rangeSet, begin) → end

    public func insertRange(begin: FDB.Bytes, end: FDB.Bytes, transaction: TransactionProtocol) async throws
    public func contains(key: FDB.Bytes, transaction: TransactionProtocol) async throws -> Bool
    public func missingRanges(begin: FDB.Bytes, end: FDB.Bytes, transaction: TransactionProtocol) async throws -> [(FDB.Bytes, FDB.Bytes)]
}
```

**使用例**:
```swift
// インデックス構築の進行状況を記録
let rangeSet = RangeSet(database: database, subspace: progressSubspace)

// バッチ処理
for batch in batches {
    // レコードをスキャンしてインデックスエントリを作成
    try await processBatch(batch, transaction: transaction)

    // 完了したRangeを記録
    try await rangeSet.insertRange(
        begin: batch.startKey,
        end: batch.endKey,
        transaction: transaction
    )
}

// 中断からの再開: 未完了のRangeを取得
let missingRanges = try await rangeSet.missingRanges(
    begin: totalBeginKey,
    end: totalEndKey,
    transaction: transaction
)
```

### オンラインインデックス構築

```swift
public final class OnlineIndexer<Record: Sendable>: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let lock: Mutex<IndexBuildState>

    private struct IndexBuildState {
        var totalRecordsScanned: UInt64 = 0
        var isRunning: Bool = false
    }

    public func buildIndex() async throws {
        // 1. インデックスを writeOnly 状態に設定
        try await indexStateManager.setState(index: indexName, state: .writeOnly)

        // 2. RangeSetで進行状況を追跡しながらバッチ処理
        let rangeSet = RangeSet(database: database, subspace: progressSubspace)
        let missingRanges = try await rangeSet.missingRanges(...)

        for (begin, end) in missingRanges {
            try await database.withTransaction { transaction in
                // レコードをスキャン
                let sequence = transaction.getRange(
                    beginSelector: .firstGreaterOrEqual(begin),
                    endSelector: .firstGreaterOrEqual(end),
                    snapshot: false
                )

                var batch: [(key: FDB.Bytes, value: FDB.Bytes)] = []
                for try await (key, value) in sequence {
                    batch.append((key, value))
                    if batch.count >= batchSize { break }
                }

                // インデックスエントリを作成
                for (key, value) in batch {
                    let record = try serializer.deserialize(value)
                    let indexEntry = evaluateIndexExpression(record)
                    transaction.setValue([], for: indexSubspace.pack(indexEntry))
                }

                // 進行状況を記録
                try await rangeSet.insertRange(begin: begin, end: batch.last!.key, transaction: transaction)
            }
        }

        // 3. インデックスを readable 状態に設定
        try await indexStateManager.setState(index: indexName, state: .readable)
    }

    public func getProgress() async throws -> (scanned: UInt64, total: UInt64, percentage: Double) {
        return lock.withLock { state in
            let percentage = total > 0 ? Double(state.totalRecordsScanned) / Double(total) : 0.0
            return (state.totalRecordsScanned, total, percentage)
        }
    }
}
```

**重要な特性**:
- **再開可能**: RangeSetにより中断された場所から再開
- **バッチ処理**: トランザクション制限（5秒、10MB）を遵守
- **並行安全**: 同じインデックスに対する複数のビルダーは競合しない（RangeSetで調整）
- **進行状況追跡**: リアルタイムで進捗を確認可能

### クエリプランナー

**TypedRecordQueryPlannerV2**: コストベース最適化

```swift
public final class TypedRecordQueryPlannerV2: Sendable {
    private let statisticsManager: StatisticsManager

    public func plan<Record>(query: TypedQuery<Record>) -> TypedQueryPlan<Record> {
        // 1. フィルタ正規化（DNF変換）
        let normalizedFilters = normalizeToDNF(query.filters)

        // 2. 各候補プランのコスト計算
        var candidates: [(plan: TypedQueryPlan<Record>, cost: Double)] = []

        // フルスキャンプラン
        let fullScanCost = estimateFullScanCost()
        candidates.append((TypedScanPlan(), fullScanCost))

        // インデックススキャンプラン
        for index in availableIndexes {
            if let indexPlan = tryIndexPlan(index: index, filters: normalizedFilters) {
                let selectivity = statisticsManager.estimateSelectivity(
                    index: index,
                    filters: normalizedFilters
                )
                let cost = estimateIndexCost(index: index, selectivity: selectivity)
                candidates.append((indexPlan, cost))
            }
        }

        // 3. 最小コストのプランを選択
        return candidates.min(by: { $0.cost < $1.cost })!.plan
    }
}
```

**StatisticsManager**: ヒストグラムベースの統計情報管理

```swift
public final class StatisticsManager: Sendable {
    // ヒストグラム: (stats, indexName, bucketID) → (min, max, count)

    public func collectStatistics(
        index: Index,
        sampleRate: Double = 0.01
    ) async throws {
        // サンプリングしてヒストグラム構築
        var buckets: [Bucket] = []

        try await database.withTransaction { transaction in
            let sequence = transaction.getRange(...)

            for try await (key, _) in sequence where shouldSample(sampleRate) {
                let value = extractIndexValue(key)
                addToBucket(&buckets, value: value)
            }

            // ヒストグラムを保存
            for bucket in buckets {
                let statsKey = statsSubspace.pack(Tuple(index.name, bucket.id))
                transaction.setValue(
                    Tuple(bucket.min, bucket.max, bucket.count).pack(),
                    for: statsKey
                )
            }
        }
    }

    public func estimateSelectivity(
        index: Index,
        filters: [Filter]
    ) -> Double {
        // ヒストグラムから選択性を推定
        // 例: city == "Tokyo" → ヒストグラムでTokyoのバケットを検索
        let bucket = findBucket(index: index, value: filterValue)
        return Double(bucket.count) / Double(totalRecords)
    }
}
```

**クエリ最適化の例**:

```swift
// クエリ: 東京在住の25-35歳のユーザー
let query = QueryBuilder<User>()
    .filter(\.city == "Tokyo")
    .filter(\.age >= 25)
    .filter(\.age <= 35)
    .build()

// プランナーの判断:
// - Option 1: フルスキャン → コスト = 100,000（全レコード数）
// - Option 2: city インデックス → 選択性 = 10%（東京: 10,000人）→ コスト = 10,000
// - Option 3: city_age 複合インデックス → 選択性 = 1%（東京25-35歳: 1,000人）→ コスト = 1,000
// → city_age インデックスを選択
```

### Record Layerアーキテクチャ

**Subspace構造**:
```
rootSubspace/
├── records/          # レコードデータ
├── indexes/          # インデックスデータ
│   ├── user_by_email/
│   └── user_by_city_age/
├── metadata/         # メタデータ
└── state/           # インデックス状態
```

**インデックスタイプ**:

| タイプ | キー構造 | 値 | 用途 |
|--------|---------|-----|------|
| **VALUE** | (index, field..., primaryKey) | '' | 基本的な検索、Range読み取り |
| **COUNT** | (index, groupKey) | count | グループごとの集約 |
| **SUM** | (index, groupKey) | sum | 数値フィールドの集約 |
| **MIN/MAX** | (index, groupKey) | min/max | 最小/最大値の追跡 |

**VALUE Index**:
```swift
// インデックスキー: (index, email, userID) = ''
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "email"),
        FieldKeyExpression(fieldName: "userID")
    ])
)

// 使用例
let query = QueryBuilder<User>()
    .filter(\.email == "alice@example.com")
    .build()
// → emailIndexを使用してRange読み取り
```

**COUNT Index**:
```swift
// インデックスキー: (index, city) → count（アトミック操作で更新）
let cityCount = Index(
    name: "user_count_by_city",
    type: .count,
    rootExpression: FieldKeyExpression(fieldName: "city")
)

// レコード追加時
transaction.atomicOp(
    key: countIndexSubspace.pack(Tuple("Tokyo")),
    param: withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) },
    mutationType: .add
)
```

**複合インデックス**:
```swift
// 都市と年齢で検索可能
let cityAgeIndex = Index(
    name: "user_by_city_age",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "age"),
        FieldKeyExpression(fieldName: "userID")
    ])
)

// 使用例: 東京在住の18-65歳
let (begin, end) = indexSubspace.range(
    from: Tuple("Tokyo", 18),
    to: Tuple("Tokyo", 65)
)
```

### マクロAPI（95%完了）

```swift
@Recordable
struct User {
    #Unique<User>([\.email])
    #Index<User>([\.city, \.age])
    #Directory<User>(["tenants", \.tenantID, "users"], layer: .partition)

    @PrimaryKey var userID: Int64
    var email: String
    var city: String
    var age: Int

    @Default(value: Date())
    var createdAt: Date

    @Transient var isLoggedIn: Bool = false
}

// 使用例
let metaData = RecordMetaData()
try metaData.registerRecordType(User.self, name: "User")

let store = RecordStore(database: database, subspace: subspace, metaData: metaData)
try await store.save(user)

let users: [User] = try await store.fetch(User.self)
    .where(\.email == "user@example.com")
    .collect()
```

---

**Last Updated**: 2025-01-10
**FoundationDB**: 7.1.0+ | **fdb-swift-bindings**: 1.0.0+ | **Record Layer (Swift)**: 開発中（マクロAPI 95%完了）
