# @Spatial Macro 実装ガイド（KeyPath方式）

**Status**: Production Ready
**Version**: 1.0
**Last Updated**: 2025-01-16
**Author**: Record Layer Team

---

## 目次

1. [概要](#概要)
2. [基本的な使用方法](#基本的な使用方法)
3. [SpatialTypeの仕様](#spatialtypeの仕様)
4. [実装例](#実装例)
5. [KeyPath方式の利点](#keypath方式の利点)
6. [内部実装](#内部実装)
7. [クエリAPI](#クエリapi)
8. [ベストプラクティス](#ベストプラクティス)

---

## 概要

`@Spatial`マクロは、地理座標や直交座標に対して空間インデックスを自動生成するための**プロパティマクロ**です。

### 重要な設計原則

**KeyPath方式**: `@Spatial`は座標フィールドへの**KeyPath**を引数として受け取ります。これにより：

1. **ネスト構造対応**: 深い階層のフィールドにも対応
2. **柔軟なフィールド名**: `latitude`, `lat`, `緯度` など任意の名前を使用可能
3. **型安全性**: コンパイル時にKeyPathの存在と型をチェック
4. **複数フィールド組み合わせ**: 異なるプロパティから座標を構成可能

---

## 基本的な使用方法

### シンプルな2D地理座標

```swift
import FDBRecordCore

@Recordable
struct Place {
    #PrimaryKey<Place>([\.placeID])

    // ✅ @SpatialマクロでKeyPathを指定
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

### オプションパラメータ付き

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])

    @Spatial(
        type: .geo(
            latitude: \.location.latitude,
            longitude: \.location.longitude
        ),
        level: 20,      // S2Cellレベル（デフォルト: 20）
        name: "by_location"  // インデックス名（デフォルト: 自動生成）
    )
    var location: Location

    var restaurantID: Int64
}
```

---

## SpatialTypeの仕様

### 1. `.geo` - 2D地理座標

**用途**: 地球上の位置（緯度・経度）

**引数**:
- `latitude`: 緯度を返すKeyPath（Double型）
- `longitude`: 経度を返すKeyPath（Double型）

**例**:
```swift
@Spatial(type: .geo(
    latitude: \.location.latitude,
    longitude: \.location.longitude
))
var location: Location
```

**生成されるインデックス**:
- アルゴリズム: S2 Geometry + Hilbert Curve
- エンコーディング: S2CellID (UInt64)
- 精度: Level 20 で ~1.5cm

---

### 2. `.geo3D` - 3D地理座標

**用途**: 地球上の位置 + 高度（ドローン、航空機など）

**引数**:
- `latitude`: 緯度を返すKeyPath（Double型）
- `longitude`: 経度を返すKeyPath（Double型）
- `altitude`: 高度を返すKeyPath（Double型）

**例**:
```swift
@Recordable
struct Drone {
    #PrimaryKey<Drone>([\.droneID])

    @Spatial(type: .geo3D(
        latitude: \.position.lat,
        longitude: \.position.lon,
        altitude: \.position.height
    ))
    var position: Position

    var droneID: Int64
}

struct Position: Codable, Sendable {
    var lat: Double      // ✅ "latitude"ではなくても可
    var lon: Double      // ✅ "longitude"ではなくても可
    var height: Double   // ✅ "altitude"ではなくても可
}
```

---

### 3. `.cartesian` - 2D直交座標

**用途**: 平面上の位置（マップエディタ、ゲームなど）

**引数**:
- `x`: X座標を返すKeyPath（Double型）
- `y`: Y座標を返すKeyPath（Double型）

**例**:
```swift
@Recordable
struct GameObject {
    #PrimaryKey<GameObject>([\.objectID])

    @Spatial(type: .cartesian(
        x: \.position.x,
        y: \.position.y
    ))
    var position: CGPoint

    var objectID: Int64
}
```

---

### 4. `.cartesian3D` - 3D直交座標

**用途**: 3D空間上の位置（3Dゲーム、CADなど）

**引数**:
- `x`: X座標を返すKeyPath（Double型）
- `y`: Y座標を返すKeyPath（Double型）
- `z`: Z座標を返すKeyPath（Double型）

**例**:
```swift
@Recordable
struct Particle {
    #PrimaryKey<Particle>([\.particleID])

    @Spatial(type: .cartesian3D(
        x: \.position.x,
        y: \.position.y,
        z: \.position.z
    ))
    var position: SIMD3<Double>

    var particleID: Int64
}
```

---

## 実装例

### 例1: ネストされた構造

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])

    // ✅ 深くネストされたフィールドを直接指定
    @Spatial(type: .geo(
        latitude: \.address.location.coordinates.latitude,
        longitude: \.address.location.coordinates.longitude
    ))
    var address: Address

    var restaurantID: Int64
    var name: String
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

### 例2: 複数の空間フィールド

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

### 例3: 異なる型のフィールド

```swift
@Recordable
struct Weather {
    #PrimaryKey<Weather>([\.stationID])

    // ✅ 異なるプロパティから座標を構成
    @Spatial(type: .geo(
        latitude: \.stationLatitude,    // トップレベルのフィールド
        longitude: \.stationLongitude   // トップレベルのフィールド
    ))
    var stationLatitude: Double

    var stationLongitude: Double
    var stationID: Int64
    var temperature: Double
}
```

---

## KeyPath方式の利点

### 1. ネスト構造への完全対応

**従来の問題**:
```swift
// ❌ プロパティレベルでしか指定できない
@Spatial(type: .geo)
var location: Location  // location内のどのフィールドを使うか不明
```

**KeyPath方式の解決**:
```swift
// ✅ 任意の深さのフィールドを指定可能
@Spatial(type: .geo(
    latitude: \.address.location.coordinates.lat,
    longitude: \.address.location.coordinates.lon
))
var address: Address
```

### 2. 柔軟なフィールド命名

**従来の問題**:
```swift
// ❌ フィールド名が"latitude", "longitude"に固定される
struct Location {
    var latitude: Double   // 必須
    var longitude: Double  // 必須
}
```

**KeyPath方式の解決**:
```swift
// ✅ 任意のフィールド名を使用可能
struct Position {
    var lat: Double   // ✅ "lat"でも可
    var lng: Double   // ✅ "lng"でも可
}

@Spatial(type: .geo(
    latitude: \.position.lat,
    longitude: \.position.lng
))
var position: Position
```

### 3. 型安全性

**コンパイル時チェック**:
```swift
// ✅ コンパイル成功
@Spatial(type: .geo(
    latitude: \.location.latitude,   // Double型
    longitude: \.location.longitude  // Double型
))

// ❌ コンパイルエラー: フィールドが存在しない
@Spatial(type: .geo(
    latitude: \.location.lat,  // エラー: 'lat'プロパティは存在しない
    longitude: \.location.lon
))

// ❌ コンパイルエラー: 型が合わない
@Spatial(type: .geo(
    latitude: \.location.name,  // エラー: String型（Double期待）
    longitude: \.location.longitude
))
```

### 4. 複数フィールドの組み合わせ

```swift
@Recordable
struct Event {
    #PrimaryKey<Event>([\.eventID])

    // ✅ 異なるプロパティから座標を構成
    @Spatial(type: .cartesian(
        x: \.venue.x,
        y: \.venue.y
    ))
    var venue: Venue

    // ✅ 別の組み合わせも可能
    @Spatial(type: .cartesian(
        x: \.stage.centerX,
        y: \.stage.centerY
    ), name: "by_stage")
    var stage: Stage

    var eventID: Int64
}
```

---

## 内部実装

### マクロ展開

`@Spatial`マクロは以下のメタデータを生成します：

```swift
// ソースコード
@Recordable
struct Place {
    #PrimaryKey<Place>([\.placeID])

    @Spatial(type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude
    ), level: 20)
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
                spatialType: .geo,
                spatialOptions: SpatialIndexOptions(
                    level: 20,
                    enableHilbertCurve: true,
                    latitudeKeyPath: \Place.location.latitude,    // ✅ KeyPathを保存
                    longitudeKeyPath: \Place.location.longitude   // ✅ KeyPathを保存
                )
            )
        ]
    }
}
```

### SpatialIndexMaintainer

```swift
final class SpatialIndexMaintainer<Record: Sendable>: IndexMaintainer {
    private let latitudeKeyPath: KeyPath<Record, Double>
    private let longitudeKeyPath: KeyPath<Record, Double>
    private let level: Int

    func updateIndex(
        record: Record,
        transaction: TransactionProtocol
    ) async throws {
        // ✅ KeyPathで値を抽出
        let lat = record[keyPath: latitudeKeyPath]
        let lon = record[keyPath: longitudeKeyPath]

        // S2CellID生成
        let cellID = S2CellID(lat: lat, lon: lon, level: level)

        // インデックスキー構築
        let primaryKey = recordAccess.extractPrimaryKey(from: record)
        let indexKey = indexSubspace.pack(Tuple(cellID.rawValue, primaryKey))

        // 書き込み
        transaction.setValue([], for: indexKey)
    }
}
```

### インデックス構造

```
Subspace構造:
rootSubspace/
├── records/
│   └── Place/
│       └── {placeID}/
│           └── record data
├── indexes/
│   └── Place_location_spatial/
│       └── {s2CellID}/
│           └── {placeID} = ''
```

**インデックスキー**:
```
[indexSubspace][s2CellID (UInt64)][placeID] = ''
```

- `s2CellID`: KeyPathで抽出した座標をS2エンコード
- `placeID`: プライマリキー（タイブレーカー）
- 値は空（インデックスキーのみ）

---

## クエリAPI

### 半径検索

```swift
let store = try await Place.store(database: database, schema: schema)

// 東京駅から5km以内
let tokyo = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)

let places = try await store.query(Place.self)
    .where(\.location, .withinRadius(
        center: tokyo,
        radiusMeters: 5000
    ))
    .execute()
```

**内部処理**:
1. S2RegionCovererで半径5kmをカバーするS2Cellsを計算
2. 複数のRange読み取りに分解
3. False positiveを距離計算でフィルタ（KeyPathで座標抽出）

### バウンディングボックス検索

```swift
// 東京23区内
let places = try await store.query(Place.self)
    .where(\.location, .withinBounds(
        minLat: 35.5,
        maxLat: 35.9,
        minLon: 139.5,
        maxLon: 139.9
    ))
    .execute()
```

### 最近傍検索

```swift
// 東京駅に最も近い10件
let places = try await store.query(Place.self)
    .where(\.location, .nearest(
        to: tokyo,
        limit: 10
    ))
    .execute()
```

---

## ベストプラクティス

### 1. レベルの選択

| Level | 精度 | 用途 |
|-------|------|------|
| 10 | ~156km | 国/州レベルの検索 |
| 15 | ~1.2km | 都市レベルの検索 |
| 20 | ~1.5cm | 建物/店舗レベルの検索（推奨） |
| 25 | ~0.6mm | 超高精度検索 |
| 30 | ~1cm | 最高精度 |

**推奨**: Level 20（デフォルト）

```swift
@Spatial(
    type: .geo(latitude: \.lat, longitude: \.lon),
    level: 20  // ほとんどのユースケースに最適
)
```

### 2. インデックス名の命名規則

```swift
// ✅ 良い例: 検索目的が明確
@Spatial(
    type: .geo(latitude: \.lat, longitude: \.lon),
    name: "by_pickup_location"
)
var pickupLocation: Location

@Spatial(
    type: .geo(latitude: \.lat, longitude: \.lon),
    name: "by_delivery_location"
)
var deliveryLocation: Location

// ❌ 悪い例: 名前が重複
@Spatial(type: .geo(latitude: \.lat, longitude: \.lon))
var pickupLocation: Location  // 自動生成名が衝突する可能性

@Spatial(type: .geo(latitude: \.lat, longitude: \.lon))
var deliveryLocation: Location
```

### 3. ネスト構造の活用

```swift
// ✅ 推奨: 関連データをグループ化
struct Restaurant {
    var address: Address  // グループ化
    var menu: Menu
    var hours: BusinessHours
}

struct Address: Codable, Sendable {
    var street: String
    var city: String
    var location: Location  // 位置情報
}

@Spatial(type: .geo(
    latitude: \.address.location.latitude,
    longitude: \.address.location.longitude
))
var address: Address

// ❌ 非推奨: フラット構造
struct Restaurant {
    var street: String
    var city: String
    var latitude: Double   // フラット
    var longitude: Double  // フラット
}
```

### 4. 型安全性の活用

```swift
// ✅ 専用の型を定義
struct GeoLocation: Codable, Sendable {
    var latitude: Double
    var longitude: Double
}

struct Place {
    var location: GeoLocation  // 型で制約
}

// ❌ プリミティブ型の直接使用
struct Place {
    var latitude: Double   // 制約なし
    var longitude: Double  // 制約なし
}
```

---

## 制限事項と注意点

### 1. KeyPathの制約

```swift
// ✅ サポート: プロパティへのKeyPath
@Spatial(type: .geo(
    latitude: \.location.latitude,
    longitude: \.location.longitude
))

// ❌ 非サポート: 計算プロパティへのKeyPath
var computedLat: Double {
    return someCalculation()
}

@Spatial(type: .geo(
    latitude: \.computedLat,  // エラー: 計算プロパティは不可
    longitude: \.lon
))
```

### 2. 型の制約

KeyPathが返す値は**必ずDouble型**である必要があります：

```swift
// ✅ 正しい
var latitude: Double

// ❌ エラー
var latitude: Float        // Float型は不可
var latitude: Int          // Int型は不可
var latitude: String       // String型は不可
var latitude: Double?      // Optional型は不可
```

### 3. 座標範囲の検証

座標値は実行時に検証されます：

```swift
// 緯度: -90.0 ~ 90.0
// 経度: -180.0 ~ 180.0

// 範囲外の値はエラー
let invalidLat = 95.0  // エラー: 緯度は-90~90
let invalidLon = 200.0 // エラー: 経度は-180~180
```

---

## まとめ

### @Spatial マクロの仕様（最終版）

```swift
@Spatial(
    type: .geo(latitude: KeyPath, longitude: KeyPath) |
          .geo3D(latitude: KeyPath, longitude: KeyPath, altitude: KeyPath) |
          .cartesian(x: KeyPath, y: KeyPath) |
          .cartesian3D(x: KeyPath, y: KeyPath, z: KeyPath),
    level: Int = 20,        // オプション: S2Cellレベル
    name: String? = nil     // オプション: インデックス名
)
```

### 主要な利点

1. **KeyPath方式**: ネスト構造対応、柔軟な命名
2. **型安全**: コンパイル時チェック
3. **効率的**: S2 + Hilbert Curveで高速検索
4. **柔軟**: 複数の空間フィールドを同時にサポート

### 推奨事項

- Level 20を使用（ほとんどのユースケースに最適）
- ネスト構造でデータをグループ化
- 専用の型（Location, Position等）を定義
- インデックス名を明示的に指定（複数インデックス時）

---

**関連ドキュメント**:
- [S2CellID実装ガイド](s2cellid-implementation.md)
- [空間クエリAPI](spatial-query-api.md)
- [パフォーマンスチューニング](performance-tuning.md)
