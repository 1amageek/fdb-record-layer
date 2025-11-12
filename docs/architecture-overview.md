# アーキテクチャ概要

## 概要

FoundationDB Record Layer (Swift) は、クライアント・サーバー間でモデル定義を共有できる3層アーキテクチャを採用しています。

```
┌─────────────────────────────────────────────────────────────────┐
│                         アプリケーション層                          │
├─────────────────────────────┬───────────────────────────────────┤
│      クライアントアプリ         │      サーバーアプリ                │
│    (iOS/macOS/Web)          │      (Vapor/Hummingbird)         │
│                             │                                   │
│  • SwiftUI Views            │  • API Endpoints                  │
│  • ViewModel                │  • Business Logic                 │
│  • Network Layer            │  • Authentication                 │
└─────────────────────────────┴───────────────────────────────────┘
                 ↓                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                      FDBRecordCore（共通）                        │
│                                                                 │
│  • @Record, @ID, @Transient, @Default                          │
│  • Codable対応のモデル定義                                        │
│  • プラットフォーム非依存                                          │
│  • 依存: なし（Swift標準ライブラリのみ）                            │
└─────────────────────────────────────────────────────────────────┘
                              ↓
                 ┌────────────────────────┐
                 │  FDBRecordServer       │
                 │     (サーバー専用)       │
                 │                        │
                 │  • RecordStore         │
                 │  • IndexManager        │
                 │  • QueryPlanner        │
                 │  • #ServerIndex        │
                 │  • #ServerDirectory    │
                 │                        │
                 │  依存: FoundationDB    │
                 └────────────────────────┘
                              ↓
                 ┌────────────────────────┐
                 │    FoundationDB        │
                 │   (分散KVストア)        │
                 └────────────────────────┘
```

---

## レイヤー別詳細

### Layer 1: FDBRecordCore（共通レイヤー）

**目的**: クライアント・サーバー間で共有可能なモデル定義を提供

**特徴**:
- ✅ プラットフォーム非依存（iOS、macOS、Linux）
- ✅ データベース実装に非依存
- ✅ Codable対応（JSON、Protobuf、MessagePack等）
- ✅ 軽量（外部依存なし）

**提供する機能**:
- `@Record`: レコード型マーク
- `@ID`: プライマリキー定義
- `@Transient`: 非永続化フィールド
- `@Default`: デフォルト値
- `Record` プロトコル: 共通インターフェース
- `RecordMetadataDescriptor`: 実行時型情報

**使用例**:
```swift
import FDBRecordCore

@Record
public struct User {
    @ID public var userID: Int64
    public var email: String
    public var name: String

    @Default(value: Date())
    public var createdAt: Date

    @Transient
    public var isLoggedIn: Bool = false
}
```

**パッケージ依存**:
```swift
dependencies: [
    .product(name: "FDBRecordCore", package: "fdb-record-layer")
]
```

---

### Layer 2: FDBRecordServer（サーバーレイヤー）

**目的**: サーバーサイドでの永続化、インデックス、クエリ機能を提供

**特徴**:
- ✅ FoundationDB統合
- ✅ ACID保証のトランザクション
- ✅ 自動インデックス管理
- ✅ コストベースクエリ最適化
- ✅ オンラインスキーマ変更

**提供する機能**:

#### ストレージ
- `RecordStore<Record>`: レコードの永続化
- `Schema`: スキーマ定義と検証
- `RecordSerializer`: Protobufシリアライゼーション

#### インデックス
- `IndexManager`: インデックス管理
- `IndexDefinition<Record>`: インデックス定義
- `#ServerIndex`: インデックス作成マクロ
- `#ServerUnique`: ユニーク制約マクロ

#### クエリ
- `RecordQueryPlanner`: クエリ最適化
- `QueryBuilder<Record>`: 型安全なクエリAPI
- `TypedRecordCursor<Record>`: ストリーミング読み取り

#### ディレクトリ
- `DirectoryConfiguration`: マルチテナント対応
- `#ServerDirectory`: ディレクトリ定義マクロ
- DirectoryLayer統合

