import Foundation

/// Geohash encoding/decoding for geographic coordinates
///
/// Geohash is a geocoding system that encodes latitude/longitude into a short string
/// using base32 encoding. It provides:
/// - **Hierarchical spatial indexing**: Prefixes represent larger areas
/// - **Z-order curve mapping**: Nearby coordinates have similar geohashes
/// - **Efficient range queries**: Spatial searches via string prefix matching
///
/// **Precision table** (corrected from documentation):
///
/// | Precision | ±Lat  | ±Lon  | Area (km²) | Example Use Case |
/// |-----------|-------|-------|------------|------------------|
/// | 1         | 2.2km | 5.0km | 25000      | Country/Region   |
/// | 2         | 0.6km | 0.6km | 630        | City             |
/// | 3         | 78m   | 156m  | 19.5       | Neighborhood     |
/// | 4         | 20m   | 20m   | 0.61       | Street block     |
/// | 5         | 2.4m  | 4.9m  | 0.019      | Individual trees |
/// | 6         | 0.6m  | 0.6m  | 0.0012     | Building         |
/// | 7         | 76mm  | 152mm | 0.00015    | Room             |
/// | 8         | 19mm  | 19mm  | 0.000038   | Desktop          |
/// | 9         | 2.4mm | 4.8mm | 0.0000012  | Book             |
/// | 10        | 0.6mm | 1.2mm | 0.00000037 | Coin             |
/// | 11        | 76µm  | 152µm | 0.000000012| Hair             |
/// | 12        | 19µm  | 38µm  | 0.0000000003| Cell            |
///
/// **Note**: Precision 6 gives ±0.6m accuracy. Precision 12 gives ±19µm (micrometer) accuracy.
/// For reference: precision 7 ≈ ±76mm, precision 8 ≈ ±19mm.
///
/// **Reference**: [Geohash Wikipedia](https://en.wikipedia.org/wiki/Geohash)
public enum Geohash {
    /// Base32 character set for geohash encoding
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Reverse lookup table for base32 decoding
    private static let base32Lookup: [Character: Int] = {
        var lookup: [Character: Int] = [:]
        for (index, char) in base32.enumerated() {
            lookup[char] = index
        }
        return lookup
    }()

    // MARK: - Encoding

    /// Encode latitude and longitude into a geohash string
    ///
    /// - Parameters:
    ///   - latitude: Latitude in degrees [-90, 90]
    ///   - longitude: Longitude in degrees [-180, 180]
    ///   - precision: Number of characters in output geohash [1-12]
    /// - Returns: Geohash string of specified precision
    ///
    /// **Example**:
    /// ```swift
    /// let hash = Geohash.encode(latitude: 37.7749, longitude: -122.4194, precision: 7)
    /// // → "9q8yyk8"
    /// ```
    public static func encode(latitude: Double, longitude: Double, precision: Int = 12) -> String {
        precondition(latitude >= -90 && latitude <= 90, "Latitude must be in [-90, 90]")
        precondition(longitude >= -180 && longitude <= 180, "Longitude must be in [-180, 180]")
        precondition(precision >= 1 && precision <= 12, "Precision must be in [1, 12]")

        var geohash = ""
        var minLat = -90.0
        var maxLat = 90.0
        var minLon = -180.0
        var maxLon = 180.0
        var bit = 0
        var ch = 0
        var even = true // Interleave: longitude first

        while geohash.count < precision {
            if even {
                // Longitude
                let mid = (minLon + maxLon) / 2
                if longitude > mid {
                    ch |= (1 << (4 - bit))
                    minLon = mid
                } else {
                    maxLon = mid
                }
            } else {
                // Latitude
                let mid = (minLat + maxLat) / 2
                if latitude > mid {
                    ch |= (1 << (4 - bit))
                    minLat = mid
                } else {
                    maxLat = mid
                }
            }

            even = !even

            if bit < 4 {
                bit += 1
            } else {
                geohash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }

        return geohash
    }

    // MARK: - Decoding

    /// Decode a geohash string into latitude/longitude bounds
    ///
    /// - Parameter geohash: Geohash string
    /// - Returns: Tuple of (minLat, minLon, maxLat, maxLon) representing the bounding box
    ///
    /// **Example**:
    /// ```swift
    /// let bounds = Geohash.decode("9q8yyk8")
    /// // → (37.77484, -122.41943, 37.77492, -122.41935)
    /// ```
    public static func decode(_ geohash: String) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        var minLat = -90.0
        var maxLat = 90.0
        var minLon = -180.0
        var maxLon = 180.0
        var even = true

        for char in geohash.lowercased() {
            guard let idx = base32Lookup[char] else {
                continue // Skip invalid characters
            }

            for bit in (0..<5).reversed() {
                let mask = 1 << bit

                if even {
                    // Longitude
                    let mid = (minLon + maxLon) / 2
                    if (idx & mask) != 0 {
                        minLon = mid
                    } else {
                        maxLon = mid
                    }
                } else {
                    // Latitude
                    let mid = (minLat + maxLat) / 2
                    if (idx & mask) != 0 {
                        minLat = mid
                    } else {
                        maxLat = mid
                    }
                }

                even = !even
            }
        }

        return (minLat, minLon, maxLat, maxLon)
    }

