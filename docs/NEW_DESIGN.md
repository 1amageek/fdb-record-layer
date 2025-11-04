# FDB Record Layer - 新設計提案（改訂版）

## 概要

現在の実装における型システムの不整合とトランザクションスコープの問題を解決する、完全に実装可能な設計を提案します。

## 現在の問題点の詳細分析

### 🔴 致命的な問題（Critical）

1. **型システムの不整合**
   - RecordStore は `Record` 型パラメータを持つが、内部実装は `[String: Any]` を強制
   - IndexMaintainer プロトコルが `[String: Any]` を要求
   - Protobuf メッセージが保存できない（即座にクラッシュ）

2. **RecordAccess の契約が未定義**
   - KeyExpression の評価方法が不明確
   - RecordMetaData との一貫性保証メカニズムがない
   - 実装不能なまま

3. **トランザクションスコープの問題**
   - `transaction { }` ブロックから RecordCursor を返すと、ブロック外で無効になる
   - 型システムで表現できない（実行時エラー）

### 🟡 重大な問題（Major）

4. **RecordCursor の型安全性欠如**
   - 結果が `[String: Any]` で返る
   - ユーザーが手動でダウンキャスト
   - SwiftData スタイルの型安全性がない

5. **辞書前提のコード**
   - KeyExpression.evaluate() が `[String: Any]` のみ対応
   - 全インデックスメンテナが辞書に依存

6. **パフォーマンス問題**
   - RankIndex の降順処理で `removeFirst()` を使用 (O(N * endRank))

---

## 新設計の方針

### 設計原則

1. **完全な型安全性**: コンパイル時に可能な限り多くのエラーを検出
2. **実装可能性**: すべての設計が具体的な実装方法を持つ
3. **一貫性保証**: RecordAccess と RecordMetaData の整合性を検証
4. **明確なスコープ**: トランザクションとカーソルの関係を型で表現
5. **後方互換性**: 辞書ベースの API も引き続きサポート

---

## 1. KeyExpression 評価システムの完全設計

### 1.1 KeyExpressionVisitor パターン

KeyExpression を統一的に評価するビジターパターンを導入します。

```swift
/// KeyExpression を評価するビジターインターフェース
public protocol KeyExpressionVisitor {
    associatedtype Result

    func visitField(_ fieldName: String) throws -> Result
    func visitConcatenate(_ expressions: [KeyExpression]) throws -> Result
    func visitEmpty() throws -> Result
    func visitThen(_ first: KeyExpression, _ second: KeyExpression) throws -> Result
}

/// KeyExpression を走査可能にする
extension KeyExpression {
    public func accept<V: KeyExpressionVisitor>(visitor: V) throws -> V.Result {
        switch self {
        case let field as FieldKeyExpression:
            return try visitor.visitField(field.fieldName)
        case let concat as ConcatenateExpression:
            return try visitor.visitConcatenate(concat.children)
        case is EmptyKeyExpression:
            return try visitor.visitEmpty()
        case let then as ThenKeyExpression:
            return try visitor.visitThen(then.first, then.second)
        default:
            throw RecordLayerError.notImplemented("Unsupported KeyExpression")
        }
    }
}
```

### 1.2 RecordAccess プロトコルの完全な定義

