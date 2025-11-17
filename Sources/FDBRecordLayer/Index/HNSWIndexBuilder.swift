import Foundation
import FoundationDB
import Synchronization

// MARK: - Build Options

/// Configuration options for HNSW index building
///
/// Controls batch processing, throttling, and resource management during
/// HNSW index construction.
///
/// **Example**:
/// ```swift
/// let options = HNSWBuildOptions(
///     batchSize: 500,
///     throttleDelayMs: 20,
///     clearFirst: true,
///     concurrency: 2
/// )
/// let builder = HNSWIndexBuilder(store: store, indexName: "embedding_hnsw")
/// try await builder.build(options: options)
/// ```
public struct HNSWBuildOptions: Sendable, Codable {
    /// Number of records to process per batch (default: 1000)
    ///
    /// **Constraints**: Must respect FDB transaction limits:
    /// - Transaction size ≤ 10MB
    /// - Transaction time ≤ 5 seconds
    ///
    /// **Tuning**:
    /// - Small datasets (< 10K): 500-1000
    /// - Large datasets (> 100K): 100-500
    /// - High-dimensional vectors: reduce to avoid size limit
    public var batchSize: Int = 1000

    /// Delay in milliseconds between batches (default: 10ms)
    ///
    /// **Purpose**: Rate limiting to avoid overwhelming FDB cluster
    ///
    /// **Tuning**:
    /// - Low cluster load: 0-10ms
    /// - High cluster load: 50-100ms
    /// - Shared cluster: 20-50ms
    public var throttleDelayMs: UInt64 = 10

    /// Whether to clear existing index before building (default: false)
    ///
    /// **Use cases**:
    /// - `true`: Rebuild from scratch (e.g., corruption recovery)
    /// - `false`: Resume interrupted build
    public var clearFirst: Bool = false

    /// Dry run mode - validate without writing (default: false)
    ///
    /// **Purpose**:
    /// - Estimate build time and resource usage
    /// - Validate record compatibility
    /// - Test configuration before production build
    ///
    /// **Note**: Still creates a transaction but rolls back at the end
    public var dryRun: Bool = false

    /// Number of concurrent build workers (default: 1)
    ///
    /// **Purpose**: Parallel processing for large datasets
    ///
    /// **Constraints**:
    /// - Each worker uses separate FDB connection
    /// - Memory usage scales linearly with concurrency
    /// - Recommended max: 4-8 workers
    ///
    /// **Note**: Currently not implemented (Phase 1 limitation)
    public var concurrency: Int = 1

    /// Timeout in seconds (default: 0 = no timeout)
    ///
    /// **Purpose**: Prevent runaway builds
    ///
    /// **Recommended**:
    /// - Small datasets: 300s (5 min)
    /// - Large datasets: 3600s (1 hour)
    /// - Very large: 0 (no timeout)
    public var timeoutSeconds: Int = 0

    /// Optional notification endpoint for progress updates (default: nil)
    ///
    /// **Purpose**: Send progress updates to external monitoring system
    ///
    /// **Format**: HTTP endpoint expecting POST with JSON body:
    /// ```json
    /// {
    ///   "phase": "graphConstruction",
    ///   "progress": 0.75,
    ///   "statistics": { ... }
    /// }
    /// ```
    ///
    /// **Note**: Currently not implemented (Phase 3)
    public var notificationEndpoint: String? = nil

    /// Resource usage limit as fraction of available resources (default: 0.8)
    ///
    /// **Purpose**: Prevent memory exhaustion during build
    ///
    /// **Range**: 0.0 - 1.0
    /// - 0.5: Conservative (50% of available memory)
    /// - 0.8: Balanced (recommended)
    /// - 1.0: Aggressive (use all available memory)
    ///
    /// **Note**: Currently not enforced (Phase 1 limitation)
    public var resourceLimit: Double = 0.8

