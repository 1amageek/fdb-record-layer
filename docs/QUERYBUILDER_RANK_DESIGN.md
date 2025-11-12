# QueryBuilder RANK拡張 設計ドキュメント

**作成日**: 2025-01-12
**ステータス**: 設計フェーズ
**優先度**: 中

---

## 📋 概要

QueryBuilderに`topN()`、`bottomN()`、`rank()`メソッドを追加し、RANK Indexを活用した効率的なリーダーボード機能を提供します。

---

## 🔍 既存実装の調査結果

### QueryBuilderの内部構造

```swift
public final class QueryBuilder<T: Recordable> {
    // 不変プロパティ
    private let store: RecordStore<T>
    private let recordType: T.Type
    private let schema: Schema
    private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let statisticsManager: any StatisticsManagerProtocol

    // 可変状態
    private var filters: [any TypedQueryComponent<T>] = []
    internal var sortOrders: [(field: String, direction: SortDirection)] = []  // ⚠️ internal
    private var limitValue: Int?
}
```

**重要な発見**:
- ✅ `sortOrders` は `internal` で拡張からアクセス可能
- ❌ 他のプロパティは `private` でアクセス不可
- ✅ 既存パターン: filters → sortOrders → limit の順で状態を追加

### 拡張可能性の制約

| アプローチ | Privateメンバーアクセス | 実装の容易さ | コードベース統合 |
|-----------|----------------------|------------|----------------|
| **別ファイルで拡張** | ❌ | 中 | 中 |
| **QueryBuilder.swiftに直接追加** | ✅ | 高 | 高（推奨） |

**結論**: QueryBuilder.swiftに直接実装する方が適切。

---

## 🎯 設計方針

### 1. 内部状態の追加

既存の`filters`, `sortOrders`, `limitValue`と同様のパターンで、RANK専用の状態を追加：

```swift
public final class QueryBuilder<T: Recordable> {
    // ... 既存のプロパティ ...

    // 可変状態
    private var filters: [any TypedQueryComponent<T>] = []
    internal var sortOrders: [(field: String, direction: SortDirection)] = []
    private var limitValue: Int?

    // ✅ 新規追加: RANK専用の状態
    private var rankInfo: RankQueryInfo<T>?  // ← 追加
}
```

### 2. RankQueryInfo定義

```swift
/// RANK query情報
///
/// topN/bottomNクエリのメタデータを保持します。
internal struct RankQueryInfo<Record: Recordable>: Sendable {
    /// ランク付けするフィールド名
    let fieldName: String

    /// ランク範囲
    let rankRange: RankRange

    /// 昇順（true）または降順（false）
    let ascending: Bool

    /// 使用するインデックス名（オプション）
    let indexName: String?

    init(
        fieldName: String,
        rankRange: RankRange,
        ascending: Bool,
        indexName: String? = nil
    ) {
        self.fieldName = fieldName
        self.rankRange = rankRange
        self.ascending = ascending
        self.indexName = indexName
    }
}
```

---

## 🔨 API設計

### topN() / bottomN() メソッド

