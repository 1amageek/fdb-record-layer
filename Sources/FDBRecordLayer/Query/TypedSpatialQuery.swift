import Foundation
import FDBRecordCore
import FoundationDB

/// Type-safe spatial query for geographic and Cartesian spatial searches
///
/// Performs spatial queries using S2 Geometry (geographic) or Morton Code (Cartesian) indexes
/// and optionally filters results.
///
/// **Geographic Query Example**:
/// ```swift
/// let restaurants = try await store.query(Restaurant.self)
///     .withinRadius(
///         \.location,  // KeyPath to @Spatial field
///         centerLat: 35.6762,
///         centerLon: 139.6503,
///         radiusMeters: 5000
///     )
///     .filter(\.category == "Italian")
///     .execute()
/// ```
///
/// **Cartesian Query Example**:
/// ```swift
/// let warehouses = try await store.query(Warehouse.self)
///     .withinBoundingBox(
///         \.position,  // KeyPath to @Spatial field
///         minX: 0.0, maxX: 100.0,
///         minY: 0.0, maxY: 100.0
///     )
///     .execute()
/// ```
public struct TypedSpatialQuery<Record: Recordable>: Sendable {

    // MARK: - Query Types

    /// Spatial query type
    internal enum QueryType: Sendable {
        /// Geographic radius query (.geo only)
        case radius(centerLat: Double, centerLon: Double, radiusMeters: Double)

        /// Geographic bounding box query (.geo, .geo3D)
        case geoBoundingBox(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)

        /// Cartesian 2D bounding box query (.cartesian)
        case cartesianBoundingBox(minX: Double, maxX: Double, minY: Double, maxY: Double)

        /// Cartesian 3D bounding box query (.cartesian3D)
        case cartesian3DBoundingBox(minX: Double, maxX: Double, minY: Double, maxY: Double, minZ: Double, maxZ: Double)
    }

    // MARK: - Properties

    let queryType: QueryType
    let index: Index
    let recordAccess: any RecordAccess<Record>
    let recordSubspace: Subspace
    let indexSubspace: Subspace
    nonisolated(unsafe) let database: any DatabaseProtocol

    // Post-filter using TypedQueryComponent (consistent with existing DSL)
    private let postFilter: (any TypedQueryComponent<Record>)?

    // MARK: - Initialization

    internal init(
        queryType: QueryType,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace,
        indexSubspace: Subspace,
        database: any DatabaseProtocol,
        postFilter: (any TypedQueryComponent<Record>)? = nil
    ) {
        self.queryType = queryType
        self.index = index
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
        self.indexSubspace = indexSubspace
        self.database = database
        self.postFilter = postFilter
    }

    // MARK: - Filter Chaining

    /// Add a filter to post-process results
    ///
    /// **Note**: Filters are applied AFTER spatial search returns candidates.
    /// Multiple calls to filter() are combined with AND logic.
    ///
    /// - Parameter component: Filter predicate using existing DSL (e.g., `\.category == "Italian"`)
    /// - Returns: Modified query with additional filter
    public func filter(_ component: any TypedQueryComponent<Record>) -> TypedSpatialQuery<Record> {
        let newFilter: any TypedQueryComponent<Record>
        if let existing = postFilter {
            // Combine with AND
            newFilter = TypedAndQueryComponent(children: [existing, component])
        } else {
            newFilter = component
        }

        return TypedSpatialQuery(
            queryType: queryType,
            index: index,
            recordAccess: recordAccess,
            recordSubspace: recordSubspace,
            indexSubspace: indexSubspace,
            database: database,
            postFilter: newFilter
        )
    }

    // MARK: - Execution

    /// Execute spatial search
    ///
    /// - Returns: Array of records within the spatial query region
    /// - Throws: RecordLayerError on execution failure
    public func execute() async throws -> [Record] {
        // Create transaction for this query execution
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let plan = TypedSpatialIndexScanPlan(
            queryType: queryType,
            index: index,
            postFilter: postFilter
        )

        return try await plan.execute(
            subspace: indexSubspace,
            recordAccess: recordAccess,
            context: context,
            recordSubspace: recordSubspace
        )
    }
}

/// Execution plan for spatial queries
///
/// **Supported Spatial Types**:
/// - `.geo`: S2CellID-based geographic queries (radius, bounding box)
/// - `.geo3D`: S2CellID + altitude-based 3D geographic queries (bounding box)
/// - `.cartesian`: Morton Code-based 2D Cartesian queries (bounding box)
/// - `.cartesian3D`: Morton Code-based 3D Cartesian queries (bounding box)
///
/// **Implementation**: Uses S2RegionCoverer or MortonCode.boundingBox*() to generate
/// covering ranges, then performs FDB range reads to retrieve candidates.
struct TypedSpatialIndexScanPlan<Record: Recordable>: Sendable {
    private let queryType: TypedSpatialQuery<Record>.QueryType
    private let index: Index
    private let postFilter: (any TypedQueryComponent<Record>)?

