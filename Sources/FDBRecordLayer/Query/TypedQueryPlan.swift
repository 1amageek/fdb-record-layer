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
    ///   - serializer: The record serializer
    ///   - accessor: The field accessor
    ///   - context: The transaction context
    /// - Returns: An async sequence of records
    func execute<A: FieldAccessor, S: RecordSerializer>(
        subspace: Subspace,
        serializer: S,
        accessor: A,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record>
    where A.Record == Record, S.Record == Record
}

// MARK: - Full Scan Plan

/// Full table scan plan
public struct TypedFullScanPlan<Record: Sendable>: TypedQueryPlan {
    public let filter: (any TypedQueryComponent<Record>)?

    public init(filter: (any TypedQueryComponent<Record>)?) {
        self.filter = filter
    }

    public func execute<A: FieldAccessor, S: RecordSerializer>(
        subspace: Subspace,
        serializer: S,
        accessor: A,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record>
    where A.Record == Record, S.Record == Record {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let transaction = context.getTransaction()

        let (beginKey, endKey) = recordSubspace.range()

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterThan(endKey),
            snapshot: true
        )

        let cursor = BasicTypedRecordCursor<Record, A, S>(
            sequence: sequence,
            serializer: serializer,
            accessor: accessor,
            filter: filter
        )

        return AnyTypedRecordCursor(cursor)
    }
}

// MARK: - Index Scan Plan

/// Index scan plan
public struct TypedIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    public let index: TypedIndex<Record>
    public let beginValues: [any TupleElement]
    public let endValues: [any TupleElement]
    public let filter: (any TypedQueryComponent<Record>)?
    public let primaryKeyLength: Int

    public init(
        index: TypedIndex<Record>,
        beginValues: [any TupleElement],
        endValues: [any TupleElement],
        filter: (any TypedQueryComponent<Record>)?,
        primaryKeyLength: Int
    ) {
        self.index = index
        self.beginValues = beginValues
        self.endValues = endValues
        self.filter = filter
        self.primaryKeyLength = primaryKeyLength
    }

    public func execute<A: FieldAccessor, S: RecordSerializer>(
        subspace: Subspace,
        serializer: S,
        accessor: A,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record>
    where A.Record == Record, S.Record == Record {
        let transaction = context.getTransaction()
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        // Build index key range
        let beginTuple = TupleHelpers.toTuple(beginValues)
        let endTuple = TupleHelpers.toTuple(endValues)

        let beginKey = indexSubspace.pack(beginTuple)
        let endKey = indexSubspace.pack(endTuple)

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterThan(endKey),
            snapshot: true
        )

        // For index scans, we need to fetch the actual records
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        let cursor = IndexScanTypedCursor<Record, A, S>(
            indexSequence: sequence,
            recordSubspace: recordSubspace,
            serializer: serializer,
            accessor: accessor,
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

    public func execute<A: FieldAccessor, S: RecordSerializer>(
        subspace: Subspace,
        serializer: S,
        accessor: A,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record>
    where A.Record == Record, S.Record == Record {
        let childCursor = try await child.execute(
            subspace: subspace,
            serializer: serializer,
            accessor: accessor,
            context: context
        )

        let limitedCursor = LimitedTypedCursor(source: childCursor, limit: limit)

        return AnyTypedRecordCursor(limitedCursor)
    }
}

// MARK: - Union Plan

/// Union plan (combines results from multiple plans)
public struct TypedUnionPlan<Record: Sendable>: TypedQueryPlan {
    public let children: [any TypedQueryPlan<Record>]

    public init(children: [any TypedQueryPlan<Record>]) {
        self.children = children
    }

    public func execute<A: FieldAccessor, S: RecordSerializer>(
        subspace: Subspace,
        serializer: S,
        accessor: A,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record>
    where A.Record == Record, S.Record == Record {
        // Execute all child plans and combine their results
        var allResults: [Record] = []

        for childPlan in children {
            let cursor = try await childPlan.execute(
                subspace: subspace,
                serializer: serializer,
                accessor: accessor,
                context: context
            )

            for try await record in cursor {
                allResults.append(record)
            }
        }

        // Return a cursor over the combined results
        let arraySequence = AsyncStream<Record> { continuation in
            for record in allResults {
                continuation.yield(record)
            }
            continuation.finish()
        }

        return AnyTypedRecordCursor(ArrayCursor(sequence: arraySequence))
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