**使用例**:
```swift
import FDBRecordCore
import FDBRecordServer

extension User {
    // インデックス定義
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email]),
        .unique(name: "email_unique", keyPaths: [\.email]),
    ]

    // RecordStoreを開く
    static func openStore(
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<User> {
        let dir = try await database.directoryLayer.createOrOpen(
            path: ["app", "users"],
            type: nil
        )

        return RecordStore(
            database: database,
            subspace: dir.subspace,
            schema: schema,
            indexes: serverIndexes
        )
    }
}

// 使用
let store = try await User.openStore(database: db, schema: schema)
try await store.save(user)

let users = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

**パッケージ依存**:
```swift
dependencies: [
    .product(name: "FDBRecordServer", package: "fdb-record-layer")
]
```

---

### Layer 3: FDBRecordClient（クライアントレイヤー、将来実装）

**目的**: クライアントサイドでの同期、キャッシュ、オフライン機能を提供

**提供予定の機能**:
- `RecordSyncManager`: サーバーとの自動同期
- `RecordCache`: ローカルキャッシュ
- `ConflictResolver`: 競合解決戦略
- オフライン対応
- 変更追跡（Change Tracking）

**使用予定例**:
```swift
import FDBRecordCore
import FDBRecordClient

let syncManager = RecordSyncManager<User>(
    apiEndpoint: "https://api.example.com/users",
    syncStrategy: .realtime
)

// ローカルキャッシュから読み取り
let users = try await syncManager.fetchAll()

// 変更を追跡
syncManager.observe { change in
    switch change {
    case .inserted(let user):
        print("New user: \(user.name)")
    case .updated(let user):
        print("Updated user: \(user.name)")
    case .deleted(let userID):
        print("Deleted user: \(userID)")
    }
}
```

---

## データフロー

### クライアント → サーバー → FoundationDB

```
┌─────────────┐
│   Client    │
│   (SwiftUI) │
└──────┬──────┘
       │ HTTP/WebSocket
       │ JSON
       ↓
┌─────────────┐
│   Server    │
│   (Vapor)   │
└──────┬──────┘
       │ FDBRecordServer API
       │ RecordStore.save()
       ↓
┌─────────────┐
│ RecordStore │
│ + Index     │
└──────┬──────┘
       │ fdb-swift-bindings
       │ Transaction
       ↓
┌─────────────┐
│FoundationDB │
│  (Cluster)  │
└─────────────┘
```

### クエリフロー

```
1. Client: APIリクエスト
   GET /users?email=alice@example.com

2. Server: クエリ実行
   store.query(User.self)
       .where(\.email, .equals, "alice@example.com")
       .execute()

3. QueryPlanner: インデックス選択
   - email_index を使用（コストベース最適化）

4. IndexManager: インデックススキャン
   - email_index から該当レコードのキーを取得

5. RecordStore: レコード読み取り
   - プライマリキーでレコード取得

6. Server: JSON レスポンス
   [{"userID": 1, "email": "alice@example.com", "name": "Alice"}]

7. Client: デコード & 表示
   let users = try JSONDecoder().decode([User].self, from: data)
```

---

## スキーマ進化

### スキーマバージョン管理

```swift
public struct Schema: Sendable {
    public let version: Int
    public let recordTypes: [any Record.Type]

    public init(version: Int = 1, _ recordTypes: [any Record.Type]) {
        self.version = version
        self.recordTypes = recordTypes
    }
}

// バージョン1
let schemaV1 = Schema(version: 1, [User.self, Order.self])

// バージョン2（新しいフィールド追加）
@Record
struct User {
    @ID var userID: Int64
    var email: String
    var name: String

    @Default(value: "active")  // 新フィールド（デフォルト値あり）
    var status: String
}

let schemaV2 = Schema(version: 2, [User.self, Order.self])
```

### マイグレーション戦略

```swift
// オンラインマイグレーション（インデックス追加）
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

// バックグラウンドで構築
try await indexer.buildIndex()

// 進行状況監視
let progress = try await indexer.getProgress()
print("Progress: \(progress.percentage)%")
```

---

## マルチテナント対応

### Partition Directory Layer

```swift
@Record
struct Order {
    @ID var orderID: Int64
    var tenantID: String
    var userID: Int64
    var amount: Double
}

extension Order {
    static let serverDirectory: DirectoryConfiguration = .init(
        pathTemplate: [
            .literal("tenants"),
            .field(\Order.tenantID),  // 動的パーティション
            .literal("orders")
        ],
        layerType: .partition
    )

