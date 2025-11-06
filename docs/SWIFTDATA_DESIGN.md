# SwiftData-Style API Design for FDB Record Layer

**作成日**: 2025-01-06
**ステータス**: 設計中
**対象読者**: FDB Record Layer開発者

---

## 📋 概要

このドキュメントは、FDB Record LayerにSwiftData風のAPIを導入する設計を記述します。

### 設計目標

1. **SwiftData互換のAPI**: Swift開発者に親しみやすいインターフェース
2. **学習コストの最小化**: SwiftDataの知識を活用可能
3. **既存コードとの互換性**: RecordMetaDataとRecordStoreの既存実装を活用
4. **段階的移行**: 既存コードへの影響を最小化
5. **型安全性**: コンパイル時の型チェック

### SwiftDataとの対応

| SwiftData | FDB Record Layer | 役割 |
|-----------|------------------|------|
| `Schema` | `Schema` (新規) | 全ての型とバージョンを管理 |
| `Schema.Entity` | `Schema.Entity` (新規) | 型のブループリント |
| `ModelContainer` | `RecordContainer` (新規) | SchemaとDBを組み合わせたコンテナ |
| `ModelConfiguration` | `DatabaseConfiguration` (新規) | データベース設定 |
| `PersistentModel` | `Recordable` (既存) | モデルプロトコル |
| `VersionedSchema` | `VersionedSchema` (新規) | バージョン管理 |
| `SchemaMigrationPlan` | `SchemaMigrationPlan` (新規) | マイグレーション |

---

## 🏗 アーキテクチャ

### コンポーネント構造

```
┌─────────────────────────────────────────────────────────┐
│                    Application Layer                     │
│              @main struct MyApp { ... }                  │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│               RecordContainer (New)                      │
│  - schema: Schema                                        │
│  - configuration: DatabaseConfiguration                  │
│  - database: DatabaseProtocol                           │
│                                                          │
│  func store<T>(for:path:) -> RecordStore<T>            │
└────────────┬─────────────────────┬──────────────────────┘
             │                     │
┌────────────▼────────────┐  ┌────▼─────────────────────┐
│   Schema (New)          │  │ DatabaseConfiguration    │
│  - entities             │  │  - apiVersion            │
│  - version              │  │  - clusterFilePath       │
│  - recordMetaData (内部)│  │  - isStoredInMemoryOnly  │
└────────────┬────────────┘  └──────────────────────────┘
             │
┌────────────▼────────────┐
│  Schema.Entity (New)    │
│  - name                 │
│  - attributes           │
│  - relationships        │
│  - indices              │
│  - uniquenessConstraints│
│                         │
│  - recordType (内部)    │
└────────────┬────────────┘
             │
┌────────────▼────────────┐
│  RecordMetaData (既存)  │
│  - recordTypes          │
│  - indexes              │
│  - version              │
└─────────────────────────┘
```

### データフロー

```
1. アプリ起動時:
   Schema作成 → RecordContainer作成 → グローバル保持

2. データアクセス時:
   container.store(for:path:) → RecordStore取得 → CRUD操作

3. マイグレーション時:
   VersionedSchema定義 → SchemaMigrationPlan定義 → Container初期化時に実行
```

---

## 📦 コンポーネント設計

### 1. Schema

**目的**: アプリのモデルクラスをデータストアにマッピング

**責務**:
- Recordable型の登録管理
- バージョン管理
- Entityへのアクセス提供
- RecordMetaDataのラッパー（内部）

**API**:

```swift
public final class Schema: Sendable {
    // バージョン
    public struct Version: Sendable, Hashable, Codable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(_ major: Int, _ minor: Int, _ patch: Int)
    }

    // プロパティ
    public let version: Version
    public let encodingVersion: Version
    public let entities: [Entity]
    public let entitiesByName: [String: Entity]

    // 内部実装
    internal let recordMetaData: RecordMetaData

    // イニシャライザ
    public init(_ types: [any Recordable.Type], version: Version = Version(1, 0, 0)) throws
    public init(_ entities: Entity..., version: Version = Version(1, 0, 0)) throws
    public convenience init(versionedSchema: any VersionedSchema.Type) throws

    // Entity アクセス
    public func entity<T: Recordable>(for type: T.Type) -> Entity?
    public func entity(named name: String) -> Entity?

    // 永続化（将来）
    public func save(to url: URL) throws
    public static func load(from url: URL) throws -> Schema
}
```

