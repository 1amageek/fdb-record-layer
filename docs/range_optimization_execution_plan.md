# Range インデックス最適化 実行計画

**目標**: 提案3（Pre-filtering）、提案1（Covering Indexes）、提案5（Range Selectivity統計）を実装し、Range クエリのパフォーマンスを90-97%改善する。

**実装順序**: 3 → 1 → 5（効果とリスクのバランスを考慮）

---

## Phase 1: Proposal 3 - Pre-filtering (Prefix scan)

**期間**: 1-2週間
**優先度**: 最高 ⭐⭐⭐⭐⭐
**効果**: 70-90% IO削減
**リスク**: 低

### 1.1 概要

複数のRange フィルタの交差 "window" を事前計算し、各index scanの範囲を狭めることで、false-positiveを大幅に削減する。

**例**:
```swift
// クエリ: overlaps(period1) AND overlaps(period2)
// period1 = 2024-01-01...2024-12-31
// period2 = 2024-06-01...2024-09-30

// 現在の実装:
// - scan1: [2024-01-01, 2024-12-31] → 365件
// - scan2: [2024-06-01, 2024-09-30] → 122件
// - IntersectionPlan: 365 + 122 = 487件読み取り

// Pre-filtering後:
// window = [max(2024-01-01, 2024-06-01), min(2024-12-31, 2024-09-30)]
//        = [2024-06-01, 2024-09-30]
// - scan1: [2024-06-01, 2024-09-30] → 122件
// - scan2: [2024-06-01, 2024-09-30] → 122件
// - IntersectionPlan: 122 + 122 = 244件読み取り（50%削減）
```

### 1.2 実装ファイルと変更内容

#### 1.2.1 新規ファイル: `Sources/FDBRecordLayer/Query/RangeWindowCalculator.swift`

**目的**: Range交差windowの計算ロジックを集約

```swift
import Foundation

/// Range フィルタの交差windowを計算するユーティリティ
public struct RangeWindowCalculator {

    /// 複数のRange<Date>フィルタの交差windowを計算
    /// - Parameter ranges: Range<Date>の配列
    /// - Returns: 交差window、または交差なしの場合はnil
    public static func calculateIntersectionWindow(_ ranges: [Range<Date>]) -> Range<Date>? {
        guard !ranges.isEmpty else { return nil }

        // 最大のlowerBoundと最小のupperBoundを計算
        let maxLower = ranges.map(\.lowerBound).max()!
        let minUpper = ranges.map(\.upperBound).min()!

        // 交差なし
        guard maxLower < minUpper else {
            return nil
        }

        return maxLower..<minUpper
    }

    /// 複数のPartialRangeFrom<Date>フィルタの交差windowを計算
    public static func calculateIntersectionWindow(_ ranges: [PartialRangeFrom<Date>]) -> PartialRangeFrom<Date>? {
        guard !ranges.isEmpty else { return nil }

        // 最大のlowerBoundを計算
        let maxLower = ranges.map(\.lowerBound).max()!
        return maxLower...
    }

    /// 複数のPartialRangeThrough<Date>フィルタの交差windowを計算
    public static func calculateIntersectionWindow(_ ranges: [PartialRangeThrough<Date>]) -> PartialRangeThrough<Date>? {
        guard !ranges.isEmpty else { return nil }

        // 最小のupperBoundを計算
        let minUpper = ranges.map(\.upperBound).min()!
        return ...minUpper
    }

    /// 複数のPartialRangeUpTo<Date>フィルタの交差windowを計算
    public static func calculateIntersectionWindow(_ ranges: [PartialRangeUpTo<Date>]) -> PartialRangeUpTo<Date>? {
        guard !ranges.isEmpty else { return nil }

        // 最小のupperBoundを計算
        let minUpper = ranges.map(\.upperBound).min()!
        return ..<minUpper
    }
}
```

**テスト**: `Tests/FDBRecordLayerTests/Query/RangeWindowCalculatorTests.swift`

```swift
import Testing
import Foundation
@testable import FDBRecordLayer

@Suite("RangeWindowCalculator Tests")
struct RangeWindowCalculatorTests {

    @Test("Calculate intersection window for Range<Date>")
    func testRangeIntersection() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)
        let date4 = Date(timeIntervalSince1970: 4000)

        let range1 = date1..<date4  // [1000, 4000)
        let range2 = date2..<date3  // [2000, 3000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window?.lowerBound == date2)
        #expect(window?.upperBound == date3)
    }

    @Test("No intersection returns nil")
    func testNoIntersection() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let date3 = Date(timeIntervalSince1970: 3000)
        let date4 = Date(timeIntervalSince1970: 4000)

        let range1 = date1..<date2  // [1000, 2000)
        let range2 = date3..<date4  // [3000, 4000)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window == nil)
    }

    @Test("PartialRangeFrom intersection")
    func testPartialRangeFromIntersection() throws {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        let range1 = date1...  // [1000, ∞)
        let range2 = date2...  // [2000, ∞)

        let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])

        #expect(window?.lowerBound == date2)  // max(1000, 2000) = 2000
    }
}
```

