import Foundation
import FoundationDB

/// Migration Definition
///
/// Defines a schema migration from one version to another.
/// Migrations are applied automatically by MigrationManager to
/// evolve the schema and data over time.
///
/// **Migration Types**:
/// 1. **Index Migration**: Add/remove/rebuild indexes
/// 2. **Data Migration**: Transform record data
/// 3. **Schema Migration**: Change field types or constraints
///
/// **Example**:
/// ```swift
/// let migration = Migration(
///     fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
///     toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
///     description: "Add email index and make city field optional"
/// ) { context in
///     // Add new index
///     try await context.addIndex(
///         Index.value(named: "email_index", on: FieldKeyExpression(fieldName: "email"))
///     )
///
///     // Transform data
///     try await context.transformRecords(recordType: "User") { record in
///         // Migration logic here
///         return record
///     }
/// }
/// ```
public struct Migration: Sendable {
    // MARK: - Properties

    /// Source schema version
    public let fromVersion: SchemaVersion

    /// Target schema version
    public let toVersion: SchemaVersion

    /// Human-readable description of this migration
    public let description: String

    /// Migration execution function
    public let execute: @Sendable (MigrationContext) async throws -> Void

    // MARK: - Initialization

    /// Initialize a migration
    ///
    /// - Parameters:
    ///   - fromVersion: Source schema version
    ///   - toVersion: Target schema version
    ///   - description: Description of the migration
    ///   - execute: Migration execution closure
    public init(
        fromVersion: SchemaVersion,
        toVersion: SchemaVersion,
        description: String,
        execute: @escaping @Sendable (MigrationContext) async throws -> Void
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.description = description
        self.execute = execute
    }
}

// MARK: - Migration Context

/// Context provided to migrations during execution
///
/// Provides access to database operations and migration utilities.
public struct MigrationContext: Sendable {
    // MARK: - Properties

    /// Database instance
    nonisolated(unsafe) public let database: any DatabaseProtocol

    /// Schema being migrated to
    public let schema: Schema

    /// Record store factory
    ///
    /// **Current Limitation**: Returns `Any` instead of type-safe `RecordStore<Record>`.
    ///
    /// This prevents implementing migration operations that require:
    /// - Type-safe record scanning and iteration
    /// - Type-safe record transformation
    /// - Index building with specific Record types
    ///
    /// **Future Design Options**:
    /// 1. Protocol-based approach with associated types
    /// 2. Type-erased wrapper (AnyRecordStore)
    /// 3. Generic factory with type registration
    ///
    /// See Migration.swift method implementations for detailed requirements.
    private let storeFactory: @Sendable (String) throws -> Any

    // MARK: - Initialization

    internal init(
        database: any DatabaseProtocol,
        schema: Schema,
        storeFactory: @escaping @Sendable (String) throws -> Any
    ) {
        self.database = database
        self.schema = schema
        self.storeFactory = storeFactory
    }

    // MARK: - Index Operations

    /// Add a new index and build it online
    ///
    /// - Parameter index: The index to add
    /// - Throws: RecordLayerError if index addition fails
    public func addIndex(_ index: Index) async throws {
        throw RecordLayerError.internalError(
            """
            Migration index operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain Record type)
            2. RecordStore subspace in MigrationContext (for IndexStateManager and data operations)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Add index to schema (if not already present)
            2. Create IndexStateManager with RecordStore subspace
            3. Enable index (sets to writeOnly)
            4. Create OnlineIndexer with proper Record type from factory
            5. Build index using OnlineIndexer.buildIndex()
            6. Mark index as readable via IndexStateManager.makeReadable()
            """
        )
    }

