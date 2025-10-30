import Foundation
import FoundationDB

/// Type-safe cursor for iterating over query results
///
/// TypedRecordCursor provides an async sequence interface for query results.
public protocol TypedRecordCursor<Record>: AsyncSequence where Element == Record {
    associatedtype Record: Sendable
}

// MARK: - Basic Record Cursor

/// Basic cursor implementation for full scans
public struct BasicTypedRecordCursor<Record: Sendable, A: FieldAccessor, S: RecordSerializer>: TypedRecordCursor
where A.Record == Record, S.Record == Record {
    public typealias Element = Record

    private let sequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>
    private let serializer: S
    private let accessor: A
    private let filter: (any TypedQueryComponent<Record>)?

    init(
        sequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>,
        serializer: S,
        accessor: A,
        filter: (any TypedQueryComponent<Record>)?
    ) {
        self.sequence = sequence
        self.serializer = serializer
        self.accessor = accessor
        self.filter = filter
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: any AsyncIteratorProtocol<(FDB.Bytes, FDB.Bytes), Error>
        let serializer: S
        let accessor: A
        let filter: (any TypedQueryComponent<Record>)?

        public mutating func next() async throws -> Record? {
            while true {
                guard let pair = try await iterator.next() else {
                    return nil
                }

                let record = try serializer.deserialize(pair.1)

                // Apply filter
                if let filter = filter {
                    guard filter.matches(record: record, accessor: accessor) else {
                        continue
                    }
                }

                return record
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let iter = sequence.makeAsyncIterator()
        return AsyncIterator(
            iterator: iter,
            serializer: serializer,
            accessor: accessor,
            filter: filter
        )
    }
}

// MARK: - Index Scan Cursor

/// Cursor for index scans that fetches actual records
public struct IndexScanTypedCursor<Record: Sendable, A: FieldAccessor, S: RecordSerializer>: TypedRecordCursor
where A.Record == Record, S.Record == Record {
    public typealias Element = Record

    private let indexSequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>
    private let recordSubspace: Subspace
    private let serializer: S
    private let accessor: A
    private let transaction: any TransactionProtocol
    private let filter: (any TypedQueryComponent<Record>)?
    private let primaryKeyLength: Int

    init(
        indexSequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>,
        recordSubspace: Subspace,
        serializer: S,
        accessor: A,
        transaction: any TransactionProtocol,
        filter: (any TypedQueryComponent<Record>)?,
        primaryKeyLength: Int
    ) {
        self.indexSequence = indexSequence
        self.recordSubspace = recordSubspace
        self.serializer = serializer
        self.accessor = accessor
        self.transaction = transaction
        self.filter = filter
        self.primaryKeyLength = primaryKeyLength
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: any AsyncIteratorProtocol<(FDB.Bytes, FDB.Bytes), Error>
        let recordSubspace: Subspace
        let serializer: S
        let accessor: A
        let transaction: any TransactionProtocol
        let filter: (any TypedQueryComponent<Record>)?
        let primaryKeyLength: Int

        public mutating func next() async throws -> Record? {
            while true {
                guard let pair = try await iterator.next() else {
                    return nil
                }
                let indexKey = pair.0

                // Extract primary key from index key
                // Index key format: [index_subspace_prefix][indexed_values...][primary_key...]
                // We need to extract the last primaryKeyLength elements as the primary key

                // Decode the full index key
                let indexTuple = try Tuple.decode(from: indexKey)

                // Extract primary key elements (last N elements)
                guard indexTuple.count >= primaryKeyLength else {
                    continue
                }

                let primaryKeyElements = Array(indexTuple.suffix(primaryKeyLength))
                let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

                // Fetch the actual record
                let recordKey = recordSubspace.pack(primaryKeyTuple)
                guard let recordBytes = try await transaction.getValue(for: recordKey) else {
                    continue
                }

                let record = try serializer.deserialize(recordBytes)

                // Apply filter
                if let filter = filter {
                    guard filter.matches(record: record, accessor: accessor) else {
                        continue
                    }
                }

                return record
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let iter = indexSequence.makeAsyncIterator()
        return AsyncIterator(
            iterator: iter,
            recordSubspace: recordSubspace,
            serializer: serializer,
            accessor: accessor,
            transaction: transaction,
            filter: filter,
            primaryKeyLength: primaryKeyLength
        )
    }
}

// MARK: - Limited Cursor

/// Cursor that limits the number of results
public struct LimitedTypedCursor<C: TypedRecordCursor>: TypedRecordCursor {
    public typealias Record = C.Record
    public typealias Element = C.Record

    private let source: C
    private let limit: Int

    init(source: C, limit: Int) {
        self.source = source
        self.limit = limit
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var sourceIterator: C.AsyncIterator
        let limit: Int
        var count: Int = 0

        public mutating func next() async throws -> C.Record? {
            guard count < limit else { return nil }

            guard let record = try await sourceIterator.next() else {
                return nil
            }

            count += 1
            return record
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            sourceIterator: source.makeAsyncIterator(),
            limit: limit
        )
    }
}

// MARK: - Type Erased Cursor

/// Type-erased cursor wrapper
public struct AnyTypedRecordCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let _makeAsyncIterator: () -> AnyAsyncIterator

    public init<C: TypedRecordCursor>(_ cursor: C) where C.Record == Record {
        self._makeAsyncIterator = {
            AnyAsyncIterator(cursor.makeAsyncIterator())
        }
    }

    public func makeAsyncIterator() -> AnyAsyncIterator {
        return _makeAsyncIterator()
    }

    public struct AnyAsyncIterator: AsyncIteratorProtocol {
        private var _next: () async throws -> Record?

        init<I: AsyncIteratorProtocol>(_ iterator: I) where I.Element == Record {
            var iterator = iterator
            self._next = {
                try await iterator.next()
            }
        }

        public mutating func next() async throws -> Record? {
            return try await _next()
        }
    }
}