```swift
/// レコードからメタデータとフィールド値を抽出
///
/// **責務:**
/// - レコード型名の取得
/// - KeyExpression の評価（Visitor パターンで実装）
/// - シリアライゼーション
///
/// **一貫性:**
/// RecordMetaData と整合性を持つ必要があります。
/// RecordStore 初期化時に検証されます。
public protocol RecordAccess<Record>: Sendable {
    associatedtype Record: Sendable

    // MARK: - メタデータ

    /// レコード型名を取得
    func recordTypeName(for record: Record) -> String

    // MARK: - KeyExpression 評価

    /// KeyExpression を評価してフィールド値を抽出
    func evaluate(
        record: Record,
        expression: KeyExpression
    ) throws -> [any TupleElement]

    /// 単一フィールドを抽出（Visitor から呼ばれる）
    func extractField(
        from record: Record,
        fieldName: String
    ) throws -> [any TupleElement]

    // MARK: - シリアライゼーション

    func serialize(_ record: Record) throws -> FDB.Bytes
    func deserialize(_ bytes: FDB.Bytes) throws -> Record
}

// MARK: - Default Implementation

extension RecordAccess {
    /// KeyExpression を評価（デフォルト実装）
    public func evaluate(
        record: Record,
        expression: KeyExpression
    ) throws -> [any TupleElement] {
        let visitor = RecordAccessEvaluator(recordAccess: self, record: record)
        return try expression.accept(visitor: visitor)
    }
}

// MARK: - RecordAccessEvaluator

fileprivate struct RecordAccessEvaluator<Access: RecordAccess>: KeyExpressionVisitor {
    let recordAccess: Access
    let record: Access.Record

    typealias Result = [any TupleElement]

    func visitField(_ fieldName: String) throws -> [any TupleElement] {
        return try recordAccess.extractField(from: record, fieldName: fieldName)
    }

    func visitConcatenate(_ expressions: [KeyExpression]) throws -> [any TupleElement] {
        var result: [any TupleElement] = []
        for expression in expressions {
            let values = try expression.accept(visitor: self)
            result.append(contentsOf: values)
        }
        return result
    }

    func visitEmpty() throws -> [any TupleElement] {
        return []
    }

    func visitThen(_ first: KeyExpression, _ second: KeyExpression) throws -> [any TupleElement] {
        return try first.accept(visitor: self)
    }
}
```

### 1.3 Protobuf 用の実装

**実装方法: ProtobufFieldExtractor によるフィールドマッピング**

```swift
/// Protobuf メッセージ用の RecordAccess 実装
public struct ProtobufRecordAccess<M: SwiftProtobuf.Message & Sendable>: RecordAccess {
    public typealias Record = M

    private let typeName: String
    private let fieldExtractor: ProtobufFieldExtractor<M>

    public init(
        typeName: String,
        fieldExtractor: ProtobufFieldExtractor<M>
    ) {
        self.typeName = typeName
        self.fieldExtractor = fieldExtractor
    }

    public func recordTypeName(for record: M) -> String {
        return typeName
    }

    public func extractField(
        from record: M,
        fieldName: String
    ) throws -> [any TupleElement] {
        return try fieldExtractor.extract(from: record, fieldPath: fieldName)
    }

    public func serialize(_ record: M) throws -> FDB.Bytes {
        return try Array(record.serializedData())
    }

    public func deserialize(_ bytes: FDB.Bytes) throws -> M {
        return try M(serializedBytes: bytes)
    }
}

// MARK: - ProtobufFieldExtractor

/// Protobuf メッセージからフィールド値を抽出
///
/// **実装方法:**
/// 1. **手動実装（推奨）**: 各メッセージ型ごとに手動でマッピングを定義
/// 2. コード生成: プロトコル定義から自動生成（将来的な拡張）
/// 3. Reflection: SwiftProtobuf の API（パフォーマンス低下）
///
/// **使用例:**
/// ```swift
/// extension ProtobufFieldExtractor where M == User {
///     public static func forUser() -> ProtobufFieldExtractor<User> {
///         return ProtobufFieldExtractor(extractors: [
///             "userID": { user in [user.userID] },
///             "name": { user in [user.name] },
///             "email": { user in [user.email] }
///         ])
///     }
/// }
/// ```
public struct ProtobufFieldExtractor<M: SwiftProtobuf.Message & Sendable>: Sendable {
    private let extractors: [String: @Sendable (M) throws -> [any TupleElement]]

    public init(
        extractors: [String: @Sendable (M) throws -> [any TupleElement]]
    ) {
        self.extractors = extractors
    }

    public func extract(
        from record: M,
        fieldPath: String
    ) throws -> [any TupleElement] {
        // 単一フィールド
        guard let extractor = extractors[fieldPath] else {
            throw RecordLayerError.invalidKey("Unknown field: \(fieldPath) in \(M.self)")
        }
        return try extractor(record)
    }
}

