# FDB Record Layer - Examples

このディレクトリには、FDB Record Layer（マクロAPI）の実践的な使用例が含まれています。

## 前提条件

### 1. FoundationDBのインストールと起動

```bash
# インストール
brew install foundationdb

# 起動
brew services start foundationdb

# 動作確認
fdbcli --exec "status"
```

### 2. プロジェクトのビルド

```bash
cd /path/to/fdb-record-layer
swift build
```

---

## サンプル一覧

### 1. SimpleExample.swift - 基本的な使い方

**内容**:
- `@Recordable`マクロでレコードタイプを定義
- `#Directory`でデータ保存場所を指定
- `#Index`でインデックスを定義
- 基本的なCRUD操作
- KeyPathベースのクエリ

**実行方法**:
```bash
swift run SimpleExample
```

**コード例**:
```swift
@Recordable
struct User {
    #Directory<User>("app", "users", layer: .recordStore)
    #Index<User>([\email])

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32

    @Default(value: Date())
    var createdAt: Date
}

// RecordStoreを開く（自動生成されたメソッド）
let store = try await User.store(database: database, schema: schema)

// 保存
try await store.save(user)

// クエリ
let results = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

**学べること**:
- ✅ マクロAPIの基本
- ✅ レコードの保存・読み取り・更新・削除
- ✅ インデックスを使った検索
- ✅ デフォルト値の使用

---

### 2. MultiTypeExample.swift - 複数のレコードタイプ

**内容**:
- 複数の`@Recordable`型（User、Order）
- `#Directory`でのパーティション（マルチテナント）
- レコード間の関係（外部キー）
- クロスタイプクエリ
- ユニーク制約

**実行方法**:
```bash
swift run MultiTypeExample
```

**コード例**:
```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #Unique<User>([\email])

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
}

@Recordable
struct Order {
    #Directory<Order>("tenants", Field(\Order.accountID), "orders", layer: .partition)
    #Index<Order>([\userID])

    @PrimaryKey var orderID: Int64
    var accountID: String  // パーティションキー
    var userID: Int64      // 外部キー
    var total: Double
}

// 両方の型をスキーマに登録
let schema = Schema([User.self, Order.self])

let userStore = try await User.store(database: database, schema: schema)
let orderStore = try await Order.store(
    accountID: "account-123",
    database: database,
    schema: schema
)
```

**学べること**:
- ✅ 複数のレコードタイプ管理
- ✅ パーティションによるデータ分離
- ✅ 外部キー関係
- ✅ ユニーク制約
- ✅ クロスタイプクエリ

---

### 3. PartitionExample.swift - マルチテナントアーキテクチャ

**内容**:
- マルチレベルパーティション（tenant → channel → messages）
- テナント間のデータ完全分離
- 同じ主キーが異なるパーティションで使用可能
- パーティションごとの統計情報

**実行方法**:
```bash
swift run PartitionExample
```

**コード例**:
```swift
@Recordable
struct Message {
    #Directory<Message>(
        "tenants",
        Field(\Message.tenantID),
        "channels",
        Field(\Message.channelID),
        "messages",
        layer: .partition
    )

    #Index<Message>([\authorID])

    @PrimaryKey var messageID: Int64
    var tenantID: String   // 第1パーティションキー
    var channelID: String  // 第2パーティションキー
    var content: String
}

// テナントA、チャンネル"general"
let tenantAGeneralStore = try await Message.store(
    tenantID: "tenant-A",
    channelID: "general",
    database: database,
    schema: schema
)

// テナントB、チャンネル"general"（完全に分離）
let tenantBGeneralStore = try await Message.store(
    tenantID: "tenant-B",
    channelID: "general",
    database: database,
    schema: schema
)
```

**学べること**:
- ✅ マルチレベルパーティション
- ✅ テナント別データ分離
- ✅ SaaSアプリケーションのアーキテクチャ
- ✅ パーティションごとの分析

---

## サンプル実行の期待される出力

### SimpleExample.swift

```
FDB Record Layer - Macro API Example
=====================================

1. Initializing FoundationDB...
   ✓ Connected to FoundationDB

2. Creating schema...
   ✓ Schema created with User type

3. Opening record store...
   ✓ Record store opened at: app/users

4. Creating sample records...
5. Saving records...
   ✓ Saved 3 records

6. Loading record by primary key (userID = 1)...
   ✓ Found user:
     - ID: 1
     - Name: Alice
     - Email: alice@example.com
     - Age: 30

7. Querying by email (bob@example.com)...
   ✓ Found user: Bob (ID: 2)

8. Querying users aged 30 or older...
   ✓ Found 2 user(s):
     - Alice (age: 30)
     - Charlie (age: 35)

9. Updating Bob's age...
   ✓ Updated Bob's age to 26

10. Verifying update...
   ✓ Bob's age is now: 26

11. Deleting Charlie...
   ✓ Deleted user ID 3

12. Verifying deletion...
   ✓ Charlie successfully deleted

13. Counting remaining users...
   ✓ Total users: 2

Example completed successfully!

Key Features of Macro API:
  • @Recordable - No manual Protobuf files needed
  • #Directory - Type-safe directory paths
  • #Index - Declarative index definitions
  • @PrimaryKey - Explicit primary key marking
  • @Default - Default value support
  • Type-safe queries with KeyPath-based filtering
  • Automatic store() method generation
```

