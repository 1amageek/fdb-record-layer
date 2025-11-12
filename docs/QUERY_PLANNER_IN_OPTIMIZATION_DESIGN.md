# Query Planner IN最適化 設計ドキュメント

**作成日**: 2025-01-12
**ステータス**: 設計フェーズ
**優先度**: 中

---

## 📋 概要

TypedRecordQueryPlannerにIN述語の自動検出機能を追加し、適切なインデックスが存在する場合にTypedInJoinPlanを自動生成します。

---

## 🔍 既存実装の調査結果

### 現在のIN最適化の状況

**Location**: `TypedRecordQueryPlanner.swift` lines 994-1053

```swift
private func generateInJoinPlan(
    filter: any TypedQueryComponent<Record>
) throws -> (any TypedQueryPlan<Record>)? {
    // 1. フィルタがINクエリコンポーネントかチェック
    guard let inFilter = filter as? TypedInQueryComponent<Record> else {
        return nil
    }

    // 2. 値の数が2以上かチェック
    guard inFilter.values.count >= 2 else {
        return nil
    }

    // 3. 最大値制限のチェック
    guard inFilter.values.count <= config.maxInValues else {
        return nil
    }

    // 4. インデックスの検索とプラン生成
    // ...
}
```

**現在の問題点**:
1. ✅ トップレベルのIN述語は検出できる
2. ❌ AND/OR内にネストされたIN述語は検出できない
3. ❌ 複数のIN述語の組み合わせを考慮していない

### InExtractorの完成

**Location**: `InExtractor.swift`

```swift
public struct InExtractor {
    public mutating func visit<Record: Sendable>(_ component: any TypedQueryComponent<Record>) throws {
        // TypedInQueryComponentの検出
        if let inComponent = component as? TypedInQueryComponent<Record> {
            inPredicates.append(InPredicate(
                fieldName: inComponent.fieldName,
                values: inComponent.values
            ))
        }

        // 再帰的なAND/OR/NOT探索
        if let andComponent = component as? TypedAndQueryComponent<Record> {
            for child in andComponent.children {
                try visit(child)
            }
        }
        // ...
    }
}
```

**InExtractorの利点**:
- ✅ ネストされたIN述語を検出可能
- ✅ 複数のIN述語を抽出可能
- ✅ AND/OR/NOTを再帰的に探索

---

## 🎯 設計方針

### 1. InExtractorの統合フロー

```
TypedRecordQueryPlanner.plan()
    └─ generateCandidatePlans()
          ├─ generateSingleIndexPlans()
          │    ├─ generateInJoinPlan()          [既存、単一IN述語のみ]
          │    ├─ ✅ generateInJoinPlansWithExtractor()  [新規]
          │    │    └─ InExtractorでネストされたIN述語も検出
          │    └─ matchFilterWithIndex()
          └─ ...
```

### 2. 改善されたIN最適化フロー

```swift
// 既存: トップレベルのIN述語のみ検出
if let inPlan = try generateInJoinPlan(filter: filter) {
    indexPlans.append(inPlan)
}

// ✅ 新規: ネストされたIN述語も検出
let extractedInPlans = try generateInJoinPlansWithExtractor(filter: filter)
indexPlans.append(contentsOf: extractedInPlans)
```

---

## 🔨 実装設計

### generateInJoinPlansWithExtractor() メソッド