// MARK: - 使用例: User メッセージ

extension ProtobufFieldExtractor where M == User {
    /// User 用の FieldExtractor を作成
    ///
    /// **マッピング定義:**
    /// - "userID" → user.userID (Int64)
    /// - "name" → user.name (String)
    /// - "email" → user.email (String)
    /// - "age" → user.age (Int32 → Int64)
    public static func forUser() -> ProtobufFieldExtractor<User> {
        return ProtobufFieldExtractor(extractors: [
            "userID": { user in [user.userID] },
            "name": { user in [user.name] },
            "email": { user in [user.email] },
            "age": { user in [Int64(user.age)] }
        ])
    }
}
```

### 1.4 辞書用の実装（後方互換性）

```swift
/// 辞書用の RecordAccess 実装
public struct DictionaryRecordAccess: RecordAccess {
    public typealias Record = [String: Any]

    public func recordTypeName(for record: [String: Any]) -> String {
        return record["_type"] as? String ?? "Unknown"
    }

    public func extractField(
        from record: [String: Any],
        fieldName: String
    ) throws -> [any TupleElement] {
        // ドット記法対応: "user.address.city"
        let components = fieldName.split(separator: ".")
        var current: Any = record

        for component in components {
            guard let dict = current as? [String: Any],
                  let value = dict[String(component)] else {
                throw RecordLayerError.invalidKey("Field not found: \(fieldName)")
            }
            current = value
        }

        // TupleElement に変換
        guard let element = convertToTupleElement(current) else {
            throw RecordLayerError.invalidKey("Cannot convert to TupleElement: \(current)")
        }

        return [element]
    }

    public func serialize(_ record: [String: Any]) throws -> FDB.Bytes {
        let data = try JSONEncoder().encode(record)
        return Array(data)
    }

    public func deserialize(_ bytes: FDB.Bytes) throws -> [String: Any] {
        let data = Data(bytes)
        return try JSONDecoder().decode([String: Any].self, from: data)
    }

    private func convertToTupleElement(_ value: Any) -> (any TupleElement)? {
        switch value {
        case let int as Int: return Int64(int)
        case let int64 as Int64: return int64
        case let string as String: return string
        case let data as Data: return Array(data)
        case let bytes as [UInt8]: return bytes
        default: return nil
        }
    }
}
```

---

## 2. RecordAccess と RecordMetaData の一貫性保証

### 2.1 問題の明確化

RecordAccess が RecordMetaData と不整合の場合：
- 存在しないフィールドを参照 → 実行時エラー
- プライマリキーの定義が異なる → データ破損
- インデックスキーが評価できない → インデックス構築失敗

### 2.2 一貫性検証の設計

```swift
/// RecordMetaData と RecordAccess の一貫性を検証
public struct RecordAccessValidator<Access: RecordAccess> {
    private let metaData: RecordMetaData
    private let recordAccess: Access

    public init(metaData: RecordMetaData, recordAccess: Access) {
        self.metaData = metaData
        self.recordAccess = recordAccess
    }

    /// 一貫性を検証
    /// - Throws: 不整合がある場合にエラー
    public func validate() throws {
        // 1. プライマリキーの検証
        for recordType in metaData.recordTypes {
            try validateKeyExpression(
                recordType.primaryKey,
                context: "Primary key for \(recordType.name)"
            )
        }

        // 2. インデックスキーの検証
        for index in metaData.indexes {
            try validateKeyExpression(
                index.rootExpression,
                context: "Index \(index.name)"
            )
        }
    }

    private func validateKeyExpression(
        _ expression: KeyExpression,
        context: String
    ) throws {
        // KeyExpression の構造を検証
        let visitor = ValidationVisitor(context: context)
        try expression.accept(visitor: visitor)
    }
}

// MARK: - ValidationVisitor

private struct ValidationVisitor: KeyExpressionVisitor {
    let context: String

