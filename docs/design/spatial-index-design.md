# SPATIAL Index Design (空間インデックス)

## 概要

Swift版Record LayerにSPATIALインデックスを実装し、地理空間データの高速な範囲検索を提供します。**Z-order curve（モートン曲線）**を使用して、2D/3D座標を1次元キーにマッピングし、FoundationDBの順序付きキー空間を活用します。

## 背景

### 地理空間検索の用途

1. **位置ベース検索**: 「現在地から5km以内のレストラン」
2. **地図アプリ**: 表示範囲内のポイント検索
3. **配送最適化**: 配達エリア内の注文検索
4. **ジオフェンシング**: 特定エリアへの出入り検知
5. **不動産検索**: 地域・価格帯での物件検索

### なぜZ-order Curveか

| 手法 | 次元削減 | 局所性保持 | 実装複雑度 | 用途 |
|------|---------|-----------|----------|------|
| **Z-order (Morton)** | ✅ | 良い | 低 | 汎用的 |
| **Hilbert Curve** | ✅ | 最良 | 高 | 高精度が必要 |
| **Geohash** | ✅ | 良い | 低 | 緯度経度専用 |
| **Quadtree** | ❌ | 最良 | 中 | 動的な階層 |

**Z-order Curve**は**実装が簡単**で**十分な局所性**を持ち、FoundationDBの順序付きキー空間と相性が良いです。

---

## Z-order Curveの原理

### 1. ビットインターリーブ

Z-order curveは、X座標とY座標のビットを交互に配置します：

```
X = 10 (binary: 1010)
Y = 13 (binary: 1101)

Z-order key:
  X: 1  0  1  0
  Y: 1  1  0  1
  Z: 11 01 10 01 (binary) = 213 (decimal)

ビット配置: YXYX YXYX
```

**特性**:
- 近い座標は近いZ値を持つ（局所性保持）
- ビット演算で高速に計算可能
- 可逆変換（Z ⇔ (X, Y)）

### 2. 空間の分割パターン

Z-order curveは空間を再帰的に4分割（Quadtree）します：

```
Level 0:              Level 1:            Level 2:
┌──────────┐          ┌─────┬─────┐       ┌──┬──┬──┬──┐
│          │          │ 2 │ 3 │       │00│01│04│05│
│    0     │    →    ├─────┼─────┤  →  ├──┼──┼──┼──┤
│          │          │ 0 │ 1 │       │02│03│06│07│
└──────────┘          └─────┴─────┘       ├──┼──┼──┼──┤
                                           │08│09│12│13│
                                           ├──┼──┼──┼──┤
                                           │10│11│14│15│
                                           └──┴──┴──┴──┘
```

各セルのZ値は、親セルの値を引き継ぎながら4方向に分岐します。

### 3. 範囲クエリの効率化

矩形範囲クエリは、複数のZ-orderサブレンジに分解されます：

```
検索範囲:
┌──────────────┐
│   ┌────┐     │
│   │ Q  │     │  Q: 検索範囲
│   └────┘     │
└──────────────┘

Z-orderサブレンジ:
[z1, z2), [z3, z4), [z5, z6)  ← 3つのRange読み取り
```

**トレードオフ**:
- 小さい範囲: 少数のRange（効率的）
- 大きい範囲: 多数のRange（フィルタリングが必要）

---

## FoundationDBへのマッピング

### 1. データモデル

**キー構造**:

```
# Z-order → レコード（双方向マッピング）
[spatialIndexSubspace]["z"][z_value][recordID] = []

# レコード → Z-order（逆引き）
[spatialIndexSubspace]["r"][recordID] = z_value

# バウンディングボックス（オプション）
[spatialIndexSubspace]["bbox"][recordID] = {
    "minX": Double,
    "minY": Double,
    "maxX": Double,
    "maxY": Double
}

# 統計情報
[spatialIndexSubspace]["stats"]["count"] = Int
[spatialIndexSubspace]["stats"]["bounds"] = {
    "minX": Double, "minY": Double,
    "maxX": Double, "maxY": Double
}
```

**設計上の選択**:

