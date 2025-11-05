import Foundation
import FoundationDB

/// Cursor for iterating records within a transaction
///
/// TransactionCursor is bound to a transaction and can only be used within
/// the transaction block. It does NOT conform to TransactionResult, so the
/// compiler prevents it from being returned from transaction blocks.
///
/// **Important:**
/// - Must be consumed within the transaction block
/// - Uses snapshot: false (change detection enabled)
/// - Cannot be returned from transaction blocks (compile-time error)
///
/// **Usage:**
/// ```swift
/// try await context.transaction { transaction in
///     let cursor = try await transaction.fetch(query)
///     for try await user in cursor {
///         print(user.name)
///     }
/// }
/// ```
public struct TransactionCursor<Record: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Record

    private let context: RecordContext
    private let query: RecordQuery
    private let recordAccess: any RecordAccess<Record>
    private let recordSubspace: Subspace
    private let storeSubspace: Subspace
    private let metaData: RecordMetaData

    // MARK: - Initialization

    internal init(
        context: RecordContext,
        query: RecordQuery,
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace,
        storeSubspace: Subspace,
        metaData: RecordMetaData
    ) {
        self.context = context
        self.query = query
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
        self.storeSubspace = storeSubspace
        self.metaData = metaData
    }

    // MARK: - AsyncSequence

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            context: context,
            query: query,
            recordAccess: recordAccess,
            storeSubspace: storeSubspace,
            metaData: metaData
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let context: RecordContext
        private let query: RecordQuery
        private let recordAccess: any RecordAccess<Record>
        private let storeSubspace: Subspace
        private let metaData: RecordMetaData

        private var typedCursor: AnyTypedRecordCursor<Record>?
        private var typedIterator: AnyTypedRecordCursor<Record>.AnyAsyncIterator?
        private var initialized = false

        init(
            context: RecordContext,
            query: RecordQuery,
            recordAccess: any RecordAccess<Record>,
            storeSubspace: Subspace,
            metaData: RecordMetaData
        ) {
            self.context = context
            self.query = query
            self.recordAccess = recordAccess
            self.storeSubspace = storeSubspace
            self.metaData = metaData
        }

        public mutating func next() async throws -> Record? {
            if !initialized {
                // Convert RecordQuery to TypedRecordQuery
                guard let recordTypeName = query.recordTypes.first else {
                    return nil
                }

                let typedQuery: TypedRecordQuery<Record> = try query.toTypedQuery(recordTypeName: recordTypeName)

                // Use QueryPlanner to create optimal execution plan
                let planner = TypedRecordQueryPlanner<Record>(
                    metaData: metaData,
                    recordTypeName: recordTypeName
                )
                let plan = try await planner.plan(query: typedQuery)

                // Execute the plan
                // Use snapshot: false for serializable reads within transactions
                // - Enables conflict detection
                // - Provides Read-Your-Writes guarantee
                // - Ensures Serializable isolation
                let cursor = try await plan.execute(
                    subspace: storeSubspace,
                    recordAccess: recordAccess,
                    context: context,
                    snapshot: false
                )

                self.typedCursor = cursor
                self.typedIterator = typedCursor?.makeAsyncIterator()
                initialized = true
            }

            return try await typedIterator?.next()
        }
    }

    // MARK: - Collection Methods

    /// Collect cursor results into an array
    ///
    /// This method fully consumes the cursor and returns all results as an array.
    /// The array can be returned from the transaction block since Array conforms
    /// to TransactionResult.
    ///
    /// **Warning:** This loads all results into memory. Use with caution for large datasets.
    ///
    /// - Parameter limit: Maximum number of records to collect (default: 1000)
    /// - Returns: Array of records
    public func collect(limit: Int = 1000) async throws -> [Record] {
        var results: [Record] = []
        results.reserveCapacity(Swift.min(limit, 1000))

        for try await record in self {
            results.append(record)
            if results.count >= limit {
                break
            }
        }

        return results
    }

    /// Get the first record
    ///
    /// - Returns: First record or nil if no results
    public func first() async throws -> Record? {
        var iterator = makeAsyncIterator()
        return try await iterator.next()
    }

    /// Get the first record matching a predicate
    ///
    /// - Parameter predicate: Closure to test each record
    /// - Returns: First matching record or nil
    public func first(
        where predicate: (Record) throws -> Bool
    ) async throws -> Record? {
        for try await record in self {
            if try predicate(record) {
                return record
            }
        }
        return nil
    }

    /// Count the number of records
    ///
    /// **Warning:** This fully consumes the cursor.
    ///
    /// - Returns: Number of records
    public func count() async throws -> Int {
        var count = 0
        for try await _ in self {
            count += 1
        }
        return count
    }
}
