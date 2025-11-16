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
    public let recordName: String

    /// Range window for pre-filtering (Phase 1: Range Pre-filtering)
    /// When set, narrows the scan range to the intersection window
    public let window: Range<Date>?

    public init(
        indexName: String,
        indexSubspaceTupleKey: any TupleElement,
        beginValues: [any TupleElement],
        endValues: [any TupleElement],
        filter: (any TypedQueryComponent<Record>)?,
        primaryKeyLength: Int,
        recordName: String,
        window: Range<Date>? = nil
    ) {
        self.indexName = indexName
        self.indexSubspaceTupleKey = indexSubspaceTupleKey
        self.beginValues = beginValues
        self.endValues = endValues
        self.filter = filter
        self.primaryKeyLength = primaryKeyLength
        self.recordName = recordName
        self.window = window
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

        // Apply window bounds if specified (Phase 1: Range Pre-filtering)
        var effectiveBeginValues = beginValues
        var effectiveEndValues = endValues

        if let window = window {
            // Window narrows the scan range to the intersection window
            // Apply window bounds to the first field (assumes Range index has Date as first field)
            effectiveBeginValues = applyWindowToBeginValues(
                beginValues: beginValues,
                window: window
            )
            effectiveEndValues = applyWindowToEndValues(
                endValues: endValues,
                window: window
            )
        }

        // Build index key range
        let beginTuple = TupleHelpers.toTuple(effectiveBeginValues)
        let endTuple = TupleHelpers.toTuple(effectiveEndValues)

        // CRITICAL FIX: Pack the tuple directly without nesting
        // Index keys are stored as: <indexSubspace><indexValue><primaryKey>
        // Example: ...simple_category\x00 + \x02A\x00 + \x15\x01
        //
        // For equality queries (beginValues == endValues), we need:
        //   beginKey = <prefix><tuple>     (inclusive)
        //   endKey   = <prefix><tuple>\xFF (exclusive to include all primary keys)
        // This ensures all index entries with matching index values are included
        //
        // For range queries (beginValues != endValues), we handle:
        //   lessThan/lessThanOrEquals: beginValues empty, endValues has value
        //   greaterThan/greaterThanOrEquals: beginValues has value, endValues empty
        //   Between: both have values
        //
        // For open-ended ranges (empty array), use subspace boundaries:
        //   Empty beginValues → use indexSubspace.prefix (start of subspace)
        //   Empty endValues → use strinc(prefix) (end of subspace)
        //
        // WARNING: Do NOT use indexSubspace.subspace(tuple) as it creates nested tuples
        // with the \x05 marker, which won't match the flat encoding used by IndexManager
        let beginKey: FDB.Bytes
        if effectiveBeginValues.isEmpty {
            // Open lower bound: start from beginning of index
            let (rangeBegin, _) = indexSubspace.range()
            beginKey = rangeBegin
        } else {
            beginKey = indexSubspace.pack(beginTuple)
        }

        var endKey: FDB.Bytes
        if effectiveEndValues.isEmpty {
            // Open upper bound: use range end (strinc of prefix)
            let (_, rangeEnd) = indexSubspace.range()
            endKey = rangeEnd
        } else {
            endKey = indexSubspace.pack(endTuple)

            // Only append 0xFF for equality queries (beginValues == endValues)
            // For range queries, the endKey is the exact boundary (exclusive)
            //
            // IMPORTANT: Compare packed bytes to ensure exact equality including types
            // (String(describing:) comparison would incorrectly treat Int64(100) == Double(100))
            let isEqualityQuery = beginKey == endKey

            if isEqualityQuery {
                endKey.append(0xFF)  // Append successor byte for equality queries
            }
        }

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterOrEqual(endKey),  // Changed from .firstGreaterThan
            snapshot: snapshot
        )

        // For index scans, we need to fetch the actual records
        let recordSubspace = subspace.subspace("R")

        let cursor = IndexScanTypedCursor(
            indexSequence: sequence,
            indexSubspace: indexSubspace,
            recordSubspace: recordSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            filter: filter,
            primaryKeyLength: primaryKeyLength,
            recordName: recordName,
            snapshot: snapshot
        )

        return AnyTypedRecordCursor(cursor)
    }

    // MARK: - Range Window Application Helpers

    /// Apply window to begin values for range pre-filtering
    ///
    /// Takes the maximum of the original begin bound and the window's lowerBound
    /// to ensure we don't scan records outside the intersection window.
    ///
    /// **SAFETY**: This function is only called when window is non-nil, which means
    /// the filter passed isRangeCompatibleFilter() check in generateIntersectionPlan().
    /// Therefore, the field is guaranteed to be Date-based, and inserting Date bounds is safe.
    ///
    /// - Parameters:
    ///   - beginValues: Original begin values from the query
    ///   - window: Intersection window from multiple Range filters
    /// - Returns: Narrowed begin values
    private func applyWindowToBeginValues(
        beginValues: [any TupleElement],
        window: Range<Date>
    ) -> [any TupleElement] {
        // If beginValues is empty (open lower bound), use window's lowerBound
        // SAFETY: window is only set for Range-compatible filters (Date fields)
        if beginValues.isEmpty {
            return [window.lowerBound]
        }

        // If beginValues has a Date value, take the max of (original, window.lowerBound)
        guard let firstValue = beginValues.first else {
            return [window.lowerBound]
        }

        // Extract Date from the first value
        let originalDate: Date
        if let date = firstValue as? Date {
            originalDate = date
        } else if let double = firstValue as? Double {
            // Handle case where Date might be encoded as Double
            originalDate = Date(timeIntervalSince1970: double)
        } else {
            // If first value is not a Date, keep original beginValues
            // (This handles non-Range indexes that might have window set incorrectly)
            return beginValues
        }

        // Take the maximum (later date) to narrow the range
        let effectiveBegin = max(originalDate, window.lowerBound)

        // Reconstruct beginValues with the narrowed bound
        var result = beginValues
        result[0] = effectiveBegin
        return result
    }

    /// Apply window to end values for range pre-filtering
    ///
    /// Takes the minimum of the original end bound and the window's upperBound
    /// to ensure we don't scan records outside the intersection window.
    ///
    /// **SAFETY**: This function is only called when window is non-nil, which means
    /// the filter passed isRangeCompatibleFilter() check in generateIntersectionPlan().
    /// Therefore, the field is guaranteed to be Date-based, and inserting Date bounds is safe.
    ///
    /// - Parameters:
    ///   - endValues: Original end values from the query
    ///   - window: Intersection window from multiple Range filters
    /// - Returns: Narrowed end values
    private func applyWindowToEndValues(
        endValues: [any TupleElement],
        window: Range<Date>
    ) -> [any TupleElement] {
        // If endValues is empty (open upper bound), use window's upperBound
        // SAFETY: window is only set for Range-compatible filters (Date fields)
        if endValues.isEmpty {
            return [window.upperBound]
        }

        // If endValues has a Date value, take the min of (original, window.upperBound)
        guard let firstValue = endValues.first else {
            return [window.upperBound]
        }

        // Extract Date from the first value
        let originalDate: Date
        if let date = firstValue as? Date {
            originalDate = date
        } else if let double = firstValue as? Double {
            // Handle case where Date might be encoded as Double
            originalDate = Date(timeIntervalSince1970: double)
        } else {
            // If first value is not a Date, keep original endValues
            return endValues
        }

        // Take the minimum (earlier date) to narrow the range
        let effectiveEnd = min(originalDate, window.upperBound)

        // Reconstruct endValues with the narrowed bound
        var result = endValues
        result[0] = effectiveEnd
        return result
    }
}

