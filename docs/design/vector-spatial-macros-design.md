# ⚠️ DEPRECATED - @Vector と @Spatial マクロ設計書

> **このドキュメントは廃止されました** (Deprecated as of 2025-01-16)
>
> **理由**: `@Vector`と`@Spatial`マクロ + プロトコルベースの設計は、よりシンプルなcomputed property方式に置き換えられました。
>
> **最新の実装**: [CLAUDE.md - Part 5: 空間インデックス](../../CLAUDE.md#part-5-空間インデックスspatial-indexing)を参照してください。
>
> **新しいアプローチの利点**:
> - ✅ プロトコル不要（`VectorRepresentable`/`SpatialRepresentable`は不要）
> - ✅ マクロ不要（`@Vector`/`@Spatial`は不要）
> - ✅ シンプルなcomputed property
> - ✅ 柔軟（任意のフィールドから計算可能）
> - ✅ 型安全（Swift標準機能を使用）

## 新しい実装例（Spatial Indexing）

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])
    #Index<Restaurant>([\.geohash], name: "restaurant_by_location")

    var restaurantID: Int64
    var latitude: Double
    var longitude: Double

    // ✅ Computed property（プロトコル不要）
    var geohash: String {
        Geohash.encode(latitude: latitude, longitude: longitude, precision: 7)
    }
}

// 使用例
let restaurants = try await store.query()
    .where(\.geohash, .hasPrefix, Geohash.encode(latitude: centerLat, longitude: centerLon, precision: 6))
    .execute()
```

詳細は[CLAUDE.md](../../CLAUDE.md)を参照してください。

---

# 以下は古い設計書（参考用）

このドキュメントは、Swift Record LayerにおけるVector検索とSpatial検索のための添付プロパティマクロ（attached property macros）の設計を定義します。

**設計決定**: `#VectorIndex<T>`や`#SpatialIndex<T>`のようなフリースタンディングマクロではなく、`@Vector`と`@Spatial`の添付プロパティマクロを使用します。これは以下の理由によります：

- **フィールドレベルのアノテーション**: `@Attribute`, `@Transient`, `@Default`と同じパターン
- **型安全性**: プロパティ型（Vector, GeoCoordinate）に直接アノテーション
- **簡潔な構文**: `@Vector(dimensions: 768) var embedding: Vector`
- **デフォルト値の活用**: 99%のユースケースで適切なデフォルト設定

## マクロ定義

### @Vector マクロ

**目的**: ML埋め込みベクトルのHNSWベース近傍検索インデックスを定義

