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
/// **Usage Example**:
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

    /// Root subspace for global indexes
    ///
    /// When provided, global-scoped indexes will be stored under `rootSubspace.subspace("G")`
    /// instead of under the partition's index subspace. This enables cross-partition queries.
    public let rootSubspace: Subspace?

    // MARK: - Initialization

    /// Initialize IndexManager
    ///
    /// - Parameters:
    ///   - schema: The schema containing entity definitions
    ///   - subspace: The subspace for storing partition-local index data
    ///   - rootSubspace: Optional root subspace for global indexes (defaults to subspace for backward compatibility)
    public init(schema: Schema, subspace: Subspace, rootSubspace: Subspace? = nil) {
        self.schema = schema
        self.subspace = subspace
        self.rootSubspace = rootSubspace
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
    internal func updateIndexes<T: Recordable>(
        for record: T,
        primaryKey: Tuple,
        oldRecord: T? = nil,
        context: TransactionContext,
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
            // Get subspace for this index (supports global scope)
            let indexSubspace = self.indexSubspace(for: index)

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
    internal func deleteIndexes<T: Recordable>(
        oldRecord: T,
        primaryKey: Tuple,
        context: TransactionContext,
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
            // Get subspace for this index (supports global scope)
            let indexSubspace = self.indexSubspace(for: index)

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
    /// Get the subspace for a specific index
    ///
    /// Returns the appropriate subspace based on the index scope:
    /// - `.partition`: Index within the current partition subspace
    /// - `.global`: Index in a shared global space outside any partition
    ///
    /// **Partition-local index**:
    /// ```
    /// [partition-prefix][I][index_name]
    /// ```
    ///
    /// **Global index**:
    /// ```
    /// [root-subspace][global-indexes][index_name]
    /// ```
    ///
    /// - Parameter index: The index definition
    /// - Returns: Subspace for the index
    internal func indexSubspace(for index: Index) -> Subspace {
        switch index.scope {
        case .partition:
            // Partition-local index: within current partition
            return subspace.subspace(index.name)

        case .global:
            // Global index: cross-partition shared indexes
            // Use root subspace if provided, otherwise fall back to partition subspace (for backward compatibility)
            if let root = rootSubspace {
                // Correct: Store under [root][G][index_name] for cross-partition access
                return root.subspace("G").subspace(index.name)
            } else {
                // Backward compatibility: Fall back to old behavior
                // This will still store under partition, but at least won't break existing code
                return subspace.subspace("global-indexes").subspace(index.name)
            }
        }
    }

    /// Get the subspace for a specific index by name (deprecated - use index object)
    ///
    /// This method assumes partition scope and should only be used for backward compatibility.
    /// For new code, use `indexSubspace(for: Index)` which supports global scope.
    ///
    /// - Parameter indexName: The index name
    /// - Returns: Subspace for the index (assumes partition scope)
    internal func indexSubspace(for indexName: String) -> Subspace {
        // Backward compatibility: assume partition scope
        return subspace.subspace(indexName)
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

        case .min:
            let maintainer = GenericMinIndexMaintainer<T>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)

        case .max:
            let maintainer = GenericMaxIndexMaintainer<T>(
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

        case .vector:
            // Select maintainer based on vector index strategy from Schema (runtime configuration)
            guard index.options.vectorOptions != nil else {
                throw RecordLayerError.invalidArgument("Vector index requires vectorOptions")
            }

            // ✅ Read strategy from Schema (runtime configuration)
            // Separates data structure (VectorIndexOptions) from runtime optimization (IndexConfiguration)
            let strategy = schema.getVectorStrategy(for: index.name)

            switch strategy {
            case .flatScan:
                // Flat scan: O(n) search, lower memory
                let maintainer = try GenericVectorIndexMaintainer<T>(
                    index: index,
                    subspace: indexSubspace,
                    recordSubspace: recordSubspace
                )
                return AnyGenericIndexMaintainer(maintainer)

            case .hnsw(let inlineIndexing):
                // HNSW: O(log n) search, higher memory
                // ✅ Check inlineIndexing flag to determine maintainer type
                if inlineIndexing {
                    // ⚠️ Inline indexing: WILL timeout for medium-sized graphs (>1000 nodes)
                    // This path exists only for completeness; NOT recommended for production
                    let maintainer = try GenericHNSWIndexMaintainer<T>(
                        index: index,
                        subspace: indexSubspace,
                        recordSubspace: recordSubspace
                    )
                    return AnyGenericIndexMaintainer(maintainer)
                } else {
                    // ✅ Batch-only indexing (recommended): Skip inline updates
                    // Index MUST be built using OnlineIndexer.buildHNSWIndex()
                    // This No-op maintainer prevents RecordStore.save() from failing
                    let maintainer = try VectorIndexNoOpMaintainer<T>(
                        index: index,
                        subspace: indexSubspace,
                        recordSubspace: recordSubspace
                    )
                    return AnyGenericIndexMaintainer(maintainer)
                }
            }

        case .spatial:
            let maintainer = SpatialIndexMaintainer<T>(
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
