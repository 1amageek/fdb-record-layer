import Foundation
import FoundationDB
import Logging
import Synchronization

/// Online index builder with batch transaction support and resume capability
///
/// Builds indexes without blocking writes to the record store.
/// Features:
/// - Batch processing: Each batch runs in its own transaction to respect FDB limits
/// - Resume capability: Can resume from interruptions using RangeSet
/// - State management: Automatically transitions index state through lifecycle
/// - Progress tracking: Reports progress and allows monitoring
/// - Throttling: Configurable delays between batches to reduce load
public final class OnlineIndexer: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let metaData: RecordMetaData
    private let index: Index
    private let serializer: any RecordSerializer<[String: Any]>
    private let indexStateManager: IndexStateManager
    private let rangeSet: RangeSet
    private let logger: Logger
    private let lock: Mutex<IndexBuildState>

    // MARK: - Configuration

    /// Number of records to process per transaction batch
    public let batchSize: Int

    /// Delay in milliseconds between batches (for throttling)
    public let throttleDelayMs: UInt64

    // MARK: - Build State

    private struct IndexBuildState {
        var totalRecordsScanned: UInt64 = 0
        var batchesProcessed: UInt64 = 0
        var startTime: Date?
        var endTime: Date?
        var currentRange: (begin: FDB.Bytes, end: FDB.Bytes)?
    }

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        index: Index,
        serializer: any RecordSerializer<[String: Any]>,
        indexStateManager: IndexStateManager,
        batchSize: Int = 1000,
        throttleDelayMs: UInt64 = 10,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.index = index
        self.serializer = serializer
        self.indexStateManager = indexStateManager
        self.batchSize = batchSize
        self.throttleDelayMs = throttleDelayMs
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.indexer")

        // Initialize RangeSet for tracking progress
        let rangeSetSubspace = subspace
            .subspace(RecordStoreKeyspace.indexRange.rawValue)
            .subspace(index.name)
        self.rangeSet = RangeSet(
            database: database,
            subspace: rangeSetSubspace,
            logger: logger
        )

        self.lock = Mutex(IndexBuildState())
    }

    // MARK: - Public Methods

    /// Build the index from scratch
    ///
    /// This method:
    /// 1. Transitions index to writeOnly state
    /// 2. Clears any previous progress
    /// 3. Builds the index in batches
    /// 4. Transitions index to readable state
    ///
    /// - Parameter clearFirst: If true, clears existing progress before starting
    public func buildIndex(clearFirst: Bool = false) async throws {
        lock.withLock { state in
            state.startTime = Date()
            state.totalRecordsScanned = 0
            state.batchesProcessed = 0
        }

        logger.info("Starting index build for: \(index.name)")

        // Step 1: Transition to writeOnly (if not already)
        let currentState = try await indexStateManager.state(of: index.name)
        if currentState == .disabled {
            try await indexStateManager.enable(index.name)
            logger.info("Transitioned index '\(index.name)' to writeOnly")
        }

        // Step 2: Clear progress if requested
        if clearFirst {
            try await rangeSet.clear()
            logger.info("Cleared previous build progress")
        }

        // Step 3: Build index in batches
        try await buildIndexInBatches()

        // Step 4: Transition to readable
        try await indexStateManager.makeReadable(index.name)
        logger.info("Transitioned index '\(index.name)' to readable")

        let (totalScanned, batchCount) = lock.withLock { state in
            state.endTime = Date()
            return (state.totalRecordsScanned, state.batchesProcessed)
        }

        logger.info("Index build completed for: \(index.name), scanned \(totalScanned) records in \(batchCount) batches")
    }

    /// Resume an interrupted index build
    ///
    /// Continues building from where the last build left off using RangeSet.
    public func resumeBuild() async throws {
        logger.info("Resuming index build for: \(index.name)")

        lock.withLock { state in
            state.startTime = Date()
        }

        // Build only the missing ranges
        try await buildIndexInBatches()

        // Transition to readable when complete
        try await indexStateManager.makeReadable(index.name)

        let (totalScanned, batchCount) = lock.withLock { state in
            state.endTime = Date()
            return (state.totalRecordsScanned, state.batchesProcessed)
        }

        logger.info("Index build resumed and completed: \(index.name), scanned \(totalScanned) records in \(batchCount) batches")
    }

    /// Get build progress
    ///
    /// - Returns: (records scanned, batches processed, estimated progress %)
    public func getProgress() async throws -> (recordsScanned: UInt64, batchesProcessed: UInt64, estimatedProgress: Double) {
        let (scanned, batches) = lock.withLock { state in
            (state.totalRecordsScanned, state.batchesProcessed)
        }

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let (fullBegin, fullEnd) = recordSubspace.range()
        let (_, progress) = try await rangeSet.getProgress(fullBegin: fullBegin, fullEnd: fullEnd)

        return (recordsScanned: scanned, batchesProcessed: batches, estimatedProgress: progress)
    }

    /// Cancel the current build and clear progress
    ///
    /// This allows restarting from scratch.
    public func cancel() async throws {
        try await rangeSet.clear()
        logger.info("Cancelled index build for: \(index.name)")
    }

    // MARK: - Private Methods

    /// Build index by processing batches in separate transactions
    private func buildIndexInBatches() async throws {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let (fullBegin, fullEnd) = recordSubspace.range()

        // Get missing ranges that need to be processed
        let missingRanges = try await rangeSet.missingRanges(fullBegin: fullBegin, fullEnd: fullEnd)

        if missingRanges.isEmpty {
            logger.info("No missing ranges - index is already complete")
            return
        }

        logger.info("Found \(missingRanges.count) missing ranges to process")

        // Process each missing range
        for (rangeIndex, range) in missingRanges.enumerated() {
            logger.debug("Processing range \(rangeIndex + 1)/\(missingRanges.count)")

            lock.withLock { state in
                state.currentRange = range
            }

            try await processRangeInBatches(begin: range.begin, end: range.end)

            // Throttle between ranges if configured
            if throttleDelayMs > 0 {
                try await Task.sleep(nanoseconds: throttleDelayMs * 1_000_000)
            }
        }
    }

    /// Process a single range in batches
    private func processRangeInBatches(begin: FDB.Bytes, end: FDB.Bytes) async throws {
        var currentBegin = begin
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        while currentBegin.lexicographicallyPrecedes(end) {
            // Process one batch in its own transaction
            let batchEnd = try await processSingleBatch(
                begin: currentBegin,
                end: end,
                recordSubspace: recordSubspace,
                indexSubspace: indexSubspace
            )

            // Mark this batch as complete
            try await database.withRecordContext { [rangeSet, currentBegin] context in
                try await rangeSet.insertRange(begin: currentBegin, end: batchEnd, context: context)
            }

            lock.withLock { state in
                state.batchesProcessed += 1
            }

            // Move to next batch
            currentBegin = batchEnd

            // Check if we've reached the end
            if !batchEnd.lexicographicallyPrecedes(end) || batchEnd == end {
                break
            }

            // Throttle between batches
            if throttleDelayMs > 0 {
                try await Task.sleep(nanoseconds: throttleDelayMs * 1_000_000)
            }
        }
    }

    /// Process a single batch in one transaction
    ///
    /// - Returns: The end key of the batch (exclusive)
    private func processSingleBatch(
        begin: FDB.Bytes,
        end: FDB.Bytes,
        recordSubspace: Subspace,
        indexSubspace: Subspace
    ) async throws -> FDB.Bytes {
        return try await database.withRecordContext { [weak self] context in
            guard let self = self else { throw RecordLayerError.contextAlreadyClosed }

            let transaction = context.getTransaction()
            var recordsInBatch = 0
            var lastKey = begin

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            for try await (key, value) in sequence {
                // Deserialize record
                let record = try self.serializer.deserialize(value)

                // Extract primary key
                let primaryKey = try recordSubspace.unpack(key)

                // Create index entry
                let maintainer = self.createIndexMaintainer(indexSubspace: indexSubspace)
                try await maintainer.scanRecord(record, primaryKey: primaryKey, transaction: transaction)

                recordsInBatch += 1
                lastKey = key

                // Stop after processing batchSize records
                if recordsInBatch >= self.batchSize {
                    break
                }
            }

            // Update statistics
            self.lock.withLock { state in
                state.totalRecordsScanned += UInt64(recordsInBatch)
            }

            self.logger.debug("Processed batch: \(recordsInBatch) records")

            // Return the next key position (one past last processed key)
            // If we processed any records, increment the last key
            if recordsInBatch > 0 {
                return self.incrementKey(lastKey)
            } else {
                // No records in this range - return end
                return end
            }
        }
    }

    /// Increment a key by one (for batch boundaries)
    private func incrementKey(_ key: FDB.Bytes) -> FDB.Bytes {
        var result = key

        // Add 0x00 byte to create the next key
        result.append(0x00)

        return result
    }

    private func createIndexMaintainer(indexSubspace: Subspace) -> any IndexMaintainer {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        switch index.type {
        case .value:
            return ValueIndexMaintainer(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
        case .count:
            return CountIndexMaintainer(
                index: index,
                subspace: indexSubspace
            )
        case .sum:
            return SumIndexMaintainer(
                index: index,
                subspace: indexSubspace
            )
        case .rank, .version, .permuted:
            fatalError("Index type \(index.type) not yet implemented")
        }
    }
}
