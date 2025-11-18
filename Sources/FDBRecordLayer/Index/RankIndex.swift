import Foundation
import FoundationDB
import Collections

// MARK: - Rank Score Protocol

/// Protocol for types that can be used as RANK index scores
///
/// Types conforming to this protocol can be used as score values in RANK indexes.
/// The protocol requires:
/// - Comparability (for ranking order)
/// - TupleElement conformance (for FoundationDB encoding)
/// - Bucket boundary calculation (for Range Tree optimization)
///
/// **Supported Types**:
/// - Int64 (default, most efficient)
/// - Double (floating point scores)
/// - Float (32-bit floating point)
/// - Int (native integer)
/// - Other numeric types can be added by conforming to this protocol
///
/// **NaN and Infinity Handling**:
/// - ⚠️ **NaN values are undefined behavior** - do not use NaN as score values
/// - ±Infinity values work but may cause unexpected ranking behavior
/// - Best practice: validate scores before indexing to avoid special values
///
/// **Example**:
/// ```swift
/// // Int64 scores (built-in support)
/// let rankIndex = Index(
///     name: "user_score_rank",
///     type: .rank,
///     rootExpression: FieldKeyExpression("score") // score: Int64
/// )
///
/// // Double scores (built-in support)
/// let doubleRankIndex = Index(
///     name: "temperature_rank",
///     type: .rank,
///     rootExpression: FieldKeyExpression("temperature") // temperature: Double
/// )
/// ```
internal protocol RankScore: Comparable, TupleElement {
    /// Calculate bucket boundary for Range Tree
    ///
    /// This method rounds the score down to the nearest bucket boundary
    /// at the specified tree level. Used by Range Tree algorithm to
    /// organize scores into hierarchical buckets for O(log n) counting.
    ///
    /// **Algorithm**:
    /// ```
    /// levelBucketSize = bucketSize ^ level
    /// boundary = floor(score / levelBucketSize) * levelBucketSize
    /// ```
    ///
    /// - Parameters:
    ///   - bucketSize: Size of bucket at level 1
    ///   - level: Tree level (1, 2, 3, ...)
    /// - Returns: Bucket boundary (score rounded down to bucket start)
    func bucketBoundary(bucketSize: Int, level: Int) -> Self

    /// Get the next score value (for range queries)
    ///
    /// Used to construct exclusive upper bounds in range scans.
    /// For integers: `score + 1`
    /// For floating point: `score.nextUp` (next representable value)
    ///
    /// ⚠️ **Warning**: For floating point types, nextUp may return infinity.
    /// Caller should handle infinity cases appropriately.
    var nextScore: Self { get }

    /// Calculate the next bucket boundary for Range Tree
    ///
    /// Returns the starting position of the next bucket at the specified level.
    /// This is used in Range Tree to correctly scan count nodes.
    ///
    /// **Algorithm**:
    /// ```
    /// levelBucketSize = bucketSize ^ level
    /// currentBucket = floor(score / levelBucketSize)
    /// nextBoundary = (currentBucket + 1) * levelBucketSize
    /// ```
    ///
    /// - Parameters:
    ///   - bucketSize: Size of bucket at level 1
    ///   - level: Tree level (1, 2, 3, ...)
    /// - Returns: Start of the next bucket
    func nextBucketBoundary(bucketSize: Int, level: Int) -> Self
}

// MARK: - RankScore Conformances (Internal)

// ⚠️ Internal to avoid global namespace pollution
// Only fdb-record-layer module can see these conformances

extension Int64: RankScore {
    func bucketBoundary(bucketSize: Int, level: Int) -> Int64 {
        let levelBucketSize = Int64(pow(Double(bucketSize), Double(level)))
        return (self / levelBucketSize) * levelBucketSize
    }

    var nextScore: Int64 {
        return self + 1
    }

    func nextBucketBoundary(bucketSize: Int, level: Int) -> Int64 {
        let levelBucketSize = Int64(pow(Double(bucketSize), Double(level)))
        let currentBucket = self / levelBucketSize
        return (currentBucket + 1) * levelBucketSize
    }
}

extension Double: RankScore {
    func bucketBoundary(bucketSize: Int, level: Int) -> Double {
        let levelBucketSize = pow(Double(bucketSize), Double(level))
        return floor(self / levelBucketSize) * levelBucketSize
    }

    var nextScore: Double {
        return self.nextUp
    }

    func nextBucketBoundary(bucketSize: Int, level: Int) -> Double {
        let levelBucketSize = pow(Double(bucketSize), Double(level))
        let currentBucket = floor(self / levelBucketSize)
        return (currentBucket + 1) * levelBucketSize
    }
}

extension Float: RankScore {
    func bucketBoundary(bucketSize: Int, level: Int) -> Float {
        let levelBucketSize = pow(Float(bucketSize), Float(level))
        return floor(self / levelBucketSize) * levelBucketSize
    }

