# Partition Manager Usage Guide

**作成日**: 2025-01-06
**対象読者**: FDB Record Layer Swiftのユーザー
**関連ドキュメント**: [PARTITION_DESIGN.md](PARTITION_DESIGN.md)

---

## 📋 概要

PartitionManagerは、マルチテナントアプリケーションでアカウントごとに完全に分離されたRecordStoreを管理するためのコンポーネントです。

### 主な機能

- ✅ **アカウント分離**: 各アカウントが独立したSubspaceを持つ
- ✅ **キャッシング**: RecordStoreを自動的にキャッシュして再利用
- ✅ **型安全**: RecordStore<Record>による完全な型安全性
- ✅ **高スループット**: final class + Mutex パターンで並列性を最大化
- ✅ **メトリクスとログ**: アカウント単位で自動的に設定

---

## 🚀 Quick Start

### 1. 基本的な使用方法

```swift
import FoundationDB
import FDBRecordLayer

// 1. RecordMetaDataを作成
let metaData = RecordMetaData()
try metaData.registerRecordType(User.self)
try metaData.registerRecordType(Order.self)

// 2. PartitionManagerを作成
let manager = PartitionManager(
    database: database,
    rootSubspace: Subspace(rootPrefix: "myapp"),
    metaData: metaData
)

// 3. アカウント専用のRecordStoreを取得
let userStore: RecordStore<User> = try await manager.recordStore(
    for: "account-001",
    collection: "users"
)

// 4. 型安全な操作
let user = User(userID: 1, name: "Alice", email: "alice@example.com")
try await userStore.save(user)

// 5. 取得
if let fetchedUser = try await userStore.fetch(by: 1) {
    print("User: \(fetchedUser.name)")
}
```

### 2. Subspace構造

PartitionManagerは以下のSubspace構造を使用します:

```
/rootSubspace/accounts/<accountID>/<collection>/
```

**例**:
```
/myapp/accounts/account-001/users/
/myapp/accounts/account-001/orders/
/myapp/accounts/account-002/users/
```

---

## 💡 使用パターン

### Pattern 1: 複数コレクションの管理

```swift
let manager = PartitionManager(
    database: database,
    rootSubspace: Subspace(rootPrefix: "ecommerce"),
    metaData: metaData
)

// 同じアカウント内の異なるコレクション
let userStore: RecordStore<User> = try await manager.recordStore(
    for: "account-001",
    collection: "users"
)

let orderStore: RecordStore<Order> = try await manager.recordStore(
    for: "account-001",
    collection: "orders"
)

// 各コレクションは独立して動作
try await userStore.save(user)
try await orderStore.save(order)
```

### Pattern 2: トランザクション内での操作

```swift
let userStore: RecordStore<User> = try await manager.recordStore(
    for: "account-001",
    collection: "users"
)

// トランザクション内で複数操作を実行
try await userStore.transaction { transaction in
    // ユーザーを作成
    let user = User(userID: 1, name: "Alice", email: "alice@example.com")
    try await transaction.save(user)

    // 別のユーザーを取得して更新
    if var existingUser = try await transaction.fetch(by: 2) {
        existingUser.name = "Updated Name"
        try await transaction.save(existingUser)
    }

    // すべてコミットされる（または全ロールバック）
}
```

### Pattern 3: 複合主キーの使用

```swift
struct OrderItem: Recordable {
    static let recordTypeName = "OrderItem"
    static let primaryKey = \OrderItem.compositeKey

    var orderID: String
    var itemID: String
    var quantity: Int32

    var compositeKey: Tuple {
        Tuple(orderID, itemID)
    }
}

let itemStore: RecordStore<OrderItem> = try await manager.recordStore(
    for: "account-001",
    collection: "order_items"
)

// 保存
let item = OrderItem(orderID: "order-123", itemID: "item-456", quantity: 2)
try await itemStore.save(item)

// 取得（可変長引数版 - 推奨）
let fetchedItem = try await itemStore.fetch(by: "order-123", "item-456")

// または Tuple版
let fetchedItem = try await itemStore.fetch(by: Tuple("order-123", "item-456"))
```

### Pattern 4: アカウント削除

```swift
// アカウント全体を削除（すべてのコレクションを含む）
try await manager.deleteAccount("account-001")

// キャッシュもクリアされる
print("Cache size: \(manager.cacheSize())") // 0
```

---

## 🎯 ベストプラクティス

### 1. StatisticsManagerの使用

パフォーマンスを最大化するため、StatisticsManagerを提供することを推奨します:

```swift
let statsManager = StatisticsManager(
    database: database,
    subspace: Subspace(rootPrefix: "myapp-stats")
)

let manager = PartitionManager(
    database: database,
    rootSubspace: Subspace(rootPrefix: "myapp"),
    metaData: metaData,
    statisticsManager: statsManager
)
```

### 2. キャッシュの活用

PartitionManagerは自動的にRecordStoreをキャッシュします。同じアカウント・コレクションに繰り返しアクセスする場合は、同じインスタンスが返されます:

```swift
// 初回: 新しいRecordStoreを作成（キャッシュミス）
let store1: RecordStore<User> = try await manager.recordStore(
    for: "account-001",
    collection: "users"
)

// 2回目: キャッシュから返される（高速）
let store2: RecordStore<User> = try await manager.recordStore(
    for: "account-001",
    collection: "users"
)

// store1とstore2は同じSubspaceを持つ
```

### 3. メモリ管理

長期実行アプリケーションでメモリを解放したい場合は、キャッシュをクリアできます:

```swift
// すべてのキャッシュをクリア
manager.clearCache()

// 次回のrecordStore()呼び出しで再作成される
```

### 4. エラーハンドリング

```swift
do {
    let store: RecordStore<User> = try await manager.recordStore(
        for: "account-001",
        collection: "users"
    )

    let user = User(userID: 1, name: "Alice", email: "alice@example.com")
    try await store.save(user)

} catch let error as RecordLayerError {
    switch error {
    case .serializationError(let message):
        print("Serialization failed: \(message)")
    case .transactionError(let message):
        print("Transaction failed: \(message)")
    default:
        print("Unexpected error: \(error)")
    }
} catch {
    print("Unknown error: \(error)")
}
```

---

## 🔥 パフォーマンス考慮事項

### 1. final class + Mutex パターン

PartitionManagerは`actor`ではなく`final class + Mutex`を使用しています。これにより、約3倍のスループット向上を実現しています:

| パターン | スループット | 理由 |
|---------|-------------|------|
| actor | 8.3 batch/sec | 全メソッドがシリアライズ |
| **final class + Mutex** | **22.2 batch/sec** | 必要な部分のみロック |

### 2. I/O操作の並列化

PartitionManagerは、I/O操作（RecordStore作成）をロックの外で実行します:

```swift
public func recordStore<Record: Recordable>(
    for accountID: String,
    collection: String
) async throws -> RecordStore<Record> {
    // 1. キャッシュチェック（ロック内 - 高速）
    let cached = storeCacheLock.withLock { cache[key] }
    if let cached = cached { return cached }

    // 2. RecordStore作成（ロックの外 - 並列実行可能）
    let store = RecordStore<Record>(...)

    // 3. キャッシュ更新（ロック内 - 高速）
    storeCacheLock.withLock { cache[key] = store }

    return store
}
```

### 3. 並行アクセス

複数のアカウントに同時にアクセスする場合、PartitionManagerは高い並列性を提供します:

```swift
await withTaskGroup(of: Void.self) { group in
    for accountID in accountIDs {
        group.addTask {
            let store: RecordStore<User> = try await manager.recordStore(
                for: accountID,
                collection: "users"
            )
            // 各アカウントで独立して処理
            try await store.save(user)
        }
    }
}
```

---

## 🛠 トラブルシューティング

### 問題 1: "Record type not registered" エラー

**原因**: RecordMetaDataに型が登録されていない

**解決策**:
```swift
let metaData = RecordMetaData()
try metaData.registerRecordType(User.self) // ← 必須
```

### 問題 2: キャッシュが大きくなりすぎる

**原因**: 多数のアカウント・コレクションにアクセスしている

**解決策**:
```swift
// 定期的にキャッシュをクリア
if manager.cacheSize() > 1000 {
    manager.clearCache()
}

// または、アプリケーション終了時にクリア
defer {
    manager.clearCache()
}
```

### 問題 3: 型が合わない

**原因**: RecordStore<T>の型パラメータが間違っている

**解決策**:
```swift
// ❌ 間違い
let store: RecordStore<Order> = try await manager.recordStore(
    for: "account-001",
    collection: "users" // ← Userのコレクションなのに Order型
)

// ✅ 正しい
let store: RecordStore<User> = try await manager.recordStore(
    for: "account-001",
    collection: "users"
)
```

---

## 📚 関連ドキュメント

- [PARTITION_DESIGN.md](PARTITION_DESIGN.md) - 設計思想と実装詳細
- [CLAUDE.md](../CLAUDE.md) - FoundationDB使い方ガイド
- [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md) - メトリクスとロギング

---

## 🔗 API Reference

### PartitionManager

```swift
public final class PartitionManager: Sendable {
    /// 初期化
    public init(
        database: any DatabaseProtocol,
        rootSubspace: Subspace,
        metaData: RecordMetaData,
        statisticsManager: StatisticsManager? = nil
    )

    /// アカウント専用のRecordStoreを取得
    public func recordStore<Record: Recordable>(
        for accountID: String,
        collection: String
    ) async throws -> RecordStore<Record>

    /// アカウント全体を削除
    public func deleteAccount(_ accountID: String) async throws

    /// キャッシュをクリア
    public func clearCache()

    /// キャッシュサイズを取得
    public func cacheSize() -> Int
}
```

---

**メンテナ**: Claude Code
**最終更新**: 2025-01-06