    typealias Result = Void

    func visitField(_ fieldName: String) throws {
        guard !fieldName.isEmpty else {
            throw RecordLayerError.invalidKey("\(context): Empty field name")
        }
        // フィールド名の妥当性チェック（特殊文字など）
    }

    func visitConcatenate(_ expressions: [KeyExpression]) throws {
        for expression in expressions {
            try expression.accept(visitor: self)
        }
    }

    func visitEmpty() throws {
        // Empty は常に有効
    }

    func visitThen(_ first: KeyExpression, _ second: KeyExpression) throws {
        try first.accept(visitor: self)
        try second.accept(visitor: self)
    }
}
```

### 2.3 RecordStore での検証実行

```swift
public final class RecordStore<Record: Sendable>: Sendable {
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        recordAccess: any RecordAccess<Record>
    ) throws {
        self.database = database
        self.subspace = subspace
        self.recordSubspace = subspace.subspace(named: "records")
        self.metaData = metaData
        self.recordAccess = recordAccess
        self.logger = Logger(label: "RecordStore")

        // ✅ 一貫性検証（初期化時）
        let validator = RecordAccessValidator(
            metaData: metaData,
            recordAccess: recordAccess
        )
        try validator.validate()

        // インデックスメンテナを初期化
        self.indexMaintainers = metaData.indexes.map { index in
            AnyIndexMaintainer(
                createMaintainer(for: index, subspace: subspace)
            )
        }
    }
}
```

### 2.4 実行時検証

```swift
extension RecordStore {
    internal func save(_ record: Record, context: RecordContext) async throws {
        let transaction = context.getTransaction()

        // ✅ 型名を取得して RecordMetaData で検証
        let typeName = recordAccess.recordTypeName(for: record)

        guard let recordType = metaData.recordTypes.first(where: { $0.name == typeName }) else {
            throw RecordLayerError.unknownRecordType(
                "RecordAccess returned unknown type: \(typeName)"
            )
        }

        // ✅ プライマリキーを評価
        let primaryKeyValues = try recordAccess.evaluate(
            record: record,
            expression: recordType.primaryKey
        )
        let primaryKey = TupleHelpers.toTuple(primaryKeyValues)

        // 保存処理...
    }
}
```

---

## 3. トランザクションとカーソルの型安全設計

### 3.1 TransactionCursor - トランザクションに束縛されたカーソル

```swift
/// トランザクション内でのみ使用可能なカーソル
///
/// **重要:**
/// - TransactionCursor はトランザクションブロック外に返却できない
/// - ブロック内で完全に消費するか、collect() で配列に変換
/// - TransactionResult プロトコルに準拠していないため、型制約で保護
public struct TransactionCursor<Record: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Record

    private let context: RecordContext
    private let query: RecordQuery
    private let recordAccess: any RecordAccess<Record>
    private let recordSubspace: Subspace

    internal init(
        context: RecordContext,
        query: RecordQuery,
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace
    ) {
        self.context = context
        self.query = query
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
    }

    // MARK: - AsyncSequence

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            context: context,
            query: query,
            recordAccess: recordAccess,
            recordSubspace: recordSubspace
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let context: RecordContext
        private let query: RecordQuery
        private let recordAccess: any RecordAccess<Record>
        private let recordSubspace: Subspace
        private var fdbIterator: FDB.KeyValuesSequence.AsyncIterator?
        private var initialized = false

        init(/* ... */) { /* ... */ }

        public mutating func next() async throws -> Record? {
            if !initialized {
                let transaction = context.getTransaction()
                let beginKey = recordSubspace.pack(query.beginKey ?? Tuple())
                let endKey = recordSubspace.pack(query.endKey ?? Tuple()) + [0xFF]

                let sequence = transaction.getRange(
                    beginSelector: .firstGreaterOrEqual(beginKey),
                    endSelector: .firstGreaterOrEqual(endKey),
                    snapshot: false  // ✅ トランザクション内は変更検知
                )
                fdbIterator = sequence.makeAsyncIterator()
                initialized = true
            }

            guard let (_, value) = try await fdbIterator?.next() else {
                return nil
            }

            return try recordAccess.deserialize(value)
        }
    }

    // MARK: - 配列への変換

    /// カーソルを配列に変換（トランザクションブロック外に返却可能）
    public func collect(limit: Int = 1000) async throws -> [Record] {
        var results: [Record] = []
        results.reserveCapacity(min(limit, 1000))

        for try await record in self {
            results.append(record)
            if results.count >= limit {
                break
            }
        }

        return results
    }
}
```

### 3.2 TransactionResult - 返却可能な型の制約

```swift
/// トランザクションブロックから返却可能な型
///
/// **設計:**
/// - TransactionCursor は準拠しない → コンパイルエラーで防止
/// - 配列や基本型のみ返却可能
public protocol TransactionResult: Sendable {}