1. **双方向マッピング**: 更新時に既存のZ値を高速に検索
2. **複合キー**: `[z_value][recordID]`で同一Z値の複数レコードに対応
3. **バウンディングボックス**: ポリゴンなどの複雑な形状に対応

### 2. 精度とスケール

**座標の正規化**:

```swift
// 緯度経度を32ビット整数に変換
latitude:  -90.0 ~ 90.0  → 0 ~ 2^32
longitude: -180.0 ~ 180.0 → 0 ~ 2^32

// 精度: 32ビット → 約1cm（地球上）
```

**Z値のビット長**: 64ビット（32ビット × 2座標）

---

## Swift実装設計

### 1. Coordinate型とZ-order変換

```swift
/// 地理座標（緯度・経度）
public struct GeoCoordinate: Sendable, Equatable {
    public let latitude: Double   // -90.0 ~ 90.0
    public let longitude: Double  // -180.0 ~ 180.0

    public init(latitude: Double, longitude: Double) {
        precondition((-90.0...90.0).contains(latitude), "Invalid latitude")
        precondition((-180.0...180.0).contains(longitude), "Invalid longitude")

        self.latitude = latitude
        self.longitude = longitude
    }

    /// 正規化（0.0 ~ 1.0）
    func normalized() -> (x: Double, y: Double) {
        let x = (longitude + 180.0) / 360.0  // -180~180 → 0~1
        let y = (latitude + 90.0) / 180.0    // -90~90 → 0~1
        return (x, y)
    }
}

/// 2D座標（汎用）
public struct Coordinate2D: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Z-order（モートン）曲線
public struct ZOrderCurve: Sendable {
    /// 座標をZ値に変換
    public static func encode(x: Double, y: Double) -> UInt64 {
        // 0.0~1.0の座標を32ビット整数に変換
        let xi = UInt32(x * Double(UInt32.max))
        let yi = UInt32(y * Double(UInt32.max))

        return interleave(xi, yi)
    }

    /// Z値を座標に復元
    public static func decode(_ z: UInt64) -> (x: Double, y: Double) {
        let (xi, yi) = deinterleave(z)

        let x = Double(xi) / Double(UInt32.max)
        let y = Double(yi) / Double(UInt32.max)

        return (x, y)
    }

    /// ビットインターリーブ
    private static func interleave(_ x: UInt32, _ y: UInt32) -> UInt64 {
        var result: UInt64 = 0

        for i in 0..<32 {
            // Xのiビット目を偶数位置に配置
            result |= (UInt64(x) & (1 << i)) << i

            // Yのiビット目を奇数位置に配置
            result |= (UInt64(y) & (1 << i)) << (i + 1)
        }

        return result
    }

    /// ビットデインターリーブ
    private static func deinterleave(_ z: UInt64) -> (x: UInt32, y: UInt32) {
        var x: UInt32 = 0
        var y: UInt32 = 0

        for i in 0..<32 {
            // 偶数位置のビットをXに
            x |= UInt32((z >> (i * 2)) & 1) << i

            // 奇数位置のビットをYに
            y |= UInt32((z >> (i * 2 + 1)) & 1) << i
        }

        return (x, y)
    }
}
```

### 2. SpatialIndexDefinition

```swift
/// SPATIALインデックスの定義
public struct SpatialIndexDefinition: Sendable {
    public let name: String
    public let coordinateFields: CoordinateFields
    public let coordinateType: CoordinateType

    public init(
        name: String,
        coordinateFields: CoordinateFields,
        coordinateType: CoordinateType = .geo
    ) {
        self.name = name
        self.coordinateFields = coordinateFields
        self.coordinateType = coordinateType
    }
}

/// 座標フィールドの指定
public enum CoordinateFields: Sendable {
    /// 単一のGeoCoordinateフィールド
    case geoField(String)

    /// XとYの別々のフィールド
    case separate(xField: String, yField: String)

    /// 緯度と経度の別々のフィールド
    case latLon(latField: String, lonField: String)
}

/// 座標タイプ
public enum CoordinateType: Sendable {
    case geo          // 地理座標（緯度経度）
    case cartesian    // デカルト座標（X, Y）
}

/// マクロAPI拡張
extension Index {
    public static func spatial(
        _ name: String,
        on coordinateExpression: KeyExpression,
        type: CoordinateType = .geo
    ) -> Index {
        Index(
            name: name,
            type: .spatial,
            rootExpression: coordinateExpression,
            options: IndexOptions(spatialType: type)
        )
    }
}
```

