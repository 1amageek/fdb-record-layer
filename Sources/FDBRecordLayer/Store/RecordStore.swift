import Foundation
import FoundationDB
import Logging

/// Record store for managing records and indexes
///
/// RecordStore is the main interface for storing and retrieving records.
/// It automatically maintains indexes and enforces the schema defined in RecordMetaData.
public final class RecordStore<Record: Sendable>: RecordStoreProtocol, Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    public let subspace: Subspace
    public let metaData: RecordMetaData
    private let serializer: any RecordSerializer<Record>
    private let logger: Logger
    private let indexStateManager: IndexStateManager

    // Subspaces
    private let recordSubspace: Subspace
    private let indexSubspace: Subspace
    private let indexStateSubspace: Subspace
    private let storeInfoSubspace: Subspace

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        serializer: any RecordSerializer<Record>,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.serializer = serializer
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.store")
        self.indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace,
            logger: logger
        )

        // Initialize subspaces
        self.recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        self.indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
        self.indexStateSubspace = subspace.subspace(RecordStoreKeyspace.indexState.rawValue)
        self.storeInfoSubspace = subspace.subspace(RecordStoreKeyspace.storeInfo.rawValue)
    }

    // MARK: - Record Operations

    /// Save a record
    ///
    /// If the record already exists (same primary key), it will be updated.
    /// All indexes are automatically maintained.
    public func save(_ record: Record, context: RecordContext) async throws {
        logger.debug("Saving record")

        let transaction = context.getTransaction()

        // For dictionary-based records, we can extract type and primary key
        // In a real implementation with Protobuf, this would use reflection
        guard let recordDict = record as? [String: Any] else {
            throw RecordLayerError.internalError("Record must be a dictionary for this implementation")
        }

        guard let recordTypeName = recordDict["_type"] as? String else {
            throw RecordLayerError.internalError("Record must have _type field")
        }

        let recordType = try metaData.getRecordType(recordTypeName)

        // Extract primary key
        let primaryKeyValues = recordType.primaryKey.evaluate(record: recordDict)
        let primaryKey = TupleHelpers.toTuple(primaryKeyValues)

        // Load existing record for index updates
        let existingRecord = try await load(primaryKey: primaryKey, context: context)

        // Serialize new record
        let serialized = try serializer.serialize(record)

        // Save record
        let recordKey = recordSubspace.pack(primaryKey)
        transaction.setValue(serialized, for: recordKey)

        // Update indexes
        try await updateIndexesForRecord(
            oldRecord: existingRecord,
            newRecord: record,
            recordType: recordType,
            recordDict: recordDict,
            transaction: transaction
        )

        logger.debug("Record saved successfully")
    }

    /// Load a record by primary key
    public func load(primaryKey: Tuple, context: RecordContext) async throws -> Record? {
        logger.debug("Loading record with primary key")

        let transaction = context.getTransaction()
        let recordKey = recordSubspace.pack(primaryKey)

        guard let bytes = try await transaction.getValue(for: recordKey) else {
            logger.debug("Record not found")
            return nil
        }

        let record = try serializer.deserialize(bytes)
        logger.debug("Record loaded successfully")
        return record
    }

    /// Delete a record by primary key
    public func delete(primaryKey: Tuple, context: RecordContext) async throws {
        logger.debug("Deleting record with primary key")

        let transaction = context.getTransaction()

        // Load existing record for index updates
        guard let existingRecord = try await load(primaryKey: primaryKey, context: context) else {
            logger.debug("Record not found, nothing to delete")
            return
        }

        guard let recordDict = existingRecord as? [String: Any] else {
            throw RecordLayerError.internalError("Record must be a dictionary")
        }

        guard let recordTypeName = recordDict["_type"] as? String else {
            throw RecordLayerError.internalError("Record must have _type field")
        }

        let recordType = try metaData.getRecordType(recordTypeName)

        // Delete record
        let recordKey = recordSubspace.pack(primaryKey)
        transaction.clear(key: recordKey)

        // Update indexes
        try await updateIndexesForRecord(
            oldRecord: existingRecord,
            newRecord: nil,
            recordType: recordType,
            recordDict: recordDict,
            transaction: transaction
        )

        logger.debug("Record deleted successfully")
    }

    // MARK: - Index Management

    /// Get index state
    ///
    /// Delegates to IndexStateManager for consistent state management
    public func indexState(of indexName: String, context: RecordContext) async throws -> IndexState {
        return try await indexStateManager.state(of: indexName, context: context)
    }

    // MARK: - Internal Methods

    private func updateIndexesForRecord(
        oldRecord: Record?,
        newRecord: Record?,
        recordType: RecordType,
        recordDict: [String: Any],
        transaction: any TransactionProtocol
    ) async throws {
        let indexes = metaData.getIndexesForRecordType(recordType.name)

        for index in indexes {
            let maintainer = createIndexMaintainer(for: index)

            let oldDict = oldRecord as? [String: Any]
            let newDict = newRecord as? [String: Any]

            try await maintainer.updateIndex(
                oldRecord: oldDict,
                newRecord: newDict,
                transaction: transaction
            )
        }
    }

    private func createIndexMaintainer(for index: Index) -> any IndexMaintainer {
        let indexSubspace = self.indexSubspace.subspace(index.subspaceTupleKey)

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