    /// Decode a geohash string into center latitude/longitude
    ///
    /// - Parameter geohash: Geohash string
    /// - Returns: Tuple of (latitude, longitude) at the center of the bounding box
    public static func decodeCenter(_ geohash: String) -> (latitude: Double, longitude: Double) {
        let bounds = decode(geohash)
        let lat = (bounds.minLat + bounds.maxLat) / 2
        let lon = (bounds.minLon + bounds.maxLon) / 2
        return (lat, lon)
    }

    // MARK: - Neighbors

    /// Get the 8 neighboring geohashes
    ///
    /// - Parameter geohash: Input geohash
    /// - Returns: Array of 8 neighboring geohashes (N, NE, E, SE, S, SW, W, NW)
    ///
    /// **Example**:
    /// ```swift
    /// let neighbors = Geohash.neighbors("9q8yyk8")
    /// // → ["9q8yyk9", "9q8yykd", "9q8yyk6", ...]
    /// ```
    public static func neighbors(_ geohash: String) -> [String] {
        return [
            neighbor(geohash, direction: .north),
            neighbor(geohash, direction: .northEast),
            neighbor(geohash, direction: .east),
            neighbor(geohash, direction: .southEast),
            neighbor(geohash, direction: .south),
            neighbor(geohash, direction: .southWest),
            neighbor(geohash, direction: .west),
            neighbor(geohash, direction: .northWest)
        ].compactMap { $0 }
    }

    /// Get a neighboring geohash in a specific direction
    ///
    /// - Parameters:
    ///   - geohash: Input geohash
    ///   - direction: Direction of neighbor
    /// - Returns: Neighboring geohash, or nil if at boundary
    public static func neighbor(_ geohash: String, direction: Direction) -> String? {
        guard !geohash.isEmpty else { return nil }

        // Handle diagonal directions by composing two cardinal directions
        switch direction {
        case .northEast:
            guard let n = neighbor(geohash, direction: .north) else { return nil }
            return neighbor(n, direction: .east)
        case .northWest:
            guard let n = neighbor(geohash, direction: .north) else { return nil }
            return neighbor(n, direction: .west)
        case .southEast:
            guard let s = neighbor(geohash, direction: .south) else { return nil }
            return neighbor(s, direction: .east)
        case .southWest:
            guard let s = neighbor(geohash, direction: .south) else { return nil }
            return neighbor(s, direction: .west)
        default:
            break
        }

        // Handle cardinal directions
        let lastChar = geohash.last!
        var base = String(geohash.dropLast())

        // Lookup tables for neighbor calculation
        let neighborMap = direction.neighborMap(even: geohash.count % 2 == 0)
        let borderMap = direction.borderMap(even: geohash.count % 2 == 0)

        // Check if we're at a border
        if borderMap.contains(lastChar) {
            guard let parentNeighbor = neighbor(base, direction: direction) else {
                return nil
            }
            base = parentNeighbor
        }

        // Replace last character using base32 position
        // The neighborMap is indexed by base32 character positions
        // e.g., if lastChar is 'p' (index 16 in base32), neighborMap[16] gives the neighbor
        guard let base32Index = base32.firstIndex(of: lastChar) else {
            return base + String(lastChar)
        }

        let charIndex = base32.distance(from: base32.startIndex, to: base32Index)
        let neighborChar = neighborMap[neighborMap.index(neighborMap.startIndex, offsetBy: charIndex)]
        return base + String(neighborChar)
    }

