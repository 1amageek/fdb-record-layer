import Foundation
import FDBRecordCore
import FoundationDB

// Import spatial encoding modules
// Note: These will be available once the spatial encoding files are in the build

/// Index maintainer for spatial indexes using S2 Geometry or Morton Code
///
/// **Supported Spatial Types**:
/// - `.geo`: S2CellID encoding (Hilbert curve on sphere)
/// - `.geo3D`: S2CellID + altitude encoding
/// - `.cartesian`: 2D Morton Code (Z-order curve)
/// - `.cartesian3D`: 3D Morton Code (Z-order curve)
///
/// **Index Key Structure**:
/// ```
/// <indexSubspace> + <indexName> + <spatialCode> + <primaryKey>
/// ```
///
/// Where `spatialCode` is:
/// - `.geo`: S2CellID (UInt64)
/// - `.geo3D`: S2CellID + altitude (UInt64)
/// - `.cartesian`: Morton Code (UInt64)
/// - `.cartesian3D`: Morton Code (UInt64)
///
/// **KeyPath Extraction**:
/// This maintainer uses reflection (Mirror API) to extract coordinate values
/// from nested structures using KeyPath strings stored in SpatialType.
///
/// **Example**:
/// ```swift
/// @Recordable
/// struct Restaurant {
///     @Spatial(
///         type: .geo(
///             latitude: \.address.location.latitude,
///             longitude: \.address.location.longitude,
///             level: 17
///         ),
///         name: "by_location"
///     )
///     var address: Address
///
///     struct Address {
///         var location: Coordinate
///     }
///
///     struct Coordinate {
///         var latitude: Double
///         var longitude: Double
///     }
/// }
/// ```
public struct SpatialIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {

    // MARK: - Properties

    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    // MARK: - Initialization

    public init(
        index: Index,
        subspace: Subspace,
        recordSubspace: Subspace
    ) {
        self.index = index
        self.subspace = subspace
        self.recordSubspace = recordSubspace
    }

    // MARK: - GenericIndexMaintainer Protocol

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old index entries
        if let oldRecord = oldRecord {
            try await removeIndexEntries(for: oldRecord, recordAccess: recordAccess, transaction: transaction)
        }

        // Add new index entries
        if let newRecord = newRecord {
            try await addIndexEntries(for: newRecord, recordAccess: recordAccess, transaction: transaction)
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // For spatial indexes, scanning a record means adding its index entry
        try await addIndexEntries(for: record, recordAccess: recordAccess, transaction: transaction)
    }

    // MARK: - Private Methods

    /// Add spatial index entries for a record
    private func addIndexEntries(
        for record: Record,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Verify this is a spatial index
        guard index.type == .spatial else {
            throw RecordLayerError.internalError("Index type is not spatial")
        }

        // Get spatial options from index.options
        guard let options = index.options.spatialOptions else {
            throw RecordLayerError.internalError("Spatial index '\(index.name)' missing spatialOptions")
        }

        let spatialType = options.type

        // Extract coordinate values using KeyPath reflection
        let coordinates = try extractCoordinates(from: record, spatialType: spatialType)

        // Encode coordinates to spatial code (S2CellID or Morton Code)
        let spatialCode = try encodeSpatialCode(
            coordinates: coordinates,
            spatialType: spatialType,
            options: options
        )

        // Extract primary key using Recordable protocol (same pattern as ValueIndex)
        let primaryKeyTuple: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKeyTuple = recordableRecord.extractPrimaryKey()
        } else {
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }
        let primaryKey = try Tuple.unpack(from: primaryKeyTuple.pack())

        // Build index key: <indexSubspace> + <indexName> + <spatialCode> + <primaryKey>
        let indexNameSubspace = subspace.subspace("I").subspace(index.name)

        // Combine spatial code with primary key values
        let allValues: [any TupleElement] = [spatialCode] + primaryKey
        let tuple = TupleHelpers.toTuple(allValues)
        let indexKey = indexNameSubspace.pack(tuple)

