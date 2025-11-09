import Foundation
import FoundationDB

/// IndexManager coordinates index maintenance operations
///
/// IndexManager is responsible for keeping indexes up-to-date when records are
/// saved, updated, or deleted. It works with IndexMaintainer implementations
/// to update each index type.
///
/// **Implementation Status**: OK: **Fully Implemented**
///
/// IndexManager now provides complete index maintenance for all 6 index types:
/// - **VALUE**: Standard B-tree indexes
/// - **COUNT**: Count aggregation indexes
/// - **SUM**: Sum aggregation indexes
/// - **RANK**: Leaderboard/ranking indexes
/// - **VERSION**: Version tracking indexes (OCC)
/// - **PERMUTED**: Permuted indexes (alternative orderings)
///
/// **使用例**:
/// ```swift
/// let indexManager = IndexManager(metaData: metaData, subspace: indexSubspace)
///
/// // Update indexes when saving a record
/// try await indexManager.updateIndexes(
///     for: user,
///     primaryKey: Tuple([user.id]),
///     oldRecord: existingUser,  // nil if inserting
///     context: context,
///     recordSubspace: recordSubspace
/// )
///
/// // Delete index entries when deleting a record
/// try await indexManager.deleteIndexes(
///     oldRecord: user,
///     primaryKey: Tuple([user.id]),
///     context: context,
///     recordSubspace: recordSubspace
/// )
/// ```
///
/// **Integration**:
/// IndexManager is automatically called by RecordStore during save() and delete() operations.
/// No manual intervention is required for standard CRUD operations.
public final class IndexManager: Sendable {
    // MARK: - Properties

    public let schema: Schema
    public let subspace: Subspace

    // MARK: - Initialization

    /// Initialize IndexManager
    ///
    /// - Parameters:
    ///   - schema: The schema containing entity definitions
    ///   - subspace: The subspace for storing index data
    public init(schema: Schema, subspace: Subspace) {
        self.schema = schema
        self.subspace = subspace
    }

    // MARK: - Index Updates

    /// Update indexes for a saved record
    ///
    /// This method is called when a record is saved (insert or update).
    /// It updates all indexes that apply to the record type.
    ///
    /// - Parameters:
    ///   - record: The record being saved (must conform to Recordable)
    ///   - primaryKey: The primary key of the record
    ///   - oldRecord: The old record (nil if inserting)
    ///   - context: The record context for database operations
    ///   - recordSubspace: The subspace for storing record data
    public func updateIndexes<T: Recordable>(
        for record: T,
        primaryKey: Tuple,
        oldRecord: T? = nil,
        context: RecordContext,
        recordSubspace: Subspace
    ) async throws {
        let recordName = T.recordName
        let applicableIndexes = getApplicableIndexes(for: recordName)

        guard !applicableIndexes.isEmpty else {
            return  // No indexes to maintain
        }

        // Create RecordAccess for this record type
        let recordAccess = GenericRecordAccess<T>()

        // Get transaction from context
        let transaction = context.getTransaction()

        // Update each applicable index
        for index in applicableIndexes {
            // Get subspace for this index
            let indexSubspace = self.indexSubspace(for: index.name)

            // Create maintainer for this index type
            let maintainer: AnyGenericIndexMaintainer<T> = try createMaintainer(
                for: index,
                indexSubspace: indexSubspace,
                recordSubspace: recordSubspace
            )

            // Update the index
            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: record,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }
    }

    /// Delete index entries for a deleted record
    ///
    /// This method is called when a record is deleted.
    /// It removes all index entries for the record.
    ///
    /// - Parameters:
    ///   - oldRecord: The record being deleted
    ///   - primaryKey: The primary key of the deleted record
    ///   - context: The record context for database operations
    ///   - recordSubspace: The subspace for storing record data
    public func deleteIndexes<T: Recordable>(
        oldRecord: T,
        primaryKey: Tuple,
        context: RecordContext,
        recordSubspace: Subspace
    ) async throws {
        let recordName = T.recordName
        let applicableIndexes = getApplicableIndexes(for: recordName)

        guard !applicableIndexes.isEmpty else {
            return  // No indexes to maintain
        }

        // Create RecordAccess for this record type
        let recordAccess = GenericRecordAccess<T>()

        // Get transaction from context
        let transaction = context.getTransaction()

        // Delete from each applicable index
        for index in applicableIndexes {
            // Get subspace for this index
            let indexSubspace = self.indexSubspace(for: index.name)

            // Create maintainer for this index type
            let maintainer: AnyGenericIndexMaintainer<T> = try createMaintainer(
                for: index,
                indexSubspace: indexSubspace,
                recordSubspace: recordSubspace
            )

            // Delete the index entry (oldRecord = deleted record, newRecord = nil)
            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: nil as T?,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }
    }

    // MARK: - Helpers

    /// Get indexes that apply to a specific record type
    ///
    /// - Parameter recordName: The record type name
    /// - Returns: Array of applicable indexes
    internal func getApplicableIndexes(for recordName: String) -> [Index] {
        return schema.indexes(for: recordName)
    }

    /// Get the subspace for a specific index
    ///
    /// - Parameter indexName: The index name
    /// - Returns: The subspace for storing this index's data
    internal func indexSubspace(for indexName: String) -> Subspace {
        return subspace.subspace(Tuple([indexName]))
    }

    /// Create an index maintainer for a specific index type
    ///
    /// This factory method creates the appropriate maintainer based on the index type.
    ///
    /// - Parameters:
    ///   - index: The index definition
    ///   - indexSubspace: The subspace for this index's data
    ///   - recordSubspace: The subspace for record data
    /// - Returns: Type-erased index maintainer
    /// - Throws: RecordLayerError if index type is not supported
    private func createMaintainer<T: Recordable>(
        for index: Index,
        indexSubspace: Subspace,
        recordSubspace: Subspace
    ) throws -> AnyGenericIndexMaintainer<T> {
        switch index.type {
        case .value:
            let maintainer = GenericValueIndexMaintainer<T>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .count:
            let maintainer = GenericCountIndexMaintainer<T>(
                index: index,
                subspace: indexSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .sum:
            let maintainer = GenericSumIndexMaintainer<T>(
                index: index,
                subspace: indexSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .rank:
            let maintainer = RankIndexMaintainer<T>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .version:
            let maintainer = VersionIndexMaintainer<T>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .permuted:
            let maintainer = try GenericPermutedIndexMaintainer<T>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)
        }
    }
}

// MARK: - Future Enhancements

extension IndexManager {
    // Future methods to be implemented:
    //
    // - func rebuildIndex(_ indexName: String) async throws
    //   Rebuild a single index from scratch
    //
    // - func rebuildAllIndexes() async throws
    //   Rebuild all indexes for all record types
    //
    // - func getIndexState(_ indexName: String) async throws -> IndexState
    //   Get the current state of an index (ready, building, disabled, etc.)
    //
    // - func markIndexReadable(_ indexName: String) async throws
    //   Mark an index as readable after building
}
