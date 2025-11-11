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
        let recordSubspace = subspace.subspace("R")
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
        let indexSubspace = subspace.subspace("I")
            .subspace(indexSubspaceTupleKey)

        // Build index key range
        let beginTuple = TupleHelpers.toTuple(beginValues)
        let endTuple = TupleHelpers.toTuple(endValues)

        // CRITICAL FIX: Use Subspace.range() to get correct prefix successors
        // For equality queries (beginTuple == endTuple), we need:
        //   beginKey = <prefix><tuple><0x00>
        //   endKey   = <prefix><tuple><0xFF>
        // This ensures all index entries <prefix><tuple><primaryKey> are included
        let beginNestedSubspace = indexSubspace.subspace(beginTuple)
        let endNestedSubspace = indexSubspace.subspace(endTuple)

        let (beginKey, _) = beginNestedSubspace.range()
        let (_, endKey) = endNestedSubspace.range()

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterOrEqual(endKey),  // Changed from .firstGreaterThan
            snapshot: snapshot
        )

        // For index scans, we need to fetch the actual records
        let recordSubspace = subspace.subspace("R")

        let cursor = IndexScanTypedCursor(
            indexSequence: sequence,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            filter: filter,
            primaryKeyLength: primaryKeyLength,
            snapshot: snapshot
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

// MARK: - Filter Plan

/// Filter plan (applies post-scan filtering)
///
/// This plan applies filtering to records produced by a child plan.
/// Use this when:
/// - The filter contains conditions not satisfied by an index
/// - Multiple filter conditions need to be applied at different stages
/// - The planner determines it's more efficient to filter after retrieval
public struct TypedFilterPlan<Record: Sendable>: TypedQueryPlan {
    public let child: any TypedQueryPlan<Record>
    public let filter: any TypedQueryComponent<Record>

    public init(
        child: any TypedQueryPlan<Record>,
        filter: any TypedQueryComponent<Record>
    ) {
        self.child = child
        self.filter = filter
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

        let filteredCursor = FilteredTypedCursor(
            source: childCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        return AnyTypedRecordCursor(filteredCursor)
    }
}

// MARK: - Array Cursor

/// Simple cursor over an array of records
///
/// Supports error propagation via AsyncThrowingStream.
private struct ArrayCursor<Record: Sendable>: TypedRecordCursor {
    typealias Element = Record

    let sequence: AsyncThrowingStream<Record, Error>

    init(sequence: AsyncThrowingStream<Record, Error>) {
        self.sequence = sequence
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncThrowingStream<Record, Error>.AsyncIterator

        mutating func next() async throws -> Record? {
            return try await iterator.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(iterator: sequence.makeAsyncIterator())
    }
}

// MARK: - IN Join Plan

/// IN Join plan (optimized for IN predicates)
///
/// Executes multiple index scans (one per IN value) and unions the results.
/// This is more efficient than OR expansion when:
/// 1. An index exists on the field
/// 2. The number of values is small to moderate (< 100)
///
/// **Example**:
/// ```swift
/// // Query: age IN (20, 25, 30)
/// // Becomes: Union of:
/// //   - Index scan for age == 20
/// //   - Index scan for age == 25
/// //   - Index scan for age == 30
/// ```
public struct TypedInJoinPlan<Record: Sendable>: TypedQueryPlan {
    public let fieldName: String
    public let values: [any TupleElement]
    public let indexName: String
    public let indexSubspaceTupleKey: any TupleElement
    public let primaryKeyLength: Int
    public let recordName: String

    public init(
        fieldName: String,
        values: [any TupleElement],
        indexName: String,
        indexSubspaceTupleKey: any TupleElement,
        primaryKeyLength: Int,
        recordName: String
    ) {
        self.fieldName = fieldName
        self.values = values
        self.indexName = indexName
        self.indexSubspaceTupleKey = indexSubspaceTupleKey
        self.primaryKeyLength = primaryKeyLength
        self.recordName = recordName
    }

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Get index and record subspaces
        let indexSubspace = subspace
            .subspace("I")
            .subspace(indexSubspaceTupleKey)

        // IMPORTANT: Use same layout as TypedIndexScanPlan and TypedFullScanPlan
        // Record subspace does NOT include recordName
        let recordSubspace = subspace
            .subspace("R")

        let transaction = context.getTransaction()

        // Create a throwing stream that unions all index scans
        let stream = AsyncThrowingStream<Record, Error> { continuation in
            Task {
                do {
                    // Use Set<Data> for stable, unique deduplication
                    // Data is explicitly Hashable and optimized for byte operations
                    // String representation of Tuple is not guaranteed to be stable
                    var seenKeys = Set<Data>()

                    // Execute index scan for each value
                    for value in values {
                        // Create range for this specific value
                        // We need to scan all entries where the first indexed field equals this value
                        let beginKey = indexSubspace.pack(Tuple(value))
                        // End key: same prefix but with 0xFF to get all entries with this value
                        let endKey = beginKey + [0xFF]

                        let sequence = transaction.getRange(
                            begin: beginKey,
                            end: endKey,
                            snapshot: snapshot
                        )

                        for try await (indexKey, _) in sequence {
                            // Extract primary key from index key
                            // Use indexSubspace.unpack() to properly strip prefixes
                            let indexTuple = try indexSubspace.unpack(indexKey)
                            guard indexTuple.count >= primaryKeyLength else {
                                continue
                            }

                            // Convert Tuple to array so we can use suffix
                            let indexElements = TupleHelpers.toArray(indexTuple)
                            let primaryKeyElements = Array(indexElements.suffix(primaryKeyLength))
                            let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

                            // Fetch the actual record
                            let recordKey = recordSubspace.pack(primaryKeyTuple)

                            // Deduplicate by primary key (using Data for stable hashing)
                            // Convert FDB.Bytes ([UInt8]) to Data for Set membership
                            let recordKeyData = Data(recordKey)
                            if seenKeys.contains(recordKeyData) {
                                continue
                            }
                            seenKeys.insert(recordKeyData)
                            guard let recordBytes = try await transaction.getValue(for: recordKey, snapshot: snapshot) else {
                                continue
                            }

                            let record = try recordAccess.deserialize(recordBytes)
                            continuation.yield(record)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return AnyTypedRecordCursor(ArrayCursor(sequence: stream))
    }
}
