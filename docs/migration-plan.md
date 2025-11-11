# マイグレーション計画

## 概要

既存の `fdb-record-layer` を3層アーキテクチャ（Core / Server / Client）に段階的に移行する計画です。

**目標**:
- クライアント・サーバー間でモデル定義を共有可能にする
- サーバー専用機能（インデックス、ディレクトリ）を明確に分離
- 既存のテストとコードベースへの影響を最小化

---

## Phase 1: 新しいパッケージ構造の準備

### ステップ 1.1: Package.swift の更新

```swift
// Package.swift

let package = Package(
    name: "fdb-record-layer",
    platforms: [.macOS(.v15)],
    products: [
        // 既存パッケージ（後方互換性のため維持）
        .library(name: "FDBRecordLayer", targets: ["FDBRecordLayer"]),

        // 新しいパッケージ
        .library(name: "FDBRecordCore", targets: ["FDBRecordCore"]),
        .library(name: "FDBRecordServer", targets: ["FDBRecordServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/1amageek/fdb-swift-bindings.git", branch: "feature/directory-layer"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.33.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/MrLotU/SwiftPrometheus.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.3.0"),
    ],
    targets: [
        // ========================================
        // FDBRecordCore（新規）
        // ========================================
        .macro(
            name: "FDBRecordCoreMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/FDBRecordCoreMacros"
        ),
        .target(
            name: "FDBRecordCore",
            dependencies: ["FDBRecordCoreMacros"],
            path: "Sources/FDBRecordCore"
        ),

        // ========================================
        // FDBRecordServer（新規）
        // ========================================
        .macro(
            name: "FDBRecordServerMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/FDBRecordServerMacros"
        ),
        .target(
            name: "FDBRecordServer",
            dependencies: [
                "FDBRecordCore",
                "FDBRecordServerMacros",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
                .product(name: "Collections", package: "swift-collections"),
            ],
            path: "Sources/FDBRecordServer"
        ),

        // ========================================
        // FDBRecordLayer（既存、移行期間中のみ維持）
        // ========================================
        .macro(
            name: "FDBRecordLayerMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/FDBRecordLayerMacros"
        ),
        .target(
            name: "FDBRecordLayer",
            dependencies: [
                "FDBRecordLayerMacros",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Collections", package: "swift-collections"),
            ],
            path: "Sources/FDBRecordLayer"
        ),

        // ========================================
        // Tests
        // ========================================
        .testTarget(
            name: "FDBRecordCoreTests",
            dependencies: ["FDBRecordCore"],
            path: "Tests/FDBRecordCoreTests"
        ),
        .testTarget(
            name: "FDBRecordServerTests",
            dependencies: [
                "FDBRecordCore",
                "FDBRecordServer",
            ],
            path: "Tests/FDBRecordServerTests",
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
        .testTarget(
            name: "FDBRecordLayerTests",
            dependencies: [
                "FDBRecordLayer",
                "FDBRecordLayerMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/FDBRecordLayerTests",
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
    ]
)
```

### ステップ 1.2: ディレクトリ作成

```bash
# FDBRecordCore
mkdir -p Sources/FDBRecordCore/Protocols
mkdir -p Sources/FDBRecordCore/Serialization
mkdir -p Sources/FDBRecordCoreMacros

# FDBRecordServer
mkdir -p Sources/FDBRecordServer/Store
mkdir -p Sources/FDBRecordServer/Index
mkdir -p Sources/FDBRecordServer/Query
mkdir -p Sources/FDBRecordServer/Directory
mkdir -p Sources/FDBRecordServer/Extensions
mkdir -p Sources/FDBRecordServerMacros

# Tests
mkdir -p Tests/FDBRecordCoreTests/MacroTests
mkdir -p Tests/FDBRecordCoreTests/SerializationTests
mkdir -p Tests/FDBRecordServerTests/StoreTests
mkdir -p Tests/FDBRecordServerTests/IndexTests
mkdir -p Tests/FDBRecordServerTests/QueryTests
```

---

## Phase 2: FDBRecordCore の実装

### ステップ 2.1: プロトコル定義

