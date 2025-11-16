import Foundation

/// 3D Geographic coordinate encoding using S2CellID + altitude
///
/// **Encoding Strategy**:
/// - Bits 0-39: S2CellID at specified level (40 bits, supports up to level 16)
/// - Bits 40-63: Normalized altitude (24 bits, ~16.7M steps)
///
/// **Level vs Bit Allocation**:
/// - Level 16: 2*16 + 3 = 35 bits → 40 bits (5 bits padding)
/// - Level 17: 2*17 + 3 = 37 bits → 40 bits (3 bits padding)
/// - Level 18: 2*18 + 3 = 39 bits → 40 bits (1 bit padding)
/// - Level 19+: Requires >40 bits, not supported for .geo3D
///
/// **Altitude Range**:
/// - Specified via `SpatialIndexOptions.altitudeRange`
/// - Default: 0...10000 (meters, sea level to 10km)
/// - Aviation: -500...15000 (below sea level to stratosphere)
/// - Underwater: -11000...0 (Mariana Trench to surface)
///
/// **Example**:
/// ```swift
/// // Tokyo at 40m altitude
/// let s2cell = S2CellID.fromLatLon(
///     latitude: 35.6762 * .pi / 180,
///     longitude: 139.6503 * .pi / 180,
///     level: 16
/// )
/// let encoded = Geo3DEncoding.encode(
///     s2cell: s2cell,
///     altitude: 40.0,
///     altitudeRange: 0...10000
/// )
/// // Bits 0-39: S2CellID (2594699609063424)
/// // Bits 40-63: Normalized altitude (67108) → final UInt64
/// ```
public struct Geo3DEncoding {

    // MARK: - Constants

    /// Number of bits allocated to S2CellID (lower bits)
    private static let s2CellIDBits: Int = 40

    /// Number of bits allocated to altitude (upper bits)
    private static let altitudeBits: Int = 24

    /// Maximum S2Cell level supported (level 18 = 39 bits, fits in 40)
    ///
    /// **Bit Count by Level**:
    /// - Level 0: 3 bits (face ID only)
    /// - Level 16: 35 bits → 40 bits (5 bits padding)
    /// - Level 17: 37 bits → 40 bits (3 bits padding)
    /// - Level 18: 39 bits → 40 bits (1 bit padding)
    /// - Level 19: 41 bits → ❌ exceeds 40-bit allocation
    ///
    /// For `.geo3D`, default level 16 is recommended to leave room for altitude.
    public static let maxSupportedLevel: Int = 18

    /// Maximum altitude steps (2^24 - 1 = 16,777,215)
    private static let maxAltitudeSteps: UInt64 = (1 << altitudeBits) - 1

    /// Bitmask for extracting S2CellID (lower 40 bits)
    private static let s2CellIDMask: UInt64 = (1 << s2CellIDBits) - 1

    /// Bitmask for extracting altitude (upper 24 bits)
    private static let altitudeMask: UInt64 = ((1 << altitudeBits) - 1) << s2CellIDBits

    // MARK: - Encoding

