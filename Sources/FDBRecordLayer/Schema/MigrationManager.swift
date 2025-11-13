import Foundation
import FoundationDB
import Synchronization

/// Migration Manager
///
/// Manages schema migrations and ensures they are applied in the correct order.
/// Tracks which migrations have been executed and prevents duplicate execution.
///
/// **Features**:
/// - Automatic migration ordering based on versions
/// - Idempotent migration execution (safe to run multiple times)
/// - Progress tracking with RangeSet
/// - Rollback support (future enhancement)
///
/// **Usage**:
/// ```swift
/// let manager = MigrationManager(
///     database: database,
///     schema: schema,
///     migrations: [
///         migration1,
///         migration2,
///         migration3
///     ]
/// )
///
/// // Apply all pending migrations
/// try await manager.migrate(to: SchemaVersion(major: 3, minor: 0, patch: 0))
/// ```
public final class MigrationManager: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let schema: Schema
    private let migrations: [Migration]
    private let migrationSubspace: Subspace
    private let lock: Mutex<MigrationState>

    /// Type-erased record store registry
    ///
    /// Maps record type names to their RecordStores for migration operations.
    private let storeRegistry: [String: any AnyRecordStore]

    private struct MigrationState {
        var isRunning: Bool = false
        var currentVersion: SchemaVersion?
    }

    // MARK: - Initialization

    /// Initialize migration manager with store registry
    ///
    /// - Parameters:
    ///   - database: Database instance
    ///   - schema: Target schema
    ///   - migrations: Array of migrations to manage
    ///   - storeRegistry: Registry of RecordStores for each record type
    ///   - migrationSubspace: Subspace for migration metadata (default: "migrations")
    public init(
        database: any DatabaseProtocol,
        schema: Schema,
        migrations: [Migration],
        storeRegistry: [String: any AnyRecordStore],
        migrationSubspace: Subspace? = nil
    ) {
        self.database = database
        self.schema = schema
        self.migrations = migrations.sorted { $0.toVersion < $1.toVersion }
        self.storeRegistry = storeRegistry
        self.migrationSubspace = migrationSubspace ?? Subspace(prefix: Tuple("migrations").pack())
        self.lock = Mutex(MigrationState())
    }

    /// Convenience initializer for single RecordStore
    ///
    /// Use this when migrating a single record type.
    ///
    /// - Parameters:
    ///   - database: Database instance
    ///   - schema: Target schema
    ///   - migrations: Array of migrations
    ///   - store: RecordStore to migrate
    ///   - migrationSubspace: Subspace for migration metadata
    public convenience init<Record: Recordable>(
        database: any DatabaseProtocol,
        schema: Schema,
        migrations: [Migration],
        store: RecordStore<Record>,
        migrationSubspace: Subspace? = nil
    ) {
        let registry: [String: any AnyRecordStore] = [Record.recordName: store]
        self.init(
            database: database,
            schema: schema,
            migrations: migrations,
            storeRegistry: registry,
            migrationSubspace: migrationSubspace
        )
    }

    // MARK: - Public API

    /// Get current schema version
    ///
    /// - Returns: Current schema version, or nil if not initialized
    /// - Throws: Database errors
    public func getCurrentVersion() async throws -> SchemaVersion? {
        return try await database.withTransaction { transaction -> SchemaVersion? in
            let versionKey = migrationSubspace.pack(Tuple("current_version"))
            guard let versionData = try await transaction.getValue(for: versionKey, snapshot: true) else {
                return nil
            }

            // Decode version
            let tuple = try Tuple.unpack(from: versionData)
            guard tuple.count >= 3 else {
                throw RecordLayerError.invalidSerializedData("Invalid version format: tuple count \(tuple.count), expected 3")
            }

            // Tuple encoding returns Int for zero, Int64 for non-zero
            // We need to handle both types
            func extractInt(_ element: any TupleElement) -> Int? {
                if let value = element as? Int {
                    return value
                } else if let value = element as? Int64 {
                    return Int(value)
                }
                return nil
            }

            guard let major = extractInt(tuple[0]),
                  let minor = extractInt(tuple[1]),
                  let patch = extractInt(tuple[2]) else {
                let types = (0..<tuple.count).map { i in
                    let element = tuple[i]
                    return "\(i): \(type(of: element)) = \(element)"
                }.joined(separator: ", ")
                throw RecordLayerError.invalidSerializedData("Invalid version format. Types: [\(types)]")
            }

            return SchemaVersion(major: major, minor: minor, patch: patch)
        }
    }

    /// Migrate to a specific version
    ///
    /// Applies all migrations from the current version to the target version.
    ///
    /// - Parameter targetVersion: Target schema version
    /// - Throws: RecordLayerError if migration fails
    public func migrate(to targetVersion: SchemaVersion) async throws {
        // Check if already running
        let isAlreadyRunning = lock.withLock { state -> Bool in
            if state.isRunning {
                return true
            }
            state.isRunning = true
            return false
        }

        guard !isAlreadyRunning else {
            throw RecordLayerError.internalError("Migration already in progress")
        }

        defer {
            lock.withLock { state in
                state.isRunning = false
            }
        }

        // Get current version
        var currentVersion = try await getCurrentVersion() ?? SchemaVersion(major: 0, minor: 0, patch: 0)

        // Build migration path from current to target version
        // We need to find a chain of migrations that takes us from currentVersion to targetVersion
        var migrationsToApply: [Migration] = []

        while currentVersion < targetVersion {
            // Find the next migration in the chain
            guard let nextMigration = migrations.first(where: { migration in
                migration.fromVersion == currentVersion && migration.toVersion <= targetVersion
            }) else {
                throw RecordLayerError.internalError(
                    "No migration path found from \(currentVersion) to \(targetVersion)"
                )
            }

            migrationsToApply.append(nextMigration)
            currentVersion = nextMigration.toVersion
        }

        guard !migrationsToApply.isEmpty else {
            // Already at target version
            return
        }

        // Apply migrations in order
        for migration in migrationsToApply {
            try await applyMigration(migration)
        }

        // Update current version
        try await setCurrentVersion(targetVersion)
    }

    /// List all migrations
    ///
    /// - Returns: Array of all registered migrations
    public func listMigrations() -> [Migration] {
        return migrations
    }

    /// Check if migration has been applied
    ///
    /// - Parameter migration: Migration to check
    /// - Returns: True if migration has been applied
    /// - Throws: Database errors
    public func isMigrationApplied(_ migration: Migration) async throws -> Bool {
        return try await database.withTransaction { transaction in
            let migrationKey = migrationSubspace.pack(Tuple("applied", migration.id))
            let value = try await transaction.getValue(for: migrationKey, snapshot: true)
            return value != nil
        }
    }

    // MARK: - Private Methods

    /// Apply a single migration
    ///
    /// - Parameter migration: Migration to apply
    /// - Throws: RecordLayerError if migration fails
    private func applyMigration(_ migration: Migration) async throws {
        // Check if already applied
        if try await isMigrationApplied(migration) {
            return
        }

        // Create migration context with store registry
        let metadataSubspace = migrationSubspace.subspace("metadata")
        let context = MigrationContext(
            database: database,
            schema: schema,
            metadataSubspace: metadataSubspace,
            storeRegistry: storeRegistry
        )

        // Execute migration
        try await migration.execute(context)

        // Mark as applied
        try await markMigrationApplied(migration)
    }

    /// Mark migration as applied
    ///
    /// - Parameter migration: Migration to mark
    /// - Throws: Database errors
    private func markMigrationApplied(_ migration: Migration) async throws {
        try await database.withTransaction { transaction in
            let migrationKey = migrationSubspace.pack(Tuple("applied", migration.id))
            let timestamp = Date().timeIntervalSince1970
            transaction.setValue(
                Tuple(timestamp).pack(),
                for: migrationKey
            )
        }
    }

    /// Set current schema version
    ///
    /// - Parameter version: Version to set
    /// - Throws: Database errors
    private func setCurrentVersion(_ version: SchemaVersion) async throws {
        try await database.withTransaction { transaction in
            let versionKey = migrationSubspace.pack(Tuple("current_version"))
            let versionTuple = Tuple(
                Int64(version.major),
                Int64(version.minor),
                Int64(version.patch)
            )
            transaction.setValue(versionTuple.pack(), for: versionKey)
        }
    }
}

