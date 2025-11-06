import Foundation
import FoundationDB
import Logging
import Metrics
import Synchronization

// MARK: - OnlineIndexScrubber

/// Online index scrubber for detecting and repairing index inconsistencies
///
/// **Design Decisions (based on code review)**:
/// 1. **Factory Method Pattern**: Uses `create()` instead of async init
///    - Reason: Swift doesn't support async initializers
/// 2. **VALUE Index Only**: Phase 1 supports only VALUE index type
///    - COUNT/SUM/RANK require specialized repair logic (future implementation)
/// 3. **Separate RangeSets**: Phase 1 and Phase 2 use separate progress tracking
///    - Prevents mixing progress between phases during resumption
/// 4. **Multi-Type Support**: Scans each record type separately
///    - Avoids scanning irrelevant record types
/// 5. **Size/Time Failsafe**: Multiple limits to prevent transaction timeouts
///    - entriesScanLimit, maxTransactionBytes, transactionTimeoutMillis
/// 6. **KeyExpression Reuse**: Uses same logic as IndexMaintainer
///    - Ensures consistency with index maintenance
///
/// **Thread Safety**: This class is Sendable and uses Mutex for state synchronization.
public final class OnlineIndexScrubber<Record: Sendable>: Sendable {

    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let schema: Schema
    private let index: Index
    private let recordAccess: any RecordAccess<Record>
    private let configuration: ScrubberConfiguration

    // MARK: - Metrics & Logging

    private let logger: Logger
    private let baseDimensions: [(String, String)]

    // Counters (monotonically increasing)
    private let entriesScannedCounter: Counter
    private let recordsScannedCounter: Counter
    private let danglingEntriesCounter: Counter
    private let missingEntriesCounter: Counter

    // Timers
    private let batchDurationTimer: Timer

    // Gauge (current progress ratio)
    private let progressGauge: Gauge

    // Recorder (for batch size distribution)
    private let batchSizeRecorder: Recorder

    // MARK: - Mutable State (protected by Mutex)

    /// Progress tracking state protected by Mutex for thread-safe access
    private let statelock: Mutex<ScrubberState>

    private struct ScrubberState {
        var batchCount: Int = 0
        var totalScannedSoFar: Int = 0
    }

    // MARK: - Private Initialization

