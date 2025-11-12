import Foundation
import FoundationDB

/// Migration Definition
///
/// Defines a schema migration from one version to another.
/// Migrations are applied automatically by MigrationManager to
/// evolve the schema and data over time.
///
/// **Migration Types**:
/// 1. **Index Migration**: Add/remove/rebuild indexes
/// 2. **Data Migration**: Transform record data
/// 3. **Schema Migration**: Change field types or constraints
///
/// **Example**:
/// ```swift
/// let migration = Migration(
///     fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
///     toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
///     description: "Add email index and make city field optional"
/// ) { context in
///     // Add new index
///     try await context.addIndex(
///         Index.value(named: "email_index", on: FieldKeyExpression(fieldName: "email"))
///     )
///
///     // Transform data
///     try await context.transformRecords(recordType: "User") { record in
///         // Migration logic here
///         return record
///     }
/// }
/// ```
public struct Migration: Sendable {
    // MARK: - Properties

    /// Source schema version
    public let fromVersion: SchemaVersion

    /// Target schema version
    public let toVersion: SchemaVersion

    /// Human-readable description of this migration
    public let description: String

    /// Migration execution function
    public let execute: @Sendable (MigrationContext) async throws -> Void

    // MARK: - Initialization

    /// Initialize a migration
    ///
    /// - Parameters:
    ///   - fromVersion: Source schema version
    ///   - toVersion: Target schema version
    ///   - description: Description of the migration
    ///   - execute: Migration execution closure
    public init(
        fromVersion: SchemaVersion,
        toVersion: SchemaVersion,
        description: String,
        execute: @escaping @Sendable (MigrationContext) async throws -> Void
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.description = description
        self.execute = execute
    }
}

// MARK: - Migration Context

/// Context provided to migrations during execution
///
/// Provides access to database operations and migration utilities.
public struct MigrationContext: Sendable {
    // MARK: - Properties

    /// Database instance
    nonisolated(unsafe) public let database: any DatabaseProtocol

    /// Schema being migrated to
    public let schema: Schema

    /// Metadata subspace for storing migration progress
    public let metadataSubspace: Subspace

    /// Record store factory
    ///
    /// **Current Limitation**: Returns `Any` instead of type-safe `RecordStore<Record>`.
    ///
    /// This prevents implementing migration operations that require:
    /// - Type-safe record scanning and iteration
    /// - Type-safe record transformation
    /// - Index building with specific Record types
    ///
    /// **Future Design Options**:
    /// 1. Protocol-based approach with associated types
    /// 2. Type-erased wrapper (AnyRecordStore)
    /// 3. Generic factory with type registration
    ///
    /// See Migration.swift method implementations for detailed requirements.
    private let storeFactory: @Sendable (String) throws -> Any

    // MARK: - Initialization

    internal init(
        database: any DatabaseProtocol,
        schema: Schema,
        metadataSubspace: Subspace,
        storeFactory: @escaping @Sendable (String) throws -> Any
    ) {
        self.database = database
        self.schema = schema
        self.metadataSubspace = metadataSubspace
        self.storeFactory = storeFactory
    }

    // MARK: - Index Operations

    /// Add a new index and build it online
    ///
    /// - Parameter index: The index to add
    /// - Throws: RecordLayerError if index addition fails
    public func addIndex(_ index: Index) async throws {
        throw RecordLayerError.internalError(
            """
            Migration index operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain Record type)
            2. RecordStore subspace in MigrationContext (for IndexStateManager and data operations)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Add index to schema (if not already present)
            2. Create IndexStateManager with RecordStore subspace
            3. Enable index (sets to writeOnly)
            4. Create OnlineIndexer with proper Record type from factory
            5. Build index using OnlineIndexer.buildIndex()
            6. Mark index as readable via IndexStateManager.makeReadable()
            """
        )
    }

    /// Remove an index and add FormerIndex entry
    ///
    /// - Parameters:
    ///   - indexName: Name of the index to remove
    ///   - addedVersion: Version when index was originally added
    /// - Throws: RecordLayerError if index removal fails
    public func removeIndex(
        indexName: String,
        addedVersion: SchemaVersion
    ) async throws {
        throw RecordLayerError.internalError(
            """
            Migration index operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain Record type)
            2. RecordStore subspace in MigrationContext (for IndexStateManager and data operations)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Create FormerIndex entry in schema metadata
               Key: [subspace][storeInfo][formerIndexes][indexName]
               Value: Tuple(addedVersion, removedTimestamp)
            2. Disable index state via IndexStateManager
            3. Clear all index data
               Range: [subspace][index][indexName]/*
            4. Update schema to remove index from active indexes list
            """
        )
    }

