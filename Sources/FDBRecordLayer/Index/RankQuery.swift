import Foundation
import FoundationDB

/// RANK Query
///
/// Provides specialized query operations for rank indexes, including:
/// - Get record by rank (1st place, 2nd place, etc.)
/// - Get rank by value (what rank does score 1000 have?)
/// - Get range of records by rank (top 10, ranks 50-100, etc.)
///
/// **Implementation Status**: ✅ Fully Implemented
///
/// All RANK operations are implemented using Range Tree algorithm with O(log n) complexity.
///
/// **Architecture**:
/// - `RankQuery` (this file): User-facing query API, thin adapter layer
/// - `RankIndexMaintainer`: Core business logic, O(log n) operations with Range Tree
/// - Count nodes: Hierarchical aggregation for efficient rank calculation
///
/// **Performance**:
/// - All operations are O(log n) using Range Tree algorithm
/// - No full scan required
/// - Efficient for leaderboards and rankings
/// - Descending rank queries optimized with Deque (O(1) removeFirst)
///
/// **Example Usage**:
/// ```swift
/// let rankQuery = try store.rankQuery(named: "score_rank")
///
/// // Get 1st place user
/// let topUser = try await rankQuery.byRank(1)
///
/// // Get rank of user with score 1000
/// let rank = try await rankQuery.getRank(score: 1000, primaryKey: user.userID)
///
/// // Get top 10 users
/// let top10 = try await rankQuery.top(10)
///
/// // Get ranks 5-10
/// let range = try await rankQuery.range(startRank: 5, endRank: 10)
///
/// // Get total count
/// let total = try await rankQuery.count()
/// ```
///
/// **Design References**:
/// - Java implementation: `com.apple.foundationdb.record.provider.foundationdb.indexes.RankIndexMaintainer`
/// - Range Tree: Hierarchical count nodes for O(log n) aggregation
public struct RankQuery<Record: Recordable>: Sendable {
    // MARK: - Properties

    private let recordStore: RecordStore<Record>
    private let indexName: String
    private let index: Index
    private let indexSubspace: Subspace

    // MARK: - Initialization

    /// Initialize rank query
    ///
    /// - Parameters:
    ///   - recordStore: Record store instance
    ///   - indexName: Name of the rank index
    /// - Throws: RecordLayerError if index not found or not a rank index
    public init(recordStore: RecordStore<Record>, indexName: String) throws {
        self.recordStore = recordStore
        self.indexName = indexName

        // Find index in schema
        guard let index = recordStore.schema.indexes.first(where: { $0.name == indexName }) else {
            throw RecordLayerError.indexNotFound(indexName)
        }

        guard index.type == .rank else {
            throw RecordLayerError.invalidArgument("Index '\(indexName)' is not a RANK index")
        }

        self.index = index
        self.indexSubspace = recordStore.indexSubspace.subspace(indexName)
    }

    // MARK: - BY_RANK API

    /// Get record by rank
    ///
    /// Returns the record at the specified rank position.
    /// Rank 1 = highest score (1st place)
    ///
    /// - Parameter rank: Rank position (1-indexed)
    /// - Returns: Record at the specified rank, or nil if rank is out of bounds
    /// - Throws: RecordLayerError if operation fails
    public func byRank(_ rank: Int) async throws -> Record? {
        guard rank > 0 else {
            throw RecordLayerError.invalidArgument("Rank must be positive")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            // Create maintainer
            let maintainer = RankIndexMaintainer<Record>(
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace
            )

            // Get grouping values (empty for ungrouped indexes)
            let groupingValues: [any TupleElement] = []

            // Get primary key by rank
            guard let primaryKeyTuple = try await maintainer.getRecordByRank(
                groupingValues: groupingValues,
                rank: rank,
                transaction: transaction
            ) else {
                return nil
            }

            // Load record by primary key
            return try await self.recordStore.fetchByPrimaryKey(
                primaryKeyTuple,
                transaction: transaction
            )
        }
    }

    /// Get range of records by rank
    ///
    /// Returns records in the specified rank range (inclusive).
    ///
    /// - Parameters:
    ///   - startRank: Starting rank (1-indexed, inclusive)
    ///   - endRank: Ending rank (1-indexed, inclusive)
    /// - Returns: Array of records in the rank range
    /// - Throws: RecordLayerError if operation fails
    public func range(startRank: Int, endRank: Int) async throws -> [Record] {
        guard startRank > 0 && endRank >= startRank else {
            throw RecordLayerError.invalidArgument("Invalid rank range")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            // Create maintainer
            let maintainer = RankIndexMaintainer<Record>(
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace
            )

            // Get grouping values (empty for ungrouped indexes)
            let groupingValues: [any TupleElement] = []

            // Get primary keys by rank range
            let primaryKeyTuples = try await maintainer.getRecordsByRankRange(
                groupingValues: groupingValues,
                startRank: startRank,
                endRank: endRank,
                transaction: transaction
            )

            // Load records by primary keys
            var records: [Record] = []
            for primaryKeyTuple in primaryKeyTuples {
                if let record = try await self.recordStore.fetchByPrimaryKey(
                    primaryKeyTuple,
                    transaction: transaction
                ) {
                    records.append(record)
                }
            }

            return records
        }
    }

