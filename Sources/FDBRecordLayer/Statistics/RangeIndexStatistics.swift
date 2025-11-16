import Foundation

/// Range index statistics
///
/// Stores statistical information about a Range index to enable selectivity estimation
/// and cost-based query optimization.
///
/// **Statistical Metrics**:
/// - **Total Records**: Number of records in the index
/// - **Average Range Width**: Mean duration/size of Range values (in seconds for Date ranges)
/// - **Overlap Factor**: Average number of overlapping ranges at any point
/// - **Selectivity**: Typical query selectivity (0.0-1.0)
///
/// **Example**:
/// ```swift
/// let stats = RangeIndexStatistics(
///     totalRecords: 10_000,
///     avgRangeWidth: 86400,      // 1 day in seconds
///     overlapFactor: 5.2,         // ~5 ranges overlap on average
///     selectivity: 0.05,          // Typical query returns 5% of records
///     collectedAt: Date()
/// )
/// ```
///
/// **Usage in Query Optimization**:
/// ```swift
/// // Estimate selectivity for a specific query range
/// let queryWidth = queryRange.upperBound.timeIntervalSince(queryRange.lowerBound)
/// let estimatedSelectivity = (queryWidth / stats.avgRangeWidth) * stats.overlapFactor * stats.selectivity
/// ```
public struct RangeIndexStatistics: Sendable, Codable, Hashable {
    // MARK: - Properties

    /// Total number of records in the index
    public let totalRecords: UInt64

    /// Average range width in seconds (for Date ranges)
    ///
    /// Calculated as: sum(upperBound - lowerBound) / totalRecords
    public let avgRangeWidth: Double

    /// Overlap factor - average number of ranges overlapping at any point
    ///
    /// Higher values indicate more temporal/spatial overlap in the data.
    /// Calculated by sampling representative points and counting overlaps.
    public let overlapFactor: Double

    /// Typical query selectivity (0.0-1.0)
    ///
    /// Represents the fraction of records typically returned by a query.
    /// Estimated based on avgRangeWidth and overlapFactor.
    public let selectivity: Double

    /// Timestamp when statistics were collected
    public let collectedAt: Date

    /// Sample size used for statistics collection
    ///
    /// Number of records sampled during statistics collection.
    /// Larger samples provide more accurate statistics but take longer.
    public let sampleSize: UInt64

    // MARK: - Initialization

    public init(
        totalRecords: UInt64,
        avgRangeWidth: Double,
        overlapFactor: Double,
        selectivity: Double,
        collectedAt: Date = Date(),
        sampleSize: UInt64
    ) {
        self.totalRecords = totalRecords
        self.avgRangeWidth = avgRangeWidth
        self.overlapFactor = overlapFactor
        self.selectivity = selectivity
        self.collectedAt = collectedAt
        self.sampleSize = sampleSize
    }

    // MARK: - Computed Properties

    /// Check if statistics are stale (older than threshold)
    ///
    /// - Parameter threshold: Maximum age in seconds (default: 1 hour)
    /// - Returns: True if statistics should be refreshed
    public func isStale(threshold: TimeInterval = 3600) -> Bool {
        return Date().timeIntervalSince(collectedAt) > threshold
    }

    /// Estimate selectivity for a specific query range
    ///
    /// - Parameter queryRangeWidth: Width of the query range in seconds
    /// - Returns: Estimated selectivity (0.0-1.0)
    ///
    /// Formula: (queryWidth / avgRangeWidth) * overlapFactor * baseSelectivity
    public func estimateSelectivity(for queryRangeWidth: Double) -> Double {
        guard avgRangeWidth > 0 else { return selectivity }

        // Normalize query width relative to average
        let widthRatio = queryRangeWidth / avgRangeWidth

        // Apply overlap factor (more overlaps = higher selectivity)
        let rawSelectivity = widthRatio * overlapFactor * selectivity

        // Clamp to [0, 1]
        return min(max(rawSelectivity, 0.0), 1.0)
    }
}

// MARK: - CustomStringConvertible

extension RangeIndexStatistics: CustomStringConvertible {
    public var description: String {
        """
        RangeIndexStatistics(
            totalRecords: \(totalRecords),
            avgRangeWidth: \(String(format: "%.2f", avgRangeWidth))s,
            overlapFactor: \(String(format: "%.2f", overlapFactor)),
            selectivity: \(String(format: "%.4f", selectivity)),
            sampleSize: \(sampleSize),
            collectedAt: \(collectedAt)
        )
        """
    }
}
