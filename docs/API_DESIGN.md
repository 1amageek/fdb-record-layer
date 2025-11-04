# FDB Record Layer - SwiftData Style API Design

## 概要

このドキュメントは、FDB Record LayerをSwiftDataスタイルのAPIに変更するための設計を定義します。

### 設計原則

1. **RecordContextが中心**: すべての操作はRecordContextを通して行う
2. **contextパラメータを渡さない**: SwiftDataと同様、インスタンスメソッドで完結
3. **明示的なトランザクション**: `transaction { transaction in }` でTransactionオブジェクトを受け取る
4. **自動分離レベル管理**: トランザクション内は競合検出あり、単一操作は読み込み専用最適化

---

## API階層

```
RecordStore (コンテナ/ファクトリー)
  └─ RecordContext (主要API)
       ├─ 単一操作メソッド（自動トランザクション）
       └─ transaction { Transaction in }
            └─ Transaction (明示的トランザクション)
```

---

## 1. RecordStore (コンテナ)

### 役割
- TypedRecordContextの生成（ファクトリー）
- メタデータ、サブスペース、シリアライザーの管理
- SwiftDataの`ModelContainer`に相当
- **CRUD操作は提供しない**（すべてTypedRecordContextを通して行う）

### 公開API

```swift
public final class RecordStore<Record: Sendable>: Sendable {
    // MARK: - Properties

    public let subspace: Subspace
    public let metaData: RecordMetaData

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        serializer: any RecordSerializer<Record>,
        logger: Logger? = nil
    )

    // MARK: - Context Management

    /// コンテキストを作成
    ///
    /// TypedRecordContextは操作の基本単位です。
    /// すべての読み書き操作はTypedRecordContextを通して行います。
    ///
    /// - Returns: 新しいTypedRecordContextインスタンス
    public func createContext() async throws -> TypedRecordContext<Record>

    /// コンテキスト内で操作を実行
    ///
    /// 便利メソッド。内部でcreateContextを呼び出します。
    ///
    /// - Parameter block: TypedRecordContextを受け取るクロージャ
    /// - Returns: blockの戻り値
    public func withContext<T>(
        _ block: (TypedRecordContext<Record>) async throws -> T
    ) async throws -> T

    // MARK: - Index Management

    /// インデックスの状態を取得
    public func indexState(of indexName: String, context: RecordContext) async throws -> IndexState
}
```

### 内部実装の詳細

RecordStore は以下のメソッドを `internal` として持ちますが、これらは直接呼び出しません：

- `save(_:context:)`
- `save(_:expectedVersion:context:)`
- `fetch(primaryKey:context:snapshot:)`
- `fetchWithVersion(primaryKey:context:snapshot:)`
- `delete(primaryKey:context:)`
- `executeQuery(_:context:snapshot:)`

これらは TypedRecordContext と Transaction から内部的に呼び出されます。

### 使用例

```swift
// RecordStore作成
let recordStore = RecordStore<User>(
    database: database,
    subspace: Subspace(rootPrefix: "users"),
    metaData: metaData,
    serializer: ProtobufRecordSerializer<User>()
)

// コンテキスト作成
let context = try await recordStore.createContext()

// または便利メソッド
try await recordStore.withContext { context in
    try await context.save(user)
}
```

---

## 2. TypedRecordContext (主要API)

### 役割
- すべての読み書き操作を提供
- 単一操作は自動トランザクション管理（snapshot: true で最適化）
- 明示的トランザクションの作成
- SwiftDataの`ModelContext`に相当

### 重要な設計原則

**開発者は snapshot パラメータを意識しない**

- TypedRecordContext の単一操作 → 自動的に `snapshot: true`（読み込み専用最適化）
- Transaction 内の操作 → 自動的に `snapshot: false`（変更を検知）

### API