    var nextScore: Float {
        return self.nextUp
    }

    func nextBucketBoundary(bucketSize: Int, level: Int) -> Float {
        let levelBucketSize = pow(Float(bucketSize), Float(level))
        let currentBucket = floor(self / levelBucketSize)
        return (currentBucket + 1) * levelBucketSize
    }
}

extension Int: RankScore {
    func bucketBoundary(bucketSize: Int, level: Int) -> Int {
        let levelBucketSize = Int(pow(Double(bucketSize), Double(level)))
        return (self / levelBucketSize) * levelBucketSize
    }

    var nextScore: Int {
        return self + 1
    }

    func nextBucketBoundary(bucketSize: Int, level: Int) -> Int {
        let levelBucketSize = Int(pow(Double(bucketSize), Double(level)))
        let currentBucket = self / levelBucketSize
        return (currentBucket + 1) * levelBucketSize
    }
}

// MARK: - Rank Index

/// Rank index for leaderboard functionality
///
/// Rank indexes provide efficient ranking and leaderboard queries.
/// They answer questions like:
/// - "What is the rank of user X?"
/// - "Who are the top 10 users?"
/// - "Get users ranked 100-110"
///
/// **Generic Score Support**:
/// The index now supports any score type conforming to `RankScore`,
/// including Int64, Double, Float, and custom numeric types.
///
/// **Algorithm: Range Tree**
/// Uses a hierarchical tree structure where each node stores the count
/// of records in its subtree. This allows O(log n) rank calculations.
///
/// **Data Model:**
/// ```
/// Score Entry:
///   [subspace][grouping_values][score: Score][primary_key] → ∅
///
/// Count Node (Range Tree):
///   [subspace][grouping_values]["_count"][level: Int64][range_start: Score] → count: Int64
/// ```
///
/// **Example Usage:**
/// ```swift
/// // Int64 scores (traditional)
/// let rankIndex = Index(
///     name: "user_score_rank",
///     type: .rank,
///     rootExpression: CompoundKeyExpression([
///         FieldKeyExpression("game_id"),  // Grouping
///         FieldKeyExpression("score")     // Ranked field (Int64)
///     ]),
///     options: IndexOptions(
///         rankOrder: .descending,
///         bucketSize: 100
///     )
/// )
///
/// // Double scores (new!)
/// let tempIndex = Index(
///     name: "temperature_rank",
///     type: .rank,
///     rootExpression: FieldKeyExpression("temperature"),  // Double
///     options: IndexOptions(rankOrder: .ascending)
/// )
///
/// // Query operations
/// let rank = try await recordStore.getRank(
///     grouping: ["game_id": 123],
///     score: 1000.5,  // Works with Double!
///     index: "temperature_rank"
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

/// Maintainer for rank indexes with generic score support
///
/// Works with any record type through RecordAccess and any score type through RankScore.
/// Implements Range Tree algorithm for O(log n) rank queries with Deque optimization.
///
/// **Generic Parameters**:
/// - `Record`: The record type (must be Sendable)
/// - `Score`: The score type (must conform to RankScore)
///
/// **Usage:**
/// ```swift
/// // Int64 scores (traditional)
/// let maintainer = RankIndexMaintainer<User, Int64>(
///     index: rankIndex,
///     subspace: rankSubspace,
///     recordSubspace: recordSubspace
/// )
///
/// // Double scores (new!)
/// let doubleMaintainer = RankIndexMaintainer<Temperature, Double>(
///     index: tempIndex,
///     subspace: tempSubspace,
///     recordSubspace: recordSubspace
/// )
/// ```
internal struct RankIndexMaintainer<Record: Sendable, Score: RankScore>: GenericIndexMaintainer {
    let index: Index
    let subspace: Subspace
    let recordSubspace: Subspace

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