#### 1.2.2 修正ファイル: `Sources/FDBRecordLayer/Query/TypedRecordQueryPlanner.swift`

**変更箇所1**: `planIntersection()` メソッドの拡張

```swift
// 現在の実装（行番号は参考）
func planIntersection(filters: [Filter]) -> any TypedQueryPlan<Record> {
    var childPlans: [any TypedQueryPlan<Record>] = []

    for filter in filters {
        if let indexPlan = tryIndexPlan(filter: filter) {
            childPlans.append(indexPlan)
        }
    }

    return TypedIntersectionPlan(children: childPlans)
}

// ↓ 以下に変更

func planIntersection(filters: [Filter]) -> any TypedQueryPlan<Record> {
    // Step 1: Range フィルタを抽出
    let rangeFilters = filters.filter { filter in
        // RangeOverlapsFilter を判定（実装に応じて調整）
        return filter is RangeOverlapsFilter  // 仮の型
    }

    // Step 2: 交差windowを計算
    var intersectionWindow: Range<Date>?
    if rangeFilters.count >= 2 {
        let ranges = rangeFilters.compactMap { filter -> Range<Date>? in
            // フィルタから Range<Date> を抽出
            guard let rangeFilter = filter as? RangeOverlapsFilter else { return nil }
            return rangeFilter.queryRange
        }

        intersectionWindow = RangeWindowCalculator.calculateIntersectionWindow(ranges)

        // 交差なし → EmptyPlan
        if intersectionWindow == nil && !ranges.isEmpty {
            return TypedEmptyPlan()
        }
    }

    // Step 3: 各子プランに狭い範囲を適用
    var childPlans: [any TypedQueryPlan<Record>] = []

    for filter in filters {
        if let indexPlan = tryIndexPlan(filter: filter, window: intersectionWindow) {
            childPlans.append(indexPlan)
        }
    }

    return TypedIntersectionPlan(children: childPlans)
}

// tryIndexPlan() を拡張してwindowを受け取る
private func tryIndexPlan(
    filter: Filter,
    window: Range<Date>? = nil
) -> (any TypedQueryPlan<Record>)? {
    // 既存のロジック + window適用
    if let rangeFilter = filter as? RangeOverlapsFilter,
       let window = window {
        // windowを適用した新しいフィルタを作成
        let narrowedFilter = rangeFilter.narrowed(to: window)
        return createIndexScanPlan(filter: narrowedFilter)
    }

    // 通常のフィルタ処理
    return createIndexScanPlan(filter: filter)
}
```

**注意**: 現在の実装には `RangeOverlapsFilter` 型が存在しない可能性があるため、実際のFilter構造に応じて調整が必要。

#### 1.2.3 修正ファイル: `Sources/FDBRecordLayer/Query/TypedIndexScanPlan.swift`

**変更箇所**: beginKey/endKeyの計算にwindowを適用

```swift
// 現在の実装
let beginTuple = Tuple(indexedValues)
let endTuple = Tuple(indexedValues)
var endKey = indexSubspace.pack(endTuple)
endKey.append(0xFF)  // 等価クエリの場合

// ↓ 以下に変更

// Window適用（Range<Date>フィルタの場合）
if let window = self.window {  // windowプロパティを追加
    // beginTupleのlowerBoundをwindow.lowerBoundに置き換え
    let narrowedBeginTuple = Tuple(window.lowerBound, /* 他のフィールド */)
    let narrowedEndTuple = Tuple(window.upperBound, /* 他のフィールド */)

    beginKey = indexSubspace.pack(narrowedBeginTuple)
    endKey = indexSubspace.pack(narrowedEndTuple)
} else {
    // 通常の処理
    // ...
}
```

### 1.3 テスト戦略

#### 1.3.1 ユニットテスト

**ファイル**: `Tests/FDBRecordLayerTests/Query/RangeWindowCalculatorTests.swift`

- ✅ 2つのRange交差
- ✅ 3つ以上のRange交差
- ✅ 交差なし → nil
- ✅ PartialRangeFrom交差
- ✅ PartialRangeThrough交差
- ✅ PartialRangeUpTo交差
- ✅ 空配列 → nil

#### 1.3.2 統合テスト

**ファイル**: `Tests/FDBRecordLayerTests/Query/RangePrefilteriengIntegrationTests.swift`

