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
///
/// **Generic Version**: Works with any record type through RecordAccess
public final class OnlineIndexer<Record: Sendable & Recordable>: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let schema: Schema
    private let entityName: String
    private let index: Index
    private let recordAccess: any RecordAccess<Record>
    private let indexStateManager: IndexStateManager
    private let rangeSetSubspace: Subspace
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
        schema: Schema,
        entityName: String,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        indexStateManager: IndexStateManager,
        batchSize: Int = 1000,
        throttleDelayMs: UInt64 = 10,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.schema = schema
        self.entityName = entityName
        self.index = index
        self.recordAccess = recordAccess
        self.indexStateManager = indexStateManager
        self.batchSize = batchSize
        self.throttleDelayMs = throttleDelayMs
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.indexer")

        // Store RangeSet subspace for later use
        self.rangeSetSubspace = subspace
            .subspace(RecordStoreKeyspace.indexRange.rawValue)
            .subspace(index.name)

        self.lock = Mutex(IndexBuildState())
    }

    /// Create a RangeSet instance for tracking progress
    private func createRangeSet() -> RangeSet {
        return RangeSet(
            database: self.database,
            subspace: self.rangeSetSubspace,
            logger: self.logger
        )
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
        // For HNSW-enabled vector indexes, delegate to buildHNSWIndex()
        if case .vector = index.type,
           index.options.vectorOptions != nil {
            // ✅ Read strategy from Schema (runtime configuration)
            let strategy = schema.getVectorStrategy(for: index.name)
            if case .hnsw = strategy {
                try await buildHNSWIndex(clearFirst: clearFirst)
                return
            }
        }

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
            try await createRangeSet().clear()
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
        let (_, progress) = try await createRangeSet().getProgress(fullBegin: fullBegin, fullEnd: fullEnd)

        return (recordsScanned: scanned, batchesProcessed: batches, estimatedProgress: progress)
    }

    /// Cancel the current build and clear progress
    ///
    /// This allows restarting from scratch.
    public func cancel() async throws {
        try await createRangeSet().clear()
        logger.info("Cancelled index build for: \(index.name)")
    }

    // MARK: - Private Methods

    /// Build index by processing batches in separate transactions
    private func buildIndexInBatches() async throws {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let (fullBegin, fullEnd) = recordSubspace.range()

        // Get missing ranges that need to be processed
        let rangeSet = createRangeSet()
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
        let rangeSet = createRangeSet()

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
        return try await database.withRecordContext { context in
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
                let record = try self.recordAccess.deserialize(value)

                // Extract primary key
                let primaryKey = try recordSubspace.unpack(key)

                // Create index entry
                let maintainer = try self.createIndexMaintainer(indexSubspace: indexSubspace)
                try await maintainer.scanRecord(
                    record,
                    primaryKey: primaryKey,
                    recordAccess: self.recordAccess,
                    transaction: transaction
                )

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

    private func createIndexMaintainer(indexSubspace: Subspace) throws -> AnyGenericIndexMaintainer<Record> {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        switch index.type {
        case .value:
            let maintainer = GenericValueIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .count:
            let maintainer = GenericCountIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .sum:
            let maintainer = GenericSumIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .min:
            let maintainer = GenericMinIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .max:
            let maintainer = GenericMaxIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .version:
            let maintainer = VersionIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .rank:
            return try createRankIndexMaintainer(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )

        case .permuted:
            do {
                let maintainer = try GenericPermutedIndexMaintainer<Record>(
                    index: index,
                    subspace: indexSubspace,
                    recordSubspace: recordSubspace
                )
                return AnyGenericIndexMaintainer(maintainer)
            } catch {
                logger.error("Failed to create permuted index maintainer for '\(index.name)': \(error)")
                throw RecordLayerError.internalError("Invalid permuted index configuration for '\(index.name)': \(error)")
            }

        case .vector:
            // Select maintainer based on vector index strategy from Schema
            guard index.options.vectorOptions != nil else {
                throw RecordLayerError.invalidArgument("Vector index requires vectorOptions")
            }

            // ✅ Read strategy from Schema (runtime configuration)
            // Separates data structure (VectorIndexOptions) from runtime optimization (IndexConfiguration)
            let strategy = schema.getVectorStrategy(for: index.name)

            switch strategy {
            case .flatScan:
                // Flat scan: O(n) search, lower memory
                do {
                    let maintainer = try GenericVectorIndexMaintainer<Record>(
                        index: index,
                        subspace: indexSubspace,
                        recordSubspace: recordSubspace
                    )
                    return AnyGenericIndexMaintainer(maintainer)
                } catch {
                    logger.error("Failed to create flat vector index maintainer for '\(index.name)': \(error)")
                    throw RecordLayerError.internalError("Invalid vector index configuration for '\(index.name)': \(error)")
                }

            case .hnsw:
                // HNSW: O(log n) search, higher memory
                do {
                    let maintainer = try GenericHNSWIndexMaintainer<Record>(
                        index: index,
                        subspace: indexSubspace,
                        recordSubspace: recordSubspace
                    )
                    return AnyGenericIndexMaintainer(maintainer)
                } catch {
                    logger.error("Failed to create HNSW index maintainer for '\(index.name)': \(error)")
                    throw RecordLayerError.internalError("Invalid HNSW index configuration for '\(index.name)': \(error)")
                }
            }

        case .spatial:
            // NOTE: Spatial index support temporarily disabled during transition to S2-based design
            // Will be re-implemented in Phase 2.6: SpatialIndexMetadata implementation
            // See: docs/spatial-indexing-complete-design.md
            logger.error("Spatial index type is currently not supported for '\(index.name)'")
            throw RecordLayerError.internalError(
                "Spatial index type is currently not supported. Use Value index with computed S2CellID property instead."
            )
        }
    }

    // MARK: - HNSW-Specific Build Methods

    /// Build HNSW index using level-by-level processing
    ///
    /// This specialized build method handles HNSW vector indexes to stay within
    /// FoundationDB transaction limits (~5 seconds, 10MB).
    ///
    /// **Two-Phase Process**:
    /// 1. **Phase 1**: Assign levels to all nodes (~10 operations per node)
    /// 2. **Phase 2**: Build graph level-by-level (~3,000 operations per level per node)
    ///
    /// **Transaction Budget**:
    /// - Phase 1: Very lightweight, completes quickly
    /// - Phase 2: Each level processed in separate transaction batches
    ///
    /// - Parameter clearFirst: If true, clears existing progress before starting
    public func buildHNSWIndex(clearFirst: Bool = false) async throws {
        guard case .vector = index.type else {
            throw RecordLayerError.internalError("buildHNSWIndex() can only be called for vector indexes")
        }

        lock.withLock { state in
            state.startTime = Date()
            state.totalRecordsScanned = 0
            state.batchesProcessed = 0
        }

        logger.info("Starting HNSW index build for: \(index.name)")

        // Step 1: Transition to writeOnly (if not already)
        let currentState = try await indexStateManager.state(of: index.name)
        if currentState == .disabled {
            try await indexStateManager.enable(index.name)
            logger.info("Transitioned index '\(index.name)' to writeOnly")
        }

        // Step 2: Clear progress if requested
        if clearFirst {
            try await createRangeSet().clear()
            logger.info("Cleared previous build progress")
        }

        // Step 3: Phase 1 - Assign levels to all nodes
        logger.info("HNSW Phase 1: Assigning levels to all nodes")
        try await assignLevelsToAllNodes()

        // Step 4: Phase 2 - Build graph level-by-level
        logger.info("HNSW Phase 2: Building graph level-by-level")
        try await buildHNSWGraphLevelByLevel()

        // Step 5: Transition to readable
        try await indexStateManager.makeReadable(index.name)
        logger.info("Transitioned index '\(index.name)' to readable")

        let (totalScanned, batchCount) = lock.withLock { state in
            state.endTime = Date()
            return (state.totalRecordsScanned, state.batchesProcessed)
        }

        logger.info("HNSW index build completed for: \(index.name), scanned \(totalScanned) records in \(batchCount) batches")
    }

    /// Phase 1: Assign levels to all nodes (lightweight operation)
    private func assignLevelsToAllNodes() async throws {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let (fullBegin, fullEnd) = recordSubspace.range()
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        var currentBegin = fullBegin
        var totalAssigned: UInt64 = 0

        while currentBegin.lexicographicallyPrecedes(fullEnd) {
            let batchEnd = try await assignLevelsForBatch(
                begin: currentBegin,
                end: fullEnd,
                recordSubspace: recordSubspace,
                indexSubspace: indexSubspace
            )

            totalAssigned += UInt64(batchSize)
            logger.debug("Assigned levels for \(totalAssigned) nodes")

            // Move to next batch
            currentBegin = batchEnd

            if !batchEnd.lexicographicallyPrecedes(fullEnd) || batchEnd == fullEnd {
                break
            }

            // Throttle between batches
            if throttleDelayMs > 0 {
                try await Task.sleep(nanoseconds: throttleDelayMs * 1_000_000)
            }
        }

        logger.info("Phase 1 complete: Assigned levels to \(totalAssigned) nodes")
    }

    /// Assign levels for a single batch
    private func assignLevelsForBatch(
        begin: FDB.Bytes,
        end: FDB.Bytes,
        recordSubspace: Subspace,
        indexSubspace: Subspace
    ) async throws -> FDB.Bytes {
        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            var recordsInBatch = 0
            var lastKey = begin

            // Create HNSW maintainer
            guard let hnswMaintainer = try? GenericHNSWIndexMaintainer<Record>(
                index: self.index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            ) else {
                throw RecordLayerError.internalError("Failed to create HNSW maintainer")
            }

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            for try await (key, _) in sequence {
                // Extract primary key
                let primaryKey = try recordSubspace.unpack(key)

                // Assign level (lightweight: ~10 operations)
                _ = try await hnswMaintainer.assignLevel(
                    primaryKey: primaryKey,
                    transaction: transaction
                )

                recordsInBatch += 1
                lastKey = key

                if recordsInBatch >= self.batchSize {
                    break
                }
            }

            self.logger.debug("Assigned levels for batch: \(recordsInBatch) records")

            if recordsInBatch > 0 {
                return self.incrementKey(lastKey)
            } else {
                return end
            }
        }
    }

    /// Phase 2: Build graph level-by-level
    private func buildHNSWGraphLevelByLevel() async throws {
        // First, determine the maximum level across all nodes
        let maxLevel = try await findMaxLevel()
        logger.info("Maximum level in graph: \(maxLevel)")

        // Build each level from highest to lowest
        for level in stride(from: maxLevel, through: 0, by: -1) {
            logger.info("Building level \(level)")
            try await buildSingleLevel(level: level)
        }
    }

    /// Find the maximum level across all nodes
    private func findMaxLevel() async throws -> Int {
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        guard let hnswMaintainer = try? GenericHNSWIndexMaintainer<Record>(
            index: self.index,
            subspace: indexSubspace,
            recordSubspace: subspace.subspace(RecordStoreKeyspace.record.rawValue)
        ) else {
            throw RecordLayerError.internalError("Failed to create HNSW maintainer")
        }

        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            return try await hnswMaintainer.getMaxLevel(transaction: transaction)
        }
    }

    /// Build a single level of the HNSW graph
    private func buildSingleLevel(level: Int) async throws {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let (fullBegin, fullEnd) = recordSubspace.range()
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        var currentBegin = fullBegin
        var totalInserted: UInt64 = 0

        while currentBegin.lexicographicallyPrecedes(fullEnd) {
            let batchEnd = try await insertLevelForBatch(
                level: level,
                begin: currentBegin,
                end: fullEnd,
                recordSubspace: recordSubspace,
                indexSubspace: indexSubspace
            )

            totalInserted += UInt64(batchSize)

            // Move to next batch
            currentBegin = batchEnd

            if !batchEnd.lexicographicallyPrecedes(fullEnd) || batchEnd == fullEnd {
                break
            }

            // Throttle between batches
            if throttleDelayMs > 0 {
                try await Task.sleep(nanoseconds: throttleDelayMs * 1_000_000)
            }
        }

        logger.info("Level \(level) complete: Inserted \(totalInserted) nodes")
    }

    /// Insert nodes at a specific level for a single batch
    private func insertLevelForBatch(
        level: Int,
        begin: FDB.Bytes,
        end: FDB.Bytes,
        recordSubspace: Subspace,
        indexSubspace: Subspace
    ) async throws -> FDB.Bytes {
        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            var recordsInBatch = 0
            var lastKey = begin

            // Create HNSW maintainer
            guard let hnswMaintainer = try? GenericHNSWIndexMaintainer<Record>(
                index: self.index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            ) else {
                throw RecordLayerError.internalError("Failed to create HNSW maintainer")
            }

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            for try await (key, value) in sequence {
                // Extract primary key
                let primaryKey = try recordSubspace.unpack(key)

                // Check if this node has a level >= current level
                if let metadata = try await hnswMaintainer.getNodeMetadata(
                    primaryKey: primaryKey,
                    transaction: transaction,
                    snapshot: false
                ) {
                    if metadata.level >= level {
                        // Deserialize record to extract vector
                        let record = try self.recordAccess.deserialize(value)
                        let vector = try hnswMaintainer.extractVector(from: record, recordAccess: self.recordAccess)

                        // Insert at this level (~3,000 operations)
                        try await hnswMaintainer.insertAtLevel(
                            primaryKey: primaryKey,
                            queryVector: vector,
                            targetLevel: level,
                            transaction: transaction
                        )
                    }
                }

                recordsInBatch += 1
                lastKey = key

                if recordsInBatch >= self.batchSize {
                    break
                }
            }

            self.logger.debug("Inserted level \(level) for batch: \(recordsInBatch) records")

            if recordsInBatch > 0 {
                return self.incrementKey(lastKey)
            } else {
                return end
            }
        }
    }
}