```swift
/// Marks a Vector property for HNSW-based similarity search indexing
///
/// This macro generates index metadata for vector similarity search using
/// Hierarchical Navigable Small World (HNSW) algorithm.
///
/// **Basic Usage**:
/// ```swift
/// @Recordable
/// struct Product {
///     #PrimaryKey<Product>([\.productID])
///
///     @Vector(dimensions: 768)
///     var embedding: Vector
///
///     var productID: Int64
///     var name: String
/// }
/// ```
///
/// **Advanced Usage with Custom Parameters**:
/// ```swift
/// @Vector(
///     dimensions: 1536,
///     metric: .l2,
///     m: 32,
///     efConstruction: 200,
///     efSearch: 100
/// )
/// var embedding: Vector
/// ```
///
/// **Parameters**:
/// - `dimensions`: Required. Vector dimensions (e.g., 768 for BERT, 1536 for GPT-3)
/// - `metric`: Distance metric (default: `.cosine` - 99% of ML use cases)
/// - `m`: HNSW M parameter (default: 16) - connections per layer
/// - `efConstruction`: Build-time search depth (default: 100)
/// - `efSearch`: Query-time search depth (default: 50)
///
/// **Performance Characteristics**:
/// - Build time: O(N log N * M * efConstruction)
/// - Query time: O(log N * efSearch)
/// - Memory: O(N * M * dimensions * 4 bytes)
///
/// **Important**:
/// - Property type MUST conform to `VectorRepresentable` protocol
/// - Dimensions must match vector data at runtime
/// - Metric cannot be changed after index creation (affects HNSW graph structure)
@attached(peer)
public macro Vector(
    dimensions: Int,
    metric: VectorMetric = .cosine,
    m: Int = 16,
    efConstruction: Int = 100,
    efSearch: Int = 50
) = #externalMacro(module: "FDBRecordLayerMacros", type: "VectorMacro")
```

### @Spatial マクロ

**目的**: 地理座標の空間インデックス（Z-orderカーブ）を定義

```swift
/// Marks a GeoCoordinate property for spatial indexing using Z-order curve
///
/// This macro generates index metadata for efficient spatial queries such as
/// bounding box searches and radius queries.
///
/// **Basic Usage (2D Geographic)**:
/// ```swift
/// @Recordable
/// struct Restaurant {
///     #PrimaryKey<Restaurant>([\.restaurantID])
///
///     @Spatial  // Defaults to geographic coordinates
///     var location: GeoCoordinate
///
///     var restaurantID: Int64
///     var name: String
/// }
/// ```
///
/// **3D Usage (with Altitude)**:
/// ```swift
/// @Recordable
/// struct Drone {
///     #PrimaryKey<Drone>([\.droneID])
///
///     @Spatial(includeAltitude: true, altitudeRange: 0.0...5000.0)
///     var position: GeoCoordinate
///
///     var droneID: Int64
/// }
/// ```
///
/// **Parameters**:
/// - `type`: Spatial type (default: `.geo` - geographic coordinates)
/// - `includeAltitude`: Include altitude in 3D indexing (default: `false`)
/// - `altitudeRange`: Range for altitude normalization (required if includeAltitude = true)
///
/// **Index Structure**:
/// - 2D: 32 bits per dimension (latitude, longitude) → ~1cm accuracy
/// - 3D: 21 bits per dimension (lat, lon, alt) → ~50cm accuracy
///
/// **Query Support**:
/// - Bounding box: `within(minLat, minLon, maxLat, maxLon)`
/// - Circle: `withinRadius(centerLat, centerLon, radiusMeters)`
/// - Nearest: `nearest(lat, lon, k: 10)`
///
/// **Important**:
/// - Property type MUST conform to `SpatialRepresentable` protocol
/// - For geographic coordinates: use `GeoCoordinate` (standard implementation)
/// - For custom coordinates: implement `SpatialRepresentable` protocol
@attached(peer)
public macro Spatial(
    type: SpatialType = .geo,
    includeAltitude: Bool = false,
    altitudeRange: ClosedRange<Double>? = nil
) = #externalMacro(module: "FDBRecordLayerMacros", type: "SpatialMacro")
```

## 型定義

### ⚠️ VectorRepresentableプロトコル（削除済み）

> **このプロトコルは実装から削除されました** (Removed as of 2025-01-18)
>
> **理由**: 実装が複雑になり、混乱を招いたため削除されました。
>
> **現在の実装**: ベクトルフィールドは直接配列型（[Float], [Float32], [Double]）を使用します。
>
> 詳細は[CLAUDE.md](../../CLAUDE.md)を参照してください。

以下は削除前の設計（参考用）：

```swift
/// Protocol for types that can be indexed as vectors
///
/// Any type conforming to this protocol can be used with the @Vector macro.
/// This allows users to define custom vector types (sparse vectors, quantized vectors, etc.)
/// while still benefiting from HNSW-based similarity search.
public protocol VectorRepresentable: Sendable {
    /// Number of dimensions in the vector
    var dimensions: Int { get }

    /// Convert to array of Float elements for indexing and distance calculations
    /// - Returns: Dense float array representation
    func toFloatArray() -> [Float]

    /// Dot product with another vector
    /// Default implementation provided in protocol extension
    func dot(_ other: Self) -> Float

    /// L2 (Euclidean) distance to another vector
    /// Default implementation provided in protocol extension
    func l2Distance(to other: Self) -> Float

    /// Cosine similarity to another vector
    /// Default implementation provided in protocol extension
    func cosineSimilarity(to other: Self) -> Float
}

extension VectorRepresentable {
    // Default implementations using toFloatArray()
    public func dot(_ other: Self) -> Float {
        let a = self.toFloatArray()
        let b = other.toFloatArray()
        precondition(a.count == b.count, "Vector dimensions must match")
        return zip(a, b).map(*).reduce(0, +)
    }

    public func l2Distance(to other: Self) -> Float {
        let a = self.toFloatArray()
        let b = other.toFloatArray()
        precondition(a.count == b.count, "Vector dimensions must match")
        let diff = zip(a, b).map { $0 - $1 }
        return sqrt(diff.map { $0 * $0 }.reduce(0, +))
    }

    public func cosineSimilarity(to other: Self) -> Float {
        let dotProduct = self.dot(other)
        let magnitudeA = sqrt(self.dot(self))
        let magnitudeB = sqrt(other.dot(other))
        return dotProduct / (magnitudeA * magnitudeB)
    }
}