```swift
@Suite("Range Pre-filtering Integration Tests")
struct RangePrefilteringIntegrationTests {

    @Test("Multiple Range overlaps with pre-filtering")
    func testMultipleRangeOverlaps() async throws {
        // Setup: 1000件のイベントを作成
        // - period1: 2024-01-01...2024-12-31（365日分）
        // - period2: 2024-06-01...2024-09-30（122日分）

        let query = QueryBuilder<Event>()
            .filter(\.period, .overlaps, period1)
            .filter(\.period, .overlaps, period2)
            .build()

        let results = try await store.query(query).execute()

        // 検証1: 結果が正しい
        #expect(results.count == 122)

        // 検証2: IO削減を確認（メトリクスから）
        // - Pre-filteringなし: 487件読み取り
        // - Pre-filteringあり: 244件読み取り（50%削減）
        let ioCount = getIOCount()  // メトリクス取得関数
        #expect(ioCount < 300)  // 期待値: 244件
    }

    @Test("No intersection returns empty result immediately")
    func testNoIntersectionEarlyExit() async throws {
        let period1 = Date(timeIntervalSince1970: 1000)..<Date(timeIntervalSince1970: 2000)
        let period2 = Date(timeIntervalSince1970: 3000)..<Date(timeIntervalSince1970: 4000)

        let query = QueryBuilder<Event>()
            .filter(\.period, .overlaps, period1)
            .filter(\.period, .overlaps, period2)
            .build()

        let results = try await store.query(query).execute()

        // 検証1: 結果が空
        #expect(results.isEmpty)

        // 検証2: IO削減を確認（スキャン不要）
        let ioCount = getIOCount()
        #expect(ioCount == 0)  // 一切スキャンしない
    }
}
```

### 1.4 成功指標

- ✅ RangeWindowCalculator の全テストが合格
- ✅ 2つのRange overlapsクエリでIO削減率 50%以上
- ✅ 3つのRange overlapsクエリでIO削減率 70%以上
- ✅ 交差なしクエリでIO削減率 100%（スキャンなし）
- ✅ 既存の525テストが引き続き合格

### 1.5 ロールバック計画

Phase 1が失敗した場合:
1. `RangeWindowCalculator.swift` を削除
2. `TypedRecordQueryPlanner.swift` の変更を元に戻す
3. `TypedIndexScanPlan.swift` の変更を元に戻す

---

## Phase 2: Proposal 1 - Covering Indexes

**期間**: 2-3週間
**優先度**: 高 ⭐⭐⭐⭐⭐
**効果**: 50-90% IO削減
**リスク**: 低（Java版実績あり）

### 2.1 概要

Rangeインデックスのキーに `lowerBound/upperBound` + クエリフィルタフィールド（`title`など）を含めることで、IntersectionPlan段階でレコード本体のフェッチを回避する。

**例**:
```swift
// 現在の実装:
// インデックスキー: [period.lowerBound, period.upperBound, primaryKey]
// インデックス値: []
// → titleフィルタのためにレコード本体を読む必要がある

// Covering Index:
// インデックスキー: [period.lowerBound, period.upperBound, title, primaryKey]
// インデックス値: []
// → インデックスだけでtitleフィルタを適用可能、レコード本体不要
```

### 2.2 実装ファイルと変更内容

#### 2.2.1 修正ファイル: `Sources/FDBRecordLayer/Macro/Macros.swift`

**変更箇所**: `#RangeIndex` マクロの拡張

```swift
// 現在の実装
public macro RangeIndex<T>(
    _ keyPath: KeyPath<T, Range<Date>>,
    name: String? = nil
) -> Index = #externalMacro(...)

// ↓ 以下に拡張

public macro RangeIndex<T>(
    _ keyPath: KeyPath<T, Range<Date>>,
    name: String? = nil,
    covering: [PartialKeyPath<T>] = []  // ← 追加
) -> Index = #externalMacro(...)

// 使用例:
@Recordable
struct Event {
    #RangeIndex<Event>(\\.period, covering: [\\.title, \\.category])

    var id: Int64
    var period: Range<Date>
    var title: String
    var category: String
}

// 生成されるインデックス:
// キー: [period.lowerBound, period.upperBound, title, category, primaryKey]
// 値: []
```

#### 2.2.2 修正ファイル: `Sources/FDBRecordLayer/Macro/RangeIndexMacro.swift`

**変更箇所**: マクロ展開ロジック

