# Migration Manager 設計書

**バージョン**: 1.0
**日付**: 2025-01-13
**ステータス**: 設計完了 / 実装待ち

---

## 目次

1. [概要](#1-概要)
2. [既存実装の分析](#2-既存実装の分析)
3. [設計方針](#3-設計方針)
4. [詳細設計](#4-詳細設計)
5. [実装計画](#5-実装計画)
6. [使用例](#6-使用例)
7. [参考資料](#7-参考資料)

---

## 1. 概要

### 1.1 目的

Migration Managerは、FoundationDB Record Layerのスキーマ進化を管理するコンポーネントです。SwiftDataの`SchemaMigrationPlan`アプローチを採用しつつ、FoundationDBの特性（分散トランザクション、大規模データ、オンライン操作）に最適化されています。

### 1.2 主要機能

- **スキーマバージョン管理**: セマンティックバージョニングによるスキーマ追跡
- **マイグレーション実行**: 自動的な依存関係解決とチェーン実行
- **Lightweight Migration**: 単純なスキーマ変更の自動処理
- **Custom Migration**: 複雑なデータ変換とカスタムロジック
- **インデックス管理**: オンラインでのインデックス追加/削除/再構築
- **データ変換**: RangeSet-basedバッチ処理による大規模データ変換
- **進行状況追跡**: 中断可能で再開可能なマイグレーション

### 1.3 設計原則

1. **型安全性**: コンパイル時の型チェックによるバグ防止
2. **SwiftData互換**: 既存のSwiftData APIとの一貫性
3. **FoundationDB最適化**: トランザクション制限（5秒/10MB）の遵守
4. **再開可能性**: RangeSetによる進行状況追跡
5. **並行安全性**: `final class: Sendable + Mutex<State>`パターン

---

## 2. 既存実装の分析

### 2.1 実装済みコンポーネント

#### ファイル構成

```
Sources/FDBRecordLayer/Schema/
├── MigrationManager.swift      # マイグレーション管理（基本実装済み）
├── Migration.swift             # マイグレーション定義（部分実装）
├── VersionedSchema.swift       # SwiftData互換プロトコル（完全実装）
├── SchemaVersion.swift         # バージョン定義（完全実装）
└── Schema.swift                # スキーマ管理（完全実装）
```

#### 実装済み機能

| 機能 | ステータス | ファイル | 行番号 |
|------|----------|---------|--------|
| バージョン管理 | ✅ 完全実装 | `MigrationManager.swift` | 73-91, 225-235 |
| マイグレーション実行 | ✅ 完全実装 | `MigrationManager.swift` | 99-152 |
| マイグレーション追跡 | ✅ 完全実装 | `MigrationManager.swift` | 166-219 |
| データ変換 | ✅ 完全実装 | `Migration.swift` | 248-429 |
| レコード削除 | ✅ 完全実装 | `Migration.swift` | 458-612 |
| SwiftData互換API | ✅ 完全実装 | `VersionedSchema.swift` | 21-76 |

**実装品質**:
- データ変換は`RangeSet`による進行状況追跡を実装
- バッチ処理でFDBトランザクション制限を遵守
- アトミックな進行状況更新（データ+進捗を同一トランザクション）

### 2.2 未実装機能と課題

#### 課題1: インデックス操作が未実装

**場所**: `Migration.swift:126-204`

```swift
public func addIndex(_ index: Index) async throws {
    throw RecordLayerError.internalError(
        """
        Migration index operations not yet implemented.

        Missing requirements:
        1. Type-safe RecordStore factory (to obtain Record type)
        2. RecordStore subspace in MigrationContext
        """
    )
}
```

**影響**:
- インデックス追加/削除/再構築のマイグレーションが実行不可
- Lightweight migrationが不完全

#### 課題2: storeFactoryの型安全性問題

**場所**: `Migration.swift:103`

```swift
private let storeFactory: @Sendable (String) throws -> Any
```

**問題点**:
- `Any`を返すため型安全性がない
- `RecordStore<Record>`へのキャストが必要
- ジェネリック型情報が失われ、`OnlineIndexer<Record>`の生成が困難

**原因**:
- Swiftのジェネリクスの制約（存在型の制限）
- `RecordStore<Record>`の`Record`型がコンパイル時に不明

#### 課題3: RecordStore subspaceの欠如

**問題**:
- `MigrationContext`に`RecordStore`のsubspace情報がない
- `IndexStateManager`と`OnlineIndexer`にはsubspaceが必須

### 2.3 既存パターンの評価

#### 成功しているパターン

1. **`final class: Sendable + Mutex<State>`**:
   ```swift
   public final class MigrationManager: Sendable {
       nonisolated(unsafe) private let database: any DatabaseProtocol
       private let lock: Mutex<MigrationState>

       private struct MigrationState {
           var isRunning: Bool = false
           var currentVersion: SchemaVersion?
       }
   }
   ```
   - `RecordStore`, `IndexManager`, `OnlineIndexer`で統一
   - 高い並行性とスループット

2. **RangeSet-based Progress Tracking**:
   ```swift
   // Migration.swift:308-362
   private func processTransformRange<Record: Recordable>(...) async throws {
       var currentBegin = rangeBegin

       while currentBegin.lexicographicallyPrecedes(rangeEnd) {
           // 1. Process batch
           let batchResult = try await processSingleBatch(...)

           // 2. ATOMIC: Commit data + progress in SAME transaction
           try await database.withTransaction { transaction in
               for record in batchResult.transformedRecords {
                   try await store.saveInternal(record, context: context)
               }
               try await rangeSet.insertRange(
                   begin: currentBegin,
                   end: successor(of: batchResult.lastKey),
                   context: context
               )
               try await context.commit()
           }

           currentBegin = successor(of: batchResult.lastKey)
       }
   }
   ```
   - 再開可能性とアトミック性を両立
   - `OnlineIndexer`と同じパターン

---

## 3. 設計方針

### 3.1 SwiftDataとの互換性維持

SwiftDataの`SchemaMigrationPlan`アプローチを採用しつつ、FoundationDBの特性に最適化:

```swift
// SwiftData style (参考)
enum MyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        SchemaV1.self,
        SchemaV2.self
    ]

    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
    ]
}

// FDB Record Layer (拡張)
enum MyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        SchemaV1.self,
        SchemaV2.self,
        SchemaV3.self
    ]

    static var stages: [MigrationStage] = [
        // Lightweight: automatic schema evolution
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),

        // Custom: manual migration with data transformation
        .custom(
            fromVersion: SchemaV2.self,
            toVersion: SchemaV3.self,
            willMigrate: { schema in
                // Pre-migration logic (e.g., backup, validation)
            },
            didMigrate: { schema in
                // Post-migration logic (e.g., statistics rebuild)
            }
        )
    ]
}
```

### 3.2 既存パターンの活用

| パターン | 採用理由 | 適用箇所 |
|---------|---------|---------|
| `final class: Sendable + Mutex<State>` | 高並行性、スレッドセーフ | `MigrationManager`, `MigrationContext` |
| `nonisolated(unsafe) let database` | DatabaseProtocolは内部的にスレッドセーフ | 全クラス |
| RangeSet-based progress tracking | 再開可能性、アトミック性 | データ変換、インデックス構築 |
| Batch processing | FDB制限遵守（5秒/10MB） | 全マイグレーション操作 |

### 3.3 Java版Record Layerの参考設計

| 概念 | Java版 | Swift版 | 実装ステータス |
|------|--------|---------|--------------|
| FormerIndex | ✅ `FormerIndex` | `Schema.formerIndexes` | ✅ 定義済み（未使用） |
| IndexBuildState | ✅ `IndexState` enum | `IndexState` enum | ✅ 実装済み |
| OnlineIndexer | ✅ `OnlineIndexer` | `OnlineIndexer<Record>` | ✅ 実装済み |
| RecordStoreState | ✅ `RecordStoreState` | `IndexStateManager` | ✅ 実装済み |

---

## 4. 詳細設計

### 4.1 型安全なstoreFactoryの実装

#### 4.1.1 問題の整理

**現状**:
```swift
// Migration.swift:103
private let storeFactory: @Sendable (String) throws -> Any
```

**問題**:
- `Any`を返すため型情報が失われる
- `as? RecordStore<Record>`のキャストが必要だが、`Record`型が不明
- `OnlineIndexer<Record>`の生成に必要な型情報がない

**失敗した試み**:
```swift
// ❌ Generic factory - 存在型の制限で不可能
private let storeFactory: @Sendable <Record: Recordable>(String) throws -> RecordStore<Record>

// ❌ Associated type - Protocol with associated type cannot be used as type
protocol StoreFactory {
    associatedtype Record: Recordable
    func create(for recordName: String) throws -> RecordStore<Record>
}
```

#### 4.1.2 解決策: Type-erased Protocol Approach

**設計**:

```swift
/// Type-erased RecordStore wrapper for migration operations
///
/// Provides type-safe access to RecordStore operations without exposing
/// the generic Record type.
///
/// **Design Rationale**:
/// - Avoids `Any` casting by using protocol methods
/// - Enables type-safe operations without knowing concrete Record type
/// - Compatible with existing RecordStore implementations
public protocol AnyRecordStore: Sendable {
    /// The record type name
    var recordName: String { get }

    /// Get the record subspace
    var recordSubspace: Subspace { get }

    /// Get the index subspace
    var indexSubspace: Subspace { get }

    /// Get the root subspace
    var subspace: Subspace { get }

    /// Get the schema
    var schema: Schema { get }

    /// Build a specific index
    ///
    /// Creates an OnlineIndexer internally with the correct Record type.
    ///
    /// - Parameters:
    ///   - indexName: Name of the index to build
    ///   - batchSize: Number of records per batch (default: 1000)
    ///   - throttleDelayMs: Delay between batches in milliseconds (default: 10)
    /// - Throws: RecordLayerError if index not found or build fails
    func buildIndex(
        indexName: String,
        batchSize: Int,
        throttleDelayMs: UInt64
    ) async throws

    /// Scan all records with a predicate
    ///
    /// - Parameter predicate: Predicate function
    /// - Returns: Async sequence of matching records (as Data)
    /// - Throws: RecordLayerError if scan fails
    func scanRecords(
        where predicate: @Sendable @escaping (Data) -> Bool
    ) async throws -> AsyncStream<Data>
}
```

**RecordStoreへの適合**:

```swift
// RecordStore+Migration.swift
extension RecordStore: AnyRecordStore {
    public var recordName: String {
        Record.recordName
    }

    public func buildIndex(
        indexName: String,
        batchSize: Int = 1000,
        throttleDelayMs: UInt64 = 10
    ) async throws {
        // 1. Find index
        guard let index = schema.index(named: indexName) else {
            throw RecordLayerError.indexNotFound("Index '\(indexName)' not found")
        }

        // 2. Create RecordAccess with concrete Record type
        let recordAccess = GenericRecordAccess<Record>()

        // 3. Create IndexStateManager
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )

        // 4. Create OnlineIndexer with concrete Record type
        let indexer = OnlineIndexer(
            database: database,
            subspace: subspace,
            schema: schema,
            entityName: Record.recordName,
            index: index,
            recordAccess: recordAccess,
            indexStateManager: indexStateManager,
            batchSize: batchSize,
            throttleDelayMs: throttleDelayMs
        )

        // 5. Build index
        try await indexer.buildIndex(clearFirst: false)
    }

    public func scanRecords(
        where predicate: @Sendable @escaping (Data) -> Bool
    ) async throws -> AsyncStream<Data> {
        let recordAccess = GenericRecordAccess<Record>()

        return AsyncStream { continuation in
            Task {
                do {
                    for try await record in self.scan() {
                        let data = try recordAccess.serialize(record)
                        if predicate(Data(data)) {
                            continuation.yield(Data(data))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

#### 4.1.3 改善されたMigrationContext

```swift
/// Context provided to migrations during execution
///
/// **Redesigned with type-safe store registry**
public struct MigrationContext: Sendable {
    nonisolated(unsafe) public let database: any DatabaseProtocol
    public let schema: Schema
    public let metadataSubspace: Subspace

    /// Type-erased record store registry
    ///
    /// Maps record type names to their corresponding RecordStores.
    /// All stores conform to AnyRecordStore for type-safe operations.
    private let storeRegistry: [String: any AnyRecordStore]

    internal init(
        database: any DatabaseProtocol,
        schema: Schema,
        metadataSubspace: Subspace,
        storeRegistry: [String: any AnyRecordStore]
    ) {
        self.database = database
        self.schema = schema
        self.metadataSubspace = metadataSubspace
        self.storeRegistry = storeRegistry
    }

    // MARK: - Store Access

    /// Get RecordStore for a record type
    ///
    /// - Parameter recordName: Record type name
    /// - Returns: Type-erased RecordStore
    /// - Throws: RecordLayerError if store not found
    public func store(for recordName: String) throws -> any AnyRecordStore {
        guard let store = storeRegistry[recordName] else {
            throw RecordLayerError.invalidArgument(
                "RecordStore for '\(recordName)' not found in registry. " +
                "Available stores: \(storeRegistry.keys.sorted().joined(separator: ", "))"
            )
        }
        return store
    }

    // MARK: - Index Operations (NOW IMPLEMENTED)

    /// Add a new index and build it online
    ///
    /// **Implementation**:
    /// 1. Find applicable record types (from index.recordTypes or all stores)
    /// 2. For each record type:
    ///    a. Enable index (sets to writeOnly via IndexStateManager)
    ///    b. Build index (via OnlineIndexer through AnyRecordStore)
    ///    c. Mark as readable (via IndexStateManager)
    ///
    /// **Example**:
    /// ```swift
    /// let emailIndex = Index.value(
    ///     named: "user_by_email",
    ///     on: FieldKeyExpression(fieldName: "email")
    /// )
    /// try await context.addIndex(emailIndex)
    /// ```
    ///
    /// - Parameter index: The index to add
    /// - Throws: RecordLayerError if index addition fails
    public func addIndex(_ index: Index) async throws {
        // 1. Determine applicable record types
        let applicableTypes: Set<String>
        if let recordTypes = index.recordTypes {
            applicableTypes = recordTypes
        } else {
            // Universal index: applies to all record types
            applicableTypes = Set(storeRegistry.keys)
        }

        // 2. Build index for each applicable record type
        for recordName in applicableTypes {
            let store = try self.store(for: recordName)

            // 2a. Enable index (writeOnly state)
            let indexStateManager = IndexStateManager(
                database: database,
                subspace: store.subspace
            )
            try await indexStateManager.enable(index.name)

            // 2b. Build index using OnlineIndexer (via AnyRecordStore)
            try await store.buildIndex(
                indexName: index.name,
                batchSize: 1000,
                throttleDelayMs: 10
            )

            // 2c. Mark as readable
            try await indexStateManager.makeReadable(index.name)
        }
    }

    /// Remove an index and add FormerIndex entry
    ///
    /// **Implementation**:
    /// 1. Create FormerIndex metadata entry
    /// 2. Disable index (via IndexStateManager)
    /// 3. Clear all index data (range clear)
    /// 4. Update schema to remove from active indexes
    ///
    /// **FormerIndex Storage**:
    /// ```
    /// Key: [subspace][storeInfo][formerIndexes][indexName]
    /// Value: Tuple(addedVersion.major, minor, patch, removedTimestamp)
    /// ```
    ///
    /// **Example**:
    /// ```swift
    /// try await context.removeIndex(
    ///     indexName: "legacy_index",
    ///     addedVersion: SchemaVersion(major: 1, minor: 0, patch: 0)
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - indexName: Name of the index to remove
    ///   - addedVersion: Version when index was originally added
    /// - Throws: RecordLayerError if index removal fails
    public func removeIndex(
        indexName: String,
        addedVersion: SchemaVersion
    ) async throws {
        // Remove from all stores
        for (_, store) in storeRegistry {
            // 1. Create FormerIndex entry
            let formerIndexKey = store.subspace
                .subspace(RecordStoreKeyspace.storeInfo.rawValue)
                .subspace("formerIndexes")
                .pack(Tuple(indexName))

            try await database.withTransaction { transaction in
                let timestamp = Date().timeIntervalSince1970
                transaction.setValue(
                    Tuple(
                        Int64(addedVersion.major),
                        Int64(addedVersion.minor),
                        Int64(addedVersion.patch),
                        timestamp
                    ).pack(),
                    for: formerIndexKey
                )
            }

            // 2. Disable index
            let indexStateManager = IndexStateManager(
                database: database,
                subspace: store.subspace
            )
            try await indexStateManager.disable(indexName)

            // 3. Clear index data
            let indexRange = store.indexSubspace.subspace(indexName).range()
            try await database.withTransaction { transaction in
                transaction.clearRange(
                    beginKey: indexRange.begin,
                    endKey: indexRange.end
                )
            }
        }
    }

    /// Rebuild an existing index
    ///
    /// **Implementation**:
    /// 1. Disable index (via IndexStateManager)
    /// 2. Clear existing index data (range clear)
    /// 3. Enable index (writeOnly state)
    /// 4. Build index (via OnlineIndexer)
    /// 5. Mark as readable
    ///
    /// **Use Cases**:
    /// - Index corruption recovery
    /// - Index definition change (e.g., adding uniqueness constraint)
    /// - Performance optimization (rebuild with better distribution)
    ///
    /// **Example**:
    /// ```swift
    /// try await context.rebuildIndex(indexName: "user_by_email")
    /// ```
    ///
    /// - Parameter indexName: Name of the index to rebuild
    /// - Throws: RecordLayerError if rebuild fails
    public func rebuildIndex(indexName: String) async throws {
        guard let index = schema.index(named: indexName) else {
            throw RecordLayerError.indexNotFound(
                "Index '\(indexName)' not found in schema"
            )
        }

        let applicableTypes = index.recordTypes ?? Set(storeRegistry.keys)

        for recordName in applicableTypes {
            let store = try self.store(for: recordName)

            // 1. Disable index
            let indexStateManager = IndexStateManager(
                database: database,
                subspace: store.subspace
            )
            try await indexStateManager.disable(indexName)

            // 2. Clear existing data
            let indexRange = store.indexSubspace.subspace(indexName).range()
            try await database.withTransaction { transaction in
                transaction.clearRange(
                    beginKey: indexRange.begin,
                    endKey: indexRange.end
                )
            }

            // 3. Enable (writeOnly)
            try await indexStateManager.enable(indexName)

            // 4. Build index
            try await store.buildIndex(
                indexName: indexName,
                batchSize: 1000,
                throttleDelayMs: 10
            )

            // 5. Mark as readable
            try await indexStateManager.makeReadable(indexName)
        }
    }

    // MARK: - Data Transformation (ALREADY IMPLEMENTED)

    // transformRecords(), deleteRecords(), etc. remain unchanged
    // See Migration.swift:248-612 for full implementation
}
```

### 4.2 改善されたMigrationManager

```swift
/// Migration Manager
///
/// **Redesigned with type-safe store registry**
///
/// Manages schema migrations and ensures they are applied in the correct order.
/// Tracks which migrations have been executed and prevents duplicate execution.
///
/// **Features**:
/// - Automatic migration ordering based on versions
/// - Idempotent migration execution (safe to run multiple times)
/// - Progress tracking with RangeSet
/// - Type-safe store registry
///
/// **Usage**:
/// ```swift
/// // Create store registry
/// let userStore = RecordStore<User>(...)
/// let orderStore = RecordStore<Order>(...)
/// let registry: [String: any AnyRecordStore] = [
///     "User": userStore,
///     "Order": orderStore
/// ]
///
/// // Create migration manager
/// let manager = MigrationManager(
///     database: database,
///     schema: schema,
///     migrations: [migration1, migration2],
///     storeRegistry: registry
/// )
///
/// // Apply all pending migrations
/// try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))
/// ```
public final class MigrationManager: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let schema: Schema
    private let migrations: [Migration]
    private let migrationSubspace: Subspace
    private let lock: Mutex<MigrationState>

    /// Type-erased record store registry
    ///
    /// Maps record type names to their RecordStores for migration operations.
    private let storeRegistry: [String: any AnyRecordStore]

    private struct MigrationState {
        var isRunning: Bool = false
        var currentVersion: SchemaVersion?
    }

    // MARK: - Initialization

    /// Initialize migration manager with store registry
    ///
    /// - Parameters:
    ///   - database: Database instance
    ///   - schema: Target schema
    ///   - migrations: Array of migrations to manage
    ///   - storeRegistry: Registry of RecordStores for each record type
    ///   - migrationSubspace: Subspace for migration metadata (default: "migrations")
    public init(
        database: any DatabaseProtocol,
        schema: Schema,
        migrations: [Migration],
        storeRegistry: [String: any AnyRecordStore],
        migrationSubspace: Subspace? = nil
    ) {
        self.database = database
        self.schema = schema
        self.migrations = migrations.sorted { $0.toVersion < $1.toVersion }
        self.storeRegistry = storeRegistry
        self.migrationSubspace = migrationSubspace ?? Subspace(prefix: Tuple("migrations").pack())
        self.lock = Mutex(MigrationState())
    }

    /// Convenience initializer for single RecordStore
    ///
    /// Use this when migrating a single record type.
    ///
    /// - Parameters:
    ///   - database: Database instance
    ///   - schema: Target schema
    ///   - migrations: Array of migrations
    ///   - store: RecordStore to migrate
    ///   - migrationSubspace: Subspace for migration metadata
    public convenience init<Record: Recordable>(
        database: any DatabaseProtocol,
        schema: Schema,
        migrations: [Migration],
        store: RecordStore<Record>,
        migrationSubspace: Subspace? = nil
    ) {
        let registry: [String: any AnyRecordStore] = [Record.recordName: store]
        self.init(
            database: database,
            schema: schema,
            migrations: migrations,
            storeRegistry: registry,
            migrationSubspace: migrationSubspace
        )
    }

    // MARK: - Private Methods (UPDATED)

    /// Apply a single migration
    ///
    /// - Parameter migration: Migration to apply
    /// - Throws: RecordLayerError if migration fails
    private func applyMigration(_ migration: Migration) async throws {
        // Check if already applied
        if try await isMigrationApplied(migration) {
            return
        }

        // Create migration context with store registry
        let metadataSubspace = migrationSubspace.subspace("metadata")
        let context = MigrationContext(
            database: database,
            schema: schema,
            metadataSubspace: metadataSubspace,
            storeRegistry: storeRegistry  // Now type-safe!
        )

        // Execute migration
        try await migration.execute(context)

        // Mark as applied
        try await markMigrationApplied(migration)
    }

    // ... (other methods remain unchanged)
}
```

### 4.3 Lightweight Migrationの実装

```swift
// MigrationManager+Lightweight.swift

extension MigrationManager {
    /// Perform lightweight migration between two schemas
    ///
    /// Lightweight migrations handle simple schema changes automatically:
    /// - ✅ Adding new record types
    /// - ✅ Adding new indexes
    /// - ✅ Adding optional fields (with default values)
    ///
    /// **Not supported** (requires custom migration):
    /// - ❌ Removing record types
    /// - ❌ Removing fields
    /// - ❌ Changing field types
    /// - ❌ Data transformation
    ///
    /// **Example**:
    /// ```swift
    /// let migration = MigrationManager.lightweightMigration(
    ///     from: SchemaV1.self,
    ///     to: SchemaV2.self
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - fromSchema: Source schema
    ///   - toSchema: Target schema
    /// - Returns: Migration instance
    public static func lightweightMigration(
        from fromSchema: any VersionedSchema.Type,
        to toSchema: any VersionedSchema.Type
    ) -> Migration {
        let fromVersion = SchemaVersion(
            major: fromSchema.versionIdentifier.major,
            minor: fromSchema.versionIdentifier.minor,
            patch: fromSchema.versionIdentifier.patch
        )
        let toVersion = SchemaVersion(
            major: toSchema.versionIdentifier.major,
            minor: toSchema.versionIdentifier.minor,
            patch: toSchema.versionIdentifier.patch
        )

        return Migration(
            fromVersion: fromVersion,
            toVersion: toVersion,
            description: "Lightweight migration: \(fromVersion) → \(toVersion)"
        ) { context in
            // 1. Detect schema changes
            let fromSchemaObj = Schema(versionedSchema: fromSchema)
            let toSchemaObj = Schema(versionedSchema: toSchema)

            let changes = detectSchemaChanges(from: fromSchemaObj, to: toSchemaObj)

            // 2. Validate lightweight migration is possible
            guard changes.canBeAutomatic else {
                throw RecordLayerError.internalError(
                    "Cannot perform lightweight migration: " +
                    changes.unsupportedChanges.joined(separator: ", ")
                )
            }

            // 3. Apply changes automatically
            for indexToAdd in changes.indexesToAdd {
                try await context.addIndex(indexToAdd)
            }

            // New record types are automatically supported (no migration needed)
            // Optional fields with defaults are automatically supported
        }
    }

    // MARK: - Schema Change Detection

    /// Schema changes detected between two versions
    private struct SchemaChanges {
        let indexesToAdd: [Index]
        let indexesToRemove: [String]
        let newRecordTypes: [String]
        let unsupportedChanges: [String]

        var canBeAutomatic: Bool {
            return unsupportedChanges.isEmpty
        }
    }

    /// Detect changes between two schemas
    ///
    /// - Parameters:
    ///   - oldSchema: Source schema
    ///   - newSchema: Target schema
    /// - Returns: Schema changes
    private static func detectSchemaChanges(
        from oldSchema: Schema,
        to newSchema: Schema
    ) -> SchemaChanges {
        var indexesToAdd: [Index] = []
        var indexesToRemove: [String] = []
        var newRecordTypes: [String] = []
        var unsupportedChanges: [String] = []

        // Detect new indexes
        for index in newSchema.indexes {
            if oldSchema.index(named: index.name) == nil {
                indexesToAdd.append(index)
            }
        }

        // Detect removed indexes (requires custom migration)
        for index in oldSchema.indexes {
            if newSchema.index(named: index.name) == nil {
                indexesToRemove.append(index.name)
                unsupportedChanges.append(
                    "Index '\(index.name)' removed (requires custom migration with removeIndex())"
                )
            }
        }

        // Detect new record types (automatically supported)
        for entity in newSchema.entities {
            if oldSchema.entity(named: entity.name) == nil {
                newRecordTypes.append(entity.name)
            }
        }

        // Detect removed record types (not supported)
        for entity in oldSchema.entities {
            if newSchema.entity(named: entity.name) == nil {
                unsupportedChanges.append(
                    "Record type '\(entity.name)' removed (not supported in lightweight migration)"
                )
            }
        }

        // TODO: Detect field changes (requires Entity.properties comparison)
        // For now, field changes are not validated

        return SchemaChanges(
            indexesToAdd: indexesToAdd,
            indexesToRemove: indexesToRemove,
            newRecordTypes: newRecordTypes,
            unsupportedChanges: unsupportedChanges
        )
    }
}
```

### 4.4 SchemaMigrationPlan統合

```swift
// MigrationManager+Plan.swift

extension MigrationManager {
    /// Create MigrationManager from a SchemaMigrationPlan
    ///
    /// **Example**:
    /// ```swift
    /// enum MyPlan: SchemaMigrationPlan {
    ///     static var schemas: [any VersionedSchema.Type] = [V1.self, V2.self]
    ///     static var stages: [MigrationStage] = [
    ///         .lightweight(fromVersion: V1.self, toVersion: V2.self)
    ///     ]
    /// }
    ///
    /// let manager = try MigrationManager.from(
    ///     plan: MyPlan.self,
    ///     database: database,
    ///     storeRegistry: registry
    /// )
    /// try await manager.migrate(to: SchemaVersion(2, 0, 0))
    /// ```
    ///
    /// - Parameters:
    ///   - plan: SchemaMigrationPlan type
    ///   - database: Database instance
    ///   - storeRegistry: RecordStore registry
    ///   - migrationSubspace: Subspace for migration metadata
    /// - Returns: MigrationManager instance
    public static func from(
        plan: any SchemaMigrationPlan.Type,
        database: any DatabaseProtocol,
        storeRegistry: [String: any AnyRecordStore],
        migrationSubspace: Subspace? = nil
    ) throws -> MigrationManager {
        // 1. Get latest schema
        guard let latestSchemaType = plan.schemas.last else {
            throw RecordLayerError.invalidArgument("Migration plan has no schemas")
        }
        let latestSchema = Schema(versionedSchema: latestSchemaType)

        // 2. Convert stages to migrations
        let migrations = try plan.stages.map { stage -> Migration in
            try convertStageToMigration(stage)
        }

        // 3. Create manager
        return MigrationManager(
            database: database,
            schema: latestSchema,
            migrations: migrations,
            storeRegistry: storeRegistry,
            migrationSubspace: migrationSubspace
        )
    }

    /// Convert MigrationStage to Migration
    private static func convertStageToMigration(_ stage: MigrationStage) throws -> Migration {
        switch stage {
        case let .lightweight(fromVersion, toVersion):
            return lightweightMigration(from: fromVersion, to: toVersion)

        case let .custom(fromVersion, toVersion, willMigrate, didMigrate):
            let fromVer = SchemaVersion(
                major: fromVersion.versionIdentifier.major,
                minor: fromVersion.versionIdentifier.minor,
                patch: fromVersion.versionIdentifier.patch
            )
            let toVer = SchemaVersion(
                major: toVersion.versionIdentifier.major,
                minor: toVersion.versionIdentifier.minor,
                patch: toVersion.versionIdentifier.patch
            )

            return Migration(
                fromVersion: fromVer,
                toVersion: toVer,
                description: "Custom migration: \(fromVer) → \(toVer)"
            ) { context in
                // Pre-migration
                if let willMigrate = willMigrate {
                    try await willMigrate(context.schema)
                }

                // Main migration logic should be provided separately
                // This is just a wrapper for SwiftData compatibility

                // Post-migration
                if let didMigrate = didMigrate {
                    try await didMigrate(context.schema)
                }
            }
        }
    }
}
```

---

## 5. 実装計画

### Phase 1: Type-safe Infrastructure (優先度: 高)

**目標**: インデックス操作を可能にする基盤の構築

**タスク**:
- [ ] `AnyRecordStore` protocolの実装
  - File: `Sources/FDBRecordLayer/Store/AnyRecordStore.swift`
  - 推定工数: 4時間

- [ ] `RecordStore`への`AnyRecordStore`適合
  - File: `Sources/FDBRecordLayer/Store/RecordStore+Migration.swift`
  - 推定工数: 4時間

- [ ] `MigrationContext`の`storeRegistry`への移行
  - File: `Sources/FDBRecordLayer/Schema/Migration.swift`
  - 推定工数: 2時間

- [ ] `MigrationManager`の`storeRegistry`サポート
  - File: `Sources/FDBRecordLayer/Schema/MigrationManager.swift`
  - 推定工数: 2時間

- [ ] テスト: Type-safe store registry
  - File: `Tests/FDBRecordLayerTests/Schema/StoreRegistryTests.swift`
  - 推定工数: 3時間

**完了条件**:
- ✅ `MigrationContext.store(for:)`が型安全に動作
- ✅ 全既存テストがパス

### Phase 2: Index Operations (優先度: 高)

**目標**: インデックスマイグレーション操作の完全実装

**タスク**:
- [ ] `MigrationContext.addIndex()`の実装
  - File: `Sources/FDBRecordLayer/Schema/Migration.swift`
  - 推定工数: 6時間

- [ ] `MigrationContext.removeIndex()`の実装
  - File: `Sources/FDBRecordLayer/Schema/Migration.swift`
  - 推定工数: 4時間

- [ ] `MigrationContext.rebuildIndex()`の実装
  - File: `Sources/FDBRecordLayer/Schema/Migration.swift`
  - 推定工数: 3時間

- [ ] `FormerIndex`メタデータ管理
  - File: `Sources/FDBRecordLayer/Schema/FormerIndex.swift`
  - 推定工数: 3時間

- [ ] テスト: Index migration operations
  - File: `Tests/FDBRecordLayerTests/Schema/IndexMigrationTests.swift`
  - 推定工数: 6時間

**完了条件**:
- ✅ インデックス追加マイグレーションが動作
- ✅ インデックス削除マイグレーションが動作（FormerIndex記録）
- ✅ インデックス再構築マイグレーションが動作
- ✅ 中断・再開が正しく動作

### Phase 3: Lightweight Migration (優先度: 中)

**目標**: 自動スキーマ進化機能

**タスク**:
- [ ] `lightweightMigration()`の実装
  - File: `Sources/FDBRecordLayer/Schema/MigrationManager+Lightweight.swift`
  - 推定工数: 4時間

- [ ] `detectSchemaChanges()`の実装
  - File: `Sources/FDBRecordLayer/Schema/MigrationManager+Lightweight.swift`
  - 推定工数: 4時間

- [ ] バリデーション機能（unsupported changesの検出）
  - File: `Sources/FDBRecordLayer/Schema/MigrationManager+Lightweight.swift`
  - 推定工数: 2時間

- [ ] テスト: Lightweight migration
  - File: `Tests/FDBRecordLayerTests/Schema/LightweightMigrationTests.swift`
  - 推定工数: 4時間

**完了条件**:
- ✅ 新しいインデックス追加が自動で動作
- ✅ 新しいレコードタイプ追加が自動で動作
- ✅ サポートされない変更で適切なエラー

### Phase 4: SchemaMigrationPlan Integration (優先度: 中)

**目標**: SwiftData APIとの完全互換性

**タスク**:
- [ ] `MigrationManager.from(plan:)`の実装
  - File: `Sources/FDBRecordLayer/Schema/MigrationManager+Plan.swift`
  - 推定工数: 3時間

- [ ] `convertStageToMigration()`の実装
  - File: `Sources/FDBRecordLayer/Schema/MigrationManager+Plan.swift`
  - 推定工数: 2時間

- [ ] テスト: SchemaMigrationPlan integration
  - File: `Tests/FDBRecordLayerTests/Schema/SchemaMigrationPlanTests.swift`
  - 推定工数: 4時間

**完了条件**:
- ✅ `SchemaMigrationPlan`からの自動変換が動作
- ✅ lightweight/customステージが正しく変換

### Phase 5: Testing & Documentation (優先度: 中)

**タスク**:
- [ ] エンドツーエンドマイグレーションテスト
  - File: `Tests/FDBRecordLayerTests/Schema/EndToEndMigrationTests.swift`
  - 推定工数: 6時間

- [ ] パフォーマンステスト（大規模データ）
  - File: `Tests/FDBRecordLayerTests/Schema/MigrationPerformanceTests.swift`
  - 推定工数: 4時間

- [ ] ドキュメント更新（CLAUDE.md）
  - File: `CLAUDE.md`
  - 推定工数: 3時間

- [ ] 使用例の追加（README）
  - File: `README.md`
  - 推定工数: 2時間

**完了条件**:
- ✅ 全テストがパス（297+ tests）
- ✅ ドキュメントが最新
- ✅ 使用例が動作

### 総工数見積もり

| Phase | タスク数 | 推定工数 | 優先度 |
|-------|---------|---------|--------|
| Phase 1: Type-safe Infrastructure | 5 | 15時間 | 高 |
| Phase 2: Index Operations | 5 | 22時間 | 高 |
| Phase 3: Lightweight Migration | 4 | 14時間 | 中 |
| Phase 4: SchemaMigrationPlan | 3 | 9時間 | 中 |
| Phase 5: Testing & Documentation | 4 | 15時間 | 中 |
| **合計** | **21** | **75時間** | - |

**実装順序**:
1. Phase 1 → Phase 2（インデックス操作を最優先）
2. Phase 3 → Phase 4（自動化機能）
3. Phase 5（テストとドキュメント）

---

## 6. 使用例

### 6.1 基本的な使用例

```swift
import FDBRecordLayer
import FoundationDB

// 1. Define versioned schemas
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any Recordable.Type] = [User.self]
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any Recordable.Type] = [User.self, Order.self]
}

enum SchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any Recordable.Type] = [UserV3.self, Order.self]
}

// 2. Define migration plan
enum MyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [
        SchemaV1.self,
        SchemaV2.self,
        SchemaV3.self
    ]

    static var stages: [MigrationStage] = [
        // V1 → V2: Add Order record type (lightweight)
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),

        // V2 → V3: Transform User data (custom)
        .custom(
            fromVersion: SchemaV2.self,
            toVersion: SchemaV3.self,
            willMigrate: nil,
            didMigrate: { schema in
                print("Migration completed for schema \(schema.version)")
            }
        )
    ]
}

