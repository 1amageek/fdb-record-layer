import Foundation

/// S2 Geometry: Hierarchical cell ID on sphere surface using Hilbert curve
///
/// S2CellID represents a cell on the unit sphere using a 64-bit integer:
/// - 3 bits: face ID (0-5) for cube projection
/// - 60 bits: Hilbert curve index on face
/// - 1 bit: LSB (always 1 for valid cells)
///
/// **Levels**:
/// - Level 0: 6 faces (~85M km²)
/// - Level 10: ~1000 km²
/// - Level 17: ~0.36 km² (≈600m cell edge, IndexDefinition default)
/// - Level 20: ~6000 m² (≈76m cell edge, S2CellID default)
/// - Level 30: ~1 cm² (maximum precision)
///
/// **Usage**:
/// ```swift
/// // Create cell from lat/lon
/// let cell = S2CellID(lat: 35.6762, lon: 139.6503, level: 20)
///
/// // Get parent/children
/// let parent = cell.parent(level: 15)
/// let children = cell.children()
///
/// // Get neighbors
/// let neighbors = cell.neighbors()
///
/// // Decode back to lat/lon
/// let (lat, lon) = cell.toLatLon()
/// ```
public struct S2CellID: Sendable, Hashable, Comparable {
    /// Raw 64-bit cell ID
    public let rawValue: UInt64

    // MARK: - Constants

    /// Number of faces on the cube (6 faces)
    private static let numFaces = 6

    /// Maximum level (30)
    public static let maxLevel = 30

    /// Number of position bits (60)
    private static let posBits = 2 * maxLevel

    /// FIXED: Face bits shift (61 bits)
    /// Face requires 3 bits (values 0-5) and must be stored at bits 63-61
    /// to avoid overlap with Hilbert data at bits 60-1
    private static let faceBitsShift = UInt64(posBits + 1)  // 61, not 60

    /// Lookup table for Hilbert curve orientation updates (Google S2 reference)
    /// Maps Hilbert position → orientation XOR mask
    /// Based on kPosToOrientation from s2coords_internal.h
    /// Values: { kSwapMask, 0, 0, kInvertMask + kSwapMask } = { 1, 0, 0, 3 }
    private static let posToOrientation: [Int] = [1, 0, 0, 3]

    /// Maps (orientation, position) → IJ position
    private static let posToIJ: [[Int]] = [
        [0, 1, 3, 2],  // Orientation 0
        [0, 2, 3, 1],  // Orientation 1
        [3, 2, 0, 1],  // Orientation 2
        [3, 1, 0, 2]   // Orientation 3
    ]

    // MARK: - Initialization

    /// Create S2CellID from raw 64-bit value
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Create S2CellID from latitude and longitude
    ///
    /// - Parameters:
    ///   - lat: Latitude in degrees [-90, 90]
    ///   - lon: Longitude in degrees [-180, 180]
    ///   - level: Cell level [0, 30] (default: 20 ≈ 50m)
    public init(lat: Double, lon: Double, level: Int = 20) {
        precondition(lat >= -90 && lat <= 90, "Latitude must be in [-90, 90], got \(lat)")
        precondition(lon >= -180 && lon <= 180, "Longitude must be in [-180, 180], got \(lon)")
        precondition(level >= 0 && level <= S2CellID.maxLevel, "Level must be in [0, 30], got \(level)")

        // Convert to radians
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0

        // Convert to XYZ on unit sphere
        let cosLat = cos(latRad)
        let x = cos(lonRad) * cosLat
        let y = sin(lonRad) * cosLat
        let z = sin(latRad)

        // Determine face and UV coordinates
        let (face, u, v) = S2CellID.xyzToFaceUV(x: x, y: y, z: z)

        // Convert UV to ST (quadratic projection)
        let s = S2CellID.uvToST(u)
        let t = S2CellID.uvToST(v)

        // Convert ST to IJ (integer coordinates)
        let maxSize = 1 << S2CellID.maxLevel
        let si = max(0, min(maxSize - 1, Int((s * Double(maxSize)).rounded(.down))))
        let ti = max(0, min(maxSize - 1, Int((t * Double(maxSize)).rounded(.down))))

        // Encode face + IJ into cell ID using Hilbert curve
        let cellID = S2CellID.encodeFaceIJ(face: face, i: si, j: ti, level: level)
        self.init(rawValue: cellID)
    }

