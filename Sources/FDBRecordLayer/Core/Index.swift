import Foundation

// MARK: - Index Scope

/// Defines the scope of an index relative to partitions
///
/// When using `#Directory` with `layer: .partition`, you can choose whether an index
/// should be partition-local or global across all partitions.
///
/// **Example**:
/// ```swift
/// @Recordable
/// struct Hotel {
///     #PrimaryKey<Hotel>([\.ownerID, \.hotelID])
///     #Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)
///
///     // Partition-local index (default)
///     #Index<Hotel>([\.name], name: "by_name", scope: .partition)
///
///     // Global index (cross-partition)
///     #Index<Hotel>([\.rating], type: .rank, name: "global_rating", scope: .global)
///
///     var ownerID: String
///     var hotelID: Int64
///     var name: String
///     var rating: Double
/// }
/// ```
///
/// **Key structures**:
/// ```
/// // Records: partition-local
/// [owner-A-prefix][records][Hotel][ownerID][hotelID]
/// [owner-B-prefix][records][Hotel][ownerID][hotelID]
///
/// // by_name index: partition-local (scope: .partition)
/// [owner-A-prefix][indexes][by_name][name][ownerID][hotelID]
/// [owner-B-prefix][indexes][by_name][name][ownerID][hotelID]
///
/// // global_rating index: cross-partition (scope: .global)
/// [root-subspace][global-indexes][global_rating][rating][ownerID][hotelID]
/// ```
///
/// **Important**: Global indexes with partitions MUST include partition key in primary key.
public enum IndexScope: String, Sendable {
    /// Index is local to each partition (default)
    ///
    /// The index is created within each partition's subspace.
    /// Queries are scoped to the current partition.
    case partition

