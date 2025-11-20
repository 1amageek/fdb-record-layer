import Foundation
import FoundationDB

/// Query plan that sorts results from a child plan
///
/// TypedSortPlan wraps another query plan and sorts its results in memory.
/// This is used when no index can satisfy the sort order.
///
/// **Usage:**
/// ```swift
/// let childPlan = TypedFullScanPlan(...)
/// let sortPlan = TypedSortPlan(
///     childPlan: childPlan,
///     sortFields: [SortField(fieldName: "name", ascending: true)]
/// )
/// ```
///
/// **Performance:**
/// - Requires reading all results into memory
/// - Time complexity: O(n log n) where n is the number of results
/// - Memory complexity: O(n)
/// - Should be avoided when an index can provide the sort order
internal struct TypedSortPlan<Record: Sendable>: TypedQueryPlan {
    // MARK: - Properties

    /// The child plan producing unsorted results
    internal let childPlan: any TypedQueryPlan<Record>

    /// Fields to sort by (in order)
    internal let sortFields: [SortField]

    // MARK: - Types

    /// Specification for a sort field
    public struct SortField: Sendable, Hashable {
        /// Field name to sort by
        public let fieldName: String

        /// Whether to sort in ascending order (true) or descending (false)
        public let ascending: Bool

        public init(fieldName: String, ascending: Bool = true) {
            self.fieldName = fieldName
            self.ascending = ascending
        }
    }

    // MARK: - Initialization

    internal init(
        childPlan: any TypedQueryPlan<Record>,
        sortFields: [SortField]
    ) {
        self.childPlan = childPlan
        self.sortFields = sortFields
    }

    // MARK: - TypedQueryPlan

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: TransactionContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Execute child plan
        let childCursor = try await childPlan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: snapshot
        )

        // Collect all results into memory
        var records: [Record] = []
        for try await record in childCursor {
            records.append(record)
        }

        // Sort records
        try sortRecords(&records, recordAccess: recordAccess)

        // Return cursor over sorted results
        let arrayCursor = TypedArrayCursor(records: records)
        return AnyTypedRecordCursor(arrayCursor)
    }

    // MARK: - Private Helpers

    /// Sort records in place according to sort fields
    private func sortRecords(
        _ records: inout [Record],
        recordAccess: any RecordAccess<Record>
    ) throws {
        records.sort { lhs, rhs in
            // Compare by each sort field in order
            for sortField in sortFields {
                // Extract field values
                guard let lhsValues = try? recordAccess.extractField(from: lhs, fieldName: sortField.fieldName),
                      let lhsValue = lhsValues.first,
                      let rhsValues = try? recordAccess.extractField(from: rhs, fieldName: sortField.fieldName),
                      let rhsValue = rhsValues.first else {
                    continue
                }

                // Compare values
                let compareResult = compareValues(lhsValue, rhsValue)

                if compareResult != .orderedSame {
                    // Apply ascending/descending
                    if sortField.ascending {
                        return compareResult == .orderedAscending
                    } else {
                        return compareResult == .orderedDescending
                    }
                }

                // Values are equal, continue to next sort field
            }

            // All sort fields are equal: preserve original order
            return false
        }
    }

    /// Compare two tuple elements
    private func compareValues(
        _ lhs: any TupleElement,
        _ rhs: any TupleElement
    ) -> ComparisonResult {
        // String comparison
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr.compare(rhsStr)
        }

        // Int64 comparison
        if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
            if lhsInt < rhsInt { return .orderedAscending }
            if lhsInt > rhsInt { return .orderedDescending }
            return .orderedSame
        }

        // Int comparison
        if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int {
            if lhsInt < rhsInt { return .orderedAscending }
            if lhsInt > rhsInt { return .orderedDescending }
            return .orderedSame
        }

        // Double comparison
        if let lhsDouble = lhs as? Double, let rhsDouble = rhs as? Double {
            if lhsDouble < rhsDouble { return .orderedAscending }
            if lhsDouble > rhsDouble { return .orderedDescending }
            return .orderedSame
        }

        // Float comparison
        if let lhsFloat = lhs as? Float, let rhsFloat = rhs as? Float {
            if lhsFloat < rhsFloat { return .orderedAscending }
            if lhsFloat > rhsFloat { return .orderedDescending }
            return .orderedSame
        }

        // Bool comparison (false < true)
        if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
            if !lhsBool && rhsBool { return .orderedAscending }
            if lhsBool && !rhsBool { return .orderedDescending }
            return .orderedSame
        }

        // Mixed types or unsupported: treat as equal
        return .orderedSame
    }
}

// MARK: - TypedArrayCursor

/// Cursor that iterates over an in-memory array of records
struct TypedArrayCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let records: [Record]

    init(records: [Record]) {
        self.records = records
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let records: [Record]
        private var currentIndex: Int = 0

        init(records: [Record]) {
            self.records = records
        }

        public mutating func next() async throws -> Record? {
            guard currentIndex < records.count else {
                return nil
            }

            let record = records[currentIndex]
            currentIndex += 1
            return record
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(records: records)
    }
}
