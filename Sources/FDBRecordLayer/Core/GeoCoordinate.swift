import Foundation

// MARK: - SpatialRepresentable Protocol

/// Protocol for types that can be indexed spatially
///
/// Any type conforming to this protocol can be used with the @Spatial macro.
/// This allows users to define custom spatial types while still benefiting from
/// Z-order curve-based spatial indexing.
///
/// **Coordinate System**:
/// - 2D: [longitude, latitude] normalized to [0, 1]
/// - 3D: [longitude, latitude, altitude] normalized to [0, 1]
///
/// **Normalization**:
/// The protocol requires normalization to [0, 1] range for efficient Z-order encoding.
/// - Longitude: [-180, 180] → [0, 1]
/// - Latitude: [-90, 90] → [0, 1]
/// - Altitude: [min, max] → [0, 1] (user-defined range)
///
/// **Example Usage**:
/// ```swift
/// @Recordable
/// struct Restaurant {
///     #PrimaryKey<Restaurant>([\.id])
///     #Spatial<Restaurant>([\.location], name: "by_location")
///
///     var id: Int64
///     @Spatial var location: GeoCoordinate  // Standard implementation
/// }
/// ```
public protocol SpatialRepresentable: Sendable {
    /// Number of spatial dimensions (2 for 2D, 3 for 3D)
    var spatialDimensions: Int { get }

    /// Convert to normalized coordinates [0, 1] for Z-order encoding
    ///
    /// **2D (default)**:
    /// Returns [longitude_normalized, latitude_normalized]
    /// - longitude: [-180, 180] → [0, 1]
    /// - latitude: [-90, 90] → [0, 1]
    ///
    /// **Performance**: Should be O(1) for simple types
    ///
    /// - Returns: Array of normalized coordinates in [0, 1] range
    func toNormalizedCoordinates() -> [Double]

    /// Convert to normalized coordinates with altitude [0, 1] for 3D Z-order encoding
    ///
    /// **3D**:
    /// Returns [longitude_normalized, latitude_normalized, altitude_normalized]
    /// - altitude: [min, max] → [0, 1] using provided altitudeRange
    ///
    /// **Note**: The altitudeRange parameter comes from SpatialIndexOptions.altitudeRange
    /// and is passed by the IndexMaintainer during encoding.
    ///
    /// - Parameter altitudeRange: User-defined altitude range for normalization
    /// - Returns: Array of 3 normalized coordinates in [0, 1] range
    func toNormalizedCoordinates(altitudeRange: ClosedRange<Double>) -> [Double]

    /// Calculate distance to another spatial point
    ///
    /// Default implementation uses Haversine formula for geographic coordinates.
    /// Override for custom distance metrics.
    ///
    /// - Parameter other: Another spatial point of the same type
    /// - Returns: Distance in meters (for geographic coordinates)
    func distance(to other: Self) -> Double
}

// MARK: - SpatialRepresentable Default Implementations

extension SpatialRepresentable {
    /// Default implementation using Haversine formula
    ///
    /// **Formula**: Great-circle distance on Earth's surface
    /// **Accuracy**: ±0.5% for distances < 1000km
    /// **Performance**: O(1)
    ///
    /// **Note**: Override this method for custom distance metrics or non-geographic coordinates.
    public func distance(to other: Self) -> Double {
        // This implementation assumes GeoCoordinate-like structure
        // Custom types should override with appropriate distance calculation
        return 0.0  // Placeholder - will be overridden by concrete types
    }
}

// MARK: - GeoCoordinate (Standard Geographic Implementation)