    /// Encode 3D geographic coordinates (S2CellID + altitude) into a single UInt64
    ///
    /// - Parameters:
    ///   - s2cell: S2CellID at level ≤ 18
    ///   - altitude: Altitude value (in same units as altitudeRange)
    ///   - altitudeRange: Range for altitude normalization
    /// - Returns: 64-bit encoded value
    /// - Throws: `RecordLayerError` if level > 18 or altitude out of range
    ///
    /// **Encoding Process**:
    /// 1. Validate S2CellID level ≤ 18
    /// 2. Normalize altitude to [0, 1] using altitudeRange
    /// 3. Convert to integer steps [0, 16777215]
    /// 4. Pack: `(altitudeSteps << 40) | (s2cell.id & 0xFFFFFFFFFF)`
    public static func encode(
        s2cell: S2CellID,
        altitude: Double,
        altitudeRange: ClosedRange<Double>
    ) throws -> UInt64 {
        // Validate S2Cell level
        let level = s2cell.level
        guard level <= maxSupportedLevel else {
            throw RecordLayerError.invalidArgument(
                "S2Cell level \(level) exceeds maximum \(maxSupportedLevel) for .geo3D encoding. " +
                "Use level ≤ 18 or consider separate indexing for lat/lon and altitude."
            )
        }

        // Validate altitude range
        guard altitude >= altitudeRange.lowerBound && altitude <= altitudeRange.upperBound else {
            throw RecordLayerError.invalidArgument(
                "Altitude \(altitude) is outside valid range \(altitudeRange). " +
                "Adjust SpatialIndexOptions.altitudeRange to include this value."
            )
        }

        // Normalize altitude to [0, 1]
        let rangeSpan = altitudeRange.upperBound - altitudeRange.lowerBound
        guard rangeSpan > 0 else {
            throw RecordLayerError.invalidArgument(
                "Altitude range must have positive span (got \(altitudeRange))"
            )
        }

        let normalized = (altitude - altitudeRange.lowerBound) / rangeSpan

        // Convert to integer steps [0, maxAltitudeSteps]
        let altitudeSteps = UInt64(normalized * Double(maxAltitudeSteps))

        // Extract lower 40 bits of S2CellID
        let s2cellLower40 = s2cell.rawValue & s2CellIDMask

        // Pack: altitude in upper 24 bits, S2CellID in lower 40 bits
        let encoded = (altitudeSteps << UInt64(s2CellIDBits)) | s2cellLower40

        return encoded
    }

    /// Encode 3D geographic coordinates from lat/lon/altitude values
    ///
    /// Convenience method that creates S2CellID from lat/lon before encoding.
    ///
    /// - Parameters:
    ///   - latitude: Latitude in radians [-π/2, π/2]
    ///   - longitude: Longitude in radians [-π, π]
    ///   - altitude: Altitude value (in same units as altitudeRange)
    ///   - altitudeRange: Range for altitude normalization
    ///   - level: S2Cell level (0-18, default 16)
    /// - Returns: 64-bit encoded value
    public static func encode(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        altitudeRange: ClosedRange<Double>,
        level: Int = 16
    ) throws -> UInt64 {
        // Convert radians to degrees for S2CellID initializer
        let latDeg = latitude * 180.0 / .pi
        let lonDeg = longitude * 180.0 / .pi

        let s2cell = S2CellID(lat: latDeg, lon: lonDeg, level: level)
        return try encode(
            s2cell: s2cell,
            altitude: altitude,
            altitudeRange: altitudeRange
        )
    }

    // MARK: - Decoding

    /// Decode a 64-bit value into S2CellID and altitude
    ///
    /// - Parameters:
    ///   - encoded: 64-bit encoded value
    ///   - altitudeRange: Range for altitude denormalization
    /// - Returns: Tuple of (s2cell, altitude)
    ///
    /// **Decoding Process**:
    /// 1. Extract lower 40 bits → S2CellID
    /// 2. Extract upper 24 bits → altitude steps
    /// 3. Denormalize altitude: `altitudeRange.lowerBound + (steps / maxSteps) * rangeSpan`
    public static func decode(
        encoded: UInt64,
        altitudeRange: ClosedRange<Double>
    ) -> (s2cell: S2CellID, altitude: Double) {
        // Extract S2CellID (lower 40 bits)
        let s2cellID = encoded & s2CellIDMask
        let s2cell = S2CellID(rawValue: s2cellID)

        // Extract altitude steps (upper 24 bits)
        let altitudeSteps = (encoded & altitudeMask) >> UInt64(s2CellIDBits)

        // Denormalize altitude
        let normalized = Double(altitudeSteps) / Double(maxAltitudeSteps)
        let rangeSpan = altitudeRange.upperBound - altitudeRange.lowerBound
        let altitude = altitudeRange.lowerBound + (normalized * rangeSpan)

        return (s2cell, altitude)
    }

    /// Decode a 64-bit value into lat/lon/altitude
    ///
    /// Convenience method that extracts lat/lon from S2CellID.
    ///
    /// - Parameters:
    ///   - encoded: 64-bit encoded value
    ///   - altitudeRange: Range for altitude denormalization
    /// - Returns: Tuple of (latitude, longitude, altitude) in radians and altitude units
    public static func decodeToLatLonAlt(
        encoded: UInt64,
        altitudeRange: ClosedRange<Double>
    ) -> (latitude: Double, longitude: Double, altitude: Double) {
        let (s2cell, altitude) = decode(encoded: encoded, altitudeRange: altitudeRange)
        let (lat, lon) = s2cell.toLatLon()
        return (lat, lon, altitude)
    }

