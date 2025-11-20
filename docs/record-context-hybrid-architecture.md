# RecordStore/RecordContext ハイブリッドアーキテクチャ設計

**作成日**: 2025-01-18
**ステータス**: 設計フェーズ

---

## 概要

このドキュメントは、FoundationDB Record Layer for Swiftにおける**RecordStoreとRecordContextのハイブリッドアーキテクチャ**の設計を定義します。

### 目的

- **3層API（RecordStore、RecordContext、ModelContext）を2層に統一**
- **命名規則の統一**: すべて`Record*`プレフィックスに統一（`Model*`は使用しない）
- **明確な責任分離**: 低レベルAPI（RecordStore）と高レベルAPI（RecordContext）を明確に分離
- **両方を公開API**: 柔軟性を保ちつつ、使いやすさも提供

### 設計原則

1. **Record*統一**: すべてのコンポーネントは`Record*`プレフィックスを使用
2. **SwiftDataパターン**: SwiftDataのModelContext APIに類似した高レベルAPIを提供
3. **下位互換性**: 既存の低レベルAPIは維持
4. **段階的移行**: 破壊的変更を避け、段階的に新APIに移行可能

---

## 現状分析

### 現在の3層構造

```
┌─────────────────────────────────────────────────────────────┐
│           RecordStore<Record>（低レベルCRUD）                │
│  - save(), delete(), load(), query()                        │
│  - 各操作が独自のトランザクションを作成                        │
│  - 公開API                                                   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│       RecordContext（トランザクションラッパー）                │
│  - transaction wrapper with commit hooks                    │
│  - metadata storage                                         │
│  - 公開API（但し名前が不明確）                                │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│         ModelContext（変更追跡 + SwiftData風API）            │
│  - insert(), delete(), save(), rollback()                   │
│  - change tracking (insertedModels, deletedModels)          │
│  - 公開API（但し命名規則が不統一）                             │
└─────────────────────────────────────────────────────────────┘
```

### 問題点

1. **命名の不統一**: `RecordStore`, `RecordContext`, `ModelContext`が混在
2. **責任の重複**: RecordContextとModelContextが部分的に重複
3. **位置づけの不明確**: どのAPIをいつ使うべきか不明
4. **SwiftDataとの乖離**: ModelContextという名前だがSwiftDataのModelContainerに相当するのはRecordContainer

---

## 設計目標

### 新しい2層構造

```
┌─────────────────────────────────────────────────────────────┐
│           RecordStore<Record>（低レベルCRUD）                │
│  ✅ 公開API                                                  │
│  - 直接的なデータベース操作                                    │
│  - 各操作が独自のトランザクション                              │
│  - 高度なカスタマイズが必要な場合に使用                         │
└─────────────────────────────────────────────────────────────┘
                            ▲
                            │ wraps
                            │
┌─────────────────────────────────────────────────────────────┐
│      RecordContext<Record>（高レベルラッパー）                │
│  ✅ 公開API                                                  │
│  - RecordStoreをラップ                                       │
│  - 変更追跡（insert/delete tracking）                        │
│  - バッチ保存（atomic save）                                 │
│  - ロールバックサポート                                       │
│  - SwiftData風のAPI                                         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│     TransactionContext（内部実装）                           │
│  ❌ 非公開（内部使用のみ）                                    │
│  - 現在のRecordContextをリネーム                              │
│  - トランザクションラッパーとして内部で使用                      │
└─────────────────────────────────────────────────────────────┘
```

### 命名規則の統一

| 現在 | 新しい名前 | 公開 | 役割 |
|------|----------|------|------|
| RecordStore | RecordStore | ✅ 公開 | 低レベルCRUD |
| RecordContext | TransactionContext | ❌ 内部 | トランザクションラッパー |
| ModelContext | RecordContext | ✅ 公開 | 高レベルラッパー |

---

## アーキテクチャ

### RecordStore（低レベルAPI）

**責任**:
- 直接的なデータベース操作（save, delete, load, query）
- 各操作が独自のトランザクションを作成
- インデックス管理、統計情報収集との統合
- 高度なカスタマイズが必要な場合に使用