```bash
# Record.swift を作成
cat > Sources/FDBRecordCore/Protocols/Record.swift << 'EOF'
import Foundation

/// 永続化可能なレコード型の基本プロトコル
public protocol Record: Identifiable, Codable, Sendable {
    associatedtype ID: Hashable & Codable & Sendable
    static var recordName: String { get }
    var id: ID { get }
    static var __recordMetadata: RecordMetadataDescriptor { get }
}
EOF

# RecordMetadata.swift を作成
cat > Sources/FDBRecordCore/Protocols/RecordMetadata.swift << 'EOF'
import Foundation

public struct RecordMetadataDescriptor: Sendable {
    public let recordName: String
    public let primaryKeyPath: AnyKeyPath
    public let fields: [FieldDescriptor]

    public init(
        recordName: String,
        primaryKeyPath: AnyKeyPath,
        fields: [FieldDescriptor]
    ) {
        self.recordName = recordName
        self.primaryKeyPath = primaryKeyPath
        self.fields = fields
    }

    public struct FieldDescriptor: Sendable {
        public let name: String
        public let keyPath: AnyKeyPath
        public let fieldNumber: Int
        public let isTransient: Bool
        public let defaultValue: (any Sendable)?

        public init(
            name: String,
            keyPath: AnyKeyPath,
            fieldNumber: Int,
            isTransient: Bool = false,
            defaultValue: (any Sendable)? = nil
        ) {
            self.name = name
            self.keyPath = keyPath
            self.fieldNumber = fieldNumber
            self.isTransient = isTransient
            self.defaultValue = defaultValue
        }
    }
}
EOF
```

### ステップ 2.2: マクロAPI定義

```bash
cat > Sources/FDBRecordCore/Macros.swift << 'EOF'
@attached(member, names: named(id), named(recordName), named(__recordMetadata))
@attached(extension, conformances: Record)
public macro Record() = #externalMacro(module: "FDBRecordCoreMacros", type: "RecordMacro")

@attached(peer)
public macro ID() = #externalMacro(module: "FDBRecordCoreMacros", type: "IDMacro")

@attached(peer)
public macro Transient() = #externalMacro(module: "FDBRecordCoreMacros", type: "TransientMacro")

@attached(peer)
public macro Default(value: Any) = #externalMacro(module: "FDBRecordCoreMacros", type: "DefaultMacro")
EOF
```

### ステップ 2.3: マクロ実装（簡易版）

既存の `FDBRecordLayerMacros` から必要な部分をコピー・簡素化：

```bash
# RecordMacro.swift（@Recordable の簡素化版）
# - DatabaseProtocol, RecordStore への依存を削除
# - store() メソッド生成を削除
# - Codable conformance のみ生成

cp Sources/FDBRecordLayerMacros/RecordableMacro.swift Sources/FDBRecordCoreMacros/RecordMacro.swift
cp Sources/FDBRecordLayerMacros/PrimaryKeyMacro.swift Sources/FDBRecordCoreMacros/IDMacro.swift
cp Sources/FDBRecordLayerMacros/TransientMacro.swift Sources/FDBRecordCoreMacros/TransientMacro.swift
cp Sources/FDBRecordLayerMacros/DefaultMacro.swift Sources/FDBRecordCoreMacros/DefaultMacro.swift
cp Sources/FDBRecordLayerMacros/Plugin.swift Sources/FDBRecordCoreMacros/Plugin.swift

# TODO: RecordMacro.swift を編集してサーバー依存を削除
```

### ステップ 2.4: テスト作成

```bash
cat > Tests/FDBRecordCoreTests/MacroTests/RecordMacroTests.swift << 'EOF'
import XCTest
import FDBRecordCore

@Record
struct TestUser {
    @ID var userID: Int64
    var email: String
    var name: String

    @Transient
    var isLoggedIn: Bool = false
}

final class RecordMacroTests: XCTestCase {
    func testRecordConformance() {
        let user = TestUser(userID: 1, email: "test@example.com", name: "Test", isLoggedIn: false)

        // Record conformance
        XCTAssertEqual(user.id, 1)
        XCTAssertEqual(TestUser.recordName, "TestUser")

        // Metadata
        XCTAssertEqual(TestUser.__recordMetadata.recordName, "TestUser")
        XCTAssertEqual(TestUser.__recordMetadata.fields.count, 3) // userID, email, name (isLoggedIn除く)
    }

    func testCodable() throws {
        let user = TestUser(userID: 1, email: "test@example.com", name: "Test", isLoggedIn: true)

        // Encode
        let data = try JSONEncoder().encode(user)

        // Decode
        let decoded = try JSONDecoder().decode(TestUser.self, from: data)
        XCTAssertEqual(decoded.userID, 1)
        XCTAssertEqual(decoded.email, "test@example.com")
        XCTAssertEqual(decoded.name, "Test")
        XCTAssertEqual(decoded.isLoggedIn, false) // @Transient なのでデフォルト値
    }
}
EOF
```

