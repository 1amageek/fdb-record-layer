import Foundation
import FoundationDB

/// Cursor for snapshot reads outside of explicit transactions
///
/// SnapshotCursor creates its own transaction internally and uses snapshot: true
/// for read-only operations without conflict detection. This is suitable for
/// single read operations that don't require serializability.
///
/// **Characteristics:**
/// - Uses snapshot: true (no conflict detection)
/// - Creates its own transaction internally
/// - Automatically cancels transaction on completion
/// - Suitable for single read operations
///
/// **Usage:**
/// ```swift
/// let cursor = try await context.fetch(query)
/// for try await user in cursor {
///     print(user.name)
/// }
/// ```
public struct SnapshotCursor<Record: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Record

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let query: RecordQuery
    private let recordAccess: any RecordAccess<Record>
    private let recordSubspace: Subspace
    private let storeSubspace: Subspace
    private let metaData: RecordMetaData

    // MARK: - Initialization

    internal init(
        database: any DatabaseProtocol,
        query: RecordQuery,
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace,
        storeSubspace: Subspace,
        metaData: RecordMetaData
    ) {
        self.database = database
        self.query = query
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
        self.storeSubspace = storeSubspace
        self.metaData = metaData
    }

    // MARK: - AsyncSequence

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            database: database,
            query: query,
            recordAccess: recordAccess,
            recordSubspace: recordSubspace,
            storeSubspace: storeSubspace,
            metaData: metaData
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        nonisolated(unsafe) private let database: any DatabaseProtocol
        private let query: RecordQuery
        private let recordAccess: any RecordAccess<Record>
        private let recordSubspace: Subspace
        private let storeSubspace: Subspace
        private let metaData: RecordMetaData

        private var context: RecordContext?
        private var typedCursor: AnyTypedRecordCursor<Record>?
        private var typedIterator: AnyTypedRecordCursor<Record>.AnyAsyncIterator?
        private var initialized = false

        init(
            database: any DatabaseProtocol,
            query: RecordQuery,
            recordAccess: any RecordAccess<Record>,
            recordSubspace: Subspace,
            storeSubspace: Subspace,
            metaData: RecordMetaData
        ) {
            self.database = database
            self.query = query
            self.recordAccess = recordAccess
            self.recordSubspace = recordSubspace
            self.storeSubspace = storeSubspace
            self.metaData = metaData
        }

        public mutating func next() async throws -> Record? {
            if !initialized {
                // Create transaction for this cursor
                let transaction = try database.createTransaction()
                let ctx = RecordContext(transaction: transaction)
                self.context = ctx

                // Convert RecordQuery to TypedRecordQuery
                guard let recordTypeName = query.recordTypes.first else {
                    context?.cancel()
                    return nil
                }

                let typedQuery: TypedRecordQuery<Record> = try query.toTypedQuery(recordTypeName: recordTypeName)

                // Use QueryPlanner to create optimal execution plan
                let planner = TypedRecordQueryPlanner<Record>(
                    metaData: metaData,
                    recordTypeName: recordTypeName
                )
                let plan = try planner.plan(query: typedQuery)

                // Execute the plan
                // Use snapshot: true for read-only snapshot queries
                // - No conflict detection needed
                // - Optimized for read-only operations
                // - No Read-Your-Writes semantics (single-use transaction)
                let cursor = try await plan.execute(
                    subspace: storeSubspace,
                    recordAccess: recordAccess,
                    context: ctx,
                    snapshot: true
                )

                self.typedCursor = cursor
                self.typedIterator = typedCursor?.makeAsyncIterator()
                initialized = true
            }

            // Get next record from typed cursor
            do {
                return try await typedIterator?.next()
            } catch {
                // Cancel transaction on error
                context?.cancel()
                throw error
            }
        }

    }

    // MARK: - Collection Methods

    /// Collect cursor results into an array
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