    // MARK: - Properties

    /// Cell level (0-30)
    public var level: Int {
        if rawValue == 0 {
            return 0
        }

        // S2CellID encoding:
        // - LSB (bit 0) is always 1 for valid cells
        // - Bits 1-60 encode position (2 bits per level, 30 levels)
        // - Bits 61-63 encode face ID
        //
        // Level N cell has (30-N)*2 trailing zero bits before the LSB
        // Example: Level 20 has (30-20)*2 = 20 trailing zeros before LSB
        //
        // To find level: count trailing zeros and divide by 2
        let trailingZeros = rawValue.trailingZeroBitCount
        return S2CellID.maxLevel - (trailingZeros / 2)
    }

    /// Face ID (0-5)
    public var face: Int {
        return Int((rawValue >> S2CellID.faceBitsShift) & 0x7)
    }

    /// Is this a leaf cell (level 30)?
    public var isLeaf: Bool {
        return level == S2CellID.maxLevel
    }

    /// Is this a valid cell?
    public var isValid: Bool {
        return face < S2CellID.numFaces && (rawValue & 0x1) != 0
    }

    // MARK: - Coordinate Conversion

    /// Convert cell ID back to (latitude, longitude)
    ///
    /// - Returns: Tuple of (latitude, longitude) in degrees at cell center
    public func toLatLon() -> (lat: Double, lon: Double) {
        // Decode face and IJ
        let (face, i, j) = S2CellID.decodeFaceIJ(rawValue: rawValue)

        // Convert IJ to ST (center of cell)
        let maxSize = 1 << S2CellID.maxLevel
        let cellSize = 1 << (S2CellID.maxLevel - level)
        let s = (Double(i) + Double(cellSize) / 2.0) / Double(maxSize)
        let t = (Double(j) + Double(cellSize) / 2.0) / Double(maxSize)

        // Convert ST to UV
        let u = S2CellID.stToUV(s)
        let v = S2CellID.stToUV(t)

        // Convert UV to XYZ
        let (x, y, z) = S2CellID.faceUVToXYZ(face: face, u: u, v: v)

        // Normalize to unit sphere
        let norm = sqrt(x * x + y * y + z * z)
        let xn = x / norm
        let yn = y / norm
        let zn = z / norm

        // Convert XYZ to lat/lon
        let latRad = atan2(zn, sqrt(xn * xn + yn * yn))
        let lonRad = atan2(yn, xn)

        return (lat: latRad * 180.0 / .pi, lon: lonRad * 180.0 / .pi)
    }

    // MARK: - Hierarchical Operations

    /// Get parent cell at specified level
    ///
    /// - Parameter level: Target level (must be <= current level)
    /// - Returns: Parent cell
    public func parent(level: Int) -> S2CellID {
        precondition(level >= 0 && level <= S2CellID.maxLevel, "Level must be in [0, 30]")
        precondition(level <= self.level, "Parent level must be <= current level (\(self.level))")

        if level == self.level {
            return self
        }

        // Calculate new LSB position
        let newLSB = lsb() << (2 * (self.level - level))

        // Clear lower bits and set new LSB
        return S2CellID(rawValue: (rawValue & ~(newLSB - 1)) | newLSB)
    }

    /// Get all 4 child cells
    ///
    /// - Returns: Array of 4 child cells
    public func children() -> [S2CellID] {
        precondition(!isLeaf, "Leaf cells (level 30) have no children")

        let lsb = lsb()
        let newLSB = lsb >> 2

        // Four children in Hilbert curve order
        return [
            S2CellID(rawValue: rawValue - lsb + newLSB),           // Child 0
            S2CellID(rawValue: rawValue + newLSB),                  // Child 1
            S2CellID(rawValue: rawValue + (lsb >> 1) - newLSB),    // Child 2
            S2CellID(rawValue: rawValue + (lsb >> 1) + newLSB)     // Child 3
        ]
    }

    /// Get child cell at specified position (0-3)
    public func child(position: Int) -> S2CellID {
        precondition(position >= 0 && position < 4, "Child position must be in [0, 3]")
        precondition(!isLeaf, "Leaf cells have no children")

        let lsb = lsb()
        let newLSB = lsb >> 2

        let offsets: [UInt64] = [
            UInt64(bitPattern: -Int64(lsb)) + newLSB,   // Child 0
            newLSB,                                      // Child 1
            (lsb >> 1) - newLSB,                        // Child 2
            (lsb >> 1) + newLSB                         // Child 3
        ]

        return S2CellID(rawValue: rawValue + offsets[position])
    }

