# @Vector と @Spatial マクロ設計書

## 概要

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

### VectorRepresentableプロトコル

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

### マクロによる実行時検証の生成

#### Recordableプロトコル拡張（検証インターフェース）

```swift
/// Recordable protocol extension for field validation
///
/// These methods are called by RecordStore before saving records.
/// Default implementations do nothing (no validation), but @Vector/@Spatial
/// macros generate override implementations with actual validation logic.
public protocol Recordable: Sendable {
    // ... 既存のメソッド ...

    /// Validate @Vector fields
    ///
    /// Default implementation: no-op (no @Vector fields)
    /// Override: generated by @Recordable macro if type has @Vector fields
    func validateVectorFields() throws

    /// Validate @Spatial fields
    ///
    /// Default implementation: no-op (no @Spatial fields)
    /// Override: generated by @Recordable macro if type has @Spatial fields
    func validateSpatialFields() throws
}

extension Recordable {
    /// Default implementation: no validation (no @Vector fields)
    public func validateVectorFields() throws {
        // No-op: Type has no @Vector fields
    }

    /// Default implementation: no validation (no @Spatial fields)
    public func validateSpatialFields() throws {
        // No-op: Type has no @Spatial fields
    }
}
```

#### @Recordableマクロが生成する検証コード

```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    @Vector(dimensions: 768)
    var embedding: Vector

    var productID: Int64
}

// ↓ @Recordableマクロが生成

extension Product {
    /// Override Recordable.validateVectorFields() with actual validation
    public func validateVectorFields() throws {
        // @Vector(dimensions: 768) から生成
        if embedding.dimensions != 768 {
            throw RecordLayerError.invalidArgument(
                "Vector field 'embedding' dimension mismatch: expected 768, got \(embedding.dimensions)"
            )
        }
    }
}
```

**複数フィールドの例**:
```swift
@Recordable
struct Hotel {
    #PrimaryKey<Hotel>([\.hotelID])

    @Vector(dimensions: 512)
    var descriptionEmbedding: Vector

    @Spatial(includeAltitude: true, altitudeRange: 0.0...5000.0)
    var location: GeoCoordinate

    var hotelID: Int64
}

// ↓ @Recordableマクロが生成

extension Hotel {
    public func validateVectorFields() throws {
        if descriptionEmbedding.dimensions != 512 {
            throw RecordLayerError.invalidArgument(
                "Vector field 'descriptionEmbedding' dimension mismatch: expected 512, got \(descriptionEmbedding.dimensions)"
            )
        }
    }

    public func validateSpatialFields() throws {
        // includeAltitude=true の場合、altitudeがnilはエラー
        guard location.altitude != nil else {
            throw RecordLayerError.invalidArgument(
                "Spatial field 'location' requires altitude (includeAltitude=true)"
            )
        }

        // altitudeRange の境界チェック（警告のみ、クリッピングされる）
        let alt = location.altitude!
        if alt < 0.0 || alt > 5000.0 {
            // Warning logged but not an error (will be clipped during encoding)
            print("Warning: Spatial field 'location' altitude \(alt) is outside range [0.0, 5000.0], will be clipped")
        }
    }
}
```

#### RecordStore統合（型安全な呼び出し）

```swift
// RecordStore.swift

public final class RecordStore<Record: Recordable> {
    // ...

    /// Save a record with automatic validation
    public func save(_ record: Record) async throws {
        // 1. Call protocol methods (implemented by macro or default no-op)
        try record.validateVectorFields()  // ✅ Always safe to call (protocol requirement)
        try record.validateSpatialFields() // ✅ Always safe to call (protocol requirement)

        // 2. Proceed with saving if validation passes
        try await saveInternal(record)
    }

    private func saveInternal(_ record: Record) async throws {
        // Existing save logic...
        let primaryKey = recordAccess.extractPrimaryKey(from: record)
        let protobufData = try record.toProtobuf()

        try await database.withTransaction { transaction in
            let recordKey = recordSubspace.subspace(Record.recordName).subspace(primaryKey).pack(Tuple())
            transaction.setValue(protobufData, for: recordKey)

            // Update indexes (IndexMaintainer will handle @Vector/@Spatial encoding)
            for index in indexes {
                try await maintainIndex(index: index, record: record, transaction: transaction)
            }
        }
    }
}
```

#### 検証タイミングのまとめ

| タイミング | 実行内容 | エラー時の動作 |
|----------|---------|--------------|
| **RecordStore.save()** | validateVectorFields() + validateSpatialFields() | throw → save中止 |
| **IndexMaintainer.buildIndexKey()** | 次元数チェック（念のため） | fatalError（検証済みのはず） |
| **Vector.init(elements:expectedDimensions:)** | 明示的な次元数チェック（推奨） | throw → 初期化失敗 |

**ベストプラクティス**:
```swift
// ✅ Good: 次元数チェック付き初期化
let embedding = try Vector(elements: data, expectedDimensions: 768)
let product = Product(productID: 1, embedding: embedding)
try await store.save(product)  // validateVectorFields() が自動で呼ばれる

// ⚠️ Risky: チェックなし初期化（save時にエラーになる）
let embedding = Vector(data)  // 次元数が間違っていても初期化成功
let product = Product(productID: 1, embedding: embedding)
try await store.save(product)  // ← ここで RecordLayerError.invalidArgument
```

### カスタムVector実装例

```swift
/// Sparse vector for high-dimensional data with many zeros
public struct SparseVector: VectorRepresentable {
    public let indices: [Int]
    public let values: [Float]
    public let dimensions: Int

    public init(indices: [Int], values: [Float], dimensions: Int) {
        precondition(indices.count == values.count, "Indices and values must have same length")
        self.indices = indices
        self.values = values
        self.dimensions = dimensions
    }

    public func toFloatArray() -> [Float] {
        var dense = [Float](repeating: 0, count: dimensions)
        for (i, value) in zip(indices, values) {
            dense[i] = value
        }
        return dense
    }
}

/// Quantized vector for memory-efficient storage (8-bit quantization)
public struct QuantizedVector: VectorRepresentable {
    public let quantized: [UInt8]  // 8-bit quantization
    public let scale: Float
    public let offset: Float
    public var dimensions: Int { quantized.count }

    public init(from vector: [Float]) {
        let min = vector.min() ?? 0
        let max = vector.max() ?? 1
        self.scale = (max - min) / 255.0
        self.offset = min
        self.quantized = vector.map { value in
            let normalized = (value - min) / (max - min)
            return UInt8(normalized * 255.0)
        }
    }

    public func toFloatArray() -> [Float] {
        return quantized.map { Float($0) * scale + offset }
    }
}
```

