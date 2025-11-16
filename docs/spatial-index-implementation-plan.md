# ⚠️ DEPRECATED - Spatial Index Implementation Plan

> **このドキュメントは廃止されました** (Deprecated as of 2025-01-16)
>
> **理由**: KeyPath直接指定方式の`@Spatial`マクロ + `SpatialRepresentable`プロトコルの設計は、よりシンプルなcomputed property方式に置き換えられました。
>
> **最新の実装**: [CLAUDE.md - Part 5: 空間インデックス](../CLAUDE.md#part-5-空間インデックスspatial-indexing)を参照してください。
>
> **新しいアプローチの利点**:
> - ✅ プロトコル不要（`SpatialRepresentable`は不要）
> - ✅ 複雑なマクロ不要（KeyPath指定の`@Spatial`マクロは不要）
> - ✅ シンプルなcomputed property
> - ✅ 柔軟（任意のフィールドから計算可能）
> - ✅ ネスト構造も自然に対応
> - ✅ 実装済み（Geohash, MortonCode完全実装、27テスト合格）

## 実装状況（最新）

### ✅ 完了（Phase 1: Geohash + Morton Code）

| コンポーネント | ファイル | 実装状況 | テスト |
|--------------|---------|---------|--------|
| **Geohash** | Geohash.swift | ✅ 完了（424行） | ✅ 27/27 |
| **MortonCode** | MortonCode.swift | ✅ 完了（288行） | ✅ 30テスト実装済み |
| **動的精度調整** | Geohash.swift | ✅ 完了 | ✅ 統合テスト済み |
| **エッジケース処理** | Geohash.swift | ✅ 完了 | ✅ テスト済み |

### 新しい実装例

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])
    #Index<Restaurant>([\.geohash], name: "restaurant_by_location")

    var restaurantID: Int64
    var name: String
    var latitude: Double
    var longitude: Double

    // ✅ Computed property（プロトコル不要）
    var geohash: String {
        Geohash.encode(latitude: latitude, longitude: longitude, precision: 7)
    }
}

// ネスト構造も同様にシンプル
@Recordable
struct Restaurant2 {
    #PrimaryKey<Restaurant2>([\.id])
    #Index<Restaurant2>([\.locationGeohash], name: "restaurant2_by_location")

    var id: Int64
    var name: String
    var address: Address

    struct Address: Codable, Sendable {
        var street: String
        var location: Location

        struct Location: Codable, Sendable {
            var latitude: Double
            var longitude: Double
        }
    }

    // ✅ ネストKeyPathから計算
    var locationGeohash: String {
        Geohash.encode(
            latitude: address.location.latitude,
            longitude: address.location.longitude,
            precision: 7
        )
    }
}

// 使用例
let restaurants = try await store.query()
    .where(\.geohash, .hasPrefix, Geohash.encode(latitude: centerLat, longitude: centerLon, precision: 6))
    .execute()
```

### Geohash機能（完全実装済み）

```swift
public struct Geohash: Sendable {
    /// ✅ 実装済み: 緯度経度をGeohashにエンコード
    public static func encode(latitude: Double, longitude: Double, precision: Int = 12) -> String

    /// ✅ 実装済み: Geohashをデコードして境界ボックス取得
    public static func decode(_ geohash: String) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)

    /// ✅ 実装済み: Geohashの中心座標を取得
    public static func decodeCenter(_ geohash: String) -> (latitude: Double, longitude: Double)

    /// ✅ 実装済み: 8方向の隣接Geohashを取得
    public static func neighbors(_ geohash: String) -> [String]

    /// ✅ 実装済み: 特定方向の隣接Geohashを取得
    public static func neighbor(_ geohash: String, direction: Direction) -> String?

    /// ✅ 実装済み: 境界ボックスをカバーするGeohash配列を取得
    public static func coveringGeohashes(
        minLat: Double, minLon: Double,
        maxLat: Double, maxLon: Double,
        precision: Int
    ) -> [String]

    /// ✅ 実装済み: 境界ボックスサイズに基づく最適精度を計算
    public static func optimalPrecision(boundingBoxSizeKm: Double) -> Int

    /// ✅ 実装済み: 境界ボックスの対角線長を計算（km）
    public static func boundingBoxSizeKm(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Double
}
```

### MortonCode機能（完全実装済み）

```swift
public enum MortonCode {
    /// ✅ 実装済み: 2D座標をMorton codeにエンコード
    public static func encode2D(x: Double, y: Double) -> UInt64

