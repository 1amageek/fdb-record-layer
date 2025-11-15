import Foundation
import Synchronization

/// SwiftData-style Schema - Maps application model classes to data store
///
/// Corresponds to SwiftData's Schema design:
/// - Initialize with array of types
/// - Version management
/// - Entity access
///
/// **Example usage**:
/// ```swift
/// let schema = try Schema(
///     [User.self, Order.self, Message.self],
///     version: Schema.Version(1, 0, 0)
/// )
///
/// // Entity access
/// let userEntity = schema.entity(for: User.self)
/// print("Indices: \(userEntity?.indices ?? [])")
/// ```
public final class Schema: Sendable {

    // MARK: - Version

    /// Schema version (SwiftData compatible)
    ///
    /// Uses semantic versioning:
    /// - major: Incompatible changes
    /// - minor: Backward-compatible feature additions
    /// - patch: Backward-compatible bug fixes
    public struct Version: Sendable, Hashable, Codable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        /// Create a version
        ///
        /// - Parameters:
        ///   - major: Major version
        ///   - minor: Minor version
        ///   - patch: Patch version
        public init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var description: String {
            return "\(major).\(minor).\(patch)"
        }

        // Codable
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.major = try container.decode(Int.self, forKey: .major)
            self.minor = try container.decode(Int.self, forKey: .minor)
            self.patch = try container.decode(Int.self, forKey: .patch)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(major, forKey: .major)
            try container.encode(minor, forKey: .minor)
            try container.encode(patch, forKey: .patch)
        }

        private enum CodingKeys: String, CodingKey {
            case major, minor, patch
        }
    }

    // MARK: - Properties

    /// Schema version
    public let version: Version

    /// Encoding version (for compatibility)
    public let encodingVersion: Version

    /// All entities (SwiftData compatible)
    public let entities: [Entity]

    /// Access entities by name (SwiftData compatible)
    public let entitiesByName: [String: Entity]

    /// [FoundationDB extension] Former indexes (schema evolution)
    /// Records of deleted indexes (schema definition only, no Index implementation objects)
    public let formerIndexes: [String: FormerIndex]

    /// [FoundationDB extension] Index definitions
    /// Full Index objects with type, options, and expressions
    public let indexes: [Index]

    /// [FoundationDB extension] Indexes by name for quick lookup
    internal let indexesByName: [String: Index]

    // MARK: - Initialization

    /// SwiftData-style initializer - Create from array of types
    ///
    /// - Parameters:
    ///   - types: Array of Recordable types
    ///   - version: Schema version
    ///   - indexes: Additional index definitions (optional, merged with macro-defined indexes)
    ///
    /// **Index Collection**:
    /// This initializer automatically collects IndexDefinitions from types:
    /// 1. Collects `indexDefinitions` from each Recordable type (defined by #Index/#Unique macros)
    /// 2. Converts IndexDefinition to Index objects
    /// 3. Merges with manually provided indexes
    ///
    /// **Example usage**:
    /// ```swift
    /// @Recordable
    /// struct User {
    ///     #Index<User>([\\.email])  // ← Automatically collected
    ///     #PrimaryKey<User>([\.userID])
    ///
    ///     var userID: Int64
    ///     var email: String
    /// }
    ///
    /// let schema = Schema([User.self, Order.self])  // OK: Indexes auto-collected
    /// ```
    ///
    /// **Manual indexes** (for programmatic index definitions):
    /// ```swift
    /// let schema = Schema(
    ///     [User.self, Order.self],
    ///     indexes: [
    ///         .value("manual_index", on: FieldKeyExpression("field"), recordTypes: ["User"])
    ///     ]
    /// )
    /// ```
    public init(
        _ types: [any Recordable.Type],
        version: Version = Version(1, 0, 0),
        indexes: [Index] = []
    ) {
        self.version = version
        self.encodingVersion = version

        // Build entities
        var entities: [Entity] = []
        var entitiesByName: [String: Entity] = [:]

        for type in types {
            let entity = Entity(from: type)
            entities.append(entity)
            entitiesByName[entity.name] = entity
        }

        self.entities = entities
        self.entitiesByName = entitiesByName

        // Collect indexes from types
        var allIndexes: [Index] = []

        for type in types {
            // Get IndexDefinitions from type (generated by macros)
            let definitions = type.indexDefinitions

            // Convert IndexDefinition to Index
            // OK: Pass type.recordName to ensure correct recordTypes (avoiding "Self" or module names)
            for def in definitions {
                let index = Self.convertIndexDefinition(def, recordName: type.recordName)
                allIndexes.append(index)
            }
        }

        // Merge with manually provided indexes
        allIndexes.append(contentsOf: indexes)

        // Store indexes
        self.indexes = allIndexes
        var indexesByName: [String: Index] = [:]
        for index in allIndexes {
            indexesByName[index.name] = index
        }
        self.indexesByName = indexesByName

        // Former indexes (empty for now, future: migration support)
        self.formerIndexes = [:]
    }

    /// Convert IndexDefinition to Index
    ///
    /// This method converts macro-generated IndexDefinition to full Index objects.
    ///
    /// - Parameters:
    ///   - definition: IndexDefinition from #Index or #Unique macro
    ///   - recordName: The actual record type name from Recordable.recordName
    /// - Returns: Index object
    ///
    /// **Note**: Uses `recordName` parameter instead of `definition.recordType` to avoid
    /// issues with Self or module-qualified type names (e.g., "MyModule.User").
    /// The `definition.recordType` is kept for logging/debugging purposes only.
    private static func convertIndexDefinition(
        _ definition: IndexDefinition,
        recordName: String
    ) -> Index {
        // Build KeyExpression from field names
        let keyExpression: KeyExpression

        // Check if this is a Range type index
        if let rangeComponent = definition.rangeComponent,
           definition.fields.count == 1 {
            // Range型インデックス: RangeKeyExpressionを生成
            keyExpression = RangeKeyExpression(
                fieldName: definition.fields[0],
                component: rangeComponent,
                boundaryType: definition.boundaryType ?? .halfOpen
            )
        } else if definition.fields.count == 1 {
            // 通常の単一フィールドインデックス
            keyExpression = FieldKeyExpression(fieldName: definition.fields[0])
        } else {
            // 複合インデックス
            keyExpression = ConcatenateKeyExpression(
                children: definition.fields.map { FieldKeyExpression(fieldName: $0) }
            )
        }

        // Determine index type and options
        let indexType: IndexType
        let options: IndexOptions

        switch definition.indexType {
        case .value:
            indexType = .value
            options = IndexOptions(unique: definition.unique)
        case .rank:
            indexType = .rank
            options = IndexOptions(unique: false)
        case .count:
            indexType = .count
            options = IndexOptions(unique: false)
        case .sum:
            indexType = .sum
            options = IndexOptions(unique: false)
        case .min:
            indexType = .min
            options = IndexOptions(unique: false)
        case .max:
            indexType = .max
            options = IndexOptions(unique: false)
        case .vector(let vectorOpts):
            indexType = .vector
            options = IndexOptions(unique: false, vectorOptions: vectorOpts)
        case .spatial(let spatialOpts):
            indexType = .spatial
            options = IndexOptions(unique: false, spatialOptions: spatialOpts)
        case .version:
            indexType = .version
            options = IndexOptions(unique: false)
        }

        // Create Index with recordTypes filter
        // OK: Use recordName parameter (from type.recordName) instead of definition.recordType
        // to avoid issues with "Self" or module-qualified names like "MyModule.User"
        // Convert IndexDefinitionScope to IndexScope
        let indexScope: IndexScope = definition.scope == .partition ? .partition : .global

        return Index(
            name: definition.name,
            type: indexType,
            rootExpression: keyExpression,
            recordTypes: Set([recordName]),  // OK: Use actual recordName
            options: options,
            scope: indexScope
        )
    }

    /// Create from VersionedSchema (for migrations)
    public convenience init(versionedSchema: any VersionedSchema.Type) {
        self.init(
            versionedSchema.models,
            version: versionedSchema.versionIdentifier
        )
    }

    /// Test-only initializer for manual Schema construction
    ///
    /// Allows creating Schema objects with custom Entity objects for testing purposes.
    /// This is primarily used for schema evolution validation tests where we need
    /// to construct schemas with specific enum metadata.
    ///
    /// - Parameters:
    ///   - entities: Array of Entity objects
    ///   - version: Schema version
    ///   - indexes: Index definitions (optional)
    public init(
        entities: [Entity],
        version: Version = Version(1, 0, 0),
        indexes: [Index] = []
    ) {
        self.version = version
        self.encodingVersion = version

        // Build entity maps
        var entitiesByName: [String: Entity] = [:]
        for entity in entities {
            entitiesByName[entity.name] = entity
        }

        self.entities = entities
        self.entitiesByName = entitiesByName

        // Store indexes
        self.indexes = indexes
        var indexesByName: [String: Index] = [:]
        for index in indexes {
            indexesByName[index.name] = index
        }
        self.indexesByName = indexesByName

        // Former indexes (empty for test schemas)
        self.formerIndexes = [:]
    }

    // MARK: - Entity Access

    /// Get entity for type
    ///
    /// - Parameter type: Recordable type
    /// - Returns: Entity (nil if not found)
    public func entity<T: Recordable>(for type: T.Type) -> Entity? {
        return entitiesByName[T.recordName]
    }

    /// Get entity by name
    ///
    /// - Parameter name: Entity name
    /// - Returns: Entity (nil if not found)
    public func entity(named name: String) -> Entity? {
        return entitiesByName[name]
    }

    // MARK: - Index Access

    /// Get index by name
    ///
    /// - Parameter name: Index name
    /// - Returns: Index (nil if not found)
    public func index(named name: String) -> Index? {
        return indexesByName[name]
    }

    /// Get indexes for a specific record type
    ///
    /// Returns all indexes that apply to the given record type.
    /// An index applies to a record type if:
    /// - index.recordTypes is nil (universal index, applies to all types), OR
    /// - index.recordTypes contains the recordName
    ///
    /// - Parameter recordName: The record type name
    /// - Returns: Array of applicable indexes
    public func indexes(for recordName: String) -> [Index] {
        return indexes.filter { index in
            if let recordTypes = index.recordTypes {
                return recordTypes.contains(recordName)
            } else {
                // Universal index (no recordTypes specified) applies to all types
                return true
            }
        }
    }

    // MARK: - Save/Load (future extension)

    /// Save schema to file
    ///
    /// - Parameter url: Destination URL
    /// - Throws: RecordLayerError
    public func save(to url: URL) throws {
        // Future implementation: Schema persistence
        throw RecordLayerError.internalError("Schema.save(to:) is not implemented yet")
    }

    /// Load schema from file
    ///
    /// - Parameter url: Source URL
    /// - Returns: Schema
    /// - Throws: RecordLayerError
    public static func load(from url: URL) throws -> Schema {
        // Future implementation: Schema loading
        throw RecordLayerError.internalError("Schema.load(from:) is not implemented yet")
    }
}

// MARK: - CustomDebugStringConvertible

extension Schema: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "Schema(version: \(version), entities: \(entities.count))"
    }
}

// MARK: - Equatable

extension Schema: Equatable {
    public static func == (lhs: Schema, rhs: Schema) -> Bool {
        return lhs.version == rhs.version &&
               lhs.entities == rhs.entities
    }
}

// MARK: - Hashable

extension Schema: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        // Use sorted entity names to ensure order-independent hashing
        for name in entitiesByName.keys.sorted() {
            hasher.combine(name)
        }
    }
}

// MARK: - Schema.Version Comparable

extension Schema.Version: Comparable {
    public static func < (lhs: Schema.Version, rhs: Schema.Version) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}