---

## Phase 3: FDBRecordServer の実装

### ステップ 3.1: 既存コードの移行

```bash
# Store
cp -r Sources/FDBRecordLayer/Store Sources/FDBRecordServer/

# Index
cp -r Sources/FDBRecordLayer/Index Sources/FDBRecordServer/

# Query
cp -r Sources/FDBRecordLayer/Query Sources/FDBRecordServer/

# Transaction
cp -r Sources/FDBRecordLayer/Transaction Sources/FDBRecordServer/

# Schema
cp Sources/FDBRecordLayer/Schema/*.swift Sources/FDBRecordServer/Schema/

# Core utilities
mkdir -p Sources/FDBRecordServer/Core
cp Sources/FDBRecordLayer/Core/Recordable.swift Sources/FDBRecordServer/Core/
cp Sources/FDBRecordLayer/Core/RecordAccess.swift Sources/FDBRecordServer/Core/
cp Sources/FDBRecordLayer/Core/RecordSerializer.swift Sources/FDBRecordServer/Core/
```

### ステップ 3.2: import 文の更新

すべてのファイルで `import FDBRecordLayer` を `import FDBRecordCore` と `import FDBRecordServer` に変更：

```bash
find Sources/FDBRecordServer -name "*.swift" -exec sed -i '' 's/import FDBRecordLayer/import FDBRecordCore\nimport FDBRecordServer/g' {} \;
```

### ステップ 3.3: Recordable → Record への移行

```bash
# プロトコル名の置換
find Sources/FDBRecordServer -name "*.swift" -exec sed -i '' 's/: Recordable/: FDBRecordCore.Record/g' {} \;
find Sources/FDBRecordServer -name "*.swift" -exec sed -i '' 's/<Record: Recordable>/<Record: FDBRecordCore.Record>/g' {} \;
```

### ステップ 3.4: サーバーマクロの実装

```bash
# IndexMacro → ServerIndexMacro
cp Sources/FDBRecordLayerMacros/IndexMacro.swift Sources/FDBRecordServerMacros/ServerIndexMacro.swift

# UniqueMacro → ServerUniqueMacro
cp Sources/FDBRecordLayerMacros/UniqueMacro.swift Sources/FDBRecordServerMacros/ServerUniqueMacro.swift

# DirectoryMacro → ServerDirectoryMacro
cp Sources/FDBRecordLayerMacros/DirectoryMacro.swift Sources/FDBRecordServerMacros/ServerDirectoryMacro.swift

# Plugin
cp Sources/FDBRecordLayerMacros/Plugin.swift Sources/FDBRecordServerMacros/Plugin.swift

# TODO: マクロ名を ServerIndexMacro 等にリネーム
```

---

## Phase 4: テストの移行

### ステップ 4.1: 既存テストのコピー

```bash
# Store テスト
cp Tests/FDBRecordLayerTests/Store/RecordStoreTests.swift Tests/FDBRecordServerTests/StoreTests/

# Index テスト
cp Tests/FDBRecordLayerTests/Index/IndexManagerTests.swift Tests/FDBRecordServerTests/IndexTests/

# Query テスト
cp Tests/FDBRecordLayerTests/Query/*.swift Tests/FDBRecordServerTests/QueryTests/
```

### ステップ 4.2: テストの更新

```bash
# import 文の更新
find Tests/FDBRecordServerTests -name "*.swift" -exec sed -i '' 's/@testable import FDBRecordLayer/@testable import FDBRecordCore\n@testable import FDBRecordServer/g' {} \;

# マクロの更新
find Tests/FDBRecordServerTests -name "*.swift" -exec sed -i '' 's/@Recordable/@Record/g' {} \;
find Tests/FDBRecordServerTests -name "*.swift" -exec sed -i '' 's/@PrimaryKey/@ID/g' {} \;
find Tests/FDBRecordServerTests -name "*.swift" -exec sed -i '' 's/#Index/#ServerIndex/g' {} \;
find Tests/FDBRecordServerTests -name "*.swift" -exec sed -i '' 's/#Unique/#ServerUnique/g' {} \;
find Tests/FDBRecordServerTests -name "*.swift" -exec sed -i '' 's/#Directory/#ServerDirectory/g' {} \;
```

