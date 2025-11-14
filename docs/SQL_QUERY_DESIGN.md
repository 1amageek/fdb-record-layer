# SQL-Like Query System Design

## 概要

FDB Record LayerにおけるSQLライクなクエリシステムの設計ドキュメント。Directoryベースのマルチテナント環境で、型安全かつ柔軟なクエリAPIを提供します。

**目標**:
- ✅ 型安全性：コンパイル時の型チェック
- ✅ 表現力：SQL風の直感的な構文
- ✅ パフォーマンス：インデックスを活用した最適化
- ✅ マルチテナント対応：Directoryベースの分離

---

## 現在の実装状況

### ✅ 実装済み

```swift
// 現在の QueryBuilder API
let users = try await store.query()
    .where(\.email, is: .equals, "alice@example.com")
    .where(\.age, is: .greaterThan, 18)
    .limit(10)
    .execute()
```

**制限事項**:
- メソッドチェーンのみ（演算子オーバーロード未対応）
- 集約関数が非効率（count()は全取得）
- JOIN、GROUP BY、サブクエリ未対応

---

## 設計アプローチ

### アプローチ1: Result Builder DSL（推奨）

SwiftのResult Builderを使用して、宣言的なクエリDSLを提供します。

```swift
let users = try await store.query {
    Where(\.email == "alice@example.com")
    Where(\.age > 18)
    OrderBy(\.createdAt, .descending)
    Limit(10)
}
```

**利点**:
- ✅ 宣言的で読みやすい
- ✅ SwiftUIやSwiftDataと統一感のある構文
- ✅ 複雑なクエリを構造化しやすい

### アプローチ2: 演算子オーバーロード拡張

現在のQueryBuilderに演算子オーバーロードを追加します。

```swift
let users = try await store.query()
    .where(\.email == "alice@example.com" && \.age > 18)
    .orderBy(\.createdAt, descending: true)
    .limit(10)
    .execute()
```

**課題**:
- ⚠️ KeyPathで演算子オーバーロードは直接的には不可能
- ⚠️ マクロや型エイリアスを使った回避策が必要

### アプローチ3: ハイブリッド（最終案）

Result BuilderとQueryBuilderを組み合わせた柔軟なAPI。

```swift
// パターン1: シンプルなクエリ（既存API互換）
let users = try await store.query()
    .where(\.email, is: .equals, "alice@example.com")
    .limit(10)
    .execute()

// パターン2: 複雑なクエリ（Result Builder）
let users = try await store.query {
    Where(\.email == "alice@example.com")
    Where(\.age > 18 && \.city == "Tokyo")
    OrderBy(\.createdAt, .descending)
    Limit(10)
}

// パターン3: 集約クエリ
let count = try await store.aggregate {
    Where(\.city == "Tokyo")
    Count()
}

let avgAge = try await store.aggregate {
    Where(\.status == "active")
    Average(\.age)
}
```

---

## Phase 1: 基本クエリの完成

### 1.1 演算子オーバーロード対応

**目標**: `.where(\.field == value)` 構文の実装

#### 設計案: Predicate型の導入

```swift
/// クエリ述語（演算子オーバーロード用）
public struct Predicate<Record: Recordable>: Sendable {
    internal let component: any TypedQueryComponent<Record>

    internal init(_ component: any TypedQueryComponent<Record>) {
        self.component = component
    }
}

// KeyPathのラッパー型
public struct QueryableKeyPath<Record: Recordable, Value: TupleElement>: Sendable {
    public let keyPath: KeyPath<Record, Value>

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.keyPath = keyPath
    }
}

// 演算子オーバーロード
extension QueryableKeyPath where Value: Equatable {
    public static func == (lhs: Self, rhs: Value) -> Predicate<Record> {
        let fieldName = Record.fieldName(for: lhs.keyPath)
        let component = TypedFieldQueryComponent<Record>(
            fieldName: fieldName,
            comparison: .equals,
            value: rhs
        )
        return Predicate(component)
    }
}

extension QueryableKeyPath where Value: Comparable {
    public static func > (lhs: Self, rhs: Value) -> Predicate<Record> {
        let fieldName = Record.fieldName(for: lhs.keyPath)
        let component = TypedFieldQueryComponent<Record>(
            fieldName: fieldName,
            comparison: .greaterThan,
            value: rhs
        )
        return Predicate(component)
    }

    // < , >=, <= も同様
}

// 論理演算子
extension Predicate {
    public static func && (lhs: Self, rhs: Self) -> Self {
        Predicate(TypedAndQueryComponent<Record>(children: [lhs.component, rhs.component]))
    }

    public static func || (lhs: Self, rhs: Self) -> Self {
        Predicate(TypedOrQueryComponent<Record>(children: [lhs.component, rhs.component]))
    }

    public static prefix func ! (predicate: Self) -> Self {
        Predicate(TypedNotQueryComponent<Record>(child: predicate.component))
    }
}
```

