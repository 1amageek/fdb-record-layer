import Foundation

/// VersionedSchema - Describes a specific version of a schema
///
/// SwiftData compatible versioning:
/// - Version identifier
/// - Models included in this version
///
/// **Example usage**:
/// ```swift
/// enum SchemaV1: VersionedSchema {
///     static var versionIdentifier = Schema.Version(1, 0, 0)
///     static var models: [any Recordable.Type] = [User.self, Order.self]
/// }
///
/// enum SchemaV2: VersionedSchema {
///     static var versionIdentifier = Schema.Version(2, 0, 0)
///     static var models: [any Recordable.Type] = [User.self, Order.self, Message.self]
/// }
/// ```
public protocol VersionedSchema: Sendable {
    /// Version identifier
    static var versionIdentifier: Schema.Version { get }

    /// Models included in this version of the schema
    static var models: [any Recordable.Type] { get }
}

/// SchemaMigrationPlan - Describes schema evolution and migration between versions
///
/// SwiftData compatible migration:
/// - Versioned schema array
/// - Migration stages
///
/// **Example usage**:
/// ```swift
/// enum MyMigrationPlan: SchemaMigrationPlan {
///     static var schemas: [any VersionedSchema.Type] = [
///         SchemaV1.self,
///         SchemaV2.self
///     ]
///
///     static var stages: [MigrationStage] = [
///         .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
///     ]
/// }
/// ```
public protocol SchemaMigrationPlan: Sendable {
    /// All versioned schemas
    static var schemas: [any VersionedSchema.Type] { get }

    /// Migration stages
    static var stages: [MigrationStage] { get }
}

/// MigrationStage - Describes migration between two versions
public enum MigrationStage: Sendable {
    /// Lightweight migration (automatic)
    ///
    /// Use for simple schema changes like adding new types.
    case lightweight(
        fromVersion: any VersionedSchema.Type,
        toVersion: any VersionedSchema.Type
    )

    /// Custom migration
    ///
    /// Use for complex migrations requiring custom logic.
    case custom(
        fromVersion: any VersionedSchema.Type,
        toVersion: any VersionedSchema.Type,
        willMigrate: (@Sendable (Schema) async throws -> Void)?,
        didMigrate: (@Sendable (Schema) async throws -> Void)?
    )
}
