# InExtractor 設計ドキュメント

**作成日**: 2025-01-12
**ステータス**: 設計完了、統合作業が必要

---

## 📋 概要

InExtractorは、IN述語を含むクエリを最適化するためのクエリリライターです。

### 実装済みファイル

1. **`QueryComponentVisitor.swift`** ✅
   - Visitor pattern documentation
   - 簡易Visitor patternとして実装
   - TypedQueryComponent直接使用

2. **`InExtractor.swift`** ✅
   - IN述語抽出ロジック実装
   - InPredicate metadata定義
   - TypedInQueryComponent検出
   - コンパイル: ✅ 成功

---

## 🎯 設計概要

### 1. Visitor Pattern

```swift
public protocol QueryComponentVisitor {
    mutating func visit(_ component: any QueryComponent) throws
}

public protocol QueryComponent: Sendable {
    func accept(visitor: inout any QueryComponentVisitor) throws
}

public protocol AnalyzableQuery {
    func accept(visitor: inout any QueryComponentVisitor) throws
}
```

**用途**:
- クエリツリーのトラバース
- IN述語の抽出
- クエリリライト

---

### 2. InExtractor

```swift
public struct InExtractor: QueryComponentVisitor {
    private var inPredicates: [InPredicate] = []

    public mutating func visit(_ component: any QueryComponent) throws {
        // IN述語を検出
    }

    public func extractedInPredicates() -> [InPredicate] {
        return inPredicates
    }

    public var hasInPredicates: Bool {
        return !inPredicates.isEmpty
    }
}
```

**実装状況**:
- ✅ Visitor pattern実装（簡易版）
- ✅ IN述語抽出ロジック
- ✅ TypedInQueryComponentとの統合
- ✅ 再帰的なAND/OR/NOTコンポーネント探索

---

### 3. InPredicate

```swift
public struct InPredicate: Sendable {
    public let fieldName: String
    public let values: [any TupleElement]

    public var valueCount: Int {
        return values.count
    }
}
```

**用途**:
- 抽出されたIN述語のメタデータ
- Query Planner が InJoinPlan生成に使用

---

## ✅ 完了した統合作業（2025-01-12）

### 1. TypedQueryComponent統合

**解決内容**:
既存の`TypedInQueryComponent`を発見し、それを直接使用：

```swift
public mutating func visit<Record: Sendable>(_ component: any TypedQueryComponent<Record>) throws {
    // Check if component is a TypedInQueryComponent
    if let inComponent = component as? TypedInQueryComponent<Record> {
        let inPredicate = InPredicate(
            fieldName: inComponent.fieldName,
            values: inComponent.values
        )
        inPredicates.append(inPredicate)
    }

    // Recursively visit AND/OR components
    // ...
}
```

**変更ファイル**:
- `InExtractor.swift`: line 41-63

---

### 2. Visitor Pattern簡素化

**解決内容**:
複雑な二重ディスパッチパターンではなく、直接TypedQueryComponentを操作：

```swift
// QueryComponentVisitor protocolは不要
// InExtractorが直接TypedQueryComponentを受け取る
public struct InExtractor {
    public mutating func visit<Record: Sendable>(_ component: any TypedQueryComponent<Record>) throws
}
```

**変更ファイル**:
- `QueryComponentVisitor.swift`: documentation onlyに簡素化
- `InExtractor.swift`: protocol conformance削除

---

## 🚧 今後の統合作業

### Query Planner自動最適化（将来実装）

**課題**: TypedRecordQueryPlannerとの統合

**要件**:
1. TypedRecordQueryから`filter`を抽出
2. InExtractorで IN述語を検出
3. 適切なインデックスが存在する場合、TypedInJoinPlanを自動生成

**優先度**: 中（手動でTypedInJoinPlanを使用可能、自動最適化は便利機能）

**推定工数**: 1-2日

---

## 💡 実装の課題

### 1. Closure-based Filter

現在の`TypedRecordQuery`はclosure-basedのfilterを使用している可能性が高い：

```swift
// 現在の実装（推定）
let query = QueryBuilder<User>()
    .where { user in user.age >= 18 }  // Closure
    .build()
```

**課題**:
- Closureは実行時にしか評価できない
- Query Plannerが構造を解析できない
- IN述語を抽出できない

**解決策案**:

#### Option 1: Filter AST導入（推奨）