#### QueryBuilderへの統合

```swift
extension QueryBuilder {
    /// Predicate を使った where 句
    public func `where`(_ predicate: Predicate<T>) -> Self {
        filters.append(predicate.component)
        return self
    }

    /// QueryableKeyPath を取得するヘルパー
    public static func keyPath<Value: TupleElement>(
        _ keyPath: KeyPath<T, Value>
    ) -> QueryableKeyPath<T, Value> {
        QueryableKeyPath(keyPath)
    }
}
```

#### 使用例

```swift
// 基本的な比較
let users = try await store.query()
    .where(\.email == "alice@example.com")
    .execute()

// 複数条件（AND）
let users = try await store.query()
    .where(\.age > 18 && \.city == "Tokyo")
    .execute()

// 複雑な条件（OR、NOT）
let users = try await store.query()
    .where((\.status == "active" || \.status == "pending") && !(\.age < 18))
    .limit(100)
    .execute()
```

**実装ファイル**:
- `Sources/FDBRecordLayer/Query/Predicate.swift` (新規)
- `Sources/FDBRecordLayer/Query/QueryBuilder.swift` (拡張)

---

### 1.2 集約関数の最適化

**目標**: COUNTインデックスを使用した効率的なcount()

#### 現在の実装（非効率）

```swift
// ❌ 全レコード取得してカウント
public func count() async throws -> Int {
    let results = try await execute()
    return results.count
}
```

#### 最適化後の実装

```swift
public func count() async throws -> Int {
    // Step 1: COUNT インデックスが利用可能かチェック
    let planner = TypedRecordQueryPlanner<T>(
        schema: schema,
        recordName: T.recordName,
        statisticsManager: statisticsManager
    )

    // Step 2: フィルタからグループキーを抽出
    let groupKeys = extractGroupKeys(from: filters)

    // Step 3: COUNT インデックスがあれば使用
    if let countIndex = findCountIndex(for: groupKeys) {
        return try await fetchCountFromIndex(index: countIndex, groupKeys: groupKeys)
    }

    // Step 4: インデックスがなければフォールバック（全取得）
    let results = try await execute()
    return results.count
}

private func findCountIndex(for groupKeys: [String]) -> Index? {
    // メタデータから適切な COUNT インデックスを探す
    let indexes = schema.indexes(for: T.recordName)
    return indexes.first { index in
        index.type == .count && index.fields == groupKeys
    }
}

private func fetchCountFromIndex(
    index: Index,
    groupKeys: [String: Any]
) async throws -> Int {
    // COUNT インデックスから直接カウントを取得
    let countSubspace = subspace
        .subspace(Tuple([T.recordName]))
        .subspace(Tuple(["indexes"]))
        .subspace(Tuple([index.name]))

    let keyTuple = Tuple(groupKeys.values.sorted { $0.key < $1.key }.map { $0.value })
    let key = countSubspace.pack(keyTuple)

    let transaction = try database.createTransaction()
    let context = RecordContext(transaction: transaction)
    defer { context.cancel() }

    guard let value = try await context.read(key) else {
        return 0
    }

    // カウント値をデコード（Int64として保存）
    let tuple = try Tuple(from: value)
    return Int(tuple[0] as? Int64 ?? 0)
}
```

#### 使用例