**設計判断**:
- ✅ RecordMetaDataを内部に持つ（既存コード活用）
- ✅ SwiftData互換のAPIを外部公開
- ✅ Version構造体でセマンティックバージョニング
- ✅ Entityは遅延評価ではなく初期化時に構築（パフォーマンス最適化）

---

### 2. Schema.Entity

**目的**: モデルクラスのブループリント

**責務**:
- 属性（attributes）の管理
- リレーションシップ（relationships）の管理
- インデックス情報の提供
- ユニーク制約の提供

**API**:

```swift
extension Schema {
    public final class Entity: Sendable, Hashable {
        // Identity
        public let name: String

        // Properties
        public let attributes: Set<Attribute>
        public let attributesByName: [String: Attribute]
        public let relationships: Set<Relationship>
        public let relationshipsByName: [String: Relationship]
        public var properties: [any SchemaProperty] { get }

        // Constraints
        public let indices: [[String]]
        public let uniquenessConstraints: [[String]]

        // Inheritance (将来)
        public let superentity: Entity?
        public let superentityName: String?
        public let subentities: Set<Entity>

        // 内部
        internal let recordType: RecordType
        internal let indexObjects: [Index]

        internal init(name: String, recordType: RecordType, metaData: RecordMetaData)
    }

    // Attribute
    public struct Attribute: Sendable, Hashable, SchemaProperty {
        public let name: String
        public let type: FieldType
        public let isOptional: Bool
        public let isPrimaryKey: Bool
        public var propertyName: String { name }
    }

    // Relationship (将来)
    public struct Relationship: Sendable, Hashable, SchemaProperty {
        public let name: String
        public let destinationEntityName: String
        public let deleteRule: DeleteRule
        public let isToMany: Bool
        public var propertyName: String { name }

        public enum DeleteRule {
            case nullify
            case cascade
            case deny
        }
    }
}

public protocol SchemaProperty: Sendable {
    var propertyName: String { get }
}
```

**設計判断**:
- ✅ RecordTypeをラップ（既存実装活用）
- ✅ Indexから`indices`と`uniquenessConstraints`を抽出
- ✅ Relationshipは将来の拡張として定義のみ
- ✅ SwiftData互換のプロパティ名

**インデックスマッピング**:

```swift
// RecordMetaDataのIndex
Index(name: "user_by_email", fields: [FieldKeyExpression("email")], isUnique: true)

// Schema.Entityでの表現
entity.indices = [["email"]]
entity.uniquenessConstraints = [["email"]]

// 複合インデックス
Index(name: "user_by_city_age", fields: [FieldKeyExpression("city"), FieldKeyExpression("age")])

// Schema.Entityでの表現
entity.indices = [["city", "age"]]
```

---

### 3. RecordContainer

**目的**: アプリのスキーマとモデルストレージ設定を管理

**責務**:
- Schemaとデータベースの統合管理
- RecordStoreの作成
- マイグレーションの実行（将来）
- StatisticsManagerの管理

**API**:

```swift
public final class RecordContainer: Sendable {
    // Properties
    public let schema: Schema
    public let configuration: DatabaseConfiguration
    public let migrationPlan: (any SchemaMigrationPlan.Type)?

    private let database: any DatabaseProtocol
    private let statisticsManager: (any StatisticsManagerProtocol)?

    // Initialization
    public init(
        for schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configurations: DatabaseConfiguration
    ) throws

    public convenience init(
        for types: any Recordable.Type...,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configurations: DatabaseConfiguration
    ) throws

    // RecordStore Access
    public func store<Record: Recordable>(
        for type: Record.Type,
        path: String
    ) -> RecordStore<Record>

    public func store<Record: Recordable>(
        for type: Record.Type,
        subspace: Subspace
    ) -> RecordStore<Record>

    // Container Management
    public func deleteAllData() async throws
    public func erase() throws
}
```

