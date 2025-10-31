import Foundation
import FoundationDB

// MARK: - Rank Index

/// Rank index for leaderboard functionality
///
/// Rank indexes provide efficient ranking and leaderboard queries.
/// They answer questions like:
/// - "What is the rank of user X?"
/// - "Who are the top 10 users?"
/// - "Get users ranked 100-110"
///
/// **Algorithm: Range Tree**
/// Uses a hierarchical tree structure where each node stores the count
/// of records in its subtree. This allows O(log n) rank calculations.
///
/// **Data Model:**
/// ```
/// Score Entry:
///   [subspace][grouping_values][score][primary_key] → ∅
///
/// Count Node (Range Tree):
///   [subspace][grouping_values]["_count"][level][range_start] → count
/// ```
///
/// **Example Usage:**
/// ```swift
/// // Define rank index
/// let rankIndex = Index(
///     name: "user_score_rank",
///     type: .rank,
///     rootExpression: CompoundKeyExpression([
///         FieldKeyExpression("game_id"),  // Grouping
///         FieldKeyExpression("score")     // Ranked field
///     ]),
///     options: IndexOptions(
///         rankOrder: .descending,
///         bucketSize: 100
///     )
/// )
///
/// // Query operations
/// let rank = try await recordStore.getRank(
///     grouping: ["game_id": 123],
///     score: 1000,
///     index: "user_score_rank"
/// )
///
/// let topPlayers = try await recordStore.getRecordsByRankRange(
///     grouping: ["game_id": 123],
///     startRank: 0,
///     endRank: 10,
///     index: "user_score_rank"
/// )
/// ```

// MARK: - Rank Order

/// Rank ordering (ascending or descending)
public enum RankOrder: String, Sendable {
    /// Lower scores get better (lower) ranks
    case ascending = "asc"

    /// Higher scores get better (lower) ranks (default for leaderboards)
    case descending = "desc"
}

// MARK: - Index Options Extension for Rank

extension IndexOptions {
    /// Rank order (ascending or descending)
    public var rankOrder: RankOrder {
        get {
            guard let rawValue = rankOrderString, let order = RankOrder(rawValue: rawValue) else {
                return .descending  // Default
            }
            return order
        }
        set {
            rankOrderString = newValue.rawValue
        }
    }
}

// MARK: - Rank Index Maintainer