### 3. SpatialIndexMaintainer

```swift
/// SPATIALインデックスのメンテナー
public final class SpatialIndexMaintainer<Record: Sendable>: IndexMaintainer {
    private let definition: SpatialIndexDefinition
    private let recordAccess: any RecordAccess<Record>
    private let subspace: Subspace

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        transaction: TransactionProtocol
    ) async throws {
        // 1. 古いレコードのエントリを削除
        if let oldRecord = oldRecord {
            let recordID = recordAccess.extractPrimaryKey(from: oldRecord)

            // 既存のZ値を取得
            let recordKey = subspace.subspace("r").pack(Tuple(recordID))
            if let zValueBytes = try await transaction.getValue(for: recordKey, snapshot: false) {
                let zValue = zValueBytes.withUnsafeBytes { $0.load(as: UInt64.self) }

                // Z-orderエントリを削除
                let zKey = subspace.subspace("z").pack(Tuple(zValue, recordID))
                transaction.clear(key: zKey)
                transaction.clear(key: recordKey)
            }
        }

        // 2. 新しいレコードのエントリを作成
        if let newRecord = newRecord {
            let recordID = recordAccess.extractPrimaryKey(from: newRecord)
            let coordinate = try extractCoordinate(from: newRecord)

            // 座標をZ値に変換
            let (x, y) = normalizeCoordinate(coordinate)
            let zValue = ZOrderCurve.encode(x: x, y: y)

            // Z-orderエントリを作成
            let zKey = subspace.subspace("z").pack(Tuple(zValue, recordID))
            transaction.setValue([], for: zKey)

            // 逆引きマッピングを保存
            let recordKey = subspace.subspace("r").pack(Tuple(recordID))
            transaction.setValue(
                withUnsafeBytes(of: zValue) { Array($0) },
                for: recordKey
            )
        }
    }

    private func extractCoordinate(from record: Record) throws -> Coordinate2D {
        switch definition.coordinateFields {
        case .geoField(let fieldName):
            guard let geoCoord = try recordAccess.extractFieldValue(
                from: record,
                fieldName: fieldName
            ) as? GeoCoordinate else {
                throw RecordLayerError.invalidArgument("Field '\(fieldName)' is not a GeoCoordinate")
            }
            let (x, y) = geoCoord.normalized()
            return Coordinate2D(x: x, y: y)

        case .separate(let xField, let yField):
            guard let x = try recordAccess.extractFieldValue(
                from: record,
                fieldName: xField
            ) as? Double else {
                throw RecordLayerError.invalidArgument("Field '\(xField)' is not a Double")
            }
            guard let y = try recordAccess.extractFieldValue(
                from: record,
                fieldName: yField
            ) as? Double else {
                throw RecordLayerError.invalidArgument("Field '\(yField)' is not a Double")
            }
            return Coordinate2D(x: x, y: y)

        case .latLon(let latField, let lonField):
            guard let lat = try recordAccess.extractFieldValue(
                from: record,
                fieldName: latField
            ) as? Double else {
                throw RecordLayerError.invalidArgument("Field '\(latField)' is not a Double")
            }
            guard let lon = try recordAccess.extractFieldValue(
                from: record,
                fieldName: lonField
            ) as? Double else {
                throw RecordLayerError.invalidArgument("Field '\(lonField)' is not a Double")
            }
            let geoCoord = GeoCoordinate(latitude: lat, longitude: lon)
            let (x, y) = geoCoord.normalized()
            return Coordinate2D(x: x, y: y)
        }
    }

    private func normalizeCoordinate(_ coordinate: Coordinate2D) -> (x: Double, y: Double) {
        switch definition.coordinateType {
        case .geo:
            // 既に0~1に正規化済み
            return (coordinate.x, coordinate.y)

        case .cartesian:
            // カスタム範囲の場合は正規化が必要
            // TODO: バウンディングボックスを使用して正規化
            return (coordinate.x, coordinate.y)
        }
    }
}
```