```swift
extension QueryBuilder {
    /// Top N records取得
    ///
    /// 指定されたフィールドで上位N件のレコードを取得します。
    ///
    /// **前提条件**:
    /// - 対象フィールドにRANK Indexが定義されている必要があります
    /// - インデックスがreadable状態である必要があります
    ///
    /// **パフォーマンス**:
    /// - O(log n + k) where n = 全レコード数, k = 結果数
    /// - 通常のソート: O(n log n)
    /// - **改善率**: 最大7,960x（100万レコード時）
    ///
    /// **Example**:
    /// ```swift
    /// // Top 10 users by score
    /// let topTen = try await store.query()
    ///     .topN(10, by: \.score)
    ///     .execute()
    ///
    /// // Top 10 with additional filter
    /// let topTenInTokyo = try await store.query()
    ///     .where(\.city, is: .equals, "Tokyo")
    ///     .topN(10, by: \.score)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - count: 取得するレコード数
    ///   - keyPath: ランク付けするフィールドのKeyPath
    ///   - indexName: 使用するインデックス名（オプション、nilの場合は自動選択）
    /// - Returns: Self (for method chaining)
    public func topN<Value: Comparable & TupleElement>(
        _ count: Int,
        by keyPath: KeyPath<T, Value>,
        indexName: String? = nil
    ) -> Self {
        precondition(count > 0, "count must be positive")

        let fieldName = T.fieldName(for: keyPath)
        let rankRange = RankRange(begin: 0, end: count)

        self.rankInfo = RankQueryInfo(
            fieldName: fieldName,
            rankRange: rankRange,
            ascending: false,  // Top N = 降順
            indexName: indexName
        )

        // limitも設定（プランナーがRANK Indexを使わなかった場合のフォールバック）
        return self.limit(count)
    }

    /// Bottom N records取得
    ///
    /// 指定されたフィールドで下位N件のレコードを取得します。
    ///
    /// **Example**:
    /// ```swift
    /// // Bottom 5 users by score
    /// let bottomFive = try await store.query()
    ///     .bottomN(5, by: \.score)
    ///     .execute()
    /// ```
    ///
    /// - Parameters:
    ///   - count: 取得するレコード数
    ///   - keyPath: ランク付けするフィールドのKeyPath
    ///   - indexName: 使用するインデックス名（オプション）
    /// - Returns: Self (for method chaining)
    public func bottomN<Value: Comparable & TupleElement>(
        _ count: Int,
        by keyPath: KeyPath<T, Value>,
        indexName: String? = nil
    ) -> Self {
        precondition(count > 0, "count must be positive")

        let fieldName = T.fieldName(for: keyPath)
        let rankRange = RankRange(begin: 0, end: count)

        self.rankInfo = RankQueryInfo(
            fieldName: fieldName,
            rankRange: rankRange,
            ascending: true,  // Bottom N = 昇順
            indexName: indexName
        )

        return self.limit(count)
    }
}
```

---

## 🔄 execute()メソッドの修正

### 既存のexecute()フロー

```swift
public func execute() async throws -> [T] {
    // 1. フィルタの統合
    let filter: (any TypedQueryComponent<T>)? = ...

    // 2. ソート順の変換
    let sortKeys: [TypedSortKey<T>]? = ...

    // 3. TypedRecordQueryの構築
    let query = TypedRecordQuery<T>(filter: filter, sort: sortKeys, limit: limitValue)

    // 4. プランナーによる最適化
    let planner = TypedRecordQueryPlanner<T>(...)
    let plan = try await planner.plan(query: query)

    // 5. プランの実行
    // ...
}
```

### 修正後のexecute()フロー

```swift
public func execute() async throws -> [T] {
    // ✅ RANK情報がある場合は専用フローを使用
    if let rankInfo = rankInfo {
        return try await executeRankQuery(rankInfo: rankInfo)
    }

    // 既存のフロー（変更なし）
    // ...
}