```swift
public struct RangeIndexMacro: FreestandingMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        // 引数を解析
        let rangeKeyPath = node.argumentList.first!  // \.period
        let coveringKeyPaths = node.argumentList["covering"]  // [\.title, \.category]

        // KeyExpressionを構築
        var children: [KeyExpression] = [
            FieldKeyExpression(fieldName: "period_lowerBound"),
            FieldKeyExpression(fieldName: "period_upperBound")
        ]

        // coveringフィールドを追加
        for keyPath in coveringKeyPaths {
            let fieldName = extractFieldName(keyPath)
            children.append(FieldKeyExpression(fieldName: fieldName))
        }

        // プライマリキーを最後に追加
        children.append(FieldKeyExpression(fieldName: "id"))  // 仮

        return """
        Index(
            name: "\(indexName)",
            type: .value,
            rootExpression: ConcatenateKeyExpression(children: \(children))
        )
        """
    }
}
```

#### 2.2.3 修正ファイル: `Sources/FDBRecordLayer/Index/RangeIndexMaintainer.swift`

**変更箇所**: インデックスキー構築にcoveringフィールドを含める

```swift
// 現在の実装
public func updateIndex(
    oldRecord: Record?,
    newRecord: Record?,
    transaction: TransactionProtocol
) async throws {
    // ...
    let indexKey = subspace.pack(Tuple(
        range.lowerBound,
        range.upperBound,
        primaryKey
    ))
    transaction.setValue([], for: indexKey)
}

// ↓ 以下に変更

public func updateIndex(
    oldRecord: Record?,
    newRecord: Record?,
    transaction: TransactionProtocol
) async throws {
    // ...

    // coveringフィールドを抽出
    var keyElements: [any TupleElement] = [
        range.lowerBound,
        range.upperBound
    ]

    // インデックス定義からcoveringフィールドを取得
    if let coveringFields = index.coveringFields {  // Index構造体に追加
        for field in coveringFields {
            let value = recordAccess.extractFieldValue(from: newRecord, fieldName: field)
            keyElements.append(value)
        }
    }

    // プライマリキーを最後に追加
    keyElements.append(contentsOf: primaryKeyElements)

    let indexKey = subspace.pack(TupleHelpers.toTuple(keyElements))
    transaction.setValue([], for: indexKey)
}
```

#### 2.2.4 修正ファイル: `Sources/FDBRecordLayer/Schema/Index.swift`

**変更箇所**: `coveringFields` プロパティを追加

```swift
public struct Index: Sendable, Hashable, Codable {
    public let name: String
    public let type: IndexType
    public let rootExpression: any KeyExpression
    public let recordTypes: Set<String>?
    public let coveringFields: [String]?  // ← 追加

    public init(
        name: String,
        type: IndexType,
        rootExpression: any KeyExpression,
        recordTypes: Set<String>? = nil,
        coveringFields: [String]? = nil  // ← 追加
    ) {
        self.name = name
        self.type = type
        self.rootExpression = rootExpression
        self.recordTypes = recordTypes
        self.coveringFields = coveringFields
    }
}
```

#### 2.2.5 新規ファイル: `Sources/FDBRecordLayer/Query/TypedCoveringIndexScanPlan.swift`

**目的**: Covering Indexを使用してレコード本体のフェッチを回避

```swift
public struct TypedCoveringIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    private let indexSubspace: Subspace
    private let index: Index
    private let beginKey: FDB.Bytes
    private let endKey: FDB.Bytes
    private let coveringFields: [String]

    public func execute(
        database: any DatabaseProtocol,
        recordSubspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        transaction: TransactionProtocol
    ) async throws -> AnyTypedRecordCursor<Record> {
        // インデックスをスキャン
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: true
        )

        // Cursorを作成（レコード本体のフェッチなし）
        let cursor = CoveringIndexScanTypedCursor(
            sequence: sequence,
            indexSubspace: indexSubspace,
            coveringFields: coveringFields,
            recordAccess: recordAccess
        )

        return AnyTypedRecordCursor(cursor)
    }
}

// Cursor実装
private final class CoveringIndexScanTypedCursor<Record: Sendable>: TypedRecordCursor {
    private let iterator: AsyncIterator
    private let indexSubspace: Subspace
    private let coveringFields: [String]
    private let recordAccess: any RecordAccess<Record>

    func next() async throws -> Record? {
        guard let (key, _) = try await iterator.next() else {
            return nil
        }

        // インデックスキーから値を抽出
        let tuple = try indexSubspace.unpack(key)
        // tuple = [lowerBound, upperBound, title, category, primaryKey]

        // Recordを部分的に構築（coveringフィールドのみ）
        let partialRecord = recordAccess.constructPartialRecord(
            from: tuple,
            coveringFields: coveringFields
        )

        return partialRecord
    }
}
```

**注意**: `RecordAccess.constructPartialRecord()` は新規メソッドで、すべてのフィールドを持たない部分的なレコードを構築する必要がある。実装の複雑さを考慮すると、Phase 2の後半で対応。

### 2.3 テスト戦略

#### 2.3.1 マクロテスト

**ファイル**: `Tests/FDBRecordLayerTests/Macro/RangeIndexMacroTests.swift`