**設計判断**:
- ✅ DatabaseProtocolを内部に持つ（FDB接続管理）
- ✅ StatisticsManagerをオプションで管理
- ✅ `store(for:path:)`でFirestore風のパス指定をサポート
- ✅ 便利イニシャライザで型の配列から直接作成可能
- ✅ SwiftData互換のライフサイクルメソッド

**パス → Subspace変換**:

```swift
// パス文字列
"accounts/acct-001/users"

// Subspace変換後
Subspace(rootPrefix: Data())
  .subspace(Tuple(["accounts"]))
  .subspace(Tuple(["acct-001"]))
  .subspace(Tuple(["users"]))
```

---

### 4. DatabaseConfiguration

**目的**: データベース設定を記述

**責務**:
- FoundationDB API version指定
- クラスターファイルパス指定
- メモリのみモード設定
- StatisticsManager設定

**API**:

```swift
public struct DatabaseConfiguration: Sendable, Hashable {
    // Properties
    public let apiVersion: Int32
    public let clusterFilePath: String?
    public let isStoredInMemoryOnly: Bool
    public let allowsSave: Bool
    public let statisticsSubspace: Subspace?

    // Initialization
    public init(
        apiVersion: Int32 = 630,
        clusterFilePath: String? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        statisticsSubspace: Subspace? = nil
    )

    public init(
        for types: any Recordable.Type...,
        isStoredInMemoryOnly: Bool = false
    )
}
```

**設計判断**:
- ✅ SwiftDataのModelConfigurationに対応
- ✅ FDB固有の設定を追加（apiVersion, clusterFilePath）
- ✅ statisticsSubspaceでStatisticsManagerを設定
- ✅ デフォルト値で簡潔な使用を可能に

---

### 5. バージョン管理とマイグレーション

**目的**: スキーマの進化とデータマイグレーションを管理

#### VersionedSchema

```swift
public protocol VersionedSchema: Sendable {
    static var versionIdentifier: Schema.Version { get }
    static var models: [any Recordable.Type] { get }
}
```

**使用例**:

```swift
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any Recordable.Type] = [User.self, Order.self]
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any Recordable.Type] = [User.self, Order.self, Message.self]
}
```

#### SchemaMigrationPlan

```swift
public protocol SchemaMigrationPlan: Sendable {
    static var schemas: [any VersionedSchema.Type] { get }
    static var stages: [MigrationStage] { get }
}
```

#### MigrationStage

```swift
public enum MigrationStage: Sendable {
    case lightweight(
        fromVersion: any VersionedSchema.Type,
        toVersion: any VersionedSchema.Type
    )

    case custom(
        fromVersion: any VersionedSchema.Type,
        toVersion: any VersionedSchema.Type,
        willMigrate: (@Sendable (Schema) async throws -> Void)?,
        didMigrate: (@Sendable (Schema) async throws -> Void)?
    )
}
```

**使用例**:

```swift
enum MyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        SchemaV1.self,
        SchemaV2.self
    ]

    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
    ]
}
```

**設計判断**:
- ✅ SwiftData完全互換のプロトコル
- ✅ 軽量マイグレーション（自動）とカスタムマイグレーションをサポート
- ⚠️ マイグレーション実行は将来の実装（Phase 1では定義のみ）

---

### 6. Subspace拡張

**目的**: Firestore風のパス文字列をSubspaceに変換

**API**:

```swift
extension Subspace {
    public static func fromPath(_ path: String) -> Subspace
}
```

**使用例**:

```swift
let subspace = Subspace.fromPath("accounts/acct-001/users")
// → Subspace(["accounts", "acct-001", "users"])
```