// MARK: - Covering Index Scan Plan

/// Covering index scan plan (reconstructs records without fetching)
///
/// **Performance**:
/// - 2-10x faster than regular index scan
/// - Eliminates getValue() call per result
/// - Network I/O reduction: ~50%
///
/// **Usage**:
/// Query planner automatically selects this plan when:
/// 1. Index has coveringFields
/// 2. All required fields are covered (indexed + covering + primary key)
/// 3. RecordAccess supports reconstruction
///
public struct TypedCoveringIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    public let index: Index
    public let indexSubspaceTupleKey: any TupleElement
    public let beginValues: [any TupleElement]
    public let endValues: [any TupleElement]
    public let filter: (any TypedQueryComponent<Record>)?
    public let primaryKeyExpression: KeyExpression

    /// Range window for pre-filtering (Phase 1: Range Pre-filtering)
    /// When set, narrows the scan range to the intersection window
    public let window: Range<Date>?

    public init(
        index: Index,
        indexSubspaceTupleKey: any TupleElement,
        beginValues: [any TupleElement],
        endValues: [any TupleElement],
        filter: (any TypedQueryComponent<Record>)?,
        primaryKeyExpression: KeyExpression,
        window: Range<Date>? = nil
    ) {
        self.index = index
        self.indexSubspaceTupleKey = indexSubspaceTupleKey
        self.beginValues = beginValues
        self.endValues = endValues
        self.filter = filter
        self.primaryKeyExpression = primaryKeyExpression
        self.window = window
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

        // Apply window bounds if specified (Phase 1: Range Pre-filtering)
        var effectiveBeginValues = beginValues
        var effectiveEndValues = endValues

        if let window = window {
            // Window narrows the scan range to the intersection window
            effectiveBeginValues = applyWindowToBeginValues(
                beginValues: beginValues,
                window: window
            )
            effectiveEndValues = applyWindowToEndValues(
                endValues: endValues,
                window: window
            )
        }

        // Build index key range (same logic as TypedIndexScanPlan)
        let beginTuple = TupleHelpers.toTuple(effectiveBeginValues)
        let endTuple = TupleHelpers.toTuple(effectiveEndValues)

        let beginKey: FDB.Bytes
        if effectiveBeginValues.isEmpty {
            let (rangeBegin, _) = indexSubspace.range()
            beginKey = rangeBegin
        } else {
            beginKey = indexSubspace.pack(beginTuple)
        }

        var endKey: FDB.Bytes
        if effectiveEndValues.isEmpty {
            let (_, rangeEnd) = indexSubspace.range()
            endKey = rangeEnd
        } else {
            endKey = indexSubspace.pack(endTuple)

            let isEqualityQuery = beginKey == endKey
            if isEqualityQuery {
                endKey.append(0xFF)
            }
        }

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: snapshot
        )

        // Use CoveringIndexScanTypedCursor (no getValue() calls)
        let cursor = CoveringIndexScanTypedCursor(
            indexSequence: sequence,
            indexSubspace: indexSubspace,
            recordAccess: recordAccess,
            transaction: transaction,
            filter: filter,
            index: index,
            primaryKeyExpression: primaryKeyExpression,
            snapshot: snapshot
        )

        return AnyTypedRecordCursor(cursor)
    }

    // MARK: - Range Window Application Helpers

    /// Apply window to begin values for range pre-filtering
    ///
    /// Takes the maximum of the original begin bound and the window's lowerBound
    /// to ensure we don't scan records outside the intersection window.
    ///
    /// **SAFETY**: This function is only called when window is non-nil, which means
    /// the filter passed isRangeCompatibleFilter() check in generateIntersectionPlan().
    /// Therefore, the field is guaranteed to be Date-based, and inserting Date bounds is safe.
    ///
    /// - Parameters:
    ///   - beginValues: Original begin values from the query
    ///   - window: Intersection window from multiple Range filters
    /// - Returns: Narrowed begin values
    private func applyWindowToBeginValues(
        beginValues: [any TupleElement],
        window: Range<Date>
    ) -> [any TupleElement] {
        // If beginValues is empty (open lower bound), use window's lowerBound
        // SAFETY: window is only set for Range-compatible filters (Date fields)
        if beginValues.isEmpty {
            return [window.lowerBound]
        }

        // If beginValues has a Date value, take the max of (original, window.lowerBound)
        guard let firstValue = beginValues.first else {
            return [window.lowerBound]
        }

        // Extract Date from the first value
        let originalDate: Date
        if let date = firstValue as? Date {
            originalDate = date
        } else if let double = firstValue as? Double {
            // Handle case where Date might be encoded as Double
            originalDate = Date(timeIntervalSince1970: double)
        } else {
            // If first value is not a Date, keep original beginValues
            // (This handles non-Range indexes that might have window set incorrectly)
            return beginValues
        }

        // Take the maximum (later date) to narrow the range
        let effectiveBegin = max(originalDate, window.lowerBound)

        // Reconstruct beginValues with the narrowed bound
        var result = beginValues
        result[0] = effectiveBegin
        return result
    }

    /// Apply window to end values for range pre-filtering
    ///
    /// Takes the minimum of the original end bound and the window's upperBound
    /// to ensure we don't scan records outside the intersection window.
    ///
    /// **SAFETY**: This function is only called when window is non-nil, which means
    /// the filter passed isRangeCompatibleFilter() check in generateIntersectionPlan().
    /// Therefore, the field is guaranteed to be Date-based, and inserting Date bounds is safe.
    ///
    /// - Parameters:
    ///   - endValues: Original end values from the query
    ///   - window: Intersection window from multiple Range filters
    /// - Returns: Narrowed end values
    private func applyWindowToEndValues(
        endValues: [any TupleElement],
        window: Range<Date>
    ) -> [any TupleElement] {
        // If endValues is empty (open upper bound), use window's upperBound
        // SAFETY: window is only set for Range-compatible filters (Date fields)
        if endValues.isEmpty {
            return [window.upperBound]
        }

        // If endValues has a Date value, take the min of (original, window.upperBound)
        guard let firstValue = endValues.first else {
            return [window.upperBound]
        }

        // Extract Date from the first value
        let originalDate: Date
        if let date = firstValue as? Date {
            originalDate = date
        } else if let double = firstValue as? Double {
            // Handle case where Date might be encoded as Double
            originalDate = Date(timeIntervalSince1970: double)
        } else {
            // If first value is not a Date, keep original endValues
            return endValues
        }

        // Take the minimum (earlier date) to narrow the range
        let effectiveEnd = min(originalDate, window.upperBound)

        // Reconstruct endValues with the narrowed bound
        var result = endValues
        result[0] = effectiveEnd
        return result
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

// MARK: - Empty Plan

/// Empty plan that returns no records
///
/// Used for optimization when query conditions guarantee zero results.
/// For example, when Range intersection window is empty.
public struct TypedEmptyPlan<Record: Sendable>: TypedQueryPlan {
    public init() {}

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Return empty async throwing sequence
        let emptyStream = AsyncThrowingStream<Record, Error> { continuation in
            continuation.finish()
        }
        return AnyTypedRecordCursor(ArrayCursor(sequence: emptyStream))
    }
}
