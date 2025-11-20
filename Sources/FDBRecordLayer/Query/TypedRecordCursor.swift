import Foundation
import FoundationDB
import Synchronization

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
                    let matches = try filter.matches(record: record, recordAccess: recordAccess)
                    guard matches else {
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
///
/// **Concurrency Design:**
///
/// This implementation uses `nonisolated(unsafe)` for iterator storage, which is safe because:
///
/// 1. **AsyncIteratorProtocol Contract**: The protocol guarantees that `next()` will not be
///    called concurrently on the same iterator instance. Each iterator is used sequentially
///    from a single task.
///
/// 2. **Single-Owner Pattern**: Once an iterator is created via `makeAsyncIterator()`, it
///    follows single-owner semantics. The caller is responsible for ensuring no concurrent
///    access, which aligns with Swift's async sequence iteration model.
///
/// 3. **Analogous to DatabaseProtocol**: Similar to how `DatabaseProtocol` is marked
///    `nonisolated(unsafe)` because it's internally thread-safe, iterators are marked
///    `nonisolated(unsafe)` because the protocol contract ensures safe sequential access.
///
/// **Why Not Mutex:**
///
/// - `Mutex.withLock` only supports synchronous closures
/// - Iterator `next()` is async and may involve I/O operations
/// - Adding Mutex would require restructuring the async call chain, breaking type erasure
/// - The protocol contract already provides the necessary guarantees
///
/// **Project Pattern Adherence:**
///
/// This follows the project's `final class + nonisolated(unsafe)` pattern for types with
/// external thread-safety guarantees, similar to `DatabaseProtocol` usage throughout the codebase.
public struct AnyTypedRecordCursor<Record: Sendable>: TypedRecordCursor, Sendable {
    public typealias Element = Record

    /// Generic cursor wrapper (private nested type)
    ///
    /// This type IS generic, but it's only instantiated during initialization.
    /// The generic type parameter is erased before storage.
    private final class CursorBox<C: TypedRecordCursor>: @unchecked Sendable where C.Record == Record {
        var cursor: C

        init(_ cursor: C) {
            self.cursor = cursor
        }

        func makeIterator() -> AnyAsyncIterator {
            let iterator = cursor.makeAsyncIterator()
            return AnyAsyncIterator(iterator)
        }
    }

    /// Non-generic box for type-erased iterator factory
    ///
    /// **Design**: This box is NOT generic, preventing metatype capture issues.
    /// The generic type parameter is erased at initialization, not stored.
    ///
    /// Marked `@unchecked Sendable` because:
    /// - Cursor usage follows single-owner pattern
    /// - Each iterator instance is used from a single task
    /// - AsyncIteratorProtocol contract ensures no concurrent calls
    private final class Box: @unchecked Sendable {
        /// Iterator factory function (NOT marked @Sendable)
        ///
        /// This closure is NOT @Sendable, which allows it to capture generic types
        /// without triggering metatype Sendable warnings. This is safe because:
        /// - Box itself is @unchecked Sendable
        /// - The closure is only called from makeAsyncIterator()
        /// - Each call creates a new iterator with independent state
        let makeIterator: () -> AnyAsyncIterator

        init(_ makeIterator: @escaping () -> AnyAsyncIterator) {
            self.makeIterator = makeIterator
        }
    }

    /// Stored box (non-generic type)
    ///
    /// Because Box is not generic, capturing it does NOT capture metatype information,
    /// solving the Swift 6 concurrency warning without `nonisolated(unsafe)`.
    private let box: Box

    public init<C: TypedRecordCursor>(_ cursor: C) where C.Record == Record {
        let cursorBox = CursorBox(cursor)

        // Store non-generic box with closure that captures cursorBox
        // This closure is NOT @Sendable, so it can capture generic types safely
        self.box = Box {
            cursorBox.makeIterator()
        }
    }

    public func makeAsyncIterator() -> AnyAsyncIterator {
        return box.makeIterator()
    }

    /// Type-erased async iterator
    ///
    /// **Concurrency Safety:**
    /// - AsyncIteratorProtocol contract guarantees sequential access to `next()`
    /// - No concurrent calls to `next()` on the same iterator instance
    ///
    /// **Performance:**
    /// - Zero-overhead type erasure
    /// - Direct async calls without synchronization overhead
    /// - Ideal for high-throughput query result iteration
    public struct AnyAsyncIterator: AsyncIteratorProtocol {
        /// Generic iterator wrapper (private nested type)
        ///
        /// This type IS generic, but it's only instantiated during initialization.
        /// The generic type parameter is erased before storage.
        private final class IteratorBox<I: AsyncIteratorProtocol>: @unchecked Sendable where I.Element == Record {
            var iterator: I

            init(_ iterator: I) {
                self.iterator = iterator
            }

            func next() async throws -> Record? {
                return try await iterator.next()
            }
        }

        /// Non-generic box for type-erased next function
        ///
        /// This design eliminates Swift 6 Sendable warnings by avoiding generic metatype capture:
        /// - `Box` is NOT generic → no metatype to capture
        /// - Closure is NOT `@Sendable` → can safely capture generic types
        /// - Generic types only exist during initialization, completely erased afterward
        ///
        /// **Why `@unchecked Sendable`:**
        /// - AsyncIteratorProtocol guarantees sequential access (no concurrent calls to `next()`)
        /// - Each iterator instance is used from a single task
        /// - Mutable state is safe under protocol contract
        private final class Box: @unchecked Sendable {
            /// Next function (NOT marked @Sendable - can capture generic types)
            let next: () async throws -> Record?

            init(_ next: @escaping () async throws -> Record?) {
                self.next = next
            }
        }

        /// Stored box (non-generic type - no metatype capture)
        private let box: Box

        init<I: AsyncIteratorProtocol>(_ iterator: I) where I.Element == Record {
            let iteratorBox = IteratorBox(iterator)

            // Store non-generic box with closure that captures iteratorBox
            // This closure is NOT @Sendable, so it can capture generic types safely
            self.box = Box {
                try await iteratorBox.next()
            }
        }

        public mutating func next() async throws -> Record? {
            return try await box.next()
        }
    }
}

// MARK: - Covering Index Scan Cursor

/// Cursor for scanning covering indexes (reconstructs records without fetching)
///
/// **Performance Improvement**:
/// - Regular index scan: Index key scan + getValue() per result (2 round-trips)
/// - Covering index scan: Index key+value scan + reconstruct() (1 round-trip, 2-10x faster)
///
/// **Requirements**:
/// - Index must have coveringFields defined
/// - RecordAccess must implement reconstruct() and return supportsReconstruction = true
///
/// **Example**:
/// ```swift
/// let coveringIndex = Index.covering(
///     named: "user_by_city_covering",
///     on: FieldKeyExpression(fieldName: "city"),
///     covering: [
///         FieldKeyExpression(fieldName: "name"),
///         FieldKeyExpression(fieldName: "email")
///     ]
/// )
///
/// // Query only needs: city, name, email, userID → all covered
/// let cursor = CoveringIndexScanTypedCursor(...)
/// // No getValue() calls → 2-10x faster
/// ```
public struct CoveringIndexScanTypedCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let indexSequence: FDB.AsyncKVSequence
    private let indexSubspace: Subspace
    private let recordAccess: any RecordAccess<Record>
    private let transaction: any TransactionProtocol
    private let filter: (any TypedQueryComponent<Record>)?
    private let index: Index
    private let primaryKeyExpression: KeyExpression
    private let snapshot: Bool

    init(
        indexSequence: FDB.AsyncKVSequence,
        indexSubspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol,
        filter: (any TypedQueryComponent<Record>)?,
        index: Index,
        primaryKeyExpression: KeyExpression,
        snapshot: Bool
    ) {
        self.indexSequence = indexSequence
        self.indexSubspace = indexSubspace
        self.recordAccess = recordAccess
        self.transaction = transaction
        self.filter = filter
        self.index = index
        self.primaryKeyExpression = primaryKeyExpression
        self.snapshot = snapshot
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: FDB.AsyncKVSequence.AsyncIterator
        let indexSubspace: Subspace
        let recordAccess: any RecordAccess<Record>
        let filter: (any TypedQueryComponent<Record>)?
        let index: Index
        let primaryKeyExpression: KeyExpression

        public mutating func next() async throws -> Record? {
            while true {
                guard let (indexKey, indexValue) = try await iterator.next() else {
                    return nil
                }

                // Unpack index key to get indexed fields + primary key
                let indexTuple = try indexSubspace.unpack(indexKey)

                // Reconstruct record from index key and value
                // No getValue() call needed → performance improvement
                let record = try recordAccess.reconstruct(
                    indexKey: indexTuple,
                    indexValue: indexValue,
                    index: index,
                    primaryKeyExpression: primaryKeyExpression
                )

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
            recordAccess: recordAccess,
            filter: filter,
            index: index,
            primaryKeyExpression: primaryKeyExpression
        )
    }
}
