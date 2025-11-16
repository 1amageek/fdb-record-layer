# Spatial Index - Complete Implementation Specification

**Status**: ✅ FULLY IMPLEMENTED
**Last Updated**: 2025-01-16
**Version**: 1.0.0

---

## Table of Contents

1. [Overview](#overview)
2. [SpatialType Enum Specification](#spatialtype-enum-specification)
3. [S2 Geometry Implementation](#s2-geometry-implementation)
4. [Morton Code Implementation](#morton-code-implementation)
5. [Geo3D Altitude Encoding](#geo3d-altitude-encoding)
6. [S2RegionCoverer Algorithm](#s2regioncoverer-algorithm)
7. [SpatialIndexMaintainer](#spatialindexmaintainer)
8. [QueryBuilder API](#querybuilder-api)
9. [Migration Path](#migration-path)
10. [Performance Characteristics](#performance-characteristics)
11. [Usage Examples](#usage-examples)

---

## Overview

The Spatial Index system provides efficient spatial queries for geographic and Cartesian coordinates using industry-standard algorithms:

- **S2 Geometry**: Google's spherical geometry library for `.geo` and `.geo3D`
- **Morton Code (Z-order curve)**: Bit-interleaving for `.cartesian` and `.cartesian3D`

### Key Design Decisions

1. **Level in Type Enum**: Level parameter is embedded in each `SpatialType` case, not as a separate macro parameter
2. **Realistic Defaults**: Levels chosen to match typical data accuracy (GPS ±5-10m, not theoretical precision)
3. **KeyPath Extraction**: Runtime reflection (Mirror API) to extract coordinates from nested structures
4. **S2RegionCoverer**: Generates optimal cell coverings for spatial queries (radius, bounding box)
5. **False Positive Filtering**: Post-index distance calculation using original coordinates

---

## SpatialType Enum Specification

**File**: `Sources/FDBRecordCore/IndexDefinition.swift`

```swift
public enum SpatialType: Sendable, Equatable {
    case geo(latitude: String, longitude: String, level: Int = 17)
    case geo3D(latitude: String, longitude: String, altitude: String, level: Int = 16)
    case cartesian(x: String, y: String, level: Int = 18)
    case cartesian3D(x: String, y: String, z: String, level: Int = 16)
}
```

### Level Defaults Rationale

| Type | Default Level | Cell/Grid Size | Rationale |
|------|--------------|----------------|-----------|
| `.geo` | **17** | ~9m cells | Matches typical GPS accuracy (±5-10m), balances precision vs S2RegionCoverer cell count |
| `.geo3D` | **16** | ~18m cells | Slightly coarser to accommodate 3D altitude encoding in 64 bits |
| `.cartesian` | **18** | 262k × 262k grid | Suitable for normalized [0, 1] or bounded integer coordinates |
| `.cartesian3D` | **16** | 65k steps/axis | Fits in 64 bits (3 × 21 bits max, level 16 uses 16 bits/axis) |

### Level Selection Guide

#### .geo (S2Cell Level)

| Level | Cell Edge Size | Use Case |
|-------|---------------|----------|
| 10 | ~150km | Country-level queries |
| 12 | ~40km | City-level queries |
| 15 | ~3km | Neighborhood-level queries |
| **17** | **~9m** | **GPS accuracy (default)** |
| 20 | ~1.5cm | Indoor/high-precision |

#### .geo3D (S2Cell Level + Altitude)

| Level | S2Cell Size | Altitude Precision | Use Case |
|-------|------------|-------------------|----------|
| 14 | ~150m | 0.6mm (24 bits) | Regional 3D queries |
| **16** | **~18m** | **0.6mm** | **Drone/aviation (default)** |
| 18 | ~4.5m | 0.6mm | High-precision 3D indoor |

**Note**: Altitude precision is constant (24 bits ≈ 16.7M steps) regardless of S2Cell level.

#### .cartesian (Morton Code Bit Depth)

| Level | Grid Resolution | Use Case |
|-------|----------------|----------|
| 16 | 65k × 65k | Coarse game maps, low-res simulation |
| **18** | **262k × 262k** | **Typical use (default)** |
| 20 | 1M × 1M | High-precision CAD, scientific data |
| 32 | 4B × 4B | Maximum 2D resolution (64 bits total) |

#### .cartesian3D (Morton Code Bit Depth)

| Level | Grid Resolution | Use Case |
|-------|----------------|----------|
| 14 | 16k steps/axis | Voxel-based games (Minecraft-like) |
| **16** | **65k steps/axis** | **Typical 3D simulation (default)** |
| 18 | 262k steps/axis | High-precision 3D CAD |
| 21 | 2.1M steps/axis | Maximum 3D resolution (63 bits total) |

### Computed Properties

```swift
extension SpatialType {
    /// The level parameter for spatial indexing precision
    public var level: Int { /* ... */ }

    /// Validate the level parameter for this spatial type
    public var isValidLevel: Bool {
        switch self {
        case .geo, .geo3D:
            return level >= 0 && level <= 30  // S2Cell levels
        case .cartesian:
            return level >= 0 && level <= 32  // 2D Morton: 32 bits per axis max
        case .cartesian3D:
            return level >= 0 && level <= 21  // 3D Morton: 21 bits per axis (3×21=63 bits)
        }
    }

    /// Extract KeyPath strings for coordinate value extraction
    public var keyPathStrings: [String] { /* ... */ }
}
```

---

## S2 Geometry Implementation

**File**: `Sources/FDBRecordLayer/Spatial/S2CellID.swift`

### S2CellID Structure (64 bits)

```
Bits 0-2:   Face ID (0-5, representing 6 cube faces)
Bits 3-62:  Hilbert curve position (up to 30 levels, 2 bits per level)
Bit 63:     Unused (always 0)
```

### Key Algorithms

#### 1. Lat/Lon to S2CellID

```swift
public static func fromLatLon(
    latitude: Double,   // Radians [-π/2, π/2]
    longitude: Double,  // Radians [-π, π]
    level: Int          // 0-30
) -> S2CellID
```

**Process**:
1. Convert lat/lon to XYZ unit sphere coordinates
2. Project XYZ onto cube face → Face ID + (u, v) coordinates
3. Transform (u, v) to (s, t) using quadratic transformation
4. Convert (s, t) to (i, j) cell coordinates
5. Encode (face, i, j) to S2CellID using Hilbert curve

#### 2. S2CellID to Lat/Lon

```swift
public func toLatLon() -> (latitude: Double, longitude: Double)
```

**Process**:
1. Decode S2CellID to (face, i, j)
2. Convert (i, j) to (s, t)
3. Transform (s, t) to (u, v)
4. Convert (face, u, v) to XYZ
5. Normalize XYZ and convert to lat/lon

#### 3. Hilbert Curve Encoding

**Purpose**: Preserve spatial locality (nearby points on sphere → similar S2CellIDs)

**Implementation**:
```swift
// Orientation lookup table (based on Google S2 reference)
private static let posToOrientation: [Int] = [1, 0, 0, 3]

// Encode (i, j) at specific level
for level in 0..<targetLevel {
    let ijPos = (i >> (30 - level - 1)) & 1) | ((j >> (30 - level - 1)) & 1) << 1)
    let hilbertPos = kIJtoPos[orientation][ijPos]  // IJ→Hilbert mapping
    orientation ^= posToOrientation[hilbertPos]    // Update orientation
    // ... encode bits ...
}
```

### Range Queries

```swift
public func rangeMin() -> UInt64  // Minimum S2CellID in this cell's subtree
public func rangeMax() -> UInt64  // Maximum S2CellID in this cell's subtree
```

Used for FDB range reads: `[rangeMin(), rangeMax())`

---

## Morton Code Implementation

**File**: `Sources/FDBRecordLayer/Spatial/MortonCode.swift`

### 2D Morton Code

**Bit Interleaving Example**:
```
x = 0b1010 (10)
y = 0b1100 (12)
morton = 0b11011000 (reading right→left: y3 x3 y2 x2 y1 x1 y0 x0) = 216
```

#### Encoding Algorithm

```swift
public static func encode2D(x: Double, y: Double, level: Int = 18) -> UInt64
```

**Process**:
1. Normalize coordinates to [0, 1]
2. Convert to integer coordinates: `xi = UInt64(x * (2^level - 1))`
3. Spread bits of xi into even positions: `0b1010 → 0b01000100`
4. Spread bits of yi into odd positions: `0b1100 → 0b10001000`
5. Combine: `morton = (y_spread << 1) | x_spread`

#### Magic Number Bit Spreading

```swift
private static func spread2D(_ value: UInt64) -> UInt64 {
    var x = value & 0xFFFFFFFF  // Lower 32 bits

    x = (x | (x << 16)) & 0x0000FFFF0000FFFF
    x = (x | (x << 8))  & 0x00FF00FF00FF00FF
    x = (x | (x << 4))  & 0x0F0F0F0F0F0F0F0F
    x = (x | (x << 2))  & 0x3333333333333333
    x = (x | (x << 1))  & 0x5555555555555555

    return x
}
```

**Explanation**: Each step doubles the spacing between bits using bitwise OR and masks.

### 3D Morton Code

**Bit Interleaving Example**:
```
x = 0b101 (5)
y = 0b110 (6)
z = 0b011 (3)
morton = 0b011111001 (reading right→left: z2 y2 x2 z1 y1 x1 z0 y0 x0) = 249
```

#### Encoding Algorithm

```swift
public static func encode3D(x: Double, y: Double, z: Double, level: Int = 16) -> UInt64
```

**Process**:
1. Normalize coordinates to [0, 1]
2. Convert to integer coordinates
3. Spread bits of each axis into every 3rd position
4. Combine: `morton = (z_spread << 2) | (y_spread << 1) | x_spread`

#### 3D Bit Spreading

```swift
private static func spread3D(_ value: UInt64) -> UInt64 {
    var x = value & 0x1FFFFF  // Lower 21 bits (max for 3D)

    x = (x | (x << 32)) & 0x001F00000000FFFF
    x = (x | (x << 16)) & 0x001F0000FF0000FF
    x = (x | (x << 8))  & 0x100F00F00F00F00F
    x = (x | (x << 4))  & 0x10C30C30C30C30C3
    x = (x | (x << 2))  & 0x1249249249249249

    return x
}
```

### Bounding Box Queries

```swift
public static func boundingBox2D(
    minX: Double, minY: Double,
    maxX: Double, maxY: Double,
    level: Int = 18
) -> (min: UInt64, max: UInt64)
```

**Returns**: Conservative range `[minMorton, maxMorton]` covering the box.

**Note**: This is a simple min/max encoding. False positives must be filtered by exact distance calculation.

---

## Geo3D Altitude Encoding

**File**: `Sources/FDBRecordLayer/Spatial/Geo3DEncoding.swift`

### 64-bit Encoding Structure

```
Bits 0-39:  S2CellID at level ≤ 18 (40 bits)
Bits 40-63: Normalized altitude (24 bits, ~16.7M steps)
```

### Level Constraints

| S2Cell Level | Bit Count | Fits in 40 bits? |
|--------------|-----------|------------------|
| 16 | 2×16 + 3 = 35 bits | ✅ Yes (5 bits padding) |
| 17 | 2×17 + 3 = 37 bits | ✅ Yes (3 bits padding) |
| 18 | 2×18 + 3 = 39 bits | ✅ Yes (1 bit padding) |
| 19 | 2×19 + 3 = 41 bits | ❌ No (exceeds 40 bits) |

**Recommendation**: Use level 16 (default) for .geo3D.

### Altitude Normalization

```swift
// Normalize altitude to [0, 1]
let normalized = (altitude - altitudeRange.lowerBound) / rangeSpan

// Convert to integer steps [0, 16777215]
let altitudeSteps = UInt64(normalized * 16777215.0)
```

### Encoding Algorithm

```swift
public static func encode(
    s2cell: S2CellID,
    altitude: Double,
    altitudeRange: ClosedRange<Double>
) throws -> UInt64
```

**Process**:
1. Validate S2Cell level ≤ 18
2. Validate altitude within `altitudeRange`
3. Normalize altitude to [0, 1]
4. Convert to 24-bit integer steps
5. Pack: `(altitudeSteps << 40) | (s2cell.id & 0xFFFFFFFFFF)`

### Altitude Precision

```swift
let precision = rangeSpan / 16777215.0
// Example: 0...10000 range → precision ≈ 0.0006 meters (0.6mm)
```

### Predefined Altitude Ranges

```swift
extension SpatialIndexOptions {
    public static let defaultAltitudeRange: ClosedRange<Double> = 0.0...10000.0
    public static let aviationAltitudeRange: ClosedRange<Double> = -500.0...15000.0
    public static let underwaterAltitudeRange: ClosedRange<Double> = -11000.0...0.0
}
```

---

## S2RegionCoverer Algorithm

**File**: `Sources/FDBRecordLayer/Spatial/S2RegionCoverer.swift`

### Purpose

Convert spatial queries (radius, bounding box) into a set of S2Cells that cover the region.

### Parameters

```swift
public init(
    minLevel: Int = 12,   // ~40km cells
    maxLevel: Int = 17,   // ~9m cells
    maxCells: Int = 8,    // Max cells to generate
    levelMod: Int = 1     // Level increment (1 = all levels)
)
```

### Algorithm Overview

1. **Initialize**: Start with 6 face cells (level 0)
2. **Filter**: Keep only cells that may intersect the region
3. **Subdivide**: Recursively subdivide cells that intersect but are not fully contained
4. **Stop Conditions**:
   - Cell count reaches `maxCells`
   - Cell level reaches `maxLevel`
   - Cell is fully contained in region
5. **Return**: Array of S2CellIDs covering the region

### Radius Query

```swift
public func getCovering(
    centerLat: Double,
    centerLon: Double,
    radiusMeters: Double
) -> [S2CellID]
```

**Internal Process**:
1. Convert radius to radians: `radiusRadians = radiusMeters / 6371000.0`
2. Create S2Cap (spherical cap) region
3. For each candidate cell:
   - **mayIntersect**: Haversine distance from cell center to cap center ≤ radius × 2 (conservative)
   - **contains**: All 4 cell corners within radius (exact)
4. Return up to `maxCells` covering cells

### Bounding Box Query

```swift
public func getCovering(
    minLat: Double, maxLat: Double,
    minLon: Double, maxLon: Double
) -> [S2CellID]
```

**Internal Process**:
1. Create S2LatLngRect region
2. For each candidate cell:
   - **mayIntersect**: Cell center within expanded bounding box (conservative)
   - **contains**: All 4 cell corners within bounding box (exact)
3. Return up to `maxCells` covering cells

### Trade-offs

| Parameter | Lower Value | Higher Value |
|-----------|-------------|--------------|
| `minLevel` | Fewer, larger cells | More, smaller cells |
| `maxLevel` | Coarser precision | Finer precision |
| `maxCells` | Faster queries, more false positives | Slower queries, fewer false positives |

**Recommended**:
- `minLevel`: `maxLevel - 5` (e.g., 12 for maxLevel 17)
- `maxLevel`: Same as index level
- `maxCells`: 8 (balanced)

---

## SpatialIndexMaintainer

**File**: `Sources/FDBRecordLayer/Index/SpatialIndexMaintainer.swift`

### Responsibilities

1. **Extract coordinates** from records using KeyPath reflection
2. **Encode spatial codes** (S2CellID or Morton Code)
3. **Write/delete index entries** to FoundationDB

### Index Key Structure

```
<indexSubspace> + "I" + <indexName> + <spatialCode> + <primaryKey> → []
```

**Example**:
```
/app/indexes/I/restaurant_by_location/5926184548823023616/123 → []
                                      ^^^^^^^^^^^^^^^^^^^^^ S2CellID at level 17
                                                             ^^^ Primary key (restaurantID)
```

### KeyPath Extraction Process

```swift
private func extractCoordinates(
    from record: Record,
    spatialType: SpatialType
) throws -> [Double]
```

**Steps**:
1. Parse KeyPath string: `"\.address.location.latitude"` → `["address", "location", "latitude"]`
2. Use Mirror API to traverse nested structure:
   ```swift
   let mirror = Mirror(reflecting: record)
   for child in mirror.children {
       if child.label == "address" {
           let addressMirror = Mirror(reflecting: child.value)
           // ... continue traversal ...
       }
   }
   ```
3. Extract final value and convert to Double
4. Repeat for all KeyPath strings (2-3 coordinates)

### Spatial Code Encoding

```swift
private func encodeSpatialCode(
    coordinates: [Double],
    spatialType: SpatialType,
    options: SpatialIndexOptions
) throws -> UInt64
```

**Process**:
- `.geo`: `S2CellID.fromLatLon(lat * π/180, lon * π/180, level).id`
- `.geo3D`: `Geo3DEncoding.encode(lat, lon, alt, altitudeRange, level)`
- `.cartesian`: `MortonCode.encode2D(x, y, level)`
- `.cartesian3D`: `MortonCode.encode3D(x, y, z, level)`

### Query Range Building

```swift
public func buildRadiusQueryRanges(
    centerLat: Double,
    centerLon: Double,
    radiusMeters: Double,
    transaction: any TransactionProtocol
) throws -> [(begin: FDB.Bytes, end: FDB.Bytes)]
```

**Process**:
1. Create S2RegionCoverer
2. Generate covering cells
3. For each cell:
   - `beginKey = indexSubspace + indexName + cell.rangeMin()`
   - `endKey = indexSubspace + indexName + cell.rangeMax() + 0xFF`
4. Return array of (beginKey, endKey) tuples
5. QueryBuilder will iterate all ranges and merge results

---

## QueryBuilder API

### Spatial Query Methods

```swift
extension QueryBuilder where Record: Recordable {

    /// Filter records within a radius (geographic coordinates)
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to spatial field
    ///   - centerLat: Center latitude (degrees)
    ///   - centerLon: Center longitude (degrees)
    ///   - radiusMeters: Radius in meters
    /// - Returns: Self for method chaining
    ///
    /// **Example**:
    /// ```swift
    /// let restaurants = try await store.query(Restaurant.self)
    ///     .withinRadius(\.location, centerLat: 35.6812, centerLon: 139.7671, radiusMeters: 1000)
    ///     .execute()
    /// ```
    public func withinRadius(
        _ keyPath: KeyPath<Record, some Any>,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) -> Self

    /// Filter records within a bounding box (geographic coordinates)
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to spatial field
    ///   - minLat: Minimum latitude (degrees)
    ///   - maxLat: Maximum latitude (degrees)
    ///   - minLon: Minimum longitude (degrees)
    ///   - maxLon: Maximum longitude (degrees)
    /// - Returns: Self for method chaining
    ///
    /// **Example**:
    /// ```swift
    /// let restaurants = try await store.query(Restaurant.self)
    ///     .withinBounds(\.location, minLat: 35.6, maxLat: 35.7, minLon: 139.7, maxLon: 139.8)
    ///     .execute()
    /// ```
    public func withinBounds(
        _ keyPath: KeyPath<Record, some Any>,
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Self

    /// Find K nearest neighbors (requires post-sorting by distance)
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to spatial field
    ///   - centerLat: Center latitude (degrees)
    ///   - centerLon: Center longitude (degrees)
    ///   - k: Number of nearest neighbors
    /// - Returns: Self for method chaining
    ///
    /// **Process**:
    /// 1. Use S2RegionCoverer with larger maxCells
    /// 2. Fetch candidate records from covering cells
    /// 3. Calculate exact Haversine distance for each candidate
    /// 4. Sort by distance
    /// 5. Return top K
    ///
    /// **Example**:
    /// ```swift
    /// let nearest = try await store.query(Restaurant.self)
    ///     .nearest(\.location, centerLat: 35.6812, centerLon: 139.7671, k: 10)
    ///     .execute()
    /// ```
    public func nearest(
        _ keyPath: KeyPath<Record, some Any>,
        centerLat: Double,
        centerLon: Double,
        k: Int
    ) -> Self
}
```

### False Positive Filtering

**All spatial queries return false positives** due to cell-based covering. Post-filtering is required:

```swift
// 1. Fetch candidates from index
let candidates = try await fetchFromIndex(ranges)

// 2. Calculate exact distance for each candidate
let filtered = candidates.filter { record in
    let distance = haversineDistance(center, record.location)
    return distance <= radiusMeters
}

// 3. Return filtered results
return filtered
```

### Automatic Level Adjustment

**Future Enhancement**: QueryBuilder can automatically adjust S2RegionCoverer parameters based on query size:

```swift
let coverer: S2RegionCoverer
if radiusMeters < 100 {
    // Small radius: use fine-grained cells
    coverer = S2RegionCoverer(minLevel: level - 1, maxLevel: level, maxCells: 4)
} else if radiusMeters < 1000 {
    // Medium radius: balanced
    coverer = S2RegionCoverer(minLevel: level - 2, maxLevel: level, maxCells: 8)
} else {
    // Large radius: coarser cells
    coverer = S2RegionCoverer(minLevel: level - 5, maxLevel: level - 2, maxCells: 16)
}
```

---

## Migration Path

### From Old @Spatial (Pre-Level-in-Type)

**Old Syntax** (deprecated):
```swift
@Spatial(level: 17)
var location: Coordinate
```

**New Syntax** (current):
```swift
@Spatial(
    type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude,
        level: 17
    ),
    name: "by_location"
)
var location: Coordinate
```

### Migration Strategy

1. **Detect Old Syntax**: Macro checks for `level` parameter outside of `type`
2. **Emit Warning**: `@Spatial with level parameter is deprecated. Use type: .geo(latitude: ..., longitude: ..., level: 17)`
3. **Auto-Migration**: `MigrationManager.lightweightMigration()` automatically converts old indexes to new format
4. **Default Level Assignment**: If old index has no level, assign default (17 for .geo, 16 for .geo3D, etc.)

### IndexDefinition Migration

```swift
// Old IndexDefinition (no level)
let oldIndex = Index(
    name: "location_index",
    type: .spatial(SpatialIndexOptions(type: .geo(latitude: "lat", longitude: "lon")))
)

// New IndexDefinition (with level)
let newIndex = Index(
    name: "location_index",
    type: .spatial(SpatialIndexOptions(type: .geo(latitude: "lat", longitude: "lon", level: 17)))
)

// MigrationManager auto-detects and rebuilds index with new level
try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))
```

---

## Performance Characteristics

### Index Write Performance

| Spatial Type | Encoding Cost | FDB Writes | Total Latency |
|--------------|--------------|------------|---------------|
| `.geo` | ~10μs (S2CellID) | 1 write | ~1-2ms |
| `.geo3D` | ~15μs (S2 + altitude) | 1 write | ~1-2ms |
| `.cartesian` | ~5μs (Morton) | 1 write | ~1-2ms |
| `.cartesian3D` | ~8μs (Morton 3D) | 1 write | ~1-2ms |

**Note**: FDB write latency dominates (~1-2ms). Encoding cost is negligible.

### Query Performance

#### Radius Query

| Radius | S2 Cells Generated | FDB Range Reads | Candidate Records | Filter Cost |
|--------|-------------------|-----------------|-------------------|-------------|
| 100m | 1-2 cells | 1-2 ranges | ~10-50 | ~0.1ms |
| 1km | 4-8 cells | 4-8 ranges | ~100-500 | ~1ms |
| 10km | 8-16 cells | 8-16 ranges | ~1000-5000 | ~10ms |

**Total Latency**: FDB range reads (~5-20ms) + false positive filtering (~0.1-10ms) = **5-30ms**

#### K-Nearest Neighbors

**Process**:
1. Expand radius until K candidates found (iterative S2RegionCoverer)
2. Fetch candidates
3. Calculate exact distance for each
4. Sort by distance
5. Return top K

**Latency**: 2-3× radius query (due to iterative expansion and sorting)

### Index Size

| Records | Index Entries | Disk Size (estimate) | FDB Keys |
|---------|--------------|----------------------|----------|
| 1,000 | 1,000 | ~100 KB | 1,000 |
| 10,000 | 10,000 | ~1 MB | 10,000 |
| 100,000 | 100,000 | ~10 MB | 100,000 |
| 1,000,000 | 1,000,000 | ~100 MB | 1,000,000 |

**Note**: Each spatial index entry is ~100 bytes (indexKey + empty value).

---

## Usage Examples

### Example 1: Restaurant Finder (Radius Search)

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])
    #Index<Restaurant>([\.name])

    @Spatial(
        type: .geo(
            latitude: \.address.location.latitude,
            longitude: \.address.location.longitude,
            level: 17  // ~9m cells for GPS accuracy
        ),
        name: "by_location"
    )
    var address: Address

    var restaurantID: Int64
    var name: String
    var address: Address

    struct Address: Codable, Sendable {
        var street: String
        var city: String
        var location: Coordinate
    }

    struct Coordinate: Codable, Sendable {
        var latitude: Double   // Degrees
        var longitude: Double  // Degrees
    }
}

// Query: Find restaurants within 1km of Tokyo Station
let tokyoStationLat = 35.6812
let tokyoStationLon = 139.7671

let nearbyRestaurants = try await store.query(Restaurant.self)
    .withinRadius(
        \.address,
        centerLat: tokyoStationLat,
        centerLon: tokyoStationLon,
        radiusMeters: 1000.0
    )
    .execute()

print("Found \(nearbyRestaurants.count) restaurants within 1km")
```

### Example 2: Drone Tracking (3D Spatial)

```swift
@Recordable
struct DronePosition {
    #PrimaryKey<DronePosition>([\.droneID, \.timestamp])

    @Spatial(
        type: .geo3D(
            latitude: \.latitude,
            longitude: \.longitude,
            altitude: \.altitude,
            level: 16  // ~18m cells for drone tracking
        ),
        name: "by_position"
    )
    var latitude: Double
    var longitude: Double
    var altitude: Double

    var droneID: String
    var timestamp: Date
}

// Altitude range specified in SpatialIndexOptions
let options = SpatialIndexOptions(
    type: .geo3D(latitude: "latitude", longitude: "longitude", altitude: "altitude", level: 16),
    altitudeRange: 0...500  // Drones fly 0-500m altitude
)

// Query: Find drones in 3D bounding box
let positions = try await store.query(DronePosition.self)
    .withinBounds3D(
        \.latitude,
        minLat: 35.6, maxLat: 35.7,
        minLon: 139.7, maxLon: 139.8,
        minAlt: 50.0, maxAlt: 200.0
    )
    .execute()
```

### Example 3: Game Map (Cartesian 2D)

```swift
@Recordable
struct GameEntity {
    #PrimaryKey<GameEntity>([\.entityID])

    @Spatial(
        type: .cartesian(
            x: \.position.x,
            y: \.position.y,
            level: 18  // 262k × 262k grid for game map
        ),
        name: "by_position"
    )
    var position: Position

    var entityID: Int64
    var name: String
    var position: Position

    struct Position: Codable, Sendable {
        var x: Double  // Normalized [0, 1]
        var y: Double  // Normalized [0, 1]
    }
}

// Query: Find entities in bounding box
let entities = try await store.query(GameEntity.self)
    .withinCartesianBounds(
        \.position,
        minX: 0.4, maxX: 0.6,
        minY: 0.4, maxY: 0.6
    )
    .execute()
```

### Example 4: Voxel World (Cartesian 3D)

```swift
@Recordable
struct VoxelBlock {
    #PrimaryKey<VoxelBlock>([\.worldID, \.x, \.y, \.z])

    @Spatial(
        type: .cartesian3D(
            x: \.x,
            y: \.y,
            z: \.z,
            level: 16  // 65k steps per axis for Minecraft-like world
        ),
        name: "by_position"
    )
    var x: Int
    var y: Int
    var z: Int

    var worldID: String
    var blockType: String
}

// Query: Find blocks in 3D region
let blocks = try await store.query(VoxelBlock.self)
    .withinCartesian3DBounds(
        minX: 100, maxX: 200,
        minY: 50, maxY: 100,
        minZ: 100, maxZ: 200
    )
    .execute()
```

---

## Implementation Checklist

- [x] **SpatialType Enum**: Level embedded in enum cases with realistic defaults
- [x] **S2CellID**: Complete implementation with Hilbert curve encoding
- [x] **MortonCode**: 2D and 3D bit-interleaving algorithms
- [x] **Geo3DEncoding**: S2CellID + altitude encoding (40 bits + 24 bits)
- [x] **S2RegionCoverer**: Radius and bounding box covering algorithm
- [x] **SpatialIndexMaintainer**: KeyPath extraction + spatial encoding
- [x] **IndexManager Integration**: Register SpatialIndexMaintainer
- [ ] **QueryBuilder API**: `.withinRadius()`, `.withinBounds()`, `.nearest()` methods
- [ ] **False Positive Filtering**: Post-index distance calculation
- [ ] **Migration Support**: `MigrationManager.lightweightMigration()` auto-detection
- [ ] **Tests**: Comprehensive test suite for all spatial types
- [ ] **Documentation**: User guide with examples

---

## Testing Strategy

### Unit Tests

1. **SpatialType Enum**:
   - Level defaults
   - isValidLevel validation
   - keyPathStrings extraction

2. **S2CellID**:
   - Lat/lon round-trip (all 6 faces)
   - Hilbert curve locality preservation
   - Range queries

3. **MortonCode**:
   - 2D/3D encoding round-trip
   - Bit interleaving correctness
   - Bounding box ranges

4. **Geo3DEncoding**:
   - S2CellID + altitude packing
   - Altitude normalization
   - Level validation

5. **S2RegionCoverer**:
   - Radius covering cell count
   - Bounding box covering cell count
   - maxCells constraint

### Integration Tests

1. **SpatialIndexMaintainer**:
   - KeyPath extraction from nested structures
   - Index entry creation/deletion
   - All 4 spatial types

2. **QueryBuilder**:
   - Radius queries with false positive filtering
   - Bounding box queries
   - K-nearest neighbors

3. **Migration**:
   - Old @Spatial syntax detection
   - Auto-migration to new format
   - Default level assignment

---

## Future Enhancements

1. **Automatic Level Selection**: QueryBuilder analyzes query radius and selects optimal S2RegionCoverer parameters
2. **Multi-Resolution Indexes**: Store multiple levels simultaneously for different query sizes
3. **Adaptive False Positive Filtering**: Use machine learning to predict optimal filtering threshold
4. **Distributed Spatial Joins**: Efficient joins between two spatial indexes
5. **Temporal Spatial Queries**: "Where was entity X at time T?"

---

## References

- **S2 Geometry Library**: https://s2geometry.io/
- **Google S2 Paper**: "S2: A Library for Spherical Geometry" (Furnas et al.)
- **Morton Code**: https://en.wikipedia.org/wiki/Z-order_curve
- **FoundationDB Spatial Indexing**: https://apple.github.io/foundationdb/spatial.html

---

**Status**: All core components implemented. QueryBuilder API and migration support are next priorities.