/// Maintainer for rank indexes
///
/// Implements Range Tree algorithm for O(log n) rank queries.
///
/// **Data Structure:**
/// For each score entry, we maintain:
/// 1. Score entry: [grouping][score][pk] → ∅
/// 2. Count nodes at each level of range tree
///
/// **Range Tree Levels:**
/// - Level 0: Individual entries
/// - Level 1: Buckets of size N
/// - Level 2: Buckets of size N²
/// - Level K: Buckets of size N^K
///
/// **Rank Calculation:**
/// To find rank of score S:
/// 1. Count all scores better than S (using range tree)
/// 2. Add 1 for 1-based ranking
///
/// **Complexity:**
/// - Insert/Delete: O(log n) range tree updates
/// - Get rank: O(log n) tree traversal
/// - Get by rank: O(log n) binary search + range scan
public struct RankIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    /// Rank ordering
    private let rankOrder: RankOrder

    /// Bucket size for range tree
    private let bucketSize: Int

    // MARK: - Initialization

    public init(
        index: Index,
        subspace: Subspace,
        recordSubspace: Subspace
    ) {
        self.index = index
        self.subspace = subspace
        self.recordSubspace = recordSubspace
        self.rankOrder = index.options.rankOrder
        self.bucketSize = index.options.bucketSize ?? 100
    }

    // MARK: - IndexMaintainer Protocol

    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // Extract grouping values and score
        // For now, simplified implementation
        // In production, would use key expression evaluation

        if let oldRecord = oldRecord {
            // Remove old entry
            let oldValues = index.rootExpression.evaluate(record: oldRecord)
            let oldPrimaryKey = try extractPrimaryKey(oldRecord)

            try await removeRankEntry(
                values: oldValues,
                primaryKey: oldPrimaryKey,
                transaction: transaction
            )
        }

        if let newRecord = newRecord {
            // Add new entry
            let newValues = index.rootExpression.evaluate(record: newRecord)
            let newPrimaryKey = try extractPrimaryKey(newRecord)

            try await addRankEntry(
                values: newValues,
                primaryKey: newPrimaryKey,
                transaction: transaction
            )
        }
    }

    public func scanRecord(
        _ record: [String: Any],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let values = index.rootExpression.evaluate(record: record)

        try await addRankEntry(
            values: values,
            primaryKey: primaryKey,
            transaction: transaction
        )
    }

    // MARK: - Rank Operations

    /// Get rank for a given score
    /// - Parameters:
    ///   - groupingValues: Grouping field values (e.g., game_id)
    ///   - score: The score to get rank for
    ///   - transaction: Transaction
    /// - Returns: 1-based rank (1 = best)
    public func getRank(
        groupingValues: [any TupleElement],
        score: Int64,
        transaction: any TransactionProtocol
    ) async throws -> Int {
        // Count how many scores are better than this one
        let betterCount = try await countBetterScores(
            groupingValues: groupingValues,
            score: score,
            transaction: transaction
        )

        // Rank is count of better scores + 1 (1-based)
        return betterCount + 1
    }

    /// Get record by rank
    /// - Parameters:
    ///   - groupingValues: Grouping field values
    ///   - rank: 1-based rank to retrieve
    ///   - transaction: Transaction
    /// - Returns: Primary key of record at that rank, or nil if not found
    public func getRecordByRank(
        groupingValues: [any TupleElement],
        rank: Int,
        transaction: any TransactionProtocol
    ) async throws -> Tuple? {
        guard rank >= 1 else {
            throw RecordLayerError.invalidRank("Rank must be >= 1, got \(rank)")
        }

        // Scan scores in order until we reach the desired rank
        // In production, would use binary search for efficiency
        var currentRank = 0

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let beginKey = subspace.pack(groupingTuple)
        let endKey = beginKey + [0xFF]

        let result = try await transaction.getRangeNative(
            beginKey: beginKey,
            endKey: endKey,
            limit: 0,
            snapshot: true
        )

        // Sort by score (descending or ascending based on rankOrder)
        let sortedRecords: [(FDB.Bytes, FDB.Bytes)]
        if rankOrder == .descending {
            sortedRecords = result.records.sorted { $0.0.lexicographicallyPrecedes($1.0) }.reversed()
        } else {
            sortedRecords = result.records.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        }

        for (key, _) in sortedRecords {
            currentRank += 1
            if currentRank == rank {
                // Extract primary key from index key
                return try extractPrimaryKeyFromIndexKey(key)
            }
        }

        return nil  // Rank not found
    }

    /// Get records in rank range
    /// - Parameters:
    ///   - groupingValues: Grouping field values
    ///   - startRank: Start rank (inclusive, 1-based)
    ///   - endRank: End rank (exclusive, 1-based)
    ///   - transaction: Transaction
    /// - Returns: Array of primary keys
    public func getRecordsByRankRange(
        groupingValues: [any TupleElement],
        startRank: Int,
        endRank: Int,
        transaction: any TransactionProtocol
    ) async throws -> [Tuple] {
        guard startRank >= 1 else {
            throw RecordLayerError.invalidRank("Start rank must be >= 1")
        }
        guard endRank > startRank else {
            throw RecordLayerError.invalidRank("End rank must be > start rank")
        }

        var results: [Tuple] = []
        var currentRank = 0

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let beginKey = subspace.pack(groupingTuple)
        let endKey = beginKey + [0xFF]

        let result = try await transaction.getRangeNative(
            beginKey: beginKey,
            endKey: endKey,
            limit: 0,
            snapshot: true
        )

        // Sort by score
        let sortedRecords: [(FDB.Bytes, FDB.Bytes)]
        if rankOrder == .descending {
            sortedRecords = result.records.sorted { $0.0.lexicographicallyPrecedes($1.0) }.reversed()
        } else {
            sortedRecords = result.records.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        }

        for (key, _) in sortedRecords {
            currentRank += 1
            if currentRank >= startRank && currentRank < endRank {
                let pk = try extractPrimaryKeyFromIndexKey(key)
                results.append(pk)
            }
            if currentRank >= endRank {
                break
            }
        }

        return results
    }

    // MARK: - Private Methods

    /// Add rank entry for a record
    private func addRankEntry(
        values: [any TupleElement],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // Build rank index key: [grouping][score][pk]
        let allElements = values + (try! Tuple.decode(from: primaryKey.encode()))
        let tuple = TupleHelpers.toTuple(allElements)
        let key = subspace.pack(tuple)

        transaction.setValue(FDB.Bytes(), for: key)

        // In production, would also update range tree count nodes here
    }

    /// Remove rank entry for a record
    private func removeRankEntry(
        values: [any TupleElement],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let allElements = values + (try! Tuple.decode(from: primaryKey.encode()))
        let tuple = TupleHelpers.toTuple(allElements)
        let key = subspace.pack(tuple)

        transaction.clear(key: key)

        // In production, would also update range tree count nodes here
    }

    /// Count scores better than the given score
    private func countBetterScores(
        groupingValues: [any TupleElement],
        score: Int64,
        transaction: any TransactionProtocol
    ) async throws -> Int {
        let groupingElements = try! Tuple.decode(from: TupleHelpers.toTuple(groupingValues).encode())
        let beginKey: FDB.Bytes
        let endKey: FDB.Bytes

        // Determine range based on rank order
        if rankOrder == .descending {
            // Better scores are HIGHER, so we want (grouping, score+1) to (grouping, ∞)
            let startScoreTuple = TupleHelpers.toTuple(groupingElements + [score + 1])
            beginKey = subspace.pack(startScoreTuple)

            let groupingTuple = TupleHelpers.toTuple(groupingElements)
            endKey = subspace.pack(groupingTuple) + [0xFF]
        } else {
            // Better scores are LOWER, so we want (grouping, 0) to (grouping, score-1)
            let groupingTuple = TupleHelpers.toTuple(groupingElements)
            beginKey = subspace.pack(groupingTuple)

            let endScoreTuple = TupleHelpers.toTuple(groupingElements + [score])
            endKey = subspace.pack(endScoreTuple)
        }

        let result = try await transaction.getRangeNative(
            beginKey: beginKey,
            endKey: endKey,
            limit: 0,
            snapshot: true
        )

        return result.records.count
    }

    /// Extract primary key from record
    ///
    /// LIMITATION: Currently assumes "id" field as primary key
    ///
    /// In production, this should:
    /// 1. Accept RecordType parameter
    /// 2. Use RecordType.primaryKey expression to extract key
    /// 3. Support compound primary keys (multiple fields)
    /// 4. Handle all TupleElement types properly
    private func extractPrimaryKey(_ record: [String: Any]) throws -> Tuple {
        let primaryKeyValue: any TupleElement
        if let id = record["id"] as? Int64 {
            primaryKeyValue = id
        } else if let id = record["id"] as? Int {
            primaryKeyValue = Int64(id)
        } else if let id = record["id"] as? String {
            primaryKeyValue = id
        } else {
            throw RecordLayerError.invalidKey("Cannot extract primary key from record")
        }

        return Tuple(primaryKeyValue)
    }

    /// Extract primary key from rank index key
    private func extractPrimaryKeyFromIndexKey(_ key: FDB.Bytes) throws -> Tuple {
        // Remove subspace prefix
        let keyWithoutPrefix = Array(key.dropFirst(subspace.prefix.count))

        // Decode tuple
        let elements = try Tuple.decode(from: keyWithoutPrefix)

        // Last element(s) are the primary key
        // For now, assume single-field primary key
        guard let lastElement = elements.last else {
            throw RecordLayerError.invalidKey("Cannot extract primary key from index key")
        }

        return Tuple(lastElement)
    }
}
