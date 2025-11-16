import Foundation

// MARK: - Vector Index Options

/// Options for vector similarity search indexes (data structure only)
///
/// **Design Principle**: This struct defines the **data structure** of vector indexes
/// (dimensions and distance metric). Runtime optimization strategy (flatScan vs HNSW)
/// is configured separately via `IndexConfiguration` at Schema initialization time.
///
/// **Why separate strategy from model definition?**
/// - Environment-dependent: Test (flatScan) vs production (HNSW) may differ
/// - Hardware-dependent: Low memory (flatScan) vs high memory (HNSW)
/// - Data-scale-dependent: Initially 100 records (flatScan), later 1M records (HNSW)
/// - Model should define structure, not runtime optimization
///
/// **Examples**:
/// ```swift
/// // Model definition: Data structure only
/// @Recordable
/// struct Product {
///     #Index<Product>([\.embedding], type: .vector(dimensions: 384, metric: .cosine))
///     var embedding: [Float32]
/// }
///
/// // Runtime configuration: Strategy selection
/// let schema = Schema(
///     [Product.self],
///     vectorStrategies: [
///         "product_embedding": .hnswBatch  // Production: HNSW
///         // "product_embedding": .flatScan  // Test: Flat Scan
///     ]
/// )
/// ```
///
/// See `IndexConfiguration` and `VectorIndexStrategy` for runtime strategy selection.
public struct VectorIndexOptions: Sendable {
    /// Number of vector dimensions
    public let dimensions: Int

    /// Distance metric for similarity calculation
    public let metric: VectorMetric

    /// Initializer
    ///
    /// - Parameters:
    ///   - dimensions: Number of vector dimensions
    ///   - metric: Distance metric for similarity calculation (default: .cosine)
    ///
    /// **Examples**:
    /// ```swift
    /// // Cosine similarity (default, for ML embeddings)
    /// VectorIndexOptions(dimensions: 384)
    ///
    /// // L2 (Euclidean) distance
    /// VectorIndexOptions(dimensions: 384, metric: .l2)
    ///
    /// // Inner product (dot product)
    /// VectorIndexOptions(dimensions: 384, metric: .innerProduct)
    /// ```
    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine
    ) {
        self.dimensions = dimensions
        self.metric = metric
    }
}

// MARK: - VectorIndexOptions Codable

extension VectorIndexOptions: Codable {
    enum CodingKeys: String, CodingKey {
        case dimensions
        case metric
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dimensions = try container.decode(Int.self, forKey: .dimensions)
        let metric = try container.decode(VectorMetric.self, forKey: .metric)

        self.init(dimensions: dimensions, metric: metric)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(metric, forKey: .metric)
    }
}

/// Distance metric for vector similarity search
public enum VectorMetric: String, Sendable, Codable {
    /// Cosine similarity (default for ML embeddings)
    case cosine

    /// L2 (Euclidean) distance
    case l2

    /// Inner product (dot product)
    case innerProduct
}

// MARK: - Spatial Index Options

/// Options for spatial indexing using Z-order curve
public struct SpatialIndexOptions: Sendable {
    /// Spatial type (2D/3D, geographic/cartesian) with KeyPath-based extraction
    public let type: SpatialType

    /// Altitude range for 3D spatial indexes (optional with safe default for .geo3D and .cartesian3D)
    ///
    /// This range is used to normalize altitude values to [0, 1] for Z-order encoding.
    ///
    /// **Default for 3D types**: `0...10000` meters (sea level to 10km altitude)
    /// - Covers most real-world use cases (aircraft, drones, buildings)
    /// - Automatically applied when omitted for .geo3D/.cartesian3D
    ///
    /// **Example**: `0...10000` for altitudes from sea level to 10km
    ///
    /// **Note**: Ignored for 2D types (.geo, .cartesian)
    public let altitudeRange: ClosedRange<Double>?

