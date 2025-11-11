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
public struct BasicTypedRecordCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let sequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>
    private let recordAccess: any RecordAccess<Record>
    private let filter: (any TypedQueryComponent<Record>)?
    private let expectedRecordType: String?

    init(
        sequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>,
        recordAccess: any RecordAccess<Record>,
        filter: (any TypedQueryComponent<Record>)?,
        expectedRecordType: String? = nil
    ) {
        self.sequence = sequence
        self.recordAccess = recordAccess
        self.filter = filter
        self.expectedRecordType = expectedRecordType
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: any AsyncIteratorProtocol<(FDB.Bytes, FDB.Bytes), Error>
        let recordAccess: any RecordAccess<Record>
        let filter: (any TypedQueryComponent<Record>)?
        let expectedRecordType: String?

        public mutating func next() async throws -> Record? {
            while true {
                guard let pair = try await iterator.next() else {
                    return nil
                }

                let record = try recordAccess.deserialize(pair.1)

                // Check recordType if expectedRecordType is specified
                if let expectedType = expectedRecordType {
                    let actualType = recordAccess.recordName(for: record)
                    guard actualType == expectedType else {
                        continue  // Skip records of wrong type
                    }
                }

                // Apply filter
                if let filter = filter {
                    guard try filter.matches(record: record, recordAccess: recordAccess) else {
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
            recordAccess: recordAccess,
            filter: filter,
            expectedRecordType: expectedRecordType
        )
    }
}

// MARK: - Index Scan Cursor

/// Cursor for index scans that fetches actual records
public struct IndexScanTypedCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let indexSequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>
    private let indexSubspace: Subspace
    private let recordSubspace: Subspace
    private let recordAccess: any RecordAccess<Record>
    private let transaction: any TransactionProtocol
    private let filter: (any TypedQueryComponent<Record>)?
    private let primaryKeyLength: Int
    private let recordName: String
    private let snapshot: Bool

    init(
        indexSequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>,
        indexSubspace: Subspace,
        recordSubspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol,
        filter: (any TypedQueryComponent<Record>)?,
        primaryKeyLength: Int,
        recordName: String,
        snapshot: Bool
    ) {
        self.indexSequence = indexSequence
        self.indexSubspace = indexSubspace
        self.recordSubspace = recordSubspace
        self.recordAccess = recordAccess
        self.transaction = transaction
        self.filter = filter
        self.primaryKeyLength = primaryKeyLength
        self.recordName = recordName
        self.snapshot = snapshot
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: any AsyncIteratorProtocol<(FDB.Bytes, FDB.Bytes), Error>
        let indexSubspace: Subspace
        let recordSubspace: Subspace
        let recordAccess: any RecordAccess<Record>
        let transaction: any TransactionProtocol
        let filter: (any TypedQueryComponent<Record>)?
        let primaryKeyLength: Int
        let recordName: String
        let snapshot: Bool

        public mutating func next() async throws -> Record? {
            while true {
                guard let pair = try await iterator.next() else {
                    return nil
                }
                let indexKey = pair.0

                // Extract primary key from index key
                // Index key format: [index_subspace_prefix][indexed_values...][primary_key...]
                // We need to extract the last primaryKeyLength elements as the primary key

                // CRITICAL FIX: Use indexSubspace.unpack() to remove the prefix
                // indexKey contains the full key with subspace prefix
                // We need to unpack it relative to indexSubspace to get the tuple elements
                let indexTuple = try indexSubspace.unpack(indexKey)
                let elements = Array(0..<indexTuple.count).compactMap { indexTuple[$0] }

                // Extract primary key elements (last N elements)
                guard elements.count >= primaryKeyLength else {
                    continue
                }

                let primaryKeyElements = Array(elements.suffix(primaryKeyLength))
                let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

                // CRITICAL FIX: RecordStore saves records with record type name in the key
                // Key structure: <R-subspace> + <recordName> + <nested-primaryKey>
                // Must match RecordStore.saveInternal() key construction:
                //   recordSubspace.subspace(Record.recordName).subspace(primaryKey).pack(Tuple())
                let effectiveSubspace = recordSubspace.subspace(recordName)
                let recordKey = effectiveSubspace.subspace(primaryKeyTuple).pack(Tuple())

                guard let recordBytes = try await transaction.getValue(for: recordKey, snapshot: snapshot) else {
                    continue
                }

                let record = try recordAccess.deserialize(recordBytes)

                // Apply filter
                if let filter = filter {
                    guard try filter.matches(record: record, recordAccess: recordAccess) else {
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
            indexSubspace: indexSubspace,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            filter: filter,
            primaryKeyLength: primaryKeyLength,
            recordName: recordName,
            snapshot: snapshot
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

// MARK: - Filtered Cursor

/// Cursor that applies filtering to source records
///
/// FilteredTypedCursor wraps another cursor and applies a filter predicate
/// to each record, only returning records that match the filter.
public struct FilteredTypedCursor<C: TypedRecordCursor>: TypedRecordCursor {
    public typealias Record = C.Record
    public typealias Element = C.Record

    private let source: C
    private let filter: any TypedQueryComponent<C.Record>
    private let recordAccess: any RecordAccess<C.Record>

    init(
        source: C,
        filter: any TypedQueryComponent<C.Record>,
        recordAccess: any RecordAccess<C.Record>
    ) {
        self.source = source
        self.filter = filter
        self.recordAccess = recordAccess
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var sourceIterator: C.AsyncIterator
        let filter: any TypedQueryComponent<C.Record>
        let recordAccess: any RecordAccess<C.Record>

        public mutating func next() async throws -> C.Record? {
            while true {
                guard let record = try await sourceIterator.next() else {
                    return nil
                }

                // Apply filter
                if try filter.matches(record: record, recordAccess: recordAccess) {
                    return record
                }
                // If doesn't match, continue to next record
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            sourceIterator: source.makeAsyncIterator(),
            filter: filter,
            recordAccess: recordAccess
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