---

## ファイル構造

```
Examples/
├── README.md               # このファイル
├── SimpleExample.swift     # 基本的な使用例
├── MultiTypeExample.swift  # 複数レコードタイプの例
└── PartitionExample.swift  # マルチテナントの例
```

---

## 主要な概念

### 1. @Recordableマクロ

レコードタイプを定義するメインマクロ。

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String
}
```

**自動生成**:
- `Recordable`プロトコル準拠
- Protobufシリアライズメソッド
- `store()`メソッド（`#Directory`と組み合わせた場合）

### 2. #Directoryマクロ

データの保存場所を指定。

```swift
// 静的パス
#Directory<User>("app", "users", layer: .recordStore)

// パーティション（動的パス）
#Directory<Order>(
    "tenants",
    Field(\Order.accountID),
    "orders",
    layer: .partition
)
```

### 3. #Indexマクロ

検索インデックスを定義。

```swift
// 単一インデックス
#Index<User>([\email])

// 複合インデックス
#Index<User>([\city, \age])

// 複数のインデックス
#Index<User>([\email], [\username])
```

### 4. #Uniqueマクロ

ユニーク制約を持つインデックス。

```swift
#Unique<User>([\email])  // emailは一意
```

### 5. @PrimaryKeyマクロ

主キーフィールドを指定（必須）。

```swift
@PrimaryKey var userID: Int64

// 複合主キー
@PrimaryKey var tenantID: String
@PrimaryKey var userID: Int64
```

### 6. @Defaultマクロ

デフォルト値を指定。

```swift
@Default(value: Date())
var createdAt: Date
```

### 7. @Transientマクロ

永続化しないフィールド。

```swift
@Transient var isLoggedIn: Bool = false
```

---

## よくある質問

### Q1: Protobufファイルは必要ですか？

**A**: いいえ、マクロAPIを使用する場合、`.proto`ファイルは不要です。

---

### Q2: 既存のProtobufスキーマと互換性はありますか？

**A**: はい、`#FieldOrder`マクロを使ってフィールド番号を明示的に指定できます。

---

### Q3: どのサンプルから始めるべきですか？

**A**: `SimpleExample.swift`から始めることをお勧めします。基本的な概念がすべて含まれています。

---

### Q4: パーティションはいつ使うべきですか？

**A**: マルチテナントアプリケーション、地理的データ分離、またはセキュリティ要件で厳格なデータ分離が必要な場合に使用してください。

---

## トラブルシューティング

### FoundationDB接続エラー

```
Error: Could not connect to FoundationDB
```

**解決法**:
```bash
# FoundationDBが起動しているか確認
brew services list | grep foundationdb

# 起動していない場合
brew services start foundationdb

# ステータス確認
fdbcli --exec "status"
```

### ビルドエラー

```
error: no such module 'FDBRecordLayer'
```

**解決法**:
```bash
# プロジェクトルートで
swift package clean
swift package resolve
swift build
```

---

## 次のステップ

サンプルを実行したら、以下のドキュメントで詳細を学びましょう：

### ガイド

- **[getting-started.md](../docs/guides/getting-started.md)** - クイックスタートガイド
- **[macro-usage-guide.md](../docs/guides/macro-usage-guide.md)** - 包括的なマクロAPIリファレンス
- **[best-practices.md](../docs/guides/best-practices.md)** - ベストプラクティス

### 設計ドキュメント

- **[swift-macro-design.md](../docs/design/swift-macro-design.md)** - マクロAPIの設計
- **[query-planner-optimization.md](../docs/design/query-planner-optimization.md)** - クエリ最適化
- **[online-index-scrubber.md](../docs/design/online-index-scrubber.md)** - インデックス整合性

### リソース

- **[FoundationDB Documentation](https://apple.github.io/foundationdb/)** - 公式ドキュメント
- **[CLAUDE.md](../CLAUDE.md)** - FoundationDB使い方ガイド

---

**最終更新**: 2025-01-09
**マクロAPI**: ✅ 100%完了