    /// Initialize with default values
    public init(
        batchSize: Int = 1000,
        throttleDelayMs: UInt64 = 10,
        clearFirst: Bool = false,
        dryRun: Bool = false,
        concurrency: Int = 1,
        timeoutSeconds: Int = 0,
        notificationEndpoint: String? = nil,
        resourceLimit: Double = 0.8
    ) {
        self.batchSize = batchSize
        self.throttleDelayMs = throttleDelayMs
        self.clearFirst = clearFirst
        self.dryRun = dryRun
        self.concurrency = concurrency
        self.timeoutSeconds = timeoutSeconds
        self.notificationEndpoint = notificationEndpoint
        self.resourceLimit = resourceLimit
    }
}

// MARK: - Build Phase

/// Phases of HNSW index construction
///
/// **Phase 1: Level Assignment**
/// - Scan all records
/// - Assign HNSW levels using exponential distribution
/// - Store level assignments
/// - Complexity: O(n)
///
/// **Phase 2: Graph Construction**
/// - Build HNSW graph level-by-level (top to bottom)
/// - For each node at each level, find nearest neighbors
/// - Connect nodes with bidirectional edges
/// - Complexity: O(n log n) amortized
///
/// **Note**: Level assignment must complete before graph construction
public enum BuildPhase: Sendable, Codable, Equatable {
    /// Assigning HNSW levels to all nodes
    ///
    /// **Progress**: Fraction of records processed (0.0 - 1.0)
    case levelAssignment

    /// Building HNSW graph for a specific level
    ///
    /// **Parameters**:
    /// - `level`: Current level being processed (0 = bottom layer)
    /// - `totalLevels`: Maximum level in the graph
    ///
    /// **Progress**: Calculated as:
    /// ```
    /// (level + nodeFraction) / totalLevels
    /// ```
    case graphConstruction(level: Int, totalLevels: Int)

    /// Human-readable description
    public var description: String {
        switch self {
        case .levelAssignment:
            return "Level Assignment"
        case .graphConstruction(let level, let total):
            return "Graph Construction (Level \(level)/\(total))"
        }
    }
}

// MARK: - Range Checkpoint

/// Checkpoint for pause/resume functionality
///
/// Records the state of an interrupted build to enable resumption.
///
/// **Use cases**:
/// 1. **Graceful shutdown**: Save checkpoint, resume later
/// 2. **Error recovery**: Resume from last checkpoint after transient error
/// 3. **Progress tracking**: Monitor build progress over time
///
/// **Example**:
/// ```swift
/// // Save checkpoint on interruption
/// let checkpoint = RangeCheckpoint(
///     lastCompletedKey: currentKey,
///     phase: .graphConstruction(level: 2, totalLevels: 5),
///     processedRecords: 50000,
///     timestamp: Date()
/// )
/// try await saveCheckpoint(checkpoint, transaction: transaction)
///
/// // Resume from checkpoint
/// let builder = HNSWIndexBuilder(store: store, indexName: "embedding_hnsw")
/// let stats = try await builder.resume(from: checkpoint)
/// ```
public struct RangeCheckpoint: Sendable, Codable {
    /// Last record key successfully processed
    ///
    /// **Format**: FDB key bytes from record subspace
    ///
    /// **Usage**: Resume will start from `lastCompletedKey + 1`
    public let lastCompletedKey: FDB.Bytes

    /// Build phase when checkpoint was created
    ///
    /// **Purpose**: Resume at correct phase and level
    public let phase: BuildPhase

    /// Number of records processed so far
    ///
    /// **Purpose**: Progress calculation and ETA estimation
    public let processedRecords: Int

    /// Timestamp when checkpoint was created
    ///
    /// **Purpose**: Checkpoint age tracking and cleanup
    public let timestamp: Date

    public init(
        lastCompletedKey: FDB.Bytes,
        phase: BuildPhase,
        processedRecords: Int,
        timestamp: Date
    ) {
        self.lastCompletedKey = lastCompletedKey
        self.phase = phase
        self.processedRecords = processedRecords
        self.timestamp = timestamp
    }
}