```swift
@Test("RangeIndex macro with covering fields")
func testRangeIndexWithCovering() throws {
    let source = """
    @Recordable
    struct Event {
        #RangeIndex<Event>(\\.period, covering: [\\.title, \\.category])

        var id: Int64
        var period: Range<Date>
        var title: String
        var category: String
    }
    """

    let expanded = expandMacro(source)

    #expect(expanded.contains("coveringFields: [\"title\", \"category\"]"))
}
```

#### 2.3.2 統合テスト

**ファイル**: `Tests/FDBRecordLayerTests/Index/CoveringIndexIntegrationTests.swift`

```swift
@Suite("Covering Index Integration Tests")
struct CoveringIndexIntegrationTests {

    @Test("Covering index avoids record fetch")
    func testCoveringIndexNoFetch() async throws {
        // Setup: covering indexを作成
        let index = Index(
            name: "event_by_period_covering_title",
            type: .value,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "period_lowerBound"),
                FieldKeyExpression(fieldName: "period_upperBound"),
                FieldKeyExpression(fieldName: "title"),
                FieldKeyExpression(fieldName: "id")
            ]),
            coveringFields: ["title"]
        )

        // データ挿入
        let event = Event(
            id: 1,
            period: Date()..<Date().addingTimeInterval(3600),
            title: "Meeting",
            category: "Work"
        )
        try await store.save(event)

        // クエリ: period overlaps AND title contains "Meeting"
        let query = QueryBuilder<Event>()
            .filter(\\.period, .overlaps, queryPeriod)
            .filter(\\.title, .contains, "Meeting")
            .build()

        let results = try await store.query(query).execute()

        // 検証1: 結果が正しい
        #expect(results.count == 1)
        #expect(results[0].title == "Meeting")

        // 検証2: レコードフェッチが発生していない
        let fetchCount = getRecordFetchCount()  // メトリクス取得
        #expect(fetchCount == 0)  // Covering indexのみ使用
    }
}
```

### 2.4 成功指標

- ✅ `#RangeIndex` マクロが `covering:` パラメータをサポート
- ✅ Covering indexのキー構造が正しい（coveringフィールドを含む）
- ✅ クエリプランナーがCovering indexを選択
- ✅ レコードフェッチ削減率 50%以上（titleフィルタ付きクエリ）
- ✅ 既存テスト + 新規テスト全合格

### 2.5 ロールバック計画

Phase 2が失敗した場合:
1. `Index.coveringFields` プロパティを削除
2. `#RangeIndex` マクロの `covering:` パラメータを削除
3. `TypedCoveringIndexScanPlan.swift` を削除
4. `RangeIndexMaintainer` の変更を元に戻す

---

## Phase 3: Proposal 5 - Range Selectivity Statistics

**期間**: 2-3週間
**優先度**: 高 ⭐⭐⭐⭐
**効果**: 10-30% CPU削減（間接的にIO削減）
**リスク**: 中（統計精度）

### 3.1 概要

StatisticsManager に Range index の cardinality/coverage を収集し、TypedIntersectionPlan の子順序を最適化する。

**例**:
```swift
// クエリ: overlaps(period1) AND category == "Electronics"
// - period1 overlapsインデックス: 10,000件（selectivity = 50%）
// - category == "Electronics"インデックス: 200件（selectivity = 1%）

// 現在の実装: 順序が任意
// - plan1 (period overlap): 10,000件読み取り
// - plan2 (category): 200件読み取り
// → IntersectionPlan: 10,200件読み取り

// Selectivity統計活用: 高selectivityを先に実行
// - plan2 (category): 200件読み取り  ← 先に実行
// - plan1 (period overlap): 200件のみチェック
// → IntersectionPlan: 400件読み取り（96%削減）
```

### 3.2 実装ファイルと変更内容

#### 3.2.1 新規ファイル: `Sources/FDBRecordLayer/Statistics/RangeIndexStatistics.swift`

**目的**: Range indexの統計情報を保持

```swift
import Foundation

/// Range indexの統計情報
public struct RangeIndexStatistics: Sendable, Codable {
    /// 総レコード数
    public let totalRecords: UInt64

    /// Rangeの平均幅（秒単位）
    public let avgRangeWidth: Double

    /// Overlap factor（平均何個のRangeが重複しているか）
    public let overlapFactor: Double

    /// 典型的なクエリに対する選択性（0.0-1.0）
    public let selectivity: Double

    /// 統計収集日時
    public let collectedAt: Date

    public init(
        totalRecords: UInt64,
        avgRangeWidth: Double,
        overlapFactor: Double,
        selectivity: Double,
        collectedAt: Date = Date()
    ) {
        self.totalRecords = totalRecords
        self.avgRangeWidth = avgRangeWidth
        self.overlapFactor = overlapFactor
        self.selectivity = selectivity
        self.collectedAt = collectedAt
    }
}
```

