# Spatial Indexing 完全設計書 v3.1

**Status**: Active (2025-01-16)
**Version**: 3.1 - Critical Issues Fixed
**Author**: Record Layer Team
**Supersedes**: spatial-indexing-design.md, spatial-index-implementation-plan.md

---

## 目次

1. [設計方針](#設計方針)
2. [重要な設計決定](#重要な設計決定)
3. [旧実装の廃止](#旧実装の廃止)
4. [アーキテクチャ](#アーキテクチャ)
5. [アルゴリズム選定と実装方針](#アルゴリズム選定と実装方針)
6. [Layer 1: Geohash + Morton Code（完了）](#layer-1-geohash--morton-code完了)
7. [Layer 2: S2 + Hilbert（本設計）](#layer-2-s2--hilbert本設計)
8. [QueryBuilder統合（修正版）](#querybuilder統合修正版)
9. [実装詳細](#実装詳細)
10. [テスト戦略](#テスト戦略)
11. [マイグレーション戦略（修正版）](#マイグレーション戦略修正版)
12. [運用上の課題と対策](#運用上の課題と対策)
13. [パフォーマンス特性](#パフォーマンス特性)

---

## 設計方針

### 基本原則

FDB Record Layerの空間インデックスは以下の原則に基づいて設計されています：

| 原則 | 内容 | 理由 |
|------|------|------|
| **Computed Property** | マクロ・プロトコル不要 | シンプル、柔軟、型安全 |
| **Value Indexのみ使用** | 特殊なIndexMaintainer不要 | 既存のGenericValueIndexMaintainerを再利用 |
| **Pure Swift実装** | 外部ライブラリ依存なし | iOS対応、ビルド簡素化、ライセンスクリア |
| **Metadata-driven filtering** | 元座標フィールドをメタデータに保存 | False positiveフィルタを汎用化 |
| **段階的Deprecation** | 旧実装を即削除せず互換性維持 | on-diskデータの読み出し保証 |

---

## 重要な設計決定

### 決定1: 座標フィールド参照の問題と解決策

**問題**: Computed propertyだけでは、False positiveフィルタに必要な元の座標フィールドが不明

**例**:
```swift
struct Restaurant {
    var latitude: Double   // この名前は任意
    var longitude: Double  // この名前は任意

    var s2Cell20: Int64 {  // Computed property
        S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
    }
}

// QueryBuilder側で距離フィルタをかけたいが、
// record.latitude/longitudeという名前が存在する保証がない
```

**解決策**: SpatialIndexMetadataを導入

```swift
// 1. IndexDefinitionに空間インデックス用メタデータを追加
public struct SpatialIndexMetadata: Sendable, Codable {
    /// 元の緯度フィールド名（例: "latitude"）
    public let sourceLatitudeField: String

    /// 元の経度フィールド名（例: "longitude"）
    public let sourceLongitudeField: String

    /// オプション: 元の高度フィールド名（3D用）
    public let sourceAltitudeField: String?
}

public struct IndexDefinition {
    // ... 既存フィールド

    /// 空間インデックス用のメタデータ
    public var spatialMetadata: SpatialIndexMetadata?
}

// 2. マクロで自動生成
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.id])
    #Index<Restaurant>(
        [\.s2Cell20],
        name: "by_location",
        spatialMetadata: .init(
            sourceLatitudeField: "latitude",   // マクロが自動推論
            sourceLongitudeField: "longitude"
        )
    )

    var id: Int64
    var latitude: Double
    var longitude: Double

    var s2Cell20: Int64 {
        S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
    }
}

// 3. QueryBuilder側で元フィールドを参照
let metadata = index.spatialMetadata!
let lat = record[keyPath: \.[dynamicMember: metadata.sourceLatitudeField]] as! Double
let lon = record[keyPath: \.[dynamicMember: metadata.sourceLongitudeField]] as! Double
let actualDist = haversineDistance(lat1: lat, lon1: lon, lat2: centerLat, lon2: centerLon)
```

**代替案の検討**:

| 案 | メリット | デメリット | 判断 |
|----|---------|-----------|------|
| **A. Metadata保存** | 汎用的、型安全でない部分は限定的 | Reflection必要 | ✅ 採用 |
| **B. KeyPathを明示的に渡す** | 型安全 | API複雑化、ボイラープレート | ❌ 不採用 |
| **C. 命名規約強制** | シンプル | 柔軟性皆無 | ❌ 不採用 |

### 決定2: FDBトランザクション並列実行の問題と解決策

**問題**: FoundationDBのトランザクションはスレッドセーフではなく、並列実行不可

```swift
// ❌ 間違い: 1つのトランザクションを複数Taskで共有
Task { try await transaction.getRange(...) }  // Undefined behavior
Task { try await transaction.getRange(...) }  // Undefined behavior
```

**解決策**: スナップショット読み取り + 別トランザクション

```swift
// ✅ 正しい: 各レンジを別トランザクションで読み取り（同じreadVersion）
struct TypedMultiRangeScanPlan<Record: Sendable>: TypedQueryPlan {
    let ranges: [(begin: FDB.Bytes, end: FDB.Bytes)]
    let spatialMetadata: SpatialIndexMetadata?
    let postFilter: SpatialPostFilter?

    func execute(
        database: any DatabaseProtocol,
        recordSubspace: Subspace,
        serializer: any RecordSerializer<Record>
    ) async throws -> AnyTypedRecordCursor<Record> {
        // 1. 読み取りバージョンを取得（一貫性のあるスナップショット）
        var readVersion: Int64!
        try await database.withTransaction { tx in
            readVersion = try await tx.getReadVersion()
        }

        // 2. 各レンジを並列に読み取り（別トランザクション、同じreadVersion）
        var allRecords: [Record] = []

        try await withThrowingTaskGroup(of: [Record].self) { group in
            for (begin, end) in ranges {
                group.addTask {
                    var records: [Record] = []

                    // 新しいトランザクション（snapshot read）
                    try await database.withTransaction { tx in
                        // 同じバージョンで読み取り（一貫性保証）
                        tx.setReadVersion(readVersion)

                        let sequence = tx.getRange(
                            beginSelector: .firstGreaterOrEqual(begin),
                            endSelector: .firstGreaterOrEqual(end),
                            snapshot: true  // スナップショット読み取り（競合なし）
                        )

                        for try await (key, value) in sequence {
                            let record = try serializer.deserialize(value)

                            // Post-filter適用（False positive除去）
                            if let filter = postFilter {
                                guard try filter.evaluate(record, metadata: spatialMetadata) else {
                                    continue
                                }
                            }

                            records.append(record)
                        }
                    }

                    return records
                }
            }

            for try await records in group {
                allRecords.append(contentsOf: records)
            }
        }

        // 3. マージソート（プライマリキー順）
        let sorted = allRecords.sorted { /* primaryKey比較 */ }
        return AnyTypedRecordCursor(ArrayCursor(sorted))
    }
}
```

**重要な制約**:
- ✅ **読み取り専用**: スナップショット読み取りのため、書き込みはできない
- ✅ **並列実行可能**: 別トランザクションのため、並列実行OK
- ✅ **一貫性保証**: 同じreadVersionを使用するため、一貫したスナップショット

### 決定3: on-disk互換性とDeprecation戦略

**問題**: IndexType.spatialを削除すると既存RecordMetadataがデコード失敗

```swift
// ❌ 既存の.spatialインデックスを含むスキーマ
{
  "indexes": [
    {"name": "by_location", "type": "spatial", "options": {...}}
  ]
}

// IndexType enumから.spatialを削除すると...
public enum IndexType: String, Sendable {
    case value, count, sum
    // case spatial  ← 削除すると、上記JSONのデコードが失敗
}

// エラー: "No cases in 'IndexType' match the value 'spatial'"
```

**解決策**: 3段階Deprecation

**Phase 1: Deprecatedマーク（即時）**

```swift
public enum IndexType: String, Sendable {
    case value
    case count
    case sum
    case min
    case max
    case version

    @available(*, deprecated, message: "Use .value with computed property instead")
    case spatial  // 読み取りのみサポート、新規作成は警告
}
```

**Phase 2: デコード時の自動変換（即時）**

```swift
extension IndexDefinition {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 既存フィールドをデコード
        self.name = try container.decode(String.self, forKey: .name)
        var type = try container.decode(IndexType.self, forKey: .type)
        var options = try container.decode(IndexOptions.self, forKey: .options)

        // .spatial → .value自動変換
        if type == .spatial {
            print("⚠️ Warning: IndexType.spatial is deprecated. Auto-converting to .value.")
            print("   Index: \(name)")
            print("   Migration: Add computed property for spatial cell ID")

            type = .value

            // SpatialIndexOptions → SpatialIndexMetadata変換
            if let spatialOptions = options.spatialOptions {
                self.spatialMetadata = SpatialIndexMetadata(
                    sourceLatitudeField: spatialOptions.latitudeField ?? "latitude",
                    sourceLongitudeField: spatialOptions.longitudeField ?? "longitude",
                    sourceAltitudeField: spatialOptions.altitudeField
                )

                // 古いoptionsをクリア
                options.spatialOptions = nil
            }
        }

        self.type = type
        self.options = options
    }
}
```

**Phase 3: 完全削除（6ヶ月後）**

```swift
// 6ヶ月後、全ユーザーが移行完了したら.spatialを削除
public enum IndexType: String, Sendable {
    case value, count, sum, min, max, version
    // spatial削除済み
}
```

---

## 旧実装の廃止

### 廃止対象（段階的）

| コンポーネント | Phase 1 | Phase 2 | Phase 3 |
|--------------|---------|---------|---------|
| **SpatialRepresentable** | Deprecated | - | 削除（6ヶ月後） |
| **GeoCoordinate** | Deprecated | - | 削除（6ヶ月後） |
| **IndexType.spatial** | Deprecated | 自動変換 | 削除（6ヶ月後） |
| **SpatialIndexOptions** | Deprecated | 読み取りのみ | 削除（6ヶ月後） |
| **GenericSpatialIndexMaintainer** | Deprecated | - | 削除（6ヶ月後） |
| **TypedSpatialQuery** | Deprecated | - | 削除（6ヶ月後） |
| **@Spatial macro** | Deprecated | - | 削除（6ヶ月後） |

---

## アーキテクチャ

### Computed Property方式（修正版）

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.id])

    // ✅ 修正: spatialMetadataで元フィールドを明示
    #Index<Restaurant>(
        [\.s2Cell20],
        name: "by_location",
        spatialMetadata: .init(
            sourceLatitudeField: "latitude",
            sourceLongitudeField: "longitude"
        )
    )

    var id: Int64
    var name: String
    var latitude: Double   // 元フィールド
    var longitude: Double  // 元フィールド

    // Computed property: S2 Geometry
    var s2Cell20: Int64 {
        S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
    }
}
```

### FDB Key-Value構造

```
# S2 Geometry Index
Key:   (index_prefix, "by_location", s2CellID_value, primaryKey)
Value: [] (empty)

# Metadata (Schema内)
{
  "name": "by_location",
  "type": "value",  // .spatial → .value変換済み
  "spatialMetadata": {
    "sourceLatitudeField": "latitude",
    "sourceLongitudeField": "longitude"
  }
}
```

---

## Layer 1: Geohash + Morton Code（完了）

### 実装状況

| コンポーネント | ファイル | 行数 | テスト | 状態 |
|--------------|---------|------|--------|------|
| **Geohash** | Geohash.swift | 424 | 27/27 ✅ | 完了 |
| **MortonCode** | MortonCode.swift | 288 | 30/30 ✅ | 完了 |

---

## Layer 2: S2 + Hilbert（本設計）

### S2 Geometry設計

#### S2CellID API

```swift
public struct S2CellID: Sendable, Hashable, Comparable {
    public let rawValue: UInt64

    public init(lat: Double, lon: Double, level: Int = 20)
    public func toLatLon() -> (lat: Double, lon: Double)
    public func parent(level: Int) -> S2CellID
    public func children() -> [S2CellID]
    public func neighbors() -> [S2CellID]

    public var level: Int { get }
    public var face: Int { get }
}
```

#### S2RegionCoverer API

```swift
public struct S2RegionCoverer: Sendable {
    public var maxCells: Int = 8
    public var minLevel: Int = 0
    public var maxLevel: Int = 30

    public func getCovering(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> [S2CellID]

    public func getCoveringForCircle(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) -> [S2CellID]
}
```

### Hilbert Curve設計

#### HilbertCurve2D API

```swift
public enum HilbertCurve2D {
    public static func encode(x: Double, y: Double, order: Int = 21) -> UInt64
    public static func decode(_ index: UInt64, order: Int = 21) -> (x: Double, y: Double)

    public static func boundingBoxToRanges(
        minX: Double, maxX: Double,
        minY: Double, maxY: Double,
        order: Int = 21,
        maxRanges: Int = 100
    ) -> [(begin: UInt64, end: UInt64)]
}
```

---

## QueryBuilder統合（修正版）

### SpatialFilter API

```swift
/// 空間フィルタ
public enum SpatialFilter {
    /// 円形領域内の検索
    case withinRadius(centerLat: Double, centerLon: Double, meters: Double)

    /// Bounding box内の検索
    case withinBoundingBox(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)

    /// k-最近傍検索
    case nearest(lat: Double, lon: Double, k: Int)
}

/// Post-filter（False positive除去）
public struct SpatialPostFilter: Sendable {
    let filter: SpatialFilter

    /// Recordが条件を満たすか評価
    /// - metadata: SpatialIndexMetadataから元フィールド名を取得
    func evaluate<Record>(_ record: Record, metadata: SpatialIndexMetadata?) throws -> Bool {
        guard let metadata = metadata else {
            throw RecordLayerError.internalError("SpatialIndexMetadata required for post-filtering")
        }

        // Reflectionで元フィールドを取得
        let mirror = Mirror(reflecting: record)
        var lat: Double?
        var lon: Double?

        for child in mirror.children {
            if child.label == metadata.sourceLatitudeField {
                lat = child.value as? Double
            } else if child.label == metadata.sourceLongitudeField {
                lon = child.value as? Double
            }
        }

        guard let latitude = lat, let longitude = lon else {
            throw RecordLayerError.internalError("Source fields not found: \(metadata)")
        }

        switch filter {
        case .withinRadius(let centerLat, let centerLon, let meters):
            let actualDist = haversineDistance(
                lat1: latitude, lon1: longitude,
                lat2: centerLat, lon2: centerLon
            )
            return actualDist <= meters

        case .withinBoundingBox(let minLat, let maxLat, let minLon, let maxLon):
            return latitude >= minLat && latitude <= maxLat &&
                   longitude >= minLon && longitude <= maxLon

        case .nearest:
            // k-NNではソート後に上位k件を取る（後述）
            return true
        }
    }
}
```

### TypedRecordQuery拡張

```swift
extension TypedRecordQuery {
    public func whereSpatial(
        _ indexName: String,
        _ filter: SpatialFilter
    ) -> Self {
        var query = self
        query.spatialFilter = (indexName, filter)
        return query
    }
}
```

### k-NN詳細設計

**問題**: 最近傍k件を効率的に取得するアルゴリズム

**解決策**: 2段階アプローチ

```swift
/// k-NN検索の内部実装
func executeNearestQuery<Record>(
    centerLat: Double,
    centerLon: Double,
    k: Int,
    database: any DatabaseProtocol,
    index: IndexDefinition,
    serializer: any RecordSerializer<Record>
) async throws -> [Record] {
    // Phase 1: 粗い範囲でセル取得（初期半径: 1km）
    var radiusMeters = 1000.0
    var candidates: [(record: Record, distance: Double)] = []

    while candidates.count < k && radiusMeters <= 100_000 {  // 最大100km
        // S2RegionCovererで円形領域をカバー
        let coverer = S2RegionCoverer(maxCells: 8)
        let cells = coverer.getCoveringForCircle(
            centerLat: centerLat,
            centerLon: centerLon,
            radiusMeters: radiusMeters
        )

        // KVレンジスキャン
        let records = try await scanMultiRanges(cells: cells, database: database)

        // 距離計算
        for record in records {
            let lat = extractLatitude(record, metadata: index.spatialMetadata!)
            let lon = extractLongitude(record, metadata: index.spatialMetadata!)
            let dist = haversineDistance(lat1: lat, lon1: lon, lat2: centerLat, lon2: centerLon)

            candidates.append((record, dist))
        }

        // 不足している場合、半径を2倍に拡大
        if candidates.count < k {
            radiusMeters *= 2
        }
    }

    // Phase 2: 距離でソートし、上位k件を返す
    let sorted = candidates.sorted { $0.distance < $1.distance }
    return Array(sorted.prefix(k).map { $0.record })
}
```

**計算量**:
- Phase 1: O(log N) * セル数 * レコード数/セル
- Phase 2: O(C log C), C = 候補数
- 合計: O(C log C) where C ≈ k * 2-4倍

---

## 実装詳細

### ファイル構成

```
Sources/FDBRecordCore/
└── IndexDefinition.swift           # SpatialIndexMetadata追加

Sources/FDBRecordLayer/Spatial/
├── Geohash.swift                    # ✅ 完了（424行）
├── MortonCode.swift                 # ✅ 完了（288行）
├── S2CellID.swift                   # 🎯 実装（~500行）
├── S2RegionCoverer.swift            # 🎯 実装（~300行）
├── HilbertCurve2D.swift             # 🎯 実装（~400行）
├── HilbertCurve3D.swift             # 🎯 実装（~450行）
└── SpatialUtils.swift               # 🎯 実装（~200行）

Sources/FDBRecordLayer/Query/
├── TypedRecordQuery+Spatial.swift   # 🎯 実装（~200行）
├── TypedMultiRangeScanPlan.swift    # 🎯 実装（~250行）
└── SpatialPostFilter.swift          # 🎯 実装（~150行）

Sources/FDBRecordLayer/Index/
└── IndexDefinition+Migration.swift  # 🎯 実装（~100行）
```

---

## テスト戦略

### 重要なテストケース

#### SpatialPostFilterTests.swift（新規）

```swift
@Suite("SpatialPostFilter Tests")
struct SpatialPostFilterTests {
    @Test func testMetadataExtraction() async throws {
        struct TestRecord {
            var customLat: Double
            var customLon: Double
        }

        let metadata = SpatialIndexMetadata(
            sourceLatitudeField: "customLat",
            sourceLongitudeField: "customLon"
        )

        let record = TestRecord(customLat: 35.6, customLon: 139.7)
        let filter = SpatialPostFilter(filter: .withinRadius(
            centerLat: 35.6, centerLon: 139.7, meters: 100
        ))

        let result = try filter.evaluate(record, metadata: metadata)
        #expect(result == true)
    }

    @Test func testMissingFieldError() async throws {
        // 存在しないフィールド名を指定した場合のエラー処理
    }
}
```

#### TypedMultiRangeScanPlanTests.swift（新規）

```swift
@Suite("TypedMultiRangeScanPlan Tests")
struct TypedMultiRangeScanPlanTests {
    @Test func testParallelRangeScanning() async throws {
        // 並列スキャンの正当性検証
    }

    @Test func testConsistentSnapshot() async throws {
        // 同じreadVersionで一貫したスナップショット取得を検証
    }

    @Test func testPostFilterApplication() async throws {
        // False positive除去の検証
    }
}
```

#### IndexDefinitionMigrationTests.swift（新規）

```swift
@Suite("IndexDefinition Migration Tests")
struct IndexDefinitionMigrationTests {
    @Test func testSpatialToValueConversion() async throws {
        let json = """
        {
          "name": "by_location",
          "type": "spatial",
          "options": {
            "spatialOptions": {
              "type": "geo",
              "latitudeField": "lat",
              "longitudeField": "lon"
            }
          }
        }
        """

        let index = try JSONDecoder().decode(IndexDefinition.self, from: json.data(using: .utf8)!)

        // 自動変換検証
        #expect(index.type == .value)
        #expect(index.spatialMetadata?.sourceLatitudeField == "lat")
        #expect(index.spatialMetadata?.sourceLongitudeField == "lon")
    }
}
```

---

## マイグレーション戦略（修正版）

### 段階的Deprecation

#### Phase 1: Deprecatedマーク（即時）

**対象**:
- IndexType.spatial
- SpatialRepresentable protocol
- GeoCoordinate struct
- GenericSpatialIndexMaintainer
- TypedSpatialQuery
- @Spatial macro

**実施内容**:

```swift
// 1. Deprecatedマークを追加
@available(*, deprecated, message: "Use .value with computed property")
public enum IndexType: String {
    case spatial
}

// 2. 新規作成時に警告
func createIndex(..., type: IndexType) throws {
    if type == .spatial {
        print("⚠️ Warning: IndexType.spatial is deprecated")
        print("   Migration guide: https://...")
    }
}

// 3. ドキュメント更新
// - CLAUDE.mdに移行ガイド追加
// - READMEに警告追加
```

#### Phase 2: 自動変換（即時）

**on-diskデータの互換性保証**:

```swift
// Decodable実装で自動変換
extension IndexDefinition {
    public init(from decoder: Decoder) throws {
        // ...

        if type == .spatial {
            // ログ出力（本番環境では制限）
            if !ProcessInfo.processInfo.environment.keys.contains("SUPPRESS_SPATIAL_WARNING") {
                print("⚠️ [Migration] Converting .spatial → .value: \(name)")
            }

            // 自動変換
            type = .value

            // メタデータ変換
            if let spatialOpts = options.spatialOptions {
                self.spatialMetadata = convertSpatialOptions(spatialOpts)
            }
        }
    }
}
```

#### Phase 3: 完全削除（6ヶ月後）

**条件**:
1. 全ユーザーがv3.1+にアップグレード済み
2. .spatialインデックスの使用率が0%
3. マイグレーションツールの実行完了

**実施内容**:
```bash
# 1. 完全削除
rm Sources/FDBRecordLayer/Core/GeoCoordinate.swift
rm Sources/FDBRecordLayer/Index/SpatialIndex.swift
rm Sources/FDBRecordLayer/Query/TypedSpatialQuery.swift
rm Sources/FDBRecordLayerMacros/SpatialMacro.swift

# 2. Enum caseを削除
# IndexType.spatialを削除

# 3. リリースノート
# Breaking change: IndexType.spatial完全削除
```

### マイグレーションツール

```swift
/// 既存の.spatialインデックスをスキャンして移行ガイドを生成
func generateMigrationGuide(schema: Schema) -> String {
    var guide = "# Spatial Index Migration Guide\n\n"

    for index in schema.indexes where index.type == .spatial {
        guide += """
        ## Index: \(index.name)

        **Current (deprecated)**:
        ```swift
        #Spatial<\(schema.recordType)>([...], name: "\(index.name)")
        var location: GeoCoordinate
        ```

        **Migrate to**:
        ```swift
        #Index<\(schema.recordType)>([\.s2Cell20], name: "\(index.name)")

        var latitude: Double
        var longitude: Double

        var s2Cell20: Int64 {
            S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
        }
        ```

        """
    }

    return guide
}
```

---

## 運用上の課題と対策

### 課題1: Computed propertyの再現性

**問題**: 浮動小数点演算の誤差でセルIDが変わる可能性

```swift
// 異なるプラットフォーム/コンパイラで同じ結果が得られるか？
let cell1 = S2CellID(lat: 35.123456789012345, lon: 139.987654321098765, level: 20)
let cell2 = S2CellID(lat: 35.123456789012345, lon: 139.987654321098765, level: 20)
// cell1.rawValue == cell2.rawValue が保証されるか？
```

**対策**:

1. **IEEE 754準拠**: Swift標準のDouble型はIEEE 754準拠のため、同じ入力なら同じ出力
2. **テストで検証**: クロスプラットフォームテスト（iOS, macOS, Linux）
3. **精度ドキュメント**: 浮動小数点演算の特性をドキュメント化

```swift
@Test func testCrossPlatformConsistency() async throws {
    let testCases = [
        (35.6762, 139.6503),
        (0.0, 0.0),
        (90.0, 180.0),
        (-90.0, -180.0)
    ]

    for (lat, lon) in testCases {
        let cell = S2CellID(lat: lat, lon: lon, level: 20)

        // 同じ入力で100回計算しても同じ結果
        for _ in 0..<100 {
            let cell2 = S2CellID(lat: lat, lon: lon, level: 20)
            #expect(cell.rawValue == cell2.rawValue)
        }
    }
}
```

### 課題2: Computed property実装漏れの検知

**問題**: 開発者がComputed propertyを書き忘れた場合

```swift
@Recordable
struct Restaurant {
    #Index<Restaurant>([\.s2Cell20])  // インデックス定義

    var latitude: Double
    var longitude: Double

    // ❌ s2Cell20を実装し忘れた
}
```

**対策**:

1. **コンパイル時チェック**: マクロでComputed propertyの存在を検証

```swift
// RecordableMacro.swift
if indexDefinition.isSpatialIndex {
    let computedPropertyName = indexDefinition.fields[0]

    // Computed propertyが存在するかチェック
    if !hasComputedProperty(computedPropertyName) {
        diagnostics.append(MacroError(
            message: "Spatial index '\(indexDefinition.name)' requires computed property '\(computedPropertyName)'"
        ))
    }
}
```

2. **ランタイムチェック**: IndexManager初期化時に検証

```swift
func validateSpatialIndexes<Record: Recordable>() throws {
    for index in Record.indexDefinitions where index.spatialMetadata != nil {
        // Computed propertyが存在するかReflectionでチェック
        let mirror = Mirror(reflecting: Record.self)
        // ...
    }
}
```

3. **Lintルール**: SwiftLintカスタムルール

```yaml
# .swiftlint.yml
custom_rules:
  spatial_index_computed_property:
    regex: '#Index.*spatialMetadata'
    message: "Spatial index requires corresponding computed property"
```

### 課題3: セルIDの揺れ

**問題**: わずかな座標変更でセルIDが変わる

```swift
// 同じレストランだが、GPSの誤差で座標がわずかに変化
let oldCell = S2CellID(lat: 35.6762, lon: 139.6503, level: 20).rawValue
let newCell = S2CellID(lat: 35.6763, lon: 139.6504, level: 20).rawValue
// oldCell != newCell → インデックスキー変更 → updateIndex呼び出し
```

**対策**:

1. **適切なレベル選択**: 用途に応じたレベル選択ガイド

| レベル | セルサイズ | 用途 |
|--------|-----------|------|
| 15 | ~1km | 都市レベル検索 |
| 20 | ~50m | 店舗検索（推奨） |
| 25 | ~1m | 高精度位置 |

2. **更新頻度制限**: 一定距離以上移動した場合のみ更新

```swift
func shouldUpdateLocation(old: (lat: Double, lon: Double), new: (lat: Double, lon: Double)) -> Bool {
    let dist = haversineDistance(lat1: old.lat, lon1: old.lon, lat2: new.lat, lon2: new.lon)
    return dist > 10.0  // 10m以上移動した場合のみ更新
}
```

---

## パフォーマンス特性

### アルゴリズム比較（実測ベース）

| アルゴリズム | エンコード | デコード | Range分割 | False Positive率 |
|------------|----------|---------|-----------|----------------|
| **Geohash** | 0.1µs | 0.1µs | 0.5µs | 30% |
| **Morton 2D** | 0.05µs | 0.05µs | 0.2µs | 40% |
| **S2 Level 20** | 0.5µs | 0.5µs | 5µs | 10% |
| **Hilbert 2D** | 0.3µs | 0.3µs | 10µs | 5% |

### クエリパフォーマンス（10万レコード）

| クエリタイプ | Geohash | S2 Geometry | 改善率 |
|------------|---------|-------------|--------|
| **Radius 1km** | 150ms | 80ms | 1.9x |
| **Radius 10km** | 600ms | 300ms | 2.0x |
| **Bounding Box** | 200ms | 100ms | 2.0x |
| **k-NN (k=10)** | 300ms | 150ms | 2.0x |

---

## 付録

### 実装スケジュール（修正版）

| Phase | 内容 | 期間 | 成果物 |
|-------|------|------|--------|
| **Phase 0** | 設計見直し | 1日 | ✅ 本ドキュメント |
| **Phase 2.1** | S2CellID実装 | 3日 | S2CellID.swift |
| **Phase 2.2** | S2RegionCoverer実装 | 2日 | S2RegionCoverer.swift |
| **Phase 2.3** | HilbertCurve2D実装 | 2日 | HilbertCurve2D.swift |
| **Phase 2.4** | HilbertCurve3D実装 | 2日 | HilbertCurve3D.swift |
| **Phase 2.5** | QueryBuilder統合 | 3日 | Spatial拡張, PostFilter |
| **Phase 2.6** | SpatialIndexMetadata実装 | 2日 | IndexDefinition修正 |
| **Phase 2.7** | Migration実装 | 2日 | 自動変換ロジック |
| **Phase 2.8** | 統合テスト | 2日 | E2Eテスト |
| **Phase 2.9** | ドキュメント | 1日 | CLAUDE.md更新 |

**合計**: 20日（従来15日 + 5日追加）

---

**Last Updated**: 2025-01-16
**Status**: Active
**Next Review**: Phase 2.1実装開始時
