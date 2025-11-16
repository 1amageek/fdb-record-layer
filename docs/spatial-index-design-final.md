# Spatial Index 設計仕様書（最終版）

**Status**: Final Design
**Version**: 1.0
**Last Updated**: 2025-01-16
**Author**: Record Layer Team

---

## 目次

1. [概要](#概要)
2. [設計原則](#設計原則)
3. [SpatialType仕様](#spatialtype仕様)
4. [@Spatialマクロ仕様](#spatialマクロ仕様)
5. [実装状況](#実装状況)
6. [使用例](#使用例)
7. [アルゴリズム詳細](#アルゴリズム詳細)
8. [内部実装](#内部実装)

---

## 概要

Spatial Indexは、地理座標や直交座標に対して効率的な空間検索を可能にするインデックスです。

### 重要な設計決定

1. **levelはSpatialTypeの引数**: 各座標系で意味が異なるため、typeの中に含める
2. **デフォルトlevel=20**: ほとんどのユースケースに最適
3. **KeyPath方式**: ネスト構造対応、柔軟なフィールド指定
4. **Model分離**: インデックス名以外の設定はModelに含めない

---

## 設計原則

### 1. Model分離

**原則**: Modelは純粋なデータ構造であるべき

```swift
// ✅ 正しい: Modelは座標フィールドの宣言のみ
@Recordable
struct Place {
    #PrimaryKey<Place>([\.placeID])

    @Spatial(
        type: .geo(latitude: \.location.latitude, longitude: \.location.longitude),
        name: "by_location"  // ✅ nameはインデックス識別のため許可
    )
    var location: Location

    var placeID: Int64
}

// ❌ 間違い: 実行時設定をModelに含めない
@Spatial(
    type: .geo(...),
    searchRadius: 5000,     // ❌ Query時のパラメータ
    minResults: 10          // ❌ Query時のパラメータ
)
```

### 2. levelはtypeに紐づく

**理由**: 座標系によってlevelの意味が異なる

- `.geo` / `.geo3D`: S2Cellレベル (0-30)
- `.cartesian` / `.cartesian3D`: Morton Codeビット深度 (0-32)

```swift
// ✅ 正しい: levelはtypeの引数
.geo(latitude: \.lat, longitude: \.lon, level: 20)

// ❌ 間違い: levelを外に出さない
@Spatial(type: .geo(...), level: 20)
```

### 3. KeyPath方式

**理由**: ネスト構造対応、型安全性

```swift
// ✅ ネストされたフィールドを直接指定
.geo(latitude: \.address.location.coordinates.latitude, ...)
```

---

## SpatialType仕様

### 定義

```swift
public enum SpatialType: Sendable, Equatable {
    /// 2D地理座標 (S2 Geometry + Hilbert Curve)
    ///
    /// - Parameters:
    ///   - latitude: 緯度を返すKeyPath文字列 (例: "\.latitude", "\.address.location.latitude")
    ///   - longitude: 経度を返すKeyPath文字列 (例: "\.longitude", "\.address.location.longitude")
    ///   - level: S2Cellレベル (0-30, デフォルト: 20)
    ///
    /// **Level精度**:
    /// - Level 10: ~156km (国/州レベル)
    /// - Level 15: ~1.2km (都市レベル)
    /// - Level 20: ~1.5cm (建物/店舗レベル) ← デフォルト
    /// - Level 25: ~0.6mm (超高精度)
    /// - Level 30: ~1cm (最高精度)
    case geo(latitude: String, longitude: String, level: Int = 20)

    /// 3D地理座標 (S2 Geometry + Hilbert Curve + 高度)
    ///
    /// - Parameters:
    ///   - latitude: 緯度を返すKeyPath文字列
    ///   - longitude: 経度を返すKeyPath文字列
    ///   - altitude: 高度を返すKeyPath文字列 (メートル単位)
    ///   - level: S2Cellレベル (0-30, デフォルト: 20)
    ///
    /// **用途**: ドローン、航空機、3D地理座標
    case geo3D(latitude: String, longitude: String, altitude: String, level: Int = 20)

    /// 2D直交座標 (Z-order curve / Morton Code)
    ///
    /// - Parameters:
    ///   - x: X座標を返すKeyPath文字列
    ///   - y: Y座標を返すKeyPath文字列
    ///   - level: Morton Codeビット深度 (0-32, デフォルト: 20)
    ///
    /// **Level精度**:
    /// - Level 10: 2^10 = 1024グリッド
    /// - Level 16: 2^16 = 65,536グリッド
    /// - Level 20: 2^20 = 1,048,576グリッド ← デフォルト
    /// - Level 32: 2^32 = 4,294,967,296グリッド (最大)
    ///
    /// **用途**: マップエディタ、2Dゲーム、平面座標
    case cartesian(x: String, y: String, level: Int = 20)

    /// 3D直交座標 (3D Z-order curve)
    ///
    /// - Parameters:
    ///   - x: X座標を返すKeyPath文字列
    ///   - y: Y座標を返すKeyPath文字列
    ///   - z: Z座標を返すKeyPath文字列
    ///   - level: Morton Codeビット深度 (0-21, デフォルト: 20)
    ///
    /// **Level精度**:
    /// - Level 10: 2^10 = 1024^3 グリッド
    /// - Level 20: 2^20 = 1,048,576^3 グリッド ← デフォルト
    /// - Level 21: 2^21 = 2,097,152^3 グリッド (最大、64bit制限)
    ///
    /// **用途**: 3Dゲーム、CAD、3D空間シミュレーション
    case cartesian3D(x: String, y: String, z: String, level: Int = 20)
}
```

### プロパティ

```swift
extension SpatialType {
    /// 次元数 (2 or 3)
    public var dimensions: Int {
        switch self {
        case .geo, .cartesian:
            return 2
        case .geo3D, .cartesian3D:
            return 3
        }
    }

    /// levelの有効範囲を検証
    public var isValidLevel: Bool {
        switch self {
        case .geo(_, _, let level), .geo3D(_, _, _, let level):
            return level >= 0 && level <= 30  // S2Cell制限
        case .cartesian(_, _, let level):
            return level >= 0 && level <= 32  // 2D Morton Code制限
        case .cartesian3D(_, _, _, let level):
            return level >= 0 && level <= 21  // 3D Morton Code制限 (64bit)
        }
    }

    /// 使用するアルゴリズム
    public var algorithm: String {
        switch self {
        case .geo, .geo3D:
            return "S2 Geometry + Hilbert Curve"
        case .cartesian, .cartesian3D:
            return "Z-order curve (Morton Code)"
        }
    }
}
```

---

## @Spatialマクロ仕様

### シグネチャ

```swift
@attached(peer)
public macro Spatial(
    type: SpatialType,    // 必須: 座標系とKeyPath
    name: String? = nil   // オプション: インデックス名（デフォルト: 自動生成）
)
```

### パラメータ詳細

| パラメータ | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `type` | `SpatialType` | ✅ | 座標系、KeyPath、levelを含む |
| `name` | `String?` | ❌ | インデックス名（省略時は自動生成） |

### インデックス名の自動生成ルール

```swift
// プロパティ名: location
// 生成されるインデックス名: "Place_location_spatial"

@Spatial(type: .geo(latitude: \.lat, longitude: \.lon))
var location: Location
// → インデックス名: "Place_location_spatial"

// 明示的に指定
@Spatial(
    type: .geo(latitude: \.lat, longitude: \.lon),
    name: "by_location"  // ✅ 明示的
)
var location: Location
// → インデックス名: "by_location"
```

---

## 実装状況

### ✅ 完了

- S2CellID実装（.geo / .geo3D用）
- S2CellID座標変換パイプライン
- S2CellID階層操作（parent/children）
- S2CellID隣接セル（edgeNeighbors）
- S2CellIDテスト（30テスト合格）
- @Spatialマクロ（KeyPath方式）
- SpatialType定義

### 🚧 実装中

- SpatialIndexMaintainer（現在エラー投げる状態）
- QueryBuilder空間クエリAPI

### ⏳ 未実装

- Z-order curve / Morton Code（.cartesian / .cartesian3D用）
- S2RegionCoverer（範囲を複数S2Cellでカバー）
- HilbertCurve2D/3D（汎用ユーティリティ）

---

## 使用例

### 例1: シンプルな2D地理座標（デフォルトlevel）

```swift
import FDBRecordCore

@Recordable
struct Place {
    #PrimaryKey<Place>([\.placeID])

    // ✅ levelを省略 → デフォルト20
    @Spatial(type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude
    ))
    var location: Location

    var placeID: Int64
    var name: String
}

struct Location: Codable, Sendable {
    var latitude: Double
    var longitude: Double
}
```

### 例2: 高精度インデックス（level明示）

```swift
@Recordable
struct PreciseLocation {
    #PrimaryKey<PreciseLocation>([\.id])

    // ✅ Level 25 → ~0.6mm精度
    @Spatial(
        type: .geo(
            latitude: \.coordinates.lat,
            longitude: \.coordinates.lon,
            level: 25  // 高精度
        ),
        name: "precise_location"
    )
    var coordinates: Coordinates

    var id: Int64
}
```

### 例3: 3D地理座標（ドローン）

```swift
@Recordable
struct Drone {
    #PrimaryKey<Drone>([\.droneID])

    @Spatial(
        type: .geo3D(
            latitude: \.position.lat,
            longitude: \.position.lon,
            altitude: \.position.height,
            level: 20
        ),
        name: "by_position"
    )
    var position: Position

    var droneID: Int64
    var status: String
}

struct Position: Codable, Sendable {
    var lat: Double
    var lon: Double
    var height: Double  // メートル単位
}
```

### 例4: ネスト構造

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])

    // ✅ 深くネストされたフィールド
    @Spatial(
        type: .geo(
            latitude: \.address.location.coordinates.latitude,
            longitude: \.address.location.coordinates.longitude,
            level: 20
        ),
        name: "by_address_location"
    )
    var address: Address

    var restaurantID: Int64
}

struct Address: Codable, Sendable {
    var street: String
    var city: String
    var location: LocationInfo
}

struct LocationInfo: Codable, Sendable {
    var coordinates: Coordinates
    var zipCode: String
}

struct Coordinates: Codable, Sendable {
    var latitude: Double
    var longitude: Double
}
```

### 例5: 複数の空間インデックス

```swift
@Recordable
struct Delivery {
    #PrimaryKey<Delivery>([\.deliveryID])

    // 出発地
    @Spatial(
        type: .geo(
            latitude: \.origin.latitude,
            longitude: \.origin.longitude
        ),
        name: "by_origin"
    )
    var origin: Location

    // 目的地
    @Spatial(
        type: .geo(
            latitude: \.destination.latitude,
            longitude: \.destination.longitude
        ),
        name: "by_destination"
    )
    var destination: Location

    var deliveryID: Int64
    var status: String
}
```

### 例6: 直交座標（2Dゲーム）

```swift
@Recordable
struct GameObject {
    #PrimaryKey<GameObject>([\.objectID])

    @Spatial(
        type: .cartesian(
            x: \.position.x,
            y: \.position.y,
            level: 16  // 2^16 = 65,536グリッド
        ),
        name: "by_position"
    )
    var position: CGPoint

    var objectID: Int64
    var objectType: String
}
```

### 例7: 3D直交座標（3Dゲーム）

```swift
@Recordable
struct Particle {
    #PrimaryKey<Particle>([\.particleID])

    @Spatial(
        type: .cartesian3D(
            x: \.position.x,
            y: \.position.y,
            z: \.position.z,
            level: 20  // 2^20 = 1,048,576^3 グリッド
        ),
        name: "by_3d_position"
    )
    var position: SIMD3<Double>

    var particleID: Int64
}
```

---

## アルゴリズム詳細

### S2 Geometry + Hilbert Curve (.geo, .geo3D)

**用途**: 地球の球面座標

**アルゴリズム**:
1. 地球を6つの立方体面に投影（Cube Map）
2. 各面をHilbert曲線で分割
3. 緯度・経度 → S2CellID (UInt64)

**Level精度表**:

| Level | セルサイズ | 精度 | 用途 |
|-------|-----------|------|------|
| 0 | ~85,000,000km² | 大陸 | 全球レベル |
| 5 | ~21,000km² | 国 | 国レベル検索 |
| 10 | ~156km² | 都市 | 都市レベル検索 |
| 15 | ~1.2km² | 地区 | 地区レベル検索 |
| **20** | **~1.5cm²** | **建物** | **店舗/建物検索（推奨）** |
| 25 | ~0.6mm² | 超高精度 | センチメートル精度 |
| 30 | ~1cm² | 最高精度 | ミリメートル精度 |

**Hilbert曲線の特性**:
- 局所性保持: 近い座標 → 近いCellID
- Z-order curveより優れた局所性
- Range読み取りで効率的な近傍検索

**実装状況**: ✅ 完了（S2CellID.swift）

---

### Z-order curve / Morton Code (.cartesian, .cartesian3D)

**用途**: 平面/3D空間の直交座標

**アルゴリズム**:
1. X, Y (,Z) 座標をビット交互配置
2. 1次元の整数値にエンコード

**2D Morton Code例**:
```
X = 5 = 0b101
Y = 3 = 0b011

Morton Code:
Y: 0  1  1
X: 1  0  1
   ↓  ↓  ↓
   011011 = 27
```

**3D Morton Code例**:
```
X = 5 = 0b101
Y = 3 = 0b011
Z = 2 = 0b010

Morton Code:
Z: 0  1  0
Y: 0  1  1
X: 1  0  1
   ↓  ↓  ↓
   001101101 = 109
```

**Level制限**:
- 2D: Level 0-32 (64bit制限: 32bit × 2)
- 3D: Level 0-21 (64bit制限: 21bit × 3 = 63bit)

**実装状況**: ⏳ 未実装

---

## 内部実装

### マクロ展開

```swift
// ソースコード
@Recordable
struct Place {
    #PrimaryKey<Place>([\.placeID])

    @Spatial(type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude,
        level: 25
    ))
    var location: Location

    var placeID: Int64
}

// マクロ展開後
extension Place {
    static var indexDefinitions: [IndexDefinition] {
        [
            IndexDefinition(
                name: "Place_location_spatial",
                type: .spatial,
                fields: ["location"],
                spatialType: .geo(
                    latitude: "location.latitude",
                    longitude: "location.longitude",
                    level: 25  // ✅ typeに含まれる
                )
            )
        ]
    }
}
```

### IndexDefinition

```swift
public struct IndexDefinition: Sendable {
    public let name: String
    public let type: IndexType  // .spatial
    public let fields: [String]
    public let spatialType: SpatialType?  // ✅ levelを含む
}
```

### SpatialIndexMaintainer（実装予定）

```swift
final class SpatialIndexMaintainer<Record: Sendable>: IndexMaintainer {
    private let spatialType: SpatialType
    private let indexSubspace: Subspace

    func updateIndex(
        record: Record,
        transaction: TransactionProtocol
    ) async throws {
        let cellID: UInt64

        switch spatialType {
        case .geo(let latPath, let lonPath, let level):
            // KeyPathで値を抽出
            let lat = extractValue(from: record, keyPath: latPath) as! Double
            let lon = extractValue(from: record, keyPath: lonPath) as! Double

            // S2CellID生成（levelを使用）
            cellID = S2CellID(lat: lat, lon: lon, level: level).rawValue

        case .geo3D(let latPath, let lonPath, let altPath, let level):
            let lat = extractValue(from: record, keyPath: latPath) as! Double
            let lon = extractValue(from: record, keyPath: lonPath) as! Double
            let alt = extractValue(from: record, keyPath: altPath) as! Double

            // S2CellID + 高度エンコード
            cellID = encodeGeo3D(lat: lat, lon: lon, altitude: alt, level: level)

        case .cartesian(let xPath, let yPath, let level):
            let x = extractValue(from: record, keyPath: xPath) as! Double
            let y = extractValue(from: record, keyPath: yPath) as! Double

            // Morton Code生成（levelを使用）
            cellID = MortonCode.encode2D(x: x, y: y, level: level)

        case .cartesian3D(let xPath, let yPath, let zPath, let level):
            let x = extractValue(from: record, keyPath: xPath) as! Double
            let y = extractValue(from: record, keyPath: yPath) as! Double
            let z = extractValue(from: record, keyPath: zPath) as! Double

            // 3D Morton Code生成
            cellID = MortonCode.encode3D(x: x, y: y, z: z, level: level)
        }

        // インデックスキー構築
        let primaryKey = recordAccess.extractPrimaryKey(from: record)
        let indexKey = indexSubspace.pack(Tuple(cellID, primaryKey))

        // 書き込み
        transaction.setValue([], for: indexKey)
    }
}
```

---

## Query API（実装予定）

### 半径検索

```swift
let places = try await store.query(Place.self)
    .where(\.location, .withinRadius(
        center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
        radiusMeters: 5000
    ))
    .execute()
```

### バウンディングボックス検索

```swift
let places = try await store.query(Place.self)
    .where(\.location, .withinBounds(
        minLat: 35.5, maxLat: 35.9,
        minLon: 139.5, maxLon: 139.9
    ))
    .execute()
```

### 最近傍検索

```swift
let places = try await store.query(Place.self)
    .where(\.location, .nearest(
        to: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
        limit: 10
    ))
    .execute()
```

---

## まとめ

### 最終仕様

```swift
// @Spatialマクロ
@Spatial(
    type: .geo(latitude: KeyPath, longitude: KeyPath, level: Int = 20) |
          .geo3D(latitude: KeyPath, longitude: KeyPath, altitude: KeyPath, level: Int = 20) |
          .cartesian(x: KeyPath, y: KeyPath, level: Int = 20) |
          .cartesian3D(x: KeyPath, y: KeyPath, z: KeyPath, level: Int = 20),
    name: String? = nil
)
```

### 設計の要点

1. **levelはtypeの引数**: 各座標系で意味が異なるため
2. **デフォルトlevel=20**: ほとんどのユースケースに最適
3. **KeyPath方式**: ネスト構造対応、型安全
4. **name以外はModelに含めない**: 実行時パラメータは分離

### 実装優先順位

1. ✅ S2CellID（完了）
2. 🚧 SpatialIndexMaintainer（.geo / .geo3D対応）
3. ⏳ QueryBuilder空間クエリAPI
4. ⏳ Morton Code実装（.cartesian / .cartesian3D対応）
5. ⏳ S2RegionCoverer（範囲検索最適化）

---

**関連ドキュメント**:
- [S2CellID実装ガイド](s2cellid-implementation.md)
- [空間インデックス完全設計](spatial-indexing-complete-design.md)
- [QueryBuilder API仕様](query-builder-api.md)