// MARK: - Build Statistics

/// Statistics collected during HNSW index building
///
/// Provides real-time metrics for monitoring and optimization.
///
/// **Example**:
/// ```swift
/// let stats = try await builder.build(options: options)
/// print("Processed \(stats.processedRecords) / \(stats.totalRecords) records")
/// print("Elapsed: \(stats.elapsedTime)s, Throughput: \(stats.throughput) rec/s")
/// if let eta = stats.estimatedTimeRemaining {
///     print("ETA: \(eta)s")
/// }
/// print("Memory usage: \(stats.memoryUsage / 1024 / 1024) MB")
/// if let maxLevel = stats.maxLevel {
///     print("Max HNSW level: \(maxLevel)")
/// }
/// ```
public struct BuildStatistics: Sendable, Codable {
    /// Total number of records to process
    public let totalRecords: Int

    /// Number of records processed so far
    public let processedRecords: Int

    /// Elapsed time in seconds
    public let elapsedTime: TimeInterval

    /// Estimated time remaining in seconds (nil if cannot estimate)
    ///
    /// **Calculation**: `(totalRecords - processedRecords) / throughput`
    ///
    /// **Note**: Only available after processing at least 100 records
    public let estimatedTimeRemaining: TimeInterval?

    /// Memory usage in bytes
    ///
    /// **Note**: Currently reports process memory, not build-specific memory
    public let memoryUsage: UInt64

    /// Maximum HNSW level assigned (nil during level assignment)
    ///
    /// **Purpose**: Indicates graph height and search complexity
    ///
    /// **Typical values**:
    /// - Small dataset (< 1K): 2-4
    /// - Medium dataset (1K - 100K): 4-6
    /// - Large dataset (> 100K): 6-8
    public let maxLevel: Int?

    /// Processing throughput (records per second)
    ///
    /// **Calculation**: `processedRecords / elapsedTime`
    ///
    /// **Typical values**:
    /// - Level assignment: 1000-5000 rec/s
    /// - Graph construction: 100-500 rec/s (depends on dimensionality)
    public var throughput: Double {
        elapsedTime > 0 ? Double(processedRecords) / elapsedTime : 0
    }

    /// Progress percentage (0.0 - 100.0)
    public var progressPercentage: Double {
        totalRecords > 0 ? Double(processedRecords) / Double(totalRecords) * 100.0 : 0
    }

    public init(
        totalRecords: Int,
        processedRecords: Int,
        elapsedTime: TimeInterval,
        estimatedTimeRemaining: TimeInterval? = nil,
        memoryUsage: UInt64,
        maxLevel: Int? = nil
    ) {
        self.totalRecords = totalRecords
        self.processedRecords = processedRecords
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.memoryUsage = memoryUsage
        self.maxLevel = maxLevel
    }
}

// MARK: - Build State

/// State machine for HNSW index building
///
/// **State transitions**:
/// ```
/// notStarted → running → completed
///            ↓         ↓
///            ↓       paused → running
///            ↓         ↓
///            ↓       failed
///            ↓         ↓
///            └─────────┘
/// ```
///
/// **Thread safety**: State transitions are protected by Mutex in HNSWIndexBuilder
public enum BuildState: Sendable {
    /// Build has not started
    case notStarted

    /// Build is in progress
    ///
    /// **Parameters**:
    /// - `phase`: Current build phase
    /// - `progress`: Progress within current phase (0.0 - 1.0)
    case running(phase: BuildPhase, progress: Double)

    /// Build is paused (can be resumed)
    ///
    /// **Parameter**:
    /// - `checkpoint`: Checkpoint for resuming
    case paused(checkpoint: RangeCheckpoint)

    /// Build completed successfully
    ///
    /// **Parameter**:
    /// - `stats`: Final statistics
    case completed(stats: BuildStatistics)