    /// Rebuild an existing index
    ///
    /// - Parameter indexName: Name of the index to rebuild
    /// - Throws: RecordLayerError if rebuild fails
    public func rebuildIndex(indexName: String) async throws {
        throw RecordLayerError.internalError(
            """
            Migration index operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain Record type)
            2. RecordStore subspace in MigrationContext (for IndexStateManager and data operations)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Disable index via IndexStateManager
            2. Clear existing index data
               Range: [subspace][index][indexName]/*
            3. Enable index (sets to writeOnly)
            4. Create OnlineIndexer with proper Record type from factory
            5. Build index using OnlineIndexer.buildIndex()
            6. Mark as readable via IndexStateManager.makeReadable()
            """
        )
    }

    // MARK: - Data Transformation

    /// Batch processing configuration
    ///
    /// Controls limits for batch processing to respect FDB constraints.
    public struct BatchConfig: Sendable {
        public let maxRecordsPerBatch: Int
        public let maxBytesPerBatch: Int
        public let maxTimePerBatch: TimeInterval

        public static func makeDefault() -> BatchConfig {
            return BatchConfig(
                maxRecordsPerBatch: 100,
                maxBytesPerBatch: 5_000_000,  // 5MB (safe margin from 10MB limit)
                maxTimePerBatch: 3.0  // 3s (safe margin from 5s limit)
            )
        }

        public init(
            maxRecordsPerBatch: Int = 100,
            maxBytesPerBatch: Int = 5_000_000,
            maxTimePerBatch: TimeInterval = 3.0
        ) {
            self.maxRecordsPerBatch = maxRecordsPerBatch
            self.maxBytesPerBatch = maxBytesPerBatch
            self.maxTimePerBatch = maxTimePerBatch
        }
    }

    /// Transform records of a specific type
    ///
    /// **Redesigned for correctness and resumability**:
    /// - Uses RangeSet for progress tracking
    /// - Atomic transactions (data + progress in same transaction)
    /// - Proper range continuation with while loop
    /// - Respects FDB limits (size, time, transaction)
    ///
    /// - Parameters:
    ///   - recordType: The record type to transform
    ///   - config: Batch processing configuration
    ///   - transform: Transformation function
    /// - Throws: RecordLayerError if transformation fails
    public func transformRecords<Record: Recordable>(
        recordType: String,
        config: BatchConfig = .makeDefault(),
        transform: @escaping @Sendable (Record) async throws -> Record
    ) async throws {
        // Get RecordStore from factory
        guard let store = try storeFactory(recordType) as? RecordStore<Record> else {
            throw RecordLayerError.internalError(
                "Failed to get RecordStore<\(Record.self)> from factory for recordType '\(recordType)'"
            )
        }

        // Setup progress tracking
        let progressSubspace = metadataSubspace
            .subspace("migration")
            .subspace("transform")
            .subspace(recordType)
        let rangeSet = RangeSet(database: database, subspace: progressSubspace)

        let recordAccess = GenericRecordAccess<Record>()
        let effectiveSubspace = store.recordSubspace.subspace(Record.recordName)
        let totalRange = effectiveSubspace.range()

        // Find incomplete ranges
        let missingRanges = try await rangeSet.missingRanges(
            fullBegin: totalRange.begin,
            fullEnd: totalRange.end
        )

        // Process each incomplete range
        for (rangeBegin, rangeEnd) in missingRanges {
            try await processTransformRange(
                store: store,
                recordAccess: recordAccess,
                rangeBegin: rangeBegin,
                rangeEnd: rangeEnd,
                config: config,
                transform: transform,
                rangeSet: rangeSet
            )
        }
    }

    /// Process a range with proper continuation and atomicity
    ///
    /// **Critical design**:
    /// - Outer `while` loop continues until entire range processed
    /// - Inner `for` loop processes single batch
    /// - Data + progress updates in SAME transaction (atomic)
    /// - Uses successor() to avoid key duplication
    ///
    /// - Parameters:
    ///   - store: RecordStore to transform
    ///   - recordAccess: Record accessor
    ///   - rangeBegin: Start of range
    ///   - rangeEnd: End of range
    ///   - config: Batch configuration
    ///   - transform: Transformation function
    ///   - rangeSet: Progress tracker
    /// - Throws: RecordLayerError if processing fails
    private func processTransformRange<Record: Recordable>(
        store: RecordStore<Record>,
        recordAccess: GenericRecordAccess<Record>,
        rangeBegin: FDB.Bytes,
        rangeEnd: FDB.Bytes,
        config: BatchConfig,
        transform: @escaping @Sendable (Record) async throws -> Record,
        rangeSet: RangeSet
    ) async throws {
        var currentBegin = rangeBegin

        // ✅ Outer loop: Continue until entire range is processed
        while currentBegin.lexicographicallyPrecedes(rangeEnd) {
            let batchResult = try await processSingleBatch(
                store: store,
                recordAccess: recordAccess,
                batchBegin: currentBegin,
                rangeEnd: rangeEnd,
                config: config,
                transform: transform
            )

            // Check if batch is empty (end of range)
            guard !batchResult.transformedRecords.isEmpty else {
                break
            }

            // ✅ ATOMIC: Commit batch + update progress in SAME transaction
            try await database.withTransaction { transaction in
                let context = RecordContext(transaction: transaction)
                defer { context.cancel() }

                // 1. Save transformed records
                for record in batchResult.transformedRecords {
                    try await store.saveInternal(record, context: context)
                }

                // 2. Mark progress (SAME transaction ensures consistency)
                // CRITICAL: Use successor to make range inclusive of lastKey
                // RangeSet treats [begin, end) as completed, so we need end = successor(lastKey)
                // to include lastKey itself in the completed range
                try await rangeSet.insertRange(
                    begin: currentBegin,
                    end: successor(of: batchResult.lastKey),
                    context: context
                )

                // ✅ Both commit together or both rollback
                try await context.commit()
            }

            // ✅ Resume from successor of last processed key
            currentBegin = successor(of: batchResult.lastKey)
        }
    }

