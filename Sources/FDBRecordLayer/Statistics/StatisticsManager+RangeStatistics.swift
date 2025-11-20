import Foundation
import FoundationDB

/// Range Statistics Extension for StatisticsManager
///
/// Provides Range-specific statistics collection and selectivity estimation
/// for cost-based query optimization.
///
/// **Key Features**:
/// - Collect Range index statistics (avgRangeWidth, overlapFactor, selectivity)
/// - Estimate selectivity for Range overlap queries
/// - Cache Range statistics for performance
/// - Support for Date-based Range indexes
///
/// **Usage**:
/// ```swift
/// // Collect statistics for a Range index
/// try await statisticsManager.collectRangeStatistics(
///     index: eventPeriodIndex,
///     indexSubspace: indexSubspace,
///     sampleRate: 0.1  // Sample 10% of records
/// )
///
/// // Estimate selectivity for a query range
/// let selectivity = try await statisticsManager.estimateRangeSelectivity(
///     indexName: "event_by_period",
///     queryRange: Date()..< Date().addingTimeInterval(86400)
/// )
/// ```
extension StatisticsManager {

    // MARK: - Storage Keys

    /// Get storage key for Range statistics
    private func rangeStatisticsKey(indexName: String) -> FDB.Bytes {
        return subspace
            .subspace("statistics")
            .subspace("range")
            .pack(Tuple(indexName))
    }

    // MARK: - Range Statistics Collection

    /// Collect statistics for a Range index
    ///
    /// Collects the following metrics:
    /// - Total number of records
    /// - Average range width (duration in seconds for Date ranges)
    /// - Overlap factor (average number of overlapping ranges)
    /// - Base selectivity (estimated typical query selectivity)
    ///
    /// **Algorithm**:
    /// 1. Scan index entries with sampling
    /// 2. Extract Range values (lowerBound, upperBound)
    /// 3. Calculate average range width
    /// 4. Sample overlap points and count overlaps
    /// 5. Estimate base selectivity from overlap distribution
    ///
    /// - Parameters:
    ///   - index: The Range index to collect statistics for
    ///   - indexSubspace: The index subspace
    ///   - sampleRate: Sampling rate (0.0-1.0), default 0.1 (10%)
    /// - Throws: RecordLayerError if collection fails
    public func collectRangeStatistics(
        index: Index,
        indexSubspace: Subspace,
        sampleRate: Double = 0.1
    ) async throws {
        // Input validation
        guard index.type == .value else {
            throw RecordLayerError.invalidArgument("Index must be of type .value for Range statistics")
        }

        guard sampleRate > 0.0 && sampleRate <= 1.0 else {
            throw RecordLayerError.invalidArgument("sampleRate must be in range (0.0, 1.0], got \(sampleRate)")
        }

        // Scan index entries and collect Range metrics
        let (totalRecords, totalWidth, sampleCount, overlapSamples) = try await database.withTransactionContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = indexSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            var localTotalRecords: UInt64 = 0
            var localTotalWidth: Double = 0
            var localSampleCount: UInt64 = 0
            var ranges: [(lowerBound: Date, upperBound: Date)] = []

            // First pass: collect range samples
            for try await (key, _) in sequence {
                localTotalRecords += 1

                // Sample based on rate
                if Double.random(in: 0..<1) < sampleRate {
                    let tuple = try indexSubspace.unpack(key)

                    // Extract Range bounds (assuming first two elements are lowerBound, upperBound)
                    // Note: Tuple encodes Date as Double (timeIntervalSince1970)
                    guard tuple.count >= 2,
                          let lowerBoundDouble = tuple[0] as? Double,
                          let upperBoundDouble = tuple[1] as? Double else {
                        continue
                    }

                    let lowerBound = Date(timeIntervalSince1970: lowerBoundDouble)
                    let upperBound = Date(timeIntervalSince1970: upperBoundDouble)

                    let width = upperBound.timeIntervalSince(lowerBound)
                    localTotalWidth += width
                    localSampleCount += 1

                    ranges.append((lowerBound: lowerBound, upperBound: upperBound))
                }
            }

            // Second pass: calculate overlap factor
            // Sample representative points and count overlaps
            var overlapCounts: [Int] = []
            let maxSamplePoints = min(100, ranges.count)

            for _ in 0..<maxSamplePoints {
                guard !ranges.isEmpty else { break }

                // Pick a random range
                let sampleRange = ranges.randomElement()!

                // Pick a random point within that range
                let totalInterval = sampleRange.upperBound.timeIntervalSince(sampleRange.lowerBound)
                let randomOffset = Double.random(in: 0...totalInterval)
                let samplePoint = sampleRange.lowerBound.addingTimeInterval(randomOffset)

                // Count how many ranges overlap this point
                var overlapCount = 0
                for range in ranges {
                    if range.lowerBound <= samplePoint && samplePoint < range.upperBound {
                        overlapCount += 1
                    }
                }

                overlapCounts.append(overlapCount)
            }

            return (localTotalRecords, localTotalWidth, localSampleCount, overlapCounts)
        }