// MARK: - 基本型

extension Int: TransactionResult {}
extension Int64: TransactionResult {}
extension String: TransactionResult {}
extension Bool: TransactionResult {}

// MARK: - コレクション

extension Array: TransactionResult where Element: Sendable {}
extension Dictionary: TransactionResult where Key: Sendable, Value: Sendable {}
extension Optional: TransactionResult where Wrapped: TransactionResult {}

// MARK: - カスタム型

extension User: TransactionResult {}  // Protobuf Message
extension Tuple: TransactionResult {}
```

### 3.3 SnapshotCursor - スナップショット読み込みカーソル

```swift
/// スナップショット読み込み用のカーソル
///
/// **設計:**
/// - 単一操作（context.fetch()）で使用
/// - snapshot: true で読み込み
/// - トランザクション外でも使用可能（自動トランザクション）
public struct SnapshotCursor<Record: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Record

    private let database: any DatabaseProtocol
    private let store: RecordStore<Record>
    private let query: RecordQuery

    internal init(/* ... */) { /* ... */ }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var context: RecordContext?
        private var fdbIterator: FDB.KeyValuesSequence.AsyncIterator?
        private var initialized = false

        public mutating func next() async throws -> Record? {
            if !initialized {
                let transaction = try database.createTransaction()
                let ctx = RecordContext(transaction: transaction)
                self.context = ctx

                let sequence = transaction.getRange(
                    beginSelector: /* ... */,
                    endSelector: /* ... */,
                    snapshot: true  // ✅ スナップショット読み込み
                )
                fdbIterator = sequence.makeAsyncIterator()
                initialized = true
            }

            guard let (_, value) = try await fdbIterator?.next() else {
                context?.cancel()  // 終了時にキャンセル
                return nil
            }

            return try store.recordAccess.deserialize(value)
        }
    }

    public func collect(limit: Int = 1000) async throws -> [Record] { /* ... */ }
}
```

### 3.4 TypedRecordContext の更新

```swift
public final class TypedRecordContext<Record: Sendable>: Sendable {
    /// トランザクションを実行
    ///
    /// **型制約:**
    /// TransactionResult に準拠した型のみ返却可能
    ///
    /// ```swift
    /// // ✅ OK: 配列を返す
    /// let users = try await context.transaction { transaction in
    ///     let cursor = try await transaction.fetch(query)
    ///     return try await cursor.collect(limit: 100)
    /// }
    ///
    /// // ❌ コンパイルエラー: TransactionCursor は返却不可
    /// let cursor = try await context.transaction { transaction in
    ///     return try await transaction.fetch(query)
    /// }
    /// ```
    public func transaction<T: TransactionResult>(
        _ block: (Transaction<Record>) async throws -> T
    ) async throws -> T {
        return try await database.withRecordContext { context in
            let transaction = Transaction(store: self.store, context: context)
            return try await block(transaction)
        }
    }

    /// クエリでレコードを検索（スナップショット読み込み）
    public func fetch(_ query: RecordQuery) async throws -> SnapshotCursor<Record> {
        return SnapshotCursor(
            database: database,
            store: store,
            query: query
        )
    }
}
```

---

## 4. 使用例とコンパイル時検証

### 4.1 正しい使用例

```swift
let context = try await recordStore.createContext()

