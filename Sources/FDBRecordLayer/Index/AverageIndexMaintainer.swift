import Foundation
import FoundationDB

// MARK: - Generic Average Index Maintainer

/// Generic maintainer for average aggregation indexes
///
/// This is the generic version that works with any record type
/// through RecordAccess instead of assuming dictionary-based records.
///
/// Average indexes maintain both sum and count grouped by specific fields,
/// enabling efficient average calculation (average = sum / count).
/// They use atomic operations for efficient concurrent updates.
///
/// **Usage:**
/// ```swift
/// let maintainer = GenericAverageIndexMaintainer(
///     index: averageIndex,
///     subspace: averageSubspace
/// )
/// ```
public struct GenericAverageIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
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
        // For average indexes, we need both grouping key and averaged value
        // The index expression should produce: [grouping_fields..., averaged_field]

        if let newRecord = newRecord {
            let values = try recordAccess.evaluate(
                record: newRecord,
                expression: index.rootExpression
            )
            if values.count >= 2 {
                // Last value is what we average, others are grouping
                let groupingValues = Array(values.dropLast())
                let avgValue = try extractNumericValue(values.last!)

                let groupingTuple = TupleHelpers.toTuple(groupingValues)
                let sumKey = subspace.pack(Tuple([groupingTuple, "sum"]))
                let countKey = subspace.pack(Tuple([groupingTuple, "count"]))

                // Add to sum and increment count
                let sumDeltaBytes = TupleHelpers.int64ToBytes(avgValue)
                transaction.atomicOp(key: sumKey, param: sumDeltaBytes, mutationType: .add)

                let countDeltaBytes = TupleHelpers.int64ToBytes(1)
                transaction.atomicOp(key: countKey, param: countDeltaBytes, mutationType: .add)
            }
        }

        if let oldRecord = oldRecord {
            let values = try recordAccess.evaluate(
                record: oldRecord,
                expression: index.rootExpression
            )
            if values.count >= 2 {
                let groupingValues = Array(values.dropLast())
                let avgValue = try extractNumericValue(values.last!)

                let groupingTuple = TupleHelpers.toTuple(groupingValues)
                let sumKey = subspace.pack(Tuple([groupingTuple, "sum"]))
                let countKey = subspace.pack(Tuple([groupingTuple, "count"]))

                // Subtract from sum and decrement count
                let sumDeltaBytes = TupleHelpers.int64ToBytes(-avgValue)
                transaction.atomicOp(key: sumKey, param: sumDeltaBytes, mutationType: .add)

                let countDeltaBytes = TupleHelpers.int64ToBytes(-1)
                transaction.atomicOp(key: countKey, param: countDeltaBytes, mutationType: .add)
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
            throw RecordLayerError.internalError("Average index requires at least 2 values")
        }

        let groupingValues = Array(values.dropLast())
        let avgValue = try extractNumericValue(values.last!)

        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let sumKey = subspace.pack(Tuple([groupingTuple, "sum"]))
        let countKey = subspace.pack(Tuple([groupingTuple, "count"]))

        // Add to sum and increment count
        let sumBytes = TupleHelpers.int64ToBytes(avgValue)
        transaction.atomicOp(key: sumKey, param: sumBytes, mutationType: .add)

        let countBytes = TupleHelpers.int64ToBytes(1)
        transaction.atomicOp(key: countKey, param: countBytes, mutationType: .add)
    }

    /// Get the average for a specific grouping
    /// - Parameters:
    ///   - groupingValues: The grouping key values
    ///   - transaction: The transaction to use
    /// - Returns: The average, or nil if no records
    public func getAverage(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> Double? {
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let sumKey = subspace.pack(Tuple([groupingTuple, "sum"]))
        let countKey = subspace.pack(Tuple([groupingTuple, "count"]))

        guard let sumBytes = try await transaction.getValue(for: sumKey),
              let countBytes = try await transaction.getValue(for: countKey) else {
            return nil
        }

        let sum = TupleHelpers.bytesToInt64(sumBytes)
        let count = TupleHelpers.bytesToInt64(countBytes)

        guard count > 0 else {
            return nil
        }

        return Double(sum) / Double(count)
    }

    /// Get both sum and count for a specific grouping
    /// - Parameters:
    ///   - groupingValues: The grouping key values
    ///   - transaction: The transaction to use
    /// - Returns: Tuple of (sum, count)
    public func getSumAndCount(
        groupingValues: [any TupleElement],
        transaction: any TransactionProtocol
    ) async throws -> (sum: Int64, count: Int64) {
        let groupingTuple = TupleHelpers.toTuple(groupingValues)
        let sumKey = subspace.pack(Tuple([groupingTuple, "sum"]))
        let countKey = subspace.pack(Tuple([groupingTuple, "count"]))

        let sumBytes = try await transaction.getValue(for: sumKey)
        let countBytes = try await transaction.getValue(for: countKey)

        let sum = sumBytes.map { TupleHelpers.bytesToInt64($0) } ?? 0
        let count = countBytes.map { TupleHelpers.bytesToInt64($0) } ?? 0

        return (sum, count)
    }

    // MARK: - Private Methods

    private func extractNumericValue(_ element: any TupleElement) throws -> Int64 {
        if let int64 = element as? Int64 {
            return int64
        } else if let int = element as? Int {
            return Int64(int)
        } else if let int32 = element as? Int32 {
            return Int64(int32)
        } else if let double = element as? Double {
            return Int64(double)
        } else if let float = element as? Float {
            return Int64(float)
        } else {
            throw RecordLayerError.internalError("Average index value must be numeric")
        }
    }
}