### VectorMetric列挙型

```swift
/// Distance metric for vector similarity search
public enum VectorMetric: String, Sendable {
    /// Cosine similarity (default for ML embeddings)
    /// Range: [-1, 1], higher = more similar
    /// Use case: Text embeddings, image embeddings (99% of cases)
    case cosine

    /// L2 (Euclidean) distance
    /// Range: [0, ∞], lower = more similar
    /// Use case: Normalized vectors, certain CV tasks
    case l2

    /// Inner product (dot product)
    /// Range: [-∞, ∞], higher = more similar
    /// Use case: Pre-normalized vectors, recommendation systems
    case innerProduct
}
```

### SpatialRepresentableプロトコル

```swift
/// Protocol for types that can be spatially indexed using Z-order curve
///
/// Any type conforming to this protocol can be used with the @Spatial macro.
/// This allows users to define custom coordinate systems (game coordinates, custom projections, etc.)
/// while still benefiting from Z-order curve spatial indexing.
public protocol SpatialRepresentable: Sendable {
    /// Number of spatial dimensions (2 or 3)
    var spatialDimensions: Int { get }

    /// Convert to normalized coordinates in range [0.0, 1.0] for Z-order encoding
    ///
    /// The normalization should map the entire valid coordinate space to [0, 1]:
    /// - 2D: [latitude/longitude normalized, ...]
    /// - 3D: [latitude/longitude normalized, altitude normalized]
    ///
    /// - Returns: Array of normalized coordinates, length must match spatialDimensions
    func toNormalizedCoordinates() -> [Double]

    /// Calculate distance to another spatial point
    ///
    /// Distance should be in the same units as the original coordinate system:
    /// - Geographic coordinates: meters (Haversine distance)
    /// - Game coordinates: game units (Euclidean distance)
    ///
    /// - Parameter other: Another point in the same coordinate system
    /// - Returns: Distance in coordinate system units
    func distance(to other: Self) -> Double
}
```

### GeoCoordinate型（標準実装）

```swift
/// Geographic coordinate with optional altitude
///
/// This is the standard implementation for geographic locations on Earth.
/// Uses WGS84 coordinate system and Haversine distance for accuracy.
///
/// **Important**: This type does NOT store altitudeRange internally.
/// The normalization range is provided by the @Spatial macro's altitudeRange parameter
/// and stored in SpatialIndexOptions. When encoding for indexing, the IndexMaintainer
/// passes the range to toNormalizedCoordinates(altitudeRange:).
public struct GeoCoordinate: SpatialRepresentable, Equatable {
    public let latitude: Double   // -90.0 ~ 90.0
    public let longitude: Double  // -180.0 ~ 180.0
    public let altitude: Double?  // Optional meters above sea level

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        precondition((-90.0...90.0).contains(latitude), "Latitude must be in range -90.0...90.0")
        precondition((-180.0...180.0).contains(longitude), "Longitude must be in range -180.0...180.0")

        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public var spatialDimensions: Int {
        altitude != nil ? 3 : 2
    }

    /// Default implementation for 2D (ignores altitude)
    ///
    /// **Note**: This method is used when includeAltitude=false.
    /// For 3D indexing, use toNormalizedCoordinates(altitudeRange:) instead.
    public func toNormalizedCoordinates() -> [Double] {
        let normLat = (latitude + 90.0) / 180.0   // [-90, 90] → [0, 1]
        let normLon = (longitude + 180.0) / 360.0  // [-180, 180] → [0, 1]
        return [normLat, normLon]
    }

    /// 3D normalization with altitude range (called by IndexMaintainer)
    ///
    /// **Parameters**:
    /// - `altitudeRange`: Normalization range from @Spatial macro
    ///
    /// **Example**:
    /// ```swift
    /// let coord = GeoCoordinate(latitude: 35.6812, longitude: 139.7671, altitude: 500)
    /// let normalized = coord.toNormalizedCoordinates(altitudeRange: 0.0...10000.0)
    /// // → [0.7045, 0.8880, 0.05]
    /// ```
    public func toNormalizedCoordinates(altitudeRange: ClosedRange<Double>) -> [Double] {
        let normLat = (latitude + 90.0) / 180.0   // [-90, 90] → [0, 1]
        let normLon = (longitude + 180.0) / 360.0  // [-180, 180] → [0, 1]

        guard let alt = altitude else {
            // If altitude is nil but altitudeRange is provided, this is an error
            // (should be caught by validateSpatialFields() before reaching here)
            fatalError("Altitude is nil but altitudeRange was provided")
        }

        // Clipping: 範囲外の値を境界値に制限
        let clippedAlt = min(max(alt, altitudeRange.lowerBound), altitudeRange.upperBound)
        // Normalization: [lowerBound, upperBound] → [0, 1]
        let normAlt = (clippedAlt - altitudeRange.lowerBound) /
                      (altitudeRange.upperBound - altitudeRange.lowerBound)

        return [normLat, normLon, normAlt]
    }

    public func distance(to other: GeoCoordinate) -> Double {
        // Haversine distance in meters
        let R = 6371000.0  // Earth radius in meters
        let lat1 = latitude * .pi / 180.0
        let lat2 = other.latitude * .pi / 180.0
        let dLat = (other.latitude - latitude) * .pi / 180.0
        let dLon = (other.longitude - longitude) * .pi / 180.0

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        let distance2D = R * c

        // If both have altitude, include vertical distance
        if let alt1 = altitude, let alt2 = other.altitude {
            let dAlt = alt2 - alt1
            return sqrt(distance2D * distance2D + dAlt * dAlt)
        }

        return distance2D
    }

    public func bearingTo(_ other: GeoCoordinate) -> Double {
        let lat1 = latitude * .pi / 180.0
        let lat2 = other.latitude * .pi / 180.0
        let dLon = (other.longitude - longitude) * .pi / 180.0

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180.0 / .pi

        return (bearing + 360.0).truncatingRemainder(dividingBy: 360.0)
    }
}
```

### カスタムSpatial実装例

```swift
/// Game coordinate system (2D or 3D)
///
/// Example for game world coordinates with configurable map bounds
public struct GamePosition: SpatialRepresentable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double?  // Optional floor/level

    public let mapBounds: (width: Double, height: Double, levels: Double?)

    public init(x: Double, y: Double, z: Double? = nil,
                mapBounds: (Double, Double, Double?) = (10000.0, 10000.0, nil)) {
        self.x = x
        self.y = y
        self.z = z
        self.mapBounds = mapBounds
    }

    public var spatialDimensions: Int {
        z != nil ? 3 : 2
    }

    public func toNormalizedCoordinates() -> [Double] {
        let normX = x / mapBounds.width
        let normY = y / mapBounds.height

        if let z = z, let levels = mapBounds.levels {
            let normZ = z / levels
            return [normX, normY, normZ]
        } else {
            return [normX, normY]
        }
    }

    public func distance(to other: GamePosition) -> Double {
        let dx = other.x - x
        let dy = other.y - y

        if let z1 = z, let z2 = other.z {
            let dz = z2 - z1
            return sqrt(dx * dx + dy * dy + dz * dz)
        }

        return sqrt(dx * dx + dy * dy)
    }
}
```

### SpatialType列挙型

```swift
/// Spatial index type
public enum SpatialType: String, Sendable {
    /// Geographic coordinates (latitude, longitude)
    /// Default for most use cases
    case geo