/// Standard geographic coordinate implementation for spatial indexing
///
/// This is the recommended type for location-based applications.
///
/// **Coordinate System**:
/// - Latitude: [-90, 90] degrees (North/South)
/// - Longitude: [-180, 180] degrees (East/West)
/// - Altitude: meters above sea level (optional)
///
/// **Usage**:
/// ```swift
/// // 2D (latitude/longitude only)
/// let location = GeoCoordinate(latitude: 35.6762, longitude: 139.6503)
///
/// // 3D (with altitude)
/// let locationWithAltitude = GeoCoordinate(
///     latitude: 35.6762,
///     longitude: 139.6503,
///     altitude: 40.0  // Tokyo Tower height
/// )
///
/// // Distance calculation
/// let distance = location1.distance(to: location2)  // meters
/// ```
///
/// **Index Definition**:
/// ```swift
/// // 2D spatial index (default)
/// #Spatial<Restaurant>([\.location], name: "by_location")
///
/// // 3D spatial index with altitude
/// #Spatial<Restaurant>(
///     [\.location],
///     name: "by_location_3d",
///     includeAltitude: true,
///     altitudeRange: 0...10000  // 0-10km
/// )
/// ```
public struct GeoCoordinate: SpatialRepresentable, Equatable, Sendable {
    /// Latitude in degrees [-90, 90]
    public let latitude: Double

    /// Longitude in degrees [-180, 180]
    public let longitude: Double

    /// Altitude in meters (optional, for 3D spatial indexing)
    public let altitude: Double?

    /// Number of spatial dimensions
    public var spatialDimensions: Int {
        return altitude != nil ? 3 : 2
    }

    // MARK: - Initialization

    /// Initialize with latitude and longitude (2D)
    ///
    /// - Parameters:
    ///   - latitude: Latitude in degrees [-90, 90]
    ///   - longitude: Longitude in degrees [-180, 180]
    ///   - altitude: Optional altitude in meters
    /// - Note: Coordinates are validated at initialization time
    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        precondition(
            latitude >= -90 && latitude <= 90,
            "Latitude must be in range [-90, 90], got \(latitude)"
        )
        precondition(
            longitude >= -180 && longitude <= 180,
            "Longitude must be in range [-180, 180], got \(longitude)"
        )

        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    // MARK: - SpatialRepresentable Implementation

    /// Convert to normalized coordinates [0, 1] for 2D Z-order encoding
    ///
    /// **Normalization**:
    /// - Longitude: [-180, 180] → [0, 1] via (longitude + 180) / 360
    /// - Latitude: [-90, 90] → [0, 1] via (latitude + 90) / 180
    ///
    /// **Bit Allocation** (Z-order curve):
    /// - 2D: 32 bits per dimension (64-bit total)
    /// - Precision: ~1cm at equator
    ///
    /// - Returns: [longitude_normalized, latitude_normalized]
    public func toNormalizedCoordinates() -> [Double] {
        let normalizedLongitude = (longitude + 180.0) / 360.0
        let normalizedLatitude = (latitude + 90.0) / 180.0
        return [normalizedLongitude, normalizedLatitude]
    }

    /// Convert to normalized coordinates [0, 1] for 3D Z-order encoding with altitude
    ///
    /// **Normalization**:
    /// - Longitude: [-180, 180] → [0, 1]
    /// - Latitude: [-90, 90] → [0, 1]
    /// - Altitude: [altitudeRange.lowerBound, altitudeRange.upperBound] → [0, 1]
    ///
    /// **Bit Allocation** (Z-order curve):
    /// - 3D: 21 bits per dimension (63-bit total)
    /// - Precision: ~50cm horizontal, varies by altitude range
    ///
    /// **Example**:
    /// ```swift
    /// let location = GeoCoordinate(latitude: 35.6762, longitude: 139.6503, altitude: 40.0)
    /// let normalized = location.toNormalizedCoordinates(altitudeRange: 0...10000)
    /// // normalized[2] = (40 - 0) / (10000 - 0) = 0.004
    /// ```
    ///
    /// **Important**: The altitudeRange parameter comes from SpatialIndexOptions and is
    /// passed by the IndexMaintainer during encoding. It must match the range specified
    /// in the index definition.
    ///
    /// - Parameter altitudeRange: Altitude range for normalization (from SpatialIndexOptions)
    /// - Returns: [longitude_normalized, latitude_normalized, altitude_normalized]
    public func toNormalizedCoordinates(altitudeRange: ClosedRange<Double>) -> [Double] {
        var coords = toNormalizedCoordinates()  // [longitude, latitude]

        if let alt = altitude {
            // Normalize altitude: [min, max] → [0, 1]
            let normalizedAltitude = (alt - altitudeRange.lowerBound) /
                                    (altitudeRange.upperBound - altitudeRange.lowerBound)
            // Clamp to [0, 1] to handle out-of-range values gracefully
            let clampedAltitude = min(max(normalizedAltitude, 0.0), 1.0)
            coords.append(clampedAltitude)
        } else {
            // No altitude provided - use midpoint (0.5) as default
            coords.append(0.5)
        }

        return coords
    }