    /// Get rank for a given score and primary key
    ///
    /// Returns nil if the record with the given score and primary key does not exist.
    ///
    /// **Performance**: O(log n) using Range Tree algorithm
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields (empty for ungrouped indexes)
    ///   - score: Score value (can be Int64, Double, Float, etc.)
    ///   - primaryKey: Primary key of the record
    ///   - transaction: Transaction to use for reading
    /// - Returns: Rank (1-indexed), or nil if record doesn't exist
    /// - Throws: RecordLayerError if operation fails
    public func getRank(
        groupingValues: [any TupleElement],
        score: Score,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> Int? {
        // Build the exact index key to verify it exists
        // Index key structure: [grouping...][score][primaryKey...]
        var keyElements = groupingValues + [score]

        // Add primary key elements
        for i in 0..<primaryKey.count {
            if let element = primaryKey[i] {
                keyElements.append(element)
            }
        }

        let indexKey = subspace.pack(Tuple(keyElements))

        // Check if the key exists
        let value = try await transaction.getValue(for: indexKey, snapshot: true)
        guard value != nil else {
            return nil  // Record doesn't exist
        }

        // Calculate rank
        // 1. Count records with better scores
        let betterCount = try await countBetterScores(
            groupingValues: groupingValues,
            score: score,
            transaction: transaction
        )

        // ✅ BUG FIX #5: Count records with same score but better (smaller) primary key for tie-breaking
        let tieCount = try await countSameScoreButBetterPrimaryKey(
            groupingValues: groupingValues,
            score: score,
            primaryKey: primaryKey,
            transaction: transaction
        )

        return betterCount + tieCount + 1
    }

    /// Get record by rank (OPTIMIZED with Deque)
    ///
    /// **Performance**: O(n) for descending (requires buffering), O(rank) for ascending
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields (empty for ungrouped indexes)
    ///   - rank: Rank position (1-indexed)
    ///   - transaction: Transaction to use for reading
    /// - Returns: Primary key of record at specified rank, or nil if out of bounds
    /// - Throws: RecordLayerError if operation fails
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
                // Skip count nodes (internal Range Tree structure)
                if try isCountNode(key) {
                    continue
                }

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
                // Skip count nodes (internal Range Tree structure)
                if try isCountNode(key) {
                    continue
                }

                buffer.append(key)
                if buffer.count > rank {
                    buffer.removeFirst()  // O(1) with Deque
                }
            }

