# RecordContainer/RecordContext Design

**Date**: 2025-01-18
**Status**: Design Proposal
**Target**: FDBRecordLayer v3.0 (Breaking Change)

---

## 概要

SwiftDataのアーキテクチャを参考に、FDBRecordLayerにContainer/Contextパターンを導入します。これにより、Schema/Database/Subspaceを引き回す必要がなくなり、より簡潔で型安全なAPIを提供します。

### 設計原則

1. **Single Source of Truth**: Containerが全ての設定を管理
2. **SwiftData互換**: 可能な限りSwiftDataのAPIパターンに従う
3. **型安全**: KeyPathベースのAPI、コンパイル時型チェック
4. **変更追跡**: Context内でinsert/update/deleteを追跡、明示的なsave()
5. **並行性**: MainActor boundなmainContextと、バックグラウンド用のmakeContext()

---

## アーキテクチャ概要

```
┌──────────────────────────────────────────────────────────┐
│                    RecordContainer                        │
│  - Schema (model definitions)                            │
│  - Database (FoundationDB connection)                    │
│  - Configuration (subspace, vector strategies)           │
│  - MigrationPlan (schema evolution)                      │
│  - StatisticsManager (query optimization)                │
│                                                           │
│  + mainContext: RecordContext (@MainActor)               │
│  + makeContext() -> RecordContext (background)           │
└────────────┬─────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────┐
│                     RecordContext                         │
│  - Container reference                                   │
│  - Change tracking (inserted, changed, deleted)          │
│  - Auto-save support                                     │
│                                                           │
│  + fetch<T>(T.Type) -> QueryBuilder<T>                  │
│  + insert<T>(_ record: T)                               │
│  + delete<T>(_ record: T)                               │
│  + save() async throws                                   │
│  + rollback()                                            │
└──────────────────────────────────────────────────────────┘
```

---

## SwiftDataとの比較

### SwiftData

```swift
// Container作成
let container = try ModelContainer(for: [User.self, Product.self])

// Context取得
let context = ModelContext(container)

// CRUD
context.insert(user)
let users = try context.fetch(FetchDescriptor<User>(
    predicate: #Predicate { $0.email == "alice@example.com" }
))
try context.save()
```

### FDBRecordLayer（現在: ❌ 冗長）

```swift
// Schema, Database, Subspaceを毎回渡す
let schema = Schema([User.self])
let database = FDB.Database(...)
let store = try await RecordStore(
    database: database,
    schema: schema,
    subspace: subspace,
    statisticsManager: manager
)

let users = try await store.query()
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

### FDBRecordLayer（新設計: ✅ 簡潔）

```swift
// Container作成（アプリ起動時に一度だけ）
let container = try await RecordContainer(
    for: [User.self, Product.self],
    database: database,
    configuration: RecordConfiguration(
        vectorStrategies: [
            \Product.embedding: .hnswBatch
        ]
    )
)

// Context経由でCRUD（Schema/Database不要）
let context = container.mainContext
context.insert(user)

