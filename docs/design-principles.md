# 設計原則

## 概要

FoundationDB Record Layer (Swift) の設計は、以下の8つの原則に基づいています。

---

## 1. レイヤーの分離 (Separation of Concerns)

### 原則

各レイヤーは明確に定義された責任を持ち、他のレイヤーの実装詳細に依存しない。

### 実装

```swift
// ✅ 良い例: 各レイヤーの責任が明確

// FDBRecordCore: モデル定義のみ
@Record
struct User {
    @ID var userID: Int64
    var email: String
}

// FDBRecordServer: 永続化ロジック
extension User {
    static func openStore(...) -> RecordStore<User> { ... }
}

// Client App: プレゼンテーションロジック
struct UserListView: View {
    let users: [User]
    var body: some View { ... }
}
```

```swift
// ❌ 悪い例: レイヤーの責任が混在

@Record
struct User {
    @ID var userID: Int64
    var email: String

    // ❌ プレゼンテーションロジックがモデルに混在
    var displayName: String {
        return name.isEmpty ? email : name
    }

    // ❌ 永続化ロジックがモデルに混在
    func save(to database: DatabaseProtocol) async throws { ... }
}
```

### 利点

- テスト容易性の向上
- コードの再利用性
- 保守性の向上

---

## 2. 型安全性 (Type Safety)

### 原則

コンパイル時に型エラーを検出し、実行時エラーを最小化する。

### 実装

```swift
// ✅ 良い例: 型安全なクエリAPI

let users = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .where(\.age, .greaterThan, 18)
    .execute()

// コンパイル時にフィールドの存在と型をチェック
// \.email は String 型のフィールド
// \.age は Int 型のフィールド
```

```swift
// ❌ 悪い例: 文字列ベースのクエリ（実行時エラーのリスク）

let users = try await store.query("SELECT * FROM users WHERE email = ? AND age > ?",
                                    ["alice@example.com", 18])
// フィールド名のタイポ、型の不一致は実行時にしか検出できない
```

### KeyPathベースのAPI

```swift
// インデックス定義も型安全
extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email]),
        .value(name: "age_index", keyPaths: [\.age]),
        .value(name: "composite", keyPaths: [\.city, \.age])  // 複合インデックス
    ]
}

// コンパイラが型をチェック
// \.email は User.email (String)
// \.age は User.age (Int)
```

---

## 3. 不変性とスレッドセーフ (Immutability & Thread Safety)

### 原則

データ構造は可能な限り不変にし、並行アクセスを安全にする。

### Sendable準拠

```swift
// ✅ 良い例: Sendable準拠

@Record
public struct User: Sendable {  // structは値型、Sendable準拠が容易
    @ID public var userID: Int64
    public var email: String
    public var name: String
}

// IndexDefinitionもSendable
public struct IndexDefinition<Record: FDBRecordCore.Record>: Sendable {
    public let name: String
    public let type: IndexType
    public let keyPaths: [PartialKeyPath<Record>]
}
```

### Mutexによる状態管理

```swift
// ✅ 良い例: Mutexで可変状態を保護

import Synchronization

public final class RecordStore<Record: FDBRecordCore.Record>: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let stateLock: Mutex<StoreState>

    private struct StoreState {
        var cacheSize: Int = 0
        var lastAccessTime: Date = Date()
    }

    public func updateCache() {
        stateLock.withLock { state in
            state.cacheSize += 1
            state.lastAccessTime = Date()
        }
    }
}
```

```swift
// ❌ 悪い例: 保護されていない可変状態

public final class RecordStore<Record: FDBRecordCore.Record> {
    private var cacheSize: Int = 0  // ❌ データ競合のリスク

    public func updateCache() {
        cacheSize += 1  // ❌ 複数スレッドから同時アクセス可能
    }
}
```

---

## 4. プログレッシブエンハンスメント (Progressive Enhancement)

### 原則

基本機能をシンプルに保ち、高度な機能は段階的に追加可能にする。

### 実装