    /// Initialize spatial index options
    ///
    /// - Parameters:
    ///   - type: Spatial type with KeyPaths for coordinate extraction
    ///   - altitudeRange: Required for 3D types, optional for 2D types
    ///
    /// **Examples**:
    /// ```swift
    /// // 2D geographic
    /// SpatialIndexOptions(
    ///     type: .geo(latitude: \.lat, longitude: \.lon)
    /// )
    ///
    /// // 3D geographic
    /// SpatialIndexOptions(
    ///     type: .geo3D(latitude: \.lat, longitude: \.lon, altitude: \.alt),
    ///     altitudeRange: 0...10000
    /// )
    /// ```
    public init(type: SpatialType, altitudeRange: ClosedRange<Double>? = nil) {
        self.type = type

        // Backward compatibility: Provide safe default for 3D types if altitudeRange not specified
        // This prevents crashes when loading old metadata that doesn't include altitudeRange
        if type.dimensions == 3 && altitudeRange == nil {
            // Default: 0-10000 meters (covers sea level to 10km altitude)
            // This range handles most real-world use cases:
            // - Aircraft: up to ~12km
            // - Drones: typically < 500m
            // - Buildings: typically < 1km
            self.altitudeRange = 0...10000

            // Note: Users should explicitly specify altitudeRange for their use case
            // Example: SpatialIndexOptions(type: .geo3D(...), altitudeRange: 0...10000)
        } else {
            self.altitudeRange = altitudeRange
        }
    }
}

// MARK: - SpatialIndexOptions Codable

extension SpatialIndexOptions: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case altitudeRange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SpatialType.self, forKey: .type)

        // altitudeRange is optional - if missing, init will provide default for 3D types
        let altitudeRange = try container.decodeIfPresent(ClosedRange<Double>.self, forKey: .altitudeRange)

        self.init(type: type, altitudeRange: altitudeRange)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(altitudeRange, forKey: .altitudeRange)
    }
}

/// Spatial index type with KeyPath-based coordinate extraction
///
/// This enum stores KeyPath string representations for extracting coordinate values
/// from arbitrary nested structures. This eliminates the need for SpatialRepresentable protocol.
///
/// **Note**: KeyPaths are stored as strings for Sendable conformance. The actual KeyPath
/// objects are reconstructed at runtime in FDBRecordLayer.
///
/// **Level Defaults**:
/// - `.geo`: Level 17 (cell edge ~9m, matches typical GPS accuracy ±5-10m)
/// - `.geo3D`: Level 16 (cell edge ~18m + altitude normalization)
/// - `.cartesian`: Level 18 (2^18 ≈ 262k grid resolution)
/// - `.cartesian3D`: Level 16 (each axis 65k steps)
///
/// **Usage**:
/// ```swift
/// @Spatial(
///     type: .geo(
///         latitude: \.address.location.latitude,
///         longitude: \.address.location.longitude,
///         level: 17  // Optional, defaults to 17
///     )
/// )
/// var address: Address
/// ```
public enum SpatialType: Sendable, Equatable {
    /// 2D geographic coordinates (latitude, longitude) using S2 Geometry + Hilbert curve
    ///
    /// **Default Level 17** (cell edge ~600m):
    /// - Balances precision vs S2RegionCoverer cell count
    /// - Suitable for city-level location queries
    /// - Each S2Cell at level 17 is ~600m × ~600m at equator
    ///
    /// **Level Selection Guide**:
    /// - Level 15: ~2.4km cells (regional queries, low precision)
    /// - Level 17: ~600m cells (city-level queries, **default**)
    /// - Level 20: ~76m cells (building-level precision)
    ///
    /// - Parameters:
    ///   - latitude: KeyPath string (e.g., "\.latitude" or "\.address.location.latitude")
    ///   - longitude: KeyPath string (e.g., "\.longitude" or "\.address.location.longitude")
    ///   - level: S2Cell level (0-30, default 17)
    case geo(latitude: String, longitude: String, level: Int = 17)

    /// 3D geographic coordinates (latitude, longitude, altitude) using S2 + altitude encoding
    ///
    /// **Default Level 16** (cell edge ~1.2km):
    /// - Slightly coarser than .geo to accommodate 3D altitude encoding
    /// - Altitude is normalized to altitudeRange and encoded in upper bits
    ///
    /// **Encoding Strategy**:
    /// - Bits 0-39: S2CellID at level 16 (40 bits)
    /// - Bits 40-63: Normalized altitude (24 bits, ~16.7M steps)
    ///
    /// **Level Selection Guide**:
    /// - Level 14: ~4.8km cells (regional 3D queries)
    /// - Level 16: ~1.2km cells (typical drone/aviation use, **default**)
    /// - Level 18: ~300m cells (high-precision 3D positioning)
    ///
    /// - Parameters:
    ///   - latitude: KeyPath string
    ///   - longitude: KeyPath string
    ///   - altitude: KeyPath string
    ///   - level: S2Cell level for lat/lon (0-30, default 16)
    case geo3D(latitude: String, longitude: String, altitude: String, level: Int = 16)