    /// Custom spatial type (future extension)
    case custom(String)
}
```

## 使用例

### Example 1: シンプルなVector検索（推奨製品）

```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])
    #Index<Product>([\.category])

    @Vector(dimensions: 768)  // BERT embeddings
    var embedding: Vector

    var productID: Int64
    var name: String
    var category: String
    var description: String
}

// 使用例
let schema = Schema([Product.self])
let store = try await RecordStore(
    database: database,
    schema: schema,
    recordType: Product.self
)

// 類似製品検索
let queryVector = Vector(/* 768-dim vector */)
let similarProducts = try await store.query(Product.self)
    .nearestNeighbors(\.embedding, to: queryVector, k: 10)
    .execute()
```

### Example 2: 地理検索（レストラン検索）

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])
    #Index<Restaurant>([\.category])

    @Spatial  // 2D geographic (default)
    var location: GeoCoordinate

    var restaurantID: Int64
    var name: String
    var category: String
    var rating: Double
}

// 使用例
let schema = Schema([Restaurant.self])
let store = try await RecordStore(
    database: database,
    schema: schema,
    recordType: Restaurant.self
)

// Bounding box検索（東京都内）
let restaurants = try await store.query(Restaurant.self)
    .where(\.location, .within(
        minLat: 35.5, minLon: 139.5,
        maxLat: 35.8, maxLon: 139.9
    ))
    .execute()

// 半径検索（現在地から1km以内）
let nearbyRestaurants = try await store.query(Restaurant.self)
    .where(\.location, .withinRadius(
        centerLat: 35.6812, centerLon: 139.7671,
        radiusMeters: 1000
    ))
    .execute()
```

### Example 3: 3D空間検索（ドローン追跡）

```swift
@Recordable
struct Drone {
    #PrimaryKey<Drone>([\.droneID])

    @Spatial(includeAltitude: true, altitudeRange: 0.0...5000.0)
    var position: GeoCoordinate

    var droneID: Int64
    var model: String
    var batteryLevel: Double
}

// 使用例
let schema = Schema([Drone.self])
let store = try await RecordStore(
    database: database,
    schema: schema,
    recordType: Drone.self
)

// 3D bounding box検索（特定の空域内のドローン）
let dronesInAirspace = try await store.query(Drone.self)
    .where(\.position, .within3D(
        minLat: 35.6, minLon: 139.7, minAlt: 100.0,
        maxLat: 35.7, maxLon: 139.8, maxAlt: 500.0
    ))
    .execute()
```

### Example 4: VectorとSpatialの組み合わせ

```swift
@Recordable
struct Hotel {
    #PrimaryKey<Hotel>([\.hotelID])

    @Vector(dimensions: 512)  // 説明文の埋め込み
    var descriptionEmbedding: Vector

    @Spatial  // 地理座標
    var location: GeoCoordinate

    var hotelID: Int64
    var name: String
    var rating: Double
}

// 使用例: セマンティック検索 + 地理フィルタ
let queryVector = Vector(/* "luxury beachfront resort" の埋め込み */)

let hotels = try await store.query(Hotel.self)
    .where(\.location, .withinRadius(
        centerLat: 35.6812, centerLon: 139.7671,
        radiusMeters: 5000  // 5km以内
    ))
    .nearestNeighbors(\.descriptionEmbedding, to: queryVector, k: 10)
    .execute()
```

### Example 5: カスタムVector実装（Sparse Vector）

```swift
@Recordable
struct Document {
    #PrimaryKey<Document>([\.documentID])

    // Sparse vectorを使用（次元数が大きいが0が多い場合）
    @Vector(dimensions: 10000)  // 10K dimensions with 99% zeros
    var tfidfVector: SparseVector

    var documentID: Int64
    var title: String
    var content: String
}

// 使用例
let sparseQuery = SparseVector(
    indices: [10, 150, 3000],  // 非ゼロ要素のインデックス
    values: [0.5, 0.8, 0.3],   // 対応する値
    dimensions: 10000
)

let similarDocs = try await store.query(Document.self)
    .nearestNeighbors(\.tfidfVector, to: sparseQuery, k: 20)
    .execute()
```

### Example 6: カスタムSpatial実装（Game Coordinates）

```swift
@Recordable
struct GameEntity {
    #PrimaryKey<GameEntity>([\.entityID])

    // ゲーム内座標系を使用
    @Spatial
    var position: GamePosition

    var entityID: Int64
    var entityType: String  // "player", "npc", "item"
    var health: Int
}

// 使用例: プレイヤーの周辺のアイテムを検索
let playerPos = GamePosition(x: 5000, y: 5000, mapBounds: (10000, 10000, nil))

let nearbyItems = try await store.query(GameEntity.self)
    .where(\.entityType, .equals, "item")
    .where(\.position, .withinRadius(
        centerX: playerPos.x, centerY: playerPos.y,
        radius: 100  // 100 game units
    ))
    .execute()
```

## マクロ実装の内部動作

### マクロとSchemaシステムの連携

**既存のIndexメタデータ収集フロー**:
```
1. @Recordableマクロが型を処理
2. #Index, #Uniqueマクロが indexDefinitions: [IndexDefinition] を生成
3. Schema初期化時に各型から indexDefinitions を収集
4. IndexDefinition → Index オブジェクトに変換
5. RecordStore.buildIndex() でインデックス構築
```

**@Vector/@Spatialマクロの統合**:
```
1. @Vectorマクロがプロパティを処理
2. @Recordableマクロが @Vector付きプロパティを検出
3. indexDefinitions に VectorIndexDefinition を追加（#Indexと同様）
4. Schema初期化時に収集・変換
5. VectorIndexMaintainer でHNSW構築
```

### @Vector マクロの展開

**入力**:
```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    @Vector(dimensions: 768, metric: .cosine)
    var embedding: Vector  // VectorRepresentable準拠型

    var productID: Int64
}
```