let users = try await context.fetch(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()

try await context.save()
```

---

## 主要コンポーネント

### 1. RecordContainer

**役割**: Schema、Database、設定を保持し、Contextを生成

#### API

```swift
public final class RecordContainer: Sendable {
    // MARK: - Properties

    /// Schema mapping model classes to persistent storage
    public let schema: Schema

    /// Migration plan for schema evolution
    public let migrationPlan: (any SchemaMigrationPlan.Type)?

    /// Storage configuration
    public let configuration: RecordConfiguration

    /// Main context (MainActor-bound)
    @MainActor
    public private(set) lazy var mainContext: RecordContext

    // MARK: - Initialization

    /// Create container with model types
    public init(
        for recordTypes: [any Recordable.Type],
        database: any DatabaseProtocol,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configuration: RecordConfiguration = RecordConfiguration()
    ) async throws

    /// Create container with explicit schema
    public init(
        for schema: Schema,
        database: any DatabaseProtocol,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil,
        configuration: RecordConfiguration = RecordConfiguration()
    ) async throws

    // MARK: - Context Management

    /// Create background context
    public func makeContext() -> RecordContext

    // MARK: - Container Management

    /// Delete all persisted data
    public func deleteAllData() async throws
}
```

#### 使用例

```swift
// アプリ起動時に一度だけ作成
let container = try await RecordContainer(
    for: [User.self, Product.self, Order.self],
    database: database,
    migrationPlan: AppMigrationPlan.self,
    configuration: RecordConfiguration(
        subspace: Subspace(prefix: [0x01, 0x02]),
        vectorStrategies: [
            \Product.embedding: .hnswBatch,
            \Product.imageEmbedding: .flatScan
        ],
        allowAutomaticMigration: true
    )
)

// メインスレッドでの使用（SwiftUI）
@MainActor
func updateUI() {
    let context = container.mainContext
    // ...
}

// バックグラウンドでの使用（大量データ処理）
func processBatch() async {
    let context = container.makeContext()
    // ...
}
```

---

### 2. RecordConfiguration

**役割**: Subspace、VectorStrategy、マイグレーション設定を提供

#### API

```swift
public struct RecordConfiguration: Sendable {
    /// Subspace for data isolation
    public let subspace: Subspace

    /// Schema version
    public let version: Schema.Version

    /// Vector index strategies (KeyPath-based)
    public let vectorStrategies: [PartialKeyPath<Any>: VectorIndexStrategy]

    /// Allow automatic migration
    public let allowAutomaticMigration: Bool

    /// Batch size for index building
    public let indexBuildBatchSize: Int

    public init(
        subspace: Subspace = Subspace(prefix: []),
        version: Schema.Version = Schema.Version(1, 0, 0),
        vectorStrategies: [PartialKeyPath<Any>: VectorIndexStrategy] = [:],
        allowAutomaticMigration: Bool = true,
        indexBuildBatchSize: Int = 1000
    )
}
```

#### 使用例

```swift
// デフォルト設定
let config = RecordConfiguration()

// カスタム設定
let config = RecordConfiguration(
    subspace: Subspace(prefix: "myapp".data(using: .utf8)!),
    version: Schema.Version(2, 1, 0),
    vectorStrategies: [
        \Product.embedding: .hnswBatch,
        \User.profileVector: .flatScan
    ],
    allowAutomaticMigration: false,  // 手動マイグレーション
    indexBuildBatchSize: 500         // 小さいバッチサイズ
)
```

---

### 3. RecordContext

**役割**: CRUD操作の実行、変更追跡、保存管理

#### API

```swift
public final class RecordContext: Sendable {
    // MARK: - Properties

    /// Container that owns this context
    public let container: RecordContainer

    /// Whether context has unsaved changes
    public var hasChanges: Bool { get }

    /// Auto-save enabled
    public var autosaveEnabled: Bool { get set }

    /// Inserted models pending save
    public var insertedModelsArray: [any Recordable] { get }

    /// Changed models pending save
    public var changedModelsArray: [any Recordable] { get }

    /// Deleted models pending save
    public var deletedModelsArray: [any Recordable] { get }

    // MARK: - Fetching

    /// Fetch records with QueryBuilder
    public func fetch<T: Recordable>(_ recordType: T.Type) -> QueryBuilder<T>

    /// Fetch count
    public func fetchCount<T: Recordable>(_ recordType: T.Type) async throws -> Int

    // MARK: - Inserting

    /// Insert a new record
    public func insert<T: Recordable>(_ record: T)

    // MARK: - Deleting

    /// Delete a record
    public func delete<T: Recordable>(_ record: T)

    /// Delete records matching predicate
    public func delete<T: Recordable>(
        _ recordType: T.Type,
        where predicate: ((T) -> Bool)?
    ) async throws

    // MARK: - Saving

    /// Save all pending changes
    public func save() async throws

    /// Rollback all pending changes
    public func rollback()

    /// Execute block in transaction and save
    public func transaction(block: () async throws -> Void) async throws
}
```

#### 使用例

```swift
let context = container.mainContext

// Insert
let user = User(userID: 1, email: "alice@example.com", name: "Alice")
context.insert(user)

// Fetch
let users = try await context.fetch(User.self)
    .where(\.email, .equals, "alice@example.com")
    .orderBy(\.name, .ascending)
    .execute()

// Delete
context.delete(users.first!)

// Check changes
if context.hasChanges {
    print("Pending changes: \(context.insertedModelsArray.count) inserts, \(context.deletedModelsArray.count) deletes")
}

// Save
try await context.save()

// Or rollback
context.rollback()
```

---

### 4. Recordable拡張（PersistentModel互換）

SwiftDataの`PersistentModel`プロトコルに近づけるため、`Recordable`に以下を追加：

```swift
public extension Recordable {
    /// Model context (set when inserted)
    var modelContext: RecordContext? { get set }

    /// Whether model has unsaved changes
    var hasChanges: Bool { get }

    /// Whether model is deleted
    var isDeleted: Bool { get }

    /// Persistent identifier (based on primary key)
    var persistentModelID: RecordIdentifier {
        RecordIdentifier(
            recordType: Self.recordName,
            primaryKey: extractPrimaryKey()
        )
    }
}

/// Record identifier (like PersistentIdentifier)
public struct RecordIdentifier: Hashable, Sendable {
    public let recordType: String
    public let primaryKey: Tuple
}
```

---

## SwiftUI統合

### Environment経由でのアクセス

```swift
// App level
@main
struct MyApp: App {
    let container: RecordContainer

    init() {
        let database = try! FDB.Database(clusterFile: "/usr/local/etc/foundationdb/fdb.cluster")
        container = try! await RecordContainer(
            for: [User.self, Product.self],
            database: database
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.recordContainer, container)
                .environment(\.recordContext, container.mainContext)
        }
    }
}