```swift
// ✅ ステップ1: 基本的なモデル定義

@Record
struct User {
    @ID var userID: Int64
    var email: String
}

// ✅ ステップ2: サーバー側でインデックス追加（クライアントは変更不要）

extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email])
    ]
}

// ✅ ステップ3: さらにインデックス追加（既存コードは影響なし）

extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email]),
        .value(name: "name_index", keyPaths: [\.name]),  // 新規追加
    ]
}

// ✅ ステップ4: 集約インデックス追加

extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email]),
        .count(name: "user_count", keyPaths: []),  // カウントインデックス
    ]
}
```

### オプション機能の段階的有効化

```swift
// ✅ 基本機能: トランザクション
try await database.withTransaction { transaction in
    try await store.save(user, context: .init(transaction: transaction))
}

// ✅ 拡張機能: トランザクション + タイムアウト
try await database.withTransaction(timeout: .seconds(10)) { transaction in
    try await store.save(user, context: .init(transaction: transaction))
}

// ✅ 拡張機能: トランザクション + コミットフック
try await database.withTransaction { transaction in
    let context = RecordContext(transaction: transaction)
    context.addCommitHook { result in
        print("Commit result: \(result)")
    }
    try await store.save(user, context: context)
}
```

---

## 5. 明示的より暗黙的 (Explicit over Implicit)

### 原則

動作を暗黙的に推測するのではなく、明示的に指定する。

### 実装

```swift
// ✅ 良い例: snapshot パラメータを明示

try await database.withTransaction { transaction in
    // 読み取り専用、競合検知不要
    let value = try await transaction.getValue(for: key, snapshot: true)

    // 書き込みあり、競合検知必要
    let value2 = try await transaction.getValue(for: key, snapshot: false)
}
```

```swift
// ❌ 悪い例: 暗黙的な動作

try await database.withTransaction { transaction in
    // snapshot が暗黙的に決定される（読み取り専用かどうかを推測）
    let value = try await transaction.getValue(for: key)
}
```

### インデックスタイプの明示

```swift
// ✅ 良い例: インデックスタイプを明示

extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email]),      // VALUE インデックス
        .count(name: "user_count", keyPaths: [\.city]),        // COUNT インデックス
        .sum(name: "salary_sum", keyPaths: [\.city, \.salary]), // SUM インデックス
    ]
}
```

```swift
// ❌ 悪い例: 自動推測（意図が不明）

extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .auto(keyPaths: [\.email]),  // ❌ どのタイプのインデックス？
    ]
}
```

---

## 6. 失敗の可視化 (Fail Visibly)

### 原則

エラーは早期に検出し、詳細なコンテキストを提供する。

### エラーメッセージの詳細化

```swift
// ✅ 良い例: 詳細なエラーメッセージ

public enum RecordLayerError: Error, CustomStringConvertible {
    case indexNotFound(indexName: String, availableIndexes: [String])
    case invalidQuery(reason: String, field: String, expectedType: String, actualType: String)
    case schemaValidationFailed(errors: [SchemaValidationError])

    public var description: String {
        switch self {
        case .indexNotFound(let name, let available):
            return """
            Index '\(name)' not found.
            Available indexes: \(available.joined(separator: ", "))
            Did you forget to add it to serverIndexes?
            """

        case .invalidQuery(let reason, let field, let expected, let actual):
            return """
            Invalid query: \(reason)
            Field: \(field)
            Expected type: \(expected)
            Actual type: \(actual)
            """

        case .schemaValidationFailed(let errors):
            return """
            Schema validation failed with \(errors.count) error(s):
            \(errors.map { "- \($0.description)" }.joined(separator: "\n"))
            """
        }
    }
}
```

```swift
// ❌ 悪い例: 曖昧なエラーメッセージ

public enum RecordLayerError: Error {
    case indexError
    case queryError
    case schemaError

    // エラーの原因が不明
}
```

### アサーションとプリコンディション