        // Calculate statistics
        let avgRangeWidth = sampleCount > 0 ? totalWidth / Double(sampleCount) : 0
        let avgOverlapFactor = overlapSamples.isEmpty ? 1.0 : Double(overlapSamples.reduce(0, +)) / Double(overlapSamples.count)

        // Estimate base selectivity
        // Formula: selectivity ≈ 1 / (overlapFactor * sqrt(totalRecords))
        let baseSelectivity = totalRecords > 0 ? min(1.0 / (avgOverlapFactor * sqrt(Double(totalRecords))), 1.0) : 0.5

        let stats = RangeIndexStatistics(
            totalRecords: totalRecords,
            avgRangeWidth: avgRangeWidth,
            overlapFactor: avgOverlapFactor,
            selectivity: baseSelectivity,
            collectedAt: Date(),
            sampleSize: sampleCount
        )

        // Save statistics
        try await saveRangeStatistics(indexName: index.name, stats: stats)
    }

    // MARK: - Range Statistics Retrieval

    /// Get Range statistics for an index
    ///
    /// - Parameter indexName: The index name
    /// - Returns: Range statistics, or nil if not collected
    public func getRangeStatistics(indexName: String) async throws -> RangeIndexStatistics? {
        try await loadRangeStatistics(indexName: indexName)
    }

    /// Load Range statistics from storage (internal helper)
    ///
    /// - Parameter indexName: The index name
    /// - Returns: Range statistics, or nil if not collected
    internal func loadRangeStatistics(indexName: String) async throws -> RangeIndexStatistics? {
        let key = rangeStatisticsKey(indexName: indexName)

        return try await database.withTransactionContext { context in
            let transaction = context.getTransaction()
            guard let bytes = try await transaction.getValue(for: key, snapshot: true) else {
                return nil as RangeIndexStatistics?
            }
            return try JSONDecoder().decode(RangeIndexStatistics.self, from: Data(bytes))
        }
    }

    /// Save Range statistics to storage (internal helper)
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - stats: The statistics to save
    internal func saveRangeStatistics(
        indexName: String,
        stats: RangeIndexStatistics
    ) async throws {
        let key = rangeStatisticsKey(indexName: indexName)
        let data = try JSONEncoder().encode(stats)

        try await database.withTransactionContext { context in
            let transaction = context.getTransaction()
            transaction.setValue(Array(data), for: key)
        }
    }

    // MARK: - Range Selectivity Estimation

    /// Estimate selectivity for a Range overlap query
    ///
    /// Uses collected statistics to estimate what fraction of records
    /// will match a Range overlap query.
    ///
    /// **Formula**:
    /// ```
    /// selectivity = (queryWidth / avgRangeWidth) * overlapFactor * baseSelectivity
    /// ```
    ///
    /// **Example**:
    /// ```swift
    /// // Index: avgRangeWidth = 86400s (1 day), overlapFactor = 5.2
    /// // Query: 1-week range
    /// let selectivity = try await estimateRangeSelectivity(
    ///     indexName: "event_by_period",
    ///     queryRange: Date()..<Date().addingTimeInterval(7 * 86400)
    /// )
    /// // → selectivity ≈ (7 * 86400 / 86400) * 5.2 * 0.01 ≈ 0.364 (36%)
    /// ```
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - queryRange: The query range
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: Range<Date>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            // No statistics: use conservative default
            return 0.5
        }

        // Calculate query range width
        let queryWidth = queryRange.upperBound.timeIntervalSince(queryRange.lowerBound)

        // Use statistics to estimate selectivity
        return stats.estimateSelectivity(for: queryWidth)
    }

    /// Estimate selectivity for a PartialRangeFrom query
    ///
    /// For unbounded upper ranges, selectivity depends on:
    /// - Position of lowerBound relative to data distribution
    /// - Overlap factor
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - queryRange: The query range (lowerBound...)
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: PartialRangeFrom<Date>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5
        }

        // For unbounded upper range, assume it covers avgRangeWidth * overlapFactor
        // This is a conservative estimate
        let effectiveWidth = stats.avgRangeWidth * stats.overlapFactor
        return stats.estimateSelectivity(for: effectiveWidth)
    }

    /// Estimate selectivity for a PartialRangeThrough query
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - queryRange: The query range (...upperBound)
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: PartialRangeThrough<Date>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5
        }

        // Similar to PartialRangeFrom
        let effectiveWidth = stats.avgRangeWidth * stats.overlapFactor
        return stats.estimateSelectivity(for: effectiveWidth)
    }

    /// Estimate selectivity for a PartialRangeUpTo query
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - queryRange: The query range (..<upperBound)
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: PartialRangeUpTo<Date>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5
        }

        let effectiveWidth = stats.avgRangeWidth * stats.overlapFactor
        return stats.estimateSelectivity(for: effectiveWidth)
    }

    // MARK: - Generic Comparable Type Support (Phase 4)

    /// Estimate selectivity for a Range<Int> query
    ///
    /// Converts Int range to Double width and uses the same estimation logic.
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - queryRange: The query range (Int)
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: Range<Int>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5
        }

        // Convert Int range width to Double
        let queryWidth = Double(queryRange.upperBound - queryRange.lowerBound)
        return stats.estimateSelectivity(for: queryWidth)
    }

    /// Estimate selectivity for a Range<Int64> query
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - queryRange: The query range (Int64)
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: Range<Int64>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5
        }

        let queryWidth = Double(queryRange.upperBound - queryRange.lowerBound)
        return stats.estimateSelectivity(for: queryWidth)
    }

    /// Estimate selectivity for a Range<Double> query
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - queryRange: The query range (Double)
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        queryRange: Range<Double>
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5
        }

        let queryWidth = queryRange.upperBound - queryRange.lowerBound
        return stats.estimateSelectivity(for: queryWidth)
    }

    /// Estimate selectivity for a generic Range query (any Comparable type)
    ///
    /// This method accepts range boundaries as `any Comparable` and calculates selectivity
    /// based on the numeric width. It handles all supported Comparable types.
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - lowerBound: The lower bound of the query range
    ///   - upperBound: The upper bound of the query range
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateRangeSelectivity(
        indexName: String,
        lowerBound: any Comparable,
        upperBound: any Comparable
    ) async throws -> Double {
        guard let stats = try await getRangeStatistics(indexName: indexName) else {
            return 0.5
        }

        // Calculate query width based on type
        let queryWidth: Double

        if let lower = lowerBound as? Date, let upper = upperBound as? Date {
            queryWidth = upper.timeIntervalSince(lower)
        } else if let lower = lowerBound as? Int, let upper = upperBound as? Int {
            queryWidth = Double(upper - lower)
        } else if let lower = lowerBound as? Int64, let upper = upperBound as? Int64 {
            queryWidth = Double(upper - lower)
        } else if let lower = lowerBound as? Int32, let upper = upperBound as? Int32 {
            queryWidth = Double(upper - lower)
        } else if let lower = lowerBound as? Double, let upper = upperBound as? Double {
            queryWidth = upper - lower
        } else if let lower = lowerBound as? Float, let upper = upperBound as? Float {
            queryWidth = Double(upper - lower)
        } else {
            // Unsupported type: return conservative default
            return 0.5
        }

        // Use statistics to estimate selectivity
        return stats.estimateSelectivity(for: queryWidth)
    }
}
