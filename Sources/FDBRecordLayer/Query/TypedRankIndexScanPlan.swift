import Foundation
import FoundationDB

/// Rank index scan plan
///
/// Executes a scan on a RANK index, supporting two scan types:
/// - **By Value**: Returns records in value order (like regular index scan)
/// - **By Rank**: Returns top N or bottom N records by rank
///
/// **Performance**:
/// - By Value: O(n) where n = number of results
/// - By Rank: O(log n + k) where n = total records, k = number of results
///
/// **Example**:
/// ```swift
/// // Top 10 users by score
/// let topTen = try await store.query(User.self)
///     .topN(10, by: \.score, ascending: false)
///     .execute()
///
/// // Get user rank
/// let rank = try await store.rank(of: userScore, in: \.score)
/// ```
public struct TypedRankIndexScanPlan<Record: Recordable>: TypedQueryPlan, Sendable {
    /// Record access for deserialization
    private let recordAccess: any RecordAccess<Record>

    /// Subspace for records
    private let recordSubspace: Subspace

    /// Subspace for indexes
    private let indexSubspace: Subspace

    /// Rank index definition
    private let index: Index

    /// Scan type (by value or by rank)
    private let scanType: RankScanType

    /// Rank range (for byRank scan)
    private let rankRange: RankRange?

    /// Value range (for byValue scan)
    private let valueRange: (begin: Tuple, end: Tuple)?

    /// Maximum number of results
    private let limit: Int?

    /// Ascending order flag
    private let ascending: Bool

    /// Initialize a rank index scan plan
    ///
    /// - Parameters:
    ///   - recordAccess: Record access for deserialization
    ///   - recordSubspace: Subspace for records
    ///   - indexSubspace: Subspace for indexes
    ///   - index: Rank index definition
    ///   - scanType: Scan type (by value or by rank)
    ///   - rankRange: Rank range (required for byRank)
    ///   - valueRange: Value range (required for byValue)
    ///   - limit: Maximum number of results
    ///   - ascending: Ascending order flag
    public init(
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace,
        indexSubspace: Subspace,
        index: Index,
        scanType: RankScanType,
        rankRange: RankRange? = nil,
        valueRange: (begin: Tuple, end: Tuple)? = nil,
        limit: Int? = nil,
        ascending: Bool = false
    ) {
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
        self.indexSubspace = indexSubspace
        self.index = index
        self.scanType = scanType
        self.rankRange = rankRange
        self.valueRange = valueRange
        self.limit = limit
        self.ascending = ascending
    }

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        let transaction = context.getTransaction()

        switch scanType {
        case .byValue:
            // Scan by value (regular index scan)
            return try await executeByValue(transaction: transaction, snapshot: snapshot)

        case .byRank:
            // Scan by rank (top N / bottom N)
            return try await executeByRank(transaction: transaction, snapshot: snapshot)
        }
    }

    /// Execute by-value scan (regular index scan)
    private func executeByValue(transaction: any TransactionProtocol, snapshot: Bool) async throws -> AnyTypedRecordCursor<Record> {
        guard let valueRange = valueRange else {
            throw RecordLayerError.invalidArgument(
                "valueRange is required for byValue scan"
            )
        }

        // Build index subspace
        let indexNameSubspace = indexSubspace.subspace(index.name)

        // Create begin/end keys
        let beginKey = indexNameSubspace.pack(valueRange.begin)
        var endKey = indexNameSubspace.pack(valueRange.end)

        // For exact match, add 0xFF
        if beginKey == endKey {
            endKey.append(0xFF)
        }

        // Create key selectors
        let beginSelector = FDB.KeySelector.firstGreaterOrEqual(beginKey)
        let endSelector = FDB.KeySelector.firstGreaterOrEqual(endKey)

        // Execute range read
        let sequence = transaction.getRange(
            beginSelector: beginSelector,
            endSelector: endSelector,
            snapshot: snapshot
        )

        // Create cursor
        // NOTE: recordName is obtained from RecordAccess, not from generic type
        // This ensures compatibility with the Recordable protocol
        // ✅ FIX: Use Record.recordName instead of String(describing:) to support custom record names
        let recordName = Record.recordName
        let cursor = RankIndexValueCursor(
            sequence: sequence,
            indexSubspace: indexNameSubspace,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            recordName: recordName,
            limit: limit
        )

        return AnyTypedRecordCursor(cursor)
    }

    /// Execute by-rank scan (top N / bottom N)
    private func executeByRank(transaction: any TransactionProtocol, snapshot: Bool) async throws -> AnyTypedRecordCursor<Record> {
        guard let rankRange = rankRange else {
            throw RecordLayerError.invalidArgument(
                "rankRange is required for byRank scan"
            )
        }

        // Build index subspace
        let indexNameSubspace = indexSubspace.subspace(index.name)

        // Get all index keys in rank order
        let (begin, end) = indexNameSubspace.range()
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(begin),
            endSelector: .firstGreaterOrEqual(end),
            snapshot: snapshot
        )

        // Create cursor with rank filtering
        // NOTE: recordName is obtained from RecordAccess, not from generic type
        // ✅ FIX: Use Record.recordName instead of String(describing:) to support custom record names
        let recordName = Record.recordName
        let cursor = RankIndexRankCursor(
            sequence: sequence,
            indexSubspace: indexNameSubspace,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            recordName: recordName,
            rankRange: rankRange,
            ascending: ascending
        )

        return AnyTypedRecordCursor(cursor)
    }
}