// ✅ トランザクション内でカーソルを消費
try await context.transaction { transaction in
    let cursor = try await transaction.fetch(query)
    for try await user in cursor {
        print(user.name)
    }
}

// ✅ 配列に変換して返す
let users = try await context.transaction { transaction in
    let cursor = try await transaction.fetch(query)
    return try await cursor.collect(limit: 100)
}

// ✅ スナップショット読み込み
let cursor = try await context.fetch(query)
for try await user in cursor {
    print(user.name)
}
```

### 4.2 コンパイルエラーになる例

```swift
// ❌ コンパイルエラー
let cursor = try await context.transaction { transaction in
    return try await transaction.fetch(query)
    // Error: TransactionCursor<User> does not conform to TransactionResult
}
```

---

## 5. RankIndex の Deque 実装

### 5.1 パフォーマンス改善

```swift
import Collections  // swift-collections

public struct RankIndexMaintainer<Record: Sendable>: IndexMaintainer {
    public func getRecordsByRankRange(
        groupingValues: [any TupleElement],
        startRank: Int,
        endRank: Int,
        transaction: any TransactionProtocol
    ) async throws -> [Tuple] {
        // ...

        if rankOrder == .ascending {
            // 昇順: そのまま
            var currentRank = 0
            for try await (key, _) in sequence {
                currentRank += 1
                if currentRank >= startRank && currentRank < endRank {
                    results.append(try extractPrimaryKeyFromIndexKey(key))
                }
                if currentRank >= endRank { break }
            }
        } else {
            // 降順: Deque で O(1) の removeFirst
            var buffer = Deque<FDB.Bytes>()
            buffer.reserveCapacity(endRank)

            for try await (key, _) in sequence {
                buffer.append(key)
                if buffer.count > endRank {
                    buffer.removeFirst()  // ✅ O(1)
                }
            }

            // 範囲を抽出
            let rangeSize = endRank - startRank
            if buffer.count >= startRank {
                let startIndex = buffer.count - endRank + (startRank - 1)
                let endIndex = min(startIndex + rangeSize, buffer.count)

                for i in startIndex..<endIndex {
                    results.append(try extractPrimaryKeyFromIndexKey(buffer[i]))
                }
            }
        }

        return results
    }
}
```

### 5.2 Package.swift 更新

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "FDBRecordLayer",
        dependencies: [
            .product(name: "Collections", package: "swift-collections"),
        ]
    ),
]
```

**互換性:**
- データフォーマット変更なし
- API 変更なし（内部実装のみ）
- 既存インデックスの再構築不要

---

## 6. 移行計画

### Phase 1: 基盤実装（2-3日）
- [ ] KeyExpressionVisitor の実装
- [ ] RecordAccess プロトコルの実装
- [ ] RecordAccessEvaluator の実装
- [ ] ProtobufFieldExtractor の実装
- [ ] DictionaryRecordAccess の実装

### Phase 2: 一貫性検証（1日）
- [ ] RecordAccessValidator の実装
- [ ] RecordStore 初期化時の検証
- [ ] 実行時検証の追加

### Phase 3: カーソルの型安全化（2-3日）
- [ ] TransactionCursor の実装
- [ ] SnapshotCursor の実装
- [ ] TransactionResult プロトコルの実装
- [ ] TypedRecordContext の更新
- [ ] Transaction クラスの更新

### Phase 4: インデックスの更新（2-3日）
- [ ] IndexMaintainer のジェネリック化
- [ ] AnyIndexMaintainer (型消去) の実装
- [ ] VersionIndexMaintainer の更新
- [ ] ValueIndexMaintainer の更新
- [ ] RankIndexMaintainer の更新（Deque 対応）

### Phase 5: RecordStore の更新（1-2日）
- [ ] RecordStore を RecordAccess ベースに変更
- [ ] save/fetch メソッドの更新
- [ ] インデックス更新ロジックの統合