    /// Get all edge neighbors (4 cells sharing an edge)
    ///
    /// - Returns: Array of neighboring cells (may be less than 4 at edges)
    public func neighbors() -> [S2CellID] {
        let (face, i, j) = S2CellID.decodeFaceIJ(rawValue: rawValue)
        let cellSize = 1 << (S2CellID.maxLevel - level)

        var result: [S2CellID] = []
        result.reserveCapacity(4)

        // Four edge neighbors: North, South, East, West
        let offsets = [
            (0, cellSize),   // North
            (0, -cellSize),  // South
            (cellSize, 0),   // East
            (-cellSize, 0)   // West
        ]

        let maxCoord = 1 << S2CellID.maxLevel

        for (di, dj) in offsets {
            let ni = i + di
            let nj = j + dj

            // Check if neighbor is on same face
            if ni >= 0 && ni < maxCoord && nj >= 0 && nj < maxCoord {
                let neighborID = S2CellID.encodeFaceIJ(face: face, i: ni, j: nj, level: level)
                result.append(S2CellID(rawValue: neighborID))
            }
            // TODO: Handle cross-face neighbors (complex edge case)
        }

        return result
    }

    /// Alias for neighbors() - get all edge neighbors
    ///
    /// - Returns: Array of neighboring cells sharing an edge
    public func edgeNeighbors() -> [S2CellID] {
        return neighbors()
    }

    /// Check if this cell contains another cell
    ///
    /// A cell contains another if the other is a descendant (same or smaller level)
    /// and within the same Hilbert curve range.
    ///
    /// - Parameter other: The cell to check
    /// - Returns: True if this cell contains the other cell
    public func contains(_ other: S2CellID) -> Bool {
        // Cannot contain a cell at higher level (larger cell)
        if other.level < self.level {
            return false
        }

        // If same level, must be identical
        if other.level == self.level {
            return self.rawValue == other.rawValue
        }

        // Check if other is within this cell's range
        let minRange = rangeMin()
        let maxRange = rangeMax()

        return other.rawValue >= minRange.rawValue && other.rawValue <= maxRange.rawValue
    }

    /// Get the minimum leaf cell (level 30) contained by this cell
    ///
    /// - Returns: The smallest descendant cell at level 30
    public func rangeMin() -> S2CellID {
        // Already at max level
        if level == S2CellID.maxLevel {
            return self
        }

        // Clear all bits below the current level's LSB
        let lsb = lsb()
        return S2CellID(rawValue: rawValue - lsb + 1)
    }

    /// Get the maximum leaf cell (level 30) contained by this cell
    ///
    /// - Returns: The largest descendant cell at level 30
    public func rangeMax() -> S2CellID {
        // Already at max level
        if level == S2CellID.maxLevel {
            return self
        }

        // Set all bits below the current level's LSB
        let lsb = lsb()
        return S2CellID(rawValue: rawValue + lsb - 1)
    }

    // MARK: - Utility

    /// Get least significant bit (LSB) of this cell ID
    private func lsb() -> UInt64 {
        return rawValue & (~rawValue + 1)
    }

    // MARK: - Coordinate Transformations