### 4. SpatialQuery（範囲検索）

```swift
/// 空間クエリ
public enum SpatialQuery: Sendable {
    /// バウンディングボックス検索
    case boundingBox(BoundingBox)

    /// 円形範囲検索
    case circle(center: GeoCoordinate, radiusMeters: Double)

    /// ポリゴン検索
    case polygon([GeoCoordinate])
}

/// バウンディングボックス
public struct BoundingBox: Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// 地理座標からバウンディングボックスを作成
    public static func fromGeo(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double
    ) -> BoundingBox {
        let minCoord = GeoCoordinate(latitude: minLat, longitude: minLon)
        let maxCoord = GeoCoordinate(latitude: maxLat, longitude: maxLon)

        let (minX, minY) = minCoord.normalized()
        let (maxX, maxY) = maxCoord.normalized()

        return BoundingBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}

/// SPATIALインデックススキャンプラン
public struct SpatialIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    private let query: SpatialQuery
    private let indexSubspace: Subspace

    public func execute(
        transaction: TransactionProtocol,
        context: QueryContext
    ) async throws -> AnyTypedRecordCursor<Record> {
        switch query {
        case .boundingBox(let bbox):
            return try await searchBoundingBox(bbox, transaction: transaction, context: context)

        case .circle(let center, let radius):
            // 円をバウンディングボックスに変換
            let bbox = approximateCircleAsBBox(center: center, radiusMeters: radius)
            let candidates = try await searchBoundingBox(bbox, transaction: transaction, context: context)

            // 後フィルタリングで正確な円形範囲をチェック
            return FilteredCursor(
                source: candidates,
                filter: { record in
                    let coord = try extractCoordinate(from: record)
                    return haversineDistance(center, coord) <= radius
                }
            )

        case .polygon(let vertices):
            // ポリゴンのバウンディングボックスを計算
            let bbox = computePolygonBBox(vertices)
            let candidates = try await searchBoundingBox(bbox, transaction: transaction, context: context)

            // 後フィルタリングでポイント・イン・ポリゴンテスト
            return FilteredCursor(
                source: candidates,
                filter: { record in
                    let coord = try extractCoordinate(from: record)
                    return isPointInPolygon(coord, vertices)
                }
            )
        }
    }

    /// バウンディングボックス検索
    private func searchBoundingBox(
        _ bbox: BoundingBox,
        transaction: TransactionProtocol,
        context: QueryContext
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Z-orderサブレンジを計算
        let zRanges = computeZRanges(bbox)

        var recordIDs: Set<PrimaryKey> = []

        // 各Z-orderサブレンジをスキャン
        for (zMin, zMax) in zRanges {
            let beginKey = indexSubspace.subspace("z").pack(Tuple(zMin))
            let endKey = indexSubspace.subspace("z").pack(Tuple(zMax))

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: true
            )

            for try await (key, _) in sequence {
                let tuple = try indexSubspace.subspace("z").unpack(key)
                let zValue = tuple[0] as! UInt64
                let recordID = tuple[1]

                // Z値が範囲内か確認
                if zMin <= zValue && zValue < zMax {
                    // 座標がバウンディングボックス内か確認
                    let (x, y) = ZOrderCurve.decode(zValue)
                    if bbox.contains(x: x, y: y) {
                        recordIDs.insert(recordID)
                    }
                }
            }
        }

        // レコードをフェッチ
        return RecordIDCursor(
            recordIDs: Array(recordIDs),
            recordStore: context.recordStore,
            transaction: transaction
        )
    }

    /// バウンディングボックスをZ-orderサブレンジに分解
    private func computeZRanges(_ bbox: BoundingBox) -> [(UInt64, UInt64)] {
        // アルゴリズム: Quadtreeの再帰的分割
        var ranges: [(UInt64, UInt64)] = []

        func subdivide(
            level: Int,
            zPrefix: UInt64,
            cellBBox: BoundingBox
        ) {
            // 最大深さに達した場合
            if level >= 16 {  // 32レベル（32ビット×2）の半分
                let zMin = zPrefix << (64 - level * 2)
                let zMax = ((zPrefix + 1) << (64 - level * 2))
                ranges.append((zMin, zMax))
                return
            }

            // セルがクエリ範囲に完全に含まれる場合
            if bbox.fullyContains(cellBBox) {
                let zMin = zPrefix << (64 - level * 2)
                let zMax = ((zPrefix + 1) << (64 - level * 2))
                ranges.append((zMin, zMax))
                return
            }

            // セルがクエリ範囲と交差しない場合
            if !bbox.intersects(cellBBox) {
                return
            }

            // 4分割して再帰
            let midX = (cellBBox.minX + cellBBox.maxX) / 2
            let midY = (cellBBox.minY + cellBBox.maxY) / 2

            let quadrants: [(Int, BoundingBox)] = [
                (0, BoundingBox(minX: cellBBox.minX, minY: cellBBox.minY, maxX: midX, maxY: midY)),  // 左下
                (1, BoundingBox(minX: midX, minY: cellBBox.minY, maxX: cellBBox.maxX, maxY: midY)),  // 右下
                (2, BoundingBox(minX: cellBBox.minX, minY: midY, maxX: midX, maxY: cellBBox.maxY)),  // 左上
                (3, BoundingBox(minX: midX, minY: midY, maxX: cellBBox.maxX, maxY: cellBBox.maxY))   // 右上
            ]

            for (quadrant, quadBBox) in quadrants {
                let childPrefix = (zPrefix << 2) | UInt64(quadrant)
                subdivide(level: level + 1, zPrefix: childPrefix, cellBBox: quadBBox)
            }
        }

        // ルートセル（全空間）から開始
        subdivide(
            level: 0,
            zPrefix: 0,
            cellBBox: BoundingBox(minX: 0, minY: 0, maxX: 1, maxY: 1)
        )

        return ranges
    }
}

extension BoundingBox {
    func contains(x: Double, y: Double) -> Bool {
        minX <= x && x <= maxX && minY <= y && y <= maxY
    }

    func fullyContains(_ other: BoundingBox) -> Bool {
        minX <= other.minX && other.maxX <= maxX &&
        minY <= other.minY && other.maxY <= maxY
    }

    func intersects(_ other: BoundingBox) -> Bool {
        !(maxX < other.minX || other.maxX < minX ||
          maxY < other.minY || other.maxY < minY)
    }
}
```