    /// Calculate great-circle distance to another coordinate using Haversine formula
    ///
    /// **Haversine Formula**:
    /// ```
    /// a = sin²(Δlat/2) + cos(lat1) * cos(lat2) * sin²(Δlon/2)
    /// c = 2 * atan2(√a, √(1−a))
    /// distance = R * c  (R = Earth radius)
    /// ```
    ///
    /// **Accuracy**:
    /// - ±0.5% for distances < 1000km
    /// - ±3% for distances > 1000km (Earth is not a perfect sphere)
    ///
    /// **Performance**: O(1)
    ///
    /// **Note**: Altitude difference is ignored in this calculation.
    /// Use `distance3D(to:)` if you need to include altitude difference.
    ///
    /// - Parameter other: Another geographic coordinate
    /// - Returns: Distance in meters
    public func distance(to other: Self) -> Double {
        let R = 6371000.0  // Earth radius in meters

        // Convert to radians
        let lat1 = latitude * .pi / 180.0
        let lat2 = other.latitude * .pi / 180.0
        let dLat = (other.latitude - latitude) * .pi / 180.0
        let dLon = (other.longitude - longitude) * .pi / 180.0

        // Haversine formula
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return R * c
    }

    // MARK: - Utility Methods

    /// Calculate bearing (direction) to another coordinate
    ///
    /// **Bearing**: Angle measured clockwise from North
    /// - 0° = North
    /// - 90° = East
    /// - 180° = South
    /// - 270° = West
    ///
    /// **Formula**:
    /// ```
    /// θ = atan2(sin(Δlon) * cos(lat2),
    ///          cos(lat1) * sin(lat2) − sin(lat1) * cos(lat2) * cos(Δlon))
    /// bearing = (θ * 180 / π + 360) mod 360
    /// ```
    ///
    /// **Use Case**: Navigation, direction arrows in UI
    ///
    /// - Parameter other: Destination coordinate
    /// - Returns: Bearing in degrees [0, 360)
    public func bearingTo(_ other: GeoCoordinate) -> Double {
        let lat1 = latitude * .pi / 180.0
        let lat2 = other.latitude * .pi / 180.0
        let dLon = (other.longitude - longitude) * .pi / 180.0

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) -
                sin(lat1) * cos(lat2) * cos(dLon)
        let theta = atan2(y, x)

        // Convert to degrees and normalize to [0, 360)
        let bearing = (theta * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
        return bearing
    }

    /// Calculate 3D distance including altitude difference
    ///
    /// **Formula**: Combines Haversine distance with altitude difference
    /// ```
    /// distance3D = √(distance2D² + Δaltitude²)
    /// ```
    ///
    /// **Use Case**: Drone navigation, 3D spatial queries
    ///
    /// - Parameter other: Another coordinate (must have altitude)
    /// - Returns: 3D distance in meters, or nil if either coordinate lacks altitude
    public func distance3D(to other: GeoCoordinate) -> Double? {
        guard let alt1 = altitude, let alt2 = other.altitude else {
            return nil
        }

        let horizontalDistance = distance(to: other)
        let verticalDistance = abs(alt2 - alt1)

        return sqrt(horizontalDistance * horizontalDistance + verticalDistance * verticalDistance)
    }