// 3. Create migrations from plan
let migrations = MyMigrationPlan.stages.map { stage -> Migration in
    switch stage {
    case let .lightweight(fromVersion, toVersion):
        return MigrationManager.lightweightMigration(from: fromVersion, to: toVersion)

    case let .custom(fromVersion, toVersion, willMigrate, didMigrate):
        let fromVer = SchemaVersion(
            major: fromVersion.versionIdentifier.major,
            minor: fromVersion.versionIdentifier.minor,
            patch: fromVersion.versionIdentifier.patch
        )
        let toVer = SchemaVersion(
            major: toVersion.versionIdentifier.major,
            minor: toVersion.versionIdentifier.minor,
            patch: toVersion.versionIdentifier.patch
        )

        return Migration(
            fromVersion: fromVer,
            toVersion: toVer,
            description: "Custom migration: \(fromVer) → \(toVer)"
        ) { context in
            // Pre-migration
            if let willMigrate = willMigrate {
                try await willMigrate(context.schema)
            }

            // Data transformation
            try await context.transformRecords(recordType: "User") { (user: User) in
                // Transform User to UserV3
                return UserV3(
                    id: user.id,
                    email: user.email,
                    fullName: "\(user.firstName) \(user.lastName)",  // Combine fields
                    status: .active  // New field with default
                )
            }

            // Post-migration
            if let didMigrate = didMigrate {
                try await didMigrate(context.schema)
            }
        }
    }
}

