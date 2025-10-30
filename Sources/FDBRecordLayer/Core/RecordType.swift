import Foundation

/// A record type definition
///
/// Represents a single type of record that can be stored in the record store.
/// Each record type has a name, primary key expression, and optional secondary indexes.
public struct RecordType: Sendable {
    // MARK: - Properties

    /// Unique name of the record type
    public let name: String

    /// Primary key expression
    public let primaryKey: KeyExpression

    /// Names of indexes specific to this record type
    public let secondaryIndexes: [String]

    // MARK: - Initialization

    public init(
        name: String,
        primaryKey: KeyExpression,
        secondaryIndexes: [String] = []
    ) {
        self.name = name
        self.primaryKey = primaryKey
        self.secondaryIndexes = secondaryIndexes
    }
}

// MARK: - Equatable

extension RecordType: Equatable {
    public static func == (lhs: RecordType, rhs: RecordType) -> Bool {
        return lhs.name == rhs.name
    }
}

// MARK: - Hashable

extension RecordType: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