    /// Build failed with error
    ///
    /// **Parameters**:
    /// - `error`: Error that caused failure
    /// - `checkpoint`: Checkpoint for retry
    case failed(error: Error, checkpoint: RangeCheckpoint)

    /// Human-readable description
    public var description: String {
        switch self {
        case .notStarted:
            return "Not Started"
        case .running(let phase, let progress):
            return "Running: \(phase.description) (\(Int(progress * 100))%)"
        case .paused(let checkpoint):
            return "Paused at \(checkpoint.phase.description)"
        case .completed(let stats):
            return "Completed (\(stats.processedRecords) records)"
        case .failed(let error, _):
            return "Failed: \(error.localizedDescription)"
        }
    }

    /// Whether the build can be resumed
    public var canResume: Bool {
        switch self {
        case .paused, .failed:
            return true
        default:
            return false
        }
    }
}

// MARK: - HNSW Index Builder

/// Service layer for manual HNSW index building
///
/// Provides safe, observable HNSW index construction separate from
/// RecordStore.save() operations.
///
/// **Architecture**:
/// - **Service Layer** (HNSWIndexBuilder): State management, error handling, observability
/// - **Execution Layer** (OnlineIndexer): Actual graph building, RangeSet, transaction handling
///
/// **Use cases**:
/// 1. **Initial index build**: Build HNSW index for existing data
/// 2. **Rebuild after corruption**: Clear and rebuild index from scratch
/// 3. **Resume interrupted build**: Continue from last checkpoint
///
/// **Example**:
/// ```swift
/// let builder = HNSWIndexBuilder(
///     store: store,
///     indexName: "product_embedding_hnsw"
/// )
///
/// // Configure options
/// let options = HNSWBuildOptions(
///     batchSize: 500,
///     throttleDelayMs: 20,
///     clearFirst: true
/// )
///
/// // Build with progress monitoring
/// let stats = try await builder.build(options: options)
/// print("Completed: \(stats.processedRecords) records in \(stats.elapsedTime)s")
/// ```
///
/// **Thread safety**: Uses `final class + Mutex` pattern for state management
public final class HNSWIndexBuilder<Record: Recordable>: Sendable {
    // MARK: - Properties

    private let store: RecordStore<Record>
    private let indexName: String
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let schema: Schema

    /// Protected mutable state
    private let stateLock: Mutex<BuildState>

    /// Start time for elapsed time calculation
    private let startTimeLock: Mutex<Date?>

    /// OnlineIndexer instance (active during build() execution)
    ///
    /// **Purpose**: Allow createCheckpoint() and buildFinalStatistics() to access indexer
    ///
    /// **Lifecycle**:
    /// - Set to non-nil at start of build()
    /// - Accessed by createCheckpoint() and buildFinalStatistics()
    /// - Set back to nil in defer block at end of build()
    private let indexerLock: Mutex<OnlineIndexer<Record>?>

    // MARK: - Initialization

    /// Initialize HNSW index builder
    ///
    /// - Parameters:
    ///   - store: RecordStore containing records to index
    ///   - indexName: Name of HNSW index to build
    ///
    /// - Throws: RecordLayerError.indexNotFound if index doesn't exist in schema
    public init(store: RecordStore<Record>, indexName: String) throws {
        self.store = store
        self.indexName = indexName
        self.database = store.database
        self.schema = store.schema
        self.stateLock = Mutex(.notStarted)
        self.startTimeLock = Mutex(nil)
        self.indexerLock = Mutex(nil)

        // Validate index exists and is a vector index
        guard let index = schema.indexes(for: Record.recordName).first(where: { $0.name == indexName }) else {
            throw RecordLayerError.indexNotFound("Index '\(indexName)' not found in schema for record type '\(Record.recordName)'")
        }

        guard index.type == .vector else {
            throw RecordLayerError.invalidArgument("Index '\(indexName)' is not a vector index (type: \(index.type))")
        }

        // Validate HNSW strategy is configured
        let strategy = schema.getVectorStrategy(for: indexName)
        guard case .hnsw = strategy else {
            throw RecordLayerError.invalidArgument("Index '\(indexName)' does not use HNSW strategy (current: \(strategy))")
        }
    }

