# APIリファレンス

## 目次

- [FDBRecordCore](#fdbrecordcore)
  - [マクロ](#マクロ)
  - [プロトコル](#プロトコル)
  - [型](#型)
- [FDBRecordServer](#fdbrecordserver)
  - [RecordStore](#recordstore)
  - [IndexManager](#indexmanager)
  - [QueryBuilder](#querybuilder)
  - [サーバーマクロ](#サーバーマクロ)

---

## FDBRecordCore

クライアント・サーバー共通のモデル定義レイヤー。

### マクロ

#### @Record

レコード型をマークし、`Record`プロトコルへの準拠を自動生成します。

```swift
@attached(member, names: named(id), named(recordName), named(__recordMetadata))
@attached(extension, conformances: Record)
public macro Record()
```

**生成されるコード**:
- `static var recordName: String`
- `var id: ID`
- `static var __recordMetadata: RecordMetadataDescriptor`
- `Record`プロトコル準拠
- `Codable`準拠

**使用例**:
```swift
@Record
struct User {
    @ID var userID: Int64
    var email: String
    var name: String
}

// 生成されるコード:
extension User: Record {
    static var recordName: String { "User" }
    var id: Int64 { userID }
    static var __recordMetadata: RecordMetadataDescriptor { ... }
}
```

---

#### @ID

プライマリキーフィールドをマークします。少なくとも1つの`@ID`が必要です。

```swift
@attached(peer)
public macro ID()
```

**制約**:
- 型は `Hashable & Codable & Sendable` に準拠する必要がある
- 複合プライマリキーの場合、複数のフィールドに`@ID`を付与

**使用例**:
```swift
// 単一プライマリキー
@Record
struct User {
    @ID var userID: Int64
}

// 複合プライマリキー
@Record
struct TenantUser {
    @ID var tenantID: String
    @ID var userID: Int64
}
```

---

#### @Transient

フィールドを永続化対象から除外します。

```swift
@attached(peer)
public macro Transient()
```

**使用例**:
```swift
@Record
struct User {
    @ID var userID: Int64
    var email: String

    @Transient
    var isLoggedIn: Bool = false  // シリアライズされない
}
```

---

#### @Default

デフォルト値を指定します。スキーマ進化時に有用です。

```swift
@attached(peer)
public macro Default(value: Any)
```

**使用例**:
```swift
@Record
struct User {
    @ID var userID: Int64
    var email: String

    @Default(value: Date())
    var createdAt: Date

    @Default(value: "active")
    var status: String
}
```

---

### プロトコル

#### Record

永続化可能なレコード型の基本プロトコル。

```swift
public protocol Record: Identifiable, Codable, Sendable {
    associatedtype ID: Hashable & Codable & Sendable

    static var recordName: String { get }
    var id: ID { get }
    static var __recordMetadata: RecordMetadataDescriptor { get }
}
```

**要件**:
- `recordName`: レコードタイプ名（Protobuf互換性のため）
- `id`: プライマリキー
- `__recordMetadata`: メタデータ記述子（マクロが自動生成）

---

### 型

#### RecordMetadataDescriptor

レコードのメタデータを記述します。

```swift
public struct RecordMetadataDescriptor: Sendable {
    public let recordName: String
    public let primaryKeyPath: AnyKeyPath
    public let fields: [FieldDescriptor]

    public struct FieldDescriptor: Sendable {
        public let name: String
        public let keyPath: AnyKeyPath
        public let fieldNumber: Int
        public let isTransient: Bool
        public let defaultValue: (any Sendable)?
    }
}
```

**使用例**:
```swift
let metadata = User.__recordMetadata
print("Record name: \(metadata.recordName)")  // "User"
print("Fields: \(metadata.fields.map { $0.name })")  // ["userID", "email", "name"]
```

---

## FDBRecordServer

サーバーサイドの永続化、インデックス、クエリ機能を提供。

### RecordStore

レコードの永続化を管理するストア。

```swift
public final class RecordStore<Record: FDBRecordCore.Record>: Sendable {
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        indexes: [IndexDefinition<Record>] = []
    )
}
```

#### save

レコードを保存します。

```swift
public func save(_ record: Record, context: TransactionContext) async throws
```

**動作**:
1. プライマリキーでレコードキーを構築
2. Protobufシリアライズ
3. インデックスエントリを更新
4. トランザクションにコミット

**使用例**:
```swift
let store = RecordStore<User>(database: db, subspace: subspace, schema: schema)

try await database.withTransaction { transaction in
    let context = TransactionContext(transaction: transaction)
    try await store.save(user, context: context)
}
```

---

#### load

プライマリキーでレコードを読み込みます。

```swift
public func load(
    primaryKey: Record.ID,
    context: TransactionContext
) async throws -> Record?
```

**計算量**: O(1)（FoundationDB get操作）

**使用例**:
```swift
try await database.withTransaction { transaction in
    let context = TransactionContext(transaction: transaction)
    if let user = try await store.load(primaryKey: 123, context: context) {
        print("Found user: \(user.name)")
    }
}
```

---

#### delete

プライマリキーでレコードを削除します。

```swift
public func delete(
    primaryKey: Record.ID,
    context: TransactionContext
) async throws
```

**動作**:
1. 既存レコードを読み込み
2. インデックスエントリを削除
3. レコードキーを削除

**使用例**:
```swift
try await database.withTransaction { transaction in
    let context = TransactionContext(transaction: transaction)
    try await store.delete(primaryKey: 123, context: context)
}
```

---

#### query

クエリビルダーを作成します。

```swift
public func query(_ type: Record.Type) -> QueryBuilder<Record>
```

**使用例**:
```swift
let users = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

---

### IndexManager

インデックスの管理と維持を担当。

```swift
public final class IndexManager: Sendable {
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        indexes: [IndexDefinition<Record>]
    )
}
```

#### updateIndexes

レコード保存/削除時にインデックスを更新します。

```swift
public func updateIndexes(
    oldRecord: Record?,
    newRecord: Record?,
    recordAccess: any RecordAccess<Record>,
    transaction: TransactionProtocol
) async throws
```

**動作**:
1. 古いインデックスエントリを削除
2. 新しいインデックスエントリを作成
3. 集約インデックス（COUNT、SUM）を更新

---

#### setState

インデックスの状態を設定します。

```swift
public func setState(
    index: String,
    state: IndexState,
    transaction: TransactionProtocol
) async throws
```

**IndexState**:
- `.disabled`: 維持されず、クエリ不可
- `.writeOnly`: 維持されるがクエリ不可（構築中）
- `.readable`: 完全に構築され、クエリ可能

**使用例**:
```swift
// インデックス構築開始
try await indexManager.setState(index: "email_index", state: .writeOnly, transaction: tx)

// ... インデックス構築 ...

// インデックス構築完了
try await indexManager.setState(index: "email_index", state: .readable, transaction: tx)
```

---

### QueryBuilder

型安全なクエリビルダー。

```swift
public struct QueryBuilder<Record: FDBRecordCore.Record> {
    public func where<T: Equatable>(
        _ keyPath: KeyPath<Record, T>,
        _ operation: ComparisonOperation,
        _ value: T
    ) -> QueryBuilder<Record>

    public func limit(_ count: Int) -> QueryBuilder<Record>

    public func execute() async throws -> [Record]
}
```

#### where

フィルタ条件を追加します。

**ComparisonOperation**:
- `.equals`: 等価
- `.notEquals`: 非等価
- `.greaterThan`: より大きい
- `.greaterThanOrEqual`: 以上
- `.lessThan`: より小さい
- `.lessThanOrEqual`: 以下

**使用例**:
```swift
// 単一条件
let users = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()

// 複数条件（AND）
let adults = try await store.query(User.self)
    .where(\.age, .greaterThanOrEqual, 18)
    .where(\.age, .lessThan, 65)
    .execute()

// 範囲クエリ
let tokyoUsers = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .limit(100)
    .execute()
```

---

#### limit

結果件数を制限します。

```swift
public func limit(_ count: Int) -> QueryBuilder<Record>
```

**使用例**:
```swift
let topUsers = try await store.query(User.self)
    .limit(10)
    .execute()
```

---

#### execute

クエリを実行してレコードを取得します。

```swift
public func execute() async throws -> [Record]
```

**動作**:
1. QueryPlannerがクエリを最適化
2. インデックスまたはフルスキャンを選択
3. レコードをストリーミング読み取り
4. 配列として返却

---

### IndexDefinition

インデックス定義。

```swift
public struct IndexDefinition<Record: FDBRecordCore.Record>: Sendable {
    public let name: String
    public let type: IndexType
    public let keyPaths: [PartialKeyPath<Record>]

    public enum IndexType: Sendable {
        case value
        case count
        case sum
        case min
        case max
        case unique
    }
}
```

#### ファクトリメソッド

```swift
// VALUE インデックス
public static func value(
    name: String,
    keyPaths: [PartialKeyPath<Record>]
) -> IndexDefinition<Record>

// UNIQUE インデックス
public static func unique(
    name: String,
    keyPaths: [PartialKeyPath<Record>]
) -> IndexDefinition<Record>

// COUNT インデックス
public static func count(
    name: String,
    keyPaths: [PartialKeyPath<Record>]
) -> IndexDefinition<Record>

// SUM インデックス
public static func sum(
    name: String,
    keyPaths: [PartialKeyPath<Record>]
) -> IndexDefinition<Record>

// MIN インデックス
public static func min(
    name: String,
    keyPaths: [PartialKeyPath<Record>]
) -> IndexDefinition<Record>

// MAX インデックス
public static func max(
    name: String,
    keyPaths: [PartialKeyPath<Record>]
) -> IndexDefinition<Record>
```

**使用例**:
```swift
extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email]),
        .unique(name: "email_unique", keyPaths: [\.email]),
        .count(name: "city_count", keyPaths: [\.city]),
        .sum(name: "salary_by_dept", keyPaths: [\.department, \.salary]),
        .min(name: "min_age_by_city", keyPaths: [\.city, \.age]),
        .max(name: "max_age_by_city", keyPaths: [\.city, \.age]),
    ]
}
```

---

### サーバーマクロ

#### #ServerIndex

インデックス定義マクロ（サーバーサイド専用）。

```swift
@freestanding(declaration)
public macro ServerIndex<T: Record>(
    _ indices: [PartialKeyPath<T>]...,
    name: String? = nil
)
```

**使用例**:
```swift
extension User {
    static let serverIndexes: [IndexDefinition<User>] = {
        #ServerIndex<User>([\.email])
        #ServerIndex<User>([\.city, \.age], name: "city_age_index")
    }()
}
```

---

#### #ServerUnique

ユニーク制約マクロ（サーバーサイド専用）。

```swift
@freestanding(declaration)
public macro ServerUnique<T: Record>(
    _ constraints: [PartialKeyPath<T>]...
)
```

**使用例**:
```swift
extension User {
    static let serverIndexes: [IndexDefinition<User>] = {
        #ServerUnique<User>([\.email])
        #ServerUnique<User>([\.username])
    }()
}
```

---

#### #ServerDirectory

ディレクトリ設定マクロ（サーバーサイド専用）。

```swift
@freestanding(declaration)
public macro ServerDirectory<T: Record>(
    _ pathElements: any DirectoryPathElement...,
    layer: DirectoryLayerType = .recordStore
)
```

**DirectoryPathElement**:
- `String`: 固定パス要素
- `Field(\.keyPath)`: 動的パス要素（フィールド値）

**DirectoryLayerType**:
- `.recordStore`: 標準RecordStore
- `.partition`: マルチテナントパーティション
- `.custom(String)`: カスタムレイヤー

**使用例**:
```swift
// シンプルなディレクトリ
extension User {
    static let serverDirectory: DirectoryConfiguration = {
        #ServerDirectory<User>("app", "users")
    }()
}

// マルチテナント（パーティション）
extension Order {
    static let serverDirectory: DirectoryConfiguration = {
        #ServerDirectory<Order>(
            "tenants",
            Field(\.tenantID),
            "orders",
            layer: .partition
        )
    }()
}
```

---

## 集約関数

### evaluateAggregate

集約関数を評価します。

```swift
public func evaluateAggregate(
    _ function: AggregateFunction,
    groupBy: [any TupleElement]
) async throws -> Int64
```

**AggregateFunction**:
```swift
public enum AggregateFunction {
    case count(indexName: String)
    case sum(indexName: String)
    case min(indexName: String)
    case max(indexName: String)
}
```

**使用例**:
```swift
// COUNT: 東京のユーザー数
let count = try await store.evaluateAggregate(
    .count(indexName: "city_count"),
    groupBy: ["Tokyo"]
)

// SUM: エンジニアリング部門の給与合計
let total = try await store.evaluateAggregate(
    .sum(indexName: "salary_by_dept"),
    groupBy: ["Engineering"]
)

// MIN: 北米地域の最小金額
let minAmount = try await store.evaluateAggregate(
    .min(indexName: "amount_min_by_region"),
    groupBy: ["North"]
)

// MAX: 北米地域の最大金額
let maxAmount = try await store.evaluateAggregate(
    .max(indexName: "amount_max_by_region"),
    groupBy: ["North"]
)
```

---

## オンライン操作

### OnlineIndexer

オンラインインデックス構築を管理。

```swift
public final class OnlineIndexer<Record: Sendable>: Sendable {
    public init(
        database: any DatabaseProtocol,
        recordStore: RecordStore<Record>,
        index: Index,
        batchSize: Int = 1000
    )

    public func buildIndex() async throws

    public func getProgress() async throws -> (
        scanned: UInt64,
        total: UInt64,
        percentage: Double
    )
}
```

**使用例**:
```swift
let newIndex = Index(
    name: "user_by_status",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "status")
)

let indexer = OnlineIndexer(
    database: database,
    recordStore: store,
    index: newIndex
)

// バックグラウンドタスクで構築
Task {
    try await indexer.buildIndex()
}

// 進行状況監視
let progress = try await indexer.getProgress()
print("Progress: \(progress.percentage)%")
```

---

## Schema

スキーマ定義と検証。

```swift
public struct Schema: Sendable {
    public let version: Int
    public let recordTypes: [any Record.Type]

    public init(version: Int = 1, _ recordTypes: [any Record.Type])
}
```

**使用例**:
```swift
let schema = Schema(version: 1, [User.self, Order.self])

// バージョン2（新フィールド追加）
let schemaV2 = Schema(version: 2, [User.self, Order.self])
```

---

## TransactionContext

トランザクションコンテキスト。

```swift
public struct TransactionContext: Sendable {
    public let transaction: TransactionProtocol

    public init(transaction: TransactionProtocol)

    public mutating func addCommitHook(_ hook: @Sendable @escaping (Result<Void, Error>) -> Void)
}
```

**使用例**:
```swift
try await database.withTransaction { transaction in
    var context = TransactionContext(transaction: transaction)

    // コミット後に実行されるフック
    context.addCommitHook { result in
        switch result {
        case .success:
            print("Committed successfully")
        case .failure(let error):
            print("Commit failed: \(error)")
        }
    }

    try await store.save(user, context: context)
}
```

---

## エラー

### RecordLayerError

Record Layer固有のエラー。

```swift
public enum RecordLayerError: Error {
    case indexNotFound(indexName: String)
    case invalidQuery(reason: String)
    case schemaValidationFailed(errors: [SchemaValidationError])
    case duplicateKey(indexName: String, key: String)
    case recordNotFound(recordType: String, primaryKey: String)
    case invalidArgument(String)
}
```

**使用例**:
```swift
do {
    try await store.save(user, context: context)
} catch RecordLayerError.duplicateKey(let indexName, let key) {
    print("Duplicate key in index '\(indexName)': \(key)")
} catch {
    print("Unexpected error: \(error)")
}
```

---

## まとめ

### よく使うAPI

| 操作 | API | レイヤー |
|------|-----|---------|
| モデル定義 | `@Record`, `@ID` | FDBRecordCore |
| レコード保存 | `store.save(_:context:)` | FDBRecordServer |
| レコード読み込み | `store.load(primaryKey:context:)` | FDBRecordServer |
| レコード削除 | `store.delete(primaryKey:context:)` | FDBRecordServer |
| クエリ実行 | `store.query(_:).where(...).execute()` | FDBRecordServer |
| 集約関数 | `store.evaluateAggregate(_:groupBy:)` | FDBRecordServer |
| インデックス定義 | `IndexDefinition.value(...)` | FDBRecordServer |
| オンラインインデックス | `OnlineIndexer.buildIndex()` | FDBRecordServer |

### 次のステップ

- [アーキテクチャ概要](./architecture-overview.md)を読む
- [設計原則](./design-principles.md)を理解する
- [パッケージ構造](./package-structure-example.md)を確認する
- [マイグレーション計画](./migration-plan.md)に従って実装する