// MARK: - Migration Helpers

extension MigrationManager {
    /// Create a simple index addition migration
    ///
    /// - Parameters:
    ///   - fromVersion: Source version
    ///   - toVersion: Target version
    ///   - index: Index to add
    /// - Returns: Migration instance
    public static func addIndexMigration(
        fromVersion: SchemaVersion,
        toVersion: SchemaVersion,
        index: Index
    ) -> Migration {
        return Migration(
            fromVersion: fromVersion,
            toVersion: toVersion,
            description: "Add index: \(index.name)"
        ) { context in
            try await context.addIndex(index)
        }
    }

    /// Create a simple index removal migration
    ///
    /// - Parameters:
    ///   - fromVersion: Source version
    ///   - toVersion: Target version
    ///   - indexName: Name of index to remove
    ///   - addedVersion: Version when index was added
    /// - Returns: Migration instance
    public static func removeIndexMigration(
        fromVersion: SchemaVersion,
        toVersion: SchemaVersion,
        indexName: String,
        addedVersion: SchemaVersion
    ) -> Migration {
        return Migration(
            fromVersion: fromVersion,
            toVersion: toVersion,
            description: "Remove index: \(indexName)"
        ) { context in
            try await context.removeIndex(indexName: indexName, addedVersion: addedVersion)
        }
    }
}