    /// Private initializer - use create() factory method instead
    private init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        configuration: ScrubberConfiguration
    ) {
        self.database = database
        self.subspace = subspace
        self.schema = schema
        self.index = index
        self.recordAccess = recordAccess
        self.configuration = configuration

        // Initialize logger
        self.logger = Logger(label: "com.apple.foundationdb.recordlayer.scrubber")

        // Base dimensions for all metrics
        self.baseDimensions = [
            ("index", index.name),
            ("type", index.type.rawValue)
        ]

        // Initialize all metrics using Metrics factory API
        // Note: dimensions are passed as an array of tuples
        self.entriesScannedCounter = Counter(
            label: "fdb_scrubber_entries_scanned_total",
            dimensions: baseDimensions + [("phase", "index_scan")]
        )
        self.recordsScannedCounter = Counter(
            label: "fdb_scrubber_entries_scanned_total",
            dimensions: baseDimensions + [("phase", "record_scan")]
        )
        self.danglingEntriesCounter = Counter(
            label: "fdb_scrubber_issues_total",
            dimensions: baseDimensions + [("phase", "phase1"), ("issue_type", "dangling_entry")]
        )
        self.missingEntriesCounter = Counter(
            label: "fdb_scrubber_issues_total",
            dimensions: baseDimensions + [("phase", "phase2"), ("issue_type", "missing_entry")]
        )

        // Timer for batch duration
        self.batchDurationTimer = Timer(
            label: "fdb_scrubber_batch_duration_seconds",
            dimensions: baseDimensions
        )

        // Gauge for progress ratio (0.0-1.0)
        self.progressGauge = Gauge(
            label: "fdb_scrubber_progress_ratio",
            dimensions: baseDimensions
        )

        // Recorder for batch size distribution
        self.batchSizeRecorder = Recorder(
            label: "fdb_scrubber_batch_size",
            dimensions: baseDimensions,
            aggregate: true
        )

        // Initialize mutable state with Mutex
        self.statelock = Mutex(ScrubberState())
    }

    // MARK: - Factory Method

    /// Create and validate a new index scrubber
    ///
    /// - Parameters:
    ///   - database: FoundationDB database
    ///   - subspace: Record store subspace
    ///   - schema: Schema definition
    ///   - index: Index to scrub
    ///   - recordAccess: Record access for field extraction
    ///   - configuration: Scrubber configuration
    /// - Returns: Validated scrubber instance
    /// - Throws: RecordLayerError if validation fails
    public static func create(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        index: Index,
        recordAccess: any RecordAccess<Record>,
        configuration: ScrubberConfiguration = .default
    ) async throws -> OnlineIndexScrubber<Record> {
        // Validate index type
        guard configuration.supportedTypes.contains(index.type) else {
            throw RecordLayerError.invalidArgument(
                "Index type '\(index.type)' is not supported for scrubbing. " +
                "Supported types: \(configuration.supportedTypes.map { $0.rawValue }.joined(separator: ", "))"
            )
        }

        // Validate index state (must be readable for scrubbing)
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        let indexState = try await indexStateManager.state(of: index.name)

        guard indexState == .readable else {
            throw RecordLayerError.indexNotReady(
                "Index '\(index.name)' must be readable for scrubbing (current state: \(indexState))"
            )
        }

        return OnlineIndexScrubber(
            database: database,
            subspace: subspace,
            schema: schema,
            index: index,
            recordAccess: recordAccess,
            configuration: configuration
        )
    }

    // MARK: - Public API

    /// Scrub the entire index
    ///
    /// Performs a full scan of both index entries and records to detect
    /// and optionally repair any inconsistencies.
    ///
    /// **Error Handling**: This method never throws. Instead, errors are captured
    /// in `ScrubberResult.error` and partial progress is available in `ScrubberResult.summary`.
    ///
    /// - Returns: Scrubbing result with statistics, health status, and optional error
    public func scrubIndex() async -> ScrubberResult {
        let startTime = Date()

        // Reset progress tracking state
        statelock.withLock { state in
            state.batchCount = 0
            state.totalScannedSoFar = 0
        }

        // Initialize progress tracking
        let progress = initializeProgress()

        // Track partial progress for error reporting
        var indexEntriesScanned = 0
        var recordsScanned = 0
        var phase1Issues: [ScrubberIssue] = []
        var phase2Issues: [ScrubberIssue] = []

        do {
            // Phase 1: Scan index entries for dangling entries
            (phase1Issues, indexEntriesScanned) = try await scrubIndexEntries(progress: progress)

            // Phase 2: Scan records for missing entries
            (phase2Issues, recordsScanned) = try await scrubRecords(progress: progress)

            let timeElapsed = Date().timeIntervalSince(startTime)

            // Calculate result statistics
            let danglingDetected = phase1Issues.filter { $0.type == .danglingEntry }.count
            let danglingRepaired = phase1Issues.filter { $0.type == .danglingEntry && $0.repaired }.count
            let missingDetected = phase2Issues.filter { $0.type == .missingEntry }.count
            let missingRepaired = phase2Issues.filter { $0.type == .missingEntry && $0.repaired }.count

            // Create summary with detailed breakdown
            let summary = ScrubberSummary(
                timeElapsed: timeElapsed,
                entriesScanned: indexEntriesScanned,
                recordsScanned: recordsScanned,
                danglingEntriesDetected: danglingDetected,
                danglingEntriesRepaired: danglingRepaired,
                missingEntriesDetected: missingDetected,
                missingEntriesRepaired: missingRepaired,
                indexName: index.name
            )

            let isHealthy = summary.issuesDetected == 0

            logger.info("Scrubber completed successfully", metadata: [
                "index": "\(index.name)",
                "healthy": "\(isHealthy)",
                "entries_scanned": "\(indexEntriesScanned)",
                "records_scanned": "\(recordsScanned)",
                "issues_detected": "\(summary.issuesDetected)"
            ])

            return ScrubberResult(
                isHealthy: isHealthy,
                completedSuccessfully: true,
                summary: summary,
                terminationReason: nil
            )
        } catch {
            // ✅ Handle failure: Return partial result with error
            let timeElapsed = Date().timeIntervalSince(startTime)

            let danglingDetected = phase1Issues.filter { $0.type == .danglingEntry }.count
            let danglingRepaired = phase1Issues.filter { $0.type == .danglingEntry && $0.repaired }.count
            let missingDetected = phase2Issues.filter { $0.type == .missingEntry }.count
            let missingRepaired = phase2Issues.filter { $0.type == .missingEntry && $0.repaired }.count

            let partialSummary = ScrubberSummary(
                timeElapsed: timeElapsed,
                entriesScanned: indexEntriesScanned,
                recordsScanned: recordsScanned,
                danglingEntriesDetected: danglingDetected,
                danglingEntriesRepaired: danglingRepaired,
                missingEntriesDetected: missingDetected,
                missingEntriesRepaired: missingRepaired,
                indexName: index.name
            )

            logger.error("Scrubber terminated with error", metadata: [
                "index": "\(index.name)",
                "partial_entries_scanned": "\(indexEntriesScanned)",
                "partial_records_scanned": "\(recordsScanned)",
                "partial_issues_detected": "\(partialSummary.issuesDetected)",
                "partial_issues_repaired": "\(partialSummary.issuesRepaired)",
                "time_elapsed": "\(String(format: "%.2f", timeElapsed))s",
                "error": "\(error.safeDescription)"
            ])

            // Return partial result with error information
            return ScrubberResult(
                isHealthy: false,
                completedSuccessfully: false,
                summary: partialSummary,
                terminationReason: error.localizedDescription,
                error: error
            )
        }
    }

    // MARK: - Progress Tracking

    /// Initialize progress tracking with separate RangeSets for Phase 1 and Phase 2
    private func initializeProgress() -> ScrubberProgress {
        let progressSubspace = subspace
            .subspace(RecordStoreKeyspace.indexBuild.rawValue)
            .subspace(index.name)
            .subspace("scrubber")

        return ScrubberProgress(
            progressSubspace: progressSubspace,
            phase1RangeSet: RangeSet(database: database, subspace: progressSubspace.subspace("phase1")),
            phase2RangeSet: RangeSet(database: database, subspace: progressSubspace.subspace("phase2"))
        )
    }

    // MARK: - Helper Methods

    /// Get the next key after the given key (for RangeSet boundaries and continuations)
    ///
    /// **Purpose**:
    /// 1. **RangeSet boundaries**: RangeSet uses half-open intervals `[from, to)`, so `to` is exclusive.
    ///    When marking a range as complete, we need to pass the key AFTER the last processed key.
    /// 2. **Batch continuations**: To avoid re-reading the last key of the previous batch.
    ///
    /// **Implementation**: Appends a single `0x00` byte to get the next key.
    /// This is equivalent to FoundationDB's `firstGreaterThan(key)` selector.
    ///
    /// - Parameter key: The last processed key
    /// - Returns: The next key (lastKey + 0x00)
    private func nextKey(after key: FDB.Bytes) -> FDB.Bytes {
        // Append a single 0x00 byte to get the next key
        // This is equivalent to FoundationDB's firstGreaterThan(key) selector
        return key + [0x00]
    }

    /// Record skip metrics with phase and reason labels
    ///
    /// **Design**: Creates Counter on-demand with appropriate dimensions for observability
    ///
    /// - Parameters:
    ///   - phase: Phase identifier ("phase1" or "phase2")
    ///   - reason: Skip reason (e.g., "oversized_key", "tuple_decode_failure")
    private func recordSkip(phase: String, reason: String) {
        Counter(
            label: "fdb_scrubber_skipped_total",
            dimensions: baseDimensions + [("phase", phase), ("reason", reason)]
        ).increment()
    }

    // MARK: - Phase 1: Index Entries Scan

    /// Scan all index entries and check if corresponding records exist
    ///
    /// **Algorithm**:
    /// 1. Get index key range
    /// 2. Iterate through index entries in batches
    /// 3. For each index entry:
    ///    a. Extract primary key from index key
    ///    b. Check if corresponding record exists in each record type
    ///    c. If not, log dangling entry
    ///    d. If allowRepair, delete dangling entry
    ///
    /// - Returns: Tuple of (issues, totalScanned)
    private func scrubIndexEntries(progress: ScrubberProgress) async throws -> ([ScrubberIssue], Int) {
        logger.info("Starting Phase 1: Index→Record validation", metadata: [
            "index": "\(index.name)",
            "type": "\(index.type.rawValue)"
        ])

        // ✅ Use index.subspaceTupleKey (consistent with TypedQueryPlan and OnlineIndexer)
        let indexSubspace = subspace
            .subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        // ✅ Get record types for this index (needed to check each record type)
        let recordNames: [String]
        if let indexRecordTypes = index.recordTypes {
            recordNames = Array(indexRecordTypes)
        } else {
            // Universal index - applies to all entities
            recordNames = Array(schema.entitiesByName.keys)
        }

        let (beginKey, endKey) = indexSubspace.range()
        var continuation: FDB.Bytes? = beginKey
        var allIssues: [ScrubberIssue] = []
        var totalScanned = 0
        var warningCount = 0

        while let currentKey = continuation {
            if configuration.enableProgressLogging {
                logger.debug("Processing batch", metadata: [
                    "key": "\(currentKey.safeLogRepresentation)"
                ])
            }

            // 📊 Record batch start time for duration measurement
            let batchStartTime = Date()

            var retryCount = 0
            var batchSucceeded = false

            // ✅ CORRECT RETRY LOGIC: Create new transaction for each retry
            while !batchSucceeded && retryCount <= configuration.maxRetries {
                let context = try RecordContext(database: database)
                // Note: No need for defer { context.cancel() } - RecordContext.deinit handles cleanup

                do {
                    let (nextContinuation, batchIssues, batchEndKey, scannedCount) = try await scrubIndexEntriesBatch(
                        context: context,
                        indexSubspace: indexSubspace,
                        recordSubspace: recordSubspace,
                        recordNames: recordNames,
                        startKey: currentKey,
                        endKey: endKey,
                        warningCount: &warningCount
                    )

                    // ✅ FIX (Issue 2): Update progress with next key after lastKey
                    // RangeSet uses [from, to) half-open interval, so 'to' must be AFTER the last processed key
                    if let lastKey = batchEndKey {
                        let rangeEnd = nextKey(after: lastKey)
                        try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
                    }

                    // ✅ ATOMICITY FIX: Commit FIRST
                    try await context.commit()

                    // ✅ Then record issues (only if commit succeeded)
                    allIssues.append(contentsOf: batchIssues)
                    totalScanned += scannedCount

                    // 📊 Record metrics (batched - once per batch instead of per entry)
                    entriesScannedCounter.increment(by: Int64(scannedCount))

                    // Count and record issues by type
                    let danglingCount = batchIssues.filter { $0.type == .danglingEntry }.count
                    if danglingCount > 0 {
                        danglingEntriesCounter.increment(by: Int64(danglingCount))
                    }

                    batchSizeRecorder.record(Int64(scannedCount))

                    // 📊 Record batch duration
                    let batchDuration = Date().timeIntervalSince(batchStartTime)
                    batchDurationTimer.recordSeconds(batchDuration)

                    // 📊 Progress tracking strategy:
                    // - Update progress gauge only every 10 batches (accurate RangeSet progress)
                    let (currentBatch, _) = statelock.withLock { state in
                        state.batchCount += 1
                        state.totalScannedSoFar += scannedCount
                        return (state.batchCount, state.totalScannedSoFar)
                    }

                    // 📊 Update progress gauge only every 10 batches (accurate RangeSet progress)
                    if currentBatch % 10 == 0 {
                        let accurateProgress = try await progress.getAccurateProgress(
                            phase: .phase1InProgress,
                            fullBegin: beginKey,
                            fullEnd: endKey
                        )
                        progressGauge.record(accurateProgress)

                        logger.info("Phase 1 accurate progress check", metadata: [
                            "batch": "\(currentBatch)",
                            "progress": "\(String(format: "%.2f", accurateProgress * 100))%"
                        ])
                    }

                    if configuration.enableProgressLogging {
                        logger.info("Phase 1 batch complete", metadata: [
                            "scanned": "\(scannedCount)",
                            "issues": "\(batchIssues.count)"
                        ])
                    }

                    continuation = nextContinuation
                    batchSucceeded = true

                } catch let error as FDBError where error.code == 2101 {
                    // ✅ INFINITE LOOP FIX: transaction_too_large - skip oversized key
                    // This is NOT retryable - we must skip the key and continue
                    logger.warning("Oversized key detected, skipping", metadata: [
                        "key": "\(currentKey.safeLogRepresentation)",
                        "error_code": "2101",
                        "phase": "phase1"
                    ])

                    // 📊 Record skip metric with phase and reason
                    recordSkip(phase: "phase1", reason: "oversized_key")

                    let skipKey = nextKey(after: currentKey)

                    // Retry logic for skip commit (separate from main batch retry)
                    var skipRetryCount = 0
                    var skipCommitted = false

                    while !skipCommitted && skipRetryCount <= configuration.maxRetries {
                        let skipContext = try RecordContext(database: database)
                        // Note: No need for defer - RecordContext.deinit handles cleanup

                        do {
                            try await progress.markPhase1Range(from: currentKey, to: skipKey, context: skipContext)
                            try await skipContext.commit()
                            skipCommitted = true

                        } catch let skipError as FDBError where skipError.isRetryable {
                            skipRetryCount += 1
                            if skipRetryCount > configuration.maxRetries {
                                logger.error("Skip commit retry exhausted", metadata: [
                                    "key": "\(currentKey.safeLogRepresentation)",
                                    "attempts": "\(skipRetryCount)",
                                    "error": "\(skipError.safeDescription)"
                                ])

                                // ✅ Wrap FDBError in RecordLayerError with context
                                throw RecordLayerError.scrubberSkipFailed(
                                    key: currentKey.safeLogRepresentation,
                                    reason: skipError,
                                    attempts: skipRetryCount
                                )
                            }

                            logger.debug("Retryable error on skip commit", metadata: [
                                "attempt": "\(skipRetryCount)",
                                "error": "\(skipError.safeDescription)"
                            ])

                            let delay = configuration.retryDelayMillis * (1 << (skipRetryCount - 1))
                            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                        }
                    }

                    // 📊 Record batch duration (including skip overhead)
                    let batchDuration = Date().timeIntervalSince(batchStartTime)
                    batchDurationTimer.recordSeconds(batchDuration)

                    continuation = skipKey
                    batchSucceeded = true  // Mark as handled

                } catch let error as FDBError where error.isRetryable {
                    // ✅ CORRECT RETRY LOGIC: Retryable error - create new transaction and retry
                    retryCount += 1

                    if retryCount > configuration.maxRetries {
                        logger.error("Batch retry exhausted", metadata: [
                            "phase": "Phase 1",
                            "key_range": "\(currentKey.safeLogRepresentation) - \(endKey.safeLogRepresentation)",
                            "attempts": "\(retryCount)",
                            "error": "\(error.safeDescription)"
                        ])

                        // ✅ Wrap FDBError in RecordLayerError with context
                        throw RecordLayerError.scrubberRetryExhausted(
                            phase: "Phase 1",
                            operation: "scrubIndexEntriesBatch",
                            keyRange: "\(currentKey.safeLogRepresentation) - \(endKey.safeLogRepresentation)",
                            attempts: retryCount,
                            lastError: error,
                            recommendation: "Check FoundationDB cluster health and increase maxRetries if needed"
                        )
                    }

                    logger.debug("Retryable error on batch", metadata: [
                        "attempt": "\(retryCount)/\(configuration.maxRetries)",
                        "error": "\(error.safeDescription)"
                    ])

                    // Exponential backoff
                    let delay = configuration.retryDelayMillis * (1 << (retryCount - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)

                    // Loop continues with new transaction

                } catch {
                    // Non-retryable error - propagate immediately
                    throw error
                }
            }
        }

        logger.info("Phase 1 complete", metadata: [
            "total_scanned": "\(totalScanned)",
            "total_issues": "\(allIssues.count)"
        ])
        return (allIssues, totalScanned)
    }

    /// Scrub a batch of index entries within a single transaction
    ///
    /// ✅ FIX (Issue 3): Now returns scannedCount as 4th tuple element
    private func scrubIndexEntriesBatch(
        context: RecordContext,
        indexSubspace: Subspace,
        recordSubspace: Subspace,
        recordNames: [String],
        startKey: FDB.Bytes,
        endKey: FDB.Bytes,
        warningCount: inout Int
    ) async throws -> (continuation: FDB.Bytes?, issues: [ScrubberIssue], lastKey: FDB.Bytes?, scannedCount: Int) {
        let transaction = context.getTransaction()

        // ✅ Set transaction timeout
        if configuration.transactionTimeoutMillis > 0 {
            try context.setTimeout(milliseconds: configuration.transactionTimeoutMillis)
        }

        // ✅ Set read-your-writes option
        let snapshot = !configuration.readYourWrites
        if !configuration.readYourWrites {
            try context.disableReadYourWrites()
        }

        var scannedBytes = 0
        var scannedCount = 0
        var issues: [ScrubberIssue] = []
        var lastProcessedKey: FDB.Bytes?

        let sequence = transaction.getRange(
            begin: startKey,
            end: endKey,
            snapshot: snapshot  // ✅ Use configured snapshot setting
        )

        for try await (indexKey, _) in sequence {
            // ✅ STEP 1: Check byte limit BEFORE processing
            // ✅ FORWARD PROGRESS GUARANTEE: Only check if we've processed at least 1 entry
            let keySize = indexKey.count
            if scannedCount > 0 && scannedBytes + keySize > configuration.maxTransactionBytes {
                // Current key is NOT processed - return it as continuation
                // Don't increment scannedCount, don't update lastProcessedKey
                return (indexKey, issues, lastProcessedKey, scannedCount)
            }

            // ✅ STEP 2: We have capacity - commit to processing this key
            scannedBytes += keySize
            scannedCount += 1

            // ✅ STEP 3: Process the key (check if record exists)
            var recordFound = false

            // Check each record type (since index may apply to multiple types)
            for recordName in recordNames {
                guard let primaryKey = try extractPrimaryKey(
                    from: indexKey,
                    indexSubspace: indexSubspace,
                    recordName: recordName
                ) else {
                    // Primary key extraction failed (tuple decode issue or record type mismatch)
                    warningCount += 1

                    // 📊 Record skip metric with phase and reason
                    recordSkip(phase: "phase1", reason: "primary_key_extraction_failure")

                    // 📝 Log warning with sampling (1/100)
                    if warningCount % 100 == 0 {
                        logger.warning("Primary key extraction failed (sampled 1/100)", metadata: [
                            "index_key": "\(indexKey.safeLogRepresentation)",
                            "record_type": "\(recordName)",
                            "phase": "phase1"
                        ])
                    }
                    continue
                }

                // Build record key with record type name
                let typeSubspace = recordSubspace.subspace(recordName)
                let recordKey = typeSubspace.pack(TupleHelpers.toTuple(primaryKey))

                // Check if record exists (use configured snapshot setting)
                if try await transaction.getValue(for: recordKey, snapshot: snapshot) != nil {
                    recordFound = true
                    break
                }
            }

            if !recordFound {
                // Dangling entry detected
                warningCount += 1

                // Use first record type's primary key for logging
                let primaryKey = try extractPrimaryKey(
                    from: indexKey,
                    indexSubspace: indexSubspace,
                    recordName: recordNames.first ?? ""
                ) ?? []

                let issue = ScrubberIssue(
                    type: .danglingEntry,
                    indexKey: indexKey,
                    primaryKey: primaryKey,
                    repaired: false,
                    context: "Index entry exists but record does not"
                )

                issues.append(issue)

                // 📝 Log sampling (1/100) to reduce I/O overhead
                // ✅ PII Protection: Only log sanitized index_key, NOT primary_key
                if warningCount % 100 == 0 {
                    logger.warning(
                        "Dangling entry detected (sampled 1/100)",
                        metadata: [
                            "index_key": "\(indexKey.safeLogRepresentation)",
                            "index": "\(index.name)"
                        ]
                    )
                }

                // Repair if enabled
                if configuration.allowRepair {
                    transaction.clear(key: indexKey)
                    // Update issue to mark as repaired
                    let repairedIssue = ScrubberIssue(
                        type: .danglingEntry,
                        indexKey: indexKey,
                        primaryKey: primaryKey,
                        repaired: true,
                        context: "Dangling entry deleted"
                    )
                    issues[issues.count - 1] = repairedIssue
                }
            }

            // ✅ STEP 4: Mark this key as processed
            lastProcessedKey = indexKey

            // ✅ STEP 5: Check scan limit AFTER processing
            // If we've reached the limit, continue from NEXT key
            if scannedCount >= configuration.entriesScanLimit {
                let continuationKey = nextKey(after: indexKey)
                return (continuationKey, issues, lastProcessedKey, scannedCount)
            }
        }

        return (nil, issues, lastProcessedKey, scannedCount)  // ✅ Return scan count
    }

    /// Extract primary key from index key
    ///
    /// Index key format: [index_subspace_prefix][indexed_values...][primary_key...]
    ///
    /// - Parameters:
    ///   - indexKey: The index key to extract from
    ///   - indexSubspace: The index subspace (used to remove prefix)
    ///   - recordName: Record type name (used to get primary key length)
    /// - Returns: Primary key elements, or nil if extraction fails
    private func extractPrimaryKey(
        from indexKey: FDB.Bytes,
        indexSubspace: Subspace,
        recordName: String
    ) throws -> [any TupleElement]? {
        // ✅ Get primary key length from Schema
        guard let entity = schema.entity(named: recordName) else {
            // If record type not found, skip
            return nil
        }
        let primaryKeyLength = entity.primaryKeyFields.count

        // Remove index subspace prefix and decode tuple
        // Note: Subspace.unpack() returns Tuple, but we need to extract elements
        // The most efficient way is to remove the prefix and decode directly
        guard indexKey.starts(with: indexSubspace.prefix) else {
            return nil
        }

        let tupleBytes = Array(indexKey.dropFirst(indexSubspace.prefix.count))
        let elementsArray = try Tuple.decode(from: tupleBytes)

        // Index key structure: [indexed_values...][primary_key...]
        // We need to extract the last `primaryKeyLength` elements
        guard elementsArray.count >= primaryKeyLength else {
            return nil
        }

        // Extract primary key elements
        let primaryKeyElements = Array(elementsArray.suffix(primaryKeyLength))
        return primaryKeyElements
    }

    // MARK: - Phase 2: Records Scan

    /// Scan all records and check if corresponding index entries exist
    ///
    /// **Algorithm**:
    /// 1. Get record types indexed by this index
    /// 2. For each record type:
    ///    a. Get record type subspace
    ///    b. Iterate through records in batches
    ///    c. For each record:
    ///       - Deserialize record
    ///       - Extract indexed field values (using KeyExpression)
    ///       - Build expected index keys
    ///       - Check if index entries exist
    ///       - If not, log missing entry
    ///       - If allowRepair, insert index entry
    ///
    /// - Returns: Tuple of (issues, totalScanned)
    private func scrubRecords(progress: ScrubberProgress) async throws -> ([ScrubberIssue], Int) {
        logger.info("Starting Phase 2: Record→Index validation", metadata: [
            "index": "\(index.name)",
            "type": "\(index.type.rawValue)"
        ])

        // Reset progress tracking for Phase 2
        statelock.withLock { state in
            state.batchCount = 0
            state.totalScannedSoFar = 0
        }

        // Get record types indexed by this index
        let recordNames: [String]
        if let indexRecordTypes = index.recordTypes {
            recordNames = Array(indexRecordTypes)
        } else {
            // Universal index - applies to all entities
            recordNames = Array(schema.entitiesByName.keys)
        }

        guard !recordNames.isEmpty else {
            logger.warning("No record types found for index", metadata: [
                "index": "\(index.name)"
            ])
            return ([], 0)
        }

        var allIssues: [ScrubberIssue] = []
        var totalScanned = 0

        // Scan each record type separately (avoid scanning irrelevant types)
        for recordName in recordNames {
            if configuration.enableProgressLogging {
                logger.info("Phase 2: Scanning records", metadata: [
                    "record_type": "\(recordName)"
                ])
            }

            let (issues, scannedCount) = try await scrubRecordsForType(
                recordName: recordName,
                progress: progress
            )

            allIssues.append(contentsOf: issues)
            totalScanned += scannedCount
        }

        logger.info("Phase 2 complete", metadata: [
            "total_scanned": "\(totalScanned)",
            "total_issues": "\(allIssues.count)"
        ])
        return (allIssues, totalScanned)
    }

    /// Scrub records for a specific record type
    ///
    /// - Returns: Tuple of (issues, totalScanned)
    private func scrubRecordsForType(
        recordName: String,
        progress: ScrubberProgress
    ) async throws -> ([ScrubberIssue], Int) {
        let recordSubspace = subspace
            .subspace(RecordStoreKeyspace.record.rawValue)
            .subspace(recordName)

        // ✅ Use index.subspaceTupleKey (consistent with Phase 1)
        let indexSubspace = subspace
            .subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        let (beginKey, endKey) = recordSubspace.range()
        var continuation: FDB.Bytes? = beginKey
        var allIssues: [ScrubberIssue] = []
        var totalScanned = 0
        var warningCount = 0

        while let currentKey = continuation {
            if configuration.enableProgressLogging {
                logger.debug("Processing batch", metadata: [
                    "key": "\(currentKey.safeLogRepresentation)"
                ])
            }

            // 📊 Record batch start time for duration measurement
            let batchStartTime = Date()

            var retryCount = 0
            var batchSucceeded = false

            // ✅ CORRECT RETRY LOGIC: Create new transaction for each retry
            while !batchSucceeded && retryCount <= configuration.maxRetries {
                let context = try RecordContext(database: database)
                // Note: No need for defer { context.cancel() } - RecordContext.deinit handles cleanup

                do {
                    let (nextContinuation, batchIssues, batchEndKey, scannedCount) = try await scrubRecordsBatch(
                        context: context,
                        recordSubspace: recordSubspace,
                        indexSubspace: indexSubspace,
                        recordName: recordName,
                        startKey: currentKey,
                        endKey: endKey,
                        warningCount: &warningCount
                    )

                    // ✅ FIX (Issue 2): Update progress with next key after lastKey
                    if let lastKey = batchEndKey {
                        let rangeEnd = nextKey(after: lastKey)
                        try await progress.markPhase2Range(from: currentKey, to: rangeEnd, context: context)
                    }

                    // ✅ ATOMICITY FIX: Commit FIRST
                    try await context.commit()

                    // ✅ Then record issues (only if commit succeeded)
                    allIssues.append(contentsOf: batchIssues)
                    totalScanned += scannedCount

                    // 📊 Record metrics (batched - once per batch instead of per entry)
                    recordsScannedCounter.increment(by: Int64(scannedCount))

                    // Count and record issues by type
                    let missingCount = batchIssues.filter { $0.type == .missingEntry }.count
                    if missingCount > 0 {
                        missingEntriesCounter.increment(by: Int64(missingCount))
                    }

                    batchSizeRecorder.record(Int64(scannedCount))

                    // 📊 Record batch duration
                    let batchDuration = Date().timeIntervalSince(batchStartTime)
                    batchDurationTimer.recordSeconds(batchDuration)

                    // 📊 Progress tracking strategy (same as Phase 1)
                    let (currentBatch, _) = statelock.withLock { state in
                        state.batchCount += 1
                        state.totalScannedSoFar += scannedCount
                        return (state.batchCount, state.totalScannedSoFar)
                    }

                    // 📊 Update progress gauge only every 10 batches (accurate RangeSet progress)
                    if currentBatch % 10 == 0 {
                        let accurateProgress = try await progress.getAccurateProgress(
                            phase: .phase2InProgress,
                            fullBegin: beginKey,
                            fullEnd: endKey
                        )
                        progressGauge.record(accurateProgress)

                        logger.info("Phase 2 accurate progress check", metadata: [
                            "batch": "\(currentBatch)",
                            "progress": "\(String(format: "%.2f", accurateProgress * 100))%"
                        ])
                    }

                    if configuration.enableProgressLogging {
                        logger.info("Phase 2 batch complete", metadata: [
                            "scanned": "\(scannedCount)",
                            "issues": "\(batchIssues.count)"
                        ])
                    }

                    continuation = nextContinuation
                    batchSucceeded = true

                } catch let error as FDBError where error.code == 2101 {
                    // ✅ INFINITE LOOP FIX: transaction_too_large - skip oversized key
                    // This is NOT retryable - we must skip the key and continue
                    logger.warning("Oversized record detected, skipping", metadata: [
                        "key": "\(currentKey.safeLogRepresentation)",
                        "error_code": "2101",
                        "phase": "phase2"
                    ])

                    // 📊 Record skip metric with phase and reason
                    recordSkip(phase: "phase2", reason: "oversized_key")

                    let skipKey = nextKey(after: currentKey)

                    // Retry logic for skip commit (separate from main batch retry)
                    var skipRetryCount = 0
                    var skipCommitted = false

                    while !skipCommitted && skipRetryCount <= configuration.maxRetries {
                        let skipContext = try RecordContext(database: database)
                        // Note: No need for defer - RecordContext.deinit handles cleanup

                        do {
                            try await progress.markPhase2Range(from: currentKey, to: skipKey, context: skipContext)
                            try await skipContext.commit()
                            skipCommitted = true

                        } catch let skipError as FDBError where skipError.isRetryable {
                            skipRetryCount += 1
                            if skipRetryCount > configuration.maxRetries {
                                logger.error("Skip commit retry exhausted", metadata: [
                                    "key": "\(currentKey.safeLogRepresentation)",
                                    "attempts": "\(skipRetryCount)",
                                    "error": "\(skipError.safeDescription)"
                                ])

                                // ✅ Wrap FDBError in RecordLayerError with context
                                throw RecordLayerError.scrubberSkipFailed(
                                    key: currentKey.safeLogRepresentation,
                                    reason: skipError,
                                    attempts: skipRetryCount
                                )
                            }

                            logger.debug("Retryable error on skip commit", metadata: [
                                "attempt": "\(skipRetryCount)",
                                "error": "\(skipError.safeDescription)"
                            ])

                            let delay = configuration.retryDelayMillis * (1 << (skipRetryCount - 1))
                            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                        }
                    }

                    // 📊 Record batch duration (including skip overhead)
                    let batchDuration = Date().timeIntervalSince(batchStartTime)
                    batchDurationTimer.recordSeconds(batchDuration)

                    continuation = skipKey
                    batchSucceeded = true  // Mark as handled

                } catch let error as FDBError where error.isRetryable {
                    // ✅ CORRECT RETRY LOGIC: Retryable error - create new transaction and retry
                    retryCount += 1

                    if retryCount > configuration.maxRetries {
                        logger.error("Batch retry exhausted", metadata: [
                            "phase": "Phase 2",
                            "key_range": "\(currentKey.safeLogRepresentation) - \(endKey.safeLogRepresentation)",
                            "attempts": "\(retryCount)",
                            "error": "\(error.safeDescription)"
                        ])

                        // ✅ Wrap FDBError in RecordLayerError with context
                        throw RecordLayerError.scrubberRetryExhausted(
                            phase: "Phase 2",
                            operation: "scrubRecordsBatch",
                            keyRange: "\(currentKey.safeLogRepresentation) - \(endKey.safeLogRepresentation)",
                            attempts: retryCount,
                            lastError: error,
                            recommendation: "Check FoundationDB cluster health and increase maxRetries if needed"
                        )
                    }

                    logger.debug("Retryable error on batch", metadata: [
                        "attempt": "\(retryCount)/\(configuration.maxRetries)",
                        "error": "\(error.safeDescription)"
                    ])

                    // Exponential backoff
                    let delay = configuration.retryDelayMillis * (1 << (retryCount - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)

                    // Loop continues with new transaction

                } catch {
                    // Non-retryable error - propagate immediately
                    throw error
                }
            }
        }

        return (allIssues, totalScanned)  // ✅ Return scan count
    }

    /// Scrub a batch of records within a single transaction
    ///
    /// ✅ FIX (Issue 3): Now returns scannedCount as 4th tuple element
    private func scrubRecordsBatch(
        context: RecordContext,
        recordSubspace: Subspace,
        indexSubspace: Subspace,
        recordName: String,
        startKey: FDB.Bytes,
        endKey: FDB.Bytes,
        warningCount: inout Int
    ) async throws -> (continuation: FDB.Bytes?, issues: [ScrubberIssue], lastKey: FDB.Bytes?, scannedCount: Int) {
        let transaction = context.getTransaction()

        // ✅ Set transaction timeout
        if configuration.transactionTimeoutMillis > 0 {
            try context.setTimeout(milliseconds: configuration.transactionTimeoutMillis)
        }

        // ✅ Set read-your-writes option
        let snapshot = !configuration.readYourWrites
        if !configuration.readYourWrites {
            try context.disableReadYourWrites()
        }

        var scannedBytes = 0
        var scannedCount = 0
        var issues: [ScrubberIssue] = []
        var lastProcessedKey: FDB.Bytes?

        // ✅ Get primary key length from Schema
        guard let entity = schema.entity(named: recordName) else {
            throw RecordLayerError.recordTypeNotFound(recordName)
        }
        let primaryKeyLength = entity.primaryKeyFields.count

        let sequence = transaction.getRange(
            begin: startKey,
            end: endKey,
            snapshot: snapshot  // ✅ Use configured snapshot setting
        )

        for try await (recordKey, recordBytes) in sequence {
            // ✅ STEP 1: Check byte limit BEFORE processing
            // ✅ FORWARD PROGRESS GUARANTEE: Only check if we've processed at least 1 entry
            let entrySize = recordKey.count + recordBytes.count
            if scannedCount > 0 && scannedBytes + entrySize > configuration.maxTransactionBytes {
                // Current record is NOT processed - return it as continuation
                // Don't increment scannedCount, don't update lastProcessedKey
                return (recordKey, issues, lastProcessedKey, scannedCount)
            }

            // ✅ STEP 2: We have capacity - commit to processing this record
            scannedBytes += entrySize
            scannedCount += 1

            // ✅ STEP 3: Process the record

            // Deserialize record
            let record: Record
            do {
                record = try recordAccess.deserialize(recordBytes)
            } catch {
                // Skip records that can't be deserialized
                // 📊 Record skip metric with phase and specific reason
                recordSkip(phase: "phase2", reason: "record_deserialization_failure")

                // 📝 Log warning with sampling (1/100) to avoid log spam
                if warningCount % 100 == 0 {
                    logger.warning("Record deserialization failed (sampled 1/100)", metadata: [
                        "key": "\(recordKey.safeLogRepresentation)",
                        "error": "\(error.safeDescription)",
                        "phase": "phase2"
                    ])
                }
                warningCount += 1

                // Update lastProcessedKey since we "processed" (skipped) it
                lastProcessedKey = recordKey

                // Check scan limit after skipping
                if scannedCount >= configuration.entriesScanLimit {
                    let continuationKey = nextKey(after: recordKey)
                    return (continuationKey, issues, lastProcessedKey, scannedCount)
                }
                continue
            }

            // Extract primary key from record key using recordSubspace.unpack()
            // Remove record subspace prefix and decode tuple
            guard recordKey.starts(with: recordSubspace.prefix) else {
                lastProcessedKey = recordKey

                // Check scan limit after skipping
                if scannedCount >= configuration.entriesScanLimit {
                    let continuationKey = nextKey(after: recordKey)
                    return (continuationKey, issues, lastProcessedKey, scannedCount)
                }
                continue
            }

            let tupleBytes = Array(recordKey.dropFirst(recordSubspace.prefix.count))
            let elementsArray: [any TupleElement]
            do {
                elementsArray = try Tuple.decode(from: tupleBytes)
            } catch {
                // 📊 Record skip metric with phase and specific reason
                recordSkip(phase: "phase2", reason: "tuple_decode_failure")

                // 📝 Log warning with sampling (1/100) to avoid log spam
                if warningCount % 100 == 0 {
                    logger.warning("Tuple decode failed (sampled 1/100)", metadata: [
                        "key": "\(recordKey.safeLogRepresentation)",
                        "error": "\(error.safeDescription)",
                        "phase": "phase2"
                    ])
                }
                warningCount += 1

                lastProcessedKey = recordKey

                // Check scan limit after skipping
                if scannedCount >= configuration.entriesScanLimit {
                    let continuationKey = nextKey(after: recordKey)
                    return (continuationKey, issues, lastProcessedKey, scannedCount)
                }
                continue
            }

            // Primary key is the entire unpacked tuple (already without record type prefix)
            guard elementsArray.count == primaryKeyLength else {
                // Unexpected key structure
                lastProcessedKey = recordKey

                // Check scan limit after skipping
                if scannedCount >= configuration.entriesScanLimit {
                    let continuationKey = nextKey(after: recordKey)
                    return (continuationKey, issues, lastProcessedKey, scannedCount)
                }
                continue
            }

            let primaryKeyElements = elementsArray

            // Build expected index keys using KeyExpression
            let indexKeys = try buildIndexKeys(
                record: record,
                primaryKey: primaryKeyElements,
                indexSubspace: indexSubspace
            )

            // Check if index entries exist (use configured snapshot setting)
            for indexKey in indexKeys {
                let indexExists = try await transaction.getValue(for: indexKey, snapshot: snapshot) != nil

                if !indexExists {
                    // Missing entry detected
                    warningCount += 1

                    let issue = ScrubberIssue(
                        type: .missingEntry,
                        indexKey: indexKey,
                        primaryKey: primaryKeyElements,
                        repaired: false,
                        context: "Record exists but index entry does not"
                    )

                    issues.append(issue)

                    // 📝 Log sampling (1/100) to reduce I/O overhead
                    // ✅ PII Protection: Only log sanitized index_key, NOT primary_key
                    if warningCount % 100 == 0 {
                        logger.warning(
                            "Missing index entry detected (sampled 1/100)",
                            metadata: [
                                "index_key": "\(indexKey.safeLogRepresentation)",
                                "index": "\(index.name)"
                            ]
                        )
                    }

                    // Repair if enabled
                    if configuration.allowRepair {
                        // Insert index entry (VALUE index: empty value)
                        transaction.setValue(FDB.Bytes(), for: indexKey)

                        // Update issue to mark as repaired
                        let repairedIssue = ScrubberIssue(
                            type: .missingEntry,
                            indexKey: indexKey,
                            primaryKey: primaryKeyElements,
                            repaired: true,
                            context: "Missing index entry inserted"
                        )
                        issues[issues.count - 1] = repairedIssue
                    }
                }
            }

            // ✅ STEP 4: Mark this record as processed
            lastProcessedKey = recordKey

            // ✅ STEP 5: Check scan limit AFTER processing
            // If we've reached the limit, continue from NEXT key
            if scannedCount >= configuration.entriesScanLimit {
                let continuationKey = nextKey(after: recordKey)
                return (continuationKey, issues, lastProcessedKey, scannedCount)
            }
        }

        return (nil, issues, lastProcessedKey, scannedCount)  // ✅ Return scan count
    }

    /// Build expected index keys for a record
    ///
    /// Uses KeyExpression.evaluate() to ensure consistency with IndexMaintainer
    ///
    /// - Parameters:
    ///   - record: The record to index
    ///   - primaryKey: Primary key elements
    ///   - indexSubspace: Index subspace
    /// - Returns: Array of expected index keys
    private func buildIndexKeys(
        record: Record,
        primaryKey: [any TupleElement],
        indexSubspace: Subspace
    ) throws -> [FDB.Bytes] {
        // ✅ FIX: evaluateKeyExpression now returns [[TupleElement]]
        // Each inner array represents one complete index entry
        // - For single-valued field: [["value"]]
        // - For multi-valued field (array): [["value1"], ["value2"], ...]
        // - For composite index: [["field1", "field2", ...]]
        let indexEntries = try evaluateKeyExpression(
            expression: index.rootExpression,
            record: record
        )

        var indexKeys: [FDB.Bytes] = []

        // ✅ FIX: Remove empty tuple condition
        // For VALUE index, null/missing fields should NOT create index entries
        if indexEntries.isEmpty {
            // No values: no index entries (field is null/missing)
            return []
        }

        // For each index entry (not individual element),
        // combine with primary key to create complete index key
        for indexedValues in indexEntries {
            let keyElements = indexedValues + primaryKey
            let keyTuple = TupleHelpers.toTuple(keyElements)
            let indexKey = indexSubspace.pack(keyTuple)
            indexKeys.append(indexKey)
        }

        return indexKeys
    }

    /// Evaluate key expression on a record
    ///
    /// Recursively evaluates KeyExpression to extract indexed values.
    /// Reuses the same logic as IndexMaintainer for consistency.
    ///
    /// **Return Type**: `[[TupleElement]]` (2D array)
    /// - Outer array: Multiple index entries (for multi-valued fields)
    /// - Inner array: Field values for one index entry
    ///
    /// **Examples**:
    /// - Single field: `FieldKeyExpression("email")` → `[["alice@example.com"]]`
    /// - Composite: `ConcatenateKeyExpression([city, age])` → `[["Tokyo", 30]]`
    /// - Multi-valued: `FieldKeyExpression("tags")` → `[["swift"], ["fdb"], ["database"]]`
    /// - Composite + Multi: `ConcatenateKeyExpression([city, tags])` → `[["Tokyo", "swift"], ["Tokyo", "fdb"]]`
    ///
    /// - Parameters:
    ///   - expression: The key expression to evaluate
    ///   - record: The record to evaluate on
    /// - Returns: Array of index entries, each containing field values
    private func evaluateKeyExpression(
        expression: KeyExpression,
        record: Record
    ) throws -> [[any TupleElement]] {
        switch expression {
        case let field as FieldKeyExpression:
            // Extract field value(s) - may return multiple values for array fields
            let values = try recordAccess.extractField(
                from: record,
                fieldName: field.fieldName
            )

            // ✅ FIX: Empty means NO index entries (not one empty entry)
            // For VALUE index, null/missing fields are not indexed
            if values.isEmpty {
                return []  // Empty 2D array - no index entries at all
            }
            return values.map { [$0] }  // [[value1], [value2], ...]

        case let concat as ConcatenateKeyExpression:
            // ✅ FIX: Compute Cartesian product to combine fields correctly
            // Start with one empty entry
            var result: [[any TupleElement]] = [[]]

            for child in concat.children {
                let childEntries = try evaluateKeyExpression(
                    expression: child,
                    record: record
                )

                // Cartesian product: combine each existing entry with each child entry
                var newResult: [[any TupleElement]] = []
                for existingEntry in result {
                    for childEntry in childEntries {
                        newResult.append(existingEntry + childEntry)
                    }
                }
                result = newResult
            }

            return result

        default:
            throw RecordLayerError.invalidArgument(
                "Unsupported key expression type: \(type(of: expression))"
            )
        }
    }
}

// MARK: - ScrubberConfiguration

/// Configuration for index scrubbing
public struct ScrubberConfiguration: Sendable {

    // MARK: - Scan Limits

    /// Maximum number of entries to scan per transaction
    /// - Default: 1,000
    /// - Note: Consider FoundationDB's 5-second transaction limit
    public let entriesScanLimit: Int

    /// Maximum transaction size in bytes (for read data)
    /// - Default: 9 MB (留有10MB限制的余地)
    /// - Note: FoundationDB's getRange has 10MB response limit
    public let maxTransactionBytes: Int

    /// Maximum transaction execution time in milliseconds
    /// - Default: 4,000 ms (留有5秒限制的余地)
    /// - Note: FoundationDB's default transaction timeout is 5 seconds
    public let transactionTimeoutMillis: Int

    /// Enable read-your-writes isolation
    /// - Default: false (memory optimization for large scans)
    /// - false: Disable for memory optimization
    /// - true: Enable for consistency (increases memory usage)
    public let readYourWrites: Bool

    // MARK: - Repair Settings

    /// Whether to automatically repair detected inconsistencies
    /// - Default: false (detection only, no repair)
    /// - **Caution**: Enable carefully in production environments
    /// - **Limitation**: Only VALUE index is supported (COUNT/SUM/RANK not supported)
    public let allowRepair: Bool

    /// Supported index types for repair
    /// - Note: Phase 1 supports only VALUE index
    /// - COUNT/SUM/RANK: Future implementation (requires specialized repair logic)
    public let supportedTypes: Set<IndexType>

    // MARK: - Logging

    /// Maximum number of warnings to log
    /// - Default: 100
    /// - Prevents log bloat
    public let logWarningsLimit: Int

    /// Whether to log detailed progress
    /// - Default: true
    public let enableProgressLogging: Bool

    /// Progress log interval (in seconds)
    /// - Default: 10.0 seconds
    public let progressLogIntervalSeconds: Double

    // MARK: - Retry Settings

    /// Maximum number of retries on transient errors
    /// - Default: 10
    public let maxRetries: Int

    /// Retry delay (in milliseconds)
    /// - Default: 100ms
    public let retryDelayMillis: Int

    // MARK: - Presets

    /// Default configuration (balanced settings)
    public static let `default` = ScrubberConfiguration(
        entriesScanLimit: 1_000,
        maxTransactionBytes: 9_000_000,  // 9 MB
        transactionTimeoutMillis: 4_000,  // 4 seconds
        readYourWrites: false,  // Memory optimization
        allowRepair: false,  // Detection only
        supportedTypes: [.value],  // VALUE index only
        logWarningsLimit: 100,
        enableProgressLogging: true,
        progressLogIntervalSeconds: 10.0,
        maxRetries: 10,
        retryDelayMillis: 100
    )

    /// Conservative configuration (production environments)
    public static let conservative = ScrubberConfiguration(
        entriesScanLimit: 100,  // Smaller batches
        maxTransactionBytes: 1_000_000,  // 1 MB
        transactionTimeoutMillis: 2_000,  // 2 seconds
        readYourWrites: false,
        allowRepair: false,
        supportedTypes: [.value],
        logWarningsLimit: 50,
        enableProgressLogging: true,
        progressLogIntervalSeconds: 30.0,
        maxRetries: 5,
        retryDelayMillis: 200
    )

    /// Aggressive configuration (maintenance windows)
    public static let aggressive = ScrubberConfiguration(
        entriesScanLimit: 10_000,  // Larger batches
        maxTransactionBytes: 9_000_000,  // 9 MB
        transactionTimeoutMillis: 4_000,  // 4 seconds
        readYourWrites: false,
        allowRepair: true,  // Auto-repair enabled
        supportedTypes: [.value],
        logWarningsLimit: 500,
        enableProgressLogging: true,
        progressLogIntervalSeconds: 5.0,
        maxRetries: 20,
        retryDelayMillis: 50
    )
}

// MARK: - ScrubberIssue

/// Represents a detected index inconsistency
public struct ScrubberIssue: Sendable {

    /// Type of issue
    public let type: IssueType

    /// Index key where issue was found
    public let indexKey: FDB.Bytes

    /// Primary key extracted from index key
    public let primaryKey: [any TupleElement]

    /// Whether the issue was repaired
    public let repaired: Bool

    /// Additional context information
    public let context: String?

    /// Issue type enumeration
    public enum IssueType: String, Sendable {
        case danglingEntry = "dangling_entry"  // Index entry without record
        case missingEntry = "missing_entry"    // Record without index entry
    }
}

// MARK: - ScrubberProgress

/// Progress tracking for scrubbing operations
///
/// **Design Note**: Uses separate RangeSets for Phase 1 and Phase 2
/// to prevent mixing progress between phases during resumption.
struct ScrubberProgress {

    /// Subspace for storing progress metadata
    let progressSubspace: Subspace

    /// Phase 1: Index entries scan progress
    let phase1RangeSet: RangeSet

    /// Phase 2: Records scan progress
    let phase2RangeSet: RangeSet

    /// Current scrubbing phase
    enum Phase: String, Sendable {
        case notStarted = "not_started"
        case phase1InProgress = "phase1_in_progress"
        case phase1Complete = "phase1_complete"
        case phase2InProgress = "phase2_in_progress"
        case phase2Complete = "phase2_complete"
        case completed = "completed"
    }

    /// Get current phase from metadata
    func getCurrentPhase(context: RecordContext) async throws -> Phase {
        let phaseKey = progressSubspace.pack(Tuple("current_phase"))
        guard let bytes = try await context.getTransaction().getValue(for: phaseKey),
              let phaseString = String(bytes: bytes, encoding: .utf8),
              let phase = Phase(rawValue: phaseString) else {
            return .notStarted
        }
        return phase
    }

    /// Set current phase
    func setPhase(_ phase: Phase, context: RecordContext) {
        let phaseKey = progressSubspace.pack(Tuple("current_phase"))
        let value = FDB.Bytes(phase.rawValue.utf8)
        context.getTransaction().setValue(value, for: phaseKey)
    }

    /// Mark a range as completed in Phase 1
    func markPhase1Range(from: FDB.Bytes, to: FDB.Bytes, context: RecordContext) async throws {
        try await phase1RangeSet.insertRange(begin: from, end: to, context: context)
    }

    /// Mark a range as completed in Phase 2
    func markPhase2Range(from: FDB.Bytes, to: FDB.Bytes, context: RecordContext) async throws {
        try await phase2RangeSet.insertRange(begin: from, end: to, context: context)
    }

    /// Calculate estimated progress without issuing a transaction
    ///
    /// Uses in-memory estimation based on scanned entries and total estimated entries.
    /// This is fast and doesn't require a database read.
    ///
    /// - Parameters:
    ///   - scannedEntries: Number of entries scanned so far
    ///   - totalEstimatedEntries: Estimated total number of entries (can be approximate)
    /// - Returns: Progress ratio between 0.0 and 1.0
    func estimateProgress(scannedEntries: Int, totalEstimatedEntries: Int) -> Double {
        guard totalEstimatedEntries > 0 else { return 0.0 }
        let progress = Double(scannedEntries) / Double(totalEstimatedEntries)
        return min(1.0, max(0.0, progress))
    }

    /// Get accurate progress from RangeSet (issues a transaction)
    ///
    /// This method is expensive as it reads from the database.
    /// Use sparingly (e.g., every 10 batches) for accurate progress tracking.
    ///
    /// - Parameters:
    ///   - phase: Which phase to get progress for
    ///   - fullBegin: Start of the key space
    ///   - fullEnd: End of the key space
    /// - Returns: Accurate progress ratio between 0.0 and 1.0
    func getAccurateProgress(
        phase: Phase,
        fullBegin: FDB.Bytes,
        fullEnd: FDB.Bytes
    ) async throws -> Double {
        let rangeSet = (phase == .phase1InProgress || phase == .phase1Complete) ? phase1RangeSet : phase2RangeSet
        let (_, progress) = try await rangeSet.getProgress(fullBegin: fullBegin, fullEnd: fullEnd)
        return progress
    }
}