```swift
// Filter Expression AST
public protocol FilterExpression: Sendable {
    func accept(visitor: inout any FilterVisitor) throws
}

public struct FieldFilter: FilterExpression {
    let fieldName: String
    let comparator: ComparisonOperator
    let value: any TupleElement
}

public struct InFilter: FilterExpression {
    let fieldName: String
    let values: [any TupleElement]
}

public struct AndFilter: FilterExpression {
    let left: any FilterExpression
    let right: any FilterExpression
}

// QueryBuilderで使用
let query = QueryBuilder<User>()
    .where(\.age, .greaterThanOrEquals, 18)  // FilterExpression生成
    .where(\.city, .in, ["Tokyo", "Osaka"])  // InFilter生成
    .build()
```

**利点**:
- Query Plannerが構造を解析可能
- IN述語を簡単に抽出
- クエリリライトが可能

**実装コスト**: 3-5日

---

#### Option 2: QueryBuilder拡張（暫定）

```swift
// QueryBuilderにメタデータ追加
extension QueryBuilder {
    private var filterMetadata: [FilterMetadata] = []

    public func where<T>(...) -> Self {
        // フィルタ追加時にメタデータも記録
        var builder = self
        builder.filterMetadata.append(FilterMetadata(...))
        return builder
    }
}

struct FilterMetadata: Sendable {
    let fieldName: String
    let operation: FilterOperation
    let values: [any TupleElement]
}

enum FilterOperation: Sendable {
    case equals
    case greaterThan
    case in
    // ...
}
```

**利点**:
- 既存APIを変更せずに実装可能
- IN述語抽出が可能

**欠点**:
- メタデータとclosureの二重管理
- 複雑なクエリに対応しにくい

**実装コスト**: 1-2日

---

### 2. IN Predicate → InJoinPlan 変換

**目標**:
```swift
// Before: IN述語をpost-filterで処理
WHERE city IN ("Tokyo", "Osaka", "Kyoto")
→ IndexScan(city_index) + post-filter

// After: InJoinPlanで並行実行
→ InJoinPlan {
    IndexScan(city="Tokyo"),
    IndexScan(city="Osaka"),
    IndexScan(city="Kyoto")
}
```

**実装**:
```swift
func generateInJoinPlan(
    for inPredicate: InPredicate,
    index: Index
) throws -> TypedInJoinPlan<Record> {
    // 既存のTypedInJoinPlanを使用
    return TypedInJoinPlan(
        recordAccess: recordAccess,
        recordSubspace: recordSubspace,
        indexSubspace: indexSubspace,
        index: index,
        fieldName: inPredicate.fieldName,
        values: inPredicate.values,
        additionalFilters: []  // 他のfilterを保持
    )
}
```

---

## 🧪 テスト計画

### Unit Tests

```swift
@Test("InExtractor detects IN predicates")
func testInExtractorDetection() async throws {
    // Create query with IN predicate
    let query = QueryBuilder<User>()
        .where(\.city, .in, ["Tokyo", "Osaka"])
        .build()

    // Extract IN predicates
    var extractor = InExtractor()
    try query.accept(visitor: &extractor)

    let predicates = extractor.extractedInPredicates()
    #expect(predicates.count == 1)
    #expect(predicates[0].fieldName == "city")
    #expect(predicates[0].valueCount == 2)
}

@Test("InExtractor ignores non-IN predicates")
func testInExtractorIgnoresOthers() async throws {
    // Create query without IN
    let query = QueryBuilder<User>()
        .where(\.age, .greaterThanOrEquals, 18)
        .build()

    // Extract IN predicates
    var extractor = InExtractor()
    try query.accept(visitor: &extractor)

    #expect(extractor.hasInPredicates == false)
}

@Test("Query Planner uses InJoinPlan for IN queries")
func testQueryPlannerInOptimization() async throws {
    // Save test data
    try await store.save(User(city: "Tokyo"))
    try await store.save(User(city: "Osaka"))
    try await store.save(User(city: "Nagoya"))

    // Query with IN predicate
    let query = QueryBuilder<User>()
        .where(\.city, .in, ["Tokyo", "Osaka"])
        .build()

    // Get execution plan
    let planner = TypedRecordQueryPlanner(...)
    let plan = try await planner.plan(query)

    // Verify InJoinPlan is used
    #expect(plan is TypedInJoinPlan<User>)

    // Execute and verify results
    let cursor = try await plan.execute(database: database, transaction: nil)
    var results: [User] = []
    for try await user in cursor {
        results.append(user)
    }

    #expect(results.count == 2)
}
```

---

## 📈 パフォーマンス期待値

### Before (Post-filtering)
```
city IN ("Tokyo", "Osaka", "Kyoto"):
1. 全インデックススキャン: O(n)
2. Post-filter: O(n)
→ Total: O(n)
```

### After (InJoinPlan)
```
city IN ("Tokyo", "Osaka", "Kyoto"):
1. 3つのインデックススキャン並行実行: O(k₁ + k₂ + k₃)
   where kᵢ = 各都市のレコード数
→ Total: O(k₁ + k₂ + k₃) << O(n)
```

