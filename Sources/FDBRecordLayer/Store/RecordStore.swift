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
        try await save(record, expectedVersion: nil, context: context)
    }

    /// Save a record with optimistic concurrency control
    ///
    /// If the record already exists (same primary key), it will be updated.
    /// All indexes are automatically maintained.
    ///
    /// - Parameters:
    ///   - record: The record to save
    ///   - expectedVersion: The expected version for optimistic locking (nil for first save)
    ///   - context: Transaction context
    /// - Throws: RecordLayerError.versionMismatch if version doesn't match
    public func save(_ record: Record, expectedVersion: Version?, context: RecordContext) async throws {
        logger.debug("Saving record with version check")

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

        // Check version if expectedVersion is provided
        if let expectedVersion = expectedVersion {
            try await checkVersionForRecord(
                primaryKey: primaryKey,
                expectedVersion: expectedVersion,
                context: context
            )
        }

        // Fetch existing record for index updates
        let existingRecord = try await fetch(primaryKey: primaryKey, context: context)

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
            context: context
        )

        logger.debug("Record saved successfully")
    }

    /// Fetch a record by primary key
    public func fetch(primaryKey: Tuple, context: RecordContext) async throws -> Record? {
        logger.debug("Fetching record with primary key")

        let transaction = context.getTransaction()
        let recordKey = recordSubspace.pack(primaryKey)

        guard let bytes = try await transaction.getValue(for: recordKey) else {
            logger.debug("Record not found")
            return nil
        }

        let record = try serializer.deserialize(bytes)
        logger.debug("Record fetched successfully")
        return record
    }

    /// Fetch a record with its current version
    ///
    /// - Parameters:
    ///   - primaryKey: The primary key of the record
    ///   - context: Transaction context
    /// - Returns: Tuple of (record, version), or nil if record not found
    public func fetchWithVersion(primaryKey: Tuple, context: RecordContext) async throws -> (record: Record, version: Version)? {
        logger.debug("Fetching record with version")

        // Fetch the record
        guard let record = try await fetch(primaryKey: primaryKey, context: context) else {
            logger.debug("Record not found")
            return nil
        }

        // Get version from version index
        let version = try await getVersionForRecord(primaryKey: primaryKey, context: context)

        guard let version = version else {
            logger.debug("Version not found for record")
            return nil
        }

        logger.debug("Record with version fetched successfully")
        return (record: record, version: version)
    }

    /// Delete a record by primary key
    public func delete(primaryKey: Tuple, context: RecordContext) async throws {
        logger.debug("Deleting record with primary key")

        let transaction = context.getTransaction()

        // Fetch existing record for index updates
        guard let existingRecord = try await fetch(primaryKey: primaryKey, context: context) else {
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
            context: context
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

    /// Filter indexes to only those that should be maintained
    ///
    /// - Parameter context: Transaction context for consistent state reading
    /// - Returns: List of maintainable indexes
    private func filterMaintainableIndexes(context: RecordContext) async throws -> [Index] {
        let allIndexes = Array(metaData.indexes.values)
        let indexNames = allIndexes.map { $0.name }
        let states = try await indexStateManager.states(of: indexNames, context: context)

        return allIndexes.filter { index in
            guard let state = states[index.name] else { return false }
            return state.shouldMaintain
        }
    }

    /// Check version for optimistic concurrency control
    private func checkVersionForRecord(
        primaryKey: Tuple,
        expectedVersion: Version,
        context: RecordContext
    ) async throws {
        // LIMITATION: Uses first version index found, ignoring record type
        //
        // In production, this should:
        // 1. Accept recordType parameter
        // 2. Filter indexes by recordTypes field
        // 3. Throw error if multiple version indexes match
        // 4. Support per-record-type version indexes
        let versionIndex = metaData.indexes.values.first { $0.type == .version }

        guard let versionIndex = versionIndex else {
            throw RecordLayerError.internalError("No version index configured for optimistic locking")
        }

        // Create version maintainer and check version
        let maintainer = createIndexMaintainer(for: versionIndex)
        guard let versionMaintainer = maintainer as? VersionIndexMaintainer else {
            throw RecordLayerError.internalError("Version index maintainer not found")
        }

        try await versionMaintainer.checkVersion(
            primaryKey: primaryKey,
            expectedVersion: expectedVersion,
            transaction: context.getTransaction()
        )
    }

    /// Get current version for a record
    private func getVersionForRecord(
        primaryKey: Tuple,
        context: RecordContext
    ) async throws -> Version? {
        // LIMITATION: Uses first version index found, ignoring record type
        let versionIndex = metaData.indexes.values.first { $0.type == .version }

        guard let versionIndex = versionIndex else {
            return nil
        }

        // Create version maintainer and get current version
        let maintainer = createIndexMaintainer(for: versionIndex)
        guard let versionMaintainer = maintainer as? VersionIndexMaintainer else {
            return nil
        }

        return try await versionMaintainer.getCurrentVersion(
            primaryKey: primaryKey,
            transaction: context.getTransaction()
        )
    }

    private func updateIndexesForRecord(
        oldRecord: Record?,
        newRecord: Record?,
        recordType: RecordType,
        recordDict: [String: Any],
        context: RecordContext
    ) async throws {
        let transaction = context.getTransaction()

        // Only update indexes that should be maintained (checking state)
        let maintainableIndexes = try await filterMaintainableIndexes(context: context)

        // Filter to indexes for this record type
        let relevantIndexes = maintainableIndexes.filter { index in
            if let recordTypes = index.recordTypes {
                return recordTypes.contains(recordType.name)
            }
            return true  // Universal index
        }

        for index in relevantIndexes {
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
        case .version:
            return VersionIndexMaintainer(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
        case .permuted:
            return try! PermutedIndexMaintainer(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
        case .rank:
            return RankIndexMaintainer(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
        }
    }
}