// 4. Create MigrationManager with store registry
let database = try FDB.selectAPIVersion(720).createDatabase()
let subspace = Subspace(prefix: Tuple("myapp").pack())
let currentSchema = Schema([UserV3.self, Order.self], version: .init(3, 0, 0))

let userStore = RecordStore<UserV3>(
    database: database,
    subspace: subspace,
    schema: currentSchema,
    statisticsManager: NullStatisticsManager()
)

let orderStore = RecordStore<Order>(
    database: database,
    subspace: subspace,
    schema: currentSchema,
    statisticsManager: NullStatisticsManager()
)

let storeRegistry: [String: any AnyRecordStore] = [
    "User": userStore,
    "UserV3": userStore,  // Map both old and new names
    "Order": orderStore
]

let migrationManager = MigrationManager(
    database: database,
    schema: currentSchema,
    migrations: migrations,
    storeRegistry: storeRegistry
)

// 5. Run migrations
try await migrationManager.migrate(to: SchemaVersion(major: 3, minor: 0, patch: 0))
```

### 6.2 インデックス追加マイグレーション

```swift
// Define schemas with different indexes
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any Recordable.Type] = [User.self]
}

@Recordable
struct User {
    @PrimaryKey var id: Int64
    var email: String
    var name: String
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any Recordable.Type] = [UserV2.self]
}