```swift
// ✅ 良い例: プリコンディションで早期検出

public func save(_ record: Record, context: RecordContext) async throws {
    precondition(!context.transaction.isCommitted, "Transaction already committed")
    precondition(context.transaction.isValid, "Transaction is invalid")

    // ... 保存処理
}
```

---

## 7. パフォーマンスの透明性 (Performance Transparency)

### 原則

APIの計算量とコストを明確にし、驚きを最小化する。

### ドキュメント化

```swift
/// インデックスキーを使用してレコードをスキャンします。
///
/// **計算量**:
/// - 時間: O(log n + k)（n = 総レコード数、k = 結果件数）
/// - 空間: O(k)（メモリにバッファリング）
///
/// **FoundationDBトランザクション**:
/// - 読み取り: Range読み取り（beginKey〜endKey）
/// - トランザクション制限: 5秒、10MB
///
/// **使用例**:
/// ```swift
/// let users = try await store.query(User.self)
///     .where(\.email, .equals, "alice@example.com")
///     .execute()  // インデックススキャン → O(log n + 1)
/// ```
public func query<T: Record>(_ type: T.Type) -> QueryBuilder<T> { ... }
```

### バッチサイズの明示

```swift
// ✅ 良い例: バッチサイズを明示

public struct OnlineIndexer<Record: Sendable>: Sendable {
    public func buildIndex(
        batchSize: Int = 1000,  // デフォルト1000レコード/トランザクション
        timeout: Duration = .seconds(5)
    ) async throws {
        // ...
    }
}

// 使用
try await indexer.buildIndex(batchSize: 500)  // より小さなバッチ
```

```swift
// ❌ 悪い例: バッチサイズが隠蔽

public struct OnlineIndexer<Record: Sendable>: Sendable {
    public func buildIndex() async throws {
        // バッチサイズが不明（内部で決定）
    }
}
```

---

## 8. テスタビリティ (Testability)

### 原則

すべてのコンポーネントは単体でテスト可能であり、依存関係は注入可能にする。

### プロトコルベースの設計

```swift
// ✅ 良い例: プロトコルで抽象化

public protocol DatabaseProtocol: Sendable {
    func withTransaction<T>(_ operation: (TransactionProtocol) async throws -> T) async throws -> T
}

public final class RecordStore<Record: FDBRecordCore.Record>: Sendable {
    private let database: any DatabaseProtocol  // プロトコル型

    public init(database: any DatabaseProtocol, ...) {
        self.database = database
    }
}

// テスト用のモック実装
final class MockDatabase: DatabaseProtocol {
    var transactions: [MockTransaction] = []

    func withTransaction<T>(_ operation: (TransactionProtocol) async throws -> T) async throws -> T {
        let transaction = MockTransaction()
        transactions.append(transaction)
        return try await operation(transaction)
    }
}

// ユニットテスト
@Test func testRecordStoreSave() async throws {
    let mockDB = MockDatabase()
    let store = RecordStore<User>(database: mockDB, ...)

    try await store.save(user)

    #expect(mockDB.transactions.count == 1)
}
```

### テストヘルパーの提供

```swift
// ✅ 良い例: テスト用ヘルパー

extension User {
    static func testUser(
        userID: Int64 = 1,
        email: String = "test@example.com",
        name: String = "Test User"
    ) -> User {
        User(userID: userID, email: email, name: name)
    }
}

// テストで使用
@Test func testQuery() async throws {
    let user1 = User.testUser(userID: 1, email: "alice@example.com")
    let user2 = User.testUser(userID: 2, email: "bob@example.com")

    // ...
}
```

### 依存性注入

```swift
// ✅ 良い例: 依存性注入

public struct RecordSerializer<Record: FDBRecordCore.Record>: Sendable {
    private let encoder: any RecordEncoder
    private let decoder: any RecordDecoder

    public init(
        encoder: any RecordEncoder = ProtobufEncoder(),
        decoder: any RecordDecoder = ProtobufDecoder()
    ) {
        self.encoder = encoder
        self.decoder = decoder
    }

    public func serialize(_ record: Record) throws -> FDB.Bytes {
        try encoder.encode(record)
    }
}