    /// Convert (x, y, z) to (face, u, v)
    ///
    /// Projects unit sphere point to one of 6 cube faces
    /// Based on Google S2 ValidFaceXYZtoUV (s2coords.h)
    internal static func xyzToFaceUV(x: Double, y: Double, z: Double) -> (face: Int, u: Double, v: Double) {
        let absX = abs(x)
        let absY = abs(y)
        let absZ = abs(z)

        let (face, u, v): (Int, Double, Double)

        // Determine which face based on largest component
        // Google S2 reference formulas:
        // Face 0: u = p[1]/p[0], v = p[2]/p[0]  (p[0] > 0)
        // Face 1: u = -p[0]/p[1], v = p[2]/p[1]  (p[1] > 0)
        // Face 2: u = -p[0]/p[2], v = -p[1]/p[2]  (p[2] > 0)
        // Face 3: u = p[2]/p[0], v = p[1]/p[0]  (p[0] < 0)
        // Face 4: u = p[2]/p[1], v = -p[0]/p[1]  (p[1] < 0)
        // Face 5: u = -p[1]/p[2], v = -p[0]/p[2]  (p[2] < 0)
        if absX >= absY && absX >= absZ {
            // X face
            if x >= 0 {
                face = 0  // +X face
                u = y / x  // p[1]/p[0]
                v = z / x  // p[2]/p[0]
            } else {
                face = 3  // -X face
                u = z / x  // p[2]/p[0]
                v = y / x  // p[1]/p[0]
            }
        } else if absY >= absZ {
            // Y face
            if y >= 0 {
                face = 1  // +Y face
                u = -x / y  // -p[0]/p[1]
                v = z / y  // p[2]/p[1]
            } else {
                face = 4  // -Y face
                u = z / y  // p[2]/p[1]
                v = -x / y  // -p[0]/p[1]
            }
        } else {
            // Z face
            if z >= 0 {
                face = 2  // +Z face
                u = -x / z  // -p[0]/p[2]
                v = -y / z  // -p[1]/p[2]
            } else {
                face = 5  // -Z face
                u = -y / z  // -p[1]/p[2]
                v = -x / z  // -p[0]/p[2]
            }
        }

        return (face, u, v)
    }

    /// Convert (face, u, v) to (x, y, z)
    ///
    /// Projects cube face point back to unit sphere
    /// Inverse of xyzToFaceUV, based on Google S2 reference
    internal static func faceUVToXYZ(face: Int, u: Double, v: Double) -> (x: Double, y: Double, z: Double) {
        // Inverse formulas derived from xyzToFaceUV:
        // Face 0: u = y/x, v = z/x (x>0)  =>  z=vx, y=ux, x=1  =>  (x, y, z) = (1, u, v)
        // Face 1: u = -x/y, v = z/y (y>0)  =>  z=vy, x=-uy, y=1  =>  (x, y, z) = (-u, 1, v)
        // Face 2: u = -x/z, v = -y/z (z>0)  =>  x=-uz, y=-vz, z=1  =>  (x, y, z) = (-u, -v, 1)
        // Face 3: u = z/x, v = y/x (x<0)  =>  z=ux, y=vx, x=-1  =>  (x, y, z) = (-1, -v, -u)
        // Face 4: u = z/y, v = -x/y (y<0)  =>  z=uy, x=-vy, y=-1  =>  (x, y, z) = (v, -1, -u)
        // Face 5: u = -y/z, v = -x/z (z<0)  =>  y=-uz, x=-vz, z=-1  =>  (x, y, z) = (v, u, -1)
        switch face {
        case 0: return (1.0, u, v)       // +X: u=y/x, v=z/x
        case 1: return (-u, 1.0, v)      // +Y: u=-x/y, v=z/y
        case 2: return (-u, -v, 1.0)     // +Z: u=-x/z, v=-y/z
        case 3: return (-1.0, -v, -u)    // -X: u=z/x, v=y/x
        case 4: return (v, -1.0, -u)     // -Y: u=z/y, v=-x/y (FIXED: x=v, not -v)
        case 5: return (v, u, -1.0)      // -Z: u=-y/z, v=-x/z (FIXED: y=u, not -u)
        default: fatalError("Invalid face: \(face)")
        }
    }

    /// Convert U/V coordinate to S/T using quadratic projection
    ///
    /// This projection provides better area uniformity than linear projection
    internal static func uvToST(_ uv: Double) -> Double {
        if uv >= 0 {
            return 0.5 * sqrt(1.0 + 3.0 * uv)
        } else {
            return 1.0 - 0.5 * sqrt(1.0 - 3.0 * uv)
        }
    }

    /// Convert S/T coordinate to U/V using inverse quadratic projection
    internal static func stToUV(_ st: Double) -> Double {
        if st >= 0.5 {
            return (1.0 / 3.0) * (4.0 * st * st - 1.0)
        } else {
            return (1.0 / 3.0) * (1.0 - 4.0 * (1.0 - st) * (1.0 - st))
        }
    }

