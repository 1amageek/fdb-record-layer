import Foundation

/// Type-safe index definition
///
/// TypedIndex works with a specific record type for type-safe field access.
public struct TypedIndex<Record: Sendable>: Sendable {
    // MARK: - Properties

    /// Unique index name
    public let name: String

    /// Index type
    public let type: IndexType

    /// Root expression defining indexed fields
    public let rootExpression: any TypedKeyExpression<Record>

    /// Subspace key (defaults to index name)
    public let subspaceKey: String

    /// Index options
    public let options: IndexOptions

    // MARK: - Computed Properties

    /// Get the subspace tuple key (used for encoding)
    public var subspaceTupleKey: any TupleElement {
        return subspaceKey
    }

    // MARK: - Initialization

    public init(
        name: String,
        type: IndexType = .value,
        rootExpression: any TypedKeyExpression<Record>,
        subspaceKey: String? = nil,
        options: IndexOptions = IndexOptions()
    ) {
        self.name = name
        self.type = type
        self.rootExpression = rootExpression
        self.subspaceKey = subspaceKey ?? name
        self.options = options
    }
}

// MARK: - Equatable

extension TypedIndex: Equatable {
    public static func == (lhs: TypedIndex<Record>, rhs: TypedIndex<Record>) -> Bool {
        return lhs.name == rhs.name
    }
}

// MARK: - Hashable

extension TypedIndex: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