    // テナント別にRecordStoreを開く
    static func openStore(
        tenantID: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<Order> {
        let dir = try await database.directoryLayer.createOrOpen(
            path: ["tenants", tenantID, "orders"],
            type: .partition
        )

        return RecordStore(
            database: database,
            subspace: dir.subspace,
            schema: schema,
            indexes: serverIndexes
        )
    }
}

// 使用
let tenant1Store = try await Order.openStore(tenantID: "tenant-123", ...)
let tenant2Store = try await Order.openStore(tenantID: "tenant-456", ...)

// 完全に分離されたストレージ
try await tenant1Store.save(order1)  // tenant-123 のみに保存
try await tenant2Store.save(order2)  // tenant-456 のみに保存
```

---

## パフォーマンス特性

### インデックスタイプ別の性能

| インデックスタイプ | 書き込み | 読み取り | 集約 | 用途 |
|------------------|---------|---------|------|------|
| **VALUE** | O(log n) | O(log n) | O(k) | 基本的な検索、Range読み取り |
| **COUNT** | O(1) | O(1) | O(1) | グループ別カウント |
| **SUM** | O(1) | O(1) | O(1) | グループ別合計 |
| **MIN/MAX** | O(log n) | O(log n) | O(log n) | 最小/最大値 |
| **UNIQUE** | O(log n) | O(log n) | - | 一意性制約 |

### トランザクション制限

| 項目 | デフォルト | 調整可能 | 備考 |
|------|-----------|---------|------|
| キーサイズ | 10KB | ❌ | 変更不可 |
| 値サイズ | 100KB | ❌ | 変更不可 |
| トランザクションサイズ | 10MB | ✅ | `sizeLimit`で設定 |
| 実行時間 | 5秒 | ✅ | `timeout`で設定 |
| 読み取り数 | 制限なし | - | ただしメモリに注意 |
| 書き込み数 | 制限なし | - | サイズ制限の範囲内 |

### バッチ処理のベストプラクティス

```swift
// 大量のレコードを保存（バッチ処理）
let batchSize = 1000

for batch in records.chunked(into: batchSize) {
    try await database.withTransaction { transaction in
        for record in batch {
            try await store.save(record, context: .init(transaction: transaction))
        }
    }
}

// オンラインインデックス構築（中断可能）
let indexer = OnlineIndexer(...)
try await indexer.buildIndex()  // RangeSetで進行状況を記録

// 中断後に再開
try await indexer.buildIndex()  // 未完了部分のみを処理
```

---

## セキュリティ考慮事項

### テナント分離

```swift
// Partition Directory Layer使用時、テナント間は完全に分離
// - 異なるプレフィックスを使用
// - 誤ったテナントデータへのアクセスは不可能（キーが存在しない）

// ❌ 悪い例（手動でテナントを管理）
let key = recordSubspace.pack(Tuple(tenantID, recordID))

// ✅ 良い例（Partition Directory Layer）
let dir = try await database.directoryLayer.createOrOpen(
    path: ["tenants", tenantID, "records"],
    type: .partition
)
```

### アクセス制御

```swift
// サーバー側でテナントIDを検証
func getOrders(tenantID: String, authenticatedUser: User) async throws -> [Order] {
    // 認証ユーザーのテナントIDと一致するか確認
    guard authenticatedUser.tenantID == tenantID else {
        throw AuthorizationError.forbidden
    }

    let store = try await Order.openStore(tenantID: tenantID, ...)
    return try await store.query(Order.self).execute()
}
```

---

## モニタリング

### メトリクス

```swift
import Metrics

// RecordStoreが自動的にメトリクスを記録
Counter(label: "fdb_record_save_count")
Histogram(label: "fdb_record_save_duration_ms")
Counter(label: "fdb_record_query_count")
Histogram(label: "fdb_record_query_duration_ms")
Gauge(label: "fdb_index_size_bytes")
```

### Prometheus統合

```swift
import SwiftPrometheus

let prometheusClient = PrometheusClient()
MetricsSystem.bootstrap(PrometheusMetricsFactory(client: prometheusClient))

// Prometheusエンドポイント
app.get("metrics") { req -> String in
    prometheusClient.collect()
}
```

---

## まとめ

### 設計の利点

1. **クリーンな分離**: クライアント・サーバー間で明確な責任分離
2. **型安全性**: 同じモデル定義を使用、型の不一致なし
3. **スケーラビリティ**: FoundationDBの分散特性を活用
4. **柔軟性**: 将来的な拡張が容易（新しいインデックスタイプ、バックエンド対応など）
5. **保守性**: 各レイヤーが独立してテスト・デプロイ可能

### ユースケース

- **マルチテナントSaaS**: Partition Directory Layerで完全分離
- **大規模API**: コストベースクエリ最適化で高速応答
- **リアルタイムアプリ**: トランザクション保証で一貫性維持
- **モバイルアプリ**: 軽量なFDBRecordCoreでモデル共有

### 次のステップ

1. [パッケージ構造](./package-structure-example.md) を確認
2. [マイグレーション計画](./migration-plan.md) に従って実装
3. [設計原則](./design-principles.md) を理解
4. [APIリファレンス](./api-reference.md) を参照
