# Directory Layer Design

**Last Updated:** 2025-01-13
**Status:** ✅ Design Complete
**Phase:** 2b Implementation

---

## 目次

1. [概要](#概要)
2. [FoundationDB Directory Layer とは](#foundationdb-directory-layer-とは)
3. [設計原則](#設計原則)
4. [DirectoryLayer 型の設計](#directorylayer-型の設計)
5. [#Directory マクロの設計](#directory-マクロの設計)
6. [推論ルール](#推論ルール)
7. [生成されるコード](#生成されるコード)
8. [マルチテナントアーキテクチャ](#マルチテナントアーキテクチャ)
9. [実装ファイル](#実装ファイル)
10. [使用例](#使用例)

---

## 概要

このドキュメントでは、FoundationDB標準の**Directory Layer**を使用した `#Directory` マクロの設計を説明します。

### 設計目標

1. ✅ **FDB標準準拠**: FoundationDB公式のDirectory Layerを使用
2. ✅ **型安全性**: `DirectoryLayer` struct による型安全な layer 管理
3. ✅ **シンプルなAPI**: 冗長なパラメータを排除し、パスから自動推論
4. ✅ **マルチテナント対応**: `layer: .partition` による完全なデータ分離
5. ✅ **拡張性**: カスタム layer のサポート

### 主要な変更点

| 項目 | 旧設計（#Subspace） | 新設計（#Directory） |
|------|-------------------|-------------------|
| **基盤技術** | カスタム実装 | ✅ FDB標準 Directory Layer |
| **layer サポート** | なし | ✅ `DirectoryLayer` 型で型安全 |
| **partition 引数** | 明示的指定 | ✅ パスから自動推論（削除） |
| **プレフィックス管理** | 手動 | ✅ FDB が自動管理 |
| **ディレクトリ移動** | 非効率 | ✅ 高速（間接参照） |

---

## FoundationDB Directory Layer とは

### Directory Layer の階層構造

```
FDB Key Space
├─ Tuple Layer (エンコーディング)
├─ Subspace Layer (名前空間)
└─ Directory Layer (階層的パス管理)
```

### Directory Layer の役割

FoundationDB Directory Layer は、階層的なパス（ファイルシステムに類似）を**短いプレフィックス**にマッピングします。

#### 通常の Subspace のみの場合

```python
# Subspace のみ（プレフィックスが長い）
user_subspace = Subspace(b'app').subspace(b'users')
# 実際のキー: b'app' + b'users' + user_key
# → プレフィックス = b'appusers' (長い)
```

#### Directory Layer を使用した場合

```python
# Directory Layer（短いプレフィックス）
user_dir = fdb.directory.create_or_open(db, ['app', 'users'])
# 実際のキー: \x15\xA3\x82 + user_key
# → プレフィックス = \x15\xA3\x82 (短い、固定長)

# メタデータは \xFE 以下に保存
# \xFE + ('app', 'users') → \x15\xA3\x82
```

### メリット

| メリット | 説明 |
|---------|------|
| **短いプレフィックス** | パスが長くてもプレフィックスは短い（数バイト） |
| **効率的な移動** | ディレクトリのリネーム/移動が高速（プレフィックスは不変） |
| **間接参照** | パス → プレフィックスのマッピングを `\xFE` 以下に保存 |
| **layer メタデータ** | ディレクトリの用途やバージョンを識別 |

---

## 設計原則

### 1. FoundationDB標準の機能を使用

❌ **旧設計（カスタム実装）**:
```swift
#Subspace<User>(["app", "accounts", \.accountID, "users"])
// → カスタムのプレフィックス管理
```

✅ **新設計（FDB標準）**:
```swift
#Directory<User>(["app", "users"], layer: .recordStore)
// → FDB Directory Layer を使用
```

### 2. 型安全な layer 管理

```swift
// DirectoryLayer struct で型安全
let layer: DirectoryLayer = .partition
let layer2: DirectoryLayer = .recordStore
let layer3: DirectoryLayer = "custom_format_v2"  // ExpressibleByStringLiteral
```

### 3. 冗長なパラメータを削除

❌ **冗長**:
```swift
#Directory<Order>(
    ["tenants", \.accountID, "orders"],
    partition: \.accountID,  // ← パスに既にある
    layer: .partition
)
```

✅ **シンプル**:
```swift
#Directory<Order>(
    ["tenants", \.accountID, "orders"],
    layer: .partition  // パスから \.accountID を自動推論
)
```

### 4. パスから partition を推論

- `layer: .partition` の場合、パス内の KeyPath 位置で partition を作成
- KeyPath に対応するフィールドが構造体に存在する必要がある
- partition 内の残りのパスは通常のサブディレクトリとして作成

---

## DirectoryLayer 型の設計

### 型定義

**ファイル**: `Sources/FDBRecordLayer/Core/DirectoryLayer.swift`

```swift
/// FoundationDB Directory Layer の layer パラメータを表す型
public struct DirectoryLayer: Sendable, Hashable, ExpressibleByStringLiteral {

    /// layer の生バイト値
    public let rawValue: Data

    /// 文字列から初期化
    public init(_ string: String)

    /// String literal から初期化
    public init(stringLiteral value: String)
}
```

### 標準 Layer

| Layer | 説明 | FDB の動作 |
|-------|------|-----------|
| `.partition` | FDB標準のPartition | 専用nodeSubspace、共通プレフィックス |
| `.recordStore` | Record Layer v1 | メタデータとして保存のみ |
| `.luceneIndex` | Lucene インデックス | メタデータとして保存のみ |
| `.timeSeries` | 時系列データ | メタデータとして保存のみ |
| `.vectorIndex` | Vector インデックス | メタデータとして保存のみ |

### バージョン付き Layer

```swift
// Record Layer のバージョン管理
DirectoryLayer.recordStoreVersion(2)  // "fdb_record_layer_v2"

// カスタムバージョン
DirectoryLayer.versioned("my_format", version: 3)  // "my_format_v3"
```

### カスタム Layer

```swift
// ExpressibleByStringLiteral でカスタム layer を指定可能
let customLayer: DirectoryLayer = "my_custom_format_v2"
```

---

## #Directory マクロの設計

### マクロシグネチャ

**ファイル**: `Sources/FDBRecordLayer/Macros/Macros.swift`

```swift
@freestanding(declaration)
public macro Directory<T>(
    _ path: [DirectoryPathElement<T>],
    layer: DirectoryLayer = .recordStore
) = #externalMacro(
    module: "FDBRecordLayerMacros",
    type: "DirectoryMacro"
)
```

### パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|----------|------|
| `path` | `[DirectoryPathElement<T>]` | 必須 | ディレクトリパス（文字列 or KeyPath） |
| `layer` | `DirectoryLayer` | `.recordStore` | Directory Layer タイプ |

### DirectoryPathElement

```swift
public enum DirectoryPathElement<T> {
    case literal(String)           // 文字列リテラル: "app", "users"
    case keyPath(KeyPath<T, String>)  // KeyPath: \.accountID
}

// ExpressibleByStringLiteral
extension DirectoryPathElement: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .literal(value)
    }
}
```

**注**: Swift は `ExpressibleByKeyPathLiteral` をサポートしていないため、マクロ展開時に KeyPath を AST から検出します。

---

## 推論ルール

### ルール1: layer: .partition の場合

パス内の**最初の KeyPath 位置**で partition を作成します。

```swift
#Directory<Order>(
    ["tenants", \.accountID, "orders"],
    layer: .partition
)

// 推論:
// 1. "tenants" までが静的パス
// 2. \.accountID の位置で partition 作成
// 3. partition 内に "orders" ディレクトリ作成
```

#### 生成されるディレクトリ構造

```
FDB Key Space
├─ \xFE (nodeSubspace: グローバルメタデータ)
│   └─ ("tenants", "account-123") → prefix: \x15\xA3\x82, layer='partition'
│
└─ \x15\xA3\x82 (account-123 の partition)
    ├─ \xFE (partition 専用の nodeSubspace)
    │   └─ ("orders",) → prefix: \x15\xA3\x82\x01
    │
    └─ \x15\xA3\x82\x01 (orders ディレクトリ)
        ├─ R/Order/{orderID} → record data
        └─ I/{indexName}/{indexKey} → index data
```

### ルール2: 複数の KeyPath がある場合

最初の KeyPath で partition を作成し、残りは通常のパスとして扱います。

```swift
#Directory<Message>(
    ["tenants", \.accountID, "channels", \.channelID, "messages"],
    layer: .partition
)

// 推論:
// 1. "tenants" までが静的パス
// 2. \.accountID の位置で partition 作成
// 3. partition 内に "channels/{channelID}" パスを作成
// 4. その中に "messages" ディレクトリ作成
```

### ルール3: layer が .partition 以外の場合

KeyPath があっても partition を作成せず、動的パスとして扱います。

```swift
#Directory<User>(
    ["app", "users", \.userID],
    layer: .recordStore
)

// 推論:
// 1. 通常の Directory として扱う
// 2. パス = ["app", "users", userID] （動的パス）
// 3. partition は作成しない
```

### ルール4: layer: .partition で KeyPath がない場合

コンパイルエラーになります。

```swift
#Directory<User>(
    ["app", "users"],
    layer: .partition
)
// ❌ コンパイルエラー:
// layer: .partition requires at least one KeyPath in the path
```

---

## 生成されるコード

### 基本的なディレクトリ

#### Input

```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
}
```

#### Generated

```swift
extension User {
    static func openDirectory(
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace {
        let dir = try await database.directory.createOrOpen(
            path: ["app", "users"],
            layer: DirectoryLayer.recordStore.rawValue
        )

        // Layer 検証
        if dir.layer != DirectoryLayer.recordStore.rawValue {
            throw DirectoryError.layerMismatch(
                expected: DirectoryLayer.recordStore,
                actual: DirectoryLayer(rawValue: dir.layer)
            )
        }

        return dir
    }

    static func store(
        database: any DatabaseProtocol,
        metaData: RecordMetaData
    ) async throws -> RecordStore<User> {
        let directory = try await openDirectory(database: database)
        return RecordStore(
            database: database,
            subspace: directory,
            metaData: metaData
        )
    }
}
```

### Partition を使用したマルチテナント

#### Input

```swift
@Recordable
struct Order {
    #Directory<Order>(
        "tenants",
        Field(\Order.accountID),
        "orders",
        layer: .partition
    )
    #PrimaryKey<Order>([\.orderID])

    var orderID: Int64
    var accountID: String
}
```

#### Generated

```swift
extension Order {
    static func openDirectory(
        accountID: String,
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace {
        // 1. Partition を作成/取得
        let tenantPartition = try await database.directory.createOrOpen(
            path: ["tenants", accountID],
            layer: DirectoryLayer.partition.rawValue
        )

        // Layer 検証（partition であることを確認）
        if tenantPartition.layer != DirectoryLayer.partition.rawValue {
            throw DirectoryError.layerMismatch(
                expected: DirectoryLayer.partition,
                actual: DirectoryLayer(rawValue: tenantPartition.layer)
            )
        }

        // 2. Partition 内に "orders" ディレクトリを作成
        let ordersDir = try await tenantPartition.createOrOpen(
            path: ["orders"],
            layer: DirectoryLayer.recordStore.rawValue
        )

        return ordersDir
    }

    static func store(
        accountID: String,
        database: any DatabaseProtocol,
        metaData: RecordMetaData
    ) async throws -> RecordStore<Order> {
        let directory = try await openDirectory(
            accountID: accountID,
            database: database
        )
        return RecordStore(
            database: database,
            subspace: directory,
            metaData: metaData
        )
    }
}

// Usage:
let orderStore = try await Order.store(
    accountID: "account-123",
    database: database,
    metaData: metaData
)

let order = Order(orderID: 1, accountID: "account-123", amount: 100.0)
try await orderStore.save(order)
```

### 複数 KeyPath（ネストした階層）

#### Input

```swift
@Recordable
struct Message {
    #Directory<Message>(
        "tenants",
        Field(\Message.accountID),
        "channels",
        Field(\Message.channelID),
        "messages",
        layer: .partition
    )
    #PrimaryKey<Message>([\.messageID])

    var messageID: Int64
    var accountID: String
    var channelID: String
}
```

#### Generated

```swift
extension Message {
    static func openDirectory(
        accountID: String,
        channelID: String,
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace {
        // 1. "tenants/{accountID}" で partition 作成
        let tenantPartition = try await database.directory.createOrOpen(
            path: ["tenants", accountID],
            layer: DirectoryLayer.partition.rawValue
        )

        // 2. partition 内に "channels/{channelID}" パスを作成
        let channelDir = try await tenantPartition.createOrOpen(
            path: ["channels", channelID],
            layer: nil  // 中間ディレクトリ（layer なし）
        )

        // 3. その中に "messages" ディレクトリ作成
        let messagesDir = try await channelDir.createOrOpen(
            path: ["messages"],
            layer: DirectoryLayer.recordStore.rawValue
        )

        return messagesDir
    }
}
```

---

## マルチテナントアーキテクチャ

### Partition による完全なデータ分離

#### キー構造の比較

**❌ 通常の Directory（推奨しない）**:

```
グローバルキー空間
├─ \x15\xA3\x01 (tenant1/users)
│   └─ user:123 → {...}
├─ \x15\xA3\x02 (tenant1/orders)
│   └─ order:456 → {...}
├─ \x15\xA3\x03 (tenant2/users)
│   └─ user:789 → {...}
└─ \x15\xA3\x04 (tenant2/orders)
    └─ order:012 → {...}

問題:
- プレフィックスがバラバラ
- テナント全体の削除が非効率（個別に削除が必要）
- Range 削除で他テナントを誤って削除するリスク
```

**✅ Directory Partition（推奨）**:

```
グローバルキー空間
├─ \x15\xA3\x82 (tenant1 partition)
│   ├─ \x15\xA3\x82\x01 (users)
│   │   └─ user:123 → {...}
│   └─ \x15\xA3\x82\x02 (orders)
│       └─ order:456 → {...}
│
└─ \x15\xA3\x84 (tenant2 partition)
    ├─ \x15\xA3\x84\x01 (users)
    │   └─ user:789 → {...}
    └─ \x15\xA3\x84\x02 (orders)
        └─ order:012 → {...}

利点:
- すべてのキーが共通プレフィックスを共有
- テナント全体を単一の Range 削除で高速削除可能
- 物理的に完全分離（他テナントに影響なし）
```

### テナント削除の効率性

```swift
// ✅ Partition を使用した場合（超高速）
@fdb.transactional
func deleteTenant(accountID: String) async throws {
    // 単一の Range 削除で完了
    try await database.directory.remove(["tenants", accountID])

    // または直接 Range 削除
    let partition = try await database.directory.open(["tenants", accountID])
    try await database.run { transaction in
        transaction.clearRangeStartsWith(partition.prefix)
    }
}

// ❌ 通常の Directory の場合（非効率）
@fdb.transactional
func deleteTenant(accountID: String) async throws {
    // 各ディレクトリを個別に削除する必要がある
    try await database.directory.remove(["tenants", accountID, "users"])
    try await database.directory.remove(["tenants", accountID, "orders"])
    try await database.directory.remove(["tenants", accountID, "products"])
    // ... すべてのサブディレクトリを個別に削除
}
```

---

## 実装ファイル

### コアファイル

| ファイル | 説明 |
|---------|------|
| `Sources/FDBRecordLayer/Core/DirectoryLayer.swift` | `DirectoryLayer` 型定義 |
| `Sources/FDBRecordLayer/Core/Directory.swift` | FDB Directory Layer 実装 |
| `Sources/FDBRecordLayer/Core/DirectoryError.swift` | Directory エラー型 |
| `Sources/FDBRecordLayer/Core/DirectorySubspace.swift` | DirectorySubspace 型 |

### マクロファイル

| ファイル | 説明 |
|---------|------|
| `Sources/FDBRecordLayer/Macros/Macros.swift` | `#Directory` マクロ定義 |
| `Sources/FDBRecordLayerMacros/DirectoryMacro.swift` | `DirectoryMacro` 実装 |
| `Sources/FDBRecordLayerMacros/RecordableMacro.swift` | `@Recordable` 実装（AST読み取り） |

### テストファイル

| ファイル | 説明 |
|---------|------|
| `Tests/FDBRecordLayerTests/DirectoryLayerTests.swift` | DirectoryLayer 型テスト |
| `Tests/FDBRecordLayerTests/DirectoryTests.swift` | Directory 操作テスト |
| `Tests/FDBRecordLayerTests/DirectoryMacroTests.swift` | #Directory マクロテスト |

---

## 使用例

### 基本的な使用

```swift
import FDBRecordLayer

// 1. シンプルなディレクトリ
@Recordable
struct User {
    #Directory<User>("app", "users")
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
}

// 2. 明示的な layer 指定
@Recordable
struct Product {
    #Directory<Product>(
        "app",
        "products",
        layer: .recordStore
    )
    #PrimaryKey<Product>([\.productID])

    var productID: Int64
}

// 3. カスタム layer（バージョン管理）
@Recordable
struct LegacyData {
    #Directory<LegacyData>(
        "legacy",
        "data",
        layer: .recordStoreVersion(1)
    )
    #PrimaryKey<LegacyData>([\.id])

    var id: Int64
}
```

### マルチテナント

```swift
// 4. Partition を使用したマルチテナント
@Recordable
struct Order {
    #Directory<Order>(
        "tenants",
        Field(\Order.accountID),
        "orders",
        layer: .partition
    )
    #PrimaryKey<Order>([\.orderID])

    var orderID: Int64
    var accountID: String
    var amount: Double
}

// Usage:
let orderStore = try await Order.store(
    accountID: "account-123",
    database: database,
    metaData: metaData
)

let order = Order(orderID: 1, accountID: "account-123", amount: 100.0)
try await orderStore.save(order)

// テナント削除
try await database.directory.remove(["tenants", "account-123"])
```

### 複数階層

```swift
// 5. ネストした階層構造
@Recordable
struct Message {
    #Directory<Message>(
        "tenants",
        Field(\Message.accountID),
        "channels",
        Field(\Message.channelID),
        "messages",
        layer: .partition
    )
    #PrimaryKey<Message>([\.messageID])

    var messageID: Int64
    var accountID: String
    var channelID: String
    var content: String
}

// Usage:
let messageStore = try await Message.store(
    accountID: "account-123",
    channelID: "channel-456",
    database: database,
    metaData: metaData
)
```

### 特殊なストレージタイプ

```swift
// 6. Lucene インデックス
@Recordable
struct Document {
    #Directory<Document>(
        "app",
        "documents",
        layer: .luceneIndex
    )
    #PrimaryKey<Document>([\.documentID])

    var documentID: Int64
    var content: String
}

// 7. 時系列データ
@Recordable
struct Event {
    #Directory<Event>(
        "app",
        "events",
        layer: .timeSeries
    )
    #PrimaryKey<Event>([\.eventID])

    var eventID: Int64
    var timestamp: Date
}

// 8. カスタム layer
@Recordable
struct CustomData {
    #Directory<CustomData>(
        "app",
        "custom",
        layer: "my_custom_format_v2"
    )
    #PrimaryKey<CustomData>([\.id])

    var id: Int64
}
```

---

## 次のステップ

### Phase 2b: Directory Layer 実装

1. ✅ **設計ドキュメント作成** (このドキュメント)
2. ⏳ **DirectoryLayer 型実装** (`Sources/FDBRecordLayer/Core/DirectoryLayer.swift`)
3. ⏳ **Directory Layer 実装** (`Sources/FDBRecordLayer/Core/Directory.swift`)
4. ⏳ **DirectoryMacro 実装** (`Sources/FDBRecordLayerMacros/DirectoryMacro.swift`)
5. ⏳ **@Recordable マクロ更新** (AST から #Directory を読み取る)
6. ⏳ **テスト追加**
7. ⏳ **ユーザーガイド作成** (`docs/guides/directory-usage.md`)

---

## 参考資料

### FoundationDB 公式ドキュメント

- [Directory Layer](https://apple.github.io/foundationdb/developer-guide.html#directories)
- [Subspace Layer](https://apple.github.io/foundationdb/developer-guide.html#subspaces)
- [Tuple Layer](https://apple.github.io/foundationdb/data-modeling.html#tuples)

### このプロジェクト

- [CLAUDE.md](../../CLAUDE.md) - FoundationDB 使い方ガイド（Directory Layer セクション）
- [ARCHITECTURE.md](../ARCHITECTURE.md) - システムアーキテクチャ
- [swift-macro-design.md](./swift-macro-design.md) - マクロAPI設計

---

**Maintained by:** Claude Code
**Last Major Update:** 2025-01-15 (Directory Layer Design)