// テストではモックエンコーダーを注入
let serializer = RecordSerializer<User>(
    encoder: MockEncoder(),
    decoder: MockDecoder()
)
```

---

## 設計原則の適用例

### 新機能追加時のチェックリスト

新しい機能を追加する際は、以下の原則を確認します：

- [ ] **レイヤーの分離**: この機能はどのレイヤーに属するか？他のレイヤーに依存していないか？
- [ ] **型安全性**: KeyPathやGenericsを使用して型安全にできないか？
- [ ] **不変性**: データ構造は不変か？Sendable準拠しているか？
- [ ] **プログレッシブエンハンスメント**: 既存の機能を壊さず、段階的に追加できるか？
- [ ] **明示的**: デフォルト値や暗黙的な動作はドキュメント化されているか？
- [ ] **失敗の可視化**: エラーメッセージは詳細か？原因と解決策を示しているか？
- [ ] **パフォーマンスの透明性**: 計算量とコストをドキュメント化しているか？
- [ ] **テスタビリティ**: 依存関係は注入可能か？単体テストを書きやすいか？

### コードレビュー時のチェックリスト

- [ ] モデル定義はFDBRecordCoreにあり、サーバー依存がないか？
- [ ] KeyPathベースのAPIを使用しているか？
- [ ] Sendable準拠を確認したか？
- [ ] 既存のAPIを壊していないか（後方互換性）？
- [ ] デフォルト値が適切にドキュメント化されているか？
- [ ] エラーメッセージは詳細で解決策を示しているか？
- [ ] APIドキュメントに計算量を記載しているか？
- [ ] ユニットテストが追加されているか？

---

## アンチパターン

### ❌ アンチパターン1: God Object

```swift
// ❌ 悪い例: すべての機能を1つのクラスに詰め込む

public final class RecordManager<Record: FDBRecordCore.Record> {
    func save(_ record: Record) async throws { ... }
    func query(_ query: String) async throws -> [Record] { ... }
    func buildIndex(_ index: Index) async throws { ... }
    func validateSchema(_ schema: Schema) throws { ... }
    func optimizeQuery(_ query: Query) -> QueryPlan { ... }
    func serializeRecord(_ record: Record) throws -> Data { ... }
    // ... さらに50個のメソッド
}
```

```swift
// ✅ 良い例: 責任を分離

public final class RecordStore<Record: FDBRecordCore.Record> { ... }
public final class IndexManager { ... }
public final class SchemaValidator { ... }
public final class RecordQueryPlanner<Record: FDBRecordCore.Record> { ... }
public struct RecordSerializer<Record: FDBRecordCore.Record> { ... }
```

### ❌ アンチパターン2: Stringly Typed API

```swift
// ❌ 悪い例: 文字列ベースのAPI

let users = try await store.query(
    "SELECT * FROM users WHERE email = ?",
    ["alice@example.com"]
)
```

```swift
// ✅ 良い例: KeyPathベースのAPI

let users = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

### ❌ アンチパターン3: 暗黙的な動作

```swift
// ❌ 悪い例: デフォルトで自動的にインデックス作成

@Record
struct User {
    @ID var userID: Int64
    var email: String  // ← 自動的にインデックスが作成される？
}
```

```swift
// ✅ 良い例: 明示的にインデックスを定義

@Record
struct User {
    @ID var userID: Int64
    var email: String
}

extension User {
    static let serverIndexes: [IndexDefinition<User>] = [
        .value(name: "email_index", keyPaths: [\.email])  // 明示的
    ]
}
```

---

## まとめ

これらの設計原則は、以下を実現するために定義されています：

1. **保守性**: コードの理解と変更が容易
2. **拡張性**: 新機能の追加が既存コードを壊さない
3. **信頼性**: エラーが早期に検出され、詳細な情報が提供される
4. **パフォーマンス**: 計算量とコストが透明で、最適化が容易
5. **テスタビリティ**: すべてのコンポーネントが単体でテスト可能

新しいコードを書く際は、これらの原則を常に念頭に置いてください。