```swift
public final class TypedRecordContext<Record: Sendable> {
    // MARK: - Single Record Operations (Auto Transaction)

    /// レコードを主キーで取得（自動トランザクション）
    ///
    /// 内部で自動的にトランザクションを作成・コミットします。
    /// **内部で snapshot: true が自動設定されます**（読み込み専用最適化）
    ///
    /// - Parameter primaryKey: 主キーのTuple
    /// - Returns: レコード（見つからない場合はnil）
    public func fetch(by primaryKey: Tuple) async throws -> Record?

    /// レコードとバージョンを取得（自動トランザクション）
    ///
    /// 楽観的ロック（OCC）用にバージョン情報も取得します。
    /// **内部で snapshot: true が自動設定されます**
    ///
    /// - Parameter primaryKey: 主キーのTuple
    /// - Returns: (レコード, バージョン) のタプル（見つからない場合はnil）
    public func fetchWithVersion(by primaryKey: Tuple) async throws -> (record: Record, version: Version)?

    /// レコードを保存（自動トランザクション）
    ///
    /// 新規レコードの場合は挿入、既存レコードの場合は更新します。
    ///
    /// - Parameter record: 保存するレコード
    public func save(_ record: Record) async throws

    /// レコードをバージョンチェック付きで保存（自動トランザクション）
    ///
    /// 楽観的ロック。expectedVersionが現在のバージョンと一致しない場合はエラー。
    ///
    /// - Parameters:
    ///   - record: 保存するレコード
    ///   - expectedVersion: 期待されるバージョン（初回保存時はnil）
    /// - Throws: RecordLayerError.versionMismatch バージョンが一致しない場合
    public func save(_ record: Record, expectedVersion: Version?) async throws

    /// レコードを削除（自動トランザクション）
    ///
    /// - Parameter primaryKey: 削除するレコードの主キー
    public func delete(at primaryKey: Tuple) async throws

    // MARK: - Transaction

    /// 明示的トランザクション内で複数操作を実行
    ///
    /// トランザクション内の操作はすべて同じスナップショットを参照します。
    /// snapshot: false（競合検出あり）
    ///
    /// エラーが発生した場合、自動的にロールバックされます。
    /// 正常終了時は自動的にコミットされます。
    ///
    /// - Parameter block: Transactionオブジェクトを受け取るクロージャ
    /// - Returns: blockの戻り値
    ///
    /// Example:
    /// ```swift
    /// try await context.transaction { transaction in
    ///     try await transaction.save(user1)
    ///     try await transaction.save(user2)
    ///     let loaded = try await transaction.fetch(by: key)
    /// } // 自動コミット
    /// ```
    public func transaction<T>(
        _ block: (Transaction) async throws -> T
    ) async throws -> T
}
```

### 使用例

#### 単一操作

```swift
let context = try await recordStore.createContext()

// 保存
try await context.save(user)

// 取得
if let user = try await context.fetch(by: Tuple(1)) {
    print(user.name)
}

// バージョン付き取得
if let (user, version) = try await context.fetchWithVersion(by: Tuple(1)) {
    // バージョン情報を使用
    print("Version: \(version)")
}

// 削除
try await context.delete(at: Tuple(1))
```

#### 楽観的ロック

```swift
// 読み込み
let (user, version) = try await context.fetchWithVersion(by: Tuple(1))!

// 変更
var updatedUser = user
updatedUser.name = "New Name"

// バージョンチェック付き保存
try await context.save(updatedUser, expectedVersion: version)
```

#### トランザクション

```swift
try await context.transaction { transaction in
    // 複数操作をアトミックに実行
    try await transaction.save(user1)
    try await transaction.save(user2)

    let loaded = try await transaction.fetch(by: key)
    try await transaction.delete(at: oldKey)
}
```

---

## 3. Transaction (トランザクション内専用)

### 役割
- トランザクション内での読み書き操作
- **内部で常に snapshot: false を自動設定**（競合検出あり）
- Read-Your-Writes保証
- 開発者は snapshot を意識する必要なし

### API

```swift
public final class Transaction<Record: Sendable> {
    // MARK: - Read Operations

    /// レコードを主キーで取得
    ///
    /// トランザクション内での読み込み。
    /// **内部で snapshot: false が自動設定されます**（競合検出あり）
    ///
    /// - Parameter primaryKey: 主キーのTuple
    /// - Returns: レコード（見つからない場合はnil）
    public func fetch(by primaryKey: Tuple) async throws -> Record?

    /// クエリでレコードを検索
    ///
    /// カーソル（AsyncSequence）を返します。
    /// **内部で snapshot: false が自動設定されます**（競合検出あり）
    ///
    /// - Parameter query: RecordQuery
    /// - Returns: RecordCursor（AsyncSequence）
    ///
    /// Example:
    /// ```swift
    /// let query = RecordQuery(
    ///     recordType: "User",
    ///     filter: FieldQueryComponent(
    ///         fieldName: "age",
    ///         comparison: .greaterThanOrEquals,
    ///         value: 18
    ///     )
    /// )
    /// let cursor = try await transaction.fetch(query)
    /// for try await user in cursor {
    ///     print(user.name)
    /// }
    /// ```
    public func fetch(_ query: RecordQuery) async throws -> RecordCursor