```swift
extension TypedRecordQueryPlanner {
    /// InExtractorを使用してIN Join Plansを生成
    ///
    /// 既存のgenerateInJoinPlan()と異なり、ネストされたIN述語も検出します。
    ///
    /// **Example**:
    /// ```swift
    /// // Before: トップレベルのみ
    /// age IN (20, 25, 30)  → ✅ 検出
    ///
    /// // After: ネストも検出
    /// (age IN (20, 25, 30)) AND (city == "Tokyo")  → ✅ 検出
    /// (city == "Tokyo") OR (age IN (20, 25, 30))   → ✅ 検出
    /// ```
    ///
    /// - Parameter filter: Query filter
    /// - Returns: Generated IN Join Plans
    /// - Throws: RecordLayerError if plan generation fails
    private func generateInJoinPlansWithExtractor(
        filter: any TypedQueryComponent<Record>
    ) throws -> [any TypedQueryPlan<Record>] {
        var plans: [any TypedQueryPlan<Record>] = []

        // 1. InExtractorでIN述語を抽出
        var extractor = InExtractor()
        try extractor.visit(filter)

        guard extractor.hasInPredicates else {
            return []
        }

        let inPredicates = extractor.extractedInPredicates()

        // 2. 各IN述語に対してプランを生成
        for inPredicate in inPredicates {
            // 2.1 値の数をチェック
            guard inPredicate.valueCount >= 2 else {
                continue  // 1つの値の場合は通常のインデックススキャン
            }

            // 2.2 最大値制限のチェック
            guard inPredicate.valueCount <= config.maxInValues else {
                continue
            }

            // 2.3 インデックスの検索
            guard let index = findIndexForField(inPredicate.fieldName) else {
                continue
            }

            // 2.4 Cost-based判定: IN Join Planが有益かチェック
            guard shouldUseInJoinPlan(inPredicate: inPredicate, index: index) else {
                continue
            }

            // 2.5 IN Join Planの作成
            let inJoinPlan = TypedInJoinPlan<Record>(
                fieldName: inPredicate.fieldName,
                values: inPredicate.values,
                indexName: index.name,
                indexSubspaceTupleKey: index.subspaceTupleKey,
                primaryKeyLength: getPrimaryKeyLength(),
                recordName: recordName
            )

            // 2.6 他のフィルタをpost-filterとして追加
            let remainingFilter = try buildRemainingFilter(
                originalFilter: filter,
                excludingField: inPredicate.fieldName
            )

            if let remainingFilter = remainingFilter {
                let filteredPlan = TypedFilterPlan(
                    child: inJoinPlan,
                    filter: remainingFilter
                )
                plans.append(filteredPlan)
            } else {
                plans.append(inJoinPlan)
            }
        }

        return plans
    }

    /// フィールドに適用可能なインデックスを検索
    ///
    /// - Parameter fieldName: Field name
    /// - Returns: Applicable index (nil if not found)
    private func findIndexForField(_ fieldName: String) -> Index? {
        let applicableIndexes = schema.indexes(for: recordName)

        for index in applicableIndexes {
            let matchesField: Bool

            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                // 単純なフィールドインデックス
                matchesField = fieldExpr.fieldName == fieldName
            } else if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
                // 複合インデックス: 最初のフィールドをチェック
                if let firstField = concatExpr.children.first as? FieldKeyExpression {
                    matchesField = firstField.fieldName == fieldName
                } else {
                    matchesField = false
                }
            } else {
                matchesField = false
            }

            if matchesField {
                return index
            }
        }

        return nil
    }

    /// IN Join Planを使用すべきかCost-based判定
    ///
    /// **判定基準**:
    /// 1. IN値の数が適切な範囲か（2-100）
    /// 2. インデックスの選択性が高いか
    /// 3. 予想される結果数が少ないか
    ///
    /// - Parameters:
    ///   - inPredicate: IN predicate
    ///   - index: Candidate index
    /// - Returns: true if IN Join Plan should be used
    private func shouldUseInJoinPlan(
        inPredicate: InPredicate,
        index: Index
    ) -> Bool {
        // 1. IN値の数をチェック（設定済み制限内か）
        guard inPredicate.valueCount >= 2 && inPredicate.valueCount <= config.maxInValues else {
            return false
        }

        // 2. 統計情報が利用可能な場合: 選択性を推定
        if let selectivity = try? statisticsManager.estimateSelectivity(
            index: index,
            values: inPredicate.values
        ) {
            // 選択性が10%以下の場合はIN Join Planが有益
            // （結果セットが小さい = 並列スキャンが効率的）
            return selectivity <= 0.1
        }

        // 3. 統計情報がない場合: ヒューリスティック判定
        // IN値が少ない場合（<= 10）は通常有益
        return inPredicate.valueCount <= 10
    }

    /// IN述語を除いた残りのフィルタを構築
    ///
    /// - Parameters:
    ///   - originalFilter: Original filter
    ///   - excludingField: Field to exclude (IN predicate field)
    /// - Returns: Remaining filter (nil if no remaining filters)
    /// - Throws: RecordLayerError if filter construction fails
    private func buildRemainingFilter(
        originalFilter: any TypedQueryComponent<Record>,
        excludingField: String
    ) throws -> (any TypedQueryComponent<Record>)? {
        // INフィルタを除外したフィルタを構築
        // 実装は複雑なので、簡易版として全フィルタを保持

        // TODO: より洗練された実装では、フィルタツリーから特定の述語を除外
        // 現在は簡易版として、IN述語のフィールドが含まれている場合は全体を返す

        return originalFilter
    }
}
```

---

## 🔄 統合フロー修正

### generateSingleIndexPlans()の修正

```swift
private func generateSingleIndexPlans(
    _ query: TypedRecordQuery<Record>
) async throws -> [any TypedQueryPlan<Record>] {
    guard let filter = query.filter else {
        return []
    }

    var indexPlans: [any TypedQueryPlan<Record>] = []

    // ✅ 1. InExtractorを使用した高度なIN最適化（新規）
    let extractedInPlans = try generateInJoinPlansWithExtractor(filter: filter)
    indexPlans.append(contentsOf: extractedInPlans)

    // 2. 既存のIN Join Plan生成（後方互換性のため保持）
    // ただし、InExtractorで既に検出されている場合は重複を避ける
    if extractedInPlans.isEmpty {
        if let inPlan = try generateInJoinPlan(filter: filter) {
            indexPlans.append(inPlan)
        }
    }

    // 3. すべての適用可能なインデックスを取得
    let applicableIndexes = schema.indexes(for: recordName)

    // 4. 各インデックスとフィルタのマッチングを試行
    for index in applicableIndexes {
        if let matchResult = try matchFilterWithIndex(filter: filter, index: index) {
            let finalPlan: any TypedQueryPlan<Record>
            if let remainingFilter = matchResult.remainingFilter {
                finalPlan = TypedFilterPlan(child: matchResult.plan, filter: remainingFilter)
            } else {
                finalPlan = matchResult.plan
            }
            indexPlans.append(finalPlan)
        }
    }

    return indexPlans
}
```

---

## 🧪 テスト計画

### Unit Tests

```swift
@Test("IN Extractor - nested IN detection")
func testNestedInDetection() async throws {
    // Setup
    let schema = Schema([User.self])
    schema.addIndex(Index(
        name: "user_by_age",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "age")
    ))

    // Query with nested IN predicate
    let filter = TypedAndQueryComponent<User>(children: [
        TypedFieldQueryComponent<User>(fieldName: "city", comparison: .equals, value: "Tokyo"),
        TypedInQueryComponent<User>(fieldName: "age", values: [Int64(20), Int64(25), Int64(30)])
    ])

    let query = TypedRecordQuery<User>(filter: filter, sort: nil, limit: nil)

    // Plan generation
    let planner = TypedRecordQueryPlanner<User>(
        schema: schema,
        recordName: User.recordName,
        statisticsManager: statsManager
    )

    let plan = try await planner.plan(query: query)

    // Verify: IN Join Planが選択されるか、またはFilterPlanでラップされる
    if let filterPlan = plan as? TypedFilterPlan<User> {
        #expect(filterPlan.child is TypedInJoinPlan<User>)
    } else {
        #expect(plan is TypedInJoinPlan<User>)
    }
}