**設計判断**:
- ✅ `/`で区切られたパス文字列を解析
- ✅ 各コンポーネントをTupleでSubspaceに変換
- ✅ Firestoreのコレクション/ドキュメントパスと同じ感覚

---

## 💡 使用例

### 基本的な使用

```swift
@main
struct MyApp {
    // SwiftDataと同じパターン！
    static let sharedContainer: RecordContainer = {
        do {
            // 1. Schemaを作成
            let schema = try Schema(
                [User.self, Order.self, Message.self],
                version: Schema.Version(1, 0, 0)
            )

            // 2. Configurationを作成
            let configuration = DatabaseConfiguration(
                apiVersion: 630,
                statisticsSubspace: Subspace(rootPrefix: "stats")
            )

            // 3. Containerを作成
            return try RecordContainer(
                for: schema,
                configurations: configuration
            )
        } catch {
            fatalError("Could not create RecordContainer: \(error)")
        }
    }()

    static func main() async throws {
        // RecordStoreを取得
        let userStore = sharedContainer.store(
            for: User.self,
            path: "accounts/acct-001/users"
        )

        // データ操作
        let user = User(userID: 1, name: "Alice", email: "alice@example.com")
        try await userStore.save(user)

        let fetchedUser = try await userStore.fetch(by: 1)
        print("User: \(fetchedUser?.name ?? "not found")")
    }
}
```

### 便利イニシャライザ

```swift
// より簡潔な書き方
let container = try RecordContainer(
    for: User.self, Order.self, Message.self,
    configurations: DatabaseConfiguration(apiVersion: 630)
)
```

### マイグレーション

```swift
// バージョン1のスキーマ
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any Recordable.Type] = [User.self, Order.self]
}

// バージョン2のスキーマ（Messageを追加）
enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any Recordable.Type] = [User.self, Order.self, Message.self]
}

// マイグレーションプラン
enum MyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        SchemaV1.self,
        SchemaV2.self
    ]

    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
    ]
}

// Containerを作成（マイグレーション付き）
let container = try RecordContainer(
    for: Schema(versionedSchema: SchemaV2.self),
    migrationPlan: MyMigrationPlan.self,
    configurations: DatabaseConfiguration(apiVersion: 630)
)
```

### Multi-type Index

```swift
// 複数の型にまたがるインデックス
let schema = try Schema([User.self, Order.self, Message.self])

// 内部のRecordMetaDataでMulti-type indexを定義
// Note: 現在のRecordMetaDataは未サポート、将来の拡張
schema.recordMetaData.addMultiTypeIndex(
    name: "all_records_by_created_at",
    types: ["User", "Order", "Message"],
    field: "createdAt"
)
```

---

## 🔄 既存コードとの互換性

### 移行パス

**Phase 1: 新APIの導入（既存API並行）**

```swift
// 既存API（引き続き動作）
let metaData = RecordMetaData()
try metaData.registerRecordType(User.self)
let store = RecordStore<User>(
    database: database,
    subspace: subspace,
    metaData: metaData,
    statisticsManager: statsManager
)

// 新API（推奨）
let schema = try Schema([User.self])
let container = try RecordContainer(
    for: schema,
    configurations: DatabaseConfiguration(apiVersion: 630)
)
let store = container.store(for: User.self, path: "users")
```

**Phase 2: 既存コードの段階的移行**

1. アプリケーションコードから順次移行
2. テストコードの更新
3. ドキュメントの更新
4. サンプルコードの更新

**Phase 3: 非推奨化（将来）**

1. RecordMetaDataの直接使用を非推奨化
2. Schemaの使用を推奨
3. 1〜2バージョン後にRecordMetaDataをinternalに

### RecordStoreの変更不要

RecordStoreは以下の理由で変更不要：

```swift
// RecordStore内部
public final class RecordStore<Record: Recordable> {
    private let metaData: RecordMetaData  // ← 既存のまま

    // Schemaから取得したRecordMetaDataを使用
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,  // ← Schema.recordMetaDataを渡す
        statisticsManager: any StatisticsManagerProtocol
    ) { ... }
}
```