    /// Index spans across all partitions globally
    ///
    /// The index is created in a shared global space outside any partition.
    /// Queries can access records from all partitions.
    ///
    /// **Requirements**:
    /// - Primary key MUST include partition key fields for global uniqueness
    /// - Example: `#PrimaryKey<T>([\.partitionKey, \.recordID])`
    case global
}

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

    /// Index scope (partition-local or global)
    public let scope: IndexScope

    /// Covering fields (stored in index value for record reconstruction)
    ///
    /// When nil or empty: Non-covering index (backward compatible)
    /// When non-empty: Covering index with these additional fields
    ///
    /// **Important**: coveringFields should NOT include:
    /// - Fields already in rootExpression (indexed fields)
    /// - Primary key fields (already in index key)
    ///
    /// **Example**:
    /// ```swift
    /// rootExpression: FieldKeyExpression("city")
    /// primaryKey: userID
    /// coveringFields: [FieldKeyExpression("name"), FieldKeyExpression("email")]
    ///
    /// Index key:   <indexSubspace><city><userID>
    /// Index value: Tuple(name, email)
    /// ```
    public let coveringFields: [KeyExpression]?

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
        options: IndexOptions = IndexOptions(),
        scope: IndexScope = .partition,
        coveringFields: [KeyExpression]? = nil
    ) {
        self.name = name
        self.type = type
        self.rootExpression = rootExpression
        self.subspaceKey = subspaceKey ?? name
        self.recordTypes = recordTypes
        self.options = options
        self.scope = scope
        self.coveringFields = coveringFields
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
    ///   - scope: Index scope (partition-local or global, default: .partition)
    ///   - recordTypes: Optional set of record types this index applies to
    /// - Returns: Value index instance
    public static func value(
        named name: String,
        on expression: KeyExpression,
        unique: Bool = false,
        scope: IndexScope = .partition,
        recordTypes: Set<String>? = nil
    ) -> Index {
        Index(
            name: name,
            type: .value,
            rootExpression: expression,
            recordTypes: recordTypes,
            options: IndexOptions(unique: unique),
            scope: scope
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

    /// Creates a covering index that includes additional fields in the index value
    ///
    /// Covering indexes store additional field values in the index itself, enabling
    /// query execution without fetching the actual record from storage. This can
    /// provide 2-10x performance improvement for queries that only need the covered fields.
    ///
    /// **Performance Impact**:
    /// - Query latency: 2-10x faster (no record fetch needed)
    /// - Network I/O: ~50% reduction
    /// - Storage: 2-5x larger index entries
    ///
    /// **Example**:
    /// ```swift
    /// let coveringIndex = Index.covering(
    ///     named: "user_by_city_covering",
    ///     on: FieldKeyExpression(fieldName: "city"),  // Indexed field
    ///     covering: [
    ///         FieldKeyExpression(fieldName: "name"),  // Additional field 1
    ///         FieldKeyExpression(fieldName: "email")  // Additional field 2
    ///     ],
    ///     recordTypes: ["User"]
    /// )
    /// ```
    ///
    /// **Index structure**:
    /// ```
    /// Key:   <indexSubspace><city><userID>
    /// Value: Tuple(name, email)
    /// ```
    ///
    /// **When to use**:
    /// - Query frequency > 100 QPS
    /// - Record size > 500 bytes
    /// - Covering field size < 1 KB
    /// - See covering-index-design.md for decision framework
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - rootExpression: Indexed fields (used for key ordering and range scans)
    ///   - coveringFields: Additional fields stored in index value (for record reconstruction)
    ///   - recordTypes: Record types this index applies to
    ///   - options: Index options (unique, etc.)
    /// - Returns: Index with covering fields
    public static func covering(
        named name: String,
        on rootExpression: KeyExpression,
        covering coveringFields: [KeyExpression],
        recordTypes: Set<String>? = nil,
        options: IndexOptions = IndexOptions()
    ) -> Index {
        return Index(
            name: name,
            type: .value,
            rootExpression: rootExpression,
            recordTypes: recordTypes,
            options: options,
            coveringFields: coveringFields
        )
    }

    /// Check if this index covers all required fields
    ///
    /// Determines whether the index contains all fields needed to answer a query
    /// without fetching the actual record. The query planner uses this to select
    /// covering index plans automatically.
    ///
    /// **Coverage includes**:
    /// - Fields in rootExpression (indexed fields in index key)
    /// - Fields in primaryKeyExpression (always in index key)
    /// - Fields in coveringFields (stored in index value)
    ///
    /// **Index key structure**: `<indexSubspace><rootExpression fields><primaryKey fields>`
    ///
    /// **Example**:
    /// ```swift
    /// let index = Index.covering(
    ///     named: "user_by_city_covering",
    ///     on: FieldKeyExpression(fieldName: "city"),
    ///     covering: [
    ///         FieldKeyExpression(fieldName: "name"),
    ///         FieldKeyExpression(fieldName: "email")
    ///     ]
    /// )
    ///
    /// let primaryKey = FieldKeyExpression(fieldName: "userID")
    ///
    /// // Query needs: city (indexed), name (covered), email (covered), userID (pk)
    /// let requiredFields: Set<String> = ["city", "name", "email", "userID"]
    /// let isCovered = index.covers(fields: requiredFields, primaryKey: primaryKey)  // true
    ///
    /// // Query needs: city, name, age (age NOT covered)
    /// let requiredFields2: Set<String> = ["city", "name", "age"]
    /// let isCovered2 = index.covers(fields: requiredFields2, primaryKey: primaryKey)  // false
    /// ```
    ///
    /// - Parameters:
    ///   - requiredFields: Field names needed by the query
    ///   - primaryKey: Primary key expression (provides fields always available in index key)
    /// - Returns: true if index contains all required fields
    public func covers(fields requiredFields: Set<String>, primaryKey: KeyExpression) -> Bool {
        var availableFields = Set<String>()

        // Extract field names from rootExpression (indexed fields in index key)
        availableFields.formUnion(rootExpression.fieldNames())

        // Extract field names from primaryKey (always in index key)
        availableFields.formUnion(primaryKey.fieldNames())

        // Extract field names from coveringFields (stored in index value)
        if let coveringFields = coveringFields {
            for expr in coveringFields {
                availableFields.formUnion(expr.fieldNames())
            }
        }

        // Check if all required fields are available
        return requiredFields.isSubset(of: availableFields)
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
