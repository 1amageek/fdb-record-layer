import Foundation
import FoundationDB

/// Protocol for type-safe query execution plans
///
/// TypedQueryPlan defines how a query will be executed against the record store.
public protocol TypedQueryPlan<Record>: Sendable {
    associatedtype Record: Sendable

    /// Execute the plan
    /// - Parameters:
    ///   - subspace: The record store subspace
    ///   - recordAccess: The record access for field extraction and serialization
    ///   - context: The transaction context
    ///   - snapshot: Whether to use snapshot reads (true) or serializable reads (false)
    ///               - true: No conflict detection, read-only optimization
    ///               - false: Conflict detection enabled, Read-Your-Writes, Serializable isolation
    /// - Returns: An async sequence of records
    func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record>
}

// MARK: - Full Scan Plan

/// Full table scan plan
public struct TypedFullScanPlan<Record: Sendable>: TypedQueryPlan {
    public let filter: (any TypedQueryComponent<Record>)?
    public let expectedRecordType: String?

    public init(filter: (any TypedQueryComponent<Record>)?, expectedRecordType: String? = nil) {
        self.filter = filter
        self.expectedRecordType = expectedRecordType
    }

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let transaction = context.getTransaction()

        let (beginKey, endKey) = recordSubspace.range()

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterThan(endKey),
            snapshot: snapshot
        )

        let cursor = BasicTypedRecordCursor(
            sequence: sequence,
            recordAccess: recordAccess,
            filter: filter,
            expectedRecordType: expectedRecordType
        )

        return AnyTypedRecordCursor(cursor)
    }
}

// MARK: - Index Scan Plan

/// Index scan plan
public struct TypedIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    public let indexName: String
    public let indexSubspaceTupleKey: any TupleElement
    public let beginValues: [any TupleElement]
    public let endValues: [any TupleElement]
    public let filter: (any TypedQueryComponent<Record>)?
    public let primaryKeyLength: Int

    public init(
        indexName: String,
        indexSubspaceTupleKey: any TupleElement,
        beginValues: [any TupleElement],
        endValues: [any TupleElement],
        filter: (any TypedQueryComponent<Record>)?,
        primaryKeyLength: Int
    ) {
        self.indexName = indexName
        self.indexSubspaceTupleKey = indexSubspaceTupleKey
        self.beginValues = beginValues
        self.endValues = endValues
        self.filter = filter
        self.primaryKeyLength = primaryKeyLength
    }

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        let transaction = context.getTransaction()
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(indexSubspaceTupleKey)

        // Build index key range
        let beginTuple = TupleHelpers.toTuple(beginValues)
        let endTuple = TupleHelpers.toTuple(endValues)

        let beginKey = indexSubspace.pack(beginTuple)
        let endKey = indexSubspace.pack(endTuple)

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterThan(endKey),
            snapshot: snapshot
        )

        // For index scans, we need to fetch the actual records
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        let cursor = IndexScanTypedCursor(
            indexSequence: sequence,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            filter: filter,
            primaryKeyLength: primaryKeyLength
        )

        return AnyTypedRecordCursor(cursor)
    }
}

// MARK: - Limit Plan

/// Limit plan (restricts number of results)
public struct TypedLimitPlan<Record: Sendable>: TypedQueryPlan {
    public let child: any TypedQueryPlan<Record>
    public let limit: Int

    public init(child: any TypedQueryPlan<Record>, limit: Int) {
        self.child = child
        self.limit = limit
    }

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        let childCursor = try await child.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: snapshot
        )

        let limitedCursor = LimitedTypedCursor(source: childCursor, limit: limit)

        return AnyTypedRecordCursor(limitedCursor)
    }
}

// MARK: - Array Cursor

/// Simple cursor over an array of records
private struct ArrayCursor<Record: Sendable>: TypedRecordCursor {
    typealias Element = Record

    let sequence: AsyncStream<Record>

    init(sequence: AsyncStream<Record>) {
        self.sequence = sequence
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<Record>.AsyncIterator

        mutating func next() async throws -> Record? {
            return await iterator.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(iterator: sequence.makeAsyncIterator())
    }
}