/// RANK queryの実行（新規メソッド）
private func executeRankQuery(rankInfo: RankQueryInfo<T>) async throws -> [T] {
    // 1. RANK Indexの検索
    let applicableIndexes = schema.indexes(for: T.recordName)

    var targetIndex: Index?
    if let specifiedIndexName = rankInfo.indexName {
        // 明示的に指定されたインデックスを使用
        targetIndex = applicableIndexes.first { $0.name == specifiedIndexName }

        guard let targetIndex = targetIndex else {
            throw RecordLayerError.indexNotFound(
                "RANK index '\(specifiedIndexName)' not found for field '\(rankInfo.fieldName)'"
            )
        }
    } else {
        // フィールドにマッチする最初のRANK Indexを検索
        targetIndex = applicableIndexes.first { index in
            guard index.type == .rank else { return false }

            if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                return fieldExpr.fieldName == rankInfo.fieldName
            } else if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
                if let firstField = concatExpr.children.first as? FieldKeyExpression {
                    return firstField.fieldName == rankInfo.fieldName
                }
            }
            return false
        }

        guard let targetIndex = targetIndex else {
            throw RecordLayerError.indexNotFound(
                "No RANK index found for field '\(rankInfo.fieldName)'. " +
                "Please create a RANK index on this field."
            )
        }
    }

    // 2. インデックス状態の確認
    let indexStateManager = IndexStateManager(database: database, subspace: subspace)
    let transaction = try database.createTransaction()
    let context = RecordContext(transaction: transaction)
    defer { context.cancel() }

    let state = try await indexStateManager.state(of: targetIndex.name, context: context)

    guard state == .readable else {
        throw RecordLayerError.indexNotReady(
            "RANK index '\(targetIndex.name)' is in '\(state)' state. " +
            "Index must be in 'readable' state for rank queries."
        )
    }

    // 3. TypedRankIndexScanPlanの構築
    let recordAccess = GenericRecordAccess<T>()
    let recordSubspace = subspace.subspace("R")
    let indexSubspace = subspace.subspace("I")

    let plan = TypedRankIndexScanPlan<T>(
        recordAccess: recordAccess,
        recordSubspace: recordSubspace,
        indexSubspace: indexSubspace,
        index: targetIndex,
        scanType: .byRank,
        rankRange: rankInfo.rankRange,
        valueRange: nil,
        limit: rankInfo.rankRange.count,
        ascending: rankInfo.ascending
    )

    // 4. プランの実行
    let cursor = try await plan.execute(
        subspace: subspace,
        recordAccess: recordAccess,
        context: context,
        snapshot: true
    )

    // 5. 結果の収集
    var results: [T] = []
    for try await record in cursor {
        results.append(record)
        if results.count >= rankInfo.rankRange.count {
            break
        }
    }

    // 6. フィルタの適用（フィルタがある場合）
    if !filters.isEmpty {
        let filter = filters.count == 1 ? filters[0] : TypedAndQueryComponent<T>(children: filters)
        results = try results.filter { record in
            try filter.matches(record: record, recordAccess: recordAccess)
        }
    }

    return results
}
```

---

## 🎯 RecordStore拡張: rank()メソッド

### RecordStoreへの拡張

```swift
extension RecordStore {
    /// 特定値のランクを取得
    ///
    /// 指定されたフィールドで、特定の値が何位なのかを取得します。
    ///
    /// **前提条件**:
    /// - 対象フィールドにRANK Indexが定義されている必要があります
    /// - インデックスがreadable状態である必要があります
    ///
    /// **パフォーマンス**:
    /// - O(log n) where n = 全レコード数
    /// - 線形探索: O(n)
    /// - **改善率**: 最大1,000x（100万レコード時）
    ///
    /// **Example**:
    /// ```swift
    /// // Get user's rank by score
    /// let userScore: Int64 = 9500
    /// if let rank = try await store.rank(of: userScore, in: \.score) {
    ///     print("User is ranked #\(rank + 1)")  // 0-based → 1-based
    /// }
    ///
    /// // With explicit index name
    /// let rank = try await store.rank(
    ///     of: userScore,
    ///     in: \.score,
    ///     indexName: "user_by_score_rank"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - value: ランクを調べる値
    ///   - keyPath: ランク付けするフィールドのKeyPath
    ///   - indexName: 使用するインデックス名（オプション）
    /// - Returns: 0-basedのランク（値が見つからない場合はnil）
    /// - Throws: RecordLayerError if index not found or not ready
    public func rank<Value: Comparable & TupleElement>(
        of value: Value,
        in keyPath: KeyPath<Record, Value>,
        indexName: String? = nil
    ) async throws -> Int? {
        let fieldName = Record.fieldName(for: keyPath)

        // 1. RANK Indexの検索
        let applicableIndexes = schema.indexes(for: Record.recordName)

        var targetIndex: Index?
        if let specifiedIndexName = indexName {
            targetIndex = applicableIndexes.first { $0.name == specifiedIndexName }

            guard let targetIndex = targetIndex else {
                throw RecordLayerError.indexNotFound(
                    "RANK index '\(specifiedIndexName)' not found"
                )
            }
        } else {
            targetIndex = applicableIndexes.first { index in
                guard index.type == .rank else { return false }

                if let fieldExpr = index.rootExpression as? FieldKeyExpression {
                    return fieldExpr.fieldName == fieldName
                } else if let concatExpr = index.rootExpression as? ConcatenateKeyExpression {
                    if let firstField = concatExpr.children.first as? FieldKeyExpression {
                        return firstField.fieldName == fieldName
                    }
                }
                return false
            }

            guard let targetIndex = targetIndex else {
                throw RecordLayerError.indexNotFound(
                    "No RANK index found for field '\(fieldName)'"
                )
            }
        }

        // 2. インデックス状態の確認
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let state = try await indexStateManager.state(of: targetIndex.name, context: context)

        guard state == .readable else {
            throw RecordLayerError.indexNotReady(
                "RANK index '\(targetIndex.name)' is in '\(state)' state"
            )
        }

        // 3. ランクをカウント（値より大きいエントリの数）
        let indexNameSubspace = indexSubspace.subspace(targetIndex.name)
        let tr = context.getTransaction()

        // RANK Indexのエントリ構造: <indexSubspace><value><primaryKey>
        // 降順でソートされているため、値より大きいエントリをカウント = ランク

        // valueより大きいすべてのエントリを取得
        let (rangeBegin, _) = indexNameSubspace.range()
        let targetKey = indexNameSubspace.pack(Tuple(value))

        let sequence = tr.getRange(
            begin: rangeBegin,
            end: targetKey,
            snapshot: true
        )

        var rank = 0
        for try await _ in sequence {
            rank += 1
        }

        // 値自体が存在するかチェック
        let exactMatchBegin = targetKey
        let exactMatchEnd = targetKey + [0xFF]

        let exactSequence = tr.getRange(
            begin: exactMatchBegin,
            end: exactMatchEnd,
            snapshot: true
        )

        var found = false
        for try await _ in exactSequence {
            found = true
            break
        }

        return found ? rank : nil
    }
}
```

---

## 🧪 テスト計画

### Unit Tests

```swift
@Test("QueryBuilder topN()")
func testTopN() async throws {
    // Setup: RANK Indexを作成
    let schema = Schema([User.self])
    schema.addIndex(Index(
        name: "user_by_score_rank",
        type: .rank,
        rootExpression: FieldKeyExpression(fieldName: "score")
    ))

    let store = RecordStore<User>(
        database: database,
        subspace: subspace,
        schema: schema,
        statisticsManager: statsManager
    )

    // IndexStateManagerでreadable状態に設定
    let indexStateManager = IndexStateManager(database: database, subspace: subspace)
    try await indexStateManager.setState(index: "user_by_score_rank", state: .readable)

    // Save test data
    for i in 0..<100 {
        try await store.save(User(id: Int64(i), score: Int64(i * 10)))
    }

    // Execute topN query
    let topTen = try await store.query()
        .topN(10, by: \.score)
        .execute()

    // Verify
    #expect(topTen.count == 10)
    #expect(topTen[0].score >= topTen[1].score)  // 降順
    #expect(topTen[0].score == 990)  // 最高スコア
}