**API設計**:
```swift
public final class RecordStore<Record: Recordable>: Sendable {
    // 既存のAPIは維持
    public func save(_ record: Record) async throws
    public func delete(primaryKey: Tuple) async throws
    public func load(primaryKey: Tuple) async throws -> Record?
    public func query() -> QueryBuilder<Record>

    // トランザクションAPI
    public func withTransaction<T>(
        _ block: (TransactionContext) async throws -> T
    ) async throws -> T
}
```

### RecordContext（高レベルAPI）

**責任**:
- 複数のRecordStoreをラップして変更追跡を提供
- 複数の型のバッチ挿入・削除を追跡
- アトミックな`save()`（すべての変更を1トランザクションで実行）
- ロールバックサポート
- SwiftData風のシンプルなAPI

**重要**: RecordContextは**非ジェネリック**で、**複数の型**を扱えます（SwiftData準拠）。

**API設計**:
```swift
public final class RecordContext: Sendable {
    // プロパティ
    public let container: RecordContainer
    public var hasChanges: Bool { get }
    public var autosaveEnabled: Bool { get set }

    // 変更追跡
    public var insertedModelsArray: [any Recordable] { get }
    public var deletedModelsArray: [any Recordable] { get }

    // CRUD操作（ジェネリックメソッド）
    public func insert<T: Recordable>(_ record: T)
    public func insert<T: Recordable>(_ records: [T])
    public func delete<T: Recordable>(_ record: T)
    public func delete<T: Recordable>(_ records: [T])
    public func delete<T: Recordable>(model: T.Type) async throws

    // 変更管理
    public func save() async throws
    public func rollback()

    // クエリ（型を指定）
    public func fetch<T: Recordable>(_ type: T.Type) -> QueryBuilder<T>

    // トランザクション
    public func withTransaction<T>(
        _ block: () async throws -> T
    ) async throws -> T

    // 初期化（内部使用のみ）
    internal init(container: RecordContainer)
}
```

**重要な設計ポイント**:
- **subspaceプロパティなし**: 各型が#Directoryマクロから自動解決
- **非ジェネリック**: 複数の型を同時に扱える
- **ジェネリックメソッド**: insert/delete/fetchは型パラメータを持つ

### TransactionContext（内部実装）

**責任**:
- トランザクションライフサイクル管理
- コミットフック
- メタデータストレージ

**実装**:
```swift
// Sources/FDBRecordLayer/Internal/TransactionContext.swift
internal final class TransactionContext: Sendable {
    // 現在のRecordContextをリネーム
    // 内部使用のみ
}
```

---

## 実装計画

### Phase 1: RecordContext → TransactionContext リネーム

**目的**: 現在のRecordContextを内部実装としてリネーム

**変更**:
1. `Sources/FDBRecordLayer/Transaction/RecordContext.swift` を削除
2. `Sources/FDBRecordLayer/Internal/TransactionContext.swift` を作成（既存コードを移動）
3. すべての内部参照を`TransactionContext`に変更

**影響範囲**:
- RecordStore内部（withTransaction）
- IndexManager内部
- OnlineIndexer内部

### Phase 2: 新RecordContext実装

**目的**: RecordStoreをラップする新しいRecordContext実装

**変更**:
1. `Sources/FDBRecordLayer/Context/RecordContext.swift` を新規作成
2. ModelContextの機能をマージ（変更追跡、save/rollback）
3. ジェネリック型パラメータ `<Record: Recordable>` を追加
4. RecordStoreをラップする設計に変更