    /// 2D Cartesian coordinates (x, y) using Morton Code (Z-order curve)
    ///
    /// **Default Level 18** (2^18 ≈ 262k grid):
    /// - Each axis divided into 262,144 steps
    /// - Suitable for normalized [0, 1] or bounded integer coordinates
    ///
    /// **Level Selection Guide**:
    /// - Level 16: 65k × 65k grid (coarse game maps, low-res simulation)
    /// - Level 18: 262k × 262k grid (typical use, **default**)
    /// - Level 20: 1M × 1M grid (high-precision CAD, scientific data)
    ///
    /// - Parameters:
    ///   - x: KeyPath string
    ///   - y: KeyPath string
    ///   - level: Morton Code bit depth per axis (0-30, default 18)
    case cartesian(x: String, y: String, level: Int = 18)

    /// 3D Cartesian coordinates (x, y, z) using 3D Morton Code
    ///
    /// **Default Level 16** (65k steps per axis):
    /// - Total 64-bit encoding: 3 × 21 bits (2.1M steps/axis) + 1 bit unused
    /// - Level 16 uses 16 bits/axis → 65,536 steps per axis
    ///
    /// **Level Selection Guide**:
    /// - Level 14: 16k steps/axis (voxel-based games, Minecraft-like)
    /// - Level 16: 65k steps/axis (typical 3D simulation, **default**)
    /// - Level 18: 262k steps/axis (high-precision 3D CAD)
    ///
    /// - Parameters:
    ///   - x: KeyPath string
    ///   - y: KeyPath string
    ///   - z: KeyPath string
    ///   - level: Morton Code bit depth per axis (0-20, default 16)
    case cartesian3D(x: String, y: String, z: String, level: Int = 16)

    /// Number of dimensions (2 or 3)
    public var dimensions: Int {
        switch self {
        case .geo, .cartesian:
            return 2
        case .geo3D, .cartesian3D:
            return 3
        }
    }

    /// The level parameter for spatial indexing precision
    ///
    /// - `.geo`/`.geo3D`: S2Cell level (0-30)
    /// - `.cartesian`/`.cartesian3D`: Morton Code bit depth per axis (0-30 for 2D, 0-20 for 3D)
    public var level: Int {
        switch self {
        case .geo(_, _, let level):
            return level
        case .geo3D(_, _, _, let level):
            return level
        case .cartesian(_, _, let level):
            return level
        case .cartesian3D(_, _, _, let level):
            return level
        }
    }

    /// Validate the level parameter for this spatial type
    ///
    /// - Returns: `true` if level is within valid range
    public var isValidLevel: Bool {
        switch self {
        case .geo, .geo3D:
            return level >= 0 && level <= 30  // S2Cell levels
        case .cartesian:
            return level >= 0 && level <= 30  // 2D Morton: 30 bits per axis (60 bits total)
        case .cartesian3D:
            return level >= 0 && level <= 20  // 3D Morton: 20 bits per axis (60 bits total)
        }
    }

    /// Extract KeyPath strings for coordinate value extraction
    ///
    /// Returns KeyPath strings in order:
    /// - `.geo`: [latitude, longitude]
    /// - `.geo3D`: [latitude, longitude, altitude]
    /// - `.cartesian`: [x, y]
    /// - `.cartesian3D`: [x, y, z]
    public var keyPathStrings: [String] {
        switch self {
        case .geo(let lat, let lon, _):
            return [lat, lon]
        case .geo3D(let lat, let lon, let alt, _):
            return [lat, lon, alt]
        case .cartesian(let x, let y, _):
            return [x, y]
        case .cartesian3D(let x, let y, let z, _):
            return [x, y, z]
        }
    }

    /// Debug description for error messages
    public var debugDescription: String {
        switch self {
        case .geo(let lat, let lon, let level):
            return ".geo(latitude: \(lat), longitude: \(lon), level: \(level))"
        case .geo3D(let lat, let lon, let alt, let level):
            return ".geo3D(latitude: \(lat), longitude: \(lon), altitude: \(alt), level: \(level))"
        case .cartesian(let x, let y, let level):
            return ".cartesian(x: \(x), y: \(y), level: \(level))"
        case .cartesian3D(let x, let y, let z, let level):
            return ".cartesian3D(x: \(x), y: \(y), z: \(z), level: \(level))"
        }
    }
}

// MARK: - SpatialType Codable (Backward Compatibility)

