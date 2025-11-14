import Foundation

/// Index type for IndexDefinition
public enum IndexDefinitionType: Sendable {
    case value
    case rank
    case count
    case sum
    case min
    case max
    case vector(VectorIndexOptions)
    case spatial(SpatialIndexOptions)
    case version
}

/// Index scope for IndexDefinition
public enum IndexDefinitionScope: String, Sendable {
    case partition
    case global
}

/// Definition of an index created by #Index, #Unique, @Vector, or @Spatial macros
///
/// This type holds the metadata for indexes defined using macros.
/// The RecordMetadata will collect these definitions and register them.
public struct IndexDefinition: Sendable {
    /// The name of the index
    public let name: String

    /// The record type this index applies to
    public let recordType: String

    /// The fields included in this index
    public let fields: [String]

    /// Whether this index enforces uniqueness
    public let unique: Bool

    /// The type of index (.value, .vector, .spatial)
    public let indexType: IndexDefinitionType

    /// The scope of the index (.partition, .global)
    public let scope: IndexDefinitionScope

    /// Initialize an index definition with field name strings
    ///
    /// - Parameters:
    ///   - name: The name of the index
    ///   - recordType: The record type this index applies to
    ///   - fields: The fields included in this index
    ///   - unique: Whether this index enforces uniqueness
    ///   - indexType: The type of index (default: .value)
    ///   - scope: The scope of the index (default: .partition)
    public init(
        name: String,
        recordType: String,
        fields: [String],
        unique: Bool,
        indexType: IndexDefinitionType = .value,
        scope: IndexDefinitionScope = .partition
    ) {
        self.name = name
        self.recordType = recordType
        self.fields = fields
        self.unique = unique
        self.indexType = indexType
        self.scope = scope
    }

    /// Initialize an index definition with KeyPaths (type-safe)
    ///
    /// This initializer uses `PartialKeyPath` to provide compile-time type safety.
    ///
    /// - Parameters:
    ///   - name: The name of the index
    ///   - keyPaths: The key paths to the fields included in this index
    ///   - unique: Whether this index enforces uniqueness
    ///   - indexType: The type of index (default: .value)
    ///   - scope: The scope of the index (default: .partition)
    ///
    /// Example:
    /// ```swift
    /// let emailIndex = IndexDefinition(
    ///     name: "User_email_index",
    ///     keyPaths: [\User.email] as [PartialKeyPath<User>],
    ///     unique: false
    /// )
    /// ```
    public init<Record: Recordable>(
        name: String,
        keyPaths: [PartialKeyPath<Record>],
        unique: Bool,
        indexType: IndexDefinitionType = .value,
        scope: IndexDefinitionScope = .partition
    ) {
        self.name = name
        self.recordType = Record.recordName

        // Convert KeyPaths to field name strings using Record's fieldName method
        self.fields = keyPaths.map { keyPath in
            Record.fieldName(for: keyPath)
        }

        self.unique = unique
        self.indexType = indexType
        self.scope = scope
    }
}
