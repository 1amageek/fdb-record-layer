# FDB Record Layer - ベストプラクティス

このガイドでは、FDB Record Layerを本番環境で使用する際のベストプラクティスを説明します。

## 目次

1. [スキーマ設計](#スキーマ設計)
2. [インデックス設計](#インデックス設計)
3. [クエリ最適化](#クエリ最適化)
4. [パフォーマンス](#パフォーマンス)
5. [エラーハンドリング](#エラーハンドリング)
6. [セキュリティ](#セキュリティ)
7. [運用](#運用)
8. [アンチパターン](#アンチパターン)

---

## スキーマ設計

### 1. 主キーの設計

#### ✅ Good: シンプルで一意なID

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64  // Int64を使用
    var name: String
}
```

**理由**:
- `Int64`は効率的にエンコードされる
- 自動インクリメントや UUID生成が容易
- インデックスの分散が良好

#### ❌ Bad: 長い文字列やUUID

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: String  // UUID文字列（36文字）
    var name: String
}
```

**問題点**:
- ストレージコストが高い
- インデックスのパフォーマンスが低下
- 文字列比較がInt64より遅い

---

### 2. 複合主キーの設計

#### ✅ Good: 論理的な順序

```swift
@Recordable
struct OrderItem {
    #PrimaryKey<OrderItem>([\.orderID, \.itemID])

    var orderID: Int64    // 1. 親エンティティ
    var itemID: Int64     // 2. 子エンティティ
    var productID: Int64
    var quantity: Int32
}
```

**理由**:
- `orderID`でグループ化される
- 同じ注文の商品は連続して保存される
- Range読み取りが効率的

#### ❌ Bad: 非論理的な順序

```swift
@Recordable
struct OrderItem {
    #PrimaryKey<OrderItem>([\.itemID, \.orderID])

    var itemID: Int64     // ❌ 順序が逆
    var orderID: Int64
    var productID: Int64
    var quantity: Int32
}
```

**問題点**:
- 注文IDでの Range読み取りが非効率
- データの局所性が低い

---

### 3. フィールドタイプの選択

#### ✅ Good: 適切なタイプ

```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    var productID: Int64
    var name: String
    var price: Double           // 浮動小数点数
    var quantity: Int32         // 整数（小さい範囲）
    var inStock: Bool           // 真偽値
    var createdAt: Date         // 日付
}
```

#### ❌ Bad: すべてStringで保存

```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    var productID: Int64
    var name: String
    var price: String           // ❌ "99.99"
    var quantity: String        // ❌ "100"
    var inStock: String         // ❌ "true"
    var createdAt: String       // ❌ "2025-01-09T10:00:00Z"
}
```

**問題点**:
- ストレージコストが高い
- 数値比較ができない
- 型安全性がない

---

### 4. @Defaultの活用（スキーマ進化）

#### ✅ Good: 新しいフィールドにデフォルト値

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
    var email: String

    // 新しいフィールド（既存データには存在しない）
    @Default(value: "")
    var phoneNumber: String

    @Default(value: Date())
    var createdAt: Date
}
```

**理由**:
- 既存データを読み込んでもエラーにならない
- スキーマ進化が安全

#### ❌ Bad: デフォルト値なしで新フィールド追加

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
    var email: String
    var phoneNumber: String  // ❌ 既存データにはない
}
```

**問題点**:
- 既存データのデシリアライズに失敗
- マイグレーションが必要

---

## インデックス設計

### 1. インデックスの必要性判断

#### インデックスを作成すべき場合

✅ **頻繁に検索するフィールド**:
```swift
@Recordable
struct User {
    #Index<User>([\email])  // メールアドレスで検索
    #Index<User>([\username])  // ユーザー名で検索

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var email: String
    var username: String
}
```

✅ **フィルタリングに使うフィールド**:
```swift
@Recordable
struct Order {
    #Index<Order>([\status])  // ステータスでフィルタ
    #Index<Order>([\createdAt])  // 日付範囲検索

    #PrimaryKey<Order>([\.orderID])

    var orderID: Int64
    var status: String  // "pending", "completed", "cancelled"
    var createdAt: Date
}
```

✅ **ソートキー**:
```swift
@Recordable
struct Post {
    #Index<Post>([\publishedAt])  // 公開日順にソート

    #PrimaryKey<Post>([\.postID])

    var postID: Int64
    var title: String
    var publishedAt: Date
}
```

#### インデックスを作成すべきでない場合

❌ **ほぼ一意な値（カーディナリティが高すぎる）**:
```swift
@Recordable
struct User {
    #Index<User>([\lastLoginIP])  // ❌ IPアドレスはほぼ一意

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var lastLoginIP: String
}
```

❌ **めったに検索しないフィールド**:
```swift
@Recordable
struct User {
    #Index<User>([\favoriteColor])  // ❌ 使用頻度が低い

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var favoriteColor: String
}
```

**理由**:
- インデックスはストレージコストがかかる
- 書き込みパフォーマンスが低下
- メンテナンスコストが増加

---

### 2. 複合インデックスの設計

#### ✅ Good: 左端一致の原則

```swift
@Recordable
struct User {
    #Index<User>([\city, \age])  // 都市 → 年齢

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var city: String
    var age: Int32
}
```

**使えるクエリ**:
```swift
// ✅ cityのみ（左端一致）
let tokyoUsers = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .execute()

// ✅ city + age（両方）
let tokyoAdults = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .where(\.age, .greaterThanOrEquals, Int32(18))
    .execute()
```

**使えないクエリ**:
```swift
// ❌ ageのみ（左端一致でない）
let adults = try await store.query(User.self)
    .where(\.age, .greaterThanOrEquals, Int32(18))
    .execute()
// → フルスキャンになる
```

**解決策**: ageにも単独インデックスを作成
```swift
#Index<User>([\city, \age])  // 複合検索用
#Index<User>([\age])         // age単独検索用
```

---

### 3. ユニーク制約

#### ✅ Good: 論理的に一意であるべきフィールド

```swift
@Recordable
struct User {
    #Unique<User>([\email])  // メールアドレスは一意
    #Unique<User>([\username])  // ユーザー名は一意

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var email: String
    var username: String
}
```

#### ✅ Good: 複合ユニーク制約

```swift
@Recordable
struct Enrollment {
    #Unique<Enrollment>([\studentID, \courseID])  // 同じ生徒が同じコースに重複登録できない

    #PrimaryKey<Enrollment>([\.enrollmentID])

    var enrollmentID: Int64
    var studentID: Int64
    var courseID: Int64
}
```

#### ❌ Bad: 一意でないフィールドに制約

```swift
@Recordable
struct User {
    #Unique<User>([\city])  // ❌ 複数のユーザーが同じ都市に住める

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var city: String
}
```

---

## クエリ最適化

### 1. limit()を使う

#### ✅ Good: 必要な件数だけ取得

```swift
let recentPosts = try await store.query(Post.self)
    .where(\.publishedAt, .lessThanOrEquals, Date())
    .limit(10)  // 最新10件だけ
    .execute()
```

#### ❌ Bad: すべて取得してから制限

```swift
let allPosts = try await store.query(Post.self)
    .where(\.publishedAt, .lessThanOrEquals, Date())
    .execute()

let recentPosts = Array(allPosts.prefix(10))  // ❌ 非効率
```

**理由**:
- `limit()`はデータベース側で制限
- 不要なデータ転送を削減
- メモリ使用量が少ない

---

### 2. インデックスの活用

#### ✅ Good: インデックスを使ったクエリ

```swift
@Recordable
struct User {
    #Index<User>([\email])

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var email: String
}

// emailインデックスを使用
let user = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

#### ❌ Bad: インデックスなしでクエリ

```swift
@Recordable
struct User {
    // インデックスなし

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var email: String
}

// フルスキャンになる
let user = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

**パフォーマンス差**:
- インデックスあり: O(log n)
- インデックスなし: O(n)（フルスキャン）

---

### 3. 統計情報の収集（コストベース最適化）

#### ✅ Good: 定期的に統計を収集

```swift
// 定期的に実行（例: 毎日深夜）
try await statisticsManager.collectStatistics(
    recordType: "User",
    sampleRate: 0.1  // 10%サンプリング
)

try await statisticsManager.collectIndexStatistics(
    indexName: "user_by_email",
    indexSubspace: emailIndexSubspace,
    bucketCount: 100
)
```

**効果**:
- クエリプランナーが最適なインデックスを選択
- 選択性の高いインデックスを優先
- 不要なフルスキャンを回避

---

## パフォーマンス

### 1. バッチ処理

#### ✅ Good: 複数レコードを効率的に保存

```swift
let users: [User] = [...]  // 1000件

// トランザクション内で一括保存
try await database.run { transaction in
    for user in users {
        try await store.save(user, transaction: transaction)
    }
}
```

#### ❌ Bad: 1件ずつトランザクション

```swift
let users: [User] = [...]

for user in users {
    try await store.save(user)  // ❌ 1000回のトランザクション
}
```

**理由**:
- トランザクションオーバーヘッドを削減
- ネットワークラウンドトリップを削減
- スループットが向上

---

### 2. ストリーミング処理

#### ✅ Good: カーソルで逐次処理

```swift
let cursor = try await store.fetchCursor(User.self)

for try await user in cursor {
    // 1件ずつ処理（メモリ効率的）
    process(user)
}
```

#### ❌ Bad: すべてメモリに読み込む

```swift
let allUsers = try await store.query(User.self).execute()

for user in allUsers {
    process(user)  // ❌ 100万件だとメモリ不足
}
```

**理由**:
- メモリ使用量が一定（O(1)）
- 大量データでも安全
- レイテンシが低い（逐次処理開始）

---

### 3. トランザクションサイズ制限

#### ✅ Good: バッチサイズを制限

```swift
let batchSize = 1000
var batch: [User] = []

for user in allUsers {
    batch.append(user)

    if batch.count >= batchSize {
        try await saveBatch(batch)
        batch.removeAll()
    }
}

// 残りを保存
if !batch.isEmpty {
    try await saveBatch(batch)
}
```

#### ❌ Bad: 無制限にトランザクション実行

```swift
try await database.run { transaction in
    for user in allUsers {  // ❌ 100万件だとエラー
        try await store.save(user, transaction: transaction)
    }
}
// Error: transaction_too_large (2101)
```

**理由**:
- FoundationDBのトランザクションサイズ制限（デフォルト10MB）
- メモリ使用量を抑制
- コミット成功率が向上

---

## エラーハンドリング

### 1. リトライロジック

#### ✅ Good: 自動リトライ

```swift
func saveWithRetry<T>(_ record: T, maxRetries: Int = 3) async throws {
    var attempt = 0

    while attempt < maxRetries {
        do {
            try await store.save(record)
            return  // 成功
        } catch let error as FDBError {
            attempt += 1

            if error.isRetryable && attempt < maxRetries {
                // Exponential backoff
                let delay = pow(2.0, Double(attempt)) * 0.1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            throw error  // リトライ不可またはリトライ回数超過
        }
    }
}
```

**リトライ可能なエラー**:
- `not_committed` (1020)
- `transaction_too_old` (1007)
- `future_version` (1009)

**リトライ不可能なエラー**:
- `transaction_too_large` (2101)
- `operation_cancelled` (1101)

---

### 2. エラーの適切なハンドリング

#### ✅ Good: エラータイプごとに処理

```swift
do {
    try await store.save(user)
} catch let error as FDBError {
    switch error.code {
    case 1020:  // not_committed
        // リトライ
        print("Conflict detected, retrying...")

    case 2101:  // transaction_too_large
        // バッチサイズを削減
        print("Transaction too large, reducing batch size...")

    case 1031:  // transaction_timed_out
        // タイムアウト増加
        print("Transaction timed out...")

    default:
        // その他のエラー
        print("Error: \(error.localizedDescription)")
        throw error
    }
} catch {
    print("Unexpected error: \(error)")
    throw error
}
```

---

## セキュリティ

### 1. パーティションによるデータ分離

#### ✅ Good: テナント別にデータを分離

```swift
@Recordable
struct CustomerData {
    #Directory<CustomerData>(
        "tenants",
        Field(\CustomerData.tenantID),
        "data",
        layer: .partition
    )

    #PrimaryKey<CustomerData>([\.dataID])

    var dataID: Int64
    var tenantID: String  // パーティションキー
    var sensitiveData: String
}

// テナントAのストア（テナントBのデータにはアクセス不可）
let tenantAStore = try await CustomerData.store(
    tenantID: "tenant-A",
    database: database,
    schema: schema
)
```

**メリット**:
- 完全なデータ分離
- 誤ったテナントのデータへのアクセス防止
- セキュリティコンプライアンス

---

### 2. 機密データの取り扱い

#### ✅ Good: 暗号化してから保存

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String

    var encryptedSSN: Data  // 暗号化された社会保障番号
}

// 暗号化
let encryptedSSN = try encryptionService.encrypt(ssn)
let user = User(userID: 1, name: "Alice", encryptedSSN: encryptedSSN)
try await store.save(user)

// 復号化
if let user: User = try await store.fetch(by: Int64(1)) {
    let ssn = try encryptionService.decrypt(user.encryptedSSN)
}
```

#### ❌ Bad: 平文で保存

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
    var ssn: String  // ❌ 平文の社会保障番号
}
```

---

## 運用

### 1. オンラインインデックス構築

#### ✅ Good: ダウンタイムなしで追加

```swift
// 1. インデックスをスキーマに追加（writeOnlyモード）
@Recordable
struct User {
    #Index<User>([\email])
    #Index<User>([\age])  // 新しいインデックス

    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var email: String
    var age: Int32
}

// 2. OnlineIndexerでバックグラウンド構築
let indexer = OnlineIndexer(
    database: database,
    metaData: metaData,
    indexName: "user_by_age",
    subspace: recordStoreSubspace,
    batchSize: 1000
)

try await indexer.buildIndex()

// 3. インデックスをreadableモードに変更
```

**メリット**:
- ダウンタイムなし
- 既存のクエリに影響なし
- 失敗時に再開可能

---

### 2. モニタリングとロギング

#### ✅ Good: 構造化ログとメトリクス

```swift
import Logging

let logger = Logger(label: "com.example.app")

logger.info("Saving user", metadata: [
    "userID": "\(user.userID)",
    "operation": "save"
])

// メトリクス収集
metricsRecorder.increment("user.save.count")
metricsRecorder.time("user.save.duration", duration)
```

**監視すべきメトリクス**:
- リクエスト数
- レイテンシ（P50, P95, P99）
- エラー率
- トランザクションリトライ率
- インデックス構築進捗

---

### 3. バックアップとリストア

#### ✅ Good: 定期的なバックアップ

```bash
# 毎日のバックアップ（cron）
0 2 * * * fdbbackup start -d file:///backups/fdb-$(date +\%Y\%m\%d)

# ステータス確認
fdbbackup status

# リストア
fdbrestore start -r file:///backups/fdb-20250109
```

**ベストプラクティス**:
- 毎日自動バックアップ
- オフサイトストレージ（S3、Azure）
- 定期的なリストアテスト
- 保持ポリシーの設定（例: 30日間）

---

## アンチパターン

### 1. ❌ 過度に正規化されたスキーマ

```swift
// ❌ Bad: RDBMSのような正規化
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
    var addressID: Int64  // Addressテーブルへの外部キー
}

@Recordable
struct Address {
    #PrimaryKey<Address>([\.addressID])

    var addressID: Int64
    var street: String
    var city: String
}

// 2回のクエリが必要
let user = try await userStore.fetch(by: Int64(1))
let address = try await addressStore.fetch(by: user!.addressID)
```

**代わりに**: 非正規化してネストする

```swift
// ✅ Good: 非正規化
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
    var street: String
    var city: String
}

// 1回のクエリで完結
let user = try await userStore.fetch(by: Int64(1))
```

---

### 2. ❌ 大きすぎるレコード

```swift
// ❌ Bad: 100KBを超える値
@Recordable
struct Document {
    #PrimaryKey<Document>([\.documentID])

    var documentID: Int64
    var title: String
    var content: String  // 数MBのテキスト ← FoundationDBの制限100KB超過
}
```

**代わりに**: データを分割

```swift
// ✅ Good: メタデータとコンテンツを分離
@Recordable
struct Document {
    #PrimaryKey<Document>([\.documentID])

    var documentID: Int64
    var title: String
    var summary: String
}

@Recordable
struct DocumentChunk {
    #PrimaryKey<DocumentChunk>([\.documentID, \.chunkIndex])

    var documentID: Int64
    var chunkIndex: Int32
    var content: String  // 50KB以下のチャンク
}
```

---

### 3. ❌ N+1クエリ問題

```swift
// ❌ Bad: N+1クエリ
let orders = try await orderStore.query(Order.self).execute()

for order in orders {
    // ユーザーごとに1回クエリ（N回）
    let user = try await userStore.fetch(by: order.userID)
    print("\(user!.name): \(order.total)")
}
```

**代わりに**: バッチ読み取り

```swift
// ✅ Good: バッチで取得
let orders = try await orderStore.query(Order.self).execute()
let userIDs = orders.map { $0.userID }

// 1回のトランザクションで全ユーザーを取得
let users = try await database.run { transaction in
    var result: [Int64: User] = [:]
    for userID in userIDs {
        if let user: User = try await userStore.fetch(by: userID, transaction: transaction) {
            result[userID] = user
        }
    }
    return result
}

for order in orders {
    if let user = users[order.userID] {
        print("\(user.name): \(order.total)")
    }
}
```

---

## まとめ

### 重要なポイント

| カテゴリ | ベストプラクティス |
|---------|------------------|
| **スキーマ** | シンプルな主キー、適切な型、@Defaultで進化 |
| **インデックス** | 頻繁に検索するフィールドのみ、複合インデックスは左端一致 |
| **クエリ** | limit()で制限、インデックス活用、統計情報収集 |
| **パフォーマンス** | バッチ処理、ストリーミング、トランザクションサイズ制限 |
| **エラー** | リトライロジック、適切なエラーハンドリング |
| **セキュリティ** | パーティション、暗号化 |
| **運用** | オンラインインデックス、モニタリング、バックアップ |

### 次のステップ

- **[macro-usage-guide.md](./macro-usage-guide.md)** - マクロAPIリファレンス
- **[query-optimizer.md](./query-optimizer.md)** - クエリ最適化の詳細
- **[advanced-index-design.md](./advanced-index-design.md)** - 高度なインデックス設計

---

**最終更新**: 2025-01-09
**バージョン**: 1.0.0