    /// Encode (face, i, j, level) into 64-bit cell ID using Hilbert curve
    private static func encodeFaceIJ(face: Int, i: Int, j: Int, level: Int) -> UInt64 {
        // Interleave i and j bits using Hilbert curve
        var bits: UInt64 = 0
        // Initialize orientation from face's lowest bit (swap orientation for odd faces)
        var orientation = face & 1

        // Process from high bits to low bits (level-1 down to 0)
        for k in 0..<level {
            let shift = maxLevel - 1 - k  // Bit position in i/j coordinates

            // Extract single bit from i and j at this position
            let iBit = (i >> shift) & 1
            let jBit = (j >> shift) & 1

            // Combine into 2-bit IJ position
            let ijPos = (iBit << 1) | jBit

            // Convert IJ position to Hilbert position (reverse lookup)
            // posToIJ maps Hilbert → IJ, so we need to find index
            let hilbertPos = posToIJ[orientation].firstIndex(of: ijPos) ?? 0
            bits = (bits << 2) | UInt64(hilbertPos)

            // Update orientation for next level (FIXED: use hilbertPos, not ijPos)
            orientation ^= posToOrientation[hilbertPos]
        }

        // FIXED: Shift to position Hilbert bits above LSB position
        // For level N, we have N*2 Hilbert bits
        // LSB will be at position 2*(30-N), so Hilbert bits go to positions 60-[2*(30-N)+1]
        // Shift left by 2*(30-N) + 1 to make room
        bits <<= (2 * (maxLevel - level) + 1)

        // Add LSB at correct position: bit 2*(30-level)
        // This ensures: Hilbert bits at 60-[2*(30-N)+1], LSB at 2*(30-N), zeros at [2*(30-N)-1]-0
        bits |= UInt64(1) << (2 * (maxLevel - level))

        // Combine face + bits
        let faceBits = UInt64(face) << faceBitsShift
        return faceBits | bits
    }

    /// Decode 64-bit cell ID into (face, i, j)
    private static func decodeFaceIJ(rawValue: UInt64) -> (face: Int, i: Int, j: Int) {
        let face = Int((rawValue >> faceBitsShift) & 0x7)

        var i = 0
        var j = 0
        // Initialize orientation from face's lowest bit (swap orientation for odd faces)
        var orientation = face & 1

        let level = S2CellID(rawValue: rawValue).level

        // Extract bits in reverse Hilbert order
        // FIXED: Account for LSB offset at bit 0
        for k in 0..<level {
            let shift = 2 * (maxLevel - 1 - k) + 1  // Add 1 for LSB offset
            let hilbertPos = Int((rawValue >> UInt64(shift)) & 3)

            // Convert Hilbert position to IJ position (direct lookup)
            // posToIJ maps Hilbert → IJ
            let ijPos = posToIJ[orientation][hilbertPos]

            let iBit = (ijPos >> 1) & 1
            let jBit = ijPos & 1

            i = (i << 1) | iBit
            j = (j << 1) | jBit

            // Update orientation (FIXED: use hilbertPos, not ijPos)
            orientation ^= posToOrientation[hilbertPos]
        }

        // Shift to maxLevel coordinates
        let shift = maxLevel - level
        i <<= shift
        j <<= shift

        return (face, i, j)
    }

    // MARK: - Comparable

    public static func < (lhs: S2CellID, rhs: S2CellID) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        if !isValid {
            return "S2CellID(invalid)"
        }

        let (lat, lon) = toLatLon()
        return String(format: "S2CellID(face: %d, level: %d, lat: %.6f, lon: %.6f)", face, level, lat, lon)
    }
}

// MARK: - Constants

extension S2CellID {
    /// Sentinel value representing an invalid cell
    public static let none = S2CellID(rawValue: 0)

    /// Face cells (level 0)
    /// FIXED: Use faceBitsShift (61) instead of posBits (60)
    public static let faceCells: [S2CellID] = (0..<6).map { face in
        S2CellID(rawValue: (UInt64(face) << faceBitsShift) | 1)
    }
}

// MARK: - Utility Functions

extension S2CellID {
    /// Calculate Haversine distance between two lat/lon points
    ///
    /// - Returns: Distance in meters
    public static func haversineDistance(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let R = 6371000.0  // Earth radius in meters

        // Convert to radians
        let lat1Rad = lat1 * .pi / 180.0
        let lat2Rad = lat2 * .pi / 180.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0

        // Haversine formula
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1Rad) * cos(lat2Rad) *
                sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return R * c
    }
}