    init(
        queryType: TypedSpatialQuery<Record>.QueryType,
        index: Index,
        postFilter: (any TypedQueryComponent<Record>)? = nil
    ) {
        self.queryType = queryType
        self.index = index
        self.postFilter = postFilter
    }

    /// Execute spatial search plan
    ///
    /// - Returns: Array of records
    func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        recordSubspace: Subspace
    ) async throws -> [Record] {
        let transaction = context.getTransaction()

        // Build index subspace
        let indexNameSubspace = subspace.subspace(index.name)

        // Verify this is a spatial index
        guard index.type == .spatial,
              let spatialOptions = index.options.spatialOptions else {
            throw RecordLayerError.invalidArgument("Index '\(index.name)' is not a spatial index")
        }

        // Generate covering ranges based on query type
        let ranges = try buildSpatialRanges(
            queryType: queryType,
            spatialType: spatialOptions.type,
            indexSubspace: indexNameSubspace
        )

        // Fetch candidates from all covering ranges
        var candidateKeys: Set<FDB.Bytes> = []

        for (beginKey, endKey) in ranges {
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: true
            )

            for try await (key, _) in sequence {
                candidateKeys.insert(key)
            }
        }

        // Extract primary keys and fetch records
        var results: [Record] = []
        let recordName = Record.recordName

        for indexKey in candidateKeys {
            // Unpack index key: <spatialCode> + <primaryKey>
            let tuple = try indexNameSubspace.unpack(indexKey)

            // Skip the spatial code (first element) and extract primary key
            guard tuple.count > 1 else {
                continue
            }

            var primaryKeyElements: [any TupleElement] = []
            for i in 1..<tuple.count {
                if let element = tuple[i] {
                    primaryKeyElements.append(element)
                }
            }
            let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

            // Fetch record
            let effectiveSubspace = recordSubspace.subspace(recordName)
            let recordKey = effectiveSubspace.subspace(primaryKeyTuple).pack(Tuple())

            guard let recordValue = try await transaction.getValue(for: recordKey, snapshot: true) else {
                continue  // Record deleted, skip
            }

            let record = try recordAccess.deserialize(recordValue)

            // Apply post-filter if present
            if let filter = postFilter {
                let matches = try filter.matches(record: record, recordAccess: recordAccess)
                if !matches {
                    continue
                }
            }

            results.append(record)
        }

        return results
    }

    // MARK: - Spatial Range Generation

    /// Build covering ranges for spatial query
    ///
    /// **Optimizations**:
    /// - **Dynamic maxCells**: Adjusts based on query size to prevent false negatives
    /// - **Range merging**: Merges overlapping/adjacent ranges to reduce FDB I/O
    ///
    /// - Parameters:
    ///   - queryType: Spatial query type (radius, bounding box, etc.)
    ///   - spatialType: Spatial index type (.geo, .cartesian, etc.)
    ///   - indexSubspace: Index subspace (already has index name)
    /// - Returns: Array of (begin, end) key ranges
    private func buildSpatialRanges(
        queryType: TypedSpatialQuery<Record>.QueryType,
        spatialType: SpatialType,
        indexSubspace: Subspace
    ) throws -> [(begin: FDB.Bytes, end: FDB.Bytes)] {
        switch (queryType, spatialType) {

        // MARK: - Geographic Queries (.geo)

        case (.radius(let centerLat, let centerLon, let radiusMeters), .geo(_, _, let level)):
            // Calculate dynamic maxCells based on radius and level
            let maxCells = calculateMaxCells(
                radiusMeters: radiusMeters,
                level: level
            )

            // Use S2RegionCoverer for radius query
            let coverer = S2RegionCoverer(
                minLevel: Swift.max(0, level - 2),
                maxLevel: level,
                maxCells: maxCells
            )

            let coveringCells = coverer.getCovering(
                centerLat: centerLat * .pi / 180.0,
                centerLon: centerLon * .pi / 180.0,
                radiusMeters: radiusMeters
            )

            let ranges = coveringCells.map { cellID in
                let cellCode = cellID.rawValue
                let beginKey = indexSubspace.pack(Tuple(cellCode))
                var endKey = indexSubspace.pack(Tuple(cellCode))
                endKey.append(0xFF)
                return (begin: beginKey, end: endKey)
            }

            // Merge overlapping/adjacent ranges
            return mergeRanges(ranges)

        case (.geoBoundingBox(let minLat, let maxLat, let minLon, let maxLon), .geo(_, _, let level)):
            // Calculate dynamic maxCells based on bounding box size
            let latSpan = abs(maxLat - minLat)
            let lonSpan = abs(maxLon - minLon)
            let avgLat = (minLat + maxLat) / 2.0

            // Estimate radius from bounding box
            let radiusMeters = estimateRadiusFromBoundingBox(
                latSpan: latSpan,
                lonSpan: lonSpan,
                avgLat: avgLat
            )

            let maxCells = calculateMaxCells(
                radiusMeters: radiusMeters,
                level: level
            )

            // Use S2RegionCoverer for bounding box
            let coverer = S2RegionCoverer(
                minLevel: Swift.max(0, level - 2),
                maxLevel: level,
                maxCells: maxCells
            )

            let coveringCells = coverer.getCovering(
                minLat: minLat * .pi / 180.0,
                maxLat: maxLat * .pi / 180.0,
                minLon: minLon * .pi / 180.0,
                maxLon: maxLon * .pi / 180.0
            )

            let ranges = coveringCells.map { cellID in
                let cellCode = cellID.rawValue
                let beginKey = indexSubspace.pack(Tuple(cellCode))
                var endKey = indexSubspace.pack(Tuple(cellCode))
                endKey.append(0xFF)
                return (begin: beginKey, end: endKey)
            }

            // Merge overlapping/adjacent ranges
            return mergeRanges(ranges)

        // MARK: - Cartesian Queries (.cartesian, .cartesian3D)

        case (.cartesianBoundingBox(let minX, let maxX, let minY, let maxY), .cartesian(_, _, _)):
            // Use MortonCode for 2D Cartesian bounding box
            let (minCode, maxCode) = MortonCode.boundingBox2D(
                minX: minX,
                minY: minY,
                maxX: maxX,
                maxY: maxY
            )

            let beginKey = indexSubspace.pack(Tuple(minCode))
            var endKey = indexSubspace.pack(Tuple(maxCode))
            endKey.append(0xFF)

            return [(begin: beginKey, end: endKey)]

        case (.cartesian3DBoundingBox(let minX, let maxX, let minY, let maxY, let minZ, let maxZ), .cartesian3D(_, _, _, _)):
            // Use MortonCode for 3D Cartesian bounding box
            let (minCode, maxCode) = MortonCode.boundingBox3D(
                minX: minX,
                minY: minY,
                minZ: minZ,
                maxX: maxX,
                maxY: maxY,
                maxZ: maxZ
            )

            let beginKey = indexSubspace.pack(Tuple(minCode))
            var endKey = indexSubspace.pack(Tuple(maxCode))
            endKey.append(0xFF)

            return [(begin: beginKey, end: endKey)]

        // MARK: - Invalid Combinations

        case (.radius, _):
            throw RecordLayerError.invalidArgument("Radius queries are only supported for .geo spatial type")

        case (.geoBoundingBox, _):
            throw RecordLayerError.invalidArgument("Geographic bounding box queries are only supported for .geo spatial type")

        case (.cartesianBoundingBox, _):
            throw RecordLayerError.invalidArgument("Cartesian 2D bounding box queries are only supported for .cartesian spatial type")

        case (.cartesian3DBoundingBox, _):
            throw RecordLayerError.invalidArgument("Cartesian 3D bounding box queries are only supported for .cartesian3D spatial type")
        }
    }

    // MARK: - Helper Functions

    /// Calculate dynamic maxCells based on query radius and S2 level
    ///
    /// **Formula**: Estimates the number of S2 cells needed to cover a circular region
    /// at a given level, then adds 50% buffer to prevent false negatives.
    ///
    /// - Parameters:
    ///   - radiusMeters: Query radius in meters
    ///   - level: S2 cell level
    /// - Returns: Recommended maxCells value (clamped to 4-100 range)
    private func calculateMaxCells(radiusMeters: Double, level: Int) -> Int {
        // Earth radius in meters
        let earthRadiusMeters = 6371000.0

        // Cell size at this level (approximate)
        // S2 cells at level N have edge length ≈ (π / 2^N) radians
        let cellSizeRadians = .pi / Double(1 << level)
        let cellSizeMeters = earthRadiusMeters * cellSizeRadians

        // Estimate number of cells needed to cover the circle
        // Area of circle: π * r²
        // Area of S2 cell: cellSize²
        let circleArea = .pi * radiusMeters * radiusMeters
        let cellArea = cellSizeMeters * cellSizeMeters
        let estimatedCells = circleArea / cellArea

        // Add 50% buffer to account for:
        // - Edge effects (cells partially overlapping circle)
        // - S2 cell shape irregularities (not perfect squares)
        let bufferedCells = Int(estimatedCells * 1.5)

        // Clamp to reasonable range
        // - Minimum 4: Even small queries need multiple cells
        // - Maximum 100: Prevent excessive cell count (performance limit)
        return Swift.max(4, Swift.min(100, bufferedCells))
    }

    /// Estimate equivalent radius from a geographic bounding box
    ///
    /// **Method**: Calculates the diagonal distance of the bounding box and
    /// returns half of it as the equivalent radius.
    ///
    /// - Parameters:
    ///   - latSpan: Latitude span in degrees
    ///   - lonSpan: Longitude span in degrees
    ///   - avgLat: Average latitude in degrees
    /// - Returns: Equivalent radius in meters
    private func estimateRadiusFromBoundingBox(
        latSpan: Double,
        lonSpan: Double,
        avgLat: Double
    ) -> Double {
        // Earth radius in meters
        let earthRadiusMeters = 6371000.0

        // Convert to radians
        let latSpanRad = latSpan * .pi / 180.0
        let lonSpanRad = lonSpan * .pi / 180.0
        let avgLatRad = avgLat * .pi / 180.0

        // Approximate diagonal distance using planar approximation
        // (accurate for small regions)
        let latDistance = earthRadiusMeters * latSpanRad
        let lonDistance = earthRadiusMeters * lonSpanRad * cos(avgLatRad)

        let diagonalDistance = sqrt(latDistance * latDistance + lonDistance * lonDistance)

        // Return half diagonal as equivalent radius
        return diagonalDistance / 2.0
    }

    /// Merge overlapping and adjacent ranges to reduce FDB I/O operations
    ///
    /// **Algorithm**:
    /// 1. Sort ranges by begin key
    /// 2. Iterate and merge if current.begin <= previous.end
    /// 3. Return merged list
    ///
    /// **Example**:
    /// ```
    /// Input:  [(A, C), (B, D), (E, F)]
    /// Output: [(A, D), (E, F)]
    /// ```
    ///
    /// - Parameter ranges: Array of (begin, end) key ranges
    /// - Returns: Merged array of ranges
    private func mergeRanges(_ ranges: [(begin: FDB.Bytes, end: FDB.Bytes)]) -> [(begin: FDB.Bytes, end: FDB.Bytes)] {
        guard !ranges.isEmpty else { return [] }

        // Sort ranges by begin key
        let sorted = ranges.sorted { $0.begin.lexicographicallyPrecedes($1.begin) }

        var merged: [(begin: FDB.Bytes, end: FDB.Bytes)] = []
        var current = sorted[0]

        for i in 1..<sorted.count {
            let next = sorted[i]

            // Check if ranges overlap or are adjacent
            // Adjacent: current.end == next.begin
            // Overlapping: current.end >= next.begin (lexicographically)
            if !current.end.lexicographicallyPrecedes(next.begin) || areAdjacent(current.end, next.begin) {
                // Merge: extend current range to cover next
                current.end = self.max(current.end, next.end, by: { $0.lexicographicallyPrecedes($1) })
            } else {
                // No overlap: save current and move to next
                merged.append(current)
                current = next
            }
        }

        // Append final range
        merged.append(current)

        return merged
    }

    /// Check if two keys are adjacent
    ///
    /// **Purpose**: Detects if two ranges can be merged even when not overlapping.
    ///
    /// **Implementation**: For S2CellID-based keys, we check if the packed tuples
    /// represent consecutive cell IDs. However, since S2CellIDs use Hilbert curve
    /// encoding, consecutive rawValues don't necessarily represent spatially adjacent cells.
    ///
    /// **Conservative approach**: Only merge if `end >= begin` (overlapping).
    /// Adjacent-but-not-overlapping ranges are kept separate to avoid incorrect merging.
    ///
    /// - Parameters:
    ///   - end: End key of first range
    ///   - begin: Begin key of second range
    /// - Returns: True if keys are adjacent (currently always returns false)
    private func areAdjacent(_ end: FDB.Bytes, _ begin: FDB.Bytes) -> Bool {
        // Conservative: Don't attempt adjacent detection
        // S2CellID ranges from S2RegionCoverer are already optimized via
        // normalization and coarsening, so additional adjacent merging
        // would provide minimal benefit and risks incorrect merging.
        return false
    }

    /// Helper to compare two values using a comparison closure and return the maximum
    private func max<T>(_ lhs: T, _ rhs: T, by areInIncreasingOrder: (T, T) -> Bool) -> T {
        return areInIncreasingOrder(lhs, rhs) ? rhs : lhs
    }
}
