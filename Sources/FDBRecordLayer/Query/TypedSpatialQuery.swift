import Foundation
import FoundationDB

/// Spatial bounding box specification
///
/// Specifies a 2D or 3D bounding box for spatial range queries.
///
/// **Coordinate System**:
/// - Geographic (.geo, .geo3D): latitude ∈ [-90, 90], longitude ∈ [-180, 180], altitude in meters
/// - Cartesian (.cartesian, .cartesian3D): application-defined range
public enum SpatialBoundingBox: Sendable {
    /// 2D bounding box (latitude/longitude or x/y)
    case box2D(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)

    /// 3D bounding box (latitude/longitude/altitude or x/y/z)
    case box3D(minLat: Double, minLon: Double, minAlt: Double, maxLat: Double, maxLon: Double, maxAlt: Double)
}

/// Type-safe spatial range query
///
/// Searches for records within a 2D or 3D bounding box using Z-order spatial indexing.
/// **Automatically filters false positives** caused by Z-order curve approximation.
///
/// **Example**:
/// ```swift
/// let restaurants = try await store.query(Restaurant.self)
///     .withinBoundingBox(
///         minLat: 35.6, minLon: 139.6,
///         maxLat: 35.7, maxLon: 139.8,
///         using: "restaurant_location_spatial"
///     )
///     .filter(\.rating >= 4.0)
///     .limit(50)
///     .execute()
/// ```
public struct TypedSpatialQuery<Record: Sendable>: Sendable {
    let boundingBox: SpatialBoundingBox
    let index: Index
    let recordAccess: any RecordAccess<Record>
    let recordSubspace: Subspace
    let indexSubspace: Subspace
    nonisolated(unsafe) let database: any DatabaseProtocol

    private let postFilter: (any TypedQueryComponent<Record>)?
    private let limitValue: Int?

    internal init(
        boundingBox: SpatialBoundingBox,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace,
        indexSubspace: Subspace,
        database: any DatabaseProtocol,
        postFilter: (any TypedQueryComponent<Record>)? = nil,
        limitValue: Int? = nil
    ) {
        self.boundingBox = boundingBox
        self.index = index
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
        self.indexSubspace = indexSubspace
        self.database = database
        self.postFilter = postFilter
        self.limitValue = limitValue
    }

    /// Add a filter to post-process results
    ///
    /// Multiple calls are combined with AND logic.
    ///
    /// - Parameter component: Filter predicate using existing DSL (e.g., `\.rating >= 4.0`)
    /// - Returns: Modified query with additional filter
    public func filter(_ component: any TypedQueryComponent<Record>) -> TypedSpatialQuery<Record> {
        let newFilter: any TypedQueryComponent<Record>
        if let existing = postFilter {
            newFilter = TypedAndQueryComponent(children: [existing, component])
        } else {
            newFilter = component
        }

        return TypedSpatialQuery(
            boundingBox: boundingBox,
            index: index,
            recordAccess: recordAccess,
            recordSubspace: recordSubspace,
            indexSubspace: indexSubspace,
            database: database,
            postFilter: newFilter,
            limitValue: limitValue
        )
    }

    /// Limit number of results
    ///
    /// - Parameter limit: Maximum number of records to return
    /// - Returns: Modified query with limit
    public func limit(_ limit: Int) -> TypedSpatialQuery<Record> {
        return TypedSpatialQuery(
            boundingBox: boundingBox,
            index: index,
            recordAccess: recordAccess,
            recordSubspace: recordSubspace,
            indexSubspace: indexSubspace,
            database: database,
            postFilter: postFilter,
            limitValue: limit
        )
    }

    /// Execute spatial range query
    ///
    /// - Returns: Array of records within the bounding box
    /// - Throws: RecordLayerError on execution failure
    public func execute() async throws -> [Record] {
        // Create transaction for this query execution
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let plan = TypedSpatialRangePlan(
            boundingBox: boundingBox,
            index: index,
            postFilter: postFilter,
            limit: limitValue
        )

        return try await plan.execute(
            subspace: indexSubspace,
            recordAccess: recordAccess,
            context: context,
            recordSubspace: recordSubspace
        )
    }
}

/// Execution plan for spatial range query
///
/// **False Positive Handling**: Z-order curves can return points outside the bounding box.
/// This plan ALWAYS verifies actual coordinates to filter false positives.
struct TypedSpatialRangePlan<Record: Sendable>: Sendable {
    private let boundingBox: SpatialBoundingBox
    private let index: Index
    private let postFilter: (any TypedQueryComponent<Record>)?
    private let limit: Int?

