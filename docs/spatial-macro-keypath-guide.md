# @Spatial Macro 実装ガイド（相対KeyPath方式）

**Status**: Production Ready
**Version**: 2.0
**Last Updated**: 2025-01-17
**Author**: Record Layer Team

---

## 目次

1. [概要](#概要)
2. [新しい設計（v2.0）](#新しい設計v20)
3. [基本的な使用方法](#基本的な使用方法)
4. [SpatialTypeの仕様](#spatialtypeの仕様)
5. [実装例](#実装例)
6. [相対KeyPath方式の利点](#相対keypath方式の利点)
7. [内部実装](#内部実装)
8. [クエリAPI](#クエリapi)
9. [ベストプラクティス](#ベストプラクティス)
10. [マイグレーションガイド](#マイグレーションガイド)

---

## 概要

`@Spatial`マクロは、地理座標や直交座標に対して空間インデックスを自動生成するための**プロパティマクロ**です。

### 重要な設計原則

**相対KeyPath方式（v2.0）**: `@Spatial`は座標フィールドへの**フィールド型を基準とした相対KeyPath**を引数として受け取ります。これにより：

1. **フィールド名の自動取得**: マクロがフィールド名を自動認識
2. **KeyPath合成**: マクロが `\Self.fieldName` + 相対KeyPath を自動合成
3. **型安全性**: コンパイル時にKeyPathの存在と型をチェック
4. **シンプルな記述**: フィールド名の重複を排除
5. **PartialKeyPath使用**: 柔軟性と型安全性のバランス

---

## 新しい設計（v2.0）

### v1.0からの主な変更

| 項目 | v1.0（旧） | v2.0（新） |
|------|-----------|-----------|
| **KeyPath基準** | Record型（絶対パス） | フィールド型（相対パス） |
| **フィールド名** | KeyPathに含める | 自動取得 |
| **level指定** | トップレベル引数 | type引数内 |
| **KeyPath型** | KeyPath<Self, Double> | PartialKeyPath<Self> |
| **SpatialRepresentable** | 使用 | **廃止** |

### 設計の改善点

1. **Mirror APIの完全排除**: Mirrorベースの実装を削除し、完全に型安全なKeyPath合成を実装
2. **パフォーマンス最適化**: 実行時KeyPath合成により、subscript呼び出しを1回に削減
3. **記述の簡潔化**: フィールド名の重複がなくなり、より自然な記述

---

## 基本的な使用方法

### シンプルな2D地理座標

```swift
import FDBRecordCore

@Recordable
struct Place {
    #PrimaryKey<Place>([\.placeID])

    // ✅ 相対KeyPath: フィールド型（Location）を基準に指定
    @Spatial(type: .geo(
        latitude: \.latitude,     // Location.latitude
        longitude: \.longitude,   // Location.longitude
        level: 17                 // S2Cellレベル
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

**マクロの処理**:
1. フィールド名 "location" を自動取得
2. フィールド型 `Location` を認識
3. KeyPathを合成:
   - `\Place.location` + `\.latitude` = `\Place.location.latitude`
   - `\Place.location` + `\.longitude` = `\Place.location.longitude`

### ネストされた構造

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])

    // ✅ ネスト構造でも相対KeyPathで記述
    @Spatial(type: .geo(
        latitude: \.coordinate.latitude,    // Address.coordinate.latitude
        longitude: \.coordinate.longitude,  // Address.coordinate.longitude
        level: 20
    ))
    var address: Address

    var restaurantID: Int64
    var name: String

    struct Address: Codable, Sendable {
        var street: String
        var coordinate: Coordinate

        struct Coordinate: Codable, Sendable {
            var latitude: Double
            var longitude: Double
        }
    }
}
```

**生成されるKeyPath**:
- `\Restaurant.address.coordinate.latitude`
- `\Restaurant.address.coordinate.longitude`

---

## SpatialTypeの仕様

### 1. `.geo` - 2D地理座標

**用途**: 地球上の位置（緯度・経度）

**引数**:
- `latitude`: 緯度フィールドへの相対KeyPath（Double型）
- `longitude`: 経度フィールドへの相対KeyPath（Double型）
- `level`: S2Cellレベル（1-30、デフォルト: 20）

**例**:
```swift
@Spatial(type: .geo(
    latitude: \.latitude,
    longitude: \.longitude,
    level: 17  // 精度: 約150m
))
var location: Location
```

**S2Cellレベルと精度の目安**:

| Level | 平均セルサイズ | 用途 |
|-------|--------------|------|
| 10 | ~172 km | 国レベル |
| 13 | ~21 km | 都市レベル |
| 15 | ~2.6 km | 地区レベル |
| 17 | ~330 m | 街区レベル |
| 20 | ~41 m | 建物レベル |
| 23 | ~5.1 m | 部屋レベル |
| 30 | ~1 cm | 最高精度 |

### 2. `.geo3D` - 3D地理座標

**用途**: 地球上の位置 + 高度（ドローン、航空機など）

**引数**:
- `latitude`: 緯度フィールドへの相対KeyPath（Double型）
- `longitude`: 経度フィールドへの相対KeyPath（Double型）
- `altitude`: 高度フィールドへの相対KeyPath（Double型、メートル単位）
- `level`: S2Cellレベル（1-30、デフォルト: 20）

**例**:
```swift
@Spatial(type: .geo3D(
    latitude: \.coordinate.latitude,
    longitude: \.coordinate.longitude,
    altitude: \.coordinate.altitude,
    level: 17
))
var location: Location3D

struct Location3D: Codable, Sendable {
    var coordinate: Coordinate

    struct Coordinate: Codable, Sendable {
        var latitude: Double
        var longitude: Double
        var altitude: Double  // メートル単位
    }
}
```

**altitudeRangeパラメータ**（オプション）:
```swift
@Spatial(
    type: .geo3D(
        latitude: \.latitude,
        longitude: \.longitude,
        altitude: \.altitude,
        level: 17
    ),
    altitudeRange: 0...10000  // 海面～10km
)
var location: Location3D
```

### 3. `.cartesian` - 2D直交座標

**用途**: 平面座標系（地図、ゲーム、CADなど）

**引数**:
- `x`: X座標フィールドへの相対KeyPath（Double型）
- `y`: Y座標フィールドへの相対KeyPath（Double型）

**例**:
```swift
@Spatial(type: .cartesian(
    x: \.position.x,
    y: \.position.y
))
var position: Position

struct Position: Codable, Sendable {
    var position: Point

    struct Point: Codable, Sendable {
        var x: Double
        var y: Double
    }
}
```

### 4. `.cartesian3D` - 3D直交座標

**用途**: 3D空間座標系（3Dゲーム、物理シミュレーションなど）

**引数**:
- `x`: X座標フィールドへの相対KeyPath（Double型）
- `y`: Y座標フィールドへの相対KeyPath（Double型）
- `z`: Z座標フィールドへの相対KeyPath（Double型）

**例**:
```swift
@Spatial(type: .cartesian3D(
    x: \.point.x,
    y: \.point.y,
    z: \.point.z
))
var position: Position3D

struct Position3D: Codable, Sendable {
    var point: Point

    struct Point: Codable, Sendable {
        var x: Double
        var y: Double
        var z: Double
    }
}
```

---

## 実装例

### 例1: レストラン検索アプリ

```swift
import FDBRecordCore
import FDBRecordLayer

@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])
    #Index<Restaurant>([\.name])

    @Spatial(type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude,
        level: 20  // 建物レベルの精度
    ))
    var location: Location

    var restaurantID: Int64
    var name: String
    var cuisine: String

    struct Location: Codable, Sendable {
        var latitude: Double
        var longitude: Double
    }
}

// 使用例: 現在地から1km以内のレストランを検索
let currentLocation = (latitude: 35.6812, longitude: 139.7671)  // 東京駅

let nearbyRestaurants = try await store.query()
    .withinRadius(
        center: currentLocation,
        radiusMeters: 1000
    )
    .execute()

for restaurant in nearbyRestaurants {
    print("\(restaurant.name): \(restaurant.cuisine)")
}
```

### 例2: ドローン位置追跡

```swift
@Recordable
struct Drone {
    #PrimaryKey<Drone>([\.droneID])

    @Spatial(
        type: .geo3D(
            latitude: \.position.latitude,
            longitude: \.position.longitude,
            altitude: \.position.altitude,
            level: 17
        ),
        altitudeRange: 0...500  // 地上～500m
    )
    var position: Position

    var droneID: String
    var batteryLevel: Double
    var status: DroneStatus

    struct Position: Codable, Sendable {
        var latitude: Double
        var longitude: Double
        var altitude: Double  // メートル
    }

    enum DroneStatus: String, Codable, Sendable {
        case idle, flying, returning, charging
    }
}

// 使用例: 特定エリアの上空にいるドローンを検索
let searchArea = BoundingBox(
    southwest: (latitude: 35.65, longitude: 139.75),
    northeast: (latitude: 35.70, longitude: 139.80),
    minAltitude: 50,
    maxAltitude: 200
)

let dronesInArea = try await store.query()
    .withinBoundingBox(searchArea)
    .execute()
```

### 例3: ゲーム内オブジェクト

```swift
@Recordable
struct GameObject {
    #PrimaryKey<GameObject>([\.objectID])

    @Spatial(type: .cartesian3D(
        x: \.transform.position.x,
        y: \.transform.position.y,
        z: \.transform.position.z
    ))
    var transform: Transform

    var objectID: String
    var type: ObjectType

    struct Transform: Codable, Sendable {
        var position: Vector3
        var rotation: Quaternion

        struct Vector3: Codable, Sendable {
            var x: Double
            var y: Double
            var z: Double
        }

        struct Quaternion: Codable, Sendable {
            var x: Double
            var y: Double
            var z: Double
            var w: Double
        }
    }

    enum ObjectType: String, Codable, Sendable {
        case player, enemy, item, obstacle
    }
}

// 使用例: プレイヤーの近くの敵を検索
let playerPos = (x: 100.0, y: 50.0, z: 200.0)

let nearbyEnemies = try await store.query()
    .where(\.type, .equals, .enemy)
    .withinRadius3D(center: playerPos, radius: 50.0)
    .execute()
```

---

## 相対KeyPath方式の利点

### 1. フィールド名の重複排除

**v1.0（旧）**:
```swift
@Spatial(type: .geo(
    latitude: \.address.location.latitude,   // "address"が重複
    longitude: \.address.location.longitude
))
var address: Address
```

**v2.0（新）**:
```swift
@Spatial(type: .geo(
    latitude: \.location.latitude,     // "address"不要
    longitude: \.location.longitude,
    level: 17
))
var address: Address
```

### 2. 型安全性の向上

- **コンパイル時チェック**: KeyPathの存在と型をコンパイラが検証
- **リファクタリング対応**: フィールド名変更時にコンパイルエラーで検出
- **IDEサポート**: オートコンプリートが正確に動作

### 3. KeyPath合成による最適化

**マクロ生成コード**:
```swift
extension Restaurant: Recordable {
    public static subscript(spatialField field: String, coordinate: String) -> PartialKeyPath<Self>? {
        switch (field, coordinate) {
        case ("address", "latitude"): return \Self.address.location.latitude
        case ("address", "longitude"): return \Self.address.location.longitude
        default: return nil
        }
    }
}
```

**実行時の効率**:
- ✅ subscript呼び出し: 各座標で1回
- ✅ switch文評価: 各座標で1回
- ✅ PartialKeyPathの柔軟性: 型消去により将来の拡張が容易
- ❌ Mirror API: 完全に廃止（パフォーマンス向上）

### 4. シンプルな記述

相対KeyPathにより、フィールド型を基準とした自然な記述が可能：

```swift
// ネストが深くても、フィールド型からの相対パスで記述
@Spatial(type: .geo(
    latitude: \.address.location.coordinate.latitude,
    longitude: \.address.location.coordinate.longitude,
    level: 17
))
var userInfo: UserInfo
```

---

## 内部実装

### マクロの処理フロー

```
1. @Spatial属性を検出
2. フィールド名を自動取得 → "address"
3. フィールド型を取得 → Address
4. type引数を解析:
   - .geo(latitude: \.location.latitude, longitude: \.location.longitude, level: 17)
5. 相対KeyPathを解析:
   - \.location.latitude (Address基準)
   - \.location.longitude (Address基準)
6. 完全KeyPathに合成:
   - \Self.address.location.latitude
   - \Self.address.location.longitude
7. subscriptコードを生成
```

### 生成されるコード例

```swift
extension Restaurant: Recordable {
    // ... 既存のメタデータプロパティ ...

    /// Spatial座標へのPartialKeyPath取得
    public static subscript(spatialField field: String, coordinate: String) -> PartialKeyPath<Self>? {
        switch (field, coordinate) {
        case ("address", "latitude"): return \Self.address.location.latitude
        case ("address", "longitude"): return \Self.address.location.longitude
        default: return nil
        }
    }
}
```

### SpatialIndexMaintainerでの使用

```swift
private func extractCoordinates(
    from record: Record,
    spatialType: SpatialType
) throws -> [Double] {
    // 1. フィールド名を取得
    let fieldName = (index.rootExpression as? FieldKeyExpression)?.fieldName

    // 2. 座標名を取得
    let coordinateNames = getCoordinateNames(for: spatialType)  // ["latitude", "longitude"]

    // 3. 各座標のPartialKeyPathを取得して値を抽出
    var coordinates: [Double] = []
    for coordinateName in coordinateNames {
        guard let keyPath = Record.self[spatialField: fieldName, coordinate: coordinateName] else {
            throw RecordLayerError.invalidArgument("座標KeyPathが見つかりません")
        }

        let value = record[keyPath: keyPath]  // PartialKeyPath → Any
        guard let doubleValue = value as? Double else {
            throw RecordLayerError.invalidArgument("座標値がDoubleではありません")
        }

        coordinates.append(doubleValue)
    }

    return coordinates
}
```

---

## クエリAPI

### 半径検索（2D）

```swift
let results = try await store.query()
    .withinRadius(
        center: (latitude: 35.6812, longitude: 139.7671),
        radiusMeters: 1000
    )
    .execute()
```

### 矩形範囲検索（Bounding Box）

```swift
let results = try await store.query()
    .withinBoundingBox(
        southwest: (latitude: 35.65, longitude: 139.75),
        northeast: (latitude: 35.70, longitude: 139.80)
    )
    .execute()
```

### 3D範囲検索

```swift
let results = try await store.query()
    .withinBoundingBox3D(
        min: (x: 0, y: 0, z: 0),
        max: (x: 100, y: 100, z: 100)
    )
    .execute()
```

### フィルタとの組み合わせ

```swift
let results = try await store.query()
    .withinRadius(center: location, radiusMeters: 500)
    .where(\.cuisine, .equals, "Italian")
    .where(\.rating, .greaterThanOrEqual, 4.0)
    .execute()
```

---

## ベストプラクティス

### 1. 適切なS2Cellレベルの選択

```swift
// ❌ 悪い例: レベルが高すぎる（精度過剰）
@Spatial(type: .geo(
    latitude: \.location.latitude,
    longitude: \.location.longitude,
    level: 30  // ~1cm精度（レストラン検索には不要）
))
var location: Location

// ✅ 良い例: 用途に応じた適切なレベル
@Spatial(type: .geo(
    latitude: \.location.latitude,
    longitude: \.location.longitude,
    level: 17  // ~330m精度（レストラン検索に最適）
))
var location: Location
```

### 2. 座標型の分離

```swift
// ✅ 推奨: 座標を専用の構造体に分離
struct Restaurant {
    @Spatial(type: .geo(
        latitude: \.latitude,
        longitude: \.longitude,
        level: 17
    ))
    var location: Location

    var name: String
}

struct Location: Codable, Sendable {
    var latitude: Double
    var longitude: Double
}
```

### 3. altitudeRangeの指定（3D座標）

```swift
// ✅ 推奨: 実際の使用範囲を指定
@Spatial(
    type: .geo3D(
        latitude: \.latitude,
        longitude: \.longitude,
        altitude: \.altitude,
        level: 17
    ),
    altitudeRange: 0...500  // ドローンの飛行範囲
)
var position: Position
```

### 4. インデックス名の明示（複数Spatialフィールドの場合）

```swift
struct Store {
    @Spatial(
        type: .geo(
            latitude: \.headquarters.latitude,
            longitude: \.headquarters.longitude,
            level: 17
        ),
        name: "headquarters_location"
    )
    var headquarters: Location

    @Spatial(
        type: .geo(
            latitude: \.warehouse.latitude,
            longitude: \.warehouse.longitude,
            level: 17
        ),
        name: "warehouse_location"
    )
    var warehouse: Location
}
```

---

## マイグレーションガイド

### v1.0 → v2.0への移行

#### 変更1: KeyPathを相対パスに変更

**v1.0（旧）**:
```swift
@Spatial(type: .geo(
    latitude: \.address.location.latitude,
    longitude: \.address.location.longitude
))
var address: Address
```

**v2.0（新）**:
```swift
@Spatial(type: .geo(
    latitude: \.location.latitude,
    longitude: \.location.longitude,
    level: 17
))
var address: Address
```

#### 変更2: levelをtype引数内に移動

**v1.0（旧）**:
```swift
@Spatial(
    type: .geo(
        latitude: \.latitude,
        longitude: \.longitude
    ),
    level: 17
)
var location: Location
```

**v2.0（新）**:
```swift
@Spatial(type: .geo(
    latitude: \.latitude,
    longitude: \.longitude,
    level: 17
))
var location: Location
```

#### 変更3: SpatialRepresentableの削除

**v1.0では不要だった場合**: 変更なし

**v1.0で使用していた場合**: 削除
```swift
// ❌ v1.0: SpatialRepresentable準拠（削除）
extension Location: SpatialRepresentable {
    func toNormalizedCoordinates() -> [Double] {
        return [latitude, longitude]
    }
}

// ✅ v2.0: 不要（マクロがKeyPath合成で処理）
// → 削除してOK
```

### 移行チェックリスト

- [ ] KeyPathをフィールド型基準の相対パスに変更
- [ ] levelパラメータをtype引数内に移動
- [ ] SpatialRepresentable準拠を削除
- [ ] 既存のインデックスを再構築（オンラインインデックス構築を推奨）
- [ ] テストケースを更新

---

## まとめ

**v2.0の主な改善**:
- ✅ **相対KeyPath方式**: フィールド名の重複を排除
- ✅ **Mirror API完全廃止**: 型安全性とパフォーマンスの向上
- ✅ **PartialKeyPath使用**: 柔軟性と将来の拡張性
- ✅ **KeyPath合成**: マクロがコンパイル時に完全なパスを生成
- ✅ **シンプルな記述**: より自然で読みやすいコード

**次のステップ**:
1. [Spatial Index Design](./spatial-index-design-final.md) で詳細な設計を確認
2. [Implementation Guide](./spatial-index-complete-implementation.md) で実装詳細を学習
3. サンプルコードで実際に試す