        // Write empty value (index entry existence is what matters)
        transaction.setValue([], for: indexKey)
    }

    /// Remove spatial index entries for a record
    private func removeIndexEntries(
        for record: Record,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Verify this is a spatial index
        guard index.type == .spatial else {
            throw RecordLayerError.internalError("Index type is not spatial")
        }

        // Get spatial options from index.options
        guard let options = index.options.spatialOptions else {
            throw RecordLayerError.internalError("Spatial index '\(index.name)' missing spatialOptions")
        }

        let spatialType = options.type

        // Extract coordinates
        let coordinates = try extractCoordinates(from: record, spatialType: spatialType)

        // Encode spatial code
        let spatialCode = try encodeSpatialCode(
            coordinates: coordinates,
            spatialType: spatialType,
            options: options
        )

        // Extract primary key using Recordable protocol (same pattern as ValueIndex)
        let primaryKeyTuple: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKeyTuple = recordableRecord.extractPrimaryKey()
        } else {
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }
        let primaryKey = try Tuple.unpack(from: primaryKeyTuple.pack())

        // Build index key
        let indexNameSubspace = subspace.subspace("I").subspace(index.name)

        // Combine spatial code with primary key values
        let allValues: [any TupleElement] = [spatialCode] + primaryKey
        let tuple = TupleHelpers.toTuple(allValues)
        let indexKey = indexNameSubspace.pack(tuple)

        // Clear the key
        transaction.clear(key: indexKey)
    }

    // MARK: - Coordinate Extraction

    /// Extract coordinate values from record using KeyPath reflection
    ///
    /// - Parameters:
    ///   - record: Record to extract from
    ///   - spatialType: Spatial type with KeyPath strings
    /// - Returns: Array of coordinate values (2 or 3 elements)
    ///
    /// **Process**:
    /// 1. Parse KeyPath strings (e.g., "\.address.location.latitude")
    /// 2. Use Mirror API to traverse nested structure
    /// 3. Extract Double values for each coordinate
    private func extractCoordinates(
        from record: Record,
        spatialType: SpatialType
    ) throws -> [Double] {
        let keyPathStrings = spatialType.keyPathStrings

        var coordinates: [Double] = []

        for keyPathString in keyPathStrings {
            // Parse KeyPath string: "\.field1.field2.field3" → ["field1", "field2", "field3"]
            let components = parseKeyPath(keyPathString)

            // Extract value using reflection
            let value = try extractValue(from: record, components: components)

            // Convert to Double
            guard let doubleValue = convertToDouble(value) else {
                throw RecordLayerError.invalidArgument(
                    "Spatial coordinate at KeyPath '\(keyPathString)' is not a numeric type (got \(type(of: value))). " +
                    "Expected Double, Float, Int, or Int64."
                )
            }

            coordinates.append(doubleValue)
        }

        return coordinates
    }

    /// Parse KeyPath string into field name components
    ///
    /// - Parameter keyPath: KeyPath string (e.g., "\.address.location.latitude")
    /// - Returns: Array of field names ["address", "location", "latitude"]
    private func parseKeyPath(_ keyPath: String) -> [String] {
        // Remove leading "\." if present
        var cleaned = keyPath
        if cleaned.hasPrefix("\\.") {
            cleaned = String(cleaned.dropFirst(2))
        } else if cleaned.hasPrefix(".") {
            cleaned = String(cleaned.dropFirst(1))
        }

        // Split by "."
        return cleaned.split(separator: ".").map { String($0) }
    }

    /// Extract value from record using field name components
    ///
    /// - Parameters:
    ///   - value: Current value (starts with record)
    ///   - components: Remaining field names to traverse
    /// - Returns: Final value at the KeyPath
    private func extractValue(from value: Any, components: [String]) throws -> Any {
        guard !components.isEmpty else {
            return value
        }

        let fieldName = components[0]
        let remainingComponents = Array(components.dropFirst())

        // Use Mirror to find the field
        let mirror = Mirror(reflecting: value)

        for child in mirror.children {
            if child.label == fieldName {
                // Recursive traversal
                return try extractValue(from: child.value, components: remainingComponents)
            }
        }

        throw RecordLayerError.invalidArgument(
            "Field '\(fieldName)' not found in \(type(of: value)). " +
            "Check that KeyPath in @Spatial matches the actual record structure."
        )
    }

    /// Convert Any value to Double
    ///
    /// - Parameter value: Value to convert (Double, Float, Int, Int64, etc.)
    /// - Returns: Double value, or nil if conversion fails
    private func convertToDouble(_ value: Any) -> Double? {
        switch value {
        case let d as Double:
            return d
        case let f as Float:
            return Double(f)
        case let i as Int:
            return Double(i)
        case let i64 as Int64:
            return Double(i64)
        case let i32 as Int32:
            return Double(i32)
        default:
            return nil
        }
    }

    // MARK: - Spatial Encoding

    /// Encode coordinates to spatial code (S2CellID or Morton Code)
    ///
    /// - Parameters:
    ///   - coordinates: Array of coordinate values
    ///   - spatialType: Spatial type (.geo, .geo3D, .cartesian, .cartesian3D)
    ///   - options: Spatial index options (altitude range for .geo3D)
    /// - Returns: 64-bit spatial code
    private func encodeSpatialCode(
        coordinates: [Double],
        spatialType: SpatialType,
        options: SpatialIndexOptions
    ) throws -> UInt64 {
        switch spatialType {
        case .geo(_, _, let level):
            // S2CellID encoding for 2D geographic
            guard coordinates.count == 2 else {
                throw RecordLayerError.invalidArgument(
                    "Expected 2 coordinates for .geo (latitude, longitude), got \(coordinates.count)"
                )
            }

            let latitude = coordinates[0]   // Already in degrees
            let longitude = coordinates[1]  // Already in degrees

            // Create S2CellID at specified level
            let s2cell = S2CellID(lat: latitude, lon: longitude, level: level)
            return s2cell.rawValue

        case .geo3D(_, _, _, let level):
            // S2CellID + altitude encoding for 3D geographic
            guard coordinates.count == 3 else {
                throw RecordLayerError.invalidArgument(
                    "Expected 3 coordinates for .geo3D (latitude, longitude, altitude), got \(coordinates.count)"
                )
            }

            guard let altitudeRange = options.altitudeRange else {
                throw RecordLayerError.invalidArgument(
                    ".geo3D requires altitudeRange in SpatialIndexOptions. " +
                    "Example: SpatialIndexOptions(type: .geo3D(...), altitudeRange: 0...10000)"
                )
            }

            let latitude = coordinates[0] * .pi / 180.0   // Convert to radians
            let longitude = coordinates[1] * .pi / 180.0  // Convert to radians
            let altitude = coordinates[2]

            // Use Geo3DEncoding for S2CellID + altitude
            return try Geo3DEncoding.encode(
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                altitudeRange: altitudeRange,
                level: level
            )

        case .cartesian(_, _, let level):
            // 2D Morton Code encoding with level-based precision
            guard coordinates.count == 2 else {
                throw RecordLayerError.invalidArgument(
                    "Expected 2 coordinates for .cartesian (x, y), got \(coordinates.count)"
                )
            }

            let x = coordinates[0]
            let y = coordinates[1]

            // Use MortonCode with level parameter for precision control
            // level 0-30: 1-30 bits per axis
            return MortonCode.encode2D(x: x, y: y, level: level)

        case .cartesian3D(_, _, _, let level):
            // 3D Morton Code encoding with level-based precision
            guard coordinates.count == 3 else {
                throw RecordLayerError.invalidArgument(
                    "Expected 3 coordinates for .cartesian3D (x, y, z), got \(coordinates.count)"
                )
            }

            let x = coordinates[0]
            let y = coordinates[1]
            let z = coordinates[2]

            // Use MortonCode with level parameter for precision control
            // level 0-20: 1-20 bits per axis (max 60 bits total for 3 axes)
            return MortonCode.encode3D(x: x, y: y, z: z, level: level)
        }
    }
}