@Recordable
struct UserV2 {
    #Index<UserV2>([\.email])  // ← New index

    @PrimaryKey var id: Int64
    var email: String
    var name: String
}

// Migration plan
enum MyPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [SchemaV1.self, SchemaV2.self]
    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
    ]
}

// The lightweight migration will automatically:
// 1. Detect new email index
// 2. Build it online using OnlineIndexer
// 3. Mark it as readable
```

### 6.3 カスタムインデックス操作

```swift
let migration = Migration(
    fromVersion: SchemaVersion(1, 0, 0),
    toVersion: SchemaVersion(2, 0, 0),
    description: "Add email index and rebuild legacy index"
) { context in
    // Add new index
    let emailIndex = Index.value(
        named: "user_by_email",
        on: FieldKeyExpression(fieldName: "email"),
        recordTypes: Set(["User"])
    )
    try await context.addIndex(emailIndex)

    // Rebuild existing index (e.g., due to corruption or optimization)
    try await context.rebuildIndex(indexName: "user_by_name")

    // Remove legacy index
    try await context.removeIndex(
        indexName: "legacy_index",
        addedVersion: SchemaVersion(0, 9, 0)
    )
}
```

### 6.4 データ変換マイグレーション

```swift
let migration = Migration(
    fromVersion: SchemaVersion(2, 0, 0),
    toVersion: SchemaVersion(3, 0, 0),
    description: "Split name into firstName and lastName"
) { context in
    try await context.transformRecords(recordType: "User") { (user: UserV2) in
        let nameParts = user.name.split(separator: " ")
        return UserV3(
            id: user.id,
            email: user.email,
            firstName: String(nameParts.first ?? ""),
            lastName: String(nameParts.last ?? ""),
            createdAt: Date()  // New field with default
        )
    }
}
```

### 6.5 進行状況監視

```swift
// Start migration in background
Task {
    try await migrationManager.migrate(to: targetVersion)
}