    // MARK: - Public API

    /// Get current build state
    ///
    /// **Thread-safe**: Can be called concurrently with build()
    ///
    /// - Returns: Current BuildState
    public func getState() -> BuildState {
        return stateLock.withLock { $0 }
    }

    /// Build HNSW index with specified options
    ///
    /// **Process**:
    /// 1. Validate state (must be notStarted or paused)
    /// 2. Set index to writeOnly state
    /// 3. Clear existing data if requested
    /// 4. Execute build via OnlineIndexer
    /// 5. Set index to readable state on success
    /// 6. Save checkpoint on failure
    ///
    /// **Transaction limits**: Respects FDB constraints:
    /// - Each batch ≤ 5 seconds
    /// - Each batch ≤ 10MB
    /// - Uses RangeSet for progress tracking
    ///
    /// - Parameter options: Build configuration
    /// - Returns: Build statistics on completion
    /// - Throws: RecordLayerError on failure
    public func build(options: HNSWBuildOptions = .init()) async throws -> BuildStatistics {
        // 1. Validate state
        try validateStateForBuild()

        // 2. Record start time
        startTimeLock.withLock { $0 = Date() }

        // 3. Dry run check
        if options.dryRun {
            return try await performDryRun(options: options)
        }

        // 4. Create RecordAccess and IndexStateManager
        let recordAccess = GenericRecordAccess<Record>()
        let indexStateManager = IndexStateManager(database: database, subspace: store.indexSubspace)

        // 5. Set index state to writeOnly
        try await indexStateManager.enable(indexName)

        // 6. Clear existing data if requested
        if options.clearFirst {
            try await clearExistingIndex()
        }

        // 7. Get index object
        guard let index = schema.indexes(for: Record.recordName).first(where: { $0.name == indexName }) else {
            throw RecordLayerError.indexNotFound("Index '\(indexName)' not found in schema")
        }

        // 8. Create OnlineIndexer
        let indexer = OnlineIndexer(
            database: database,
            subspace: store.subspace,
            schema: schema,
            entityName: Record.recordName,
            index: index,
            recordAccess: recordAccess,
            indexStateManager: indexStateManager,
            batchSize: options.batchSize,
            throttleDelayMs: options.throttleDelayMs
        )

        // Store indexer in instance variable for checkpoint and statistics access
        indexerLock.withLock { $0 = indexer }

        // Ensure indexer is cleared when build() exits
        defer {
            indexerLock.withLock { $0 = nil }
        }

        do {
            // Execute build with progress callback
            try await indexer.buildHNSWIndex(
                clearFirst: false,  // Already cleared above if needed
                progressCallback: { [weak self] phase, progress in
                    self?.updateProgress(phase: phase, progress: progress)
                }
            )

            // Set index state to readable
            try await indexStateManager.makeReadable(indexName)

            // 8. Calculate final statistics
            let stats = try await buildFinalStatistics()

            // 9. Update state to completed
            stateLock.withLock { $0 = .completed(stats: stats) }

            return stats

        } catch {
            // Save checkpoint for resume
            let checkpoint = try await createCheckpoint()
            stateLock.withLock { $0 = .failed(error: error, checkpoint: checkpoint) }
            throw error
        }
    }

    /// Resume interrupted build from checkpoint
    ///
    /// **Note**: Currently not implemented (Phase 1 limitation)
    /// OnlineIndexer uses RangeSet internally for resume capability.
    ///
    /// - Parameter checkpoint: Checkpoint to resume from
    /// - Returns: Build statistics on completion
    /// - Throws: RecordLayerError on failure
    public func resume(from checkpoint: RangeCheckpoint) async throws -> BuildStatistics {
        throw RecordLayerError.internalError("Resume functionality not yet implemented in Phase 1")
    }

