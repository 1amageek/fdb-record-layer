# FDB Record Layer - クイックスタートガイド

このガイドでは、FDB Record Layerを使った最初のアプリケーションを**10分**で作成する手順を説明します。

## 目次

1. [前提条件](#前提条件)
2. [FoundationDBのセットアップ](#foundationdbのセットアップ)
3. [プロジェクトのセットアップ](#プロジェクトのセットアップ)
4. [最初のレコードタイプを作成](#最初のレコードタイプを作成)
5. [データベース操作](#データベース操作)
6. [次のステップ](#次のステップ)

---

## 前提条件

- **Swift 6.0以降**
- **macOS 15.0以降**
- **FoundationDB 7.1.0以降**

---

## FoundationDBのセットアップ

### インストール

#### Homebrewを使用（推奨）

```bash
brew install foundationdb
```

#### 手動インストール

1. [FoundationDB公式サイト](https://www.foundationdb.org/download/)からダウンロード
2. インストーラーを実行

### 起動と確認

```bash
# FoundationDBを起動
brew services start foundationdb

# または手動起動（macOS）
sudo launchctl load /Library/LaunchDaemons/com.foundationdb.fdbserver.plist

# 動作確認
fdbcli --exec "status"
```

**期待される出力**:
```
Using cluster file `/usr/local/etc/foundationdb/fdb.cluster'.

Configuration:
  Redundancy mode        - single
  Storage engine         - ssd-redwood-v1
  Coordinators           - 1
  ...

Database available
```

---

## プロジェクトのセットアップ

### 1. 新しいSwiftプロジェクトを作成

```bash
mkdir my-fdb-app
cd my-fdb-app
swift package init --type executable
```

### 2. Package.swiftに依存関係を追加

`Package.swift`を編集：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "my-fdb-app",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/1amageek/fdb-record-layer.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "my-fdb-app",
            dependencies: [
                .product(name: "FDBRecordLayer", package: "fdb-record-layer")
            ]
        )
    ]
)
```

### 3. 依存関係を解決

```bash
swift build
```

---

## 最初のレコードタイプを作成

`Sources/my-fdb-app/main.swift`を作成：

```swift
import Foundation
import FoundationDB
import FDBRecordLayer

// MARK: - レコード定義

@Recordable
struct User {
    // ディレクトリパス: app/users
    #Directory<User>("app", "users", layer: .recordStore)

    // インデックス: emailで検索可能にする
    #Index<User>([\email])

    // 主キー
    @PrimaryKey var userID: Int64

    // フィールド
    var name: String
    var email: String
    var age: Int32

    // デフォルト値
    @Default(value: Date())
    var createdAt: Date
}

// MARK: - メイン処理

@main
struct MyApp {
    static func main() async throws {
        print("FDB Record Layer - Getting Started")
        print("===================================\n")

        // 1. FoundationDBに接続
        print("Connecting to FoundationDB...")
        try await FDB.startNetwork()
        let database = try await FDB.open()
        print("✓ Connected\n")

        // 2. スキーマを作成
        print("Creating schema...")
        let schema = Schema([User.self])
        print("✓ Schema created\n")

        // 3. RecordStoreを開く（マクロが自動生成したメソッド）
        print("Opening record store...")
        let store = try await User.store(database: database, schema: schema)
        print("✓ Store opened\n")

        // 4. ユーザーを作成して保存
        print("Creating and saving a user...")
        let alice = User(
            userID: 1,
            name: "Alice",
            email: "alice@example.com",
            age: 30,
            createdAt: Date()
        )
        try await store.save(alice)
        print("✓ Saved: \(alice.name)\n")

        // 5. 主キーで読み取り
        print("Loading user by primary key (userID = 1)...")
        if let user: User = try await store.fetch(by: Int64(1)) {
            print("✓ Found:")
            print("  Name: \(user.name)")
            print("  Email: \(user.email)")
            print("  Age: \(user.age)\n")
        }

        // 6. インデックスで検索
        print("Querying by email...")
        let results = try await store.query(User.self)
            .where(\.email, .equals, "alice@example.com")
            .execute()

        if let found = results.first {
            print("✓ Found by email: \(found.name)\n")
        }

        // 7. 更新
        print("Updating user...")
        var updatedAlice = alice
        updatedAlice.age = 31
        try await store.save(updatedAlice)
        print("✓ Updated age to 31\n")

        // 8. 削除
        print("Deleting user...")
        try await store.delete(by: Int64(1))
        print("✓ Deleted\n")

        print("Done! You've successfully used FDB Record Layer.")
    }
}
```

---

## データベース操作

### プログラムを実行

```bash
swift run
```

**期待される出力**:

```
FDB Record Layer - Getting Started
===================================

Connecting to FoundationDB...
✓ Connected

Creating schema...
✓ Schema created

Opening record store...
✓ Store opened

Creating and saving a user...
✓ Saved: Alice

Loading user by primary key (userID = 1)...
✓ Found:
  Name: Alice
  Email: alice@example.com
  Age: 30

Querying by email...
✓ Found by email: Alice

Updating user...
✓ Updated age to 31

Deleting user...
✓ Deleted

Done! You've successfully used FDB Record Layer.
```

---

## コードの解説

### 1. @Recordableマクロ

```swift
@Recordable
struct User {
    // ...
}
```

- レコードタイプを定義
- Protobufシリアライズを自動生成
- `Recordable`プロトコルに準拠

### 2. #Directoryマクロ

```swift
#Directory<User>("app", "users", layer: .recordStore)
```

- データの保存場所を指定
- `app/users`パスに保存
- 自動的に`store()`メソッドを生成

### 3. #Indexマクロ

```swift
#Index<User>([\email])
```

- `email`フィールドにインデックスを作成
- 高速検索が可能

### 4. @PrimaryKeyマクロ

```swift
@PrimaryKey var userID: Int64
```

- 主キーを指定
- レコードを一意に識別

### 5. @Defaultマクロ

```swift
@Default(value: Date())
var createdAt: Date
```

- デフォルト値を設定
- 値がない場合に使用

---

## 次のステップ

おめでとうございます！最初のFDB Record Layerアプリケーションが完成しました。

次は以下を試してみましょう：

### 1. インデックスの追加

```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #Index<User>([\email])
    #Index<User>([\age])  // 年齢インデックスを追加

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32
}

// 年齢範囲で検索
let adults = try await store.query(User.self)
    .where(\.age, .greaterThanOrEquals, Int32(18))
    .execute()
```

### 2. 複合インデックス

```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #Index<User>([\city, \age])  // 都市と年齢の複合インデックス

    @PrimaryKey var userID: Int64
    var name: String
    var city: String
    var age: Int32
}

// 都市と年齢で検索
let results = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .where(\.age, .greaterThanOrEquals, Int32(30))
    .execute()
```

### 3. ユニーク制約

```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #Index<User>([\email])
    #Unique<User>([\email])  // emailは一意

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
}

// 重複したemailは保存できない
```

### 4. 複数のレコードタイプ

```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    @PrimaryKey var userID: Int64
    var name: String
}

@Recordable
struct Order {
    #Directory<Order>("app", "orders")
    #Index<Order>([\userID])

    @PrimaryKey var orderID: Int64
    var userID: Int64  // 外部キー
    var total: Double
}

// 両方の型をスキーマに登録
let schema = Schema([User.self, Order.self])

let userStore = try await User.store(database: database, schema: schema)
let orderStore = try await Order.store(database: database, schema: schema)
```

### 5. マルチテナント（パーティション）

```swift
@Recordable
struct TenantData {
    #Directory<TenantData>(
        "tenants",
        Field(\TenantData.tenantID),
        "data",
        layer: .partition
    )

    @PrimaryKey var dataID: Int64
    var tenantID: String  // パーティションキー
    var content: String
}

// テナントごとに分離されたストア
let tenantAStore = try await TenantData.store(
    tenantID: "tenant-A",
    database: database,
    schema: schema
)

let tenantBStore = try await TenantData.store(
    tenantID: "tenant-B",
    database: database,
    schema: schema
)
```

---

## リソース

### ドキュメント

- **[macro-usage-guide.md](./macro-usage-guide.md)** - 包括的なマクロAPIリファレンス
- **[best-practices.md](./best-practices.md)** - ベストプラクティス
- **[query-optimizer.md](./query-optimizer.md)** - クエリ最適化ガイド

### サンプルコード

- **[SimpleExample.swift](../../Examples/SimpleExample.swift)** - 基本的な使用例
- **[MultiTypeExample.swift](../../Examples/MultiTypeExample.swift)** - 複数レコードタイプ
- **[PartitionExample.swift](../../Examples/PartitionExample.swift)** - マルチテナント

### コミュニティ

- **[FoundationDB Forums](https://forums.foundationdb.org/)** - コミュニティフォーラム
- **[GitHub Issues](https://github.com/1amageek/fdb-record-layer/issues)** - バグ報告・機能リクエスト

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
# 依存関係を再解決
swift package clean
swift package resolve
swift build
```

### マクロ展開エラー

```
error: external macro implementation type 'RecordableMacro' could not be found
```

**解決法**:
1. `Package.swift`の依存関係が正しいか確認
2. プロジェクトをクリーンビルド: `swift build --clean`

---

## まとめ

このガイドでは以下を学びました：

- ✅ FoundationDBのインストールと起動
- ✅ FDB Record Layerのセットアップ
- ✅ `@Recordable`マクロでレコードタイプを定義
- ✅ `#Directory`でデータの保存場所を指定
- ✅ `#Index`で検索インデックスを作成
- ✅ 基本的なCRUD操作（作成・読み取り・更新・削除）
- ✅ KeyPathベースのクエリAPI

次のステップとして、[macro-usage-guide.md](./macro-usage-guide.md)で高度な機能を学ぶか、[Examples/](../../Examples/)のサンプルコードを実行してみましょう。

---

**最終更新**: 2025-01-09
**バージョン**: 1.0.0