// Environment keys
extension EnvironmentValues {
    @Entry var recordContainer: RecordContainer?
    @Entry var recordContext: RecordContext?
}

// View usage
struct UserListView: View {
    @Environment(\.recordContext) private var context
    @State private var users: [User] = []

    var body: some View {
        List(users, id: \.userID) { user in
            UserRow(user: user)
        }
        .task {
            await loadUsers()
        }
    }

    private func loadUsers() async {
        users = try! await context?.fetch(User.self)
            .orderBy(\.name, .ascending)
            .execute() ?? []
    }
}
```

---

## Query APIリファクタリング（統合）

RecordContextと統合した新しいQuery API：

### KeyPath-First Pattern

```swift
// ✅ Vector Search
let products = try await context.fetch(Product.self)
    .nearestNeighbors(\.embedding, k: 10, to: queryEmbedding)
    .execute()

// ✅ Ranking
let topUsers = try await context.fetch(User.self)
    .topN(\.score, count: 10)
    .execute()

// ✅ Spatial
let nearby = try await context.fetch(Restaurant.self)
    .withinRadius(
        \.location,
        centerLatitude: 35.6812,
        centerLongitude: 139.7671,
        radiusMeters: 1000
    )
    .execute()

// ✅ Range
let events = try await context.fetch(Event.self)
    .overlaps(\.period, with: queryRange)
    .execute()

// ✅ Filter
let users = try await context.fetch(User.self)
    .where(\.email, .equals, "alice@example.com")
    .where(\.age, .greaterThan, 18)
    .orderBy(\.name, .ascending)
    .limit(10)
    .execute()
```

---

## 変更追跡とNotifications

### 変更追跡

```swift
let context = container.mainContext

// Insert
context.insert(user1)
context.insert(user2)

// Track changes
print("Inserted: \(context.insertedModelsArray.count)")  // 2
print("Has changes: \(context.hasChanges)")              // true

// Save
try await context.save()

print("Has changes: \(context.hasChanges)")              // false
```

### Notifications（将来実装）

SwiftDataの`willSave`/`didSave`通知に相当：

```swift
// Subscribe to notifications
NotificationCenter.default.addObserver(
    forName: RecordContext.willSave,
    object: context,
    queue: nil
) { notification in
    print("Context will save")
}

NotificationCenter.default.addObserver(
    forName: RecordContext.didSave,
    object: context,
    queue: nil
) { notification in
    if let userInfo = notification.userInfo {
        let inserted = userInfo[RecordContext.NotificationKey.inserted] as? [any Recordable]
        let updated = userInfo[RecordContext.NotificationKey.updated] as? [any Recordable]
        let deleted = userInfo[RecordContext.NotificationKey.deleted] as? [any Recordable]

        print("Saved: \(inserted?.count ?? 0) inserts, \(updated?.count ?? 0) updates, \(deleted?.count ?? 0) deletes")
    }
}
```

---

## マイグレーションパス

### 既存コードからの移行

#### Before（現在）

```swift
// Schema作成
let schema = Schema([User.self])

// Database作成
let database = try FDB.Database(clusterFile: "...")

// RecordStore作成（型ごとに必要）
let userStore = try await RecordStore<User>(
    database: database,
    schema: schema,
    subspace: Subspace(prefix: []),
    statisticsManager: StatisticsManager(database: database)
)

// Query
let users = try await userStore.query()
    .where(\.email, .equals, "alice@example.com")
    .execute()

// Insert
try await userStore.save(user)

// Delete
try await userStore.delete(primaryKey: Tuple(user.userID))
```

#### After（新設計）

```swift
// Container作成（アプリ起動時に一度だけ）
let container = try await RecordContainer(
    for: [User.self],
    database: database
)

// Context取得
let context = container.mainContext

