import Foundation

/// Null implementation of StatisticsManager for testing
///
/// This implementation provides no statistics and uses default selectivity estimates.
/// Useful for testing scenarios where statistics are not needed.
///
/// **Usage:**
/// ```swift
/// let statisticsManager = NullStatisticsManager()
/// let store = RecordStore(
///     database: database,
///     subspace: subspace,
///     metaData: metaData,
///     statisticsManager: statisticsManager
/// )
/// ```
public final class NullStatisticsManager: StatisticsManagerProtocol, Sendable {
    public init() {}

    public func getTableStatistics(recordType: String) async throws -> TableStatistics? {
        return nil
    }

    public func getIndexStatistics(indexName: String) async throws -> IndexStatistics? {
        return nil
    }

    public func estimateSelectivity<Record: Sendable>(
        filter: any TypedQueryComponent<Record>,
        recordType: String
    ) async throws -> Double {
        // Default selectivity: 10%
        // This is a conservative estimate used when no statistics are available
        return 0.1
    }
}