```swift
// ✅ COUNT インデックスを使用（O(1)）
#Index<User>([\.city])
#Count<User>([\.city])

let tokyoCount = try await store.query()
    .where(\.city, is: .equals, "Tokyo")
    .count()  // COUNT インデックスから直接取得
```

**実装ファイル**:
- `Sources/FDBRecordLayer/Query/QueryBuilder.swift` (count()メソッド改善)
- `Sources/FDBRecordLayer/Query/AggregateFunction.swift` (補助関数)

---

### 1.3 ORDER BY と降順ソート

**目標**: `orderBy()` メソッドと降順インデックスのサポート

#### API設計

```swift
extension QueryBuilder {
    /// ソート順を指定
    public func orderBy<Value: TupleElement & Comparable>(
        _ keyPath: KeyPath<T, Value>,
        _ direction: SortDirection = .ascending
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        sortOrders.append(SortOrder(field: fieldName, direction: direction))
        return self
    }
}

public enum SortDirection: Sendable {
    case ascending
    case descending
}

private struct SortOrder: Sendable {
    let field: String
    let direction: SortDirection
}
```

#### TypedRecordQueryPlannerの拡張

```swift
// TypedRecordQueryPlanner.swift に追加
private func selectIndexForSort(
    sortOrders: [SortOrder],
    availableIndexes: [Index]
) -> Index? {
    for index in availableIndexes {
        // インデックスフィールドがソート順と一致するかチェック
        if index.fields.count >= sortOrders.count {
            let matches = zip(index.fields, sortOrders).allSatisfy { field, sort in
                field == sort.field
            }

            if matches {
                // 降順インデックスのチェック
                if sortOrders.first?.direction == .descending {
                    // TODO: 降順インデックスのメタデータを確認
                    // 現在は ascending のみサポート
                    continue
                }
                return index
            }
        }
    }
    return nil
}
```

#### 使用例

```swift
// 昇順ソート（インデックス使用）
#Index<User>([\.createdAt])

let users = try await store.query()
    .orderBy(\.createdAt, .ascending)
    .execute()

// 降順ソート（将来対応）
#Index<User>([\.createdAt], direction: .descending)

let users = try await store.query()
    .orderBy(\.createdAt, .descending)
    .execute()
```

**実装ファイル**:
- `Sources/FDBRecordLayer/Query/QueryBuilder.swift` (orderByメソッド)
- `Sources/FDBRecordLayer/Query/TypedRecordQueryPlanner.swift` (降順対応)

---

## Phase 2: Result Builder DSL

### 2.1 QueryDSL Result Builder

**目標**: 宣言的なクエリ構文の提供

#### Result Builder定義

```swift
@resultBuilder
public struct QueryDSL<Record: Recordable> {
    public static func buildBlock(_ components: QueryDSLComponent<Record>...) -> [QueryDSLComponent<Record>] {
        components
    }

    public static func buildOptional(_ component: [QueryDSLComponent<Record>]?) -> [QueryDSLComponent<Record>] {
        component ?? []
    }

    public static func buildEither(first component: [QueryDSLComponent<Record>]) -> [QueryDSLComponent<Record>] {
        component
    }

    public static func buildEither(second component: [QueryDSLComponent<Record>]) -> [QueryDSLComponent<Record>] {
        component
    }
}

/// クエリDSLコンポーネントのプロトコル
public protocol QueryDSLComponent<Record>: Sendable {
    associatedtype Record: Recordable
    func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record>
}
```

#### DSLコンポーネント

```swift
// WHERE句
public struct Where<Record: Recordable>: QueryDSLComponent {
    private let predicate: Predicate<Record>

    public init(_ predicate: Predicate<Record>) {
        self.predicate = predicate
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.where(predicate)
    }
}

// ORDER BY句
public struct OrderBy<Record: Recordable>: QueryDSLComponent {
    private let field: PartialKeyPath<Record>
    private let direction: SortDirection

    public init<Value: TupleElement & Comparable>(
        _ keyPath: KeyPath<Record, Value>,
        _ direction: SortDirection = .ascending
    ) {
        self.field = keyPath
        self.direction = direction
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.orderBy(field, direction)
    }
}

// LIMIT句
public struct Limit<Record: Recordable>: QueryDSLComponent {
    private let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.limit(value)
    }
}

// OFFSET句（将来実装）
public struct Offset<Record: Recordable>: QueryDSLComponent {
    private let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.offset(value)
    }
}
```

