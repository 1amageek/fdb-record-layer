import Foundation

/// Index definition
///
/// Defines a secondary index on record fields. Indexes are maintained automatically
/// when records are inserted, updated, or deleted.
public struct Index: Sendable {
    // MARK: - Properties

    /// Unique index name
    public let name: String

    /// Index type
    public let type: IndexType

    /// Root expression defining indexed fields
    public let rootExpression: KeyExpression

    /// Subspace key (defaults to index name)
    public let subspaceKey: String

    /// Record types this index applies to (nil = universal, applies to all types)
    public let recordTypes: Set<String>?

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
        rootExpression: KeyExpression,
        subspaceKey: String? = nil,
        recordTypes: Set<String>? = nil,
        options: IndexOptions = IndexOptions()
    ) {
        self.name = name
        self.type = type
        self.rootExpression = rootExpression
        self.subspaceKey = subspaceKey ?? name
        self.recordTypes = recordTypes
        self.options = options
    }
}

// MARK: - Index Options

/// Options for index configuration
public struct IndexOptions: Sendable {
    /// Whether this index enforces uniqueness
    public var unique: Bool

    /// Whether to replace on duplicate (only valid if unique = true)
    public var replaceOnDuplicate: Bool

    /// Whether this index can be used in equality predicates
    public var allowedInEquality: Bool

    /// Base index name (for permuted indexes)
    public var baseIndexName: String?

    /// Permutation indices (for permuted indexes)
    public var permutationIndices: [Int]?

    /// Rank order (for rank indexes) - "asc" or "desc"
    public var rankOrderString: String?

    /// Bucket size (for rank indexes)
    public var bucketSize: Int?

    /// Tie-breaker field (for rank indexes)
    public var tieBreaker: String?

    public init(
        unique: Bool = false,
        replaceOnDuplicate: Bool = false,
        allowedInEquality: Bool = true,
        baseIndexName: String? = nil,
        permutationIndices: [Int]? = nil,
        rankOrderString: String? = nil,
        bucketSize: Int? = nil,
        tieBreaker: String? = nil
    ) {
        self.unique = unique
        self.replaceOnDuplicate = replaceOnDuplicate
        self.allowedInEquality = allowedInEquality
        self.baseIndexName = baseIndexName
        self.permutationIndices = permutationIndices
        self.rankOrderString = rankOrderString
        self.bucketSize = bucketSize
        self.tieBreaker = tieBreaker
    }
}

// MARK: - Factory Methods

extension Index {
    /// Creates a value index (standard B-tree index)
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - on: Key expression defining indexed fields
    ///   - unique: Whether to enforce uniqueness (default: false)
    ///   - recordTypes: Optional set of record types this index applies to
    /// - Returns: Value index instance
    public static func value(
        named name: String,
        on expression: KeyExpression,
        unique: Bool = false,
        recordTypes: Set<String>? = nil
    ) -> Index {
        Index(
            name: name,
            type: .value,
            rootExpression: expression,
            recordTypes: recordTypes,
            options: IndexOptions(unique: unique)
        )
    }

    /// Creates a count index (aggregation index for counting)
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - groupBy: Key expression for grouping
    ///   - recordTypes: Optional set of record types this index applies to
    /// - Returns: Count index instance
    public static func count(
        named name: String,
        groupBy expression: KeyExpression,
        recordTypes: Set<String>? = nil
    ) -> Index {
        Index(
            name: name,
            type: .count,
            rootExpression: expression,
            recordTypes: recordTypes
        )
    }

    /// Creates a sum index (aggregation index for summing values)
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - of: Key expression for the value to sum
    ///   - groupBy: Key expression for grouping
    ///   - recordTypes: Optional set of record types this index applies to
    /// - Returns: Sum index instance
    public static func sum(
        named name: String,
        of valueExpression: KeyExpression,
        groupBy groupExpression: KeyExpression,
        recordTypes: Set<String>? = nil
    ) -> Index {
        // For sum indexes, we concatenate group and value expressions
        let rootExpression = ConcatenateKeyExpression(children: [
            groupExpression,
            valueExpression
        ])

        return Index(
            name: name,
            type: .sum,
            rootExpression: rootExpression,
            recordTypes: recordTypes
        )
    }

    /// Creates a rank index (for leaderboards and rankings)
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - on: Key expression defining ranked field
    ///   - order: Rank order ("asc" for ascending, "desc" for descending)
    ///   - bucketSize: Optional bucket size for optimization
    ///   - recordTypes: Optional set of record types this index applies to
    /// - Returns: Rank index instance
    public static func rank(
        named name: String,
        on expression: KeyExpression,
        order: String = "asc",
        bucketSize: Int? = nil,
        recordTypes: Set<String>? = nil
    ) -> Index {
        Index(
            name: name,
            type: .rank,
            rootExpression: expression,
            recordTypes: recordTypes,
            options: IndexOptions(
                rankOrderString: order,
                bucketSize: bucketSize
            )
        )
    }
}

// MARK: - Equatable

extension Index: Equatable {
    public static func == (lhs: Index, rhs: Index) -> Bool {
        return lhs.name == rhs.name
    }
}

// MARK: - Hashable

extension Index: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