    /// Batch processing result
    private struct BatchResult<Record: Recordable> {
        let transformedRecords: [Record]
        let lastKey: FDB.Bytes
    }

    /// Process a single batch of records
    ///
    /// - Parameters:
    ///   - store: RecordStore to process
    ///   - recordAccess: Record accessor
    ///   - batchBegin: Start key
    ///   - rangeEnd: End key
    ///   - config: Batch configuration
    ///   - transform: Transformation function
    /// - Returns: Batch result
    /// - Throws: RecordLayerError if processing fails
    private func processSingleBatch<Record: Recordable>(
        store: RecordStore<Record>,
        recordAccess: GenericRecordAccess<Record>,
        batchBegin: FDB.Bytes,
        rangeEnd: FDB.Bytes,
        config: BatchConfig,
        transform: @escaping @Sendable (Record) async throws -> Record
    ) async throws -> BatchResult<Record> {
        var transformedRecords: [Record] = []
        var lastKey: FDB.Bytes = batchBegin
        var accumulatedBytes: Int = 0
        let startTime = Date()

        // Create snapshot read transaction
        try await database.withTransaction { transaction in
            let sequence = transaction.getRange(
                begin: batchBegin,
                end: rangeEnd,
                snapshot: true  // Snapshot read: no conflicts
            )

            // Process batch with limits
            for try await (key, value) in sequence {
                // Apply transformation
                let record = try recordAccess.deserialize(value)
                let transformed = try await transform(record)
                transformedRecords.append(transformed)
                lastKey = key

                // Accumulate bytes (key + value size)
                accumulatedBytes += key.count + value.count

                // Check limits
                if transformedRecords.count >= config.maxRecordsPerBatch {
                    break
                }

                if accumulatedBytes >= config.maxBytesPerBatch {
                    break
                }

                if Date().timeIntervalSince(startTime) >= config.maxTimePerBatch {
                    break
                }
            }
        }

        return BatchResult(transformedRecords: transformedRecords, lastKey: lastKey)
    }

    /// Get the next key after the given key
    ///
    /// This is critical for resuming range scans without duplicates.
    /// FDB range reads are inclusive on both ends, so using the same key
    /// as begin would re-read the last record.
    ///
    /// - Parameter key: The current key
    /// - Returns: The lexicographically next key
    private func successor(of key: FDB.Bytes) -> FDB.Bytes {
        var nextKey = key
        // Append 0x00 byte to get the next possible key
        nextKey.append(0x00)
        return nextKey
    }

    /// Delete records matching a predicate
    ///
    /// **Redesigned for production use**:
    /// - RangeSet-based progress tracking for resumability
    /// - Batch processing to respect FDB limits (5s, 10MB)
    /// - Atomic transactions (data + progress)
    ///
    /// - Parameters:
    ///   - recordType: The record type to delete from
    ///   - predicate: Predicate to match records for deletion
    ///   - config: Batch configuration
    /// - Throws: RecordLayerError if deletion fails
    public func deleteRecords<Record: Recordable>(
        recordType: String,
        where predicate: @escaping @Sendable (Record) -> Bool,
        config: BatchConfig = .makeDefault()
    ) async throws {
        // Get RecordStore from factory
        guard let store = try storeFactory(recordType) as? RecordStore<Record> else {
            throw RecordLayerError.internalError(
                "Failed to get RecordStore<\(Record.self)> from factory for recordType '\(recordType)'"
            )
        }

        // Setup progress tracking
        let progressSubspace = metadataSubspace
            .subspace("migration")
            .subspace("delete")
            .subspace(recordType)
        let rangeSet = RangeSet(database: database, subspace: progressSubspace)

        let recordAccess = GenericRecordAccess<Record>()
        let effectiveSubspace = store.recordSubspace.subspace(Record.recordName)
        let totalRange = effectiveSubspace.range()

        // Find incomplete ranges
        let missingRanges = try await rangeSet.missingRanges(
            fullBegin: totalRange.begin,
            fullEnd: totalRange.end
        )

        // Process each incomplete range
        for (rangeBegin, rangeEnd) in missingRanges {
            try await processDeleteRange(
                store: store,
                recordAccess: recordAccess,
                rangeBegin: rangeBegin,
                rangeEnd: rangeEnd,
                config: config,
                predicate: predicate,
                rangeSet: rangeSet
            )
        }
    }