### 5. 地理空間ユーティリティ

```swift
/// Haversine距離（地球上の2点間の距離）
public func haversineDistance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
    let earthRadiusMeters = 6371000.0

    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let dLat = (b.latitude - a.latitude) * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180

    let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1) * cos(lat2) *
            sin(dLon / 2) * sin(dLon / 2)

    let c = 2 * atan2(sqrt(a), sqrt(1 - a))

    return earthRadiusMeters * c
}

/// ポイント・イン・ポリゴンテスト（Ray Casting Algorithm）
public func isPointInPolygon(_ point: GeoCoordinate, _ vertices: [GeoCoordinate]) -> Bool {
    var inside = false
    let (x, y) = point.normalized()

    for i in 0..<vertices.count {
        let j = (i + 1) % vertices.count
        let (xi, yi) = vertices[i].normalized()
        let (xj, yj) = vertices[j].normalized()

        if ((yi > y) != (yj > y)) &&
           (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
            inside.toggle()
        }
    }

    return inside
}
```

---

## API使用例

### 基本的な範囲検索

```swift
import FDBRecordLayer

// 1. レコード定義
@Recordable
struct Restaurant {
    #Index<Restaurant>([\.location], type: .spatial)

    #PrimaryKey<Restaurant>([\.restaurantID])

    var restaurantID: Int64
    var name: String
    var location: GeoCoordinate
    var rating: Double
}

// 2. レコード保存
let restaurant = Restaurant(
    restaurantID: 1,
    name: "Tokyo Sushi",
    location: GeoCoordinate(latitude: 35.6762, longitude: 139.6503),
    rating: 4.5
)
try await store.save(restaurant)

// 3. バウンディングボックス検索
let bbox = BoundingBox.fromGeo(
    minLat: 35.6, minLon: 139.6,
    maxLat: 35.7, maxLon: 139.7
)

let nearbyRestaurants = try await store.query(Restaurant.self)
    .spatialQuery(\.location, within: bbox)
    .execute()

for restaurant in nearbyRestaurants {
    print("\(restaurant.name) - Rating: \(restaurant.rating)")
}
```