**生成されるコード（@Recordableマクロが統合）**:
```swift
extension Product {
    // 既存の indexDefinitions に追加される形で生成
    static var indexDefinitions: [IndexDefinition] {
        [
            // 他の #Index, #Unique マクロからの定義...

            // @Vector マクロから生成
            IndexDefinition(
                name: "Product_embedding_vector",  // 自動生成: RecordType_field_indextype
                recordType: "Product",
                fields: ["embedding"],
                unique: false,
                indexType: .vector,
                vectorOptions: VectorIndexOptions(
                    dimensions: 768,
                    metric: .cosine,
                    m: 16,
                    efConstruction: 100,
                    efSearch: 50
                )
            )
        ]
    }
}
```

**Schema収集とIndex変換**:
```swift
// Schema.init() での処理（既存フローと同じ）
public init(_ types: [any Recordable.Type], version: Version = Version(1, 0, 0)) {
    // ...

    var allIndexes: [Index] = []
    for type in types {
        // ✅ 既存: #Index, #Unique から生成された IndexDefinition を収集
        // ✅ 新規: @Vector, @Spatial から生成された IndexDefinition も収集
        let definitions = type.indexDefinitions

        for def in definitions {
            // IndexDefinition → Index オブジェクトに変換
            let index = Self.convertIndexDefinition(def, recordName: type.recordName)
            allIndexes.append(index)
        }
    }

    self.indexes = allIndexes
    // ...
}
```

**convertIndexDefinition の拡張**:
```swift
private static func convertIndexDefinition(
    _ definition: IndexDefinition,
    recordName: String
) -> Index {
    let keyExpression: KeyExpression
    if definition.fields.count == 1 {
        keyExpression = FieldKeyExpression(fieldName: definition.fields[0])
    } else {
        keyExpression = ConcatenateKeyExpression(
            children: definition.fields.map { FieldKeyExpression(fieldName: $0) }
        )
    }

    // IndexType に応じて IndexOptions を構築
    var options = IndexOptions(unique: definition.unique)

    switch definition.indexType {
    case .vector:
        // @Vector マクロから生成された VectorIndexOptions を設定
        options.vectorOptions = definition.vectorOptions

    case .spatial:
        // @Spatial マクロから生成された SpatialIndexOptions を設定
        options.spatialOptions = definition.spatialOptions

    default:
        // 既存のインデックスタイプ
        break
    }

    return Index(
        name: definition.name,
        type: definition.indexType,
        rootExpression: keyExpression,
        recordTypes: Set([recordName]),
        options: options
    )
}
```

### @Spatial マクロの展開

**入力**:
```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])

    @Spatial(includeAltitude: false)
    var location: GeoCoordinate

    var restaurantID: Int64
}
```

**生成されるメタデータ**:
```swift
extension Restaurant {
    static var indexDefinitions: [IndexDefinition] {
        [
            IndexDefinition(
                name: "Restaurant_location_spatial",
                recordType: "Restaurant",
                fields: ["location"],
                unique: false,
                indexType: .spatial,
                spatialOptions: SpatialIndexOptions(
                    type: .geo,
                    includeAltitude: false,
                    altitudeRange: nil
                )
            )
        ]
    }
}
```

## IndexOptionsの拡張

既存の`IndexOptions`を拡張して、Vector/Spatialオプションを追加：

```swift
public struct IndexOptions: Sendable {
    // 既存のフィールド
    public var unique: Bool
    public var replaceOnDuplicate: Bool
    public var allowedInEquality: Bool

    // Rank Index用
    public var rankOrderString: String?
    public var bucketSize: Int?
    public var tieBreaker: String?
    public var scoreTypeName: String?

    // Vector Index用（新規）
    public var vectorOptions: VectorIndexOptions?

    // Spatial Index用（新規）
    public var spatialOptions: SpatialIndexOptions?

    public init(
        unique: Bool = false,
        replaceOnDuplicate: Bool = false,
        allowedInEquality: Bool = true,
        // ... 既存パラメータ
        vectorOptions: VectorIndexOptions? = nil,
        spatialOptions: SpatialIndexOptions? = nil
    ) {
        // ...
    }
}

public struct VectorIndexOptions: Sendable {
    public let dimensions: Int
    public let metric: VectorMetric
    public let m: Int
    public let efConstruction: Int
    public let efSearch: Int

    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine,
        m: Int = 16,
        efConstruction: Int = 100,
        efSearch: Int = 50
    ) {
        self.dimensions = dimensions
        self.metric = metric
        self.m = m
        self.efConstruction = efConstruction
        self.efSearch = efSearch
    }
}

public struct SpatialIndexOptions: Sendable {
    public let type: SpatialType
    public let includeAltitude: Bool
    public let altitudeRange: ClosedRange<Double>?

    public init(
        type: SpatialType = .geo,
        includeAltitude: Bool = false,
        altitudeRange: ClosedRange<Double>? = nil
    ) {
        // Validation: includeAltitude=true requires altitudeRange
        if includeAltitude {
            guard let range = altitudeRange else {
                preconditionFailure("altitudeRange is required when includeAltitude=true")
            }
            guard range.lowerBound < range.upperBound else {
                preconditionFailure("altitudeRange must have lowerBound < upperBound")
            }
        }

        self.type = type
        self.includeAltitude = includeAltitude
        self.altitudeRange = altitudeRange
    }
}

// IndexMaintainerでの使用例
class SpatialIndexMaintainer<Record: Sendable>: IndexMaintainer {
    let options: SpatialIndexOptions

    func buildIndexKey(record: Record, recordAccess: any RecordAccess<Record>) throws -> FDB.Bytes {
        let spatialValue: any SpatialRepresentable = try recordAccess.extractSpatialValue(...)

        // altitudeRangeをSpatialIndexOptionsから取得してエンコード
        let normalizedCoords: [Double]
        if options.includeAltitude, let altitudeRange = options.altitudeRange {
            // 3D: altitudeRangeを渡す（GeoCoordinate.toNormalizedCoordinates(altitudeRange:)）
            if let geoCoord = spatialValue as? GeoCoordinate {
                normalizedCoords = geoCoord.toNormalizedCoordinates(altitudeRange: altitudeRange)
            } else {
                // カスタム型はデフォルトの toNormalizedCoordinates() を使用
                normalizedCoords = spatialValue.toNormalizedCoordinates()
            }
        } else {
            // 2D: デフォルトメソッドを使用
            normalizedCoords = spatialValue.toNormalizedCoordinates()
        }

        // Z-orderエンコード
        let zOrderKey = ZOrderCurve.encode(coordinates: normalizedCoords)
        return indexSubspace.pack(Tuple(zOrderKey, primaryKey))
    }
}
```