// Query（型ごとのStore不要）
let users = try await context.fetch(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()

// Insert
context.insert(user)

// Delete
context.delete(user)

// Save（明示的）
try await context.save()
```

### 段階的移行

**Phase 1**: RecordContainer/RecordContext追加（既存APIは維持）

```swift
// 新API
let container = try await RecordContainer(for: [User.self], database: database)
let users = try await container.mainContext.fetch(User.self).execute()

// 旧API（deprecated）
let store = try await RecordStore<User>(...)
let users = try await store.query().execute()
```

**Phase 2**: 既存APIをdeprecated化

```swift
@available(*, deprecated, message: "Use RecordContainer and RecordContext instead")
public struct RecordStore<Record: Recordable> {
    // ...
}
```

**Phase 3**: 既存API削除（v3.0）

---

## 実装計画

### Phase 1: Core Infrastructure（Week 1-2）

**ファイル**:
- `Sources/FDBRecordLayer/Container/RecordContainer.swift`
- `Sources/FDBRecordLayer/Container/RecordConfiguration.swift`
- `Sources/FDBRecordLayer/Container/RecordContext.swift`
- `Sources/FDBRecordLayer/Container/RecordIdentifier.swift`

**実装内容**:
- [x] RecordContainer基本構造
- [x] RecordConfiguration定義
- [x] RecordContext基本構造
- [x] 変更追跡（insertedModels, changedModels, deletedModels）
- [x] save(), rollback(), transaction()

### Phase 2: QueryBuilder統合（Week 3）

**ファイル**:
- `Sources/FDBRecordLayer/Query/QueryBuilder.swift`（リファクタリング）
- `Sources/FDBRecordLayer/Query/TypedRecordQuery.swift`（更新）

**実装内容**:
- [x] QueryBuilderをRecordContextから生成
- [x] KeyPath-first APIリファクタリング
  - nearestNeighbors(\.field, k:, to:)
  - topN(\.field, count:)
  - bottomN(\.field, count:)
  - withinRadius(\.field, centerLatitude:, centerLongitude:, radiusMeters:)
- [x] 既存RecordStore.query()との互換性維持

### Phase 3: SwiftUI統合（Week 4）

**ファイル**:
- `Sources/FDBRecordLayer/SwiftUI/EnvironmentValues+RecordLayer.swift`
- `Sources/FDBRecordLayer/SwiftUI/RecordQuery.swift`（SwiftDataの@Query相当）

**実装内容**:
- [x] Environment keys定義
- [x] @RecordQuery property wrapper（将来）
- [x] View modifiers

### Phase 4: ドキュメント・テスト（Week 5-6）

**ファイル**:
- `README.md`（更新）
- `CLAUDE.md`（更新）
- `docs/migration-guide-v3.md`（新規）
- `Tests/FDBRecordLayerTests/Container/RecordContainerTests.swift`
- `Tests/FDBRecordLayerTests/Container/RecordContextTests.swift`

**実装内容**:
- [x] 包括的なドキュメント
- [x] マイグレーションガイド
- [x] 50+ テスト
- [x] サンプルコード（Examples/）

---

## ベストプラクティス

### 1. Container作成はアプリ起動時に一度だけ

```swift
@main
struct MyApp: App {
    let container: RecordContainer

    init() {
        container = try! await RecordContainer(
            for: [User.self, Product.self],
            database: database
        )
    }
}
```

### 2. MainActor-boundなmainContextをUIで使用

```swift
@MainActor
struct UserListView: View {
    @Environment(\.recordContext) private var context

    func addUser() {
        // MainActor上で実行されるため安全
        context?.insert(user)
        try? await context?.save()
    }
}
```

### 3. バックグラウンド処理は専用Contextを使用

```swift
func importLargeDataset(container: RecordContainer) async throws {
    // バックグラウンドContext作成
    let context = container.makeContext()

    for batch in batches {
        for record in batch {
            context.insert(record)
        }

        try await context.save()
        print("Batch saved")
    }
}
```

### 4. 明示的なsave()を推奨

```swift
// ❌ autosaveEnabled = true（暗黙的保存）
context.autosaveEnabled = true
context.insert(user)  // 自動的に保存される

// ✅ 明示的なsave()（推奨）
context.autosaveEnabled = false
context.insert(user1)
context.insert(user2)
try await context.save()  // まとめて保存
```

---

## 利点のまとめ

| 項目 | Before（現在） | After（新設計） |
|------|--------------|---------------|
| **Schema引き回し** | 毎回必要 | 不要（Containerに内包） |
| **Database引き回し** | 毎回必要 | 不要（Containerに内包） |
| **RecordStore作成** | 型ごとに作成 | Context経由で自動生成 |
| **変更追跡** | なし | あり（hasChanges） |
| **トランザクション** | 手動管理 | save()/rollback() |
| **SwiftUI統合** | 煩雑 | Environment経由で簡潔 |
| **並行処理** | 手動管理 | mainContext + makeContext() |
| **API一貫性** | まちまち | KeyPath-first統一 |

---

## 参考資料

- [SwiftData - ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer)
- [SwiftData - ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)
- [SwiftData - PersistentModel](https://developer.apple.com/documentation/swiftdata/persistentmodel)
- [Java Record Layer](https://foundationdb.github.io/fdb-record-layer/)

---

**Status**: ✅ Design Complete - Ready for Implementation
**Next Steps**: Phase 1実装開始（RecordContainer/RecordContext core infrastructure）