**利点**:
- ✅ RecordStoreの内部実装を変更不要
- ✅ 既存のCRUD操作がそのまま動作
- ✅ テストコードの大幅な書き換え不要

---

## 📋 実装計画

### Phase 1: 基本構造（優先度: 高）

**目標**: SwiftData風APIの基本骨格を実装

**タスク**:

1. **Schema.Version** (1時間)
   - セマンティックバージョニング構造体
   - Hashable, Codable準拠
   - テスト作成

2. **Schema.Attribute, Schema.Relationship, SchemaProperty** (1時間)
   - プロトコルと構造体定義
   - Hashable, Sendable準拠
   - テスト作成

3. **Schema.Entity** (2時間)
   - RecordTypeラッパー実装
   - Indexから`indices`と`uniquenessConstraints`を抽出
   - テスト作成

4. **Schema** (3時間)
   - RecordMetaDataラッパー実装
   - イニシャライザ実装（型配列版）
   - Entity構築ロジック
   - テスト作成

5. **DatabaseConfiguration** (1時間)
   - 構造体実装
   - デフォルト値設定
   - テスト作成

6. **RecordContainer** (3時間)
   - 初期化ロジック実装
   - `store(for:path:)`実装
   - StatisticsManager統合
   - テスト作成

7. **Subspace.fromPath()** (1時間)
   - パス解析実装
   - テスト作成

**成果物**:
- Schema, RecordContainer, DatabaseConfigurationの基本実装
- 単体テスト
- 統合テスト（基本的な使用例）

**期間**: 2〜3日

---

### Phase 2: バージョン管理（優先度: 中）

**目標**: マイグレーション関連のプロトコルと構造を実装

**タスク**:

1. **VersionedSchema** (1時間)
   - プロトコル定義
   - テスト用スキーマ作成

2. **SchemaMigrationPlan** (1時間)
   - プロトコル定義
   - テスト用プラン作成

3. **MigrationStage** (1時間)
   - 列挙型定義
   - テスト作成

4. **Schema(versionedSchema:)** (1時間)
   - VersionedSchemaからSchemaを作成
   - テスト作成

5. **RecordContainer マイグレーション統合** (将来)
   - マイグレーション実行ロジック
   - ⚠️ Phase 2では定義のみ、実行は将来

**成果物**:
- VersionedSchema, SchemaMigrationPlanの定義
- マイグレーション設計ドキュメント

**期間**: 1〜2日

---

### Phase 3: ドキュメントと移行（優先度: 中）

**目標**: ドキュメント整備と既存コードの移行支援

**タスク**:

1. **使用例の作成** (2時間)
   - 基本的な使用例
   - マイグレーション例
   - Multi-type index例

2. **マイグレーションガイド** (2時間)
   - 既存コードからの移行手順
   - APIの対応表
   - FAQ

3. **サンプルコードの更新** (2時間)
   - SimpleExample.swift
   - PartitionExample.swift
   - 新しいSwiftDataStyleExample.swift作成

4. **STATUS.md更新** (1時間)
   - Phase 2b完了として記録
   - 新API追加の記載

**成果物**:
- SWIFTDATA_USAGE_GUIDE.md
- MIGRATION_TO_SWIFTDATA_API.md
- 更新されたサンプルコード

**期間**: 1〜2日

---

### Phase 4: 既存機能の統合（優先度: 低）

**目標**: 既存の高度な機能をSwiftData風APIに統合

**タスク**:

1. **PartitionManagerの統合** (将来)
   - RecordContainerとの統合
   - 透明化

2. **Multi-type indexのサポート** (将来)
   - Schemaでのmulti-type index定義
   - RecordMetaDataへの反映

3. **Relationshipの実装** (将来)
   - Schema.Relationshipの完全実装
   - 外部キーのサポート

**期間**: 未定（将来の拡張）

---

## ⚠️ 制約と注意事項

### 実装上の制約

1. **RecordMetaDataへの依存**
   - Schemaは内部でRecordMetaDataを使用
   - RecordMetaData廃止は将来の大規模リファクタリング