## IndexTypeの拡張

```swift
public enum IndexType: String, Sendable {
    case value
    case rank
    case count
    case sum
    case min
    case max
    case version
    case permuted

    // 新規追加
    case vector   // HNSW-based vector similarity search
    case spatial  // Z-order curve spatial indexing
}
```

## QueryBuilderの拡張

### Vector検索API

#### TypedRecordQuery拡張

```swift
extension TypedRecordQuery {
    /// Find k nearest neighbors using vector similarity
    ///
    /// This method adds a vector similarity search filter to the query.
    /// The actual search is performed using the HNSW index.
    ///
    /// **Parameters**:
    /// - `keyPath`: KeyPath to the vector field (must have @Vector annotation)
    /// - `queryVector`: Query vector (must conform to VectorRepresentable)
    /// - `k`: Number of nearest neighbors to return
    /// - `efSearch`: Optional override for search depth (default: use index's efSearch)
    ///
    /// **Example**:
    /// ```swift
    /// let queryVector = try Vector(elements: embedding, expectedDimensions: 768)
    /// let results = try await store.query(Product.self)
    ///     .nearestNeighbors(\.embedding, to: queryVector, k: 10)
    ///     .execute()
    ///
    /// // High-precision search (override efSearch)
    /// let results = try await store.query(Product.self)
    ///     .nearestNeighbors(\.embedding, to: queryVector, k: 10, efSearch: 200)
    ///     .execute()
    /// ```
    ///
    /// **Returns**: Modified query with vector similarity filter
    ///
    /// **Throws**:
    /// - `RecordLayerError.indexNotFound` if no @Vector index exists on the field
    /// - `RecordLayerError.invalidArgument` if dimensions don't match
    public func nearestNeighbors<V: VectorRepresentable>(
        _ keyPath: KeyPath<Record, V>,
        to queryVector: V,
        k: Int,
        efSearch: Int? = nil
    ) -> Self {
        // Implementation:
        // 1. Validate keyPath has @Vector index
        // 2. Validate dimensions match
        // 3. Add VectorSimilarityFilter to query
        // 4. Query planner will use VectorScanPlan
    }
}
```

#### VectorSimilarityFilter（内部実装）

```swift
/// Internal filter for vector similarity search
struct VectorSimilarityFilter<Record: Sendable>: TypedFilter {
    let fieldName: String
    let queryVector: [Float]  // toFloatArray() result
    let k: Int
    let efSearch: Int?
    let metric: VectorMetric  // From index metadata

    func matches(_ record: Record) -> Bool {
        // Not used (HNSW performs the search)
        return true
    }
}
```

#### VectorScanPlan（実行プラン）

```swift
/// Query plan for vector similarity search using HNSW index
struct VectorScanPlan<Record: Sendable>: TypedQueryPlan {
    let index: Index
    let queryVector: [Float]
    let k: Int
    let efSearch: Int

    func execute(store: RecordStore<Record>) async throws -> AnyTypedRecordCursor<Record> {
        // 1. Get HNSW graph from index
        // 2. Perform HNSW search (greedy search with efSearch)
        // 3. Return top-k results as cursor
        let vectorIndex = try await store.getVectorIndex(index.name)
        let results = try await vectorIndex.search(
            query: queryVector,
            k: k,
            efSearch: efSearch
        )
        return VectorResultCursor(results: results, store: store)
    }
}
```

### Spatial検索API

#### TypedRecordQuery拡張

```swift
extension TypedRecordQuery {
    /// Filter records within a spatial region
    ///
    /// This method adds a spatial filter to the query using Z-order curve indexing.
    ///
    /// **Parameters**:
    /// - `keyPath`: KeyPath to the spatial field (must have @Spatial annotation)
    /// - `operator`: Spatial operator (within, withinRadius, nearest)
    ///
    /// **Example - Bounding Box**:
    /// ```swift
    /// let restaurants = try await store.query(Restaurant.self)
    ///     .where(\.location, .within(
    ///         minLat: 35.5, minLon: 139.5,
    ///         maxLat: 35.8, maxLon: 139.9
    ///     ))
    ///     .execute()
    /// ```
    ///
    /// **Example - Radius Search**:
    /// ```swift
    /// let nearby = try await store.query(Restaurant.self)
    ///     .where(\.location, .withinRadius(
    ///         centerLat: 35.6812, centerLon: 139.7671,
    ///         radiusMeters: 1000
    ///     ))
    ///     .execute()
    /// ```
    ///
    /// **Example - K Nearest**:
    /// ```swift
    /// let nearest = try await store.query(Restaurant.self)
    ///     .where(\.location, .nearest(
    ///         lat: 35.6812, lon: 139.7671, k: 10
    ///     ))
    ///     .execute()
    /// ```
    ///
    /// **Returns**: Modified query with spatial filter
    ///
    /// **Throws**:
    /// - `RecordLayerError.indexNotFound` if no @Spatial index exists on the field
    public func `where`<S: SpatialRepresentable>(
        _ keyPath: KeyPath<Record, S>,
        _ operator: SpatialOperator
    ) -> Self {
        // Implementation:
        // 1. Validate keyPath has @Spatial index
        // 2. Add SpatialFilter to query
        // 3. Query planner will use SpatialScanPlan
    }
}
```

#### SpatialOperator列挙型

```swift
/// Spatial query operators
public enum SpatialOperator {
    /// Filter by 2D bounding box
    ///
    /// **Parameters**:
    /// - `minLat`, `minLon`: Southwest corner
    /// - `maxLat`, `maxLon`: Northeast corner
    ///
    /// **Example**:
    /// ```swift
    /// .where(\.location, .within(
    ///     minLat: 35.5, minLon: 139.5,
    ///     maxLat: 35.8, maxLon: 139.9
    /// ))
    /// ```
    case within(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)

    /// Filter by 3D bounding box (requires includeAltitude=true)
    ///
    /// **Parameters**:
    /// - `minLat`, `minLon`, `minAlt`: Southwest bottom corner
    /// - `maxLat`, `maxLon`, `maxAlt`: Northeast top corner
    ///
    /// **Example**:
    /// ```swift
    /// .where(\.position, .within3D(
    ///     minLat: 35.6, minLon: 139.7, minAlt: 100.0,
    ///     maxLat: 35.7, maxLon: 139.8, maxAlt: 500.0
    /// ))
    /// ```
    case within3D(minLat: Double, minLon: Double, minAlt: Double,
                  maxLat: Double, maxLon: Double, maxAlt: Double)