            if buffer.count >= rank {
                let bufferIndex = buffer.count - rank
                return try extractPrimaryKeyFromIndexKey(buffer[bufferIndex])
            }
        }

        return nil
    }

    /// Get records in rank range (OPTIMIZED with Deque)
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields (empty for ungrouped indexes)
    ///   - startRank: Starting rank (1-indexed, inclusive)
    ///   - endRank: Ending rank (1-indexed, inclusive)
    ///   - transaction: Transaction to use for reading
    /// - Returns: Array of primary keys in rank range
    /// - Throws: RecordLayerError if operation fails
    public func getRecordsByRankRange(
        groupingValues: [any TupleElement],
        startRank: Int,
        endRank: Int,
        transaction: any TransactionProtocol
    ) async throws -> [Tuple] {
        guard startRank >= 1 else {
            throw RecordLayerError.invalidRank("Start rank must be >= 1")
        }
        guard endRank >= startRank else {
            throw RecordLayerError.invalidRank("End rank must be >= start rank")
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
                // Skip count nodes (internal Range Tree structure)
                if try isCountNode(key) {
                    continue
                }

                currentRank += 1
                if currentRank >= startRank && currentRank <= endRank {
                    let pk = try extractPrimaryKeyFromIndexKey(key)
                    results.append(pk)
                }
                if currentRank > endRank {
                    break
                }
            }
        } else {
            // OPTIMIZED: Use Deque for O(1) removeFirst
            var buffer = Deque<FDB.Bytes>()
            buffer.reserveCapacity(endRank)

            for try await (key, _) in sequence {
                // Skip count nodes (internal Range Tree structure)
                if try isCountNode(key) {
                    continue
                }

                buffer.append(key)
                if buffer.count > endRank {
                    buffer.removeFirst()  // O(1) with Deque
                }
            }

            // Extract elements from startRank to endRank (inclusive)
            // For descending: buffer is in ascending order, so highest score is at the end
            // rank 1 = buffer.last, rank 2 = buffer[count-2], etc.
            if buffer.count >= startRank {
                for rank in startRank...min(endRank, buffer.count) {
                    // Convert rank to buffer index (descending)
                    // rank 1 -> buffer[count-1], rank 2 -> buffer[count-2], etc.
                    let bufferIndex = buffer.count - rank
                    let pk = try extractPrimaryKeyFromIndexKey(buffer[bufferIndex])
                    results.append(pk)
                }
            }
        }

        return results
    }

    /// Get total count of entries (excluding count nodes)
    ///
    /// Returns the total number of ranked entries in the index, excluding internal count nodes
    /// used by the Range Tree algorithm.
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields (empty for ungrouped indexes)
    ///   - transaction: Transaction to use for reading
    /// - Returns: Total number of ranked entries
    /// - Throws: RecordLayerError if operation fails
    public func getTotalCount(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int {
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let beginKey = subspace.pack(groupingTuple)
        let endKey = beginKey + [0xFF]

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: true
        )

        var totalCount = 0
        for try await (key, _) in sequence {
            // Skip count nodes (internal Range Tree structure)
            if try !isCountNode(key) {
                totalCount += 1
            }
        }

        return totalCount
    }

    /// Get record and score by rank (OPTIMIZED with Deque)
    ///
    /// Returns both the primary key and score at the specified rank position.
    /// This is more efficient than calling getRecordByRank() and then extracting the score separately.
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields (empty for ungrouped indexes)
    ///   - rank: Rank position (1-indexed)
    ///   - transaction: Transaction to use for reading
    /// - Returns: Tuple of (primaryKey, score), or nil if rank is out of bounds
    /// - Throws: RecordLayerError if operation fails
    private func getRecordAndScoreByRank(
        groupingValues: [any TupleElement],
        rank: Int,
        transaction: any TransactionProtocol
    ) async throws -> (primaryKey: Tuple, score: Score)? {
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
                // Skip count nodes (internal Range Tree structure)
                if try isCountNode(key) {
                    continue
                }

                currentRank += 1
                if currentRank == rank {
                    return try extractPrimaryKeyAndScoreFromIndexKey(key)
                }
            }
        } else {
            // OPTIMIZED: Use Deque for O(1) removeFirst
            var buffer = Deque<FDB.Bytes>()
            buffer.reserveCapacity(rank)

            for try await (key, _) in sequence {
                // Skip count nodes (internal Range Tree structure)
                if try isCountNode(key) {
                    continue
                }

                buffer.append(key)
                if buffer.count > rank {
                    buffer.removeFirst()  // O(1) with Deque
                }
            }

            if buffer.count >= rank {
                let bufferIndex = buffer.count - rank
                return try extractPrimaryKeyAndScoreFromIndexKey(buffer[bufferIndex])
            }
        }

        return nil
    }

    /// Get score at specific rank
    ///
    /// Returns the score value at the specified rank position without fetching the full record.
    ///
    /// **Performance**: O(n) complexity - sequentially scans score entries until reaching the specified rank.
    /// For ascending order: scans from lowest to highest until rank N is reached.
    /// For descending order: scans from highest to lowest, buffering entries until rank N is reached.
    ///
    /// **Note**: While Range Tree provides O(log n) rank-to-count operations, extracting the actual score
    /// at a specific rank requires sequential scanning. Future optimization could traverse the Range Tree
    /// to find the score range containing rank N, then scan only that range.
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields (empty for ungrouped indexes)
    ///   - rank: Rank position (1-indexed)
    ///   - transaction: Transaction to use for reading
    /// - Returns: Score at the specified rank, or nil if rank is out of bounds
    /// - Throws: RecordLayerError if operation fails
    public func getScoreAtRank(
        groupingValues: [any TupleElement],
        rank: Int,
        transaction: any TransactionProtocol
    ) async throws -> Score? {
        // Use the optimized method that returns both primary key and score in a single traversal
        guard let (_, score) = try await getRecordAndScoreByRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        ) else {
            return nil
        }

        return score
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
        let allElements = values + (try Tuple.unpack(from: primaryKey.pack()))
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
        let allElements = values + (try Tuple.unpack(from: primaryKey.pack()))
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
    ///
    /// Uses Range Tree's hierarchical count nodes for O(log n) counting.
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields
    ///   - score: Score to compare against
    ///   - transaction: Transaction to use for reading
    /// - Returns: Count of records with better scores
    /// - Throws: RecordLayerError if operation fails
    private func countBetterScores(
        groupingValues: [any TupleElement],
        score: Score,
        transaction: any TransactionProtocol
    ) async throws -> Int {
        let groupingElements = try Tuple.unpack(from: TupleHelpers.toTuple(groupingValues).pack())

        var totalCount = 0

        // ✅ FIX: Use count nodes for levels > 1 only to avoid double-counting
        // Level 1's target bucket will be counted by scoreSequence below
        for level in stride(from: maxLevel, through: 2, by: -1) {
            let beginKey: FDB.Bytes
            let endKey: FDB.Bytes

            if rankOrder == .descending {
                // Better scores are HIGHER
                // Use nextBucketBoundary to get the start of the next bucket (not just +1)
                let startBoundary = score.nextBucketBoundary(bucketSize: bucketSize, level: level)
                beginKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(level), startBoundary]))
                endKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(level)])) + [0xFF]
            } else {
                // Better scores are LOWER
                beginKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(level)]))
                let endBoundary = score.bucketBoundary(bucketSize: bucketSize, level: level)
                endKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(level), endBoundary]))
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

        // ✅ FIX: For level 1, count only "better" buckets using _count nodes
        // Target bucket's count is handled by scoreSequence below to avoid double-counting
        let level1BeginKey: FDB.Bytes
        let level1EndKey: FDB.Bytes

        if rankOrder == .descending {
            // Better scores are HIGHER - count buckets above target bucket
            let targetBucket = score.bucketBoundary(bucketSize: bucketSize, level: 1)
            let startBoundary = targetBucket.nextBucketBoundary(bucketSize: bucketSize, level: 1)
            level1BeginKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(1), startBoundary]))
            level1EndKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(1)])) + [0xFF]
        } else {
            // Better scores are LOWER - count buckets below target bucket
            level1BeginKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(1)]))
            let targetBucket = score.bucketBoundary(bucketSize: bucketSize, level: 1)
            level1EndKey = subspace.pack(Tuple(groupingElements + ["_count", Int64(1), targetBucket]))
        }

        let level1Sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(level1BeginKey),
            endSelector: .firstGreaterOrEqual(level1EndKey),
            snapshot: true
        )

        for try await (_, value) in level1Sequence {
            guard !value.isEmpty else { continue }
            let nodeCount = value.withUnsafeBytes { $0.load(as: Int64.self).littleEndian }
            totalCount += Int(nodeCount)
        }

        // Count remaining scores not covered by count nodes
        let bucketStart = score.bucketBoundary(bucketSize: bucketSize, level: 1)
        // Use nextBucketBoundary to get the end of the bucket (not just +1)
        let bucketEnd = bucketStart.nextBucketBoundary(bucketSize: bucketSize, level: 1)

        let scoreBeginKey: FDB.Bytes
        let scoreEndKey: FDB.Bytes

        if rankOrder == .descending {
            scoreBeginKey = subspace.pack(Tuple(groupingElements + [score.nextScore]))
            scoreEndKey = subspace.pack(Tuple(groupingElements + [bucketEnd]))
        } else {
            scoreBeginKey = subspace.pack(Tuple(groupingElements + [bucketStart]))
            scoreEndKey = subspace.pack(Tuple(groupingElements + [score]))
        }

        let scoreSequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(scoreBeginKey),
            endSelector: .firstGreaterOrEqual(scoreEndKey),
            snapshot: true
        )

        for try await (key, _) in scoreSequence {
            // Skip count nodes in this range too
            if try isCountNode(key) {
                continue
            }
            totalCount += 1
        }

        return totalCount
    }

    /// Count records with same score but better primary key
    ///
    /// This implements tie-breaking by primary key for records with identical scores.
    ///
    /// - Parameters:
    ///   - groupingValues: Values for grouping fields
    ///   - score: Score to match
    ///   - primaryKey: Primary key to compare against
    ///   - transaction: Transaction to use for reading
    /// - Returns: Count of records with same score but better primary key
    /// - Throws: RecordLayerError if operation fails
    private func countSameScoreButBetterPrimaryKey(
        groupingValues: [any TupleElement],
        score: Score,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> Int {
        let groupingElements = try Tuple.unpack(from: TupleHelpers.toTuple(groupingValues).pack())

        // Build range to scan all records with the same score
        let sameScoreBeginKey = subspace.pack(Tuple(groupingElements + [score]))
        let sameScoreEndKey = subspace.pack(Tuple(groupingElements + [score])) + [0xFF]

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(sameScoreBeginKey),
            endSelector: .firstGreaterOrEqual(sameScoreEndKey),
            snapshot: true
        )

        var betterPrimaryKeyCount = 0

        for try await (key, _) in sequence {
            // Skip count nodes
            if try isCountNode(key) {
                continue
            }

            // Extract primary key from this entry
            let indexedFieldCount = index.rootExpression.columnCount
            let keyWithoutPrefix = Array(key.dropFirst(subspace.prefix.count))
            let elements = try Tuple.unpack(from: keyWithoutPrefix)

            guard elements.count > indexedFieldCount else {
                continue
            }

            let thisPrimaryKeyElements = Array(elements.suffix(from: indexedFieldCount))

            // Compare primary keys lexicographically
            // Smaller primary key = better rank
            if isPrimaryKeyBetter(thisPrimaryKeyElements, than: primaryKey) {
                betterPrimaryKeyCount += 1
            }
        }

        return betterPrimaryKeyCount
    }

    /// Compare two primary keys to determine which is "better"
    ///
    /// Uses Tuple binary comparison (matches FDB order).
    ///
    /// - Parameters:
    ///   - pk1Elements: First primary key elements
    ///   - pk2: Second primary key tuple
    /// - Returns: true if pk1 is "better" (according to rankOrder)
    private func isPrimaryKeyBetter(_ pk1Elements: [any TupleElement], than pk2: Tuple) -> Bool {
        // Convert to Tuple and compare packed bytes (FDB order)
        let pk1Tuple = TupleHelpers.toTuple(pk1Elements)
        let pk1Bytes = pk1Tuple.pack()
        let pk2Bytes = pk2.pack()

        // Ascending: smaller primary key = better rank
        // Descending: larger primary key = better rank
        switch rankOrder {
        case .ascending:
            return pk1Bytes.lexicographicallyPrecedes(pk2Bytes)
        case .descending:
            return pk2Bytes.lexicographicallyPrecedes(pk1Bytes)
        }
    }

    /// Check if a key is a count node
    ///
    /// Count nodes contain the "_count" marker in their tuple encoding.
    ///
    /// - Parameter key: Key to check
    /// - Returns: true if key is a count node
    /// - Throws: RecordLayerError if key cannot be decoded
    private func isCountNode(_ key: FDB.Bytes) throws -> Bool {
        let keyWithoutPrefix = Array(key.dropFirst(subspace.prefix.count))
        let elements = try Tuple.unpack(from: keyWithoutPrefix)

        return elements.contains { element in
            (element as? String) == "_count"
        }
    }

    /// Extract primary key from rank index key
    private func extractPrimaryKeyFromIndexKey(_ key: FDB.Bytes) throws -> Tuple {
        let keyWithoutPrefix = Array(key.dropFirst(subspace.prefix.count))
        let elements = try Tuple.unpack(from: keyWithoutPrefix)

        // Index key structure: [grouping...][score][primaryKey...]
        // index.rootExpression.columnCount = grouping columns + 1 (score)
        let indexedFieldCount = index.rootExpression.columnCount

        guard elements.count > indexedFieldCount else {
            throw RecordLayerError.invalidKey("Index key does not contain primary key")
        }

        // Extract primary key elements (everything after indexed fields)
        let primaryKeyElements = Array(elements.suffix(from: indexedFieldCount))

        // Convert to tuple elements array for Tuple constructor
        return Tuple(primaryKeyElements)
    }

    /// Extract both primary key and score from rank index key
    ///
    /// - Parameter key: Index key bytes
    /// - Returns: Tuple of (primaryKey, score)
    /// - Throws: RecordLayerError if key is invalid
    private func extractPrimaryKeyAndScoreFromIndexKey(_ key: FDB.Bytes) throws -> (primaryKey: Tuple, score: Score) {
        let keyWithoutPrefix = Array(key.dropFirst(subspace.prefix.count))
        let elements = try Tuple.unpack(from: keyWithoutPrefix)

        // Index key structure: [grouping...][score][primaryKey...]
        // index.rootExpression.columnCount = grouping columns + 1 (score)
        let indexedFieldCount = index.rootExpression.columnCount

        guard elements.count > indexedFieldCount else {
            throw RecordLayerError.invalidKey("Index key does not contain primary key")
        }

        // Extract score: it's at position (indexedFieldCount - 1)
        let scoreIndex = indexedFieldCount - 1
        guard scoreIndex >= 0 && scoreIndex < elements.count,
              let score = elements[scoreIndex] as? Score else {
            throw RecordLayerError.invalidKey("Index key does not contain valid score of type \(Score.self)")
        }

        // Extract primary key elements (everything after indexed fields)
        let primaryKeyElements = Array(elements.suffix(from: indexedFieldCount))
        let primaryKey = Tuple(primaryKeyElements)

        return (primaryKey, score)
    }

    /// Update count nodes at each level of the range tree
    ///
    /// Uses atomic ADD operations for concurrent updates.
    ///
    /// - Parameters:
    ///   - values: Index values (grouping + score)
    ///   - delta: Count change (+1 for add, -1 for remove)
    ///   - transaction: Transaction to use for writing
    /// - Throws: RecordLayerError if score is not a RankScore
    private func updateCountNodes(
        values: [any TupleElement],
        delta: Int64,
        transaction: any TransactionProtocol
    ) async throws {
        // Extract score (last element) and grouping (all but last)
        guard let score = values.last as? Score else {
            throw RecordLayerError.invalidArgument("Score value is not of type \(Score.self)")
        }

        let groupingElements = Array(values.dropLast())
        let groupingTuple = TupleHelpers.toTuple(groupingElements)

        // Update count at each level
        for level in 1...maxLevel {
            // Calculate range start for this score at this level
            let rangeStart = score.bucketBoundary(bucketSize: bucketSize, level: level)

            // Build count node key: [subspace][grouping]["_count"][level: Int64][range_start: Score]
            let countKey = subspace.pack(
                Tuple(
                    try Tuple.unpack(from: groupingTuple.pack()) +
                    ["_count", Int64(level), rangeStart]
                )
            )

            // Atomic increment/decrement
            let deltaBytes = withUnsafeBytes(of: delta.littleEndian) { Array($0) }
            transaction.atomicOp(key: countKey, param: deltaBytes, mutationType: .add)
        }
    }
}

