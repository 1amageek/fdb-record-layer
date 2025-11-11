# クライアント・サーバー間のモデル共有設計

## 問題分析

### 現在のマクロAPIの課題

現在の`@Recordable`マクロは以下のサーバーサイド依存を持っています：

```swift
@Recordable
struct User {
    #Index<User>([\.email])
    #Unique<User>([\.email])
    #Directory<User>("tenants", Field(\.tenantID), "users", layer: .partition)

    @PrimaryKey var userID: Int64
    var email: String
    var name: String
}

// マクロが生成するコード（サーバー依存）:
extension User: Recordable {
    // DatabaseProtocol, RecordStore に依存
    static func store(
        tenantID: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<User> { ... }

    // IndexDefinition に依存
    static var indexDefinitions: [IndexDefinition] { ... }
}
```

**問題点**:
1. `DatabaseProtocol`, `RecordStore`, `Schema` などのサーバー専用型への依存
2. クライアントアプリに含めるとサーバー側の全依存関係（FoundationDB、Protobuf、ディレクトリレイヤーなど）が必要
3. モデル定義とサーバー実装が密結合

---

## 解決策: 3層アーキテクチャ

### パッケージ構造

```
FDBRecordLayer/
├── FDBRecordCore/              # 【Layer 1】クライアント・サーバー共通
│   ├── Protocols/
│   │   ├── Record.swift        # protocol Record: Identifiable, Codable, Sendable
│   │   └── RecordMetadata.swift # メタデータ記述子（型情報のみ）
│   ├── Macros/
│   │   ├── @Record             # 基本的な型生成のみ
│   │   ├── @ID                 # プライマリキーマーク
│   │   ├── @Transient          # エンコード除外
│   │   └── @Default            # デフォルト値
│   └── Serialization/
│       └── RecordCoder.swift   # Codable ベースのシリアライゼーション
│
├── FDBRecordServer/            # 【Layer 2】サーバーサイドのみ
│   ├── Store/
│   │   ├── RecordStore.swift
│   │   └── Schema.swift
│   ├── Index/
│   │   ├── IndexManager.swift
│   │   ├── IndexDefinition.swift
│   │   └── IndexMaintainer.swift
│   ├── Query/
│   │   └── RecordQueryPlanner.swift
│   ├── Macros/
│   │   ├── #Index              # インデックス定義（サーバーのみ）
│   │   ├── #Unique             # ユニーク制約（サーバーのみ）
│   │   └── #Directory          # ディレクトリ設定（サーバーのみ）
│   └── Extensions/
│       └── Record+Server.swift # store()メソッドなど
│
└── FDBRecordClient/            # 【Layer 3】クライアントサイドのみ
    ├── Sync/
    │   ├── RecordSyncManager.swift
    │   └── ConflictResolver.swift
    └── Cache/
        └── RecordCache.swift
```

---

## Layer 1: FDBRecordCore（共通レイヤー）

### プロトコル定義

```swift
// FDBRecordCore/Protocols/Record.swift

/// 永続化可能なレコード型の基本プロトコル
/// クライアント・サーバー間で共有可能
public protocol Record: Identifiable, Codable, Sendable {
    /// プライマリキーの型
    associatedtype ID: Hashable & Codable & Sendable

    /// レコードタイプ名（Protobuf互換性のため）
    static var recordName: String { get }

    /// プライマリキー
    var id: ID { get }
}

/// レコードのメタデータ記述子
/// 実行時に型情報を提供（サーバー側で使用）
public struct RecordMetadataDescriptor: Sendable {
    public let recordName: String
    public let primaryKeyPath: PartialKeyPath<Any>
    public let fields: [FieldDescriptor]

    public struct FieldDescriptor: Sendable {
        public let name: String
        public let keyPath: PartialKeyPath<Any>
        public let fieldNumber: Int  // Protobuf field number
        public let isTransient: Bool
        public let defaultValue: (any Sendable)?
    }
}
```