#### 3.2.2 修正ファイル: `Sources/FDBRecordLayer/Statistics/StatisticsManager.swift`

**変更箇所**: Range統計の収集と取得

```swift
extension StatisticsManager {

    /// Range indexの統計を収集
    /// - Parameters:
    ///   - index: 対象インデックス
    ///   - sampleRate: サンプリングレート（0.01 = 1%）
    public func collectRangeStatistics(
        index: Index,
        sampleRate: Double = 0.01
    ) async throws {
        guard index.type == .value else {
            throw RecordLayerError.invalidArgument("Index must be of type .value")
        }

        var totalRecords: UInt64 = 0
        var totalWidth: Double = 0
        var overlapCounts: [Int] = []

        try await database.withTransaction { transaction in
            // インデックス全体をサンプリング
            let indexRange = indexSubspace.subspace(index.name).range()
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(indexRange.begin),
                endSelector: .firstGreaterOrEqual(indexRange.end),
                snapshot: true
            )

            for try await (key, _) in sequence {
                // サンプリング判定
                guard Double.random(in: 0..<1) < sampleRate else { continue }

                totalRecords += 1

                // キーから Range を抽出
                let tuple = try indexSubspace.subspace(index.name).unpack(key)
                guard let lowerBound = tuple[0] as? Date,
                      let upperBound = tuple[1] as? Date else { continue }

                let width = upperBound.timeIntervalSince(lowerBound)
                totalWidth += width

                // Overlap countを計算（同じ時間範囲に何個のRangeがあるか）
                let overlapCount = try await countOverlaps(
                    in: lowerBound..<upperBound,
                    index: index,
                    transaction: transaction
                )
                overlapCounts.append(overlapCount)
            }
        }

        // 統計を計算
        let avgRangeWidth = totalRecords > 0 ? totalWidth / Double(totalRecords) : 0
        let avgOverlapFactor = overlapCounts.isEmpty ? 1.0 : Double(overlapCounts.reduce(0, +)) / Double(overlapCounts.count)

        // 選択性を推定（簡易的な計算）
        // selectivity = avgRangeWidth / (totalTimeSpan * overlapFactor)
        let selectivity = estimateSelectivity(
            avgRangeWidth: avgRangeWidth,
            overlapFactor: avgOverlapFactor,
            totalRecords: totalRecords
        )

        let stats = RangeIndexStatistics(
            totalRecords: totalRecords,
            avgRangeWidth: avgRangeWidth,
            overlapFactor: avgOverlapFactor,
            selectivity: selectivity
        )

        // 統計を保存
        try await saveStatistics(indexName: index.name, stats: stats, transaction: transaction)
    }

    /// Range indexの統計を取得
    public func getRangeStatistics(indexName: String) async throws -> RangeIndexStatistics? {
        return try await database.withTransaction { transaction in
            let statsKey = statsSubspace.pack(Tuple("range", indexName))
            guard let data = try await transaction.getValue(for: statsKey, snapshot: true) else {
                return nil
            }

            let decoder = JSONDecoder()
            return try decoder.decode(RangeIndexStatistics.self, from: Data(data))
        }
    }

    /// Range indexの選択性を推定
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: Range<Date>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5  // デフォルト値
        }

        // クエリRange幅
        let queryWidth = queryRange.upperBound.timeIntervalSince(queryRange.lowerBound)

        // 選択性 = (queryWidth / avgRangeWidth) * overlapFactor * baseSelectivity
        let selectivity = (queryWidth / stats.avgRangeWidth) * stats.overlapFactor * stats.selectivity

        return min(selectivity, 1.0)  // 最大1.0
    }

    // ヘルパーメソッド
    private func countOverlaps(
        in range: Range<Date>,
        index: Index,
        transaction: TransactionProtocol
    ) async throws -> Int {
        // 簡易実装: Rangeに重複する他のRangeをカウント
        let indexRange = indexSubspace.subspace(index.name).range()
        var count = 0

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(indexRange.begin),
            endSelector: .firstGreaterOrEqual(indexRange.end),
            snapshot: true
        )

        for try await (key, _) in sequence {
            let tuple = try indexSubspace.subspace(index.name).unpack(key)
            guard let lowerBound = tuple[0] as? Date,
                  let upperBound = tuple[1] as? Date else { continue }

            // 重複判定
            if lowerBound < range.upperBound && upperBound > range.lowerBound {
                count += 1
            }
        }

        return count
    }

    private func estimateSelectivity(
        avgRangeWidth: Double,
        overlapFactor: Double,
        totalRecords: UInt64
    ) -> Double {
        // 簡易的な選択性推定
        // selectivity = 1 / (overlapFactor * sqrt(totalRecords))
        let selectivity = 1.0 / (overlapFactor * sqrt(Double(totalRecords)))
        return min(selectivity, 1.0)
    }
}
```