### ステップ 4.3: テスト実行

```bash
# FDBRecordCore テスト
swift test --filter FDBRecordCoreTests

# FDBRecordServer テスト
swift test --filter FDBRecordServerTests

# すべてのテスト
swift test
```

---

## Phase 5: ドキュメント更新

### ステップ 5.1: README.md の更新

```bash
cat > README.md << 'EOF'
# FoundationDB Record Layer (Swift)

SwiftでのRecord Layer実装。3層アーキテクチャでクライアント・サーバー間のモデル共有を実現。

## パッケージ構成

- **FDBRecordCore**: クライアント・サーバー共通のモデル定義
- **FDBRecordServer**: サーバーサイド専用機能（インデックス、クエリプランナー）
- **FDBRecordClient**: クライアントサイド専用機能（将来実装）

## インストール

### サーバーサイド

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

### クライアントサイド

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

## 使い方

### モデル定義（共通）

```swift
import FDBRecordCore

@Record
struct User {
    @ID var userID: Int64
    var email: String
    var name: String
}
```

### サーバーサイド

```swift
import FDBRecordServer

extension User {
    static let serverIndexes: [IndexDefinition<User>] = {
        #ServerIndex<User>([\.email])
    }()

    static func openStore(
        database: any DatabaseProtocol,
        schema: Schema
    ) async throws -> RecordStore<User> {
        // ...
    }
}
```

### クライアントサイド

```swift
import FDBRecordCore

// JSON API からデコード
let users = try JSONDecoder().decode([User].self, from: jsonData)
```

詳細は [docs/](docs/) を参照。
EOF
```

### ステップ 5.2: CLAUDE.md の更新

```bash
# CLAUDE.md に新しいパッケージ構造を追加
cat >> CLAUDE.md << 'EOF'

---

## Part 5: パッケージ構造

### 3層アーキテクチャ

**FDBRecordCore（共通レイヤー）**:
- クライアント・サーバー共通のモデル定義
- @Record, @ID, @Transient, @Default
- Codable 対応
- FoundationDB 非依存

**FDBRecordServer（サーバーレイヤー）**:
- RecordStore, IndexManager, QueryPlanner
- #ServerIndex, #ServerUnique, #ServerDirectory
- FoundationDB 依存

**FDBRecordClient（クライアントレイヤー、将来）**:
- 同期・キャッシュ機能
- オフライン対応

詳細: [docs/client-server-model-sharing.md](docs/client-server-model-sharing.md)
EOF
```

---

## Phase 6: 移行期間のサポート

### ステップ 6.1: 後方互換性レイヤー

既存のプロジェクトが `FDBRecordLayer` を使い続けられるように、互換性レイヤーを提供：

```swift
// Sources/FDBRecordLayer/Compatibility.swift

@available(*, deprecated, message: "Use @Record from FDBRecordCore instead")
public typealias Recordable = FDBRecordCore.Record

@available(*, deprecated, message: "Use @ID from FDBRecordCore instead")
public typealias PrimaryKey = FDBRecordCore.ID

// ... 他のエイリアス
```

### ステップ 6.2: 移行ガイド

```bash
cat > docs/migration-guide-v2.md << 'EOF'
# v2.0 移行ガイド

## 概要

v2.0 ではパッケージが分割されました。

## 変更点

| v1.x | v2.x |
|------|------|
| `import FDBRecordLayer` | `import FDBRecordCore` (共通) / `import FDBRecordServer` (サーバー) |
| `@Recordable` | `@Record` |
| `@PrimaryKey` | `@ID` |
| `#Index` | `#ServerIndex` |
| `#Unique` | `#ServerUnique` |
| `#Directory` | `#ServerDirectory` |

## 段階的な移行

### Step 1: 依存関係の更新

```swift
// Before
dependencies: [
    .product(name: "FDBRecordLayer", package: "fdb-record-layer")
]

// After（サーバー）
dependencies: [
    .product(name: "FDBRecordServer", package: "fdb-record-layer")
]

// After（クライアント）
dependencies: [
    .product(name: "FDBRecordCore", package: "fdb-record-layer")
]
```

### Step 2: import の更新

```swift
// Before
import FDBRecordLayer

// After
import FDBRecordCore
import FDBRecordServer  // サーバーのみ
```

### Step 3: マクロの更新

