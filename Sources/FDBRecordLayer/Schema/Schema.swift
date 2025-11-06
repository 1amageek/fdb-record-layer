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

    /// Internal: RecordMetaData (leverages existing implementation)
    internal let recordMetaData: RecordMetaData

    // MARK: - Initialization

    /// SwiftData-style initializer - Create from array of types
    ///
    /// - Parameters:
    ///   - types: Array of Recordable types
    ///   - version: Schema version
    ///
    /// **Example usage**:
    /// ```swift
    /// let schema = Schema(
    ///     [User.self, Order.self, Message.self],
    ///     version: Schema.Version(1, 0, 0)
    /// )
    /// ```
    public init(
        _ types: [any Recordable.Type],
        version: Version = Version(1, 0, 0)
    ) {
        self.version = version
        self.encodingVersion = version

        // Create RecordMetaData internally
        let metaData = RecordMetaData(version: version.major)
        for type in types {
            metaData.registerRecordType(type)
        }
        self.recordMetaData = metaData

        // Build entities
        var entities: [Entity] = []
        var entitiesByName: [String: Entity] = [:]

        for (name, recordType) in metaData.recordTypes {
            let entity = Entity(name: name, recordType: recordType, metaData: metaData)
            entities.append(entity)
            entitiesByName[name] = entity
        }

        self.entities = entities
        self.entitiesByName = entitiesByName
    }

    /// Create from VersionedSchema (for migrations)
    public convenience init(versionedSchema: any VersionedSchema.Type) {
        self.init(
            versionedSchema.models,
            version: versionedSchema.versionIdentifier
        )
    }

    // MARK: - Entity Access

    /// Get entity for type
    ///
    /// - Parameter type: Recordable type
    /// - Returns: Entity (nil if not found)
    public func entity<T: Recordable>(for type: T.Type) -> Entity? {
        return entitiesByName[T.recordTypeName]
    }

    /// Get entity by name
    ///
    /// - Parameter name: Entity name
    /// - Returns: Entity (nil if not found)
    public func entity(named name: String) -> Entity? {
        return entitiesByName[name]
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