### 改善率

| 条件 | Before | After | 改善率 |
|------|--------|-------|--------|
| 3都市, 10,000レコード | ~100ms | ~2ms | **50x** |
| 5都市, 100,000レコード | ~1,000ms | ~10ms | **100x** |
| 10都市, 1,000,000レコード | ~10,000ms | ~50ms | **200x** |

---

## 🚀 実装ロードマップ

### Phase 1: Filter AST導入（推奨、3-5日）

- [ ] FilterExpression protocol定義
- [ ] FieldFilter, InFilter, AndFilter, OrFilter実装
- [ ] QueryBuilder AST生成
- [ ] TypedRecordQuery AST統合

### Phase 2: InExtractor完成（1日）

- [ ] Filter AST visitor実装
- [ ] IN述語抽出ロジック完成
- [ ] テスト作成

### Phase 3: Query Planner統合（1-2日）

- [ ] optimizeWithInExtraction()完成
- [ ] InJoinPlan自動生成
- [ ] Cost-based判定

### Phase 4: パフォーマンステスト（0.5日）

- [ ] ベンチマーク作成
- [ ] 改善率測定
- [ ] ドキュメント更新

---

### 代替: 暫定実装（Option 2、1-2日）

- [ ] QueryBuilder metadata追加
- [ ] IN述語メタデータ記録
- [ ] InExtractor統合
- [ ] Query Planner統合（簡易版）

---

## ✅ 完了した作業（2025-01-12更新）

### Phase 1: InExtractor基本実装 ✅ 完了

1. ✅ InExtractor構造体実装
2. ✅ InPredicate metadata定義
3. ✅ TypedInQueryComponent検出ロジック
4. ✅ 再帰的なAND/OR/NOTコンポーネント探索
5. ✅ QueryComponentVisitor documentation
6. ✅ コンパイル成功確認

### Phase 2: Query Planner自動最適化 🚧 将来課題

1. ❌ TypedRecordQueryPlannerとの統合
2. ❌ 自動InJoinPlan生成
3. ❌ Cost-based判定

---

## 📝 次のステップ

### 完了した作業（2025-01-12）

- ✅ InExtractor基本実装とコンパイル成功
- ✅ TypedInQueryComponentとの統合
- ✅ 再帰的なコンポーネント探索

### 今後の作業

1. **テスト作成（優先度: 高）**: InExtractorのユニットテスト（0.5日）
2. **Query Planner統合（優先度: 中）**: 自動InJoinPlan生成（1-2日）
3. **ドキュメント更新（優先度: 低）**: 使用例の追加（0.5日）

**Note**:
- InExtractor基本機能は完成
- TypedInJoinPlanは既に存在し、手動で使用可能
- 自動最適化は便利機能として将来実装

---

## 🎯 推奨アプローチ

### Option A: Filter AST導入（推奨）

**理由**:
- クエリ最適化の基盤として必要
- IN述語以外の最適化にも使える
- 長期的なメンテナンス性が高い

**コスト**: 3-5日
**利点**: 完全な機能、将来の拡張性
**欠点**: 実装時間がかかる

---

### Option B: 暫定実装（短期）

**理由**:
- 既存APIを変更せずに実装
- IN述語最適化を早期に提供

**コスト**: 1-2日
**利点**: 早期リリース可能
**欠点**: 将来的にFilter AST移行が必要

---

**推奨**: **Option A (Filter AST導入)** を推奨します。
- クエリ最適化の基盤として重要
- 3-5日の投資で長期的な利益
- Java版Record Layerも同様のアーキテクチャ

---

**Last Updated**: 2025-01-12
**Status**: 基本実装完了、コンパイル成功、Query Planner統合は将来課題
**Reviewer**: Claude Code

---

## 📊 実装結果サマリー

### 完成した機能

- ✅ TypedInQueryComponent検出
- ✅ 再帰的なフィルタ探索（AND/OR/NOT）
- ✅ InPredicate抽出
- ✅ 型安全なVisitorパターン

### 発見された事実

1. **TypedInQueryComponent既存**: IN述語は既にTypedInQueryComponentとして実装済み
2. **Filter AST不要**: 現在のTypedQueryComponent階層で十分
3. **手動最適化可能**: TypedInJoinPlanは既に存在し、直接使用可能

### アーキテクチャ判断

**当初の想定**: Filter ASTが必要
**実際の状況**: TypedQueryComponentが既にAST構造を提供

**結論**:
- Filter AST導入は不要
- 既存のTypedQueryComponent階層を活用
- InExtractorは既存構造で十分動作