```swift
// Before
@Recordable
struct User {
    #Index<User>([\.email])
    @PrimaryKey var userID: Int64
}

// After（共通モデル）
@Record
struct User {
    @ID var userID: Int64
    var email: String
}

// After（サーバー拡張）
extension User {
    static let serverIndexes: [IndexDefinition<User>] = {
        #ServerIndex<User>([\.email])
    }()
}
```

## トラブルシューティング

**Q: 既存のテストが動かない**
A: import 文とマクロ名を更新してください。

**Q: クライアントアプリで FoundationDB が必要と言われる**
A: `FDBRecordCore` のみをインポートしてください。
EOF
```

---

## Phase 7: リリース

### ステップ 7.1: バージョンタグ

```bash
git tag -a v2.0.0-alpha.1 -m "Release v2.0.0-alpha.1: 3-layer architecture"
git push origin v2.0.0-alpha.1
```

### ステップ 7.2: リリースノート

```bash
cat > CHANGELOG.md << 'EOF'
# Changelog

## [2.0.0-alpha.1] - 2025-01-XX

### Added
- **FDBRecordCore**: クライアント・サーバー共通のモデル定義パッケージ
- **FDBRecordServer**: サーバー専用機能パッケージ
- `@Record`, `@ID`, `@Transient`, `@Default` マクロ（共通）
- `#ServerIndex`, `#ServerUnique`, `#ServerDirectory` マクロ（サーバー）

### Changed
- **Breaking**: パッケージを3層構造に分割
- **Breaking**: `@Recordable` → `@Record`
- **Breaking**: `@PrimaryKey` → `@ID`
- **Breaking**: `#Index` → `#ServerIndex`

### Deprecated
- `FDBRecordLayer` パッケージ（v3.0 で削除予定）

### Migration
詳細は [docs/migration-guide-v2.md](docs/migration-guide-v2.md) を参照。

## [1.0.0] - 2025-01-10

初回リリース
EOF
```

---

## タイムライン

| Phase | 期間 | 内容 |
|-------|------|------|
| **Phase 1** | 1日 | パッケージ構造準備 |
| **Phase 2** | 2-3日 | FDBRecordCore 実装 |
| **Phase 3** | 3-5日 | FDBRecordServer 実装 |
| **Phase 4** | 2-3日 | テスト移行 |
| **Phase 5** | 1日 | ドキュメント更新 |
| **Phase 6** | 1日 | 後方互換性 |
| **Phase 7** | 1日 | リリース |
| **合計** | **11-15日** | |

---

## リスク管理

### リスク 1: 既存テストの破壊

**対策**:
- `FDBRecordLayer` パッケージを v3.0 まで維持
- 段階的な移行をサポート
- CI/CD で両方のパッケージをテスト

### リスク 2: マクロ実装の複雑さ

**対策**:
- 既存のマクロコードを最大限再利用
- 段階的に機能を追加
- ユニットテストを充実

### リスク 3: ドキュメント不足

**対策**:
- 移行ガイドを詳細に記述
- サンプルコードを提供
- GitHub Discussions でサポート

---

## チェックリスト

### Phase 1
- [ ] Package.swift 更新
- [ ] ディレクトリ作成
- [ ] ビルド確認

### Phase 2
- [ ] FDBRecordCore プロトコル実装
- [ ] @Record マクロ実装
- [ ] @ID, @Transient, @Default マクロ実装
- [ ] テスト作成・実行

### Phase 3
- [ ] 既存コードの FDBRecordServer への移行
- [ ] import 文更新
- [ ] #ServerIndex, #ServerUnique, #ServerDirectory マクロ実装
- [ ] ビルド確認

### Phase 4
- [ ] テストコードの移行
- [ ] テスト実行・修正
- [ ] すべてのテストが通過

### Phase 5
- [ ] README.md 更新
- [ ] CLAUDE.md 更新
- [ ] API ドキュメント作成

### Phase 6
- [ ] 後方互換性レイヤー実装
- [ ] 移行ガイド作成
- [ ] サンプルコード作成

### Phase 7
- [ ] バージョンタグ作成
- [ ] CHANGELOG.md 更新
- [ ] GitHub Release 作成

---

## まとめ

この計画により、既存のコードベースへの影響を最小化しつつ、クライアント・サーバー間でモデルを共有可能な3層アーキテクチャに移行できます。

**次のステップ**: Phase 1 から開始してください。