@Test("Cost-based IN optimization")
func testCostBasedInOptimization() async throws {
    // Setup with statistics
    let schema = Schema([User.self])
    schema.addIndex(Index(
        name: "user_by_age",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "age")
    ))

    // Configure statistics manager with high selectivity
    let statsManager = StatisticsManager(database: database, subspace: statsSubspace)
    try await statsManager.collectStatistics(index: schema.indexes[0], sampleRate: 1.0)

    // Query with IN predicate (high selectivity - should use IN Join Plan)
    let filter = TypedInQueryComponent<User>(
        fieldName: "age",
        values: [Int64(20), Int64(25), Int64(30)]
    )

    let query = TypedRecordQuery<User>(filter: filter, sort: nil, limit: nil)

    // Plan generation
    let planner = TypedRecordQueryPlanner<User>(
        schema: schema,
        recordName: User.recordName,
        statisticsManager: statsManager
    )

    let plan = try await planner.plan(query: query)

    // Verify: IN Join Planが選択される
    #expect(plan is TypedInJoinPlan<User>)
}

@Test("Multiple IN predicates")
func testMultipleInPredicates() async throws {
    // Setup
    let schema = Schema([User.self])
    schema.addIndex(Index(
        name: "user_by_age",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "age")
    ))
    schema.addIndex(Index(
        name: "user_by_city",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "city")
    ))

    // Query with multiple IN predicates
    let filter = TypedAndQueryComponent<User>(children: [
        TypedInQueryComponent<User>(fieldName: "age", values: [Int64(20), Int64(25)]),
        TypedInQueryComponent<User>(fieldName: "city", values: ["Tokyo", "Osaka"])
    ])

    let query = TypedRecordQuery<User>(filter: filter, sort: nil, limit: nil)

    // Plan generation
    let planner = TypedRecordQueryPlanner<User>(
        schema: schema,
        recordName: User.recordName,
        statisticsManager: statsManager
    )

    let plan = try await planner.plan(query: query)

    // Verify: いずれかのIN Join Planが選択される
    // （コストが最小のものが選ばれる）
    var foundInJoinPlan = false

    if let filterPlan = plan as? TypedFilterPlan<User> {
        foundInJoinPlan = filterPlan.child is TypedInJoinPlan<User>
    } else {
        foundInJoinPlan = plan is TypedInJoinPlan<User>
    }

    #expect(foundInJoinPlan)
}

