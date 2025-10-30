import Foundation
import FoundationDB

/// A type-safe record type definition
///
/// TypedRecordType works with a specific record type and provides type-safe
/// field access through FieldAccessor.
public struct TypedRecordType<Record: Sendable>: Sendable {
    // MARK: - Properties

    /// Unique name of the record type
    public let name: String

    /// Primary key expression
    public let primaryKey: any TypedKeyExpression<Record>

    /// Names of indexes specific to this record type
    public let secondaryIndexes: [String]

    // MARK: - Initialization

    public init(
        name: String,
        primaryKey: any TypedKeyExpression<Record>,
        secondaryIndexes: [String] = []
    ) {
        self.name = name
        self.primaryKey = primaryKey
        self.secondaryIndexes = secondaryIndexes
    }

    // MARK: - Public Methods

    /// Extract primary key from a record
    /// - Parameters:
    ///   - record: The record
    ///   - accessor: The field accessor
    /// - Returns: Primary key as tuple
    public func extractPrimaryKey<A: FieldAccessor>(
        from record: Record,
        accessor: A
    ) -> Tuple where A.Record == Record {
        let elements = primaryKey.evaluate(record: record, accessor: accessor)
        return TupleHelpers.toTuple(elements)
    }
}

// MARK: - Equatable

extension TypedRecordType: Equatable {
    public static func == (lhs: TypedRecordType<Record>, rhs: TypedRecordType<Record>) -> Bool {
        return lhs.name == rhs.name
    }
}

// MARK: - Hashable

extension TypedRecordType: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