#### RecordStoreへの統合

```swift
extension RecordStore {
    /// Result BuilderベースのクエリAPI
    public func query<T: Recordable>(
        _ type: T.Type = T.self,
        @QueryDSL<T> _ build: () -> [QueryDSLComponent<T>]
    ) async throws -> [T] {
        // QueryBuilderを作成
        var builder = self.query(T.self)

        // DSLコンポーネントを適用
        for component in build() {
            builder = component.apply(to: builder)
        }

        return try await builder.execute()
    }
}
```

#### 使用例

```swift
// シンプルなクエリ
let users = try await store.query(User.self) {
    Where(\.email == "alice@example.com")
    Limit(1)
}

// 複数条件
let activeTokyoUsers = try await store.query(User.self) {
    Where(\.city == "Tokyo")
    Where(\.status == "active")
    Where(\.age > 18)
    OrderBy(\.createdAt, .descending)
    Limit(100)
}

// 条件分岐
let users = try await store.query(User.self) {
    if includeInactive {
        Where(\.status == "inactive")
    } else {
        Where(\.status == "active")
    }
    Limit(50)
}
```

**実装ファイル**:
- `Sources/FDBRecordLayer/Query/QueryDSL.swift` (新規)
- `Sources/FDBRecordLayer/Store/RecordStore.swift` (拡張)

---

## Phase 3: 集約クエリとグループ化

### 3.1 Aggregate API

**目標**: SQL風の集約関数を提供

#### AggregateBuilder

```swift
@resultBuilder
public struct AggregateDSL<Record: Recordable> {
    public static func buildBlock(_ components: AggregateDSLComponent<Record>...) -> [AggregateDSLComponent<Record>] {
        components
    }
}

public protocol AggregateDSLComponent<Record>: Sendable {
    associatedtype Record: Recordable
    associatedtype Result

    func execute(
        on store: RecordStore<Record>,
        filters: [any TypedQueryComponent<Record>]
    ) async throws -> Result
}

// COUNT集約
public struct Count<Record: Recordable>: AggregateDSLComponent {
    public typealias Result = Int

    public init() {}

    public func execute(
        on store: RecordStore<Record>,
        filters: [any TypedQueryComponent<Record>]
    ) async throws -> Int {
        var builder = store.query()
        for filter in filters {
            builder = builder.where(Predicate(filter))
        }
        return try await builder.count()
    }
}

// SUM集約
public struct Sum<Record: Recordable, Value: TupleElement & Numeric>: AggregateDSLComponent {
    public typealias Result = Value

    private let keyPath: KeyPath<Record, Value>

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.keyPath = keyPath
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [any TypedQueryComponent<Record>]
    ) async throws -> Value {
        // SUM インデックスを使用、なければフォールバック
        let fieldName = Record.fieldName(for: keyPath)

        if let sumIndex = findSumIndex(for: fieldName) {
            return try await fetchSumFromIndex(index: sumIndex, filters: filters)
        }

        // フォールバック：全取得して計算
        let records = try await store.query().execute()
        return records.map { $0[keyPath: keyPath] }.reduce(0, +)
    }
}

// AVG集約
public struct Average<Record: Recordable, Value: TupleElement & FloatingPoint>: AggregateDSLComponent {
    public typealias Result = Value

    private let keyPath: KeyPath<Record, Value>

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.keyPath = keyPath
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [any TypedQueryComponent<Record>]
    ) async throws -> Value {
        let records = try await store.query().execute()
        guard !records.isEmpty else { return 0 }

        let sum = records.map { $0[keyPath: keyPath] }.reduce(0, +)
        return sum / Value(records.count)
    }
}

// MAX集約
public struct Max<Record: Recordable, Value: TupleElement & Comparable>: AggregateDSLComponent {
    public typealias Result = Value?

    private let keyPath: KeyPath<Record, Value>

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.keyPath = keyPath
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [any TypedQueryComponent<Record>]
    ) async throws -> Value? {
        let records = try await store.query().execute()
        return records.map { $0[keyPath: keyPath] }.max()
    }
}

// MIN集約
public struct Min<Record: Recordable, Value: TupleElement & Comparable>: AggregateDSLComponent {
    public typealias Result = Value?

    private let keyPath: KeyPath<Record, Value>

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.keyPath = keyPath
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [any TypedQueryComponent<Record>]
    ) async throws -> Value? {
        let records = try await store.query().execute()
        return records.map { $0[keyPath: keyPath] }.min()
    }
}
```