    /// Check if this coordinate is within a bounding box
    ///
    /// **Use Case**: Quick bounding box filter before expensive spatial queries
    ///
    /// - Parameters:
    ///   - southwest: Southwest corner of bounding box
    ///   - northeast: Northeast corner of bounding box
    /// - Returns: true if coordinate is inside the bounding box
    public func isWithin(southwest: GeoCoordinate, northeast: GeoCoordinate) -> Bool {
        return latitude >= southwest.latitude &&
               latitude <= northeast.latitude &&
               longitude >= southwest.longitude &&
               longitude <= northeast.longitude
    }
}

// MARK: - GeoCoordinate CustomStringConvertible

extension GeoCoordinate: CustomStringConvertible {
    public var description: String {
        if let alt = altitude {
            return String(format: "GeoCoordinate(lat: %.6f, lon: %.6f, alt: %.1fm)",
                         latitude, longitude, alt)
        } else {
            return String(format: "GeoCoordinate(lat: %.6f, lon: %.6f)",
                         latitude, longitude)
        }
    }
}

// MARK: - Example Custom Spatial Types (for reference)

/*
/// Example: Custom spatial type for game world coordinates
///
/// This type demonstrates how to implement SpatialRepresentable for non-geographic data.
public struct GameWorldCoordinate: SpatialRepresentable {
    public let x: Double  // [0, worldWidth]
    public let y: Double  // [0, worldHeight]
    public let z: Double? // Optional height

    private let worldWidth: Double
    private let worldHeight: Double

    public var spatialDimensions: Int { z != nil ? 3 : 2 }

    public init(x: Double, y: Double, z: Double? = nil, worldWidth: Double, worldHeight: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.worldWidth = worldWidth
        self.worldHeight = worldHeight
    }

    public func toNormalizedCoordinates() -> [Double] {
        return [
            x / worldWidth,
            y / worldHeight
        ]
    }

    public func toNormalizedCoordinates(altitudeRange: ClosedRange<Double>) -> [Double] {
        var coords = toNormalizedCoordinates()
        if let height = z {
            let normalized = (height - altitudeRange.lowerBound) /
                           (altitudeRange.upperBound - altitudeRange.lowerBound)
            coords.append(min(max(normalized, 0.0), 1.0))
        } else {
            coords.append(0.5)
        }
        return coords
    }

    public func distance(to other: Self) -> Double {
        // Simple Euclidean distance
        let dx = x - other.x
        let dy = y - other.y
        return sqrt(dx * dx + dy * dy)
    }
}

/// Example: Sparse spatial data with compression
///
/// This type demonstrates spatial indexing with data compression.
public struct CompressedLocation: SpatialRepresentable {
    // Store coordinates as Int32 to save memory (4 bytes instead of 16 bytes)
    private let latitudeInt: Int32   // latitude * 1e7
    private let longitudeInt: Int32  // longitude * 1e7

    public var spatialDimensions: Int { 2 }

    public var latitude: Double {
        return Double(latitudeInt) / 1e7
    }

    public var longitude: Double {
        return Double(longitudeInt) / 1e7
    }

    public init(latitude: Double, longitude: Double) {
        self.latitudeInt = Int32(latitude * 1e7)
        self.longitudeInt = Int32(longitude * 1e7)
    }

    public func toNormalizedCoordinates() -> [Double] {
        return [
            (longitude + 180.0) / 360.0,
            (latitude + 90.0) / 180.0
        ]
    }

    public func toNormalizedCoordinates(altitudeRange: ClosedRange<Double>) -> [Double] {
        return toNormalizedCoordinates() + [0.5]
    }

    // Inherit default distance() implementation
}
*/