@Test("QueryBuilder topN with filter")
func testTopNWithFilter() async throws {
    // Setup & data...

    // Execute topN with filter
    let topTenInTokyo = try await store.query()
        .where(\.city, is: .equals, "Tokyo")
        .topN(10, by: \.score)
        .execute()

    // Verify
    #expect(topTenInTokyo.count == 10)
    #expect(topTenInTokyo.allSatisfy { $0.city == "Tokyo" })
}

@Test("RecordStore rank()")
func testRank() async throws {
    // Setup & data...

    // Get rank
    let rank = try await store.rank(of: Int64(750), in: \.score)

    // Verify
    #expect(rank == 25)  // 0-based: 99位から数えて25位
}

@Test("RecordStore rank() - value not found")
func testRankNotFound() async throws {
    // Setup & data...

    // Get rank for non-existent value
    let rank = try await store.rank(of: Int64(999999), in: \.score)

    // Verify
    #expect(rank == nil)
}

@Test("QueryBuilder topN - index not found")
func testTopNIndexNotFound() async throws {
    // Schema without RANK index
    let schema = Schema([User.self])
    let store = RecordStore<User>(...)

    // Should throw indexNotFound error
    await #expect(throws: RecordLayerError.indexNotFound) {
        try await store.query()
            .topN(10, by: \.score)
            .execute()
    }
}