#### 3.2.3 修正ファイル: `Sources/FDBRecordLayer/Query/TypedRecordQueryPlanner.swift`

**変更箇所**: 統計を使用して子プランの順序を最適化

```swift
func planIntersection(filters: [Filter]) async throws -> any TypedQueryPlan<Record> {
    // ...（Pre-filtering処理）

    // 各フィルタのプランと選択性を計算
    var childPlans: [(plan: any TypedQueryPlan<Record>, selectivity: Double)] = []

    for filter in filters {
        guard let indexPlan = tryIndexPlan(filter: filter, window: intersectionWindow) else {
            continue
        }

        // 選択性を推定
        let selectivity: Double
        if let rangeFilter = filter as? RangeOverlapsFilter {
            selectivity = try await statisticsManager.estimateRangeSelectivity(
                indexName: rangeFilter.indexName,
                queryRange: rangeFilter.queryRange
            )
        } else {
            selectivity = try await statisticsManager.estimateSelectivity(
                index: filter.index,
                filters: [filter]
            )
        }

        childPlans.append((indexPlan, selectivity))
    }

    // 選択性が高い順（結果が少ない順）にソート
    childPlans.sort { $0.selectivity > $1.selectivity }

    return TypedIntersectionPlan(children: childPlans.map(\\.plan))
}
```

### 3.3 テスト戦略

#### 3.3.1 統計収集テスト

**ファイル**: `Tests/FDBRecordLayerTests/Statistics/RangeStatisticsTests.swift`

```swift
@Suite("Range Statistics Tests")
struct RangeStatisticsTests {

    @Test("Collect range statistics")
    func testCollectRangeStatistics() async throws {
        // Setup: 1000件のイベントを作成
        for i in 0..<1000 {
            let lowerBound = Date(timeIntervalSince1970: Double(i * 86400))
            let upperBound = lowerBound.addingTimeInterval(86400)  // 1日
            let event = Event(id: Int64(i), period: lowerBound..<upperBound, title: "Event \(i)")
            try await store.save(event)
        }

        // 統計収集
        let index = Index(name: "event_by_period", type: .value, ...)
        try await statisticsManager.collectRangeStatistics(index: index, sampleRate: 0.1)

        // 統計取得
        let stats = try await statisticsManager.getRangeStatistics(indexName: "event_by_period")

        // 検証
        #expect(stats?.totalRecords ?? 0 > 0)
        #expect(stats?.avgRangeWidth == 86400)  // 1日
        #expect(stats?.overlapFactor > 0)
        #expect(stats?.selectivity > 0 && stats?.selectivity <= 1.0)
    }

    @Test("Estimate range selectivity")
    func testEstimateRangeSelectivity() async throws {
        // Setup: 統計収集済み
        let queryRange = Date()..<Date().addingTimeInterval(86400)

        let selectivity = try await statisticsManager.estimateRangeSelectivity(
            indexName: "event_by_period",
            queryRange: queryRange
        )

        // 検証: selectivityが妥当な範囲
        #expect(selectivity > 0 && selectivity <= 1.0)
    }
}
```

#### 3.3.2 プラン最適化テスト

**ファイル**: `Tests/FDBRecordLayerTests/Query/SelectivityOptimizationTests.swift`

```swift
@Suite("Selectivity-based Plan Optimization Tests")
struct SelectivityOptimizationTests {

    @Test("High selectivity plan executed first")
    func testHighSelectivityFirst() async throws {
        // Setup:
        // - Index1 (period overlap): 10,000件（selectivity = 0.5）
        // - Index2 (category): 200件（selectivity = 0.01）

        let query = QueryBuilder<Event>()
            .filter(\\.period, .overlaps, queryPeriod)
            .filter(\\.category, .equals, "Electronics")
            .build()

        let plan = try await planner.plan(query: query)

        // 検証: IntersectionPlanの子順序
        guard let intersectionPlan = plan as? TypedIntersectionPlan<Event> else {
            throw TestError.planTypeMismatch
        }

        // categoryインデックスが先に実行されるべき
        let firstChild = intersectionPlan.children[0]
        #expect(firstChild.indexName == "event_by_category")

        // IO削減を確認
        let results = try await plan.execute(...)
        let ioCount = getIOCount()
        #expect(ioCount < 1000)  // 期待値: 400件（200 + 200）
    }
}
```

### 3.4 成功指標