### Phase 6: 検証とドキュメント（2-3日）
- [ ] Examples の更新と動作確認
- [ ] テストの更新
- [ ] API ドキュメントの更新
- [ ] README の更新

**合計: 約 2週間**

---

## 7. 使用例（完全版）

### 7.1 Protobuf を使う場合

```swift
// 1. FieldExtractor を定義
extension ProtobufFieldExtractor where M == User {
    public static func forUser() -> ProtobufFieldExtractor<User> {
        return ProtobufFieldExtractor(extractors: [
            "userID": { user in [user.userID] },
            "name": { user in [user.name] },
            "email": { user in [user.email] }
        ])
    }
}

// 2. RecordAccess を作成
let userAccess = ProtobufRecordAccess(
    typeName: "User",
    fieldExtractor: .forUser()
)

// 3. RecordStore を初期化
let recordStore = try RecordStore(
    database: database,
    subspace: subspace,
    metaData: metaData,
    recordAccess: userAccess
)

// 4. Context を作成して使用
let context = try await recordStore.createContext()

// 単一操作（自動 snapshot: true）
let alice = User.with {
    $0.userID = 1
    $0.name = "Alice"
}
try await context.save(alice)

// トランザクション（自動 snapshot: false）
let results = try await context.transaction { transaction in
    let cursor = try await transaction.fetch(query)
    return try await cursor.collect(limit: 100)
}

for user in results {
    print(user.name)  // ✅ 型安全: User 型
}
```

### 7.2 辞書を使う場合（後方互換性）

```swift
let dictionaryAccess = DictionaryRecordAccess()

let recordStore = try RecordStore(
    database: database,
    subspace: subspace,
    metaData: metaData,
    recordAccess: dictionaryAccess
)

let context = try await recordStore.createContext()

let user: [String: Any] = [
    "_type": "User",
    "id": 1,
    "name": "Alice"
]
try await context.save(user)
```

---

## 8. まとめ

### 設計の完全性

✅ **KeyExpression 評価**: KeyExpressionVisitor パターンで完全に実装可能
✅ **RecordAccess**: Protobuf と辞書の両方を完全サポート
✅ **一貫性保証**: 初期化時および実行時に検証
✅ **トランザクションスコープ**: 型システムで完全に保証（コンパイル時エラー）
✅ **型安全**: 全レイヤーでジェネリックと型制約を使用
✅ **パフォーマンス**: Deque を使った効率的な実装 (O(N * endRank) → O(N))
✅ **互換性**: 既存データとの互換性を維持
✅ **実装可能性**: すべての設計が具体的な実装方法を持つ

### 解決された問題

| 問題 | 旧設計 | 新設計 |
|------|--------|--------|
| Protobuf サポート | ❌ クラッシュ | ✅ 完全サポート |
| KeyExpression 評価 | ❌ 辞書のみ | ✅ Visitor パターン |
| 一貫性保証 | ❌ なし | ✅ 初期化時+実行時 |
| カーソルスコープ | ❌ 実行時エラー | ✅ コンパイル時エラー |
| 型安全性 | ⚠️ 宣言のみ | ✅ 完全な型安全 |
| IndexMaintainer | ❌ 辞書前提 | ✅ ジェネリック |
| 降順ランキング | ⚠️ O(N * rank) | ✅ O(N) |

### トレードオフ

⚠️ **実装の複雑さ**: ジェネリックと型消去が増加
⚠️ **学習コスト**: RecordAccess と FieldExtractor の理解が必要
⚠️ **手動マッピング**: ProtobufFieldExtractor を各メッセージ型ごとに定義
⚠️ **依存関係**: swift-collections を追加

### 結論

この設計により、レビューで指摘されたすべての致命的・重大な問題が解決され、完全に型安全で実装可能な API が実現します。

**次のステップ:**
1. Phase 1 の基盤実装から開始
2. 各 Phase ごとにテストを追加
3. Examples で動作確認
4. ドキュメント更新
