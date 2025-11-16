import Foundation

// MARK: - Vector Index Options

/// Options for vector similarity search indexes (HNSW)
public struct VectorIndexOptions: Sendable {
    /// Number of vector dimensions
    public let dimensions: Int

    /// Distance metric for similarity calculation
    public let metric: VectorMetric

    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine
    ) {
        self.dimensions = dimensions
        self.metric = metric
    }
}

/// Distance metric for vector similarity search
public enum VectorMetric: String, Sendable {
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
    /// Spatial type (2D/3D, geographic/cartesian)
    public let type: SpatialType

    /// Altitude range for 3D spatial indexes (required for .geo3D and .cartesian3D)
    ///
    /// This range is used to normalize altitude values to [0, 1] for Z-order encoding.
    /// **Example**: `0...10000` for altitudes from sea level to 10km
    ///
    /// **Note**: Must be provided for 3D spatial types, ignored for 2D types
    public let altitudeRange: ClosedRange<Double>?

    public init(type: SpatialType = .geo, altitudeRange: ClosedRange<Double>? = nil) {
        self.type = type
        self.altitudeRange = altitudeRange

        // Validate: 3D types require altitudeRange
        if (type == .geo3D || type == .cartesian3D) && altitudeRange == nil {
            preconditionFailure("3D spatial types (.geo3D, .cartesian3D) require altitudeRange")
        }
    }
}

/// Spatial index type with KeyPath-based coordinate extraction
///
/// This enum uses associated values to store KeyPaths for extracting coordinate values
/// from arbitrary nested structures. This eliminates the need for SpatialRepresentable protocol.
///
/// **Usage**:
/// ```swift
/// @Spatial(
///     type: .geo(
///         latitude: \.address.location.latitude,
///         longitude: \.address.location.longitude
///     )
/// )
/// var address: Address
/// ```
public enum SpatialType: Sendable {
    /// 2D geographic coordinates (latitude, longitude)
    ///
    /// - Parameters:
    ///   - latitude: KeyPath to latitude field (Double)
    ///   - longitude: KeyPath to longitude field (Double)
    case geo(latitude: AnyKeyPath, longitude: AnyKeyPath)

    /// 3D geographic coordinates (latitude, longitude, altitude)
    ///
    /// - Parameters:
    ///   - latitude: KeyPath to latitude field (Double)
    ///   - longitude: KeyPath to longitude field (Double)
    ///   - altitude: KeyPath to altitude field (Double)
    case geo3D(latitude: AnyKeyPath, longitude: AnyKeyPath, altitude: AnyKeyPath)

    /// 2D Cartesian coordinates (x, y)
    ///
    /// - Parameters:
    ///   - x: KeyPath to x field (Double)
    ///   - y: KeyPath to y field (Double)
    case cartesian(x: AnyKeyPath, y: AnyKeyPath)

    /// 3D Cartesian coordinates (x, y, z)
    ///
    /// - Parameters:
    ///   - x: KeyPath to x field (Double)
    ///   - y: KeyPath to y field (Double)
    ///   - z: KeyPath to z field (Double)
    case cartesian3D(x: AnyKeyPath, y: AnyKeyPath, z: AnyKeyPath)

    /// Number of dimensions (2 or 3)
    public var dimensions: Int {
        switch self {
        case .geo, .cartesian:
            return 2
        case .geo3D, .cartesian3D:
            return 3
        }
    }

    /// Extract KeyPaths for coordinate value extraction
    ///
    /// Returns KeyPaths in order:
    /// - `.geo`: [latitude, longitude]
    /// - `.geo3D`: [latitude, longitude, altitude]
    /// - `.cartesian`: [x, y]
    /// - `.cartesian3D`: [x, y, z]
    public var keyPaths: [AnyKeyPath] {
        switch self {
        case .geo(let lat, let lon):
            return [lat, lon]
        case .geo3D(let lat, let lon, let alt):
            return [lat, lon, alt]
        case .cartesian(let x, let y):
            return [x, y]
        case .cartesian3D(let x, let y, let z):
            return [x, y, z]
        }
    }

    /// Extract coordinate values from a record using stored KeyPaths
    ///
    /// - Parameter record: The record to extract coordinates from
    /// - Returns: Array of Double values in order (lat/lon or x/y or lat/lon/alt or x/y/z)
    /// - Throws: RecordLayerError if KeyPath type mismatch or value extraction fails
    public func extractCoordinates<Record>(from record: Record) throws -> [Double] {
        return try keyPaths.map { keyPath in
            guard let typedKeyPath = keyPath as? KeyPath<Record, Double> else {
                throw RecordLayerError.internalError(
                    "SpatialType KeyPath must resolve to Double. " +
                    "KeyPath: \(keyPath), Record: \(type(of: record))"
                )
            }
            return record[keyPath: typedKeyPath]
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

/// Index scope for IndexDefinition
public enum IndexDefinitionScope: String, Sendable {
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
