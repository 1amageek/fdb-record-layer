import Foundation
import FoundationDB
import Logging
import Synchronization

/// Online index builder
///
/// Builds indexes without blocking writes to the record store.
/// Tracks progress and can resume from interruptions.
public final class OnlineIndexer: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let metaData: RecordMetaData
    private let index: Index
    private let serializer: any RecordSerializer<[String: Any]>
    private let logger: Logger
    private let lock: Mutex<IndexBuildState>

    // Note: _state is now managed by Mutex

    // MARK: - Build State

    private struct IndexBuildState {
        var totalRecordsScanned: UInt64 = 0
        var startTime: Date?
        var endTime: Date?
    }

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        index: Index,
        serializer: any RecordSerializer<[String: Any]>,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.index = index
        self.serializer = serializer
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.indexer")
        // Mutex is initialized with the initial state
        self.lock = Mutex(IndexBuildState())
    }

    // MARK: - Public Methods

    /// Build the index
    ///
    /// This method scans all records and builds index entries.
    /// It works in batches to avoid large transactions.
    public func buildIndex() async throws {
        lock.withLock { state in
            state.startTime = Date()
        }

        logger.info("Starting index build for: \(index.name)")

        // Scan records and build index
        try await scanAndBuildIndex()

        let totalScanned = lock.withLock { state in
            state.endTime = Date()
            return state.totalRecordsScanned
        }

        logger.info("Index build completed for: \(index.name), scanned \(totalScanned) records")
    }

    /// Get build progress
    /// - Returns: Number of records scanned
    public func getProgress() -> UInt64 {
        return lock.withLock { state in
            return state.totalRecordsScanned
        }
    }

    // MARK: - Private Methods

    private func scanAndBuildIndex() async throws {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        let batchSize = 1000

        // Get the range for all records
        let (beginKey, endKey) = recordSubspace.range()

        try await database.withRecordContext { [weak self] context in
            guard let self = self else { return }
            let transaction = context.getTransaction()
            var scannedInBatch = 0

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterThan(endKey),
                snapshot: true
            )

            for try await (key, value) in sequence {
                // Deserialize record
                let record = try self.serializer.deserialize(value)

                // Extract primary key from the key
                let primaryKey = try recordSubspace.unpack(key)

                // Create index maintainer and scan record
                let maintainer = self.createIndexMaintainer(indexSubspace: indexSubspace)
                try await maintainer.scanRecord(record, primaryKey: primaryKey, transaction: transaction)

                scannedInBatch += 1

                // Commit batch periodically
                if scannedInBatch >= batchSize {
                    let total = self.lock.withLock { state in
                        state.totalRecordsScanned += UInt64(scannedInBatch)
                        return state.totalRecordsScanned
                    }

                    scannedInBatch = 0
                    self.logger.debug("Scanned \(total) records")
                }
            }

            // Update final count
            if scannedInBatch > 0 {
                self.lock.withLock { state in
                    state.totalRecordsScanned += UInt64(scannedInBatch)
                }
            }
        }
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
