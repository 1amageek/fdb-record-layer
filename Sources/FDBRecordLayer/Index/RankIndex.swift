import Foundation
import FoundationDB
import Collections

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
/// Works with any record type through RecordAccess.
/// Implements Range Tree algorithm for O(log n) rank queries with Deque optimization.
///
/// **Usage:**
/// ```swift
/// let maintainer = RankIndexMaintainer(
///     index: rankIndex,
///     recordType: userType,
///     subspace: rankSubspace,
///     recordSubspace: recordSubspace
/// )
/// ```
public struct RankIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    /// Rank ordering
    private let rankOrder: RankOrder

    /// Bucket size for range tree (default: 100)
    private let bucketSize: Int

    /// Maximum tree levels (default: 3)
    private let maxLevel: Int

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
        self.maxLevel = 3
    }

    // MARK: - GenericIndexMaintainer Protocol

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        if let oldRecord = oldRecord {
            // Remove old entry
            let oldValues = try recordAccess.evaluate(
                record: oldRecord,
                expression: index.rootExpression
            )
            // Extract primary key using Recordable protocol
            let oldPrimaryKey: Tuple
            if let recordableRecord = oldRecord as? any Recordable {
                oldPrimaryKey = recordableRecord.extractPrimaryKey()
            } else {
                throw RecordLayerError.internalError("Record does not conform to Recordable")
            }

            try await removeRankEntry(
                values: oldValues,
                primaryKey: oldPrimaryKey,
                transaction: transaction
            )
        }

        if let newRecord = newRecord {
            // Add new entry
            let newValues = try recordAccess.evaluate(
                record: newRecord,
                expression: index.rootExpression
            )
            // Extract primary key using Recordable protocol
            let newPrimaryKey: Tuple
            if let recordableRecord = newRecord as? any Recordable {
                newPrimaryKey = recordableRecord.extractPrimaryKey()
            } else {
                throw RecordLayerError.internalError("Record does not conform to Recordable")
            }

            try await addRankEntry(
                values: newValues,
                primaryKey: newPrimaryKey,
                transaction: transaction
            )
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        let values = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        try await addRankEntry(
            values: values,
            primaryKey: primaryKey,
            transaction: transaction
        )
    }

    // MARK: - Rank Operations

    /// Get rank for a given score
    public func getRank(
        groupingValues: [any TupleElement],
        score: Int64,
        transaction: any TransactionProtocol
    ) async throws -> Int {
        let betterCount = try await countBetterScores(
            groupingValues: groupingValues,
            score: score,
            transaction: transaction
        )
        return betterCount + 1
    }

    /// Get record by rank (OPTIMIZED with Deque)
    public func getRecordByRank(
        groupingValues: [any TupleElement],
        rank: Int,
        transaction: any TransactionProtocol
    ) async throws -> Tuple? {
        guard rank >= 1 else {
            throw RecordLayerError.invalidRank("Rank must be >= 1, got \(rank)")
        }

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let beginKey = subspace.pack(groupingTuple)
        let endKey = beginKey + [0xFF]

        let beginSelector = FDB.KeySelector.firstGreaterOrEqual(beginKey)
        let endSelector = FDB.KeySelector.firstGreaterOrEqual(endKey)
        let sequence = transaction.getRange(
            beginSelector: beginSelector,
            endSelector: endSelector,
            snapshot: true
        )

        if rankOrder == .ascending {
            // Stream directly for ascending
            var currentRank = 0
            for try await (key, _) in sequence {
                currentRank += 1
                if currentRank == rank {
                    return try extractPrimaryKeyFromIndexKey(key)
                }
            }
        } else {
            // OPTIMIZED: Use Deque for O(1) removeFirst
            var buffer = Deque<FDB.Bytes>()
            buffer.reserveCapacity(rank)

            for try await (key, _) in sequence {
                buffer.append(key)
                if buffer.count > rank {
                    buffer.removeFirst()  // O(1) with Deque
                }
            }

            if buffer.count == rank {
                return try extractPrimaryKeyFromIndexKey(buffer.first!)
            }
        }

        return nil
    }

    /// Get records in rank range (OPTIMIZED with Deque)
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

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let beginKey = subspace.pack(groupingTuple)
        let endKey = beginKey + [0xFF]

        let beginSelector = FDB.KeySelector.firstGreaterOrEqual(beginKey)
        let endSelector = FDB.KeySelector.firstGreaterOrEqual(endKey)
        let sequence = transaction.getRange(
            beginSelector: beginSelector,
            endSelector: endSelector,
            snapshot: true
        )

        var results: [Tuple] = []

        if rankOrder == .ascending {
            // Stream directly for ascending
            var currentRank = 0
            for try await (key, _) in sequence {
                currentRank += 1
                if currentRank >= startRank && currentRank < endRank {
                    let pk = try extractPrimaryKeyFromIndexKey(key)
                    results.append(pk)
                }
                if currentRank >= endRank {
                    break
                }
            }
        } else {
            // OPTIMIZED: Use Deque for O(1) removeFirst
            var buffer = Deque<FDB.Bytes>()
            buffer.reserveCapacity(endRank)

            for try await (key, _) in sequence {
                buffer.append(key)
                if buffer.count > endRank {
                    buffer.removeFirst()  // O(1) with Deque
                }
            }

            // Extract elements from startRank to endRank
            let rangeSize = endRank - startRank
            if buffer.count >= startRank {
                let startIndex = buffer.count - endRank + (startRank - 1)
                let endIndex = min(startIndex + rangeSize, buffer.count)

                for i in startIndex..<endIndex {
                    let pk = try extractPrimaryKeyFromIndexKey(buffer[i])
                    results.append(pk)
                }
            }
        }

        return results
    }

    // MARK: - Private Methods

    /// Extract primary key from record
    private func extractPrimaryKey<T: Recordable>(_ record: T) -> Tuple {
        // Use Recordable's extractPrimaryKey() method
        return record.extractPrimaryKey()
    }

    /// Add rank entry for a record
    private func addRankEntry(
        values: [any TupleElement],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // Build rank index key: [grouping][score][pk]
        let allElements = values + (try Tuple.decode(from: primaryKey.encode()))
        let tuple = TupleHelpers.toTuple(allElements)
        let key = subspace.pack(tuple)

        // Add score entry
        transaction.setValue(FDB.Bytes(), for: key)

        // Update count nodes at each level of the range tree
        try await updateCountNodes(
            values: values,
            delta: 1,
            transaction: transaction
        )
    }

    /// Remove rank entry for a record
    private func removeRankEntry(
        values: [any TupleElement],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let allElements = values + (try Tuple.decode(from: primaryKey.encode()))
        let tuple = TupleHelpers.toTuple(allElements)
        let key = subspace.pack(tuple)

        // Remove score entry
        transaction.clear(key: key)

        // Update count nodes at each level of the range tree
        try await updateCountNodes(
            values: values,
            delta: -1,
            transaction: transaction
        )
    }

    /// Count scores better than the given score using count nodes
    private func countBetterScores(
        groupingValues: [any TupleElement],
        score: Int64,
        transaction: any TransactionProtocol
    ) async throws -> Int {
        let groupingElements = try Tuple.decode(from: TupleHelpers.toTuple(groupingValues).encode())

        var totalCount = 0

        // Use count nodes for efficient counting (O(log n))
        for level in stride(from: maxLevel, through: 1, by: -1) {
            let levelBucketSize = Int64(pow(Double(bucketSize), Double(level)))

            let beginKey: FDB.Bytes
            let endKey: FDB.Bytes

            if rankOrder == .descending {
                // Better scores are HIGHER
                let startRange = ((score / levelBucketSize) + 1) * levelBucketSize
                beginKey = subspace.pack(Tuple(groupingElements + ["_count", level, startRange]))
                endKey = subspace.pack(Tuple(groupingElements + ["_count", level])) + [0xFF]
            } else {
                // Better scores are LOWER
                beginKey = subspace.pack(Tuple(groupingElements + ["_count", level]))
                let endRange = (score / levelBucketSize) * levelBucketSize
                endKey = subspace.pack(Tuple(groupingElements + ["_count", level, endRange]))
            }

            // Sum counts from count nodes
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: true
            )

            for try await (_, value) in sequence {
                guard !value.isEmpty else { continue }
                let nodeCount = value.withUnsafeBytes { $0.load(as: Int64.self).littleEndian }
                totalCount += Int(nodeCount)
            }
        }

        // Count remaining scores not covered by count nodes
        let levelBucketSize = Int64(bucketSize)
        let bucketStart = (score / levelBucketSize) * levelBucketSize

        let scoreBeginKey: FDB.Bytes
        let scoreEndKey: FDB.Bytes

        if rankOrder == .descending {
            scoreBeginKey = subspace.pack(Tuple(groupingElements + [score + 1]))
            scoreEndKey = subspace.pack(Tuple(groupingElements + [bucketStart + levelBucketSize]))
        } else {
            scoreBeginKey = subspace.pack(Tuple(groupingElements + [bucketStart]))
            scoreEndKey = subspace.pack(Tuple(groupingElements + [score]))
        }

        let scoreSequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(scoreBeginKey),
            endSelector: .firstGreaterOrEqual(scoreEndKey),
            snapshot: true
        )

        for try await _ in scoreSequence {
            totalCount += 1
        }

        return totalCount
    }

    /// Extract primary key from rank index key
    private func extractPrimaryKeyFromIndexKey(_ key: FDB.Bytes) throws -> Tuple {
        let keyWithoutPrefix = Array(key.dropFirst(subspace.prefix.count))
        let elements = try Tuple.decode(from: keyWithoutPrefix)

        guard let lastElement = elements.last else {
            throw RecordLayerError.invalidKey("Cannot extract primary key from index key")
        }

        return Tuple(lastElement)
    }

    /// Update count nodes at each level of the range tree
    private func updateCountNodes(
        values: [any TupleElement],
        delta: Int64,
        transaction: any TransactionProtocol
    ) async throws {
        // Extract score (last element) and grouping (all but last)
        guard let score = values.last as? Int64 else {
            return  // Skip if score is not Int64
        }

        let groupingElements = Array(values.dropLast())
        let groupingTuple = TupleHelpers.toTuple(groupingElements)

        // Update count at each level
        for level in 1...maxLevel {
            let levelBucketSize = Int64(pow(Double(bucketSize), Double(level)))

            // Calculate range start for this score at this level
            let rangeStart = (score / levelBucketSize) * levelBucketSize

            // Build count node key: [subspace][grouping]["_count"][level][range_start]
            let countKey = subspace.pack(
                Tuple(
                    try Tuple.decode(from: groupingTuple.encode()) +
                    ["_count", level, rangeStart]
                )
            )

            // Atomic increment/decrement
            let deltaBytes = withUnsafeBytes(of: delta.littleEndian) { Array($0) }
            transaction.atomicOp(key: countKey, param: deltaBytes, mutationType: .add)
        }
    }
}