// Monitor progress
while true {
    let currentVersion = try await migrationManager.getCurrentVersion()
    print("Current version: \(currentVersion)")

    if currentVersion == targetVersion {
        break
    }

    try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
}
```

---

## 7. 参考資料

### 7.1 Apple Documentation

- [SwiftData SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)
- [SwiftData VersionedSchema](https://developer.apple.com/documentation/swiftdata/versionedschema)
- [SwiftData MigrationStage](https://developer.apple.com/documentation/swiftdata/migrationstage)

### 7.2 FoundationDB Documentation

- [Transaction Limits](https://apple.github.io/foundationdb/known-limitations.html)
- [Best Practices](https://apple.github.io/foundationdb/developer-guide.html#best-practices)

### 7.3 Java Record Layer

- [FormerIndex](https://javadoc.io/doc/org.foundationdb/fdb-record-layer-core/latest/com/apple/foundationdb/record/metadata/FormerIndex.html)
- [OnlineIndexer](https://javadoc.io/doc/org.foundationdb/fdb-record-layer-core/latest/com/apple/foundationdb/record/provider/foundationdb/OnlineIndexer.html)

### 7.4 内部実装参照

| コンポーネント | ファイル | 参考ポイント |
|-------------|---------|------------|
| RangeSet | `Sources/FDBRecordLayer/Cursor/RangeSet.swift` | 進行状況追跡パターン |
| OnlineIndexer | `Sources/FDBRecordLayer/Index/OnlineIndexer.swift` | バッチ処理とスロットリング |
| IndexManager | `Sources/FDBRecordLayer/Index/IndexManager.swift` | インデックス管理パターン |
| RecordStore | `Sources/FDBRecordLayer/Store/RecordStore.swift` | 型安全なレコード操作 |

---

## 変更履歴

| 日付 | バージョン | 変更内容 | 著者 |
|------|----------|---------|------|
| 2025-01-13 | 1.0 | 初版作成 | Claude |

---

**End of Document**