// MARK: - Spatial Query Extensions

extension SpatialIndexMaintainer {

    /// Build range selectors for a radius query (.geo only)
    ///
    /// This method is used by QueryBuilder to construct FDB range reads.
    ///
    /// - Parameters:
    ///   - centerLat: Center latitude (degrees)
    ///   - centerLon: Center longitude (degrees)
    ///   - radiusMeters: Radius in meters
    ///   - transaction: FDB transaction
    /// - Returns: Array of (beginKey, endKey) tuples for each covering cell
    ///
    /// **Process**:
    /// 1. Use S2RegionCoverer to generate covering cells
    /// 2. For each cell, create FDB range: [cellID_min, cellID_max)
    /// 3. Return all ranges (QueryBuilder will iterate and merge results)
    public func buildRadiusQueryRanges(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double,
        transaction: any TransactionProtocol
    ) throws -> [(begin: FDB.Bytes, end: FDB.Bytes)] {
        // Verify this is a spatial index with .geo type
        guard index.type == .spatial,
              let options = index.options.spatialOptions,
              case .geo(_, _, let level) = options.type else {
            throw RecordLayerError.invalidArgument(
                "buildRadiusQueryRanges only supports .geo spatial type"
            )
        }

        // Use S2RegionCoverer to generate covering cells
        let indexNameSubspace = subspace.subspace("I").subspace(index.name)

        // Create S2RegionCoverer with appropriate parameters
        let coverer = S2RegionCoverer(
            minLevel: max(0, level - 2),  // Allow cells 2 levels coarser
            maxLevel: level,               // Maximum precision at index level
            maxCells: 8                    // Limit to 8 cells for efficiency
        )

        // Get covering cells for the radius (convert degrees to radians)
        let coveringCells = coverer.getCovering(
            centerLat: centerLat * .pi / 180.0,
            centerLon: centerLon * .pi / 180.0,
            radiusMeters: radiusMeters
        )

        // Convert each S2CellID to a range
        var ranges: [(begin: FDB.Bytes, end: FDB.Bytes)] = []
        for cellID in coveringCells {
            let cellCode = cellID.rawValue
            let beginKey = indexNameSubspace.pack(Tuple(cellCode))
            var endKey = indexNameSubspace.pack(Tuple(cellCode))
            endKey.append(0xFF)
            ranges.append((begin: beginKey, end: endKey))
        }

        return ranges
    }