### 円形範囲検索

```swift
// 現在地から5km以内のレストラン
let currentLocation = GeoCoordinate(latitude: 35.6762, longitude: 139.6503)

let nearbyRestaurants = try await store.query(Restaurant.self)
    .spatialQuery(\.location, withinCircle: currentLocation, radiusMeters: 5000)
    .execute()
```

### ポリゴン検索

```swift
// 配達エリア内の注文
let deliveryArea = [
    GeoCoordinate(latitude: 35.65, longitude: 139.70),
    GeoCoordinate(latitude: 35.68, longitude: 139.72),
    GeoCoordinate(latitude: 35.70, longitude: 139.69),
    GeoCoordinate(latitude: 35.67, longitude: 139.67)
]

let ordersInArea = try await store.query(Order.self)
    .spatialQuery(\.deliveryLocation, withinPolygon: deliveryArea)
    .execute()
```

---

## パフォーマンス最適化

### 1. 適応的サブレンジ分割

**問題**: 大きな範囲は多数のZ-orderサブレンジを生成し、多数のRange読み取りが発生

**解決策**: サブレンジ数に上限を設け、超過した場合は後フィルタリング

```swift
private func computeZRanges(_ bbox: BoundingBox, maxRanges: Int = 100) -> [(UInt64, UInt64)] {
    var ranges: [(UInt64, UInt64)] = []

    func subdivide(...) {
        // maxRangesに達したら分割を停止
        if ranges.count >= maxRanges {
            return
        }

        // 通常の分割ロジック...
    }

    // ...
}
```

### 2. キャッシング

**空間統計のキャッシュ**:
```swift
private final class SpatialStatsCache: Sendable {
    private let cache: Mutex<CachedStats?>

    struct CachedStats {
        let bounds: BoundingBox
        let count: Int
        let timestamp: Date
    }

    func getStats() async throws -> CachedStats {
        // キャッシュから返すか、再計算
    }
}
```

### 3. ヒートマップの事前計算

**頻繁にアクセスされる地域の統計を事前計算**:
```swift
// 地域ごとのレストラン数を事前計算
[spatialIndexSubspace]["heatmap"][gridCellID] = count
```

---

## パフォーマンス特性

### 理論的計算量

| 操作 | 時間計算量 | 説明 |
|------|----------|------|
| **挿入** | O(log n) | Z値の計算 + FDB書き込み |
| **範囲検索** | O(r · log n + k) | r: サブレンジ数、k: 結果数 |
| **円形検索** | O(r · log n + k · f) | f: 後フィルタリングコスト |

### 実測値（予想）

**データセット**: 100万ポイント

| 操作 | レイテンシ | サブレンジ数 |
|------|----------|-----------|
| **小範囲（1km²）** | 5-20ms | 1-10 |
| **中範囲（10km²）** | 20-50ms | 10-50 |
| **大範囲（100km²）** | 50-200ms | 50-100 |

---

## 実装優先度

### Phase 1（2-3週間）: 基本実装

- [x] GeoCoordinate、Coordinate2D型
- [x] ZOrderCurve実装（ビットインターリーブ）
- [x] SpatialIndexMaintainer実装
- [x] バウンディングボックス検索

### Phase 2（1週間）: 高度なクエリ

- [ ] 円形範囲検索
- [ ] ポリゴン検索
- [ ] Haversine距離計算
- [ ] ポイント・イン・ポリゴンテスト

### Phase 3（1週間）: 最適化

- [ ] 適応的サブレンジ分割
- [ ] 空間統計のキャッシング
- [ ] ヒートマップの事前計算

### Phase 4（将来）: 高度な機能

- [ ] 3D座標対応
- [ ] Hilbert Curve（局所性改善）
- [ ] Geohash統合
- [ ] ジオフェンシング通知

---

## テスト戦略

### ユニットテスト