**実装例**:
```swift
public final class RecordContext: Sendable {
    public let container: RecordContainer
    private let stateLock: Mutex<ContextState>

    private struct ContextState {
        // 型ごとに変更を追跡
        var insertedModels: [ObjectIdentifier: TypedRecordArray] = [:]
        var deletedModels: [ObjectIdentifier: TypedRecordArray] = [:]
        var autosaveEnabled: Bool = false
        var isSaving: Bool = false

        var hasChanges: Bool {
            !insertedModels.isEmpty || !deletedModels.isEmpty
        }
    }

    // 型情報を保持するラッパー
    private struct TypedRecordArray {
        let recordName: String
        let records: [any Recordable]
        let saveAll: (RecordContainer) async throws -> Void
        let deleteAll: (RecordContainer) async throws -> Void

        init<T: Recordable>(records: [T]) {
            self.recordName = T.recordName
            self.records = records
            // 型情報をクロージャにキャプチャ
            self.saveAll = { container in
                // #Directoryマクロから自動解決されたsubspaceを使用
                let subspace = T.directorySubspace(database: container.database)
                let store = container.store(for: T.self, subspace: subspace)
                for record in records {
                    try await store.save(record)
                }
            }
            self.deleteAll = { container in
                // #Directoryマクロから自動解決されたsubspaceを使用
                let subspace = T.directorySubspace(database: container.database)
                let store = container.store(for: T.self, subspace: subspace)
                for record in records {
                    let pk = GenericRecordAccess<T>().extractPrimaryKey(from: record)
                    try await store.delete(primaryKey: pk)
                }
            }
        }
    }

    public init(container: RecordContainer) {
        self.container = container
        self.stateLock = Mutex(ContextState())
    }

    public func insert<T: Recordable>(_ record: T) {
        let typeID = ObjectIdentifier(T.self)

        stateLock.withLock { state in
            // 削除キューから削除（insert→delete最適化）
            if var deletedArray = state.deletedModels[typeID] {
                var records = deletedArray.records.compactMap { $0 as? T }
                records.removeAll { areSamePrimaryKey($0, record) }
                if records.isEmpty {
                    state.deletedModels.removeValue(forKey: typeID)
                } else {
                    state.deletedModels[typeID] = TypedRecordArray(records: records)
                }
            }

            // 挿入キューに追加
            if var insertedArray = state.insertedModels[typeID] {
                var records = insertedArray.records.compactMap { $0 as? T }
                records.append(record)
                state.insertedModels[typeID] = TypedRecordArray(records: records)
            } else {
                state.insertedModels[typeID] = TypedRecordArray(records: [record])
            }
        }

        if autosaveEnabled {
            Task { try await save() }
        }
    }

    public func delete<T: Recordable>(_ record: T) {
        let typeID = ObjectIdentifier(T.self)

        stateLock.withLock { state in
            // 挿入キューから削除（insert→delete最適化）
            if var insertedArray = state.insertedModels[typeID] {
                var records = insertedArray.records.compactMap { $0 as? T }
                if records.removeAll(where: { areSamePrimaryKey($0, record) }) > 0 {
                    if records.isEmpty {
                        state.insertedModels.removeValue(forKey: typeID)
                    } else {
                        state.insertedModels[typeID] = TypedRecordArray(records: records)
                    }
                    return  // 挿入キャンセル、削除キューに追加しない
                }
            }

            // 削除キューに追加
            if var deletedArray = state.deletedModels[typeID] {
                var records = deletedArray.records.compactMap { $0 as? T }
                records.append(record)
                state.deletedModels[typeID] = TypedRecordArray(records: records)
            } else {
                state.deletedModels[typeID] = TypedRecordArray(records: [record])
            }
        }

        if autosaveEnabled {
            Task { try await save() }
        }
    }

    public func save() async throws {
        // 保存中フラグでレースコンディションを防止
        while true {
            let shouldWait = stateLock.withLock { state -> Bool in
                if state.isSaving { return true }
                state.isSaving = true
                return false
            }
            if !shouldWait { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        defer { stateLock.withLock { $0.isSaving = false } }

        // 変更を取得してクリア
        let (inserted, deleted) = stateLock.withLock { state in
            let inserted = state.insertedModels
            let deleted = state.deletedModels
            state.insertedModels.removeAll()
            state.deletedModels.removeAll()
            return (inserted, deleted)
        }

        // 1トランザクションで全型を保存
        try await container.withTransaction { context in
            // 挿入
            for (_, array) in inserted {
                try await array.saveAll(container)
            }

            // 削除
            for (_, array) in deleted {
                try await array.deleteAll(container)
            }
        }
    }

    public func rollback() {
        stateLock.withLock { state in
            state.insertedModels.removeAll()
            state.deletedModels.removeAll()
        }
    }

    public func fetch<T: Recordable>(_ type: T.Type) -> QueryBuilder<T> {
        // #Directoryマクロから自動解決されたsubspaceを使用
        let subspace = T.directorySubspace(database: container.database)
        let store = container.store(for: type, subspace: subspace)
        return store.query()
    }

    private func areSamePrimaryKey<T: Recordable>(_ lhs: T, _ rhs: T) -> Bool {
        let lhsPK = GenericRecordAccess<T>().extractPrimaryKey(from: lhs)
        let rhsPK = GenericRecordAccess<T>().extractPrimaryKey(from: rhs)
        return lhsPK.pack() == rhsPK.pack()
    }
}
```

