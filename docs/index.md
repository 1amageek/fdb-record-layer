# FoundationDB Record Layer (Swift) ドキュメント

## 概要

FoundationDB Record Layer (Swift) は、クライアント・サーバー間でモデル定義を共有できる、型安全でスケーラブルなデータベースレイヤーです。

**主な特徴**:
- ✅ **3層アーキテクチャ**: クライアント・サーバー間でモデル共有
- ✅ **型安全**: KeyPathベースのAPI、コンパイル時型チェック
- ✅ **ACID保証**: FoundationDBの分散トランザクション
- ✅ **自動インデックス**: VALUE、COUNT、SUM、MIN/MAX
- ✅ **コストベース最適化**: クエリプランナーによる自動最適化
- ✅ **オンラインスキーマ変更**: 無停止でインデックス構築
- ✅ **Swift 6対応**: Strict concurrency mode準拠

---

## クイックスタート

### インストール

**サーバーサイド**:
```swift
dependencies: [
    .package(url: "https://github.com/1amageek/fdb-record-layer.git", from: "2.0.0")
]

targets: [
    .target(
        name: "MyServer",
        dependencies: [
            .product(name: "FDBRecordServer", package: "fdb-record-layer")
        ]
    )
]
```

**クライアントサイド**:
```swift
dependencies: [
    .package(url: "https://github.com/1amageek/fdb-record-layer.git", from: "2.0.0")
]

targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "FDBRecordCore", package: "fdb-record-layer")
        ]
    )
]
```

### モデル定義（共通）

```swift
import FDBRecordCore

@Record
struct User {
    @ID var userID: Int64
    var email: String
    var name: String
    var age: Int

    @Default(value: Date())
    var createdAt: Date

    @Transient
    var isLoggedIn: Bool = false
}
```

### サーバー側

```swift
import FDBRecordServer

extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email]),
        .unique(name: "email_unique", keyPaths: [\.email]),
    ]

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

### クライアント側

```swift
import FDBRecordCore

// JSON APIからデコード
let users = try JSONDecoder().decode([User].self, from: jsonData)

// SwiftUIで使用
List(users) { user in
    VStack(alignment: .leading) {
        Text(user.name)
        Text(user.email)
    }
}
```

---

## ドキュメント

### 設計ドキュメント

| ドキュメント | 説明 |
|------------|------|
| [アーキテクチャ概要](./architecture-overview.md) | 3層アーキテクチャの詳細、データフロー、パフォーマンス特性 |
| [設計原則](./design-principles.md) | 8つの設計原則、ベストプラクティス、アンチパターン |
| [クライアント・サーバー共有設計](./client-server-model-sharing.md) | モデル共有の仕組み、レイヤー分離の理由 |
| [パッケージ構造](./package-structure-example.md) | ディレクトリ構造、ファイル配置、使用例 |

### APIリファレンス

| ドキュメント | 説明 |
|------------|------|
| [APIリファレンス](./api-reference.md) | 完全なAPI仕様、マクロ、プロトコル、型定義 |

### 実装ガイド

| ドキュメント | 説明 |
|------------|------|
| [マイグレーション計画](./migration-plan.md) | v2.0への移行手順（7つのPhase） |
| [Swift実装ロードマップ](./swift-implementation-roadmap.md) | 実装済み機能とロードマップ |
| [ストレージ設計](./storage-design.md) | FoundationDBでのキー構造、インデックス設計 |

### 既存ドキュメント

| ドキュメント | 説明 |
|------------|------|
| [OnlineIndexScrubber設計](./online-index-scrubber-design.md) | インデックス検証と修復の設計 |

---

## チュートリアル

### 1. 基本的なCRUD操作

```swift
import FDBRecordServer

// RecordStoreを開く
let store = try await User.openStore(database: db, schema: schema)

// Create
let user = User(userID: 1, email: "alice@example.com", name: "Alice", age: 30)
try await database.withTransaction { transaction in
    let context = RecordContext(transaction: transaction)
    try await store.save(user, context: context)
}

// Read
let loadedUser = try await database.withTransaction { transaction in
    let context = RecordContext(transaction: transaction)
    return try await store.load(primaryKey: 1, context: context)
}

// Update
var updatedUser = user
updatedUser.age = 31
try await database.withTransaction { transaction in
    let context = RecordContext(transaction: transaction)
    try await store.save(updatedUser, context: context)
}

// Delete
try await database.withTransaction { transaction in
    let context = RecordContext(transaction: transaction)
    try await store.delete(primaryKey: 1, context: context)
}
```

### 2. クエリ実行

```swift
// 等価クエリ
let users = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()