```swift
@Suite struct ZOrderCurveTests {
    @Test func testBitInterleave() async throws {
        let z = ZOrderCurve.encode(x: 0.5, y: 0.5)
        let (x, y) = ZOrderCurve.decode(z)

        #expect(abs(x - 0.5) < 0.001)
        #expect(abs(y - 0.5) < 0.001)
    }

    @Test func testLocalityPreservation() async throws {
        // 近い座標は近いZ値を持つことを確認
        let z1 = ZOrderCurve.encode(x: 0.5, y: 0.5)
        let z2 = ZOrderCurve.encode(x: 0.51, y: 0.51)
        let z3 = ZOrderCurve.encode(x: 0.9, y: 0.9)

        #expect(abs(Int64(z1) - Int64(z2)) < abs(Int64(z1) - Int64(z3)))
    }
}

@Suite struct SpatialIndexTests {
    @Test func testBoundingBoxSearch() async throws {
        // バウンディングボックス検索のテスト
    }

    @Test func testCircleSearch() async throws {
        // 円形範囲検索のテスト
    }
}
```

### 精度テスト

```swift
@Suite struct SpatialAccuracyTests {
    @Test func testZRangeDecomposition() async throws {
        // Z-orderサブレンジ分解の正確性を検証
        let bbox = BoundingBox(minX: 0.25, minY: 0.25, maxX: 0.75, maxY: 0.75)
        let ranges = computeZRanges(bbox)

        // すべての範囲内ポイントがカバーされているか
        for x in stride(from: 0.0, through: 1.0, by: 0.01) {
            for y in stride(from: 0.0, through: 1.0, by: 0.01) {
                let z = ZOrderCurve.encode(x: x, y: y)
                let inBBox = bbox.contains(x: x, y: y)
                let inZRanges = ranges.contains { z >= $0.0 && z < $0.1 }

                if inBBox {
                    #expect(inZRanges)
                }
            }
        }
    }
}
```

### パフォーマンステスト

```swift
@Suite struct SpatialPerformanceTests {
    @Test func testLargeDatasetIndexing() async throws {
        let start = Date()

        for i in 0..<100_000 {
            let restaurant = Restaurant(
                restaurantID: Int64(i),
                name: "Restaurant \(i)",
                location: GeoCoordinate(
                    latitude: Double.random(in: 35.0...36.0),
                    longitude: Double.random(in: 139.0...140.0)
                ),
                rating: Double.random(in: 1.0...5.0)
            )
            try await store.save(restaurant)
        }

        let duration = Date().timeIntervalSince(start)
        let throughput = 100_000.0 / duration
        print("Indexing: \(throughput) points/sec")

        #expect(throughput > 1000)
    }

    @Test func testRangeQueryLatency() async throws {
        let bbox = BoundingBox.fromGeo(
            minLat: 35.6, minLon: 139.6,
            maxLat: 35.7, maxLon: 139.7
        )

        let start = Date()
        let _ = try await store.query(Restaurant.self)
            .spatialQuery(\.location, within: bbox)
            .execute()
        let latency = Date().timeIntervalSince(start)

        print("Range query latency: \(latency * 1000) ms")
        #expect(latency < 0.05)  // 50ms以内
    }
}
```

---

## まとめ

**Swift-Native SPATIAL Index**は、以下の特徴を持ちます：

✅ **効率的**: Z-order curveで局所性を保持
✅ **柔軟**: バウンディングボックス、円形、ポリゴン検索に対応
✅ **スケーラブル**: FoundationDBの分散特性を活用
✅ **型安全**: SwiftのRecordable APIと統合
✅ **拡張可能**: Hilbert Curve、3D座標に対応可能

**ユースケース**:

- 📍 **位置ベースサービス**: レストラン検索、配車アプリ
- 🗺️ **地図アプリ**: 可視範囲内のポイント表示
- 🚚 **配送最適化**: エリア内の注文管理
- 🏠 **不動産検索**: 地域・価格帯での物件検索

**次のステップ**:

1. Phase 1実装（2-3週間）
2. 精度・パフォーマンステスト
3. 実世界のデータセットでの検証
4. ドキュメントと使用例の整備

---

**Last Updated**: 2025-01-13
**Status**: 設計完了、実装準備完了
**Priority**: 🟡 中（位置ベースアプリで重要）