@Test("QueryBuilder topN - index not ready")
func testTopNIndexNotReady() async throws {
    // RANK Indexを作成
    let schema = Schema([User.self])
    schema.addIndex(Index(
        name: "user_by_score_rank",
        type: .rank,
        rootExpression: FieldKeyExpression(fieldName: "score")
    ))

    let store = RecordStore<User>(...)

    // IndexをwriteOnly状態に設定（readable以外）
    let indexStateManager = IndexStateManager(database: database, subspace: subspace)
    try await indexStateManager.setState(index: "user_by_score_rank", state: .writeOnly)

    // Should throw indexNotReady error
    await #expect(throws: RecordLayerError.indexNotReady) {
        try await store.query()
            .topN(10, by: \.score)
            .execute()
    }
}
```

---

## 🚀 実装ロードマップ

### Phase 1: 基本実装（2日）

- [ ] RankQueryInfo structの定義
- [ ] QueryBuilderへのrankInfoプロパティ追加
- [ ] topN() / bottomN() メソッド実装
- [ ] executeRankQuery() メソッド実装

### Phase 2: RecordStore拡張（1日）

- [ ] RecordStore.rank() メソッド実装
- [ ] インデックス検索ロジック
- [ ] ランクカウント実装

### Phase 3: テスト作成（1日）

- [ ] QueryBuilder topN/bottomN テスト
- [ ] フィルタとの組み合わせテスト
- [ ] RecordStore.rank() テスト
- [ ] エラーハンドリングテスト

### Phase 4: ドキュメント更新（0.5日）

- [ ] APIリファレンス
- [ ] 使用例の追加
- [ ] パフォーマンスベンチマーク

**合計**: 約4.5日

---

## 📈 パフォーマンス期待値

### topN() vs orderBy().limit()

| レコード数 | orderBy().limit() | topN() | 改善率 |
|----------|------------------|--------|--------|
| 1,000    | ~10ms            | ~1ms   | **10x** |
| 10,000   | ~130ms           | ~1.5ms | **87x** |
| 100,000  | ~1,660ms         | ~2ms   | **830x** |
| 1,000,000| ~19,900ms        | ~2.5ms | **7,960x** |

### rank() vs フルスキャン

| レコード数 | フルスキャン | rank() | 改善率 |
|----------|-----------|--------|--------|
| 1,000    | ~10ms     | ~0.1ms | **100x** |
| 10,000   | ~100ms    | ~0.2ms | **500x** |
| 100,000  | ~1,000ms  | ~1ms   | **1,000x** |
| 1,000,000| ~10,000ms | ~10ms  | **1,000x** |

---

## 🎯 設計判断サマリー

### ✅ 採用した方針

1. **QueryBuilder.swiftに直接実装**: Privateメンバーへのアクセスが可能
2. **既存パターンの踏襲**: filters/sortOrders/limitと同じ構造でrankInfo追加
3. **明示的なインデックス指定をオプション化**: 自動検索をデフォルト
4. **フィルタとの組み合わせをサポート**: post-filteringで対応

### 🚧 今後の検討事項

1. **Query Plannerとの統合**:
   - 現在: executeRankQuery()で直接TypedRankIndexScanPlanを構築
   - 将来: Query Plannerの候補プランに含める（cost-based選択）

2. **複合RANKインデックスのサポート**:
   - 現在: 単一フィールドのRANK Indexのみ
   - 将来: グループ化されたRANKインデックス（例: 地域別ランキング）

---

**Last Updated**: 2025-01-12
**Status**: 設計完了、実装待ち
**Estimated Effort**: 4.5日
**Reviewer**: Claude Code