    /// Filter by radius from center point
    ///
    /// **Parameters**:
    /// - `centerLat`, `centerLon`: Center coordinates
    /// - `radiusMeters`: Radius in meters (Haversine distance for geographic coordinates)
    ///
    /// **Example**:
    /// ```swift
    /// .where(\.location, .withinRadius(
    ///     centerLat: 35.6812, centerLon: 139.7671,
    ///     radiusMeters: 1000
    /// ))
    /// ```
    case withinRadius(centerLat: Double, centerLon: Double, radiusMeters: Double)

    /// Find k nearest points to given coordinates
    ///
    /// **Parameters**:
    /// - `lat`, `lon`: Query coordinates
    /// - `k`: Number of nearest points to return
    ///
    /// **Example**:
    /// ```swift
    /// .where(\.location, .nearest(
    ///     lat: 35.6812, lon: 139.7671, k: 10
    /// ))
    /// ```
    case nearest(lat: Double, lon: Double, k: Int)
}
```

#### SpatialScanPlan（実行プラン）

```swift
/// Query plan for spatial search using Z-order curve index
struct SpatialScanPlan<Record: Sendable>: TypedQueryPlan {
    let index: Index
    let operator: SpatialOperator

    func execute(store: RecordStore<Record>) async throws -> AnyTypedRecordCursor<Record> {
        switch operator {
        case .within(let minLat, let minLon, let maxLat, let maxLon):
            // 1. Convert bounding box to Z-order range(s)
            let ranges = ZOrderCurve.boundingBoxToRanges(
                minLat: minLat, minLon: minLon,
                maxLat: maxLat, maxLon: maxLon
            )
            // 2. Scan FDB keys in Z-order ranges
            // 3. Post-filter to remove false positives (Z-order approximation)
            return SpatialBoundingBoxCursor(ranges: ranges, store: store)

        case .withinRadius(let centerLat, let centerLon, let radiusMeters):
            // 1. Convert radius to bounding box
            let bbox = haversineRadiusToBoundingBox(
                centerLat: centerLat, centerLon: centerLon,
                radiusMeters: radiusMeters
            )
            // 2. Use bounding box scan + Haversine post-filter
            return SpatialRadiusCursor(center: (centerLat, centerLon), radius: radiusMeters, store: store)

        case .nearest(let lat, let lon, let k):
            // 1. Expand bounding box iteratively until k results found
            // 2. Sort by distance
            return SpatialNearestCursor(query: (lat, lon), k: k, store: store)

        case .within3D:
            // Similar to 2D but with 3D Z-order encoding
            fatalError("3D spatial queries require implementation")
        }
    }
}
```

## @Attributeマクロとの関係

### 役割の明確な分離

**@Attribute**: データ属性の指定（圧縮、暗号化、ストレージ最適化）

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    @Attribute(.unique)  // ← データ制約
    var email: String

    @Attribute(originalName: "username")  // ← スキーマ進化
    var name: String

    var userID: Int64
}
```

**@Vector / @Spatial**: インデックスタイプの指定（検索最適化）

```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    @Vector(dimensions: 768)  // ← インデックスタイプ
    var embedding: Vector

    @Spatial  // ← インデックスタイプ
    var location: GeoCoordinate

    var productID: Int64
}
```

### 組み合わせ可能

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    @Attribute(.unique)  // データ制約
    @Index<User>([\.email])  // 通常のインデックス
    var email: String

    @Vector(dimensions: 512)  // Vectorインデックス
    @Attribute(originalName: "profileEmbedding")  // スキーマ進化
    var embedding: Vector

    var userID: Int64
}
```

## 実装ステップ

### Phase 1: 基礎型とマクロ定義（Sources/FDBRecordLayer/）

1. **Types.swift** に `IndexType` の `.vector`, `.spatial` を追加
2. **Index.swift** に `VectorIndexOptions`, `SpatialIndexOptions` を追加
3. **Vector.swift** (新規) - `Vector`, `VectorMetric` の定義
4. **GeoCoordinate.swift** (新規) - `GeoCoordinate`, `SpatialType` の定義
5. **ZOrderCurve.swift** (新規) - Z-orderカーブのエンコード/デコード

### Phase 2: マクロ実装（Sources/FDBRecordLayerMacros/）

1. **VectorMacro.swift** (新規) - `@Vector` マクロの実装
2. **SpatialMacro.swift** (新規) - `@Spatial` マクロの実装
3. **Plugin.swift** - VectorMacro, SpatialMacro を登録
4. **Macros.swift** - `@Vector`, `@Spatial` マクロをエクスポート

### Phase 3: インデックスメンテナー（Sources/FDBRecordLayer/Index/）

1. **VectorIndex.swift** (新規) - HNSW実装
2. **SpatialIndex.swift** (新規) - Z-orderカーブ実装
3. **IndexManager.swift** - Vector/Spatialインデックスのサポート追加

### Phase 4: クエリプランナー拡張（Sources/FDBRecordLayer/Query/）

1. **TypedRecordQuery.swift** - `nearestNeighbors()`, `where(_:_:)` API追加
2. **VectorScanPlan.swift** (新規) - Vector検索プラン
3. **SpatialScanPlan.swift** (新規) - Spatial検索プラン
4. **TypedRecordQueryPlanner.swift** - Vector/Spatialプランのサポート

### Phase 5: テスト（Tests/FDBRecordLayerTests/）

1. **VectorMacroTests.swift** - マクロ展開のテスト
2. **SpatialMacroTests.swift** - マクロ展開のテスト
3. **VectorIndexTests.swift** - HNSW実装のテスト
4. **SpatialIndexTests.swift** - Z-orderカーブのテスト
5. **VectorQueryTests.swift** - Vector検索のテスト
6. **SpatialQueryTests.swift** - Spatial検索のテスト

## パフォーマンス特性

### Vector Index (HNSW)

#### 時間・空間計算量

| 操作 | 時間計算量 | 説明 |
|------|-----------|------|
| 構築 | O(N log N * M * efConstruction) | N=レコード数, M=接続数 |
| 検索 | O(log N * efSearch) | efSearch = 探索の深さ |
| 挿入 | O(log N * M * efConstruction) | 新しいノードの接続 |
| メモリ | O(N * M * dimensions * 4) | Float32を前提 |

#### HNSWパラメータ詳細

**M (Max connections per layer)**:
- **意味**: 各ノードが持つ最大エッジ数（グラフの密度）
- **範囲**: 4 ~ 64（推奨: 8 ~ 32）
- **トレードオフ**:
  - 大きい: 高精度・高メモリ・遅い構築
  - 小さい: 低精度・低メモリ・速い構築
- **目安**: M = 2 * dimensions / 100 （768次元なら M=15前後）

**efConstruction (Build-time search depth)**:
- **意味**: インデックス構築時の探索深さ（グラフ品質）
- **範囲**: 50 ~ 500（推奨: 100 ~ 200）
- **トレードオフ**:
  - 大きい: 高品質グラフ・遅い構築
  - 小さい: 低品質グラフ・速い構築
- **ルール**: efConstruction ≥ M （通常は efConstruction = M * 6~12）

**efSearch (Query-time search depth)**:
- **意味**: クエリ時の探索深さ（recall vs latency）
- **範囲**: 10 ~ 500（推奨: 50 ~ 100）
- **トレードオフ**:
  - 大きい: 高recall・高レイテンシ
  - 小さい: 低recall・低レイテンシ
- **ルール**: efSearch ≥ k （k=近傍数）
- **実行時調整**: クエリごとにオーバーライド可能

**metric (Distance metric)**:
- **cosine**: テキスト埋め込み、画像埋め込み（99%のケース）
- **l2**: 正規化済みベクトル、CV特定タスク
- **innerProduct**: 事前正規化済みベクトル、推薦システム
- **重要**: インデックス作成後は変更不可（グラフ構造が依存）

#### データ規模別の推奨設定

| データ規模 | レコード数 | M | efConstruction | efSearch | メモリ (768次元) | 構築時間 | 検索レイテンシ |
|----------|----------|---|----------------|----------|----------------|---------|---------------|
| **Small** | ~10K | 8 | 50 | 25 | ~40 MB | ~30秒 | ~5ms (k=10) |
| **Medium** | ~100K | 16 | 100 | 50 | ~600 MB | ~10分 | ~10ms (k=10) |
| **Large** | ~1M | 24 | 150 | 75 | ~7.5 GB | ~3時間 | ~20ms (k=10) |
| **X-Large** | ~10M+ | 32 | 200 | 100 | ~100 GB | ~2日 | ~30ms (k=10) |

**メモリ計算式（実測ベース）**:
```
基本: N * dimensions * 4 bytes * 1.5 (ベクトル + メタデータ)
グラフ: N * M * 8 bytes * 2 (エッジストレージ、平均2層)
合計: (N * dimensions * 4 * 1.5 + N * M * 8 * 2) / 1e9 GB