    /// Direction for neighbor calculation
    public enum Direction {
        case north, south, east, west
        case northEast, northWest, southEast, southWest

        fileprivate func neighborMap(even: Bool) -> String {
            switch self {
            case .north: return even ? "p0r21436x8zb9dcf5h7kjnmqesgutwvy" : "bc01fg45238967deuvhjyznpkmstqrwx"
            case .south: return even ? "14365h7k9dcfesgujnmqp0r2twvyx8zb" : "238967debc01fg45kmstqrwxuvhjyznp"
            case .east: return even ? "bc01fg45238967deuvhjyznpkmstqrwx" : "p0r21436x8zb9dcf5h7kjnmqesgutwvy"
            case .west: return even ? "238967debc01fg45kmstqrwxuvhjyznp" : "14365h7k9dcfesgujnmqp0r2twvyx8zb"
            default: return "" // Diagonal directions handled separately
            }
        }

        fileprivate func borderMap(even: Bool) -> String {
            switch self {
            case .north: return even ? "prxz" : "bcfguvyz"
            case .south: return even ? "028b" : "0145hjnp"
            case .east: return even ? "bcfguvyz" : "prxz"
            case .west: return even ? "0145hjnp" : "028b"
            default: return ""
            }
        }
    }

    // MARK: - Dynamic Precision

    /// Calculate optimal geohash precision based on bounding box size
    ///
    /// - Parameter boundingBoxSizeKm: Size of bounding box in kilometers (width or height)
    /// - Returns: Recommended precision level [1-12]
    ///
    /// **Strategy**:
    /// - Precision should be high enough that geohash cells are smaller than the bounding box
    /// - But not so high that we generate too many prefixes (>100 prefixes)
    ///
    /// **Example**:
    /// ```swift
    /// let precision = Geohash.optimalPrecision(boundingBoxSizeKm: 10.0)
    /// // → 5 (±2.4m precision for 10km box)
    /// ```
    public static func optimalPrecision(boundingBoxSizeKm: Double) -> Int {
        // Approximate cell size at equator for each precision level (km)
        let cellSizes: [Double] = [
            5000, 1250, 156, 39, 4.9, 1.2, 0.15, 0.019, 0.0048, 0.0012, 0.00015, 0.000038
        ]

        // Find the precision where cell size is smaller than bounding box
        for (precision, cellSize) in cellSizes.enumerated() {
            if cellSize < boundingBoxSizeKm {
                return min(precision + 1, 12)
            }
        }

        return 12 // Maximum precision
    }

