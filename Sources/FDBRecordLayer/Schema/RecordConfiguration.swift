import Foundation
import FoundationDB
import Logging

/// Record configuration (SwiftData-compatible)
///
/// Corresponds to SwiftData's ModelConfiguration:
/// - Schema definition
/// - FoundationDB cluster configuration
/// - In-memory only mode
/// - Statistics configuration
///
/// **Example usage**:
/// ```swift
/// let schema = Schema([User.self, Order.self])
/// let config = RecordConfiguration(
///     schema: schema,
///     clusterFilePath: "/etc/foundationdb/fdb.cluster",
///     isStoredInMemoryOnly: false
/// )
/// let container = try RecordContainer(configurations: [config])
/// ```
public struct RecordConfiguration: Sendable {

    // MARK: - Properties

    /// Schema
    public let schema: Schema

    /// FoundationDB API version (optional)
    ///
    /// If nil, assumes API version has already been selected globally.
    /// If specified, will attempt to select this version during initialization.
    /// Note: API version can only be selected once per process.
    public let apiVersion: Int32?

    /// Cluster file path (optional)
    public let clusterFilePath: String?

    /// In-memory only mode (no persistence)
    ///
    /// Note: Currently not implemented. Reserved for future use.
    public let isStoredInMemoryOnly: Bool

    /// Allow save (for read-only mode)
    ///
    /// Note: Currently not implemented. Reserved for future use.
    public let allowsSave: Bool

    /// Subspace for StatisticsManager (optional)
    public let statisticsSubspace: Subspace?

    /// MetricsRecorder (optional)
    public let metricsRecorder: (any MetricsRecorder)?

    /// Logger (optional)
    public let logger: Logger?

    // MARK: - Initialization

    /// Create record configuration (SwiftData-compatible)
    ///
    /// - Parameters:
    ///   - schema: Schema
    ///   - apiVersion: FoundationDB API version (default: nil = use already selected version)
    ///   - clusterFilePath: Cluster file path (default: nil)
    ///   - isStoredInMemoryOnly: In-memory only mode (default: false, not yet implemented)
    ///   - allowsSave: Allow save operations (default: true, not yet implemented)
    ///   - statisticsSubspace: Statistics subspace (default: nil)
    ///   - metricsRecorder: Metrics recorder (default: nil)
    ///   - logger: Logger (default: nil)
    ///
    /// **Example usage**:
    /// ```swift
    /// let schema = Schema([User.self, Order.self])
    /// let config = RecordConfiguration(schema: schema, isStoredInMemoryOnly: false)
    /// ```
    public init(
        schema: Schema,
        apiVersion: Int32? = nil,
        clusterFilePath: String? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        statisticsSubspace: Subspace? = nil,
        metricsRecorder: (any MetricsRecorder)? = nil,
        logger: Logger? = nil
    ) {
        self.schema = schema
        self.apiVersion = apiVersion
        self.clusterFilePath = clusterFilePath
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
        self.statisticsSubspace = statisticsSubspace
        self.metricsRecorder = metricsRecorder
        self.logger = logger
    }

    /// Convenience initializer - Create from types directly (SwiftData-compatible)
    ///
    /// **Example usage**:
    /// ```swift
    /// let config = RecordConfiguration(
    ///     for: User.self, Order.self,
    ///     isStoredInMemoryOnly: false
    /// )
    /// ```
    public init(
        for types: any Recordable.Type...,
        apiVersion: Int32? = nil,
        clusterFilePath: String? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        statisticsSubspace: Subspace? = nil,
        metricsRecorder: (any MetricsRecorder)? = nil,
        logger: Logger? = nil
    ) {
        let schema = Schema(types)
        self.init(
            schema: schema,
            apiVersion: apiVersion,
            clusterFilePath: clusterFilePath,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            allowsSave: allowsSave,
            statisticsSubspace: statisticsSubspace,
            metricsRecorder: metricsRecorder,
            logger: logger
        )
    }
}

// MARK: - CustomDebugStringConvertible

extension RecordConfiguration: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "RecordConfiguration(schema: \(schema), apiVersion: \(apiVersion?.description ?? "nil"), inMemory: \(isStoredInMemoryOnly))"
    }
}