// MARK: - Type Erasure for Dynamic Score Type

/// Type-erased rank index maintainer protocol
///
/// Allows dynamic score type selection at runtime based on IndexOptions.scoreTypeName.
/// This is necessary because Swift generics must be resolved at compile time, but
/// we need to select the Score type based on runtime configuration.
internal protocol AnyRankIndexMaintainerProtocol<Record>: GenericIndexMaintainer where Record == Self.Record {}

/// Helper function to create rank index maintainer with dynamic score type
///
/// Selects the appropriate Score type based on index.options.scoreTypeName:
/// - "Int64" or nil → RankIndexMaintainer<Record, Int64> (default)
/// - "Double" → RankIndexMaintainer<Record, Double>
/// - "Float" → RankIndexMaintainer<Record, Float>
/// - "Int" → RankIndexMaintainer<Record, Int>
///
/// - Parameters:
///   - index: Index definition with scoreTypeName option
///   - subspace: Subspace for index storage
///   - recordSubspace: Subspace for record storage
/// - Returns: Type-erased generic index maintainer
/// - Throws: RecordLayerError.invalidArgument if scoreTypeName is unsupported
internal func createRankIndexMaintainer<Record: Sendable>(
    index: Index,
    subspace: Subspace,
    recordSubspace: Subspace
) throws -> AnyGenericIndexMaintainer<Record> {
    let scoreTypeName = index.options.scoreTypeName ?? "Int64"  // Default to Int64

    switch scoreTypeName {
    case "Int64":
        let maintainer = RankIndexMaintainer<Record, Int64>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)

    case "Double":
        let maintainer = RankIndexMaintainer<Record, Double>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)

    case "Float":
        let maintainer = RankIndexMaintainer<Record, Float>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)

    case "Int":
        let maintainer = RankIndexMaintainer<Record, Int>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)

    default:
        throw RecordLayerError.invalidArgument(
            "Unsupported score type '\(scoreTypeName)' for RANK index '\(index.name)'. " +
            "Supported types: Int64, Double, Float, Int"
        )
    }
}