2. **マイグレーション実行**
   - Phase 1では定義のみ
   - 実行ロジックは将来の実装

3. **Relationship**
   - Phase 1では定義のみ
   - 外部キー、カスケード削除は未実装

4. **Multi-type index**
   - 現在のRecordMetaDataでは未サポート
   - 将来の拡張として設計

### パフォーマンス考慮事項

1. **Entity構築**
   - Schema初期化時に全Entityを構築
   - 大量の型がある場合、初期化コストが高い
   - 対策: 遅延評価の検討（将来）

2. **Subspace.fromPath()**
   - 毎回パース処理が発生
   - 対策: Containerでキャッシュ（将来）

3. **RecordStore作成**
   - `container.store(for:path:)`は毎回新しいRecordStoreを作成
   - 対策: Containerでキャッシュ検討（将来）

### 互換性リスク

1. **既存コードへの影響**
   - RecordMetaDataの直接使用コードは動作継続
   - 段階的移行が可能

2. **API変更リスク**
   - SwiftDataのAPI変更に追従する必要
   - バージョン管理で対応

---

## 📊 比較: 旧API vs 新API

### コード量

```swift
// 旧API (7行)
let metaData = RecordMetaData()
try metaData.registerRecordType(User.self)
try metaData.registerRecordType(Order.self)
try metaData.registerRecordType(Message.self)
let store = RecordStore<User>(
    database: database, subspace: subspace,
    metaData: metaData, statisticsManager: statsManager
)

// 新API (5行 + グローバル設定)
// グローバル設定（1回だけ）
let container = try RecordContainer(
    for: User.self, Order.self, Message.self,
    configurations: DatabaseConfiguration(apiVersion: 630)
)

// 使用時（1行）
let store = container.store(for: User.self, path: "users")
```

### 学習コスト

| 項目 | 旧API | 新API |
|------|-------|-------|
| 学習曲線 | FDB Record Layer固有 | SwiftData知識を活用 |
| ドキュメント | FDB独自ドキュメント | Appleドキュメント参照可能 |
| サンプルコード | 独自に用意 | SwiftDataのサンプル参考 |

### メンテナンス性

| 項目 | 旧API | 新API |
|------|-------|-------|
| グローバル状態管理 | 手動管理 | Container自動管理 |
| マイグレーション | 手動実装 | プロトコルベース |
| パス管理 | Subspace直接操作 | Firestore風パス |

---

## 🎯 成功基準

### Phase 1 完了基準

- [ ] Schema, RecordContainer, DatabaseConfiguration実装完了
- [ ] 全単体テストが通過
- [ ] 基本的な使用例が動作
- [ ] ドキュメント（このファイル）完成
- [ ] 既存RecordStoreとの互換性確認

### Phase 2 完了基準

- [ ] VersionedSchema, SchemaMigrationPlan定義完了
- [ ] マイグレーション設計ドキュメント完成
- [ ] マイグレーションテスト作成

### Phase 3 完了基準

- [ ] 使用ガイド完成
- [ ] サンプルコード更新完了
- [ ] STATUS.md更新完了

---

## 📚 参考資料

### SwiftData公式ドキュメント

- [Schema](https://developer.apple.com/documentation/swiftdata/schema)
- [Schema.Entity](https://developer.apple.com/documentation/swiftdata/schema/entity)
- [ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer)
- [ModelConfiguration](https://developer.apple.com/documentation/swiftdata/modelconfiguration)
- [VersionedSchema](https://developer.apple.com/documentation/swiftdata/versionedschema)
- [SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)

### 関連ドキュメント

- [STATUS.md](STATUS.md) - プロジェクト状況
- [PARTITION_DESIGN.md](PARTITION_DESIGN.md) - パーティション設計
- [ARCHITECTURE_REFERENCE.md](architecture/ARCHITECTURE_REFERENCE.md) - アーキテクチャ

---

**最終更新**: 2025-01-06
**次のレビュー**: Phase 1実装完了後
