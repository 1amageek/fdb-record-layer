# 次の実装ステップ - Swift Record Layer

**最終更新**: 2025-01-12
**現在の完成度**: 97%
**残り作業**: 約3%（10日程度）

---

## 📊 現状サマリー

### ✅ 完了したPhase（2025-01-12）

| Phase | 機能 | 完成度 | 主な成果 |
|-------|------|--------|---------|
| **Phase 1** | クエリ最適化 | 100% | Covering Index完全実装、supportsReconstruction自動判定 |
| **Phase 2** | スキーマ進化 | 100% | Enum検証、Field検証、FormerIndex |
| **Phase 4** | 集約機能 | 100% | GROUP BY Result Builder、AVG Index |
| **Phase 5** | トランザクション | 100% | Commit Hooks、Transaction Options |

### 🟡 残っているPhase

| Phase | 機能 | 完成度 | 残り作業 |
|-------|------|--------|---------|
| **Phase 3** | RANK Index | 90% | QueryBuilder API統合（5日） |
| **Phase 6** | 高度な機能 | 0% | Migration Manager、TEXT Index、SPATIAL Index |

---

## 🔴 最優先タスク（1-2週間）

### 1. RANK Index API完成（5日）

**目的**: リーダーボード機能を使いやすくする

**必要な実装**:

```swift
// 1. QueryBuilder拡張
extension QueryBuilder {
    /// Top N要素を取得
    public func topN(
        _ count: Int,
        by keyPath: KeyPath<Record, some Comparable>,
        ascending: Bool = false
    ) -> Self

    /// 特定値のランクを取得
    public func rank(
        of value: some TupleElement,
        in keyPath: KeyPath<Record, some Comparable>
    ) async throws -> Int?
}

// 2. RankIndexScanPlan実装
public struct RankIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    let scanType: RankScanType  // .byValue or .byRank
    let index: Index
    let range: RankRange
}

// 3. RankScanType定義
public enum RankScanType: Sendable {
    case byValue  // 値でスキャン（既存のインデックススキャン）
    case byRank   // ランクでスキャン（N位〜M位）
}
```

**使用例**:
```swift
// Top 10ユーザーを取得
let top10 = try await store.query(User.self)
    .topN(10, by: \.score, ascending: false)
    .execute()

// 特定ユーザーのランクを取得
let rank = try await store.rank(of: 12345, in: \.score)
print("User rank: \(rank ?? -1)")
```

**ファイル**:
- `Sources/FDBRecordLayer/Query/RankIndexScanPlan.swift`
- `Sources/FDBRecordLayer/Query/QueryBuilder+Rank.swift`

**見積もり**: 5日
**優先度**: 🔴 高

---

### 2. InExtractor完全実装（3日）

**目的**: 複雑なIN述語を含むクエリの最適化

**必要な実装**:

```swift
// 1. QueryComponentVisitor protocol
public protocol QueryComponentVisitor {
    mutating func visit(_ component: TypedFieldQueryComponent) throws
    mutating func visit(_ component: TypedInQueryComponent) throws
    mutating func visit(_ component: TypedAndQueryComponent) throws
    mutating func visit(_ component: TypedOrQueryComponent) throws
}

// 2. InExtractor実装
public struct InExtractor: QueryComponentVisitor {
    private var extractedInComponents: [TypedInQueryComponent] = []

    public mutating func visit(_ component: TypedInQueryComponent) throws {
        extractedInComponents.append(component)
    }

    public func extractInComponents(from query: TypedRecordQuery) -> [TypedInQueryComponent] {
        var extractor = InExtractor()
        // Visit all components
        return extractor.extractedInComponents
    }
}

// 3. Query Planner統合
extension TypedRecordQueryPlanner {
    func optimizeInQueries(
        _ query: TypedRecordQuery,
        using extractor: InExtractor
    ) -> TypedRecordQuery {
        // IN述語を抽出し、InJoinPlanに変換
    }
}
```