#### RecordStoreへの統合

```swift
extension RecordStore {
    /// 集約クエリAPI
    public func aggregate<T: Recordable, Component: AggregateDSLComponent>(
        _ type: T.Type = T.self,
        @AggregateDSL<T> _ build: () -> [Component]
    ) async throws -> Component.Result where Component.Record == T {
        let components = build()
        guard let component = components.first else {
            throw RecordLayerError.invalidQuery(reason: "No aggregate component provided")
        }

        // フィルタを抽出（Whereコンポーネントから）
        let filters: [any TypedQueryComponent<T>] = []  // TODO: 実装

        return try await component.execute(on: self, filters: filters)
    }
}
```

#### 使用例

```swift
// COUNT
let count = try await store.aggregate(User.self) {
    Where(\.city == "Tokyo")
    Count()
}

// SUM
#Sum<Order>([\.total])

let totalRevenue = try await store.aggregate(Order.self) {
    Where(\.status == "completed")
    Sum(\.total)
}

// AVG
let avgAge = try await store.aggregate(User.self) {
    Where(\.status == "active")
    Average(\.age)
}

// MAX, MIN
let oldestUser = try await store.aggregate(User.self) {
    Max(\.age)
}

let youngestUser = try await store.aggregate(User.self) {
    Min(\.age)
}
```

**実装ファイル**:
- `Sources/FDBRecordLayer/Query/AggregateDSL.swift` (新規)
- `Sources/FDBRecordLayer/Query/AggregateFunction.swift` (拡張)

---

### 3.2 GROUP BY サポート（将来実装）

**目標**: グループ化された集約クエリ

#### API設計案

```swift
// GROUP BY DSLコンポーネント
public struct GroupBy<Record: Recordable>: QueryDSLComponent {
    private let fields: [PartialKeyPath<Record>]

    public init(_ fields: PartialKeyPath<Record>...) {
        self.fields = fields
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.groupBy(fields)
    }
}

// グループ化された結果
public struct GroupedResult<Record: Recordable, Value> {
    public let groupKey: [String: Any]
    public let value: Value
}
```

#### 使用例（将来）

```swift
// 都市ごとのユーザー数
let results = try await store.aggregateGrouped(User.self) {
    GroupBy(\.city)
    Count()
}

for result in results {
    print("\(result.groupKey["city"]): \(result.value) users")
}

// ステータスごとの注文合計
let results = try await store.aggregateGrouped(Order.self) {
    GroupBy(\.status)
    Sum(\.total)
}
```

---

## Phase 4: JOIN とリレーションシップ（将来実装）

### 4.1 @Relationship ベースのJOIN

**目標**: リレーションシップを使った型安全なJOIN

#### 設計案

```swift
// リレーションシップ定義
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String

    @Relationship(\.userID, on: Order.self, references: \.userID)
    var orders: [Order]
}

@Recordable
struct Order {
    #PrimaryKey<Order>([\.orderID])

    var orderID: Int64
    var userID: Int64  // 外部キー
    var total: Double
}

// JOIN API（案）
let results = try await store.join(User.self, Order.self) {
    On(\.userID, equals: \.userID)
    Where(User.self, \.city == "Tokyo")
    Where(Order.self, \.status == "completed")
}

// 結果は (User, Order) のタプル配列
for (user, order) in results {
    print("\(user.name) ordered $\(order.total)")
}
```