// MARK: - Rank Query Helper Functions with Dynamic Score Type

/// Get rank for a score with dynamic score type resolution
///
/// - Parameters:
///   - recordType: The record type (for generic type inference)
///   - index: RANK index definition
///   - subspace: Index subspace
///   - recordSubspace: Record subspace
///   - groupingValues: Grouping field values
///   - score: Score value (must match index's scoreTypeName)
///   - primaryKey: Primary key tuple
///   - transaction: Transaction to use
/// - Returns: Rank (1-indexed), or nil if not found
/// - Throws: RecordLayerError if score type doesn't match index scoreTypeName
internal func getRankDynamic<Record: Sendable>(
    recordType: Record.Type,
    index: Index,
    subspace: Subspace,
    recordSubspace: Subspace,
    groupingValues: [any TupleElement],
    score: any TupleElement,
    primaryKey: Tuple,
    transaction: any TransactionProtocol
) async throws -> Int? {
    let scoreTypeName = index.options.scoreTypeName ?? "Int64"

    switch scoreTypeName {
    case "Int64":
        guard let typedScore = score as? Int64 else {
            throw RecordLayerError.invalidArgument(
                "Score type mismatch: index '\(index.name)' expects Int64, got \(type(of: score))"
            )
        }
        let maintainer = RankIndexMaintainer<Record, Int64>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRank(
            groupingValues: groupingValues,
            score: typedScore,
            primaryKey: primaryKey,
            transaction: transaction
        )

    case "Double":
        guard let typedScore = score as? Double else {
            throw RecordLayerError.invalidArgument(
                "Score type mismatch: index '\(index.name)' expects Double, got \(type(of: score))"
            )
        }
        let maintainer = RankIndexMaintainer<Record, Double>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRank(
            groupingValues: groupingValues,
            score: typedScore,
            primaryKey: primaryKey,
            transaction: transaction
        )

    case "Float":
        guard let typedScore = score as? Float else {
            throw RecordLayerError.invalidArgument(
                "Score type mismatch: index '\(index.name)' expects Float, got \(type(of: score))"
            )
        }
        let maintainer = RankIndexMaintainer<Record, Float>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRank(
            groupingValues: groupingValues,
            score: typedScore,
            primaryKey: primaryKey,
            transaction: transaction
        )

    case "Int":
        guard let typedScore = score as? Int else {
            throw RecordLayerError.invalidArgument(
                "Score type mismatch: index '\(index.name)' expects Int, got \(type(of: score))"
            )
        }
        let maintainer = RankIndexMaintainer<Record, Int>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRank(
            groupingValues: groupingValues,
            score: typedScore,
            primaryKey: primaryKey,
            transaction: transaction
        )

    default:
        throw RecordLayerError.invalidArgument(
            "Unsupported score type '\(scoreTypeName)' for RANK index '\(index.name)'"
        )
    }
}

