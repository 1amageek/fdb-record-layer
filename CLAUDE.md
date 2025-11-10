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

### トランザクション処理

**読み取り**:
```swift
// snapshot: true → 競合検知なし（読み取り専用）
// snapshot: false → Serializable読み取り（トランザクション内）
let value = try await transaction.getValue(for: key, snapshot: false)
```

**書き込み**:
```swift
try await database.withTransaction { transaction in
    transaction.setValue(value, for: key)
    // 自動リトライ: not_committed (1020), transaction_too_old (1007)
}
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

### エラーハンドリング

```swift
public struct FDBError: Error {
    public let code: Int32
    public var isRetryable: Bool
}

// 主要なエラー
// 1007: transaction_too_old
// 1020: not_committed（自動リトライ）
// 1021: commit_unknown_result（冪等な場合のみリトライ）
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

### オンラインインデックス構築

```swift
public final class OnlineIndexer<Record: Sendable>: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let lock: Mutex<IndexBuildState>

    public func buildIndex() async throws {
        // バッチ処理でレコードをスキャン
        // RangeSetで進行状況を追跡（再開可能）
        // IndexStateManager経由で writeOnly → readable に遷移
    }
}
```

### クエリプランナー

```swift
public final class TypedRecordQueryPlannerV2: Sendable {
    // コストベース最適化
    // - StatisticsManager: ヒストグラムによる選択性推定
    // - インデックス選択: カーディナリティとコストで決定
    // - DNF変換、NOT押し下げ
}
```

### データモデリングパターン

**Value Index**:
```swift
// (index, email, userID) = ''
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "email"),
        FieldKeyExpression(fieldName: "userID")
    ])
)
```

**Count Index**:
```swift
// (index, city) → count
let cityCount = Index(
    name: "user_count_by_city",
    type: .count,
    rootExpression: FieldKeyExpression(fieldName: "city")
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