**注意**: JOINは分散データベースでは高コストなため、慎重に設計する必要があります。

---

## マルチテナント対応

### Directoryベースのクエリ分離

```swift
// パーティション設定
@Recordable
struct Order {
    #Directory<Order>("tenants", Field(\.accountID), "orders", layer: .partition)

    #PrimaryKey<Order>([\.orderID])

    var orderID: Int64
    var accountID: String  // パーティションキー
    var total: Double
}

// テナントごとのクエリ
let orderStore = try await Order.store(
    accountID: "tenant-123",  // パーティションキー
    database: database,
    schema: schema
)

// このクエリは自動的に tenant-123 に分離される
let orders = try await orderStore.query {
    Where(\.status == "completed")
    OrderBy(\.createdAt, .descending)
    Limit(100)
}
```

### マルチテナント統計情報

```swift
// テナントごとの統計情報を管理
let statisticsManager = StatisticsManager(
    database: database,
    subspace: orderStore.subspace,  // テナント分離されたSubspace
    schema: schema
)

// クエリプランナーはテナント固有の統計を使用
let planner = TypedRecordQueryPlanner<Order>(
    schema: schema,
    recordName: Order.recordName,
    statisticsManager: statisticsManager
)
```

---

## 実装ロードマップ

### Phase 1: 基本クエリの完成（優先度: HIGH）

| タスク | 工数 | 状態 |
|--------|------|------|
| Predicate型と演算子オーバーロード | 2日 | ⏳ 未着手 |
| count()の最適化（COUNTインデックス） | 1日 | ⏳ 未着手 |
| orderBy()と降順ソート対応 | 2日 | ⏳ 未着手 |
| テストとドキュメント | 1日 | ⏳ 未着手 |

**合計**: 約6日

### Phase 2: Result Builder DSL（優先度: MEDIUM）

| タスク | 工数 | 状態 |
|--------|------|------|
| QueryDSL Result Builder実装 | 2日 | ⏳ 未着手 |
| DSLコンポーネント（Where, OrderBy, Limit） | 2日 | ⏳ 未着手 |
| RecordStore統合とテスト | 1日 | ⏳ 未着手 |

**合計**: 約5日

### Phase 3: 集約クエリ（優先度: MEDIUM）

| タスク | 工数 | 状態 |
|--------|------|------|
| AggregateDSL Result Builder実装 | 1日 | ⏳ 未着手 |
| SUM, AVG, MAX, MIN集約関数 | 2日 | ⏳ 未着手 |
| SUMインデックス統合 | 1日 | ⏳ 未着手 |
| テストとドキュメント | 1日 | ⏳ 未着手 |

**合計**: 約5日

### Phase 4: 高度な機能（優先度: LOW）

| タスク | 工数 | 状態 |
|--------|------|------|
| GROUP BY サポート | 3日 | ⏳ 将来検討 |
| JOIN サポート（@Relationship統合） | 5日 | ⏳ 将来検討 |
| サブクエリサポート | 3日 | ⏳ 将来検討 |

**合計**: 約11日（将来実装）

---

## まとめ

### 短期目標（Phase 1）

最も重要な基本機能を完成させ、実用的なクエリAPIを提供します：
- ✅ 演算子オーバーロード（`.where(\.field == value)`）
- ✅ 効率的なcount()（COUNTインデックス使用）
- ✅ ORDER BY と降順ソート

### 中期目標（Phase 2-3）

より表現力の高いクエリAPIを提供します：
- ✅ Result Builder DSL（宣言的なクエリ構文）
- ✅ 集約関数（SUM, AVG, MAX, MIN）

### 長期目標（Phase 4）

高度なクエリ機能を提供します（将来検討）：
- ⏳ GROUP BY
- ⏳ JOIN（@Relationship統合）
- ⏳ サブクエリ

### マルチテナント対応

すべてのフェーズでDirectoryベースのマルチテナント分離を保証します：
- ✅ パーティションキーによる自動分離
- ✅ テナントごとの統計情報管理
- ✅ 透過的なクエリ実行（テナント意識不要）

---

**Last Updated**: 2025-01-09