    /// Get top N records
    ///
    /// Convenience method to get the top N ranked records.
    ///
    /// - Parameter count: Number of top records to return
    /// - Returns: Array of top N records
    /// - Throws: RecordLayerError if operation fails
    public func top(_ count: Int) async throws -> [Record] {
        return try await range(startRank: 1, endRank: count)
    }

    // MARK: - BY_VALUE API

    /// Get rank by score and primary key
    ///
    /// Returns the rank position of a record with the specified score and primary key.
    ///
    /// - Parameters:
    ///   - score: Score value
    ///   - primaryKey: Primary key of the record
    /// - Returns: Rank position (1-indexed), or nil if not found
    /// - Throws: RecordLayerError if operation fails
    public func getRank(score: Int64, primaryKey: any TupleElement) async throws -> Int? {
        return try await recordStore.withDatabaseTransaction { transaction in
            // Create maintainer
            let maintainer = RankIndexMaintainer<Record>(
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace
            )

            // Get grouping values (empty for ungrouped indexes)
            let groupingValues: [any TupleElement] = []

            // Get rank by score
            let rank = try await maintainer.getRank(
                groupingValues: groupingValues,
                score: score,
                transaction: transaction
            )

            return rank
        }
    }

    /// Get records with score in range
    ///
    /// Returns all records with scores in the specified range.
    ///
    /// - Parameters:
    ///   - minScore: Minimum score (inclusive)
    ///   - maxScore: Maximum score (inclusive)
    /// - Returns: Array of records with scores in range
    /// - Throws: RecordLayerError if operation fails
    public func byScoreRange(minScore: Int64, maxScore: Int64) async throws -> [Record] {
        guard minScore <= maxScore else {
            throw RecordLayerError.invalidArgument("Invalid score range")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            // Build range keys
            let groupingValues: [any TupleElement] = []
            let beginTuple = Tuple(groupingValues + [minScore])
            let endTuple = Tuple(groupingValues + [maxScore + 1])

            let beginKey = self.indexSubspace.pack(beginTuple)
            let endKey = self.indexSubspace.pack(endTuple)

            // Scan index entries in score range
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: true
            )

            var records: [Record] = []
            for try await (key, _) in sequence {
                // Extract primary key from index key
                let keyWithoutPrefix = Array(key.dropFirst(self.indexSubspace.prefix.count))
                let elements = try Tuple.unpack(from: keyWithoutPrefix)

                // Index key structure: [grouping...][score][primaryKey...]
                // index.rootExpression.columnCount = grouping columns + 1 (score)
                let indexedFieldCount = self.index.rootExpression.columnCount

                guard elements.count > indexedFieldCount else { continue }

                // Extract primary key elements (everything after indexed fields)
                let primaryKeyElements = Array(elements.suffix(from: indexedFieldCount))
                let primaryKeyTuple = Tuple(primaryKeyElements)

                // Load record
                if let record = try await self.recordStore.fetchByPrimaryKey(
                    primaryKeyTuple,
                    transaction: transaction
                ) {
                    records.append(record)
                }
            }

            return records
        }
    }

    // MARK: - Statistics

    /// Get total count of ranked entries
    ///
    /// - Returns: Total number of entries in the rank index
    /// - Throws: RecordLayerError if operation fails
    public func count() async throws -> Int {
        return try await recordStore.withDatabaseTransaction { transaction in
            let maintainer = RankIndexMaintainer<Record>(
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace
            )

            return try await maintainer.getTotalCount(
                groupingValues: [],
                transaction: transaction
            )
        }
    }

    /// Get score at specific rank
    ///
    /// Returns the score value at the specified rank without fetching the full record.
    ///
    /// - Parameter rank: Rank position (1-indexed)
    /// - Returns: Score at the specified rank, or nil if rank is out of bounds
    /// - Throws: RecordLayerError if operation fails
    public func scoreAtRank(_ rank: Int) async throws -> Int64? {
        guard rank > 0 else {
            throw RecordLayerError.invalidArgument("Rank must be positive")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            let maintainer = RankIndexMaintainer<Record>(
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace
            )

            return try await maintainer.getScoreAtRank(
                groupingValues: [],
                rank: rank,
                transaction: transaction
            )
        }
    }
}

// MARK: - RecordStore Extension

extension RecordStore {
    /// Create a rank query instance
    ///
    /// Convenience method to create RankQuery for a specific index.
    ///
    /// - Parameter indexName: Name of the rank index
    /// - Returns: RankQuery instance
    /// - Throws: RecordLayerError if index not found or not a rank index
    public func rankQuery(named indexName: String) throws -> RankQuery<Record> {
        return try RankQuery(recordStore: self, indexName: indexName)
    }
}
