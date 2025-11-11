import Foundation
import FoundationDB

/// Helper functions for transaction management
///
/// These helpers encapsulate common transaction patterns and constraints
/// defined in docs/storage-design.md
public enum TransactionHelpers {
    // MARK: - Timeout Configuration

    /// Sets a short client-side timeout for fast-failing transactions
    ///
    /// **Important:** This only affects client-side cancellation.
    /// The read-version window (5s) cannot be extended.
    ///
    /// **Usage:**
    /// ```swift
    /// try await database.withTransaction { transaction in
    ///     try setShortTimeout(transaction: transaction)
    ///     // Must complete within 1 second
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - transaction: Transaction to configure
    ///   - timeoutMs: Timeout in milliseconds (default: 1000ms)
    public static func setShortTimeout(
        transaction: any TransactionProtocol,
        timeoutMs: Int64 = 1_000
    ) throws {
        try transaction.setOption(
            to: withUnsafeBytes(of: timeoutMs.littleEndian) { Array($0) },
            forOption: .timeout
        )
    }

    // MARK: - Transaction Size Management

    /// Sets conservative transaction size limit for early detection
    ///
    /// **Important:** The 10MB hard limit cannot be increased.
    /// This option only allows setting a lower limit.
    ///
    /// **Usage:**
    /// ```swift
    /// try await database.withTransaction { transaction in
    ///     try setConservativeTransactionSize(transaction: transaction)
    ///     // Transaction will fail at 5MB instead of 10MB
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - transaction: Transaction to configure
    ///   - sizeLimit: Size limit in bytes (default: 5MB, must be ≤10MB)
    public static func setConservativeTransactionSize(
        transaction: any TransactionProtocol,
        sizeLimit: Int64 = 5_000_000
    ) throws {
        precondition(sizeLimit <= 10_000_000, "Size limit cannot exceed 10MB (FDB hard limit)")
        try transaction.setOption(
            to: withUnsafeBytes(of: sizeLimit.littleEndian) { Array($0) },
            forOption: .sizeLimit
        )
    }

    // MARK: - Long-Running Range Scans

    /// Performs a long-running range scan by splitting into multiple transactions
    ///
    /// This pattern is necessary when the range scan exceeds the 5-second
    /// read-version window. Each transaction processes a batch of records,
    /// then a new transaction continues from the last key.
    ///
    /// **Usage:**
    /// ```swift
    /// let records = try await TransactionHelpers.longRangeScan(
    ///     database: database,
    ///     beginKey: startKey,
    ///     endKey: endKey,
    ///     batchSize: 1000
    /// ) { value in
    ///     try MyRecord.deserialize(from: value)
    /// }
    /// ```
    ///
    /// **Parameters:**
    /// - database: Database to query
    /// - beginKey: Start of range (inclusive)
    /// - endKey: End of range (exclusive)
    /// - batchSize: Records per transaction (default: 1000)
    /// - deserialize: Closure to deserialize values
    ///
    /// **Returns:** All records in the range
    public static func longRangeScan<Record: Sendable>(
        database: any DatabaseProtocol,
        beginKey: FDB.Bytes,
        endKey: FDB.Bytes,
        batchSize: Int = 1000,
        deserialize: @Sendable @escaping (FDB.Bytes) throws -> Record
    ) async throws -> [Record] {
        var allRecords: [Record] = []
        var continuationKey: FDB.Bytes? = beginKey

        while true {
            // Each transaction completes within 5 seconds
            let (batch, nextKey): ([Record], FDB.Bytes?) = try await database.withTransaction { transaction in
                let begin = continuationKey ?? beginKey
                let sequence = transaction.getRange(
                    beginSelector: .firstGreaterOrEqual(begin),
                    endSelector: .firstGreaterOrEqual(endKey),
                    snapshot: true  // Read-only, no conflict detection needed
                )

                var batchRecords: [Record] = []
                var lastKey: FDB.Bytes? = nil

                for try await (key, value) in sequence {
                    batchRecords.append(try deserialize(value))
                    lastKey = key

                    // Stop after collecting batchSize records
                    if batchRecords.count >= batchSize { break }
                }

                // Return next key (start from after lastKey)
                if let last = lastKey {
                    var next = last
                    next.append(0x00)  // Next key
                    return (batchRecords, next)
                } else {
                    return (batchRecords, nil)
                }
            }

            allRecords.append(contentsOf: batch)

            // Done if no continuation key
            guard let next = nextKey else { break }
            continuationKey = next
        }

        return allRecords
    }