    init(
        boundingBox: SpatialBoundingBox,
        index: Index,
        postFilter: (any TypedQueryComponent<Record>)? = nil,
        limit: Int? = nil
    ) {
        self.boundingBox = boundingBox
        self.index = index
        self.postFilter = postFilter
        self.limit = limit
    }

    /// Execute spatial range query with automatic false positive filtering
    func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        recordSubspace: Subspace
    ) async throws -> [Record] {
        let transaction = context.getTransaction()

        // Build index subspace
        let indexNameSubspace = subspace.subspace(index.name)

        // Create spatial index maintainer (read-only usage)
        let maintainer = try GenericSpatialIndexMaintainer<Record>(
            index: index,
            subspace: indexNameSubspace,
            recordSubspace: recordSubspace
        )

        // Get spatial type
        guard let spatialOptions = index.options.spatialOptions else {
            throw RecordLayerError.internalError("Spatial index missing spatialOptions")
        }
        let spatialType = spatialOptions.type

        // Perform range query (may include false positives)
        let candidatePrimaryKeys: [Tuple]
        switch boundingBox {
        case let .box2D(minLat, minLon, maxLat, maxLon):
            // Convert to normalized coordinates [0, 1]
            let normalizedBox = normalize2DBox(
                minLat: minLat,
                minLon: minLon,
                maxLat: maxLat,
                maxLon: maxLon,
                spatialType: spatialType
            )
            candidatePrimaryKeys = try await maintainer.rangeQuery2D(
                minX: normalizedBox.minX,
                minY: normalizedBox.minY,
                maxX: normalizedBox.maxX,
                maxY: normalizedBox.maxY,
                transaction: transaction
            )

        case let .box3D(minLat, minLon, minAlt, maxLat, maxLon, maxAlt):
            // Get altitudeRange for 3D normalization
            guard let options = index.options.spatialOptions else {
                throw RecordLayerError.internalError("Spatial index missing spatialOptions")
            }
            guard let altitudeRange = options.altitudeRange else {
                throw RecordLayerError.internalError("3D spatial index requires altitudeRange")
            }

            let normalizedBox = normalize3DBox(
                minLat: minLat,
                minLon: minLon,
                minAlt: minAlt,
                maxLat: maxLat,
                maxLon: maxLon,
                maxAlt: maxAlt,
                spatialType: spatialType,
                altitudeRange: altitudeRange
            )
            candidatePrimaryKeys = try await maintainer.rangeQuery3D(
                minX: normalizedBox.minX,
                minY: normalizedBox.minY,
                minZ: normalizedBox.minZ,
                maxX: normalizedBox.maxX,
                maxY: normalizedBox.maxY,
                maxZ: normalizedBox.maxZ,
                transaction: transaction
            )
        }

        // Fetch records and filter false positives
        var results: [Record] = []
        let recordName = String(describing: Record.self)

        for primaryKey in candidatePrimaryKeys {
            // Fetch record
            let effectiveSubspace = recordSubspace.subspace(recordName)
            let recordKey = effectiveSubspace.subspace(primaryKey).pack(Tuple())

            guard let recordValue = try await transaction.getValue(for: recordKey, snapshot: true) else {
                continue  // Record deleted
            }

            let record = try recordAccess.deserialize(recordValue)

            // **CRITICAL**: Verify actual coordinates (filter false positives)
            let isWithinBounds = try verifyBoundingBox(
                record: record,
                box: boundingBox,
                recordAccess: recordAccess,
                spatialType: spatialType
            )
            if !isWithinBounds {
                continue  // False positive from Z-order curve
            }

            // Apply post-filter if present
            if let filter = postFilter {
                let matches = try filter.matches(record: record, recordAccess: recordAccess)
                if !matches {
                    continue
                }
            }

            results.append(record)

            // Check limit
            if let limit = limit, results.count >= limit {
                break
            }
        }

        return results
    }

    // MARK: - False Positive Verification

    /// Verify that a record's actual coordinates are within the bounding box
    private func verifyBoundingBox(
        record: Record,
        box: SpatialBoundingBox,
        recordAccess: any RecordAccess<Record>,
        spatialType: SpatialType
    ) throws -> Bool {
        // Evaluate spatial field from record
        let spatialValues = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        guard let spatialField = spatialValues.first else {
            throw RecordLayerError.internalError("Spatial field not found in record")
        }

        guard let spatial = spatialField as? any SpatialRepresentable else {
            throw RecordLayerError.internalError("Spatial field does not conform to SpatialRepresentable")
        }

        // Get normalized coordinates (use altitudeRange for 3D)
        let coords: [Double]
        if spatialType == .geo3D || spatialType == .cartesian3D {
            guard let options = index.options.spatialOptions else {
                throw RecordLayerError.internalError("Spatial index missing spatialOptions")
            }
            guard let altitudeRange = options.altitudeRange else {
                throw RecordLayerError.internalError("3D spatial index requires altitudeRange")
            }
            coords = spatial.toNormalizedCoordinates(altitudeRange: altitudeRange)
        } else {
            coords = spatial.toNormalizedCoordinates()
        }

        // Verify coordinates are within bounds
        switch box {
        case let .box2D(minLat, minLon, maxLat, maxLon):
            let normalizedBox = normalize2DBox(
                minLat: minLat,
                minLon: minLon,
                maxLat: maxLat,
                maxLon: maxLon,
                spatialType: spatialType
            )
            return coords[0] >= normalizedBox.minX && coords[0] <= normalizedBox.maxX &&
                   coords[1] >= normalizedBox.minY && coords[1] <= normalizedBox.maxY

        case let .box3D(minLat, minLon, minAlt, maxLat, maxLon, maxAlt):
            // Get altitudeRange for normalization
            guard let options = index.options.spatialOptions else {
                throw RecordLayerError.internalError("Spatial index missing spatialOptions")
            }
            guard let altitudeRange = options.altitudeRange else {
                throw RecordLayerError.internalError("3D spatial index requires altitudeRange")
            }

            let normalizedBox = normalize3DBox(
                minLat: minLat,
                minLon: minLon,
                minAlt: minAlt,
                maxLat: maxLat,
                maxLon: maxLon,
                maxAlt: maxAlt,
                spatialType: spatialType,
                altitudeRange: altitudeRange
            )
            return coords[0] >= normalizedBox.minX && coords[0] <= normalizedBox.maxX &&
                   coords[1] >= normalizedBox.minY && coords[1] <= normalizedBox.maxY &&
                   coords[2] >= normalizedBox.minZ && coords[2] <= normalizedBox.maxZ
        }
    }

    // MARK: - Coordinate Normalization

    /// Normalize 2D box to [0, 1] coordinates
    private func normalize2DBox(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double,
        spatialType: SpatialType
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        switch spatialType {
        case .geo:
            // Latitude: [-90, 90] → [0, 1]
            // Longitude: [-180, 180] → [0, 1]
            return (
                minX: (minLon + 180) / 360,
                minY: (minLat + 90) / 180,
                maxX: (maxLon + 180) / 360,
                maxY: (maxLat + 90) / 180
            )
        case .cartesian:
            // Assume coordinates are already normalized [0, 1]
            return (minX: minLon, minY: minLat, maxX: maxLon, maxY: maxLat)
        default:
            fatalError("normalize2DBox called with non-2D spatial type: \(spatialType)")
        }
    }

    /// Normalize 3D box to [0, 1] coordinates
    private func normalize3DBox(
        minLat: Double,
        minLon: Double,
        minAlt: Double,
        maxLat: Double,
        maxLon: Double,
        maxAlt: Double,
        spatialType: SpatialType,
        altitudeRange: ClosedRange<Double>
    ) -> (minX: Double, minY: Double, minZ: Double, maxX: Double, maxY: Double, maxZ: Double) {
        switch spatialType {
        case .geo3D:
            // Latitude: [-90, 90] → [0, 1]
            // Longitude: [-180, 180] → [0, 1]
            // Altitude: [altitudeRange.lowerBound, altitudeRange.upperBound] → [0, 1]
            let normalizedMinAlt = (minAlt - altitudeRange.lowerBound) /
                                  (altitudeRange.upperBound - altitudeRange.lowerBound)
            let normalizedMaxAlt = (maxAlt - altitudeRange.lowerBound) /
                                  (altitudeRange.upperBound - altitudeRange.lowerBound)

            return (
                minX: (minLon + 180) / 360,
                minY: (minLat + 90) / 180,
                minZ: max(0.0, min(1.0, normalizedMinAlt)),  // Clamp to [0, 1]
                maxX: (maxLon + 180) / 360,
                maxY: (maxLat + 90) / 180,
                maxZ: max(0.0, min(1.0, normalizedMaxAlt))   // Clamp to [0, 1]
            )
        case .cartesian3D:
            // Assume coordinates are already normalized [0, 1]
            return (minX: minLon, minY: minLat, minZ: minAlt, maxX: maxLon, maxY: maxLat, maxZ: maxAlt)
        default:
            fatalError("normalize3DBox called with non-3D spatial type: \(spatialType)")
        }
    }
}