    /// Remove an index and add FormerIndex entry
    ///
    /// - Parameters:
    ///   - indexName: Name of the index to remove
    ///   - addedVersion: Version when index was originally added
    /// - Throws: RecordLayerError if index removal fails
    public func removeIndex(
        indexName: String,
        addedVersion: SchemaVersion
    ) async throws {
        throw RecordLayerError.internalError(
            """
            Migration index operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain Record type)
            2. RecordStore subspace in MigrationContext (for IndexStateManager and data operations)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Create FormerIndex entry in schema metadata
               Key: [subspace][storeInfo][formerIndexes][indexName]
               Value: Tuple(addedVersion, removedTimestamp)
            2. Disable index state via IndexStateManager
            3. Clear all index data
               Range: [subspace][index][indexName]/*
            4. Update schema to remove index from active indexes list
            """
        )
    }

    /// Rebuild an existing index
    ///
    /// - Parameter indexName: Name of the index to rebuild
    /// - Throws: RecordLayerError if rebuild fails
    public func rebuildIndex(indexName: String) async throws {
        throw RecordLayerError.internalError(
            """
            Migration index operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain Record type)
            2. RecordStore subspace in MigrationContext (for IndexStateManager and data operations)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Disable index via IndexStateManager
            2. Clear existing index data
               Range: [subspace][index][indexName]/*
            3. Enable index (sets to writeOnly)
            4. Create OnlineIndexer with proper Record type from factory
            5. Build index using OnlineIndexer.buildIndex()
            6. Mark as readable via IndexStateManager.makeReadable()
            """
        )
    }

    // MARK: - Data Transformation

    /// Transform records of a specific type
    ///
    /// - Parameters:
    ///   - recordType: The record type to transform
    ///   - batchSize: Number of records per batch (default: 100)
    ///   - transform: Transformation function
    /// - Throws: RecordLayerError if transformation fails
    public func transformRecords<Record: Recordable>(
        recordType: String,
        batchSize: Int = 100,
        transform: @escaping @Sendable (Record) async throws -> Record
    ) async throws {
        throw RecordLayerError.internalError(
            """
            Migration data operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain RecordStore<Record>)
            2. RecordStore subspace in MigrationContext (for record key construction)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Get RecordStore<Record> from type-safe factory
            2. Implement RecordStore.scan() method for record iteration
            3. Process in batches (respecting transaction limits: 5s, 10MB)
            4. Apply transformation to each record
            5. Save transformed record using RecordStore.save()
            6. Track progress with RangeSet for resume capability
            """
        )
    }

    /// Delete records matching a predicate
    ///
    /// - Parameters:
    ///   - recordType: The record type to delete from
    ///   - predicate: Predicate to match records for deletion
    /// - Throws: RecordLayerError if deletion fails
    public func deleteRecords<Record: Recordable>(
        recordType: String,
        where predicate: @escaping @Sendable (Record) -> Bool
    ) async throws {
        throw RecordLayerError.internalError(
            """
            Migration data operations not yet implemented.

            Missing requirements:
            1. Type-safe RecordStore factory (to obtain RecordStore<Record>)
            2. RecordStore subspace in MigrationContext (for record key construction)

            Current limitation: MigrationContext.storeFactory returns Any, preventing type-safe operations.

            Future implementation:
            1. Get RecordStore<Record> from type-safe factory
            2. Implement RecordStore.scan() method for record iteration
            3. Process in batches (respecting transaction limits: 5s, 10MB)
            4. Apply predicate to filter records for deletion
            5. Delete matching records using RecordStore.delete()
            6. Indexes will be automatically updated by RecordStore
            """
        )
    }

    // MARK: - Utility

    /// Execute arbitrary database operation
    ///
    /// - Parameter operation: Operation to execute
    /// - Returns: Operation result
    /// - Throws: Any error from the operation
    public func executeOperation<T: Sendable>(
        _ operation: @escaping @Sendable (any TransactionProtocol) async throws -> T
    ) async throws -> T {
        return try await database.withTransaction { transaction in
            try await operation(transaction)
        }
    }
}

// MARK: - Migration Extensions

extension Migration: Identifiable {
    public var id: String {
        return "\(fromVersion)-\(toVersion)"
    }
}