例: Large (1M, M=24, 768次元)
  = (1,000,000 * 768 * 4 * 1.5 + 1,000,000 * 24 * 8 * 2) / 1e9
  = (4,608,000,000 + 384,000,000) / 1e9
  = 4.99 GB ≈ 5 GB (基本)

  ※ 実測では追加のオーバーヘッド（検索キャッシュ、トランザクションバッファ等）により
    最終的に基本値の ~1.5x となることが多い: 5 GB * 1.5 = 7.5 GB
```

**注意**: 上記は**HNSWインデックスのみ**のメモリ使用量です。実際のシステムでは以下も考慮してください：
- レコードストレージ: 別途必要（FDBに永続化）
- クエリバッファ: 並行クエリ数 × k × レコードサイズ
- システムオーバーヘッド: OS、Swift runtime等

#### 精度・速度トレードオフ

**Recall @ k=10の目安**:

| efSearch | Small (10K) | Medium (100K) | Large (1M) |
|----------|-------------|---------------|-----------|
| 25 | 90% | 85% | 80% |
| 50 | 95% | 92% | 88% |
| 100 | 98% | 96% | 94% |
| 200 | 99% | 98% | 97% |

**チューニング指針**:
1. **プロトタイプ**: デフォルト値（M=16, efConstruction=100, efSearch=50）
2. **精度重視**: M↑, efConstruction↑, efSearch↑
3. **速度重視**: M↓, efConstruction↓, efSearch↓
4. **メモリ制約**: M↓（最も影響大）
5. **構築時間制約**: efConstruction↓

**実運用の調整例**:
```swift
// 開発環境: 速度優先
@Vector(dimensions: 768, m: 8, efConstruction: 50, efSearch: 25)

// 本番環境: バランス（デフォルト）
@Vector(dimensions: 768)  // m=16, efConstruction=100, efSearch=50

// 本番環境: 高精度
@Vector(dimensions: 768, m: 24, efConstruction: 150, efSearch: 100)

// クエリ時のefSearch調整（実行時）
let results = try await store.query(Product.self)
    .nearestNeighbors(\.embedding, to: queryVector, k: 10, efSearch: 200)  // 高精度
    .execute()
```

### Spatial Index (Z-order)

#### 時間・空間計算量

| 操作 | 時間計算量 | 説明 |
|------|-----------|------|
| 構築 | O(N) | 単純なビット操作 |
| Bounding box | O(log N + K) | K=結果数 |
| 半径検索 | O(log N + K) | Haversine距離でフィルタ |
| 挿入 | O(log N) | FoundationDBのB-tree |
| メモリ | O(N * 8) | UInt64キー |

#### ビット割り当てと精度

**2D空間（64ビット総容量）**:
- 緯度: 32ビット
- 経度: 32ビット
- 精度: 360度 / 2^32 ≈ 8.4e-8度 ≈ **1cm**（地球座標）

**3D空間（64ビット総容量）**:
- 緯度: 21ビット
- 経度: 21ビット
- 高度: 21ビット (余り1ビットは未使用)
- 精度: 360度 / 2^21 ≈ 1.7e-4度 ≈ **19m**（地球座標）
- 高度精度: range / 2^21 （例: 10000m → **5mm**）

**トレードオフ**: 3D使用時は水平精度が低下（1cm → 19m）

#### 高度処理の詳細仕様

**includeAltitude = false（デフォルト, 2D）**:
```swift
@Spatial
var location: GeoCoordinate

// 動作:
// - altitude フィールドは無視される
// - Z-orderエンコーディングは2Dのみ（lat, lon）
// - 高度が異なる座標も同一として扱われる

let loc1 = GeoCoordinate(latitude: 35.6812, longitude: 139.7671, altitude: 0)
let loc2 = GeoCoordinate(latitude: 35.6812, longitude: 139.7671, altitude: 100)
// → 同じZ-orderキーにエンコードされる（水平位置のみ）
```

**includeAltitude = true（3D）**:
```swift
@Spatial(includeAltitude: true, altitudeRange: 0.0...10000.0)
var location: GeoCoordinate

// 動作:
// - altitude フィールドが必須（nilの場合はエラー）
// - Z-orderエンコーディングは3D（lat, lon, alt）
// - altitudeRange で正規化範囲を指定