extension SpatialType: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case latitude, longitude, altitude
        case x, y, z
        case level
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "geo":
            let latitude = try container.decode(String.self, forKey: .latitude)
            let longitude = try container.decode(String.self, forKey: .longitude)
            // Backward compatibility: Use default if level is missing
            let level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 17
            self = .geo(latitude: latitude, longitude: longitude, level: level)

        case "geo3D":
            let latitude = try container.decode(String.self, forKey: .latitude)
            let longitude = try container.decode(String.self, forKey: .longitude)
            let altitude = try container.decode(String.self, forKey: .altitude)
            // Backward compatibility: Use default if level is missing
            let level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 16
            self = .geo3D(latitude: latitude, longitude: longitude, altitude: altitude, level: level)

        case "cartesian":
            let x = try container.decode(String.self, forKey: .x)
            let y = try container.decode(String.self, forKey: .y)
            // Backward compatibility: Use default if level is missing
            let level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 18
            self = .cartesian(x: x, y: y, level: level)

        case "cartesian3D":
            let x = try container.decode(String.self, forKey: .x)
            let y = try container.decode(String.self, forKey: .y)
            let z = try container.decode(String.self, forKey: .z)
            // Backward compatibility: Use default if level is missing
            let level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 16
            self = .cartesian3D(x: x, y: y, z: z, level: level)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown SpatialType: '\(type)'. Valid types: geo, geo3D, cartesian, cartesian3D"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .geo(let latitude, let longitude, let level):
            try container.encode("geo", forKey: .type)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encode(level, forKey: .level)

        case .geo3D(let latitude, let longitude, let altitude, let level):
            try container.encode("geo3D", forKey: .type)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encode(altitude, forKey: .altitude)
            try container.encode(level, forKey: .level)

        case .cartesian(let x, let y, let level):
            try container.encode("cartesian", forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(level, forKey: .level)

        case .cartesian3D(let x, let y, let z, let level):
            try container.encode("cartesian3D", forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(z, forKey: .z)
            try container.encode(level, forKey: .level)
        }
    }
}

// MARK: - Index Definition Types

/// Index type for IndexDefinition
public enum IndexDefinitionType: Sendable {
    case value
    case rank
    case count
    case sum
    case min
    case max
    case vector(VectorIndexOptions)
    case spatial(SpatialIndexOptions)
    case version
}

// MARK: - IndexDefinitionType Codable

extension IndexDefinitionType: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case vectorOptions
        case spatialOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "value":
            self = .value
        case "rank":
            self = .rank
        case "count":
            self = .count
        case "sum":
            self = .sum
        case "min":
            self = .min
        case "max":
            self = .max
        case "vector":
            let options = try container.decode(VectorIndexOptions.self, forKey: .vectorOptions)
            self = .vector(options)
        case "spatial":
            let options = try container.decode(SpatialIndexOptions.self, forKey: .spatialOptions)
            self = .spatial(options)
        case "version":
            self = .version
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown IndexDefinitionType: '\(type)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .value:
            try container.encode("value", forKey: .type)
        case .rank:
            try container.encode("rank", forKey: .type)
        case .count:
            try container.encode("count", forKey: .type)
        case .sum:
            try container.encode("sum", forKey: .type)
        case .min:
            try container.encode("min", forKey: .type)
        case .max:
            try container.encode("max", forKey: .type)
        case .vector(let options):
            try container.encode("vector", forKey: .type)
            try container.encode(options, forKey: .vectorOptions)
        case .spatial(let options):
            try container.encode("spatial", forKey: .type)
            try container.encode(options, forKey: .spatialOptions)
        case .version:
            try container.encode("version", forKey: .type)
        }
    }
}

/// Index scope for IndexDefinition
public enum IndexDefinitionScope: String, Sendable, Codable {
    case partition
    case global
}

/// Range型インデックスの境界成分
public enum RangeComponent: String, Sendable, Codable {
    case lowerBound
    case upperBound
}

/// Range型の境界タイプ
public enum BoundaryType: String, Sendable, Codable {
    case halfOpen  // [a, b) - Range<T>, PartialRangeUpTo<T>
    case closed    // [a, b] - ClosedRange<T>, PartialRangeFrom<T>, PartialRangeThrough<T>
}

// MARK: - Index Definition

/// Definition of an index created by #Index, #Unique, @Vector, or @Spatial macros
///
/// This type holds the metadata for indexes defined using macros.
/// The RecordMetadata will collect these definitions and register them.
public struct IndexDefinition: Sendable {
    /// The name of the index
    public let name: String

    /// The record type this index applies to
    public let recordType: String

    /// The fields included in this index
    public let fields: [String]

    /// Whether this index enforces uniqueness
    public let unique: Bool

    /// The type of index (.value, .vector, .spatial)
    public let indexType: IndexDefinitionType