- ✅ `StatisticsManager.collectRangeStatistics()` が正しく統計を収集
- ✅ `StatisticsManager.estimateRangeSelectivity()` が妥当な選択性を返す
- ✅ TypedIntersectionPlanの子順序が選択性に基づいて最適化される
- ✅ 複数インデックスクエリでIO削減率 10-30%
- ✅ 既存テスト + 新規テスト全合格

### 3.5 ロールバック計画

Phase 3が失敗した場合:
1. `RangeIndexStatistics.swift` を削除
2. `StatisticsManager` の Range統計関連メソッドを削除
3. `TypedRecordQueryPlanner` の統計ベース最適化を元に戻す（任意の順序に戻す）

---

## 全体スケジュールとマイルストーン

### Week 1-2: Phase 1 (Pre-filtering)
- **Week 1**:
  - Day 1-2: RangeWindowCalculator実装 + テスト
  - Day 3-4: TypedRecordQueryPlanner修正
  - Day 5: TypedIndexScanPlan修正
- **Week 2**:
  - Day 1-2: 統合テスト作成
  - Day 3-4: パフォーマンス検証
  - Day 5: ドキュメント更新

**マイルストーン**: Phase 1完了、IO削減率70%達成

### Week 3-5: Phase 2 (Covering Indexes)
- **Week 3**:
  - Day 1-2: #RangeIndex マクロ拡張
  - Day 3-4: Index.coveringFields追加
  - Day 5: RangeIndexMaintainer修正
- **Week 4**:
  - Day 1-3: TypedCoveringIndexScanPlan実装
  - Day 4-5: マクロテスト作成
- **Week 5**:
  - Day 1-3: 統合テスト作成
  - Day 4: パフォーマンス検証
  - Day 5: ドキュメント更新

**マイルストーン**: Phase 2完了、レコードフェッチ削減率50%達成

### Week 6-8: Phase 3 (Range Selectivity Statistics)
- **Week 6**:
  - Day 1-2: RangeIndexStatistics実装
  - Day 3-5: StatisticsManager拡張
- **Week 7**:
  - Day 1-3: TypedRecordQueryPlanner最適化
  - Day 4-5: 統計収集テスト作成
- **Week 8**:
  - Day 1-3: プラン最適化テスト作成
  - Day 4: パフォーマンス検証
  - Day 5: 最終ドキュメント更新

**マイルストーン**: Phase 3完了、全体で90-97% IO削減達成

---

## パフォーマンス測定計画

### 測定指標

| 指標 | 測定方法 | 目標値 |
|------|---------|--------|
| **IO削減率** | getRange()呼び出し回数 | Phase 1: 70%, Phase 2: 50%, Phase 3: 10-30% |
| **レスポンス時間** | クエリ実行時間 | 50%短縮 |
| **インデックスサイズ** | Covering indexのキーサイズ | 10KB以下（制限内） |
| **統計収集時間** | collectRangeStatistics()実行時間 | 10,000件で10秒以内 |

### ベンチマークシナリオ

1. **シナリオ1: 2つのRange overlap**
   - データ: 10,000件のイベント
   - クエリ: `overlaps(period1) AND overlaps(period2)`
   - 期待: IO削減率 70%

2. **シナリオ2: Range overlap + titleフィルタ**
   - データ: 10,000件のイベント
   - クエリ: `overlaps(period) AND title.contains("Meeting")`
   - 期待: レコードフェッチ削減率 80%

3. **シナリオ3: 複数インデックス交差**
   - データ: 10,000件のイベント
   - クエリ: `overlaps(period) AND category == "Work"`
   - 期待: 最適な実行順序、IO削減率 30%

---

## リスク管理

### 主要リスク

| リスク | 影響度 | 対策 |
|--------|--------|------|
| **Phase 1: 交差なしの検出漏れ** | 中 | 徹底的なエッジケーステスト |
| **Phase 2: Covering indexのキーサイズ超過** | 高 | coveringフィールド数を制限（最大3個） |
| **Phase 3: 統計の精度不足** | 中 | サンプリングレートを調整可能に |
| **全体: 既存テストの回帰** | 高 | 各Phase完了時に全テスト実行 |

### 品質保証

- ✅ 各Phase完了時に全525テストを実行
- ✅ 新規テストを各Phase 10個以上追加
- ✅ パフォーマンステストで目標値達成を確認
- ✅ コードレビュー（特にSubspace.pack() vs subspace()の誤用チェック）

---

## 最終目標

**全Phase完了後の期待効果**:

| 項目 | 改善率 |
|------|--------|
| **IO削減** | 90-97% |
| **CPU削減** | 60-80% |
| **レスポンス時間** | 50-70%短縮 |
| **インデックスサイズ** | +10%（Covering indexによる増加） |

**テスト目標**: 全テスト合格（525 + 新規30テスト = 555テスト）

---

**Last Updated**: 2025-01-13
**Author**: Claude Code
**Status**: Ready for implementation