    /// Process a range for deletion with batching
    private func processDeleteRange<Record: Recordable>(
        store: RecordStore<Record>,
        recordAccess: GenericRecordAccess<Record>,
        rangeBegin: FDB.Bytes,
        rangeEnd: FDB.Bytes,
        config: BatchConfig,
        predicate: @escaping @Sendable (Record) -> Bool,
        rangeSet: RangeSet
    ) async throws {
        var currentBegin = rangeBegin

        while currentBegin.lexicographicallyPrecedes(rangeEnd) {
            let batchResult = try await processSingleDeleteBatch(
                store: store,
                recordAccess: recordAccess,
                batchBegin: currentBegin,
                rangeEnd: rangeEnd,
                config: config,
                predicate: predicate
            )

            // If no records were scanned, we've reached the end of the range
            guard batchResult.scannedCount > 0 else {
                break
            }

            // Atomic: Delete matching records (if any) + mark progress
            try await database.withTransaction { transaction in
                let context = RecordContext(transaction: transaction)
                defer { context.cancel() }

                // Delete matching records (may be empty if predicate matched nothing)
                for primaryKey in batchResult.keysToDelete {
                    try await store.deleteInternal(by: primaryKey, context: context)
                }

                // Always mark progress, even if no records matched the predicate
                // This ensures we don't get stuck on ranges with no matching records
                try await rangeSet.insertRange(
                    begin: currentBegin,
                    end: successor(of: batchResult.lastKey),
                    context: context
                )

                try await context.commit()
            }

            currentBegin = successor(of: batchResult.lastKey)
        }
    }

    /// Batch deletion result
    private struct DeleteBatchResult {
        let keysToDelete: [Tuple]
        let lastKey: FDB.Bytes
        let scannedCount: Int  // Total records scanned (regardless of predicate match)
    }

    /// Process a single batch for deletion
    private func processSingleDeleteBatch<Record: Recordable>(
        store: RecordStore<Record>,
        recordAccess: GenericRecordAccess<Record>,
        batchBegin: FDB.Bytes,
        rangeEnd: FDB.Bytes,
        config: BatchConfig,
        predicate: @escaping @Sendable (Record) -> Bool
    ) async throws -> DeleteBatchResult {
        var keysToDelete: [Tuple] = []
        var lastKey: FDB.Bytes = batchBegin
        var scannedCount: Int = 0
        var accumulatedBytes: Int = 0
        let startTime = Date()

        // Snapshot read transaction
        try await database.withTransaction { transaction in
            let sequence = transaction.getRange(
                begin: batchBegin,
                end: rangeEnd,
                snapshot: true
            )

            for try await (key, value) in sequence {
                let record = try recordAccess.deserialize(value)
                scannedCount += 1

                // Apply predicate
                if predicate(record) {
                    let primaryKey = recordAccess.extractPrimaryKey(from: record)
                    keysToDelete.append(primaryKey)
                }

                lastKey = key
                accumulatedBytes += key.count + value.count

                // Check limits
                if keysToDelete.count >= config.maxRecordsPerBatch {
                    break
                }

                if accumulatedBytes >= config.maxBytesPerBatch {
                    break
                }

                if Date().timeIntervalSince(startTime) >= config.maxTimePerBatch {
                    break
                }
            }
        }

        return DeleteBatchResult(keysToDelete: keysToDelete, lastKey: lastKey, scannedCount: scannedCount)
    }

    // MARK: - Utility

    /// Execute arbitrary database operation
    ///
    /// - Parameter operation: Operation to execute
    /// - Returns: Operation result
    /// - Throws: Any error from the operation
    public func executeOperation<T: Sendable>(
        _ operation: @escaping @Sendable (any TransactionProtocol) async throws -> T
    ) async throws -> T {
        return try await database.withTransaction { transaction in
            try await operation(transaction)
        }
    }
}

// MARK: - Migration Extensions

extension Migration: Identifiable {
    public var id: String {
        return "\(fromVersion)-\(toVersion)"
    }
}