// ⚠️ パフォーマンス上の注意
//
// デフォルト実装は toFloatArray() を **複数回** 呼び出します:
// - dot(): 2回（self + other）
// - l2Distance(): 2回（self + other）
// - cosineSimilarity(): 5回（dot: 2回, magnitudeA: 1回, magnitudeB: 1回, dotProduct再利用: 0回）
//
// **問題**:
// SparseVector や QuantizedVector のように toFloatArray() の変換コストが高い型では、
// 1回の距離計算で O(dimensions) の変換が複数回実行されます。
//
// **推奨される対策**:
//
// 1. ✅ **カスタム実装を提供**（最も効率的）:
// ```swift
// public struct SparseVector: VectorRepresentable {
//     // ... フィールド定義 ...
//
//     // ✅ Sparse専用の最適化実装
//     public func dot(_ other: Self) -> Float {
//         // 非ゼロ要素のみ計算（O(nnz)、dense変換不要）
//         var result: Float = 0
//         var i = 0, j = 0
//         while i < self.indices.count && j < other.indices.count {
//             if self.indices[i] == other.indices[j] {
//                 result += self.values[i] * other.values[j]
//                 i += 1; j += 1
//             } else if self.indices[i] < other.indices[j] {
//                 i += 1
//             } else {
//                 j += 1
//             }
//         }
//         return result
//     }
//
//     // 他のメソッドも同様に最適化
// }
// ```
//
// 2. ⚠️ **キャッシュ戦略**（メモリとのトレードオフ）:
// ```swift
// public struct QuantizedVector: VectorRepresentable {
//     private let quantized: [UInt8]
//     private let scale: Float
//     private let offset: Float
//
//     // Lazy caching（初回のみ変換）
//     private var cachedFloatArray: [Float]?
//
//     public mutating func toFloatArray() -> [Float] {
//         if let cached = cachedFloatArray {
//             return cached
//         }
//         let array = quantized.map { Float($0) * scale + offset }
//         cachedFloatArray = array  // ⚠️ メモリ増加
//         return array
//     }
// }
// ```
//
// 3. ❌ **避けるべきパターン**:
// ```swift
// // ❌ Bad: デフォルト実装をそのまま使用（重い変換を複数回実行）
// public struct HeavyVector: VectorRepresentable {
//     public func toFloatArray() -> [Float] {
//         // 重い変換処理（例: ネットワーク取得、圧縮解凍、など）
//         return expensiveConversion()
//     }
//     // ❌ カスタム実装なし → デフォルトが複数回 toFloatArray() を呼ぶ
// }
// ```
//
// **ベンチマーク例（768次元）**:
// | 型 | toFloatArray()コスト | dot() (デフォルト) | dot() (カスタム) | 改善率 |
// |----|---------------------|------------------|-----------------|-------|
// | Vector | O(1) (参照返し) | 0.01ms | - | - |
// | SparseVector (1% nnz) | O(n) (~0.1ms) | 0.21ms (2回変換) | 0.001ms | **210x** |
// | QuantizedVector | O(n) (~0.15ms) | 0.31ms (2回変換) | 0.02ms | **15x** |
```

### Vector型（標準実装）

```swift
/// Standard dense vector implementation for ML embeddings
///
/// This is the recommended type for most use cases (text embeddings, image embeddings, etc.)
public struct Vector: VectorRepresentable, Equatable {
    public let elements: [Float]
    public var dimensions: Int { elements.count }

    /// Initialize with Float array
    ///
    /// - Parameter elements: Vector elements
    /// - Note: For type safety, use `init(elements:expectedDimensions:)` when dimensions are known at compile time
    public init(_ elements: [Float]) {
        self.elements = elements
    }

    /// Initialize with Float array and validate dimensions
    ///
    /// - Parameters:
    ///   - elements: Vector elements
    ///   - expectedDimensions: Expected number of dimensions (from @Vector macro)
    /// - Throws: `RecordLayerError.invalidArgument` if dimensions don't match
    ///
    /// **Recommended usage** when dimensions are known:
    /// ```swift
    /// // ✅ Good: Runtime validation
    /// let embedding = try Vector(elements: data, expectedDimensions: 768)
    ///
    /// // ⚠️ Risky: No validation
    /// let embedding = Vector(data)
    /// ```
    public init(elements: [Float], expectedDimensions: Int) throws {
        guard elements.count == expectedDimensions else {
            throw RecordLayerError.invalidArgument(
                "Vector dimension mismatch: expected \(expectedDimensions), got \(elements.count)"
            )
        }
        self.elements = elements
    }

    public func toFloatArray() -> [Float] {
        return elements
    }

    public func normalized() -> Vector {
        let magnitude = sqrt(elements.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return self }
        return Vector(elements.map { $0 / magnitude })
    }
}
```

[以降、残りの内容は省略 - 参考用に残していますが、新しい実装はCLAUDE.mdを参照してください]