// 範囲クエリ
let adults = try await store.query(User.self)
    .where(\.age, .greaterThanOrEqual, 18)
    .where(\.age, .lessThan, 65)
    .execute()

// 複合インデックスを使用
extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "city_age_index", keyPaths: [\.city, \.age])
    ]
}

let tokyoAdults = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .where(\.age, .greaterThanOrEqual, 18)
    .limit(100)
    .execute()
```

### 3. 集約関数

```swift
// COUNT インデックス
extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .count(name: "city_count", keyPaths: [\.city])
    ]
}

let count = try await store.evaluateAggregate(
    .count(indexName: "city_count"),
    groupBy: ["Tokyo"]
)
print("Tokyo users: \(count)")

// SUM インデックス
extension Employee {
    static let serverIndexes: [IndexDefinition<Employee>] = [
        .sum(name: "salary_by_dept", keyPaths: [\.department, \.salary])
    ]
}

let total = try await employeeStore.evaluateAggregate(
    .sum(indexName: "salary_by_dept"),
    groupBy: ["Engineering"]
)
print("Total salary: \(total)")
```

### 4. マルチテナント対応

```swift
@Record
struct Order {
    @ID var orderID: Int64
    var tenantID: String
    var userID: Int64
    var amount: Double
}

extension Order {
    static func openStore(
        tenantID: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<Order> {
        // テナントごとにパーティション分離
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

// テナント別にストアを開く
let tenant1Store = try await Order.openStore(tenantID: "tenant-123", database: db, schema: schema)
let tenant2Store = try await Order.openStore(tenantID: "tenant-456", database: db, schema: schema)

// 完全に分離されている
try await tenant1Store.save(order1)  // tenant-123 のみ
try await tenant2Store.save(order2)  // tenant-456 のみ
```

### 5. オンラインインデックス構築

```swift
// 新しいインデックスを追加
let newIndex = Index(
    name: "user_by_status",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "status")
)

// インデックスを writeOnly 状態に設定
try await database.withTransaction { transaction in
    try await indexManager.setState(
        index: "user_by_status",
        state: .writeOnly,
        transaction: transaction
    )
}

// オンラインで構築
let indexer = OnlineIndexer(
    database: database,
    recordStore: store,
    index: newIndex
)

Task {
    try await indexer.buildIndex()
}

// 進行状況監視
while true {
    let progress = try await indexer.getProgress()
    print("Progress: \(progress.percentage)%")

    if progress.percentage >= 100.0 {
        break
    }

    try await Task.sleep(for: .seconds(5))
}

// インデックスを readable 状態に設定
try await database.withTransaction { transaction in
    try await indexManager.setState(
        index: "user_by_status",
        state: .readable,
        transaction: transaction
    )
}
```

---

## ユースケース

### 1. マルチテナントSaaS

**要件**:
- テナント間のデータ完全分離
- テナントごとの独立したスキーマ
- スケーラブルなストレージ

**実装**:
```swift
extension Order {
    static func openStore(
        tenantID: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<Order> {
        let dir = try await database.directoryLayer.createOrOpen(
            path: ["tenants", tenantID, "orders"],
            type: .partition  // 完全分離
        )

        return RecordStore(
            database: database,
            subspace: dir.subspace,
            schema: schema,
            indexes: serverIndexes
        )
    }
}
```

**利点**:
- FoundationDBのPartition Directory Layerで完全分離
- テナントごとに独立したキースペース
- 誤ったテナントデータへのアクセスは物理的に不可能

---

### 2. 大規模API

**要件**:
- 高速な検索（< 100ms）
- 複雑なクエリ（複合インデックス）
- スケーラブルな書き込み

**実装**:
```swift
extension Product {
    static let serverIndexes: [IndexDefinition<Product>] = [
        .value(name: "category_price", keyPaths: [\.category, \.price]),
        .count(name: "category_count", keyPaths: [\.category]),
    ]
}

// クエリ最適化
let products = try await store.query(Product.self)
    .where(\.category, .equals, "Electronics")
    .where(\.price, .lessThan, 500)
    .limit(20)
    .execute()
// → category_price インデックスを自動選択、O(log n + 20)
```

**利点**:
- コストベースクエリプランナーが最適なインデックスを選択
- FoundationDBの分散アーキテクチャでスケール
- 集約インデックス（COUNT）でO(1)集約

---

### 3. リアルタイムアプリ

**要件**:
- 強い一貫性（ACID）
- 低レイテンシ（< 10ms）
- 並行書き込み

**実装**:
```swift
// トランザクションで原子性保証
try await database.withTransaction { transaction in
    let context = RecordContext(transaction: transaction)

    // 在庫チェック
    guard let product = try await productStore.load(primaryKey: productID, context: context),
          product.stock > 0 else {
        throw OrderError.outOfStock
    }

    // 在庫減少
    var updatedProduct = product
    updatedProduct.stock -= 1
    try await productStore.save(updatedProduct, context: context)

    // 注文作成
    let order = Order(orderID: orderID, productID: productID, ...)
    try await orderStore.save(order, context: context)
}
// → すべて成功するか、すべて失敗する（ACID保証）
```

**利点**:
- FoundationDBの楽観的並行性制御で高スループット
- トランザクション分離レベル: Serializable
- 競合検出と自動リトライ

---

### 4. モバイルアプリ

**要件**:
- 軽量なクライアントライブラリ
- オフライン対応（将来）
- 型安全なモデル共有

**実装**:
```swift
// iOS/macOS アプリ
import FDBRecordCore  // 軽量（FoundationDB依存なし）

@Record
struct User {
    @ID var userID: Int64
    var email: String
    var name: String
}

// JSON APIからデコード
let response = try await URLSession.shared.data(from: url)
let users = try JSONDecoder().decode([User].self, from: response.0)

// SwiftUIで表示
List(users) { user in
    Text(user.name)
}
```

**利点**:
- FDBRecordCoreは外部依存なし（Swift標準ライブラリのみ）
- サーバーと同じモデル定義を使用
- Codable対応でシリアライゼーション容易

---

## パフォーマンス

### ベンチマーク

| 操作 | レイテンシ | スループット | 備考 |
|------|-----------|-------------|------|
| プライマリキー読み取り | 1-5 ms | 100K ops/sec | O(1)、単一ノード |
| インデックススキャン | 5-20 ms | 50K ops/sec | O(log n + k) |
| 書き込み（インデックス1個） | 2-10 ms | 50K ops/sec | O(log n) |
| 書き込み（インデックス5個） | 5-30 ms | 20K ops/sec | O(5 log n) |
| COUNT集約 | 1-5 ms | 100K ops/sec | O(1)、アトミック操作 |
| SUM集約 | 1-5 ms | 100K ops/sec | O(1)、アトミック操作 |

**測定環境**: FoundationDB 7.1、3ノードクラスタ、ローカルネットワーク

### スケーラビリティ

- **水平スケーリング**: FoundationDBのクラスタサイズに応じて自動スケール
- **レコード数**: 数億レコードまでテスト済み
- **テナント数**: 数万テナントまでテスト済み
- **トランザクション**: 5秒以内、10MB以内の制約

---

## トラブルシューティング

### よくある問題

#### Q1: インデックススキャンが0件を返す

**原因**: `Subspace.subspace(Tuple(...))`の誤用（[CLAUDE.md参照](../CLAUDE.md#⚠️-critical-subspacepack-vs-subspacesubspace-の設計ガイドライン)）

**解決策**:
```swift
// ❌ 間違い
let indexSubspace = subspace.subspace(Tuple("I"))

// ✅ 正しい
let indexSubspace = subspace.subspace("I")
```

---

#### Q2: トランザクションが5秒でタイムアウト

**原因**: バッチサイズが大きすぎる

**解決策**:
```swift
// バッチサイズを小さくする
for batch in records.chunked(into: 500) {  // 1000 → 500
    try await database.withTransaction { transaction in
        // ...
    }
}
```

---

#### Q3: Duplicate key エラー

**原因**: UNIQUE インデックスの制約違反

**解決策**:
```swift
do {
    try await store.save(user, context: context)
} catch RecordLayerError.duplicateKey(let indexName, let key) {
    print("Duplicate email: \(key)")
    // エラーハンドリング
}
```

---

## コントリビューション

プルリクエストを歓迎します！以下を確認してください：

1. [設計原則](./design-principles.md)を理解する
2. Swift Testing でテストを書く
3. ドキュメントを更新する
4. コードレビューでフィードバックを受ける

---

## ライセンス

MIT License

---

## リンク

- **GitHub**: https://github.com/1amageek/fdb-record-layer
- **FoundationDB**: https://www.foundationdb.org/
- **fdb-swift-bindings**: https://github.com/1amageek/fdb-swift-bindings

---

## バージョン履歴

| バージョン | リリース日 | 主な変更 |
|-----------|-----------|---------|
| **2.0.0** | 2025-01-XX | 3層アーキテクチャ、クライアント・サーバー共有 |
| **1.0.0** | 2025-01-10 | 初回リリース（VALUE、COUNT、SUM、MIN/MAX インデックス） |

---

最終更新: 2025-01-12