    /// Cancel running build
    ///
    /// **Note**: Currently not implemented (Phase 1 limitation)
    /// Future implementation will:
    /// 1. Set cancellation flag
    /// 2. Wait for current batch to complete
    /// 3. Save checkpoint
    /// 4. Set state to paused
    ///
    /// - Throws: RecordLayerError if not running
    public func cancel() async throws {
        throw RecordLayerError.internalError("Cancel functionality not yet implemented in Phase 1")
    }

    // MARK: - Private Helpers

    /// Validate state allows starting a build
    private func validateStateForBuild() throws {
        let state = stateLock.withLock { $0 }
        switch state {
        case .notStarted, .paused:
            // Valid states for starting build
            break
        case .running:
            throw RecordLayerError.internalError("Build already in progress")
        case .completed:
            throw RecordLayerError.internalError("Build already completed. Use clearFirst option to rebuild.")
        case .failed:
            throw RecordLayerError.internalError("Previous build failed. Use resume() to continue or clearFirst to rebuild.")
        }
    }

    /// Perform dry run validation
    private func performDryRun(options: HNSWBuildOptions) async throws -> BuildStatistics {
        // Estimate total records
        let totalRecords = try await estimateTotalRecords()

        // Estimate time based on typical throughput
        let estimatedTime = Double(totalRecords) / 1000.0  // Assume 1000 rec/s

        return BuildStatistics(
            totalRecords: totalRecords,
            processedRecords: 0,
            elapsedTime: 0,
            estimatedTimeRemaining: estimatedTime,
            memoryUsage: 0,
            maxLevel: nil
        )
    }

    /// Clear existing index data
    private func clearExistingIndex() async throws {
        try await database.withTransaction { transaction in
            let indexSubspace = self.store.indexSubspace.subspace(self.indexName)
            let (begin, end) = indexSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    /// Update progress during build
    private func updateProgress(phase: BuildPhase, progress: Double) {
        stateLock.withLock { state in
            state = .running(phase: phase, progress: progress)
        }
    }

    /// Create checkpoint for current state
    private func createCheckpoint() async throws -> RangeCheckpoint {
        // Get current state
        let state = stateLock.withLock { $0 }

        guard case .running(let phase, _) = state else {
            throw RecordLayerError.internalError("Cannot create checkpoint: not running")
        }

        // Get indexer from instance variable
        guard let indexer = indexerLock.withLock({ $0 }) else {
            throw RecordLayerError.internalError("Cannot create checkpoint: indexer not available")
        }

        // Get actual values from OnlineIndexer
        let (lastKey, processedCount, _) = try await indexer.getCurrentCheckpoint()

        return RangeCheckpoint(
            lastCompletedKey: lastKey,
            phase: phase,
            processedRecords: processedCount,
            timestamp: Date()
        )
    }

    /// Build final statistics
    private func buildFinalStatistics() async throws -> BuildStatistics {
        let totalRecords = try await estimateTotalRecords()
        let elapsedTime = startTimeLock.withLock { startTime in
            startTime.map { Date().timeIntervalSince($0) } ?? 0
        }

        // Get memory usage
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let memoryUsage = kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0

        // Get max level from HNSW index via indexer
        let maxLevel: Int?
        if let indexer = indexerLock.withLock({ $0 }) {
            let (_, _, level) = try await indexer.getCurrentCheckpoint()
            maxLevel = level
        } else {
            maxLevel = nil
        }

        return BuildStatistics(
            totalRecords: totalRecords,
            processedRecords: totalRecords,
            elapsedTime: elapsedTime,
            estimatedTimeRemaining: 0,
            memoryUsage: memoryUsage,
            maxLevel: maxLevel
        )
    }

    /// Estimate total number of records
    private func estimateTotalRecords() async throws -> Int {
        var count = 0
        for try await _ in store.scan() {
            count += 1
        }
        return count
    }
}