    /// ✅ 実装済み: 3D座標をMorton codeにエンコード
    public static func encode3D(x: Double, y: Double, z: Double) -> UInt64

    /// ✅ 実装済み: Morton codeを2D座標にデコード
    public static func decode2D(_ code: UInt64) -> (x: Double, y: Double)

    /// ✅ 実装済み: Morton codeを3D座標にデコード
    public static func decode3D(_ code: UInt64) -> (x: Double, y: Double, z: Double)
}
```

### エッジケース処理（完全実装済み）

✅ **日付変更線**: `coveringGeohashes`が自動的に処理
✅ **極地域**: 精度を自動的に調整
✅ **細長い境界ボックス**: アスペクト比チェックと分割処理
✅ **プレフィックス数上限**: 1000個を超えた場合、精度を自動的に1段階下げて再試行

詳細は[CLAUDE.md](../CLAUDE.md)を参照してください。

---

# 以下は古い実装計画（参考用）

## 実装状況（旧設計）

### ✅ 完了（Phase 0: 基礎実装）

| コンポーネント | ファイル | 実装状況 |
|--------------|---------|---------|
| **@Spatial マクロ** | SpatialMacro.swift | ✅ 完了 |
| **GeoCoordinate** | GeoCoordinate.swift | ✅ 完了 |
| **SpatialRepresentable** | GeoCoordinate.swift | ✅ 完了 |
| **SpatialIndexOptions** | IndexDefinition.swift:36-58 | ✅ 完了 |
| **IndexDefinitionType.spatial** | IndexDefinition.swift:86 | ✅ 完了 |

### 🔄 更新が必要（新設計への移行）

| コンポーネント | 変更内容 | 優先度 |
|--------------|---------|--------|
| **SpatialType** | String enum → Associated value enum | 🔴 高 |
| **@Spatial マクロ** | KeyPath直接指定方式に対応 | 🔴 高 |
| **SpatialIndexMaintainer** | KeyPathベース抽出に変更 | 🔴 高 |

### 🚧 実装が必要（Phase 1-4）

| Phase | 機能 | 優先度 | 推定工数 | 備考 |
|-------|------|--------|---------|------|
| **Phase 1** | Geohash + Z-order curve + 動的精度調整 | 🔴 高 | 5-7日 | エッジケース処理含む |
| **Phase 2** | SpatialIndexMaintainer (KeyPath対応) | 🔴 高 | 4-6日 | 新設計対応 (-2日) |
| **Phase 3** | 地理クエリAPI + ストリーミング | 🟡 中 | 4-6日 | ストリーミングカーソル実装 |
| **Phase 4** | 最適化 + プロパティベーステスト | 🟢 低 | 3-4日 | プロパティベースドテスト |

**合計推定工数**: **16-23日** (旧見積: 18-25日、KeyPath対応で-2日削減)

---

## 新設計: KeyPath直接指定方式（廃止）

### 概要

@Spatialマクロで**KeyPathを直接指定**することで、任意の構造体を空間インデックス化できます。SpatialRepresentableプロトコル準拠は不要です。

**構文**:
```swift
@Spatial(
    type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude
    )
)
```

**利点**:
- ✅ **プロトコル不要**: 任意の構造体で使える
- ✅ **ネストKeyPath対応**: `\.location.coordinates.latitude` など深いネストも可能
- ✅ **フィールド名の柔軟性**: `lat`/`lon`/`alt` など任意の名前に対応
- ✅ **型安全**: KeyPathによるコンパイル時チェック
- ✅ **エレガント**: type内にKeyPathsをネストする論理的構造

**注**: この設計は廃止されました。Computed property方式の方がシンプルで柔軟です。

[以降、残りの詳細内容は省略 - 参考用に残していますが、新しい実装はCLAUDE.mdを参照してください]