// MARK: - Rank Index Cursors

/// Cursor for by-value rank index scan
private struct RankIndexValueCursor<Record: Recordable>: TypedRecordCursor {
    let sequence: FDB.AsyncKVSequence
    let indexSubspace: Subspace
    let recordSubspace: Subspace
    let recordAccess: any RecordAccess<Record>
    let transaction: any TransactionProtocol
    let recordName: String
    let limit: Int?

    func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            iterator: sequence.makeAsyncIterator(),
            indexSubspace: indexSubspace,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            recordName: recordName,
            limit: limit
        )
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: FDB.AsyncKVSequence.AsyncIterator
        let indexSubspace: Subspace
        let recordSubspace: Subspace
        let recordAccess: any RecordAccess<Record>
        let transaction: any TransactionProtocol
        let recordName: String
        let limit: Int?
        var count: Int = 0

        mutating func next() async throws -> Record? {
            // Check limit
            if let limit = limit, count >= limit {
                return nil
            }

            // Get next index entry
            guard let (indexKey, _) = try await iterator.next() else {
                return nil
            }

            // Extract primary key from index key
            let indexTuple = try indexSubspace.unpack(indexKey)
            let rootCount = 1  // RANK index has 1 indexed field (the value)

            // Extract primary key (last elements)
            var primaryKeyElements: [any TupleElement] = []
            for i in rootCount..<indexTuple.count {
                if let element = indexTuple[i] {
                    primaryKeyElements.append(element)
                }
            }

            let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

            // Fetch record
            let effectiveSubspace = recordSubspace.subspace(recordName)
            let recordKey = effectiveSubspace.subspace(primaryKeyTuple).pack(Tuple())
            guard let recordValue = try await transaction.getValue(for: recordKey, snapshot: false) else {
                // Record not found, skip
                return try await next()
            }

            count += 1

            // Deserialize record
            return try recordAccess.deserialize(recordValue)
        }
    }
}

/// Cursor for by-rank rank index scan
private struct RankIndexRankCursor<Record: Recordable>: TypedRecordCursor {
    let sequence: FDB.AsyncKVSequence
    let indexSubspace: Subspace
    let recordSubspace: Subspace
    let recordAccess: any RecordAccess<Record>
    let transaction: any TransactionProtocol
    let recordName: String
    let rankRange: RankRange
    let ascending: Bool

    func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            iterator: sequence.makeAsyncIterator(),
            indexSubspace: indexSubspace,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            recordName: recordName,
            rankRange: rankRange,
            ascending: ascending
        )
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: FDB.AsyncKVSequence.AsyncIterator
        let indexSubspace: Subspace
        let recordSubspace: Subspace
        let recordAccess: any RecordAccess<Record>
        let transaction: any TransactionProtocol
        let recordName: String
        let rankRange: RankRange
        let ascending: Bool
        var currentRank: Int = 0

        mutating func next() async throws -> Record? {
            // Skip to begin rank
            while currentRank < rankRange.begin {
                guard let _ = try await iterator.next() else {
                    return nil
                }
                currentRank += 1
            }

            // Check if we've reached end rank
            if currentRank >= rankRange.end {
                return nil
            }

            // Get next index entry
            guard let (indexKey, _) = try await iterator.next() else {
                return nil
            }

            currentRank += 1

            // Extract primary key from index key
            let indexTuple = try indexSubspace.unpack(indexKey)
            let rootCount = 1  // RANK index has 1 indexed field (the value)

            // Extract primary key (last elements)
            var primaryKeyElements: [any TupleElement] = []
            for i in rootCount..<indexTuple.count {
                if let element = indexTuple[i] {
                    primaryKeyElements.append(element)
                }
            }

            let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

            // Fetch record
            let effectiveSubspace = recordSubspace.subspace(recordName)
            let recordKey = effectiveSubspace.subspace(primaryKeyTuple).pack(Tuple())
            guard let recordValue = try await transaction.getValue(for: recordKey, snapshot: false) else {
                // Record not found, skip
                return try await next()
            }

            // Deserialize record
            return try recordAccess.deserialize(recordValue)
        }
    }
}