@Test("IN predicate with no index")
func testInPredicateNoIndex() async throws {
    // Setup without index on the IN field
    let schema = Schema([User.self])
    // No index on 'age' field

    // Query with IN predicate
    let filter = TypedInQueryComponent<User>(
        fieldName: "age",
        values: [Int64(20), Int64(25), Int64(30)]
    )

    let query = TypedRecordQuery<User>(filter: filter, sort: nil, limit: nil)

    // Plan generation
    let planner = TypedRecordQueryPlanner<User>(
        schema: schema,
        recordName: User.recordName,
        statisticsManager: statsManager
    )

    let plan = try await planner.plan(query: query)

    // Verify: Full scan with filter (IN Join Plan not used)
    #expect(plan is TypedFullScanPlan<User> || plan is TypedFilterPlan<User>)
}
```

---

## 📊 パフォーマンス改善の測定

### Before vs After

```swift
@Test("Performance: IN optimization")
func testInOptimizationPerformance() async throws {
    // Setup: 100,000 records
    let schema = Schema([User.self])
    schema.addIndex(Index(
        name: "user_by_city",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "city")
    ))

    let store = RecordStore<User>(...)

    // Save 100,000 users in 10 cities
    for i in 0..<100_000 {
        let city = ["Tokyo", "Osaka", "Kyoto", "Nagoya", "Sapporo",
                    "Fukuoka", "Kobe", "Sendai", "Hiroshima", "Yokohama"][i % 10]
        try await store.save(User(id: Int64(i), city: city))
    }

    // Query: city IN ("Tokyo", "Osaka", "Kyoto")
    let filter = TypedInQueryComponent<User>(
        fieldName: "city",
        values: ["Tokyo", "Osaka", "Kyoto"]
    )

    let query = TypedRecordQuery<User>(filter: filter, sort: nil, limit: nil)

    // Measure Before (without IN optimization - full scan)
    let startBefore = Date()
    let resultsBefore = try await store.query()
        .where(\.city, is: .equals, "Tokyo")  // 単一値
        .execute()
    let durationBefore = Date().timeIntervalSince(startBefore)

    // Measure After (with IN optimization)
    let startAfter = Date()
    let resultsAfter = try await store.query()
        .where(filter)  // IN predicate
        .execute()
    let durationAfter = Date().timeIntervalSince(startAfter)

    // Verify improvement
    #expect(resultsAfter.count == 30_000)  // 3 cities × 10,000 each
    #expect(durationAfter < durationBefore / 10)  // At least 10x faster
}
```

---

## 🚀 実装ロードマップ

### Phase 1: InExtractor統合（1日）

- [ ] generateInJoinPlansWithExtractor() メソッド実装
- [ ] findIndexForField() ヘルパー実装
- [ ] generateSingleIndexPlans() 修正

### Phase 2: Cost-based判定（0.5日）

- [ ] shouldUseInJoinPlan() 実装
- [ ] 統計情報との統合
- [ ] ヒューリスティック判定ロジック

### Phase 3: フィルタ構築（0.5日）

- [ ] buildRemainingFilter() 実装
- [ ] IN述語の除外ロジック
- [ ] TypedFilterPlanとの統合

### Phase 4: テスト作成（1日）

- [ ] ネストされたIN述語のテスト
- [ ] Cost-based最適化のテスト
- [ ] 複数IN述語のテスト
- [ ] パフォーマンステスト

**合計**: 約3日（余裕を持って4日）

---

## 📈 期待される改善

### クエリパターン別改善率

| クエリパターン | Before | After | 改善率 |
|--------------|--------|-------|--------|
| 単純IN（3値） | ~100ms | ~2ms | **50x** |
| ネストIN（AND内） | ~150ms | ~3ms | **50x** |
| 複数IN | ~200ms | ~5ms | **40x** |
| IN + フィルタ | ~180ms | ~10ms | **18x** |

### カバレッジ向上

| 検出パターン | 既存 | InExtractor統合後 |
|-------------|------|------------------|
| トップレベルIN | ✅ | ✅ |
| AND内のIN | ❌ | ✅ |
| OR内のIN | ❌ | ✅ |
| NOT内のIN | ❌ | ✅ |
| ネストされたAND/OR内のIN | ❌ | ✅ |

---

## 🎯 設計判断サマリー

### ✅ 採用した方針

1. **InExtractorの再利用**: 既存の完成したInExtractorを活用
2. **既存フローの拡張**: generateSingleIndexPlans()に追加
3. **Cost-based判定の導入**: 統計情報に基づく最適化判断
4. **後方互換性の維持**: 既存のgenerateInJoinPlan()も保持

### 🚧 今後の検討事項

1. **フィルタ分離の洗練化**:
   - 現在: 簡易版（全フィルタを保持）
   - 将来: フィルタツリーから特定の述語のみ除外

2. **複数IN述語の最適化**:
   - 現在: 個別にプラン生成
   - 将来: 複数IN述語の組み合わせを考慮（例: city IN (...) AND age IN (...)）

3. **統計情報の詳細化**:
   - 現在: 単純な選択性推定
   - 将来: IN値ごとの分布を考慮

---

**Last Updated**: 2025-01-12
**Status**: 設計完了、実装待ち
**Estimated Effort**: 3-4日
**Reviewer**: Claude Code