    /// レコードとバージョンを取得
    ///
    /// **内部で snapshot: false が自動設定されます**
    ///
    /// - Parameter primaryKey: 主キーのTuple
    /// - Returns: (レコード, バージョン)のタプル
    public func fetchWithVersion(by primaryKey: Tuple) async throws -> (record: Record, version: Version)?

    // MARK: - Write Operations

    /// レコードを保存
    ///
    /// 新規の場合は挿入、既存の場合は更新。
    /// インデックスは自動的に更新されます。
    ///
    /// - Parameter record: 保存するレコード
    public func save(_ record: Record) async throws

    /// レコードをバージョンチェック付きで保存
    ///
    /// 楽観的ロック。expectedVersionが現在のバージョンと一致しない場合はエラー。
    ///
    /// - Parameters:
    ///   - record: 保存するレコード
    ///   - expectedVersion: 期待されるバージョン
    /// - Throws: RecordLayerError.versionMismatch バージョン不一致
    public func save(_ record: Record, expectedVersion: Version?) async throws

    /// レコードを削除
    ///
    /// インデックスからも自動的に削除されます。
    ///
    /// - Parameter primaryKey: 削除するレコードの主キー
    public func delete(at primaryKey: Tuple) async throws
}
```

### 使用例

#### 複数レコードの保存

```swift
try await context.transaction { transaction in
    try await transaction.save(user1)
    try await transaction.save(user2)
    try await transaction.save(user3)
} // 自動コミット
```

#### 読み込みと書き込み

```swift
try await context.transaction { transaction in
    // 読み込み
    let user = try await transaction.fetch(by: Tuple(1))

    // 変更
    var updated = user
    updated.age += 1

    // 保存
    try await transaction.save(updated)
}
```

#### クエリ実行

```swift
try await context.transaction { transaction in
    let query = RecordQuery(
        recordType: "User",
        filter: FieldQueryComponent(
            fieldName: "age",
            comparison: .greaterThanOrEquals,
            value: Int64(30)
        )
    )

    let cursor = try await transaction.fetch(query)
    for try await user in cursor {
        print("User: \(user.name), Age: \(user.age)")
    }
}
```

#### エラーハンドリング

```swift
do {
    try await context.transaction { transaction in
        try await transaction.save(user1)

        if !isValid(user1) {
            throw ValidationError.invalid
        }

        try await transaction.save(user2)
    }
} catch {
    // 自動的にロールバック済み
    print("Transaction failed: \(error)")
}
```

---

## 4. 分離レベルの管理（自動）

### 重要: 開発者は snapshot パラメータを意識しない

分離レベルは **内部で自動的に設定** されます。開発者が明示的に指定する必要はありません。

### TypedRecordContext の単一操作

```swift
// 内部で自動的に snapshot: true が設定されます
try await context.fetch(by: key)
try await context.fetchWithVersion(by: key)
```

**特徴**:
- **読み込み専用最適化**（snapshot: true）
- 競合検出なし
- 効率的
- 書き込み操作（save, delete）には snapshot は関係ない

**注意**: クエリ操作は TypedRecordContext では提供されません（Transaction 内で実行）

### Transaction 内の操作

```swift
// 内部で自動的に snapshot: false が設定されます
try await context.transaction { transaction in
    try await transaction.fetch(by: key)
    try await transaction.fetch(query)
    try await transaction.save(record)
}
```

**特徴**:
- **変更を検知**（snapshot: false）
- 競合検出あり（Serializable）
- Read-Your-Writes保証
- 書き込みと併用可能
- 一貫性のあるスナップショット

### 内部実装

RecordStore のメソッドは snapshot パラメータを持ちますが、これは内部実装の詳細です：

```swift
// RecordStore (internal)
internal func fetch(primaryKey: Tuple, context: RecordContext, snapshot: Bool) async throws -> Record?
```

呼び出し側で適切な値が自動設定されます：
- TypedRecordContext → `snapshot: true`
- Transaction → `snapshot: false`

---

## 5. 破壊的変更

### 削除されるAPI

```swift
// ❌ RecordStore 直接の CRUD 操作（公開 API から削除）
recordStore.save(record)
recordStore.fetch(by: key)
recordStore.delete(at: key)

// ❌ TransactionalStore（完全に削除、Transaction に置き換え）
recordStore.transaction { tx in
    tx.save(record)  // tx は TransactionalStore
}