    /// The scope of the index (.partition, .global)
    public let scope: IndexDefinitionScope

    /// Range型インデックスの境界成分（Range型の場合のみ設定）
    public let rangeComponent: RangeComponent?

    /// Range型の境界タイプ（Range型の場合のみ設定）
    public let boundaryType: BoundaryType?

    /// Initialize an index definition with field name strings
    ///
    /// - Parameters:
    ///   - name: The name of the index
    ///   - recordType: The record type this index applies to
    ///   - fields: The fields included in this index
    ///   - unique: Whether this index enforces uniqueness
    ///   - indexType: The type of index (default: .value)
    ///   - scope: The scope of the index (default: .partition)
    public init(
        name: String,
        recordType: String,
        fields: [String],
        unique: Bool,
        indexType: IndexDefinitionType = .value,
        scope: IndexDefinitionScope = .partition
    ) {
        self.name = name
        self.recordType = recordType
        self.fields = fields
        self.unique = unique
        self.indexType = indexType
        self.scope = scope
        self.rangeComponent = nil
        self.boundaryType = nil
    }

    /// Initialize an index definition with Range type support
    ///
    /// - Parameters:
    ///   - name: The name of the index
    ///   - recordType: The record type this index applies to
    ///   - fields: The fields included in this index
    ///   - unique: Whether this index enforces uniqueness
    ///   - indexType: The type of index (default: .value)
    ///   - scope: The scope of the index (default: .partition)
    ///   - rangeComponent: The range boundary component (for Range type indexes)
    ///   - boundaryType: The range boundary type (for Range type indexes)
    public init(
        name: String,
        recordType: String,
        fields: [String],
        unique: Bool,
        indexType: IndexDefinitionType = .value,
        scope: IndexDefinitionScope = .partition,
        rangeComponent: RangeComponent?,
        boundaryType: BoundaryType?
    ) {
        self.name = name
        self.recordType = recordType
        self.fields = fields
        self.unique = unique
        self.indexType = indexType
        self.scope = scope
        self.rangeComponent = rangeComponent
        self.boundaryType = boundaryType
    }

    /// Initialize an index definition with KeyPaths (type-safe)
    ///
    /// This initializer uses `PartialKeyPath` to provide compile-time type safety.
    ///
    /// - Parameters:
    ///   - name: The name of the index
    ///   - keyPaths: The key paths to the fields included in this index
    ///   - unique: Whether this index enforces uniqueness
    ///   - indexType: The type of index (default: .value)
    ///   - scope: The scope of the index (default: .partition)
    ///
    /// Example:
    /// ```swift
    /// let emailIndex = IndexDefinition(
    ///     name: "User_email_index",
    ///     keyPaths: [\User.email] as [PartialKeyPath<User>],
    ///     unique: false
    /// )
    /// ```
    public init<Record: Recordable>(
        name: String,
        keyPaths: [PartialKeyPath<Record>],
        unique: Bool,
        indexType: IndexDefinitionType = .value,
        scope: IndexDefinitionScope = .partition
    ) {
        self.name = name
        self.recordType = Record.recordName

        // Convert KeyPaths to field name strings using Record's fieldName method
        self.fields = keyPaths.map { keyPath in
            Record.fieldName(for: keyPath)
        }

        self.unique = unique
        self.indexType = indexType
        self.scope = scope
        self.rangeComponent = nil
        self.boundaryType = nil
    }

    /// Initialize an index definition with KeyPaths and Range type support
    ///
    /// - Parameters:
    ///   - name: The name of the index
    ///   - keyPaths: The key paths to the fields included in this index
    ///   - unique: Whether this index enforces uniqueness
    ///   - indexType: The type of index (default: .value)
    ///   - scope: The scope of the index (default: .partition)
    ///   - rangeComponent: The range boundary component (for Range type indexes)
    ///   - boundaryType: The range boundary type (for Range type indexes)
    public init<Record: Recordable>(
        name: String,
        keyPaths: [PartialKeyPath<Record>],
        unique: Bool,
        indexType: IndexDefinitionType = .value,
        scope: IndexDefinitionScope = .partition,
        rangeComponent: RangeComponent?,
        boundaryType: BoundaryType?
    ) {
        self.name = name
        self.recordType = Record.recordName

        // Convert KeyPaths to field name strings using Record's fieldName method
        self.fields = keyPaths.map { keyPath in
            Record.fieldName(for: keyPath)
        }

        self.unique = unique
        self.indexType = indexType
        self.scope = scope
        self.rangeComponent = rangeComponent
        self.boundaryType = boundaryType
    }
}