### マクロAPI（共通）

```swift
// FDBRecordCore/Macros/RecordMacro.swift

/// クライアント・サーバー共通のモデル定義マクロ
/// サーバー固有の機能には依存しない
@attached(member, names: named(id), named(recordName), named(__recordMetadata))
@attached(extension, conformances: Record)
public macro Record() = #externalMacro(module: "FDBRecordCoreMacros", type: "RecordMacro")

/// プライマリキーのマーク（変更なし）
@attached(peer)
public macro ID() = #externalMacro(module: "FDBRecordCoreMacros", type: "IDMacro")

/// トランジェントフィールド（変更なし）
@attached(peer)
public macro Transient() = #externalMacro(module: "FDBRecordCoreMacros", type: "TransientMacro")

/// デフォルト値（変更なし）
@attached(peer)
public macro Default(value: Any) = #externalMacro(module: "FDBRecordCoreMacros", type: "DefaultMacro")
```

### 使用例（クライアント・サーバー共通）

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

// マクロが生成するコード:
extension User: Record {
    static var recordName: String { "User" }

    var id: Int64 { userID }

    // メタデータ記述子（サーバー側で使用）
    static let __recordMetadata = RecordMetadataDescriptor(
        recordName: "User",
        primaryKeyPath: \User.userID,
        fields: [
            .init(name: "userID", keyPath: \User.userID, fieldNumber: 1, isTransient: false, defaultValue: nil),
            .init(name: "email", keyPath: \User.email, fieldNumber: 2, isTransient: false, defaultValue: nil),
            .init(name: "name", keyPath: \User.name, fieldNumber: 3, isTransient: false, defaultValue: nil),
            .init(name: "age", keyPath: \User.age, fieldNumber: 4, isTransient: false, defaultValue: nil),
            .init(name: "createdAt", keyPath: \User.createdAt, fieldNumber: 5, isTransient: false, defaultValue: Date()),
            // isLoggedIn は isTransient = true なので除外
        ]
    )
}

// Codable conformance も自動生成
// CodingKeys, init(from:), encode(to:) など
```

---

## Layer 2: FDBRecordServer（サーバーレイヤー）

### サーバー専用マクロ

```swift
// FDBRecordServer/Macros/ServerMacros.swift

/// サーバーサイドのインデックス定義
/// サーバープロジェクトでのみ使用
#if canImport(FDBRecordServer)

@freestanding(declaration)
public macro ServerIndex<T: Record>(_ indices: [PartialKeyPath<T>]..., name: String? = nil) =
    #externalMacro(module: "FDBRecordServerMacros", type: "ServerIndexMacro")

@freestanding(declaration)
public macro ServerUnique<T: Record>(_ constraints: [PartialKeyPath<T>]...) =
    #externalMacro(module: "FDBRecordServerMacros", type: "ServerUniqueMacro")

@freestanding(declaration)
public macro ServerDirectory<T: Record>(_ pathElements: any DirectoryPathElement..., layer: DirectoryLayerType = .recordStore) =
    #externalMacro(module: "FDBRecordServerMacros", type: "ServerDirectoryMacro")

#endif
```

### サーバー側のモデル定義

```swift
// Server/Models/User+Server.swift
import FDBRecordCore
import FDBRecordServer

// モデル定義は FDBRecordCore から再エクスポート
// typealias や extension で拡張は不要（既に定義されている）

// サーバーサイドのメタデータ定義
extension User {
    // インデックス定義
    static let serverIndexes: [IndexDefinition<User>] = {
        #ServerIndex<User>([\.email], name: "email_index")
        #ServerUnique<User>([\.email])
    }()

    // ディレクトリ設定
    static let serverDirectory: DirectoryConfiguration = {
        #ServerDirectory<User>("tenants", Field(\.tenantID), "users", layer: .partition)
    }()
}