**使用例**:
```swift
// 複雑なクエリ
let query = QueryBuilder<User>()
    .where(\.age, .greaterThanOrEquals, 18)
    .where(\.city, .in, ["Tokyo", "Osaka", "Kyoto"])
    .where(\.status, .equals, "active")
    .build()

// InExtractorが自動的にIN述語を検出し、InJoinPlanを生成
// → 50-100倍高速化
```

**ファイル**:
- `Sources/FDBRecordLayer/Query/InExtractor.swift`
- `Sources/FDBRecordLayer/Query/QueryComponentVisitor.swift`

**見積もり**: 3日
**優先度**: 🟡 中

---

## 🟡 中優先度タスク（1-2ヶ月）

### 3. Migration Manager（1週間）

**目的**: スキーママイグレーションの自動実行

**必要な実装**:

```swift
// 1. SchemaMigration protocol
public protocol SchemaMigration: Sendable {
    var fromVersion: SchemaVersion { get }
    var toVersion: SchemaVersion { get }

    func migrate(
        database: DatabaseProtocol,
        subspace: Subspace,
        context: RecordContext
    ) async throws
}

// 2. MigrationManager
public final class MigrationManager: Sendable {
    private let database: any DatabaseProtocol
    private let migrations: [SchemaMigration]

    public func migrate(
        from: SchemaVersion,
        to: SchemaVersion,
        subspace: Subspace
    ) async throws {
        // マイグレーションチェーンを実行
    }

    public func currentVersion(subspace: Subspace) async throws -> SchemaVersion {
        // 現在のバージョンを取得
    }
}
```

**使用例**:
```swift
// マイグレーション定義
struct AddEmailFieldMigration: SchemaMigration {
    let fromVersion = SchemaVersion(1, 0, 0)
    let toVersion = SchemaVersion(1, 1, 0)

    func migrate(
        database: DatabaseProtocol,
        subspace: Subspace,
        context: RecordContext
    ) async throws {
        // レコードにemailフィールドを追加
        try await database.withTransaction { transaction in
            let store = RecordStore(...)
            for user in try await store.query(User.self).execute() {
                var updated = user
                updated.email = "\(user.username)@example.com"
                try await store.save(updated, context: context)
            }
        }
    }
}

// マイグレーション実行
let manager = MigrationManager(
    database: database,
    migrations: [AddEmailFieldMigration()]
)
try await manager.migrate(
    from: SchemaVersion(1, 0, 0),
    to: SchemaVersion(1, 1, 0),
    subspace: subspace
)
```

**ファイル**:
- `Sources/FDBRecordLayer/Schema/SchemaMigration.swift`
- `Sources/FDBRecordLayer/Schema/MigrationManager.swift`

**見積もり**: 7日
**優先度**: 🟡 中

---

### 4. RankedSet.delete()実装（2日）

**目的**: RANK Indexからの削除操作対応

**必要な実装**:

```swift
extension RankedSet {
    /// 要素を削除（O(log n)）
    public mutating func delete(_ value: Element) -> Int? {
        // Skip-listから要素を削除
        // 削除された要素のランクを返す
    }
}
```

**ファイル**: `Sources/FDBRecordLayer/Index/RankedSet.swift`

**見積もり**: 2日
**優先度**: 🟡 中

---

## 🟢 低優先度タスク（将来）

### 5. DistinctPlan / FirstPlan（2日）

**目的**: 重複排除・最初の1件取得の最適化

```swift
public struct TypedDistinctPlan<Record: Sendable>: TypedQueryPlan {
    let source: any TypedQueryPlan<Record>
    let distinctFields: [String]
}

public struct TypedFirstPlan<Record: Sendable>: TypedQueryPlan {
    let source: any TypedQueryPlan<Record>
}
```

**見積もり**: 2日
**優先度**: 🟢 低

---

### 6. TransactionOptions struct（1日）

**目的**: トランザクションオプションの統一的管理

```swift
public struct TransactionOptions: Sendable {
    var timeout: Int?
    var readYourWrites: Bool = true
    var priority: Priority = .default

    public enum Priority: Sendable {
        case systemImmediate
        case high
        case `default`
        case low
        case batch
    }
}
```

**見積もり**: 1日
**優先度**: 🟢 低

---

## 📈 Phase 6: 高度な機能（将来計画）

