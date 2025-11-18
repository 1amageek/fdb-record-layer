import Foundation
import FoundationDB

/// No-op maintainer for HNSW indexes with batch-only indexing strategy
///
/// **Purpose**: When `VectorIndexStrategy` is `.hnsw(inlineIndexing: false)`, this maintainer
/// is used to skip inline index updates during `RecordStore.save()` operations.
///
/// **Why This Exists**:
/// - HNSW insertion requires ~12,000 FDB operations for medium graphs
/// - User transactions WILL timeout (5-second limit) if inline indexing is attempted
/// - `.hnswBatch` (aka `.hnsw(inlineIndexing: false)`) explicitly disables inline updates
/// - Index MUST be built using `OnlineIndexer.buildHNSWIndex()` exclusively
///
/// **Design**: This maintainer implements `GenericIndexMaintainer` protocol but performs NO operations.
/// - `updateIndex()`: Silently succeeds without modifying index data
/// - `search()`: Not implemented (should never be called; search uses GenericHNSWIndexMaintainer)
///
/// **State Lifecycle**:
/// 1. Index starts as `.disabled` (default)
/// 2. OnlineIndexer calls `enable()` → `.writeOnly` (this maintainer is active)
/// 3. OnlineIndexer builds graph using batched transactions
/// 4. OnlineIndexer calls `makeReadable()` → `.readable` (search uses GenericHNSWIndexMaintainer)
///
/// **Alternative Considered**: Modify GenericHNSWIndexMaintainer to check inlineIndexing flag.
/// **Rejected**: Violates single responsibility principle. No-op maintainer is clearer and safer.
///
/// **Reference**: docs/hnsw_inline_indexing_protection.md
public final class VectorIndexNoOpMaintainer<Record: Sendable>: GenericIndexMaintainer, Sendable {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    public init(
        index: Index,
        subspace: Subspace,
        recordSubspace: Subspace
    ) throws {
        self.index = index
        self.subspace = subspace
        self.recordSubspace = recordSubspace
    }

    /// No-op update: silently succeeds without modifying index data
    ///
    /// **Why**: `.hnsw(inlineIndexing: false)` explicitly disables inline updates.
    /// Index MUST be built using `OnlineIndexer.buildHNSWIndex()`.
    ///
    /// **State**: This maintainer is only active when IndexState is `.writeOnly` (during build).
    /// Once IndexState becomes `.readable`, queries use GenericHNSWIndexMaintainer for search.
    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // No-op: intentionally does nothing
        // HNSW graph is built exclusively by OnlineIndexer in batched transactions
    }

    /// No-op scan: silently succeeds without modifying index data
    ///
    /// **Why**: `.hnsw(inlineIndexing: false)` explicitly disables inline updates.
    /// Index MUST be built using `OnlineIndexer.buildHNSWIndex()`.
    ///
    /// **Note**: This method is called by OnlineIndexer during index building,
    /// but for batch-only HNSW indexes, the actual graph construction is done
    /// by OnlineIndexer.buildHNSWIndex() using specialized batch methods.
    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // No-op: intentionally does nothing
        // HNSW graph is built exclusively by OnlineIndexer.buildHNSWIndex()
    }

    /// Search is not supported by No-op maintainer
    ///
    /// **Note**: This method should never be called because:
    /// - During `.writeOnly` state (when No-op is active), queries throw `.indexNotReadable`
    /// - During `.readable` state, `TypedVectorQuery` uses GenericHNSWIndexMaintainer for search
    ///
    /// If this method is called, it indicates a logic error in the query execution path.
    public func search(
        queryVector: [Float32],
        k: Int,
        transaction: any TransactionProtocol
    ) async throws -> [(primaryKey: Tuple, distance: Double)] {
        throw RecordLayerError.internalError(
            "VectorIndexNoOpMaintainer.search() should never be called. " +
            "Queries should use GenericHNSWIndexMaintainer when IndexState is .readable. " +
            "If you see this error, there is a logic error in the query execution path."
        )
    }
}