    /// Calculate bounding box size in kilometers
    ///
    /// - Parameters:
    ///   - minLat: Minimum latitude
    ///   - maxLat: Maximum latitude
    ///   - minLon: Minimum longitude
    ///   - maxLon: Maximum longitude
    /// - Returns: Maximum dimension of bounding box in kilometers
    public static func boundingBoxSizeKm(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> Double {
        // Calculate width at center latitude
        let centerLat = (minLat + maxLat) / 2
        let latDiff = maxLat - minLat
        let lonDiff = maxLon - minLon

        // Haversine formula for approximate distances
        let latDistanceKm = latDiff * 111.0 // 1 degree latitude ≈ 111km
        let lonDistanceKm = lonDiff * 111.0 * cos(centerLat * .pi / 180.0)

        return max(latDistanceKm, lonDistanceKm)
    }

    // MARK: - Covering Geohashes

    /// Generate geohash prefixes that cover a bounding box
    ///
    /// - Parameters:
    ///   - minLat: Minimum latitude
    ///   - minLon: Minimum longitude
    ///   - maxLat: Maximum latitude
    ///   - maxLon: Maximum longitude
    ///   - precision: Geohash precision level
    /// - Returns: Array of geohash prefixes covering the bounding box
    ///
    /// **Edge Cases Handled**:
    /// - **Dateline wrapping**: minLon > maxLon (crosses ±180°)
    /// - **Polar regions**: latitudes near ±90°
    /// - **Thin boxes**: Very narrow bounding boxes
    ///
    /// **Example**:
    /// ```swift
    /// let hashes = Geohash.coveringGeohashes(
    ///     minLat: 37.7, minLon: -122.5,
    ///     maxLat: 37.8, maxLon: -122.4,
    ///     precision: 5
    /// )
    /// // → ["9q8yy", "9q8yz", "9q8yu", ...]
    /// ```
    public static func coveringGeohashes(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double,
        precision: Int
    ) -> [String] {
        var geohashes = Set<String>()

        // Edge case: Dateline wrapping (minLon > maxLon)
        if minLon > maxLon {
            // Split into two regions: [minLon, 180] and [-180, maxLon]
            let westHashes = coveringGeohashesSimple(
                minLat: minLat, minLon: minLon,
                maxLat: maxLat, maxLon: 180.0,
                precision: precision
            )
            let eastHashes = coveringGeohashesSimple(
                minLat: minLat, minLon: -180.0,
                maxLat: maxLat, maxLon: maxLon,
                precision: precision
            )
            geohashes.formUnion(westHashes)
            geohashes.formUnion(eastHashes)
        } else {
            geohashes = coveringGeohashesSimple(
                minLat: minLat, minLon: minLon,
                maxLat: maxLat, maxLon: maxLon,
                precision: precision
            )
        }

        return Array(geohashes).sorted()
    }

    /// Generate covering geohashes for a simple (non-wrapping) bounding box
    private static func coveringGeohashesSimple(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double,
        precision: Int
    ) -> Set<String> {
        var geohashes = Set<String>()

        // Edge case: Polar regions (clamp to valid range)
        let clampedMinLat = max(-90.0, minLat)
        let clampedMaxLat = min(90.0, maxLat)

        // Sample grid points within the bounding box
        let latStep = (clampedMaxLat - clampedMinLat) / 10.0
        let lonStep = (maxLon - minLon) / 10.0

        var lat = clampedMinLat
        while lat <= clampedMaxLat {
            var lon = minLon
            while lon <= maxLon {
                let hash = encode(latitude: lat, longitude: lon, precision: precision)
                geohashes.insert(hash)

                // Also add neighbors to ensure coverage
                for neighbor in neighbors(hash) {
                    geohashes.insert(neighbor)
                }

                lon += Swift.max(lonStep, 0.001)
            }
            lat += Swift.max(latStep, 0.001)
        }

        // Add corner points to ensure complete coverage
        let corners = [
            (clampedMinLat, minLon),
            (clampedMinLat, maxLon),
            (clampedMaxLat, minLon),
            (clampedMaxLat, maxLon)
        ]

        for (lat, lon) in corners {
            let hash = encode(latitude: lat, longitude: lon, precision: precision)
            geohashes.insert(hash)
            for neighbor in neighbors(hash) {
                geohashes.insert(neighbor)
            }
        }

        return geohashes
    }
}