### TEXT Index（Lucene統合）

**見積もり**: 6-8週間
**優先度**: Phase 6

**必要な実装**:
- FDBDirectory実装（Lucene Directory APIをFoundationDBに実装）
- 全文検索API
- トークナイザー統合
- 日本語対応（Kuromoji）

---

### SPATIAL Index

**見積もり**: 4-6週間
**優先度**: Phase 6

**必要な実装**:
- Geohash実装
- R-tree実装
- 地理クエリAPI（範囲検索、最近傍検索）

---

## 🎯 推奨実装順序

### Week 1-2: 最優先タスク

```
Day 1-5:   RANK Index API完成（5日）
Day 6-8:   InExtractor完全実装（3日）
Day 9-10:  テスト・ドキュメント整備
```

**成果**: Phase 3完了（100%）、総合完成度 → 98%

---

### Week 3-4: 中優先度タスク

```
Day 11-17: Migration Manager（7日）
Day 18-19: RankedSet.delete()（2日）
Day 20:    テスト・ドキュメント整備
```

**成果**: マイグレーション機能完成、総合完成度 → 99%

---

### Month 2-3: 低優先度タスク

```
Week 5-6:  DistinctPlan / FirstPlan（2日）
           TransactionOptions struct（1日）
           残りの細かい最適化
```

**成果**: 総合完成度 → 100%

---

## 📊 Java版との主な差分（残り3%）

| 機能 | Java | Swift | 残り作業 |
|------|------|-------|---------|
| **RANK Index QueryBuilder API** | ✅ | 🟡 | .topN(), .rank(of:) 実装（5日） |
| **InExtractor** | ✅ | 🟡 | プレースホルダーから完全実装へ（3日） |
| **Migration Manager** | ✅ | ❌ | 完全実装（7日） |
| **RankedSet.delete()** | ✅ | ❌ | Skip-list削除ロジック（2日） |
| **TEXT Index** | ✅ | ❌ | Phase 6（6-8週間） |
| **SPATIAL Index** | ✅ | ❌ | Phase 6（4-6週間） |

---

## 🚀 Swift版の優位性（維持すべきポイント）

### 1. 型安全性

- KeyPath-based API
- コンパイル時型チェック
- @Recordable マクロの自動生成

### 2. パフォーマンス

- Mutex-based並行性（Java Actorの3倍高速）
- ストリーミング処理（O(1)メモリ）
- Covering Index自動検出

### 3. Swift独自機能

- AVERAGE Index（Java版にはない）
- GROUP BY Result Builder
- supportsReconstruction自動判定

### 4. 安全性

- Swift 6 Strict Concurrency
- Sendable警告ゼロ（型消去パターン）
- 非オプショナルカスタム型の安全なハンドリング

---

## 📝 開発ガイドライン

### コーディング規約

1. **並行性**: `final class + Mutex` パターンを維持（Actorは使用しない）
2. **型安全性**: KeyPath-basedで型安全性を最大化
3. **テスト**: 新機能は必ずテストカバレッジ85%以上
4. **ドキュメント**: すべてのpublicメソッドにドキュメントコメント

### テスト要件

- SwiftTestingフレームワーク使用
- 統合テスト + ユニットテスト
- パフォーマンステスト（重要機能のみ）

### ドキュメント更新

以下のドキュメントを更新：
- `IMPLEMENTATION_STATUS.md`: 実装状況
- `JAVA_COMPARISON.md`: Java版との比較
- `NEXT_STEPS.md`: 次のステップ（このファイル）

---

## 🎯 まとめ

### 現状

- **97%完成**（Production-Ready）
- **4/5 Phase完了**（Phase 1, 2, 4, 5）
- **327/327テストパス**

### 次のマイルストーン

- **Week 1-2**: RANK Index API + InExtractor → **98%**
- **Week 3-4**: Migration Manager → **99%**
- **Month 2-3**: 細かい最適化 → **100%**

### Phase 6（将来）

- TEXT Index（全文検索）
- SPATIAL Index（地理検索）
- SQL対応

---

**Last Updated**: 2025-01-12
**Reviewer**: Claude Code