/// Get record by rank with dynamic score type resolution
internal func getRecordByRankDynamic<Record: Sendable>(
    recordType: Record.Type,
    index: Index,
    subspace: Subspace,
    recordSubspace: Subspace,
    groupingValues: [any TupleElement],
    rank: Int,
    transaction: any TransactionProtocol
) async throws -> Tuple? {
    let scoreTypeName = index.options.scoreTypeName ?? "Int64"

    switch scoreTypeName {
    case "Int64":
        let maintainer = RankIndexMaintainer<Record, Int64>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordByRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    case "Double":
        let maintainer = RankIndexMaintainer<Record, Double>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordByRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    case "Float":
        let maintainer = RankIndexMaintainer<Record, Float>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordByRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    case "Int":
        let maintainer = RankIndexMaintainer<Record, Int>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordByRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    default:
        throw RecordLayerError.invalidArgument(
            "Unsupported score type '\(scoreTypeName)' for RANK index '\(index.name)'"
        )
    }
}

/// Get records by rank range with dynamic score type resolution
internal func getRecordsByRankRangeDynamic<Record: Sendable>(
    recordType: Record.Type,
    index: Index,
    subspace: Subspace,
    recordSubspace: Subspace,
    groupingValues: [any TupleElement],
    startRank: Int,
    endRank: Int,
    transaction: any TransactionProtocol
) async throws -> [Tuple] {
    let scoreTypeName = index.options.scoreTypeName ?? "Int64"

    switch scoreTypeName {
    case "Int64":
        let maintainer = RankIndexMaintainer<Record, Int64>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordsByRankRange(
            groupingValues: groupingValues,
            startRank: startRank,
            endRank: endRank,
            transaction: transaction
        )

    case "Double":
        let maintainer = RankIndexMaintainer<Record, Double>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordsByRankRange(
            groupingValues: groupingValues,
            startRank: startRank,
            endRank: endRank,
            transaction: transaction
        )

    case "Float":
        let maintainer = RankIndexMaintainer<Record, Float>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordsByRankRange(
            groupingValues: groupingValues,
            startRank: startRank,
            endRank: endRank,
            transaction: transaction
        )

    case "Int":
        let maintainer = RankIndexMaintainer<Record, Int>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getRecordsByRankRange(
            groupingValues: groupingValues,
            startRank: startRank,
            endRank: endRank,
            transaction: transaction
        )

    default:
        throw RecordLayerError.invalidArgument(
            "Unsupported score type '\(scoreTypeName)' for RANK index '\(index.name)'"
        )
    }
}