    // MARK: - Range Queries

    /// Calculate the encoded range for a 3D bounding box query
    ///
    /// Returns the minimum and maximum encoded values that cover the bounding box.
    /// Note: This is a conservative estimate; false positives must be filtered.
    ///
    /// - Parameters:
    ///   - minLat: Minimum latitude (radians)
    ///   - maxLat: Maximum latitude (radians)
    ///   - minLon: Minimum longitude (radians)
    ///   - maxLon: Maximum longitude (radians)
    ///   - minAlt: Minimum altitude
    ///   - maxAlt: Maximum altitude
    ///   - altitudeRange: Range for altitude normalization
    ///   - level: S2Cell level
    /// - Returns: Tuple of (minEncoded, maxEncoded)
    ///
    /// **Important**: This returns a conservative range. Actual query implementation
    /// should use S2RegionCoverer for lat/lon and filter results by exact altitude.
    public static func boundingBox(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        minAlt: Double, maxAlt: Double,
        altitudeRange: ClosedRange<Double>,
        level: Int = 16
    ) throws -> (min: UInt64, max: UInt64) {
        // Encode corners of the bounding box
        let minEncoded = try encode(
            latitude: minLat,
            longitude: minLon,
            altitude: minAlt,
            altitudeRange: altitudeRange,
            level: level
        )

        let maxEncoded = try encode(
            latitude: maxLat,
            longitude: maxLon,
            altitude: maxAlt,
            altitudeRange: altitudeRange,
            level: level
        )

        return (min: minEncoded, max: maxEncoded)
    }

    // MARK: - Validation

    /// Validate that altitude is within the specified range
    ///
    /// - Parameters:
    ///   - altitude: Altitude value to validate
    ///   - altitudeRange: Valid altitude range
    /// - Returns: `true` if altitude is within range
    public static func isValidAltitude(_ altitude: Double, range: ClosedRange<Double>) -> Bool {
        return altitude >= range.lowerBound && altitude <= range.upperBound
    }

    /// Calculate altitude precision (step size) for a given range
    ///
    /// - Parameter altitudeRange: Altitude range
    /// - Returns: Altitude step size (resolution)
    ///
    /// **Example**:
    /// ```swift
    /// let range = 0.0...10000.0  // 0-10km
    /// let precision = Geo3DEncoding.altitudePrecision(range)
    /// // precision ≈ 0.0006 meters (0.6mm)
    /// ```
    public static func altitudePrecision(_ altitudeRange: ClosedRange<Double>) -> Double {
        let rangeSpan = altitudeRange.upperBound - altitudeRange.lowerBound
        return rangeSpan / Double(maxAltitudeSteps)
    }

    /// Validate S2Cell level for .geo3D encoding
    ///
    /// - Parameter level: S2Cell level to validate
    /// - Returns: `true` if level ≤ 18
    public static func isValidLevel(_ level: Int) -> Bool {
        return level >= 0 && level <= maxSupportedLevel
    }
}

// MARK: - SpatialIndexOptions Extension

extension SpatialIndexOptions {

    /// Default altitude range (0 to 10,000 meters)
    public static let defaultAltitudeRange: ClosedRange<Double> = 0.0...10000.0

    /// Altitude range for aviation (-500 to 15,000 meters)
    public static let aviationAltitudeRange: ClosedRange<Double> = -500.0...15000.0

    /// Altitude range for underwater (-11,000 to 0 meters, Mariana Trench to surface)
    public static let underwaterAltitudeRange: ClosedRange<Double> = -11000.0...0.0

    /// Validate altitude range for .geo3D indexing
    ///
    /// - Returns: `true` if altitudeRange is set and has positive span
    public var hasValidAltitudeRange: Bool {
        guard let range = altitudeRange else { return false }
        return range.upperBound > range.lowerBound
    }
}
