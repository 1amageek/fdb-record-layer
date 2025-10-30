import Foundation
import FoundationDB

/// Protocol for query execution plans
///
/// QueryPlans define how a query will be executed against the record store.
public protocol QueryPlan: Sendable {
    /// Execute the plan
    /// - Parameters:
    ///   - subspace: The record store subspace
    ///   - serializer: The record serializer
    ///   - context: The transaction context
    /// - Returns: An async sequence of records
    func execute(
        subspace: Subspace,
        serializer: any RecordSerializer<[String: Any]>,
        context: RecordContext
    ) async throws -> any RecordCursor
}

// MARK: - Full Scan Plan

/// Full table scan plan
public struct FullScanPlan: QueryPlan {
    public let recordTypes: Set<String>
    public let filter: (any QueryComponent)?

    public init(recordTypes: Set<String>, filter: (any QueryComponent)?) {
        self.recordTypes = recordTypes
        self.filter = filter
    }

    public func execute(
        subspace: Subspace,
        serializer: any RecordSerializer<[String: Any]>,
        context: RecordContext
    ) async throws -> any RecordCursor {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let transaction = context.getTransaction()

        let (beginKey, endKey) = recordSubspace.range()

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterThan(endKey),
            snapshot: true
        )

        let cursor = BasicRecordCursor(
            sequence: sequence,
            serializer: serializer,
            recordTypes: recordTypes,
            filter: filter
        )

        return cursor
    }
}

// MARK: - Index Scan Plan

/// Index scan plan
public struct IndexScanPlan: QueryPlan {
    public let index: Index
    public let beginKey: FDB.Bytes
    public let endKey: FDB.Bytes
    public let filter: (any QueryComponent)?

    public init(
        index: Index,
        beginKey: FDB.Bytes,
        endKey: FDB.Bytes,
        filter: (any QueryComponent)?
    ) {
        self.index = index
        self.beginKey = beginKey
        self.endKey = endKey
        self.filter = filter
    }

    public func execute(
        subspace: Subspace,
        serializer: any RecordSerializer<[String: Any]>,
        context: RecordContext
    ) async throws -> any RecordCursor {
        let transaction = context.getTransaction()

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterThan(endKey),
            snapshot: true
        )

        // For index scans, we need to fetch the actual records
        // This is a simplified implementation
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        let cursor = IndexScanCursor(
            indexSequence: sequence,
            recordSubspace: recordSubspace,
            serializer: serializer,
            transaction: transaction,
            filter: filter
        )

        return cursor
    }
}

// MARK: - Limit Plan

/// Limit plan (restricts number of results)
public struct LimitPlan: QueryPlan {
    public let child: any QueryPlan
    public let limit: Int

    public init(child: any QueryPlan, limit: Int) {
        self.child = child
        self.limit = limit
    }

    public func execute(
        subspace: Subspace,
        serializer: any RecordSerializer<[String: Any]>,
        context: RecordContext
    ) async throws -> any RecordCursor {
        let childCursor = try await child.execute(
            subspace: subspace,
            serializer: serializer,
            context: context
        )

        return LimitedCursor(source: childCursor, limit: limit)
    }
}
