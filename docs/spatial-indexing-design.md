# Spatial Indexing Design（空間インデックス設計）

**Status**: Active (2025-01-16)
**Version**: 2.0
**Supersedes**: spatial-index-implementation-plan.md (DEPRECATED)

---

## 目次

1. [概要](#概要)
2. [アーキテクチャ](#アーキテクチャ)
3. [アルゴリズム選定](#アルゴリズム選定)
4. [S2 Geometry（地理座標）](#s2-geometry地理座標)
5. [Hilbert Curve（Cartesian座標）](#hilbert-curveCartesian座標)
6. [実装ガイドライン](#実装ガイドライン)
7. [テスト戦略](#テスト戦略)
8. [パフォーマンス特性](#パフォーマンス特性)
9. [マイグレーション戦略](#マイグレーション戦略)

---

## 概要

### 設計原則

FDB Record Layerの空間インデックスは以下の原則に基づいて設計されています：

1. **Computed Property方式**: マクロ・プロトコル不要
2. **Value Indexとして扱う**: 特殊なIndexMaintainer不要
3. **階層的導入**: Layer 1（基本）→ Layer 2（高精度）→ Layer 3（専門）
4. **KV最適化**: FoundationDBのKey-Value特性を最大活用

### 階層構造

| Layer | アルゴリズム | 用途 | 状態 |
|-------|------------|------|------|
| **Layer 1** | Geohash | 2D地理（基本） | ✅ 完了 |
| **Layer 1** | Morton Code | 2D/3D Cartesian（基本） | ✅ 完了 |
| **Layer 2** | S2 Geometry | 2D地理（高精度） | 🎯 本設計 |
| **Layer 2** | Hilbert Curve | 2D/3D Cartesian（高精度） | 🎯 本設計 |
| **Layer 3** | H3 | ヒートマップ | ⏸️ 将来 |

---

## アーキテクチャ

### Computed Property方式

```swift
@Recordable
struct Location {
    #PrimaryKey<Location>([\.id])
    #Index<Location>([\.s2CellID])    // S2 Geometry
    #Index<Location>([\.geohash7])    // Geohash (互換性)

    var id: Int64
    var latitude: Double
    var longitude: Double

    // ✅ Computed property（自動計算）
    var s2CellID: Int64 {
        S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
    }

    var geohash7: String {
        Geohash.encode(latitude: latitude, longitude: longitude, precision: 7)
    }
}
```

### インデックス構造

**FDB Key-Value構造**:

```
# S2 Geometry Index
(index, "location_by_s2", s2CellID, primaryKey) = []

# Hilbert Curve Index
(index, "entity_by_hilbert", hilbertIndex, primaryKey) = []
```

**利点**:
- ✅ 単純なKVペア（ツリー構造不要）
- ✅ Range読み取りで効率的
- ✅ トランザクション制限に優しい（1レコード = 1キー）
- ✅ 並行更新の競合が少ない

---

## アルゴリズム選定

### FoundationDBの特性分析

| 特性 | 制約/強み | 空間インデックスへの影響 |
|------|---------|---------------------|
| **Key-Valueモデル** | ツリー構造維持が困難 | → R-tree不適、1次元写像が必須 |
| **順序保証** | 辞書順ソート | → 空間曲線（Z-order/Hilbert）が有効 |
| **Range読み取り** | 高速なgetRange | → 連続性の高いアルゴリズムが有利 |
| **トランザクション制限** | 5秒、10MB | → 複雑な再バランス不可 |

### アルゴリズム比較

| アルゴリズム | 連続性 | 計算コスト | KV適合性 | 精度 | 実績 |
|------------|-------|-----------|---------|------|------|
| **Geohash** | 中 | 低 | 高 | 緯度で歪む | Elasticsearch, Redis |
| **S2 Geometry** | 高（Hilbert） | 中 | 高 | 球面で均一 | Google Maps, Bigtable |
| **Morton (Z-order)** | 中 | 低 | 高 | 均一 | 多数のKVストア |
| **Hilbert Curve** | 最高 | 中 | 高 | 均一 | Apache Sedona, PostGIS |
| **R-tree** | N/A | 高 | 低 | 最良 | PostGIS, Oracle Spatial |
| **H3** | 高 | 中 | 高 | 均一（六角形） | Uber, Foursquare |

### 選定理由

**S2 Geometry（地理座標）**:
- ✅ 球面Hilbert曲線で連続性が高い
- ✅ 極地でも精度が均一（Geohashは極地で歪む）
- ✅ 階層的（30レベル）で柔軟
- ✅ Google実績（Maps, Earth, Bigtable）
- ✅ セルベースの近似計算が可能

**Hilbert Curve（Cartesian座標）**:
- ✅ Z-orderより連続性が高い（Range分割が少ない）
- ✅ 2D/3D対応
- ✅ 計算コストが許容範囲（LUTで最適化可能）
- ✅ ゲーム、CAD、シミュレーションに実績

---

## S2 Geometry（地理座標）

### 概要

**S2 Geometry**は、Googleが開発した球面ジオメトリライブラリで、地球表面を階層的なセルに分割します。

**特徴**:
- 球面をキューブに投影（6面体）
- 各面をHilbert曲線で分割
- 30レベルの階層（レベル0 = 地球の1/6、レベル30 = 約1cm²）
- セルID = UInt64（64ビット整数）

### S2CellID構造

```
S2CellID (UInt64, 64 bits)
├─ Face (3 bits): 0-5 (キューブの6面)
├─ Position (60 bits): Hilbert curve上の位置
└─ Unused (1 bit): 将来の拡張用

レベルとビット数の関係:
Level 0:  3 bits (face only)
Level 1:  5 bits (face + 2 bits position)
Level 2:  7 bits (face + 4 bits position)
...
Level 30: 63 bits (face + 60 bits position)
```

### API設計

#### S2CellID.swift

```swift
/// S2 Geometry Cell ID
///
/// Represents a cell on the surface of a unit sphere using a hierarchical
/// subdivision based on Hilbert curve.
public struct S2CellID: Sendable, Hashable, Comparable {
    /// Raw 64-bit cell ID
    public let rawValue: UInt64

    /// Initialize from latitude/longitude at specified level
    ///
    /// - Parameters:
    ///   - lat: Latitude in degrees [-90, 90]
    ///   - lon: Longitude in degrees [-180, 180]
    ///   - level: Cell level [0, 30] (default: 20 ≈ 100m²)
    ///
    /// **Level Guide**:
    /// - Level 10: ~1000 km² (country)
    /// - Level 15: ~1 km² (city)
    /// - Level 20: ~100 m² (building, default)
    /// - Level 25: ~1 m² (room)
    /// - Level 30: ~1 cm² (precise)
    public init(lat: Double, lon: Double, level: Int = 20)

    /// Initialize from raw cell ID
    public init(rawValue: UInt64)

    /// Get cell level [0, 30]
    public var level: Int { get }

    /// Get parent cell at specified level
    public func parent(level: Int) -> S2CellID

    /// Get all children at next level (4 children)
    public func children() -> [S2CellID]

    /// Get center point (latitude, longitude)
    public func toLatLon() -> (lat: Double, lon: Double)

    /// Get cell vertices (4 corners)
    public func vertices() -> [(lat: Double, lon: Double)]

    /// Check if this cell contains a point
    public func contains(lat: Double, lon: Double) -> Bool

    /// Get neighboring cells (8 directions + 4 diagonals = up to 12)
    public func neighbors() -> [S2CellID]

    /// Comparable for sorting
    public static func < (lhs: S2CellID, rhs: S2CellID) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
```

#### S2RegionCoverer.swift

```swift
/// S2 Region Coverer
///
/// Computes a covering of a region (bounding box, circle) using S2 cells.
public struct S2RegionCoverer: Sendable {
    /// Maximum number of cells in covering (default: 8)
    public var maxCells: Int

    /// Minimum cell level (default: 0)
    public var minLevel: Int

    /// Maximum cell level (default: 30)
    public var maxLevel: Int

    /// Target cell level (default: nil = auto)
    public var levelMod: Int?

    public init(
        maxCells: Int = 8,
        minLevel: Int = 0,
        maxLevel: Int = 30,
        levelMod: Int? = nil
    )

    /// Compute covering for bounding box
    ///
    /// - Parameters:
    ///   - minLat, maxLat: Latitude bounds [-90, 90]
    ///   - minLon, maxLon: Longitude bounds [-180, 180]
    /// - Returns: Array of S2CellIDs that cover the region
    ///
    /// **Edge Cases**:
    /// - Dateline crossing (minLon > maxLon): Splits into 2 regions
    /// - Polar regions: Uses larger cells automatically
    /// - Small regions: Uses fewer, larger cells
    public func getCovering(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> [S2CellID]

    /// Compute covering for circle (radius search)
    ///
    /// - Parameters:
    ///   - centerLat, centerLon: Center coordinates
    ///   - radiusMeters: Radius in meters
    /// - Returns: Array of S2CellIDs that cover the circle
    public func getCoveringForCircle(
        centerLat: Double, centerLon: Double,
        radiusMeters: Double
    ) -> [S2CellID]
}
```

### 使用例

#### 基本的なエンコード/デコード

```swift
// エンコード: 緯度経度 → S2CellID
let tokyo = S2CellID(lat: 35.6812, lon: 139.7671, level: 20)
print("S2 Cell ID: \(tokyo.rawValue)")  // UInt64値
print("Level: \(tokyo.level)")          // 20

// デコード: S2CellID → 緯度経度
let (lat, lon) = tokyo.toLatLon()
print("Center: (\(lat), \(lon))")

// 親セル取得
let parent = tokyo.parent(level: 15)  // より粗いセル

// 子セル取得（4分割）
let children = tokyo.children()
print("Children count: \(children.count)")  // 4

// 隣接セル取得
let neighbors = tokyo.neighbors()
print("Neighbors count: \(neighbors.count)")  // 最大12
```

#### Computed Propertyとしての使用

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.id])

    // S2 Geometry Index (high precision)
    #Index<Restaurant>([\.s2Cell20])

    // Geohash Index (backward compatibility)
    #Index<Restaurant>([\.geohash7])

    var id: Int64
    var name: String
    var latitude: Double
    var longitude: Double

    // ✅ S2 Cell ID (level 20 ≈ 100m²)
    var s2Cell20: Int64 {
        S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
    }

    // Geohash (互換性のため残す)
    var geohash7: String {
        Geohash.encode(latitude: latitude, longitude: longitude, precision: 7)
    }
}

// 保存
let restaurant = Restaurant(
    id: 1,
    name: "Sushi Tokyo",
    latitude: 35.6812,
    longitude: 139.7671
)
try await store.save(restaurant)

// クエリ: Bounding box検索
let coverer = S2RegionCoverer(maxCells: 8, maxLevel: 20)
let cells = coverer.getCovering(
    minLat: 35.65, maxLat: 35.70,
    minLon: 139.75, maxLon: 139.80
)

// 各セルをプレフィックスとして検索
var results: [Restaurant] = []
for cell in cells {
    let cellMin = cell.rawValue
    let cellMax = cell.children().last!.rawValue + 1

    let batch = try await store.query()
        .where(\.s2Cell20, .greaterThanOrEqual, cellMin)
        .where(\.s2Cell20, .lessThan, cellMax)
        .execute()

    results.append(contentsOf: batch)
}

// 精密フィルタ（球面距離）
let filtered = results.filter { restaurant in
    let distance = haversineDistance(
        lat1: restaurant.latitude, lon1: restaurant.longitude,
        lat2: centerLat, lon2: centerLon
    )
    return distance <= radiusMeters
}
```

#### 階層的検索（Zoom対応）

```swift
// ズームレベル別のセル取得
func getCellForZoom(lat: Double, lon: Double, zoom: Int) -> S2CellID {
    // Zoom 0-5: Level 10 (country)
    // Zoom 6-10: Level 15 (city)
    // Zoom 11-15: Level 20 (building)
    // Zoom 16-20: Level 25 (room)
    let level = min(30, max(0, (zoom - 5) * 3 + 10))
    return S2CellID(lat: lat, lon: lon, level: level)
}

// タイル検索（地図タイル）
let tileCell = getCellForZoom(lat: 35.6812, lon: 139.7671, zoom: 15)
let tiledRestaurants = try await store.query()
    .where(\.s2Cell20, .hasPrefix, tileCell.rawValue)
    .execute()
```

### エッジケース処理

#### 日付変更線（Dateline Crossing）

```swift
// minLon > maxLon の場合、2つの領域に分割
func getCoveringWithDateline(
    minLat: Double, maxLat: Double,
    minLon: Double, maxLon: Double
) -> [S2CellID] {
    if minLon > maxLon {
        // 日付変更線をまたぐ
        let west = coverer.getCovering(
            minLat: minLat, maxLat: maxLat,
            minLon: minLon, maxLon: 180.0
        )
        let east = coverer.getCovering(
            minLat: minLat, maxLat: maxLat,
            minLon: -180.0, maxLon: maxLon
        )
        return west + east
    } else {
        return coverer.getCovering(
            minLat: minLat, maxLat: maxLat,
            minLon: minLon, maxLon: maxLon
        )
    }
}
```

#### 極地域（Polar Regions）

S2は球面上で均一なため、極地でも精度が一定です（Geohashは極地で歪む）。

```swift
// 北極点周辺（Geohashでは精度が著しく低下）
let northPole = S2CellID(lat: 89.9, lon: 0.0, level: 20)
let vertices = northPole.vertices()
// → 頂点間の距離が均一（約100m²）

// Geohashの場合（比較）
let geohash = Geohash.encode(latitude: 89.9, longitude: 0.0, precision: 12)
// → 極地では精度が大幅に低下（数km²）
```

### 実装詳細

#### 1. Lat/Lon → S2CellID

```swift
public init(lat: Double, lon: Double, level: Int = 20) {
    precondition((-90...90).contains(lat), "Latitude must be in [-90, 90]")
    precondition((-180...180).contains(lon), "Longitude must be in [-180, 180]")
    precondition((0...30).contains(level), "Level must be in [0, 30]")

    // 1. 緯度経度 → 3D単位球面座標 (x, y, z)
    let latRad = lat * .pi / 180.0
    let lonRad = lon * .pi / 180.0
    let x = cos(latRad) * cos(lonRad)
    let y = cos(latRad) * sin(lonRad)
    let z = sin(latRad)

    // 2. 3D座標 → キューブ面とUV座標
    let (face, u, v) = xyzToFaceUV(x: x, y: y, z: z)

    // 3. UV座標 → ST座標（射影）
    let s = uvToST(u)
    let t = uvToST(v)

    // 4. ST座標 → Hilbert curve位置
    let i = stToIJ(s)
    let j = stToIJ(t)
    let hilbertPos = ijToHilbert(i: i, j: j, level: level)

    // 5. Face + Hilbert position → 64-bit CellID
    self.rawValue = faceAndPosToID(face: face, pos: hilbertPos, level: level)
}
```

#### 2. S2CellID → Lat/Lon

```swift
public func toLatLon() -> (lat: Double, lon: Double) {
    // 1. CellID → Face + Hilbert position
    let (face, pos) = idToFaceAndPos(rawValue, level: level)

    // 2. Hilbert position → IJ座標
    let (i, j) = hilbertToIJ(pos: pos, level: level)

    // 3. IJ → ST座標
    let s = ijToST(i, level: level)
    let t = ijToST(j, level: level)

    // 4. ST → UV座標（逆射影）
    let u = stToUV(s)
    let v = stToUV(t)

    // 5. Face + UV → 3D座標
    let (x, y, z) = faceUVToXYZ(face: face, u: u, v: v)

    // 6. 3D座標 → 緯度経度
    let lat = atan2(z, sqrt(x * x + y * y)) * 180.0 / .pi
    let lon = atan2(y, x) * 180.0 / .pi

    return (lat, lon)
}
```

#### 3. Hilbert Curve（S2内部）

S2は各キューブ面を2D Hilbert曲線で分割します。Hilbert曲線は空間充填曲線で、2D空間を1次元に写像します。

```swift
/// IJ座標 → Hilbert curve位置
private func ijToHilbert(i: Int, j: Int, level: Int) -> UInt64 {
    var n = 1 << level  // 2^level
    var pos: UInt64 = 0
    var x = i
    var y = j

    for s in stride(from: n / 2, to: 0, by: -1) {
        let rx = (x & s) > 0 ? 1 : 0
        let ry = (y & s) > 0 ? 1 : 0
        pos += UInt64(s * s * ((3 * rx) ^ ry))

        // Rotate
        if ry == 0 {
            if rx == 1 {
                x = n - 1 - x
                y = n - 1 - y
            }
            swap(&x, &y)
        }
    }

    return pos
}

/// Hilbert curve位置 → IJ座標
private func hilbertToIJ(pos: UInt64, level: Int) -> (i: Int, j: Int) {
    var n = 1 << level
    var x = 0
    var y = 0
    var p = pos

    for s in stride(from: 1, through: n / 2, by: 2) {
        let rx = 1 & Int(p / 2)
        let ry = 1 & Int(p ^ UInt64(rx))

        // Rotate
        if ry == 0 {
            if rx == 1 {
                x = s - 1 - x
                y = s - 1 - y
            }
            swap(&x, &y)
        }

        x += s * rx
        y += s * ry
        p /= 4
    }

    return (i: x, j: y)
}
```

---

## Hilbert Curve（Cartesian座標）

### 概要

**Hilbert Curve**は、2D/3D空間を1次元に写像する空間充填曲線です。Z-order（Morton Code）より連続性が高く、Range読み取りが効率的です。

**特徴**:
- 連続性が高い（隣接セルが連続）
- Range分割が少ない（bounding boxを少数のRangeでカバー）
- 2D/3D対応
- 計算コスト中程度（LUTで最適化可能）

### 2D Hilbert Curve

#### API設計

```swift
/// 2D Hilbert Curve
public enum HilbertCurve2D {
    /// Encode 2D coordinates to Hilbert index
    ///
    /// - Parameters:
    ///   - x: X coordinate [0.0, 1.0] (normalized)
    ///   - y: Y coordinate [0.0, 1.0] (normalized)
    ///   - order: Hilbert curve order [1, 21] (default: 21, max precision)
    /// - Returns: Hilbert index (UInt64)
    ///
    /// **Order Guide**:
    /// - Order 10: 2^10 = 1024 cells per dimension (1M cells total)
    /// - Order 15: 2^15 = 32K cells per dimension (1B cells total)
    /// - Order 21: 2^21 = 2M cells per dimension (4T cells total, max)
    public static func encode(x: Double, y: Double, order: Int = 21) -> UInt64

    /// Decode Hilbert index to 2D coordinates
    ///
    /// - Parameters:
    ///   - index: Hilbert index
    ///   - order: Hilbert curve order
    /// - Returns: (x, y) in [0.0, 1.0]
    public static func decode(_ index: UInt64, order: Int = 21) -> (x: Double, y: Double)

    /// Compute Hilbert ranges covering a bounding box
    ///
    /// - Parameters:
    ///   - minX, maxX: X bounds [0.0, 1.0]
    ///   - minY, maxY: Y bounds [0.0, 1.0]
    ///   - order: Hilbert curve order
    ///   - maxRanges: Maximum number of ranges (default: 100)
    /// - Returns: Array of (begin, end) Hilbert index ranges
    ///
    /// **Note**: Hilbert requires fewer ranges than Z-order (Morton)
    /// - Z-order: 50-100 ranges typical
    /// - Hilbert: 10-20 ranges typical
    public static func boundingBoxToRanges(
        minX: Double, maxX: Double,
        minY: Double, maxY: Double,
        order: Int = 21,
        maxRanges: Int = 100
    ) -> [(begin: UInt64, end: UInt64)]
}
```

#### 使用例

```swift
// ゲームエンティティ
@Recordable
struct GameEntity {
    #PrimaryKey<GameEntity>([\.id])
    #Index<GameEntity>([\.hilbertIndex])

    var id: Int64
    var x: Double
    var y: Double
    let mapWidth: Double = 10000.0
    let mapHeight: Double = 10000.0

    // ✅ Hilbert Curve Index
    var hilbertIndex: Int64 {
        let normX = x / mapWidth
        let normY = y / mapHeight
        return Int64(bitPattern: HilbertCurve2D.encode(x: normX, y: normY, order: 21))
    }
}

// Bounding box検索
let ranges = HilbertCurve2D.boundingBoxToRanges(
    minX: (playerX - 100) / mapWidth,
    maxX: (playerX + 100) / mapWidth,
    minY: (playerY - 100) / mapHeight,
    maxY: (playerY + 100) / mapHeight,
    order: 21
)

print("Hilbert ranges: \(ranges.count)")  // 通常10-20個

// 各Rangeをスキャン
var nearbyEntities: [GameEntity] = []
for (begin, end) in ranges {
    let batch = try await store.query()
        .where(\.hilbertIndex, .greaterThanOrEqual, Int64(bitPattern: begin))
        .where(\.hilbertIndex, .lessThan, Int64(bitPattern: end))
        .execute()

    nearbyEntities.append(contentsOf: batch)
}

// 精密フィルタ（Euclidean距離）
let filtered = nearbyEntities.filter { entity in
    let dx = entity.x - playerX
    let dy = entity.y - playerY
    return sqrt(dx * dx + dy * dy) <= 100
}
```

### 3D Hilbert Curve

#### API設計

```swift
/// 3D Hilbert Curve
public enum HilbertCurve3D {
    /// Encode 3D coordinates to Hilbert index
    ///
    /// - Parameters:
    ///   - x: X coordinate [0.0, 1.0] (normalized)
    ///   - y: Y coordinate [0.0, 1.0] (normalized)
    ///   - z: Z coordinate [0.0, 1.0] (normalized)
    ///   - order: Hilbert curve order [1, 21] (default: 21)
    /// - Returns: Hilbert index (UInt64)
    ///
    /// **Note**: 3D uses 21 bits per dimension (63 bits total)
    public static func encode(x: Double, y: Double, z: Double, order: Int = 21) -> UInt64

    /// Decode Hilbert index to 3D coordinates
    public static func decode(_ index: UInt64, order: Int = 21) -> (x: Double, y: Double, z: Double)

    /// Compute Hilbert ranges covering a 3D bounding box
    public static func boundingBoxToRanges(
        minX: Double, maxX: Double,
        minY: Double, maxY: Double,
        minZ: Double, maxZ: Double,
        order: Int = 21,
        maxRanges: Int = 200
    ) -> [(begin: UInt64, end: UInt64)]
}
```

#### 使用例

```swift
// ドローン追跡（3D）
@Recordable
struct Drone {
    #PrimaryKey<Drone>([\.id])
    #Index<Drone>([\.hilbert3D])

    var id: Int64
    var latitude: Double
    var longitude: Double
    var altitude: Double

    // ✅ 3D Hilbert Curve Index
    var hilbert3D: Int64 {
        let normLat = (latitude + 90.0) / 180.0
        let normLon = (longitude + 180.0) / 360.0
        let normAlt = altitude / 10000.0  // 0-10km

        return Int64(bitPattern: HilbertCurve3D.encode(
            x: normLon,
            y: normLat,
            z: normAlt,
            order: 21
        ))
    }
}

// 3D Bounding box検索
let ranges = HilbertCurve3D.boundingBoxToRanges(
    minX: (centerLon - 0.1 + 180.0) / 360.0,
    maxX: (centerLon + 0.1 + 180.0) / 360.0,
    minY: (centerLat - 0.1 + 90.0) / 180.0,
    maxY: (centerLat + 0.1 + 90.0) / 180.0,
    minZ: 100.0 / 10000.0,
    maxZ: 500.0 / 10000.0,
    order: 21
)

// Range検索
var dronesInAirspace: [Drone] = []
for (begin, end) in ranges {
    let batch = try await store.query()
        .where(\.hilbert3D, .greaterThanOrEqual, Int64(bitPattern: begin))
        .where(\.hilbert3D, .lessThan, Int64(bitPattern: end))
        .execute()

    dronesInAirspace.append(contentsOf: batch)
}
```

### 実装詳細

#### 2D Hilbert Encoding

```swift
public static func encode(x: Double, y: Double, order: Int = 21) -> UInt64 {
    precondition((0.0...1.0).contains(x), "x must be in [0, 1]")
    precondition((0.0...1.0).contains(y), "y must be in [0, 1]")
    precondition((1...21).contains(order), "order must be in [1, 21]")

    let n = 1 << order  // 2^order
    let xi = Int(x * Double(n - 1))
    let yi = Int(y * Double(n - 1))

    return xyToHilbert(x: xi, y: yi, order: order)
}

/// XY座標 → Hilbert index（状態機械アルゴリズム）
private static func xyToHilbert(x: Int, y: Int, order: Int) -> UInt64 {
    var index: UInt64 = 0
    var n = 1 << order
    var rx: Int = 0
    var ry: Int = 0
    var s = n / 2
    var x = x
    var y = y

    while s > 0 {
        rx = (x & s) > 0 ? 1 : 0
        ry = (y & s) > 0 ? 1 : 0

        // 2ビットを追加
        index += UInt64(s * s * ((3 * rx) ^ ry))

        // 回転（Hilbert曲線の特性）
        rotate(n: s, x: &x, y: &y, rx: rx, ry: ry)

        s /= 2
    }

    return index
}

/// 回転変換（Hilbert曲線の核心）
private static func rotate(n: Int, x: inout Int, y: inout Int, rx: Int, ry: Int) {
    if ry == 0 {
        if rx == 1 {
            x = n - 1 - x
            y = n - 1 - y
        }
        swap(&x, &y)
    }
}
```

#### Bounding Box → Ranges

```swift
public static func boundingBoxToRanges(
    minX: Double, maxX: Double,
    minY: Double, maxY: Double,
    order: Int = 21,
    maxRanges: Int = 100
) -> [(begin: UInt64, end: UInt64)] {

    var ranges: [(UInt64, UInt64)] = []

    // Quad-tree分割アルゴリズム
    func subdivide(
        level: Int,
        cellMinX: Double, cellMaxX: Double,
        cellMinY: Double, cellMaxY: Double
    ) {
        // 現在のセルがbounding boxと交差するか
        if cellMaxX < minX || cellMinX > maxX ||
           cellMaxY < minY || cellMinY > maxY {
            return  // 交差なし
        }

        // 完全に含まれるか
        if cellMinX >= minX && cellMaxX <= maxX &&
           cellMinY >= minY && cellMaxY <= maxY {
            // このセル全体をRangeに追加
            let beginIdx = encode(x: cellMinX, y: cellMinY, order: order)
            let endIdx = encode(x: cellMaxX, y: cellMaxY, order: order)
            ranges.append((beginIdx, endIdx + 1))
            return
        }

        // 最大レベルに達したか
        if level >= order {
            let idx = encode(x: cellMinX, y: cellMinY, order: order)
            ranges.append((idx, idx + 1))
            return
        }

        // 4分割して再帰
        let midX = (cellMinX + cellMaxX) / 2.0
        let midY = (cellMinY + cellMaxY) / 2.0

        subdivide(level: level + 1, cellMinX: cellMinX, cellMaxX: midX, cellMinY: cellMinY, cellMaxY: midY)
        subdivide(level: level + 1, cellMinX: midX, cellMaxX: cellMaxX, cellMinY: cellMinY, cellMaxY: midY)
        subdivide(level: level + 1, cellMinX: cellMinX, cellMaxX: midX, cellMinY: midY, cellMaxY: cellMaxY)
        subdivide(level: level + 1, cellMinX: midX, cellMaxX: cellMaxX, cellMinY: midY, cellMaxY: cellMaxY)
    }

    subdivide(level: 0, cellMinX: 0.0, cellMaxX: 1.0, cellMinY: 0.0, cellMaxY: 1.0)

    // Range数が多すぎる場合、マージ
    if ranges.count > maxRanges {
        ranges = mergeRanges(ranges, maxRanges: maxRanges)
    }

    return ranges
}
```

---

## 実装ガイドライン

### ファイル構成

```
Sources/FDBRecordLayer/Spatial/
├── Geohash.swift                    # ✅ 完了
├── MortonCode.swift                 # ✅ 完了
├── S2CellID.swift                   # 🎯 新規
├── S2RegionCoverer.swift            # 🎯 新規
├── HilbertCurve2D.swift             # 🎯 新規
├── HilbertCurve3D.swift             # 🎯 新規
└── SpatialUtils.swift               # 🎯 新規（共通関数）

Tests/FDBRecordLayerTests/Spatial/
├── GeohashTests.swift               # ✅ 完了（27テスト）
├── MortonCodeTests.swift            # ✅ 完了（30テスト）
├── S2CellIDTests.swift              # 🎯 新規
├── S2RegionCovererTests.swift       # 🎯 新規
├── HilbertCurve2DTests.swift        # 🎯 新規
├── HilbertCurve3DTests.swift        # 🎯 新規
└── SpatialBenchmarkTests.swift      # 🎯 新規（比較ベンチマーク）
```

### コーディング規約

1. **型安全性**: すべてのパラメータに範囲チェック（precondition）
2. **ドキュメント**: すべてのpublic APIにDocコメント
3. **テスト**: 各関数に最低3テスト（正常系、エッジケース、エラー系）
4. **パフォーマンス**: 計算コストの高い部分はLUT（Look-Up Table）で最適化
5. **Sendable準拠**: すべての型をSendableに

### 依存関係

- **Swift Standard Library**のみ（外部依存なし）
- Geohash, MortonCodeとの互換性維持
- FoundationDB (fdb-swift-bindings)

---

## テスト戦略

### ユニットテスト

#### S2CellID

```swift
@Test("S2CellID encoding round-trip")
func testS2EncodingRoundTrip() {
    let testCases: [(lat: Double, lon: Double)] = [
        (35.6812, 139.7671),  // Tokyo
        (51.5074, -0.1278),   // London
        (0.0, 0.0),           // Equator/Prime Meridian
        (89.9, 0.0),          // North Pole
        (-89.9, 0.0),         // South Pole
        (0.0, 179.9),         // Near dateline
        (0.0, -179.9)         // Near dateline (west)
    ]

    for (origLat, origLon) in testCases {
        let cell = S2CellID(lat: origLat, lon: origLon, level: 20)
        let (decodedLat, decodedLon) = cell.toLatLon()

        // Level 20 ≈ 100m² → ±0.0001度以内
        #expect(abs(decodedLat - origLat) < 0.0001)
        #expect(abs(decodedLon - origLon) < 0.0001)
    }
}

@Test("S2CellID parent-child relationship")
func testS2Hierarchy() {
    let cell = S2CellID(lat: 35.6812, lon: 139.7671, level: 20)

    // 親セル取得
    let parent = cell.parent(level: 15)
    #expect(parent.level == 15)

    // 子セル取得
    let children = parent.children()
    #expect(children.count == 4)

    // 親→子→孫の関係
    #expect(children.contains { $0.rawValue == cell.rawValue })
}

@Test("S2CellID dateline handling")
func testS2Dateline() {
    // 日付変更線付近
    let west = S2CellID(lat: 0.0, lon: 179.9, level: 20)
    let east = S2CellID(lat: 0.0, lon: -179.9, level: 20)

    // 異なるセルIDを持つ
    #expect(west.rawValue != east.rawValue)

    // デコードで正しい座標に戻る
    let (latW, lonW) = west.toLatLon()
    let (latE, lonE) = east.toLatLon()

    #expect(lonW > 179.0)
    #expect(lonE < -179.0)
}
```

#### HilbertCurve2D

```swift
@Test("Hilbert 2D encoding round-trip")
func testHilbert2DRoundTrip() {
    for _ in 0..<100 {
        let x = Double.random(in: 0.0...1.0)
        let y = Double.random(in: 0.0...1.0)

        let index = HilbertCurve2D.encode(x: x, y: y, order: 21)
        let (decodedX, decodedY) = HilbertCurve2D.decode(index, order: 21)

        // Order 21 → 2^21 = 2M cells → 精度 1/2M ≈ 0.0000005
        #expect(abs(decodedX - x) < 0.000001)
        #expect(abs(decodedY - y) < 0.000001)
    }
}

@Test("Hilbert 2D locality preservation")
func testHilbert2DLocality() {
    // 近い座標 → 近いインデックス
    let index1 = HilbertCurve2D.encode(x: 0.5, y: 0.5, order: 21)
    let index2 = HilbertCurve2D.encode(x: 0.50001, y: 0.50001, order: 21)

    let diff = abs(Int64(bitPattern: index1) - Int64(bitPattern: index2))

    // 非常に近い座標 → インデックス差は小さい
    #expect(diff < 1000)
}

@Test("Hilbert vs Morton range count")
func testHilbertVsMortonRanges() {
    let minX = 0.4, maxX = 0.6
    let minY = 0.4, maxY = 0.6

    let hilbertRanges = HilbertCurve2D.boundingBoxToRanges(
        minX: minX, maxX: maxX,
        minY: minY, maxY: maxY,
        order: 21
    )

    let mortonRanges = MortonCode.boundingBoxToRanges(
        minX: minX, maxX: maxX,
        minY: minY, maxY: maxY
    )

    print("Hilbert ranges: \(hilbertRanges.count)")
    print("Morton ranges: \(mortonRanges.count)")

    // Hilbert は Morton より Range 数が少ない（連続性が高い）
    #expect(hilbertRanges.count < mortonRanges.count)
}
```

### 統合テスト

```swift
@Test("S2 vs Geohash comparison")
func testS2VsGeohashComparison() async throws {
    // 同じレストランデータで比較
    @Recordable
    struct Restaurant {
        #PrimaryKey<Restaurant>([\.id])
        #Index<Restaurant>([\.s2Cell20])
        #Index<Restaurant>([\.geohash7])

        var id: Int64
        var latitude: Double
        var longitude: Double

        var s2Cell20: Int64 {
            S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
        }

        var geohash7: String {
            Geohash.encode(latitude: latitude, longitude: longitude, precision: 7)
        }
    }

    let store = try await Restaurant.store(database: database, schema: schema)

    // 1000件のレストランを保存
    for i in 0..<1000 {
        let restaurant = Restaurant(
            id: Int64(i),
            latitude: 35.6 + Double.random(in: -0.1...0.1),
            longitude: 139.7 + Double.random(in: -0.1...0.1)
        )
        try await store.save(restaurant)
    }

    // Bounding box検索（S2）
    let s2Start = Date()
    let s2Results = try await queryWithS2(
        minLat: 35.65, maxLat: 35.70,
        minLon: 139.75, maxLon: 139.80
    )
    let s2Duration = Date().timeIntervalSince(s2Start)

    // Bounding box検索（Geohash）
    let geohashStart = Date()
    let geohashResults = try await queryWithGeohash(
        minLat: 35.65, maxLat: 35.70,
        minLon: 139.75, maxLon: 139.80
    )
    let geohashDuration = Date().timeIntervalSince(geohashStart)

    print("S2: \(s2Results.count) results in \(s2Duration)s")
    print("Geohash: \(geohashResults.count) results in \(geohashDuration)s")

    // 結果数はほぼ同じはず
    #expect(abs(s2Results.count - geohashResults.count) < 10)
}
```

### パフォーマンステスト

```swift
@Test("S2 encoding performance")
func testS2EncodingPerformance() {
    let iterations = 100_000

    let start = Date()
    for _ in 0..<iterations {
        let lat = Double.random(in: -90...90)
        let lon = Double.random(in: -180...180)
        _ = S2CellID(lat: lat, lon: lon, level: 20)
    }
    let duration = Date().timeIntervalSince(start)

    let perSecond = Double(iterations) / duration
    print("S2 encoding: \(perSecond) ops/sec")

    // 目標: 100K ops/sec以上
    #expect(perSecond > 100_000)
}

@Test("Hilbert encoding performance")
func testHilbertEncodingPerformance() {
    let iterations = 100_000

    let start = Date()
    for _ in 0..<iterations {
        let x = Double.random(in: 0...1)
        let y = Double.random(in: 0...1)
        _ = HilbertCurve2D.encode(x: x, y: y, order: 21)
    }
    let duration = Date().timeIntervalSince(start)

    let perSecond = Double(iterations) / duration
    print("Hilbert encoding: \(perSecond) ops/sec")

    // 目標: 500K ops/sec以上（Mortonより遅いが許容範囲）
    #expect(perSecond > 500_000)
}
```

---

## パフォーマンス特性

### エンコード/デコード性能

| アルゴリズム | エンコード | デコード | 実装複雑度 |
|------------|-----------|---------|-----------|
| **Geohash** | ~1M ops/sec | ~1M ops/sec | 低 |
| **S2 Geometry** | ~100K ops/sec | ~100K ops/sec | 高 |
| **Morton** | ~2M ops/sec | ~2M ops/sec | 低 |
| **Hilbert 2D** | ~500K ops/sec | ~500K ops/sec | 中 |
| **Hilbert 3D** | ~300K ops/sec | ~300K ops/sec | 中 |

### Range分割数（Bounding box検索）

| アルゴリズム | 平均Range数 | 最悪ケース |
|------------|-----------|-----------|
| **Geohash** | 10-20 | 100 |
| **S2 Geometry** | 4-8 | 20 |
| **Morton** | 50-100 | 500 |
| **Hilbert 2D** | 10-20 | 100 |
| **Hilbert 3D** | 20-40 | 200 |

### メモリ使用量

| アルゴリズム | インデックスサイズ（1M レコード） |
|------------|---------------------------|
| **Geohash** | ~15 MB（文字列7文字） |
| **S2 Geometry** | ~8 MB（UInt64） |
| **Morton** | ~8 MB（UInt64） |
| **Hilbert** | ~8 MB（UInt64） |

### 精度比較

| アルゴリズム | 精度（均一性） | 極地での精度 |
|------------|-------------|------------|
| **Geohash** | 緯度で歪む（±10-100m） | 大幅に低下（数km） |
| **S2 Geometry** | 球面で均一（±10m） | 均一（±10m） |
| **Morton** | 均一（正規化範囲内） | N/A（Cartesian） |
| **Hilbert** | 均一（正規化範囲内） | N/A（Cartesian） |

---

## マイグレーション戦略

### Geohash → S2 Geometry

#### ステップ1: 両方のインデックスを並行運用

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.id])

    // 既存（互換性維持）
    #Index<Restaurant>([\.geohash7], name: "restaurant_by_geohash")

    // 新規（高精度）
    #Index<Restaurant>([\.s2Cell20], name: "restaurant_by_s2")

    var id: Int64
    var latitude: Double
    var longitude: Double

    var geohash7: String {
        Geohash.encode(latitude: latitude, longitude: longitude, precision: 7)
    }

    var s2Cell20: Int64 {
        S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
    }
}
```

#### ステップ2: クエリをS2に切り替え

```swift
// 旧実装（Geohash）
let geohashes = Geohash.coveringGeohashes(
    minLat: minLat, minLon: minLon,
    maxLat: maxLat, maxLon: maxLon,
    precision: 7
)

var results: [Restaurant] = []
for geohash in geohashes {
    let batch = try await store.query()
        .where(\.geohash7, .hasPrefix, geohash)
        .execute()
    results.append(contentsOf: batch)
}

// 新実装（S2）
let coverer = S2RegionCoverer(maxCells: 8, maxLevel: 20)
let cells = coverer.getCovering(
    minLat: minLat, maxLat: maxLat,
    minLon: minLon, maxLon: maxLon
)

var results: [Restaurant] = []
for cell in cells {
    let cellMin = cell.rawValue
    let cellMax = cell.children().last!.rawValue + 1

    let batch = try await store.query()
        .where(\.s2Cell20, .greaterThanOrEqual, cellMin)
        .where(\.s2Cell20, .lessThan, cellMax)
        .execute()

    results.append(contentsOf: batch)
}
```

#### ステップ3: Geohashインデックスを削除（オプション）

```swift
// スキーマから geohash7 インデックスを削除
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.id])
    #Index<Restaurant>([\.s2Cell20])

    var id: Int64
    var latitude: Double
    var longitude: Double

    var s2Cell20: Int64 {
        S2CellID(lat: latitude, lon: longitude, level: 20).rawValue
    }

    // geohash7 は削除（computed property自体は残してもOK）
}
```

### Morton → Hilbert Curve

#### 同様のステップ

1. 両方のインデックスを並行運用
2. クエリをHilbertに切り替え
3. Mortonインデックスを削除（オプション）

```swift
@Recordable
struct GameEntity {
    #PrimaryKey<GameEntity>([\.id])

    // 既存
    #Index<GameEntity>([\.mortonCode], name: "entity_by_morton")

    // 新規（高精度）
    #Index<GameEntity>([\.hilbertIndex], name: "entity_by_hilbert")

    var id: Int64
    var x: Double
    var y: Double

    var mortonCode: Int64 {
        Int64(bitPattern: MortonCode.encode2D(x: x / 10000, y: y / 10000))
    }

    var hilbertIndex: Int64 {
        Int64(bitPattern: HilbertCurve2D.encode(x: x / 10000, y: y / 10000, order: 21))
    }
}
```

---

## 実装スケジュール

### Phase 2.1: S2 Geometry（1週間）

| タスク | 推定工数 | 優先度 |
|--------|---------|--------|
| **S2CellID.swift** | 2日 | P0 |
| **S2RegionCoverer.swift** | 2日 | P0 |
| **S2CellIDTests.swift** | 1日 | P0 |
| **S2RegionCovererTests.swift** | 1日 | P0 |
| **統合テスト** | 1日 | P1 |

### Phase 2.2: Hilbert Curve（1週間）

| タスク | 推定工数 | 優先度 |
|--------|---------|--------|
| **HilbertCurve2D.swift** | 2日 | P0 |
| **HilbertCurve3D.swift** | 2日 | P0 |
| **HilbertCurve2DTests.swift** | 1日 | P0 |
| **HilbertCurve3DTests.swift** | 1日 | P0 |
| **統合テスト** | 1日 | P1 |

### Phase 2.3: 比較・ドキュメント（3-5日）

| タスク | 推定工数 | 優先度 |
|--------|---------|--------|
| **ベンチマークテスト** | 1日 | P1 |
| **比較レポート** | 1日 | P1 |
| **マイグレーションガイド** | 1日 | P1 |
| **CLAUDE.md更新** | 0.5日 | P1 |
| **サンプルコード** | 0.5日 | P2 |

**合計推定工数**: 17-19日（Phase 2.1 + 2.2 + 2.3）

---

## 参考資料

### S2 Geometry

- [S2 Geometry Library (Google)](https://s2geometry.io/)
- [S2 Cells (Wikipedia)](https://en.wikipedia.org/wiki/S2_Geometry)
- [Google S2 Geometry (GitHub)](https://github.com/google/s2geometry)
- [Bigtable: A Distributed Storage System](https://research.google/pubs/pub27898/)

### Hilbert Curve

- [Hilbert Curve (Wikipedia)](https://en.wikipedia.org/wiki/Hilbert_curve)
- [Space-Filling Curves and Mathematical Programming](https://dl.acm.org/doi/10.1145/2983323.2983650)
- [Apache Sedona (Hilbert R-tree)](https://sedona.apache.org/)

### FoundationDB

- [FoundationDB Documentation](https://apple.github.io/foundationdb/)
- [fdb-swift-bindings](https://github.com/kirilltitov/FDBSwift)

---

**Last Updated**: 2025-01-16
**Status**: Active Design Document
**Next Review**: After Phase 2.1 completion
