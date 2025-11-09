# FDB Record Layer - Macro API 使用ガイド

このガイドでは、FDB Record LayerのSwiftData風マクロAPIの使用方法を包括的に説明します。

## 目次

1. [概要](#概要)
2. [基本的な使い方](#基本的な使い方)
3. [マクロ一覧](#マクロ一覧)
4. [実践例](#実践例)
5. [トラブルシューティング](#トラブルシューティング)
6. [よくある質問](#よくある質問)

---

## 概要

### マクロAPIとは

FDB Record LayerのマクロAPIは、**SwiftDataに似た宣言的なAPI**を提供し、Protobufファイルを手動で作成する必要をなくします。

### 主な利点

| 利点 | 説明 |
|------|------|
| **Protobuf不要** | `.proto`ファイルを手動で作成・管理する必要がない |
| **型安全性** | コンパイル時にすべてのフィールドとインデックスを検証 |
| **宣言的** | レコード定義がシンプルで読みやすい |
| **自動生成** | シリアライズ、デシリアライズ、ストア作成メソッドが自動生成 |
| **SwiftData互換** | 学習コストが低い（SwiftData経験者にとって親しみやすい） |

---

## 基本的な使い方

### ステップ1: レコードタイプの定義

`@Recordable`マクロでレコードタイプを定義します。

```swift
import FDBRecordLayer

@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32
}
```

### ステップ2: ディレクトリパスの指定（オプション）

`#Directory`マクロでデータの保存場所を指定します。

```swift
@Recordable
struct User {
    #Directory<User>("app", "users", layer: .recordStore)

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
}
```

### ステップ3: インデックスの定義（オプション）

`#Index`マクロで検索用インデックスを定義します。

```swift
@Recordable
struct User {
    #Directory<User>("app", "users", layer: .recordStore)
    #Index<User>([\email])
    #Index<User>([\age])

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32
}
```

### ステップ4: RecordStoreの作成

`@Recordable`が自動生成した`store()`メソッドを使用します。

```swift
import FoundationDB

// データベース接続
let database = try await FDB.open()

// スキーマ作成
let schema = Schema([User.self])

// RecordStore作成（自動生成されたメソッド）
let store = try await User.store(database: database, schema: schema)
```

### ステップ5: CRUD操作

```swift
// 作成
let user = User(userID: 1, name: "Alice", email: "alice@example.com", age: 30)
try await store.save(user)

// 読み取り
if let user: User = try await store.fetch(by: Int64(1)) {
    print("Found: \(user.name)")
}

// 更新
var updatedUser = user
updatedUser.age = 31
try await store.save(updatedUser)

// 削除
try await store.delete(by: Int64(1))
```

### ステップ6: クエリ

```swift
// 単純なクエリ
let adults = try await store.query(User.self)
    .where(\.age, .greaterThanOrEquals, Int32(18))
    .execute()

// 複数条件
let results = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .where(\.age, .greaterThan, Int32(25))
    .execute()
```

---

## マクロ一覧

### 1. @Recordable

レコードタイプを定義するメインマクロ。

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String
}
```

**生成されるコード**:
- `Recordable`プロトコル準拠
- `toProtobuf()` / `fromProtobuf()`メソッド
- `fieldName(for:)`メソッド
- `primaryKeyFields`静的プロパティ
- `allFields`静的プロパティ

**パラメータ**:
- `recordName: String?` - カスタムレコード名（デフォルト: 構造体名）

```swift
@Recordable(recordName: "UserRecord")
struct User {
    // ...
}
```

---

### 2. @PrimaryKey

主キーフィールドを指定します（**必須**）。

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64  // 単一主キー
    var name: String
}
```

**複合主キー**（複数フィールドに`@PrimaryKey`を付与）:

```swift
@Recordable
struct TenantUser {
    @PrimaryKey var tenantID: String
    @PrimaryKey var userID: Int64  // 複合主キー
    var name: String
}
```

**制約**:
- 最低1つの`@PrimaryKey`が必須
- 主キーの順序は宣言順

---

### 3. #Directory

ディレクトリパスとレイヤーを指定します（オプション）。

#### 基本的な使用法（静的パス）

```swift
@Recordable
struct User {
    #Directory<User>("app", "users", layer: .recordStore)

    @PrimaryKey var userID: Int64
    var name: String
}
```

**生成されるメソッド**:

```swift
// 自動生成
extension User {
    static func openDirectory(database: any DatabaseProtocol) async throws -> DirectorySubspace

    static func store(database: any DatabaseProtocol, schema: Schema) async throws -> RecordStore<User>
}
```

#### パーティション（動的パス）

`Field()`を使ってレコードのフィールドをパスに含めます。

```swift
@Recordable
struct Order {
    #Directory<Order>(
        "tenants",
        Field(\Order.accountID),
        "orders",
        layer: .partition
    )

    @PrimaryKey var orderID: Int64
    var accountID: String  // パーティションキー
    var total: Double
}
```

**生成されるメソッド**:

```swift
// 自動生成（accountIDパラメータが追加される）
extension Order {
    static func openDirectory(
        accountID: String,
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace

    static func store(
        accountID: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<Order>
}

// 使用例
let store = try await Order.store(
    accountID: "account-123",
    database: database,
    schema: schema
)
```

#### マルチレベルパーティション

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

    @PrimaryKey var messageID: Int64
    var tenantID: String
    var channelID: String
    var content: String
}

// 使用例
let store = try await Message.store(
    tenantID: "tenant-A",
    channelID: "general",
    database: database,
    schema: schema
)
```

#### ディレクトリレイヤーの種類

| レイヤー | 用途 | 例 |
|---------|------|-----|
| `.recordStore` | 標準レコードストア（デフォルト） | ユーザーデータ、商品データ |
| `.partition` | マルチテナント分離 | テナント別データ |
| `.luceneIndex` | Lucene全文検索インデックス | 記事検索 |
| `.timeSeries` | 時系列データ | メトリクス、ログ |
| `.vectorIndex` | ベクトル検索インデックス | 類似画像検索 |
| `.custom("name")` | カスタムフォーマット | 独自用途 |

**重要な注意事項**:
- `Field()`には**完全なKeyPath**を指定する必要があります
  - ✅ 正しい: `Field(\Order.accountID)`
  - ❌ 間違い: `Field(\.accountID)` ← コンパイルエラー

---

### 4. #Index

インデックスを定義します（オプション）。

#### 単一フィールドインデックス

```swift
@Recordable
struct User {
    #Index<User>([\email])

    @PrimaryKey var userID: Int64
    var email: String
}
```

#### 複数の独立したインデックス

可変引数を使って複数のインデックスを一度に定義できます。

```swift
@Recordable
struct User {
    #Index<User>([\email], [\username], [\age])

    @PrimaryKey var userID: Int64
    var email: String
    var username: String
    var age: Int32
}
```

#### 複合インデックス

複数フィールドの組み合わせでインデックスを作成します。

```swift
@Recordable
struct User {
    #Index<User>([\city, \age])  // 複合インデックス

    @PrimaryKey var userID: Int64
    var city: String
    var age: Int32
}
```

**クエリ例**:

```swift
// cityとageの両方を使った効率的な検索
let results = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .where(\.age, .greaterThanOrEquals, Int32(18))
    .execute()
```

**左端一致の原則**:
複合インデックス `[\city, \age]` は以下のクエリで有効です：
- ✅ `city`のみ
- ✅ `city` + `age`
- ❌ `age`のみ ← インデックスが使われない

#### 名前付きインデックス

```swift
@Recordable
struct User {
    #Index<User>([\country, \city], name: "location_index")

    @PrimaryKey var userID: Int64
    var country: String
    var city: String
}
```

---

### 5. #Unique

ユニーク制約を持つインデックスを定義します。

```swift
@Recordable
struct User {
    #Unique<User>([\email])  // emailは一意でなければならない

    @PrimaryKey var userID: Int64
    var email: String
}
```

**複数のユニーク制約**:

```swift
@Recordable
struct User {
    #Unique<User>([\email], [\username])

    @PrimaryKey var userID: Int64
    var email: String
    var username: String
}
```

**複合ユニーク制約**:

```swift
@Recordable
struct User {
    #Unique<User>([\firstName, \lastName])  // 氏名の組み合わせが一意

    @PrimaryKey var userID: Int64
    var firstName: String
    var lastName: String
}
```

**動作**:
- 重複した値を保存しようとするとエラーが発生
- インデックスとしても機能（高速検索）

---

### 6. @Transient

永続化しないフィールドを指定します。

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String

    @Transient var isLoggedIn: Bool = false  // DBに保存されない
    @Transient var sessionToken: String?     // DBに保存されない
}
```

**用途**:
- 一時的な状態（セッション情報など）
- 計算プロパティ
- UIの状態管理

---

### 7. @Default

フィールドのデフォルト値を指定します。

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String

    @Default(value: Date())
    var createdAt: Date

    @Default(value: 0)
    var loginCount: Int
}
```

**動作**:
- デシリアライズ時にフィールドが存在しない場合、デフォルト値を使用
- スキーマ進化時に便利（新しいフィールドを追加する際）

---

### 8. #FieldOrder

Protobufフィールド番号の順序を明示的に指定します（通常は不要）。

```swift
@Recordable
struct User {
    #FieldOrder<User>([\userID, \email, \name, \age])

    @PrimaryKey var userID: Int64  // field_number = 1
    var email: String               // field_number = 2
    var name: String                // field_number = 3
    var age: Int                    // field_number = 4
}
```

**用途**:
- 既存のProtobufスキーマとの互換性維持
- 通常はフィールド宣言順で自動的に割り当てられるため不要

---

### 9. @Relationship

他のレコードタイプとの関係を定義します（現在はマーカーのみ）。

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String

    @Relationship(deleteRule: .cascade, inverse: \Order.userID)
    var orders: [Int64] = []
}

@Recordable
struct Order {
    @PrimaryKey var orderID: Int64

    @Relationship(inverse: \User.orders)
    var userID: Int64
}
```

**削除ルール**:
- `.noAction` - 何もしない
- `.cascade` - 関連レコードも削除
- `.nullify` - 外部キーをnullに設定
- `.deny` - 関連レコードがある場合削除を拒否

**注**: 現在は宣言のみで、自動的な整合性維持は将来の実装予定

---

### 10. @Attribute

スキーマ進化のためのメタデータを提供します。

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64

    @Attribute(originalName: "username")
    var name: String  // 以前は "username" という名前だった
}
```

**用途**:
- フィールドのリネーム追跡
- マイグレーションツールのサポート

---

## 実践例

### 例1: シンプルなユーザー管理

```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #Index<User>([\email])
    #Unique<User>([\email])

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var age: Int32

    @Default(value: Date())
    var createdAt: Date
}

// 使用例
let store = try await User.store(database: database, schema: schema)

let user = User(userID: 1, name: "Alice", email: "alice@example.com", age: 30, createdAt: Date())
try await store.save(user)

let found = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

### 例2: マルチテナントアプリケーション

```swift
@Recordable
struct TenantUser {
    #Directory<TenantUser>(
        "tenants",
        Field(\TenantUser.tenantID),
        "users",
        layer: .partition
    )

    #Index<TenantUser>([\email])

    @PrimaryKey var userID: Int64
    var tenantID: String  // パーティションキー
    var name: String
    var email: String
}

// テナントA用のストア
let tenantAStore = try await TenantUser.store(
    tenantID: "tenant-A",
    database: database,
    schema: schema
)

// テナントB用のストア
let tenantBStore = try await TenantUser.store(
    tenantID: "tenant-B",
    database: database,
    schema: schema
)

// 完全に分離されたデータ
try await tenantAStore.save(userA)
try await tenantBStore.save(userB)
```

### 例3: 複数レコードタイプの関係

```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #Index<User>([\email])

    @PrimaryKey var userID: Int64
    var name: String
    var email: String
}

@Recordable
struct Order {
    #Directory<Order>("app", "orders")
    #Index<Order>([\userID])
    #Index<Order>([\createdAt])

    @PrimaryKey var orderID: Int64
    var userID: Int64  // 外部キー
    var total: Double

    @Default(value: Date())
    var createdAt: Date
}

// スキーマに両方の型を登録
let schema = Schema([User.self, Order.self])

let userStore = try await User.store(database: database, schema: schema)
let orderStore = try await Order.store(database: database, schema: schema)

// ユーザーの注文を検索
let orders = try await orderStore.query(Order.self)
    .where(\.userID, .equals, user.userID)
    .execute()
```

---

## トラブルシューティング

### エラー1: "cannot infer key path type from context"

**原因**: `Field()`に省略形KeyPathを使用している

```swift
// ❌ 間違い
#Directory<Order>("tenants", Field(\.accountID), "orders", layer: .partition)
```

**解決法**: 完全なKeyPathを使用

```swift
// ✅ 正しい
#Directory<Order>("tenants", Field(\Order.accountID), "orders", layer: .partition)
```

---

### エラー2: "Partition layer requires at least one Field"

**原因**: `layer: .partition`を指定したが、`Field()`がない

```swift
// ❌ 間違い
#Directory<Order>("app", "orders", layer: .partition)
```

**解決法**: `Field()`を追加するか、`.recordStore`を使用

```swift
// ✅ 正しい（パーティション）
#Directory<Order>("tenants", Field(\Order.accountID), "orders", layer: .partition)

// または

// ✅ 正しい（通常のストア）
#Directory<Order>("app", "orders", layer: .recordStore)
```

---

### エラー3: "No @PrimaryKey found"

**原因**: 主キーが定義されていない

```swift
// ❌ 間違い
@Recordable
struct User {
    var userID: Int64  // @PrimaryKeyがない
    var name: String
}
```

**解決法**: `@PrimaryKey`を追加

```swift
// ✅ 正しい
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String
}
```

---

### エラー4: "Type 'User' does not conform to protocol 'Message'"

**原因**: SwiftProtobufの依存関係が正しくない、またはマクロが展開されていない

**解決法**:
1. `Package.swift`の依存関係を確認
2. プロジェクトをクリーンビルド: `swift build --clean`
3. Xcodeの場合: Product → Clean Build Folder

---

### エラー5: FoundationDB接続エラー

```
Error: Could not connect to FoundationDB
```

**解決法**: FoundationDBが起動していることを確認

```bash
# FoundationDBを起動
brew services start foundationdb

# ステータス確認
fdbcli --exec "status"
```

---

## よくある質問

### Q1: Protobufファイルは必要ですか？

**A**: いいえ、マクロAPIを使用する場合、`.proto`ファイルは不要です。すべてSwiftコードで定義します。

---

### Q2: 既存のProtobufスキーマと互換性はありますか？

**A**: はい、`#FieldOrder`を使ってフィールド番号を明示的に指定すれば、既存のProtobufスキーマと互換性を保てます。

---

### Q3: インデックスはいつ作成すべきですか？

**A**: 頻繁にクエリするフィールドにインデックスを作成してください。ただし、インデックスはストレージと書き込みコストを増やすため、必要最小限にとどめることをお勧めします。

**ガイドライン**:
- ✅ 検索キー（email、username など）
- ✅ フィルタリングに使うフィールド（age、status など）
- ✅ ソートキー（createdAt、updatedAt など）
- ❌ めったに検索しないフィールド
- ❌ 高いカーディナリティ（ほぼ一意な値）のフィールド

---

### Q4: 複合主キーと複合インデックスの違いは？

**A**:
- **複合主キー**: レコードを一意に識別するフィールドの組み合わせ
  ```swift
  @PrimaryKey var tenantID: String
  @PrimaryKey var userID: Int64
  ```

- **複合インデックス**: 複数フィールドでの検索を高速化
  ```swift
  #Index<User>([\city, \age])
  ```

---

### Q5: パーティションはいつ使うべきですか？

**A**: 以下の場合にパーティションを使用してください：

- **マルチテナントアプリケーション**: テナント間のデータを完全に分離
- **地理的分離**: 国や地域ごとにデータを分離
- **セキュリティ要件**: データアクセスの厳格な分離が必要

**メリット**:
- ✅ 完全なデータ分離
- ✅ テナント単位でのバックアップ・リストア
- ✅ パフォーマンスの向上（小さなデータセットでの検索）

**デメリット**:
- ❌ クロステナントクエリができない
- ❌ パーティションキーは後から変更できない

---

### Q6: @Transientと@Defaultの違いは？

**A**:
- **@Transient**: フィールドを**永続化しない**（DBに保存されない）
- **@Default**: フィールドがない場合の**デフォルト値を指定**（DBに保存される）

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String

    @Transient var isOnline: Bool = false  // DBに保存されない

    @Default(value: Date())
    var createdAt: Date  // DBに保存される（値がない場合はDate()）
}
```

---

### Q7: クエリのパフォーマンスを最適化するには？

**A**:

1. **適切なインデックスを作成**:
   ```swift
   #Index<User>([\city, \age])  // 頻繁に検索するフィールド
   ```

2. **`limit()`で結果数を制限**:
   ```swift
   let results = try await store.query(User.self)
       .where(\.age, .greaterThan, Int32(18))
       .limit(100)
       .execute()
   ```

3. **統計情報を収集**（コストベース最適化）:
   ```swift
   try await statisticsManager.collectStatistics(
       recordType: "User",
       sampleRate: 0.1
   )
   ```

4. **複合インデックスの左端一致を活用**:
   ```swift
   // インデックス: [\city, \age]
   // ✅ 効率的
   .where(\.city, .equals, "Tokyo")
   .where(\.age, .greaterThan, Int32(18))

   // ❌ 非効率（ageのみ）
   .where(\.age, .greaterThan, Int32(18))
   ```

---

### Q8: スキーマ変更はどうやって行いますか？

**A**: マクロAPIでスキーマ進化を行う際のベストプラクティス：

**新しいフィールドを追加**:
```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String

    // 新しいフィールド（@Defaultでデフォルト値を指定）
    @Default(value: "")
    var phoneNumber: String
}
```

**フィールド名を変更**:
```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64

    @Attribute(originalName: "userName")
    var name: String  // 旧名: userName
}
```

**非推奨**:
- ❌ フィールドの削除（既存データが読めなくなる）
- ❌ フィールドタイプの変更（Protobufの互換性が壊れる）
- ❌ 主キーの変更（データ移行が必要）

---

## 次のステップ

- **[Examples/SimpleExample.swift](../../Examples/SimpleExample.swift)** - 基本的な使用例
- **[Examples/MultiTypeExample.swift](../../Examples/MultiTypeExample.swift)** - 複数レコードタイプの例
- **[Examples/PartitionExample.swift](../../Examples/PartitionExample.swift)** - マルチテナントの例
- **[getting-started.md](./getting-started.md)** - クイックスタートガイド
- **[best-practices.md](./best-practices.md)** - ベストプラクティス

---

**最終更新**: 2025-01-09
**バージョン**: 1.0.0
**マクロAPI**: ✅ 100%完了