// RecordStore インスタンス作成のヘルパー
extension User {
    static func openStore(
        tenantID: String,
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<User> {
        let dir = try await database.directoryLayer.createOrOpen(
            path: ["tenants", tenantID, "users"],
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
```

### RecordStoreの改善

```swift
// FDBRecordServer/Store/RecordStore.swift

public final class RecordStore<Record: FDBRecordCore.Record>: Sendable {
    // 初期化時にインデックス定義を受け取る
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        indexes: [IndexDefinition<Record>] = []
    ) {
        self.database = database
        self.subspace = subspace
        self.schema = schema
        self.indexManager = IndexManager(
            database: database,
            subspace: subspace,
            indexes: indexes
        )
    }

    // ... 他のメソッドは変更なし
}
```

---

## Layer 3: FDBRecordClient（クライアントレイヤー）

### クライアント側のモデル使用

```swift
// iOS/macOS Client App
import FDBRecordCore

// モデル定義は共通
// サーバー固有のマクロは一切使用しない

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

// クライアント側の使用例
struct UserListView: View {
    @State private var users: [User] = []

    var body: some View {
        List(users) { user in
            VStack(alignment: .leading) {
                Text(user.name)
                Text(user.email)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// JSON API レスポンスのデコード
let jsonData = try await fetchUsers()
let users = try JSONDecoder().decode([User].self, from: jsonData)
```

---

## マイグレーション戦略

### Phase 1: パッケージ分割

```bash
# 1. 新しいターゲットを作成
Package.swift:
  - FDBRecordCore (共通)
  - FDBRecordCoreMacros (共通マクロ)
  - FDBRecordServer (サーバー)
  - FDBRecordServerMacros (サーバーマクロ)

# 2. 既存コードを段階的に移行
Sources/FDBRecordCore/
  ← Sources/FDBRecordLayer/Protocols/Recordable.swift (抽象化)
  ← Sources/FDBRecordLayer/Serialization/ (Codable対応)

Sources/FDBRecordCoreMacros/
  ← Sources/FDBRecordLayerMacros/RecordableMacro.swift (簡素化)
  ← Sources/FDBRecordLayerMacros/PrimaryKeyMacro.swift
  ← Sources/FDBRecordLayerMacros/TransientMacro.swift
  ← Sources/FDBRecordLayerMacros/DefaultMacro.swift

Sources/FDBRecordServer/
  ← Sources/FDBRecordLayer/Store/
  ← Sources/FDBRecordLayer/Index/
  ← Sources/FDBRecordLayer/Query/

Sources/FDBRecordServerMacros/
  ← Sources/FDBRecordLayerMacros/IndexMacro.swift (リネーム)
  ← Sources/FDBRecordLayerMacros/UniqueMacro.swift (リネーム)
  ← Sources/FDBRecordLayerMacros/DirectoryMacro.swift (リネーム)
```

### Phase 2: マクロの書き換え

```swift
// Before (サーバー依存):
@Recordable
struct User {
    #Index<User>([\.email])
    #Directory<User>("users")

    @PrimaryKey var userID: Int64
    var email: String
}

// After (分離):
// Shared/Models/User.swift
import FDBRecordCore

@Record
struct User {
    @ID var userID: Int64
    var email: String
}

// Server/Models/User+Server.swift
import FDBRecordServer

extension User {
    static let serverIndexes: [IndexDefinition<User>] = {
        #ServerIndex<User>([\.email])
    }()

    static let serverDirectory: DirectoryConfiguration = {
        #ServerDirectory<User>("users")
    }()
}
```

### Phase 3: テストの更新

```swift
// Before:
let store = try await User.store(database: db, schema: schema)

// After:
let store = try await User.openStore(
    database: db,
    schema: schema,
    indexes: User.serverIndexes,
    directory: User.serverDirectory
)
```

---

## 利点

### 1. クリーンな分離

- ✅ モデル定義はクライアント・サーバーで完全に共有可能
- ✅ サーバー専用機能（インデックス、ディレクトリ）は明確に分離
- ✅ クライアントアプリに不要な依存関係を含まない

### 2. 段階的な移行

- ✅ 既存のテストは動作し続ける（APIの互換性を保つ）
- ✅ 新旧両方のAPIを一時的にサポート可能
- ✅ プロジェクトごとに段階的に移行

### 3. 型安全性の維持

- ✅ `@Record`マクロで基本的な型生成
- ✅ サーバー側でも`Record`プロトコルを活用
- ✅ KeyPath ベースのタイプセーフなAPI

### 4. 将来の拡張性

- ✅ クライアント専用機能（オフライン同期、キャッシュなど）を追加可能
- ✅ 他のバックエンド（PostgreSQL、MongoDB など）への対応が容易
- ✅ マルチプラットフォーム対応（iOS、macOS、Linux）

---

## パッケージ依存関係

```swift
// Package.swift

let package = Package(
    name: "fdb-record-layer",
    products: [
        // クライアント・サーバー共通
        .library(name: "FDBRecordCore", targets: ["FDBRecordCore"]),

        // サーバー専用
        .library(name: "FDBRecordServer", targets: ["FDBRecordServer"]),

        // クライアント専用（将来追加）
        .library(name: "FDBRecordClient", targets: ["FDBRecordClient"]),
    ],
    dependencies: [
        // 共通依存
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),

        // サーバー専用依存
        .package(url: "https://github.com/1amageek/fdb-swift-bindings.git", branch: "feature/directory-layer"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.33.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
    ],
    targets: [
        // ========================================
        // FDBRecordCore（共通レイヤー）
        // ========================================
        .macro(
            name: "FDBRecordCoreMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "FDBRecordCore",
            dependencies: ["FDBRecordCoreMacros"]
        ),

        // ========================================
        // FDBRecordServer（サーバーレイヤー）
        // ========================================
        .macro(
            name: "FDBRecordServerMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "FDBRecordServer",
            dependencies: [
                "FDBRecordCore",
                "FDBRecordServerMacros",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // ========================================
        // FDBRecordClient（クライアントレイヤー）
        // ========================================
        .target(
            name: "FDBRecordClient",
            dependencies: ["FDBRecordCore"]
        ),

        // ========================================
        // Tests
        // ========================================
        .testTarget(
            name: "FDBRecordCoreTests",
            dependencies: ["FDBRecordCore"]
        ),
        .testTarget(
            name: "FDBRecordServerTests",
            dependencies: [
                "FDBRecordCore",
                "FDBRecordServer",
            ]
        ),
    ]
)
```

---

## 今後の実装タスク

### 優先度: 高

- [ ] `FDBRecordCore`パッケージの作成
- [ ] `@Record`マクロの実装（`@Recordable`から簡素化）
- [ ] `RecordMetadataDescriptor`の実装
- [ ] `FDBRecordServer`への既存コードの移行
- [ ] `#ServerIndex`, `#ServerUnique`, `#ServerDirectory`マクロの実装

### 優先度: 中

- [ ] サーバー側のヘルパーメソッド（`openStore()`など）
- [ ] テストの書き直し（新しいAPIに対応）
- [ ] ドキュメントの更新

### 優先度: 低（将来）

- [ ] `FDBRecordClient`パッケージの作成
- [ ] オフライン同期機能
- [ ] クライアント側キャッシュ

---

## まとめ

この設計により、以下を実現します：

1. **モデル定義の共有**: `@Record`マクロで定義したモデルをクライアント・サーバー間で共有
2. **クリーンな分離**: サーバー専用機能（インデックス、ディレクトリ）を明確に分離
3. **段階的な移行**: 既存のコードベースから段階的に移行可能
4. **将来の拡張性**: クライアント専用機能や他のバックエンドへの対応が容易

この3層アーキテクチャ（Core / Server / Client）により、モジュール性とコードの再利用性が大幅に向上します。
