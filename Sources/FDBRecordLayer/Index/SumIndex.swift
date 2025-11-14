import Foundation
import FoundationDB

// MARK: - Generic Sum Index Maintainer

/// Generic maintainer for sum aggregation indexes
///
/// This is the new generic version that works with any record type
/// through RecordAccess instead of assuming dictionary-based records.
///
/// Sum indexes maintain sums of numeric field values grouped by other fields.
/// They use atomic operations for efficient concurrent updates.
///
/// **Usage:**
/// ```swift
/// let maintainer = GenericSumIndexMaintainer(
///     index: sumIndex,
///     recordType: orderType,
///     subspace: sumSubspace
/// )
/// ```
public struct GenericSumIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
    public let index: Index
    public let subspace: Subspace

    public init(
        index: Index,
                subspace: Subspace
    ) {
        self.index = index
        self.subspace = subspace
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // For sum indexes, we need both grouping key and sum value
        // The index expression should produce: [grouping_fields..., sum_field]

        if let newRecord = newRecord {
            let values = try recordAccess.evaluate(
                record: newRecord,
                expression: index.rootExpression
            )
            if values.count >= 2 {
                // Last value is what we sum, others are grouping
                let groupingValues = Array(values.dropLast())
                let sumValue = try extractNumericValue(values.last!)

                let groupingTuple = TupleHelpers.toTuple(groupingValues)
                let sumKey = subspace.pack(groupingTuple)

                // Add to sum
                let deltaBytes = TupleHelpers.int64ToBytes(sumValue)
                transaction.atomicOp(key: sumKey, param: deltaBytes, mutationType: .add)
            }
        }

        if let oldRecord = oldRecord {
            let values = try recordAccess.evaluate(
                record: oldRecord,
                expression: index.rootExpression
            )
            if values.count >= 2 {
                let groupingValues = Array(values.dropLast())
                let sumValue = try extractNumericValue(values.last!)

                let groupingTuple = TupleHelpers.toTuple(groupingValues)
                let sumKey = subspace.pack(groupingTuple)

                // Subtract from sum
                let deltaBytes = TupleHelpers.int64ToBytes(-sumValue)
                transaction.atomicOp(key: sumKey, param: deltaBytes, mutationType: .add)
            }
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        let values = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        guard values.count >= 2 else {
            throw RecordLayerError.internalError("Sum index requires at least 2 values")
        }

        let groupingValues = Array(values.dropLast())
        let sumValue = try extractNumericValue(values.last!)

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let sumKey = subspace.pack(groupingTuple)

        // Add to sum
        let valueBytes = TupleHelpers.int64ToBytes(sumValue)
        transaction.atomicOp(key: sumKey, param: valueBytes, mutationType: .add)
    }

    /// Get the sum for a specific grouping
    /// - Parameters:
    ///   - groupingValues: The grouping key values
    ///   - transaction: The transaction to use
    /// - Returns: The sum
    public func getSum(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Int64 {
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let sumKey = subspace.pack(groupingTuple)

        guard let bytes = try await transaction.getValue(for: sumKey) else {
            return 0
        }

        return TupleHelpers.bytesToInt64(bytes)
    }

    // MARK: - Private Methods

    private func extractNumericValue(_ element: any TupleElement) throws -> Int64 {
        if let int64 = element as? Int64 {
            return int64
        } else if let int = element as? Int {
            return Int64(int)
        } else if let int32 = element as? Int32 {
            return Int64(int32)
        } else if element is Double || element is Float {
            throw RecordLayerError.invalidArgument(
                "SUM index does not support Double/Float fields. " +
                "Use Int64 for exact arithmetic (e.g., store monetary values in cents)."
            )
        } else {
            throw RecordLayerError.internalError(
                "Sum index value must be numeric integer type (Int64, Int, Int32), got: \(type(of: element))"
            )
        }
    }
}