// ❌ RecordStoreProtocol 準拠（削除）
public final class RecordStore<Record: Sendable>: RecordStoreProtocol
```

### 内部化されるAPI

RecordStore の以下のメソッドは `internal` になります（公開 API ではなくなる）：

```swift
// internal（TypedRecordContext と Transaction から呼び出される）
internal func save(_ record: Record, context: RecordContext) async throws
internal func fetch(primaryKey: Tuple, context: RecordContext, snapshot: Bool) async throws -> Record?
internal func delete(primaryKey: Tuple, context: RecordContext) async throws
```

### 新しいAPI

```swift
// ✅ TypedRecordContext を通した操作
let context = try await recordStore.createContext()
try await context.save(record)
try await context.fetch(by: key)

// ✅ 明示的トランザクション（Transaction オブジェクトを受け取る）
try await context.transaction { transaction in
    try await transaction.save(record)  // transaction は Transaction<Record>
}
```

---

## 6. マイグレーションガイド

### Before (旧API)

```swift
// RecordStore作成
let recordStore = RecordStore<User>(...)

// ❌ 単一操作（削除）
try await recordStore.save(user)
let user = try await recordStore.fetch(by: Tuple(1))

// ❌ TransactionalStore（削除）
try await recordStore.transaction { tx in
    try await tx.save(user1)
    try await tx.save(user2)
}

// ❌ context付き（内部化）
try await database.withRecordContext { context in
    try await recordStore.save(user, context: context)
}
```

### After (新API)

```swift
// RecordStore作成（同じ）
let recordStore = RecordStore<User>(...)

// ✅ コンテキスト作成（必須）
let context = try await recordStore.createContext()

// ✅ 単一操作（自動的に snapshot: true）
try await context.save(user)
let user = try await context.fetch(by: Tuple(1))

// ✅ Transaction（自動的に snapshot: false）
try await context.transaction { transaction in
    try await transaction.save(user1)
    try await transaction.save(user2)
    let loaded = try await transaction.fetch(by: key)
}

// ✅ snapshot パラメータを意識する必要なし
```

---

## 7. ベストプラクティス

### コンテキストの再利用

```swift
// ✅ 推奨: コンテキストを再利用
let context = try await recordStore.createContext()

try await context.save(user1)
try await context.save(user2)
try await context.save(user3)
```

### トランザクションの使用

```swift
// ✅ 複数操作をアトミックに実行
try await context.transaction { transaction in
    try await transaction.save(user1)
    try await transaction.save(user2)
}

// ❌ 単一操作でトランザクションは不要
try await context.transaction { transaction in
    try await transaction.save(user)  // 不要
}

// ✅ 単一操作は直接
try await context.save(user)
```

### エラーハンドリング

```swift
// ✅ トランザクションは自動ロールバック
try await context.transaction { transaction in
    try await transaction.save(user1)

    if !validate(user1) {
        throw ValidationError()  // 自動ロールバック
    }

    try await transaction.save(user2)
}
```

---

## 8. 実装状況

### ✅ 完了

1. **Transaction クラス作成** - `Sources/FDBRecordLayer/Transaction/Transaction.swift`
   - すべての CRUD メソッド実装
   - snapshot: false を自動設定

2. **TypedRecordContext 作成** - `Sources/FDBRecordLayer/Transaction/TypedRecordContext.swift`
   - SwiftData スタイルの主要 API
   - snapshot: true を自動設定
   - transaction() メソッド実装

3. **RecordStore リファクタリング** - `Sources/FDBRecordLayer/Store/RecordStore.swift`
   - 公開 API から CRUD メソッドを削除
   - createContext() と withContext() を追加
   - CRUD メソッドを internal に変更
   - TransactionalStore を削除
   - RecordStoreProtocol 準拠を削除

4. **RecordStoreProtocol 保持** - `Sources/FDBRecordLayer/Store/RecordStoreProtocol.swift`
   - プロトコル自体は将来の拡張性のため保持
   - RecordStore は準拠しない

5. **Examples 更新** - `Examples/SimpleExample.swift`
   - 新しい API パターンに更新
   - context.transaction { transaction in } の使用例を追加

6. **README 更新** - `README.md`
   - SwiftData スタイル API の説明を追加
   - コード例を更新

7. **ドキュメント更新** - `docs/API_DESIGN.md`
   - 完全な API 仕様を記載
   - snapshot 自動管理の説明を追加
   - マイグレーションガイドを更新

### ⏳ 今後必要な作業

1. **Tests 更新** - `Tests/FDBRecordLayerTests/**/*.swift`
   - 新しい API に合わせてテストを更新
   - TypedRecordContext のテストを追加
   - Transaction のテストを追加
