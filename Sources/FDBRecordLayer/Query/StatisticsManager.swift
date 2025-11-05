import Foundation
import FoundationDB
import Synchronization

/// Protocol for statistics management
///
/// **Thread Safety**: Implementations must be thread-safe and Sendable.
/// The recommended implementation uses Mutex for fine-grained locking.
public protocol StatisticsManagerProtocol: Sendable {
    func getTableStatistics(recordType: String) async throws -> TableStatistics?
    func getIndexStatistics(indexName: String) async throws -> IndexStatistics?
    func estimateSelectivity<Record: Sendable>(filter: any TypedQueryComponent<Record>, recordType: String) async throws -> Double
}

/// Manages statistics for cost-based query optimization
///
/// This class is responsible for:
/// - Collecting table and index statistics
/// - Building histograms for selectivity estimation
/// - Caching statistics for performance
/// - Persisting statistics to FoundationDB
///
/// **Thread Safety**: Uses Mutex for fine-grained locking of cache state.
/// - tableStats and indexStats have independent locks for better concurrency
/// - I/O operations are performed outside of locks to maximize parallelism
public final class StatisticsManager: StatisticsManagerProtocol, Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace

    // Statistics cache with independent locks for better concurrency
    private let tableStatsLock: Mutex<[String: TableStatistics]>
    private let indexStatsLock: Mutex<[String: IndexStatistics]>

    /// Storage keys for statistics
    private enum StatisticsKeyspace: String {
        case table = "table"
        case index = "index"
    }

    public init(database: any DatabaseProtocol, subspace: Subspace) {
        self.database = database
        self.subspace = subspace
        self.tableStatsLock = Mutex([:])
        self.indexStatsLock = Mutex([:])
    }

    // MARK: - Table Statistics

    /// Collect statistics for a record type
    ///
    /// - Parameters:
    ///   - recordType: The record type name
    ///   - sampleRate: Sampling rate (0.0-1.0), 1.0 = full scan
    public func collectStatistics(
        recordType: String,
        sampleRate: Double = 0.1
    ) async throws {
        // Input validation
        guard !recordType.isEmpty else {
            throw RecordLayerError.invalidArgument("recordType cannot be empty")
        }

        guard sampleRate > 0.0 && sampleRate <= 1.0 else {
            throw RecordLayerError.invalidArgument("sampleRate must be in range (0.0, 1.0], got \(sampleRate)")
        }

        // Scan records with sampling
        let (rowCount, totalSize, sampledCount) = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let recordSubspace = self.subspace.subspace(RecordStoreKeyspace.record.rawValue)
            let (begin, end) = recordSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            var localRowCount: Int64 = 0
            var localTotalSize: Int64 = 0
            var localSampledCount = 0

            for try await (key, value) in sequence {
                localRowCount += 1

                // Sample based on rate
                if Double.random(in: 0..<1) < sampleRate {
                    localTotalSize += Int64(key.count + value.count)
                    localSampledCount += 1
                }
            }

            return (localRowCount, localTotalSize, localSampledCount)
        }

        let avgRowSize = sampledCount > 0 ? Int(totalSize / Int64(sampledCount)) : 0

        let stats = TableStatistics(
            rowCount: rowCount,
            avgRowSize: avgRowSize,
            timestamp: Date(),
            sampleRate: sampleRate
        )

        try await saveTableStatistics(recordType: recordType, stats: stats)
    }

    /// Get table statistics
    ///
    /// **Thread Safety**: Short-lived lock for cache check, I/O outside lock.
    public func getTableStatistics(
        recordType: String
    ) async throws -> TableStatistics? {
        // Check cache with short-lived lock
        let cached = tableStatsLock.withLock { cache in
            return cache[recordType]
        }

        if let cached = cached {
            return cached
        }

        // Load from storage (I/O outside lock for better concurrency)
        guard let stats = try await loadTableStatistics(recordType: recordType) else {
            return nil
        }

        // Update cache with short-lived lock
        tableStatsLock.withLock { cache in
            cache[recordType] = stats
        }

        return stats
    }

    // MARK: - Index Statistics

    /// Collect index statistics with histogram using scalable algorithms
    ///
    /// Uses HyperLogLog for cardinality estimation and Reservoir Sampling
    /// for histogram construction. Memory usage is O(1) regardless of index size.
    ///
    /// - Parameters:
    ///   - indexName: The index name
    ///   - indexSubspace: The index subspace
    ///   - bucketCount: Number of histogram buckets (default: 100)
    ///   - reservoirSize: Size of reservoir sample (default: 10,000)
    public func collectIndexStatistics(
        indexName: String,
        indexSubspace: Subspace,
        bucketCount: Int = 100,
        reservoirSize: Int = 10_000
    ) async throws {
        // Input validation
        guard !indexName.isEmpty else {
            throw RecordLayerError.invalidArgument("indexName cannot be empty")
        }

        guard bucketCount > 0 && bucketCount <= 10000 else {
            throw RecordLayerError.invalidArgument("bucketCount must be in range (0, 10000], got \(bucketCount)")
        }

        guard reservoirSize > 0 && reservoirSize <= 100_000 else {
            throw RecordLayerError.invalidArgument("reservoirSize must be in range (0, 100000], got \(reservoirSize)")
        }

        // Scan index entries using HyperLogLog and Reservoir Sampling
        let (hll, sampler, nullCount, minValue, maxValue) = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = indexSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            var localHLL = HyperLogLog()
            var localSampler = ReservoirSampling(reservoirSize: reservoirSize)
            var localNullCount: Int64 = 0
            var localMinValue: ComparableValue?
            var localMaxValue: ComparableValue?

            for try await (key, _) in sequence {
                let tuple = try indexSubspace.unpack(key)
                // Try to access first element by subscript
                // If tuple is empty, skip this entry
                guard tuple.count > 0 else {
                    localNullCount += 1
                    continue
                }

                // Access first element by subscript
                guard let firstElement = tuple[0] else {
                    localNullCount += 1
                    continue
                }

                let value = ComparableValue(firstElement)

                // Add to HyperLogLog for cardinality estimation
                localHLL.add(value)

                // Add to Reservoir Sampler for histogram
                localSampler.add(value)

                // Track min/max
                if localMinValue == nil || value < localMinValue! {
                    localMinValue = value
                }
                if localMaxValue == nil || value > localMaxValue! {
                    localMaxValue = value
                }
            }

            return (localHLL, localSampler, localNullCount, localMinValue, localMaxValue)
        }

        // Estimate distinct values using HyperLogLog
        let distinctValues = hll.cardinality()

        // Build histogram from reservoir sample
        let histogram = sampler.buildHistogram(bucketCount: bucketCount)

        let stats = IndexStatistics(
            indexName: indexName,
            distinctValues: distinctValues,
            nullCount: nullCount,
            minValue: minValue,
            maxValue: maxValue,
            histogram: histogram,
            timestamp: Date()
        )

        try await saveIndexStatistics(indexName: indexName, stats: stats)
    }

    /// Get index statistics
    ///
    /// **Thread Safety**: Short-lived lock for cache check, I/O outside lock.
    public func getIndexStatistics(
        indexName: String
    ) async throws -> IndexStatistics? {
        // Check cache with short-lived lock
        let cached = indexStatsLock.withLock { cache in
            return cache[indexName]
        }

        if let cached = cached {
            return cached
        }

        // Load from storage (I/O outside lock for better concurrency)
        guard let stats = try await loadIndexStatistics(indexName: indexName) else {
            return nil
        }

        // Update cache with short-lived lock
        indexStatsLock.withLock { cache in
            cache[indexName] = stats
        }

        return stats
    }

    // MARK: - Selectivity Estimation

    /// Estimate selectivity of a filter condition
    ///
    /// - Parameters:
    ///   - filter: The filter condition
    ///   - recordType: The record type
    /// - Returns: Fraction of rows matching the condition (0.0-1.0)
    public func estimateSelectivity<Record: Sendable>(
        filter: any TypedQueryComponent<Record>,
        recordType: String
    ) async throws -> Double {
        // Field filter: use index statistics
        if let fieldFilter = filter as? TypedFieldQueryComponent<Record> {
            return try await estimateFieldSelectivity(fieldFilter, recordType: recordType)
        }

        // AND: multiply selectivities (independence assumption)
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            var selectivity = 1.0
            for child in andFilter.children {
                let childSelectivity = try await estimateSelectivity(
                    filter: child,
                    recordType: recordType
                )
                selectivity *= childSelectivity
            }
            return selectivity
        }

        // OR: 1 - product of (1 - selectivity)
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            var complement = 1.0
            for child in orFilter.children {
                let childSelectivity = try await estimateSelectivity(
                    filter: child,
                    recordType: recordType
                )
                complement *= (1.0 - childSelectivity)
            }
            return 1.0 - complement
        }

        // NOT: 1 - selectivity
        if let notFilter = filter as? TypedNotQueryComponent<Record> {
            let childSelectivity = try await estimateSelectivity(
                filter: notFilter.child,
                recordType: recordType
            )
            return 1.0 - childSelectivity
        }

        // Default: conservative estimate
        return 0.1
    }

    /// Estimate selectivity for a field filter
    private func estimateFieldSelectivity<Record: Sendable>(
        _ filter: TypedFieldQueryComponent<Record>,
        recordType: String
    ) async throws -> Double {
        // Try to find index statistics for this field
        // For simplicity, we look for an index with name matching the field
        let indexName = "\(recordType.lowercased())_\(filter.fieldName.lowercased())"

        guard let indexStats = try await getIndexStatistics(indexName: indexName),
              let histogram = indexStats.histogram else {
            // No statistics: use heuristic
            return estimateSelectivityHeuristic(comparison: filter.comparison)
        }

        // Use histogram to estimate selectivity
        let value = ComparableValue(filter.value)
        let histogramComparison = convertToHistogramComparison(filter.comparison)
        return histogram.estimateSelectivity(
            comparison: histogramComparison,
            value: value
        )
    }

    /// Convert TypedFieldQueryComponent.Comparison to Histogram Comparison
    private func convertToHistogramComparison<Record: Sendable>(
        _ comparison: TypedFieldQueryComponent<Record>.Comparison
    ) -> Comparison {
        switch comparison {
        case .equals: return .equals
        case .notEquals: return .notEquals
        case .lessThan: return .lessThan
        case .lessThanOrEquals: return .lessThanOrEquals
        case .greaterThan: return .greaterThan
        case .greaterThanOrEquals: return .greaterThanOrEquals
        case .startsWith: return .startsWith
        case .contains: return .contains
        }
    }

    /// Heuristic selectivity when no statistics available
    private func estimateSelectivityHeuristic<Record: Sendable>(
        comparison: TypedFieldQueryComponent<Record>.Comparison
    ) -> Double {
        switch comparison {
        case .equals:
            return 0.01  // 1% of rows
        case .notEquals:
            return 0.99
        case .lessThan, .lessThanOrEquals, .greaterThan, .greaterThanOrEquals:
            return 0.33  // Assume 1/3 of range
        case .startsWith:
            return 0.1   // 10% for prefix match
        case .contains:
            return 0.2   // 20% for substring match
        }
    }


    // MARK: - Private Helpers

    /// Get storage key for statistics
    private func statisticsKey(type: StatisticsKeyspace, name: String) -> FDB.Bytes {
        return subspace
            .subspace("statistics")
            .subspace(type.rawValue)
            .pack(Tuple(name))
    }

    /// Save table statistics
    private func saveTableStatistics(
        recordType: String,
        stats: TableStatistics
    ) async throws {
        let key = statisticsKey(type: .table, name: recordType)
        let data = try JSONEncoder().encode(stats)

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            transaction.setValue(Array(data), for: key)
        }

        // Update cache with short-lived lock
        tableStatsLock.withLock { cache in
            cache[recordType] = stats
        }
    }

    /// Load table statistics
    private func loadTableStatistics(
        recordType: String
    ) async throws -> TableStatistics? {
        let key = statisticsKey(type: .table, name: recordType)

        let stats: TableStatistics? = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            guard let bytes = try await transaction.getValue(for: key) else {
                return nil
            }
            return try JSONDecoder().decode(TableStatistics.self, from: Data(bytes))
        }

        // Update cache with short-lived lock
        if let stats = stats {
            tableStatsLock.withLock { cache in
                cache[recordType] = stats
            }
        }

        return stats
    }

    /// Save index statistics
    private func saveIndexStatistics(
        indexName: String,
        stats: IndexStatistics
    ) async throws {
        let key = statisticsKey(type: .index, name: indexName)
        let data = try JSONEncoder().encode(stats)

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            transaction.setValue(Array(data), for: key)
        }

        // Update cache with short-lived lock
        indexStatsLock.withLock { cache in
            cache[indexName] = stats
        }
    }

    /// Load index statistics
    private func loadIndexStatistics(
        indexName: String
    ) async throws -> IndexStatistics? {
        let key = statisticsKey(type: .index, name: indexName)

        let stats: IndexStatistics? = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            guard let bytes = try await transaction.getValue(for: key) else {
                return nil
            }
            return try JSONDecoder().decode(IndexStatistics.self, from: Data(bytes))
        }

        // Update cache with short-lived lock
        if let stats = stats {
            indexStatsLock.withLock { cache in
                cache[indexName] = stats
            }
        }

        return stats
    }

    // MARK: - Cache Management

    /// Clear statistics cache
    public func clearCache() {
        tableStatsLock.withLock { cache in
            cache.removeAll()
        }
        indexStatsLock.withLock { cache in
            cache.removeAll()
        }
    }

    /// Clear all statistics (cache and storage)
    public func clearAllStatistics() async throws {
        clearCache()

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let statsSubspace = self.subspace.subspace("statistics")
            let (begin, end) = statsSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }
}