    /// Build range selectors for a bounding box query
    ///
    /// - Parameters:
    ///   - minLat: Minimum latitude (degrees)
    ///   - maxLat: Maximum latitude (degrees)
    ///   - minLon: Minimum longitude (degrees)
    ///   - maxLon: Maximum longitude (degrees)
    ///   - transaction: FDB transaction
    /// - Returns: Array of (beginKey, endKey) tuples
    public func buildBoundingBoxRanges(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        transaction: any TransactionProtocol
    ) throws -> [(begin: FDB.Bytes, end: FDB.Bytes)] {
        // Verify this is a spatial index with .geo type
        guard index.type == .spatial,
              let options = index.options.spatialOptions,
              case .geo(_, _, let level) = options.type else {
            throw RecordLayerError.invalidArgument(
                "buildBoundingBoxRanges only supports .geo spatial type"
            )
        }

        // Use S2RegionCoverer to generate covering cells for bounding box
        let indexNameSubspace = subspace.subspace("I").subspace(index.name)

        // Create S2RegionCoverer with appropriate parameters
        let coverer = S2RegionCoverer(
            minLevel: max(0, level - 2),  // Allow cells 2 levels coarser
            maxLevel: level,               // Maximum precision at index level
            maxCells: 8                    // Limit to 8 cells for efficiency
        )

        // Get covering cells for the bounding box (convert degrees to radians)
        let coveringCells = coverer.getCovering(
            minLat: minLat * .pi / 180.0,
            maxLat: maxLat * .pi / 180.0,
            minLon: minLon * .pi / 180.0,
            maxLon: maxLon * .pi / 180.0
        )

        // Convert each S2CellID to a range
        var ranges: [(begin: FDB.Bytes, end: FDB.Bytes)] = []
        for cellID in coveringCells {
            let cellCode = cellID.rawValue
            let beginKey = indexNameSubspace.pack(Tuple(cellCode))
            var endKey = indexNameSubspace.pack(Tuple(cellCode))
            endKey.append(0xFF)
            ranges.append((begin: beginKey, end: endKey))
        }

        return ranges
    }
}