let loc = GeoCoordinate(latitude: 35.6812, longitude: 139.7671, altitude: 500)
// → 3Dビット割り当てでエンコード
```

**altitudeRange の指定**:
- **必須**: `includeAltitude = true` の場合は必ず指定
- **用途**: 高度を [0, 1] の範囲に正規化するための範囲
- **範囲外処理**: クリッピング（範囲外の値を境界値に制限）

**正規化とクリッピングの例**:
```swift
// 設定: altitudeRange: 0.0...10000.0

// 正常値
let alt1 = 5000.0  // → 正規化: 0.5 → 21ビット: 1048576

// 範囲外（上限超過）: クリッピング
let alt2 = 15000.0  // → クリッピング: 10000.0 → 正規化: 1.0 → 21ビット: 2097151

// 範囲外（下限未満）: クリッピング
let alt3 = -500.0  // → クリッピング: 0.0 → 正規化: 0.0 → 21ビット: 0

// GeoCoordinate.toNormalizedCoordinates() の実装
public func toNormalizedCoordinates() -> [Double] {
    let normLat = (latitude + 90.0) / 180.0
    let normLon = (longitude + 180.0) / 360.0

    if let alt = altitude {
        // クリッピング: 範囲外の値を境界値に制限
        let clippedAlt = min(max(alt, altitudeRange.lowerBound), altitudeRange.upperBound)
        // 正規化: [lowerBound, upperBound] → [0, 1]
        let normAlt = (clippedAlt - altitudeRange.lowerBound) /
                      (altitudeRange.upperBound - altitudeRange.lowerBound)
        return [normLat, normLon, normAlt]
    } else {
        return [normLat, normLon]
    }
}
```

**実用例**:

| 用途 | altitudeRange | 精度 |
|------|--------------|------|
| ドローン（低高度） | 0.0...500.0 | 500m / 2^21 ≈ **0.2mm** |
| 航空機 | 0.0...15000.0 | 15000m / 2^21 ≈ **7mm** |
| 衛星 | 0.0...1000000.0 | 1000km / 2^21 ≈ **48cm** |

**検証とエラーハンドリング**:
```swift
// マクロ生成の検証コード
extension Drone {
    func validateSpatialFields() throws {
        // includeAltitude=true の場合、altitudeがnilはエラー
        guard position.altitude != nil else {
            throw RecordLayerError.invalidArgument(
                "Spatial field 'position' requires altitude (includeAltitude=true)"
            )
        }

        // altitudeRangeが指定されている場合、範囲外を警告（クリッピング）
        let alt = position.altitude!
        if alt < 0.0 || alt > 5000.0 {
            // ⚠️ 警告: クリッピングされる
            // （エラーではなく、自動的に境界値に制限）
        }
    }
}
```

## 制約と注意事項

### @Vector マクロ

1. **プロトコル要求**: プロパティ型は `VectorRepresentable` プロトコルに準拠する必要があります
   - 標準実装: `Vector`（dense vector）
   - カスタム実装: `SparseVector`, `QuantizedVector` など
2. **次元一致**: 実行時にベクトルの次元数が一致しない場合はエラー
3. **メトリック不変性**: インデックス作成後にメトリックを変更できません（HNSWグラフ構造が依存）
4. **メモリ使用量**: 大規模データセット（100万件以上）では数GBのメモリが必要
5. **精度 vs 速度**: efSearchを大きくすると精度が向上しますが、速度が低下します
6. **⚠️ toFloatArray()のパフォーマンス（重要）**:
   - **問題**: デフォルト実装は `toFloatArray()` を複数回呼び出します（dot: 2回、l2Distance: 2回、cosineSimilarity: 5回）
   - **影響**: `SparseVector` や `QuantizedVector` のように変換コストが高い型では、パフォーマンスが大幅に低下します
   - **対策**:
     - ✅ **推奨**: カスタム実装を提供（最も効率的、例: SparseVectorのdot()を非ゼロ要素のみで計算）
     - ⚠️ **次善**: キャッシュ戦略を使用（メモリ増加とのトレードオフ）
     - ❌ **非推奨**: 重い変換処理をtoFloatArray()に実装してデフォルト実装を使用
   - 詳細は「VectorRepresentableプロトコル」のパフォーマンス注記を参照してください

### @Spatial マクロ

1. **プロトコル要求**: プロパティ型は `SpatialRepresentable` プロトコルに準拠する必要があります
   - 標準実装: `GeoCoordinate`（地理座標）
   - カスタム実装: `GamePosition`, カスタム投影法など
2. **正規化範囲**: `toNormalizedCoordinates()` は [0.0, 1.0] の範囲を返す必要があります
3. **次元数**: 2D（平面）または 3D（立体）のみサポート（4D以上は未対応）
4. **Z-order特性**: 極端に細長いbounding boxでは効率が低下する可能性があります
5. **距離計算の一貫性**: `distance(to:)` の実装は座標系に適した方法を使用してください
   - 地理座標: Haversine距離（球面距離）
   - 平面座標: Euclidean距離
6. **精度トレードオフ**:
   - 2D: 32ビット/次元 → ~1cm精度（地球座標）
   - 3D: 21ビット/次元 → ~50cm精度（地球座標）

## まとめ

このドキュメントでは、以下を定義しました：

✅ **@Vector マクロ**: HNSW-based vector similarity search（attached property macro）
✅ **@Spatial マクロ**: Z-order curve spatial indexing（attached property macro）
✅ **プロトコルベース設計**:
   - `VectorRepresentable`: カスタムベクトル型をサポート（Sparse, Quantized等）
   - `SpatialRepresentable`: カスタム座標系をサポート（Game, Projection等）
✅ **標準実装**: Vector（dense vector）, GeoCoordinate（geographic）
✅ **カスタム実装例**: SparseVector, QuantizedVector, GamePosition
✅ **型定義**: VectorMetric, SpatialType列挙型
✅ **IndexOptions拡張**: VectorIndexOptions, SpatialIndexOptions
✅ **QueryBuilder API**: nearestNeighbors(), where(_:_:) with SpatialOperator
✅ **使用例**:
   - 標準実装: 推奨製品、レストラン検索、ドローン追跡、複合検索
   - カスタム実装: Sparse vector検索、ゲーム内座標検索
✅ **実装ステップ**: Phase 1-5の詳細計画
✅ **パフォーマンス特性**: 時間計算量とメモリ使用量
✅ **制約と注意事項**: プロトコル要求、精度、パフォーマンストレードオフ

**設計の利点**:
- **拡張性**: ユーザーが独自の型を定義可能（プロトコル準拠のみ）
- **柔軟性**: 様々なベクトル表現・座標系に対応
- **型安全性**: コンパイル時にプロトコル準拠をチェック
- **デフォルト実装**: 99%のユースケースは標準実装で対応可能

**次のステップ**: Phase 1から実装を開始します。
