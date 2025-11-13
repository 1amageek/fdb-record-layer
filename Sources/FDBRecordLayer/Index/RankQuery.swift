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
/// RANK operations use Range Tree algorithm for efficient rank calculations.
///
/// **Architecture**:
/// - `RankQuery` (this file): User-facing query API, thin adapter layer
/// - `RankIndexMaintainer`: Core business logic with Range Tree count nodes
/// - Count nodes: Hierarchical aggregation for efficient rank calculation
///
/// **Performance**:
/// - `getRank`: O(log n) - uses Range Tree count nodes
/// - `count`: O(log n) - uses Range Tree count nodes
/// - `byRank`, `top`, `range`: O(n) - sequential scan to find specific rank
/// - `scoreAtRank`: O(n) - sequential scan to extract score at rank
/// - `byScoreRange`: O(n) - scans all entries in score range
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
    /// - Parameters:
    ///   - rank: Rank position (1-indexed)
    ///   - grouping: Values for grouping fields (default: empty for ungrouped indexes)
    /// - Returns: Record at the specified rank, or nil if rank is out of bounds
    /// - Throws: RecordLayerError if operation fails
    public func byRank(_ rank: Int, grouping: [any TupleElement] = []) async throws -> Record? {
        guard rank > 0 else {
            throw RecordLayerError.invalidArgument("Rank must be positive")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            // Get primary key by rank using dynamic score type
            guard let primaryKeyTuple = try await getRecordByRankDynamic(
                recordType: Record.self,
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace,
                groupingValues: grouping,
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
    ///   - grouping: Values for grouping fields (default: empty for ungrouped indexes)
    /// - Returns: Array of records in the rank range
    /// - Throws: RecordLayerError if operation fails
    public func range(startRank: Int, endRank: Int, grouping: [any TupleElement] = []) async throws -> [Record] {
        guard startRank > 0 && endRank >= startRank else {
            throw RecordLayerError.invalidArgument("Invalid rank range")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            // Get primary keys by rank range using dynamic score type
            let primaryKeyTuples = try await getRecordsByRankRangeDynamic(
                recordType: Record.self,
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace,
                groupingValues: grouping,
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
    /// - Parameters:
    ///   - count: Number of top records to return
    ///   - grouping: Values for grouping fields (default: empty for ungrouped indexes)
    /// - Returns: Array of top N records
    /// - Throws: RecordLayerError if operation fails
    public func top(_ count: Int, grouping: [any TupleElement] = []) async throws -> [Record] {
        return try await range(startRank: 1, endRank: count, grouping: grouping)
    }

    // MARK: - BY_VALUE API

    /// Get rank by score and primary key
    ///
    /// Returns the rank position of a record with the specified score and primary key.
    ///
    /// **Score Type**: Must match the index's scoreTypeName (Int64, Double, Float, or Int)
    ///
    /// - Parameters:
    ///   - score: Score value (type must match index's scoreTypeName)
    ///   - primaryKey: Primary key of the record
    ///   - grouping: Values for grouping fields (default: empty for ungrouped indexes)
    /// - Returns: Rank position (1-indexed), or nil if not found
    /// - Throws: RecordLayerError if operation fails or score type doesn't match
    public func getRank(score: any TupleElement, primaryKey: any TupleElement, grouping: [any TupleElement] = []) async throws -> Int? {
        return try await recordStore.withDatabaseTransaction { transaction in
            // Convert primaryKey to Tuple
            let primaryKeyTuple: Tuple
            if let tuple = primaryKey as? Tuple {
                primaryKeyTuple = tuple
            } else {
                primaryKeyTuple = Tuple([primaryKey])
            }

            // Get rank using dynamic score type
            return try await getRankDynamic(
                recordType: Record.self,
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace,
                groupingValues: grouping,
                score: score,
                primaryKey: primaryKeyTuple,
                transaction: transaction
            )
        }
    }

    /// Get records with score in range
    ///
    /// Returns all records with scores in the specified range.
    ///
    /// **Score Type**: Must match the index's scoreTypeName (Int64, Double, Float, or Int)
    ///
    /// - Parameters:
    ///   - minScore: Minimum score (inclusive, type must match index's scoreTypeName)
    ///   - maxScore: Maximum score (inclusive, type must match index's scoreTypeName)
    ///   - grouping: Values for grouping fields (default: empty for ungrouped indexes)
    /// - Returns: Array of records with scores in range
    /// - Throws: RecordLayerError if operation fails or score type doesn't match
    public func byScoreRange(minScore: any TupleElement, maxScore: any TupleElement, grouping: [any TupleElement] = []) async throws -> [Record] {
        // Validate score range based on score type
        let scoreTypeName = self.index.options.scoreTypeName ?? "Int64"

        switch scoreTypeName {
        case "Int64":
            guard let minTyped = minScore as? Int64, let maxTyped = maxScore as? Int64 else {
                throw RecordLayerError.invalidArgument("Score type mismatch: expected Int64")
            }
            if minTyped > maxTyped {
                throw RecordLayerError.invalidArgument("Invalid score range: minScore (\(minTyped)) > maxScore (\(maxTyped))")
            }
        case "Double":
            guard let minTyped = minScore as? Double, let maxTyped = maxScore as? Double else {
                throw RecordLayerError.invalidArgument("Score type mismatch: expected Double")
            }
            if minTyped > maxTyped {
                throw RecordLayerError.invalidArgument("Invalid score range: minScore (\(minTyped)) > maxScore (\(maxTyped))")
            }
        case "Float":
            guard let minTyped = minScore as? Float, let maxTyped = maxScore as? Float else {
                throw RecordLayerError.invalidArgument("Score type mismatch: expected Float")
            }
            if minTyped > maxTyped {
                throw RecordLayerError.invalidArgument("Invalid score range: minScore (\(minTyped)) > maxScore (\(maxTyped))")
            }
        case "Int":
            guard let minTyped = minScore as? Int, let maxTyped = maxScore as? Int else {
                throw RecordLayerError.invalidArgument("Score type mismatch: expected Int")
            }
            if minTyped > maxTyped {
                throw RecordLayerError.invalidArgument("Invalid score range: minScore (\(minTyped)) > maxScore (\(maxTyped))")
            }
        default:
            throw RecordLayerError.invalidArgument("Unsupported score type: \(scoreTypeName)")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            // Build range keys
            let groupingValues = grouping
            let beginTuple = Tuple(groupingValues + [minScore])

            // Calculate exclusive end key based on score type
            let endTuple: Tuple

            switch scoreTypeName {
            case "Int64":
                guard let maxScoreTyped = maxScore as? Int64 else {
                    throw RecordLayerError.invalidArgument("Score type mismatch: expected Int64")
                }
                endTuple = Tuple(groupingValues + [maxScoreTyped + 1])
            case "Double":
                guard let maxScoreTyped = maxScore as? Double else {
                    throw RecordLayerError.invalidArgument("Score type mismatch: expected Double")
                }
                endTuple = Tuple(groupingValues + [maxScoreTyped.nextUp])
            case "Float":
                guard let maxScoreTyped = maxScore as? Float else {
                    throw RecordLayerError.invalidArgument("Score type mismatch: expected Float")
                }
                endTuple = Tuple(groupingValues + [maxScoreTyped.nextUp])
            case "Int":
                guard let maxScoreTyped = maxScore as? Int else {
                    throw RecordLayerError.invalidArgument("Score type mismatch: expected Int")
                }
                endTuple = Tuple(groupingValues + [maxScoreTyped + 1])
            default:
                throw RecordLayerError.invalidArgument("Unsupported score type: \(scoreTypeName)")
            }

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
    /// - Parameters:
    ///   - grouping: Values for grouping fields (default: empty for ungrouped indexes)
    /// - Returns: Total number of entries in the rank index
    /// - Throws: RecordLayerError if operation fails
    public func count(grouping: [any TupleElement] = []) async throws -> Int {
        return try await recordStore.withDatabaseTransaction { transaction in
            return try await getTotalCountDynamic(
                recordType: Record.self,
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace,
                groupingValues: grouping,
                transaction: transaction
            )
        }
    }

    /// Get score at specific rank
    ///
    /// Returns the score value at the specified rank without fetching the full record.
    ///
    /// **Return Type**: Score type matches the index's scoreTypeName (Int64, Double, Float, or Int).
    /// Cast the result to the appropriate type based on your index configuration.
    ///
    /// - Parameters:
    ///   - rank: Rank position (1-indexed)
    ///   - grouping: Values for grouping fields (default: empty for ungrouped indexes)
    /// - Returns: Score at the specified rank, or nil if rank is out of bounds
    /// - Throws: RecordLayerError if operation fails
    public func scoreAtRank(_ rank: Int, grouping: [any TupleElement] = []) async throws -> (any TupleElement)? {
        guard rank > 0 else {
            throw RecordLayerError.invalidArgument("Rank must be positive")
        }

        return try await recordStore.withDatabaseTransaction { transaction in
            return try await getScoreAtRankDynamic(
                recordType: Record.self,
                index: self.index,
                subspace: self.indexSubspace,
                recordSubspace: self.recordStore.recordSubspace,
                groupingValues: grouping,
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