/// Get total count with dynamic score type resolution
internal func getTotalCountDynamic<Record: Sendable>(
    recordType: Record.Type,
    index: Index,
    subspace: Subspace,
    recordSubspace: Subspace,
    groupingValues: [any TupleElement],
    transaction: any TransactionProtocol
) async throws -> Int {
    let scoreTypeName = index.options.scoreTypeName ?? "Int64"

    switch scoreTypeName {
    case "Int64":
        let maintainer = RankIndexMaintainer<Record, Int64>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getTotalCount(
            groupingValues: groupingValues,
            transaction: transaction
        )

    case "Double":
        let maintainer = RankIndexMaintainer<Record, Double>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getTotalCount(
            groupingValues: groupingValues,
            transaction: transaction
        )

    case "Float":
        let maintainer = RankIndexMaintainer<Record, Float>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getTotalCount(
            groupingValues: groupingValues,
            transaction: transaction
        )

    case "Int":
        let maintainer = RankIndexMaintainer<Record, Int>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getTotalCount(
            groupingValues: groupingValues,
            transaction: transaction
        )

    default:
        throw RecordLayerError.invalidArgument(
            "Unsupported score type '\(scoreTypeName)' for RANK index '\(index.name)'"
        )
    }
}

/// Get score at rank with dynamic score type resolution
/// Returns the score value as TupleElement (can be Int64, Double, Float, or Int)
internal func getScoreAtRankDynamic<Record: Sendable>(
    recordType: Record.Type,
    index: Index,
    subspace: Subspace,
    recordSubspace: Subspace,
    groupingValues: [any TupleElement],
    rank: Int,
    transaction: any TransactionProtocol
) async throws -> (any TupleElement)? {
    let scoreTypeName = index.options.scoreTypeName ?? "Int64"

    switch scoreTypeName {
    case "Int64":
        let maintainer = RankIndexMaintainer<Record, Int64>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getScoreAtRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    case "Double":
        let maintainer = RankIndexMaintainer<Record, Double>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getScoreAtRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    case "Float":
        let maintainer = RankIndexMaintainer<Record, Float>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getScoreAtRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    case "Int":
        let maintainer = RankIndexMaintainer<Record, Int>(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )
        return try await maintainer.getScoreAtRank(
            groupingValues: groupingValues,
            rank: rank,
            transaction: transaction
        )

    default:
        throw RecordLayerError.invalidArgument(
            "Unsupported score type '\(scoreTypeName)' for RANK index '\(index.name)'"
        )
    }
}