    // MARK: - Batch Processing

    /// Configuration for batch processing
    public struct BatchConfig: Sendable {
        /// Maximum records per batch
        public let maxRecordsPerBatch: Int

        /// Maximum bytes per batch (default: 5MB with safety margin)
        public let maxBytesPerBatch: Int

        /// Maximum time per batch (default: 3 seconds, well under 5s limit)
        public let maxTimePerBatch: TimeInterval

        public init(
            maxRecordsPerBatch: Int = 1000,
            maxBytesPerBatch: Int = 5_000_000,
            maxTimePerBatch: TimeInterval = 3.0
        ) {
            self.maxRecordsPerBatch = maxRecordsPerBatch
            self.maxBytesPerBatch = maxBytesPerBatch
            self.maxTimePerBatch = maxTimePerBatch
        }

        public static let `default` = BatchConfig()
    }

    /// Processes records in batches with automatic transaction splitting
    ///
    /// This helper ensures that batch processing respects FDB's constraints:
    /// - 10MB transaction size limit
    /// - 5-second read-version window
    ///
    /// **Usage:**
    /// ```swift
    /// try await TransactionHelpers.processBatch(
    ///     database: database,
    ///     records: largeRecordSet,
    ///     estimateSize: { record in record.estimatedSize }
    /// ) { batch, transaction in
    ///     for record in batch {
    ///         try await save(record, transaction: transaction)
    ///     }
    /// }
    /// ```
    ///
    /// **Parameters:**
    /// - database: Database to use
    /// - records: Records to process
    /// - config: Batch configuration
    /// - estimateSize: Closure to estimate record size in bytes
    /// - processBatch: Closure to process each batch
    public static func processBatch<Record: Sendable>(
        database: any DatabaseProtocol,
        records: [Record],
        config: BatchConfig = .default,
        estimateSize: @Sendable (Record) -> Int,
        processBatch: @Sendable ([Record], any TransactionProtocol) async throws -> Void
    ) async throws {
        var currentBatch: [Record] = []
        var currentSize = 0

        for record in records {
            let size = estimateSize(record)

            // Check if adding this record would exceed limits
            if currentBatch.count >= config.maxRecordsPerBatch ||
               currentSize + size > config.maxBytesPerBatch {
                // Commit current batch
                try await database.withTransaction { transaction in
                    try await processBatch(currentBatch, transaction)
                }

                // Reset for next batch
                currentBatch = []
                currentSize = 0
            }

            currentBatch.append(record)
            currentSize += size
        }

        // Commit remaining records
        if !currentBatch.isEmpty {
            try await database.withTransaction { transaction in
                try await processBatch(currentBatch, transaction)
            }
        }
    }

    // MARK: - Error Handling

    /// Executes an operation with automatic retry for retryable errors
    ///
    /// This helper implements exponential backoff for retryable FDB errors
    /// (e.g., transaction_too_old, not_committed).
    ///
    /// **Usage:**
    /// ```swift
    /// let result = try await TransactionHelpers.executeWithRetry(maxRetries: 3) {
    ///     try await expensiveOperation()
    /// }
    /// ```
    ///
    /// **Parameters:**
    /// - maxRetries: Maximum number of retry attempts (default: 3)
    /// - operation: Operation to execute
    ///
    /// **Returns:** Result of the operation
    ///
    /// **Throws:**
    /// - FDBError.fatal: For non-retryable errors
    /// - Last error if all retries fail
    public static func executeWithRetry<T>(
        maxRetries: Int = 3,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch let error as FDBError {
                lastError = error

                // Determine if error is retryable
                let isRetryable = error.isRetryable ||
                                  error.code == 1020  // not_committed

                if !isRetryable {
                    throw error
                }

                // Exponential backoff: 100ms, 200ms, 400ms...
                let delay = TimeInterval(pow(2.0, Double(attempt))) * 0.1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            } catch {
                // Non-FDB error: don't retry
                throw error
            }
        }

        // All retries failed
        throw lastError ?? RecordLayerError.internalError("All retries exhausted")
    }
}