### Phase 3: RecordContainer更新

**目的**: mainContextプロパティを追加

**変更**:
```swift
extension RecordContainer {
    // MARK: - RecordContext作成（SwiftData互換）

    /// メインコンテキスト（SwiftData mainContextと同じパターン）
    ///
    /// **重要**: subspaceは自動的に解決されます。
    /// - モデルの#Directoryマクロから自動的にpath/subspaceが決定される
    /// - 手動でpath指定は不要
    @MainActor
    public private(set) lazy var mainContext: RecordContext = {
        RecordContext(container: self)
    }()

    // MARK: - RecordStore作成（低レベルAPI）

    // 既存のstore()メソッドは維持（変更なし）
    public func store<Record: Recordable>(
        for type: Record.Type,
        subspace: Subspace
    ) -> RecordStore<Record>
}
```

### Phase 4: ModelContext削除

**目的**: ModelContextを完全に削除

**変更**:
1. `Sources/FDBRecordLayer/Core/ModelContext.swift` を削除
2. ModelContextテストをRecordContextテストに移行
3. ドキュメントの更新

---

## マイグレーションガイド

### Before（ModelContext使用）

```swift
// ❌ 旧API: ModelContext（単一型制限あり）
let container = try RecordContainer(for: User.self)
let context = ModelContext(container: container, path: "app/users")

let user = User(userID: 123, email: "alice@example.com", name: "Alice")
context.insert(user)

// ❌ Product は挿入できない（単一型制限）
// context.insert(product)  // Fatal error

if context.hasChanges {
    try await context.save()
}
```

### After（新RecordContext使用）

```swift
// ✅ 新API: RecordContext（複数型サポート）
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Directory<User>("app", "users")  // ← path自動解決

    var userID: Int64
    var email: String
    var name: String
}

@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])
    #Directory<Product>("app", "products")  // ← path自動解決

    var productID: Int64
    var name: String
    var price: Double
}

let container = try RecordContainer(for: User.self, Product.self, Order.self)

// mainContextを使用（SwiftData風）
let context = await container.mainContext

// 複数の型を扱える
// 各モデルの#Directoryマクロからpath/subspaceが自動解決される
let user = User(userID: 123, email: "alice@example.com", name: "Alice")
let product = Product(productID: 456, name: "Widget", price: 9.99)
let order = Order(orderID: 789, userID: 123, productID: 456)

context.insert(user)     // app/users に保存
context.insert(product)  // app/products に保存
context.insert(order)    // app/orders に保存

if context.hasChanges {
    try await context.save()  // すべての型を1トランザクションで保存
}
```

### 低レベルAPI使用（RecordStore直接使用）

```swift
// 低レベルAPIも引き続き使用可能（変更なし）
// ただし、低レベルAPIではsubspace/path指定が必要
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Directory<User>("app", "users")

    var userID: Int64
    var email: String
    var name: String
}

let container = try RecordContainer(for: User.self)

// #Directoryマクロから自動解決されたsubspaceを使用
let subspace = User.directorySubspace(database: container.database)
let store = container.store(for: User.self, subspace: subspace)

let user = User(userID: 123, email: "alice@example.com", name: "Alice")
try await store.save(user)

let users = try await store.query()
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

---

## テスト戦略

### RecordContextのテスト

#### 1. 変更追跡テスト

```swift
@Test("Insert tracking")
func testInsertTracking() async throws {
    let context = await container.mainContext

    let user = User(userID: 1, email: "test@example.com", name: "Test")
    context.insert(user)

    #expect(context.hasChanges == true)
    #expect(context.insertedRecordsArray.count == 1)
    #expect((context.insertedRecordsArray[0] as? User)?.userID == 1)
}

@Test("Delete tracking")
func testDeleteTracking() async throws {
    let context = await container.mainContext

    // 既存レコードを削除
    let user = User(userID: 1, email: "test@example.com", name: "Test")
    // 先にデータベースに保存（低レベルAPI経由）
    let subspace = User.directorySubspace(database: container.database)
    let store = container.store(for: User.self, subspace: subspace)
    try await store.save(user)

    context.delete(user)

    #expect(context.hasChanges == true)
    #expect(context.deletedModelsArray.count == 1)
}

@Test("Insert then delete optimization")
func testInsertDeleteOptimization() async throws {
    let context = await container.mainContext

    let user = User(userID: 1, email: "test@example.com", name: "Test")
    context.insert(user)
    context.delete(user)

    // 挿入をキャンセル、削除キューにも追加されない
    #expect(context.hasChanges == false)
    #expect(context.insertedModelsArray.count == 0)
    #expect(context.deletedModelsArray.count == 0)
}
```

#### 2. アトミック保存テスト

```swift
@Test("Atomic save all changes")
func testAtomicSave() async throws {
    let context = await container.mainContext

    let user1 = User(userID: 1, email: "alice@example.com", name: "Alice")
    let user2 = User(userID: 2, email: "bob@example.com", name: "Bob")

    context.insert(user1)
    context.insert(user2)

    try await context.save()

    // すべての変更がコミットされた
    let users = try await context.fetch(User.self).execute()
    #expect(users.count == 2)
    #expect(context.hasChanges == false)
}

@Test("Save atomicity on error")
func testSaveAtomicity() async throws {
    let context = await container.mainContext

    // 無効なレコード（重複プライマリキー）
    let user1 = User(userID: 1, email: "alice@example.com", name: "Alice")
    let user2 = User(userID: 1, email: "bob@example.com", name: "Bob")  // 重複

    context.insert(user1)
    context.insert(user2)

    // save()がエラー → すべてロールバック
    await #expect(throws: RecordLayerError.self) {
        try await context.save()
    }

    // データベースには何も保存されていない
    let users = try await context.fetch(User.self).execute()
    #expect(users.count == 0)
}
```

#### 3. ロールバックテスト

```swift
@Test("Rollback discards changes")
func testRollback() async throws {
    let context = await container.mainContext

    let user = User(userID: 1, email: "test@example.com", name: "Test")
    context.insert(user)

    #expect(context.hasChanges == true)

    context.rollback()

    #expect(context.hasChanges == false)
    #expect(context.insertedModelsArray.count == 0)
}
```

#### 4. 並行保存保護テスト

```swift
@Test("Concurrent save protection")
func testConcurrentSaveProtection() async throws {
    let context = await container.mainContext

    // 大量のレコードを挿入
    for i in 1...100 {
        let user = User(userID: Int64(i), email: "user\(i)@example.com", name: "User \(i)")
        context.insert(user)
    }

    // 並行してsave()を呼び出す
    async let save1 = context.save()
    async let save2 = context.save()

    try await save1
    try await save2

    // すべてのレコードが正確に保存されている
    let users = try await context.fetch(User.self).execute()
    #expect(users.count == 100)
}
```

---

## ファイル構造

### Before

```
Sources/FDBRecordLayer/
├── Core/
│   └── ModelContext.swift          ← 削除
├── Transaction/
│   └── RecordContext.swift         ← リネーム
└── Schema/
    └── RecordContainer.swift
```

### After

```
Sources/FDBRecordLayer/
├── Context/
│   └── RecordContext.swift         ← 新規実装（高レベルAPI）
├── Internal/
│   └── TransactionContext.swift    ← リネーム後（内部実装）
└── Schema/
    └── RecordContainer.swift       ← 更新（makeContext追加）
```

---

## まとめ

### 主要な変更点

1. **命名統一**: すべて`Record*`に統一
2. **2層構造**: RecordStore（低レベル）+ RecordContext（高レベル）
3. **両方公開**: 柔軟性と使いやすさを両立
4. **ModelContext削除**: RecordContextに統合

### メリット

- **明確な責任分離**: 低レベル/高レベルAPIの役割が明確
- **SwiftData風API**: 学習コストが低い
- **下位互換性**: 既存のRecordStore APIは維持
- **段階的移行**: 破壊的変更なし

### 次のステップ

1. Phase 1-4の実装
2. テストの追加
3. ドキュメントの更新（README.md、CLAUDE.md）
4. マイグレーションガイドの提供

---

**Last Updated**: 2025-01-18
**Status**: 設計完了、実装待ち
