import Foundation
import FoundationDB
import FDBRecordCore
import Synchronization

/// A context that manages CRUD operations and change tracking for multiple record types.
///
/// RecordContext provides a SwiftData-like API for managing records with automatic
/// change tracking. Unlike ModelContext, it supports multiple record types simultaneously.
///
/// ## Usage
///
/// ```swift
/// @Recordable
/// struct User {
///     #PrimaryKey<User>([\.userID])
///     #Directory<User>("app", "users")
///     var userID: Int64
///     var name: String
/// }
///
/// let container = try RecordContainer(for: User.self, Product.self)
/// let context = await container.mainContext
///
/// // Insert records of different types
/// context.insert(user)
/// context.insert(product)
///
/// // Save all changes atomically
/// try await context.save()
/// ```
///
/// ## Change Tracking
///
/// RecordContext tracks two sets of changes:
/// - **Inserted**: New records to be saved
/// - **Deleted**: Records to be removed
///
/// Changes are only persisted when `save()` is called explicitly.
///
/// ## Directory Auto-Resolution
///
/// Each record type automatically resolves its storage path via the #Directory macro.
/// No manual path specification is required.
public final class RecordContext: Sendable {
    /// The container that owns this context.
    public let container: RecordContainer

    /// Change tracking state.
    private let stateLock: Mutex<ContextState>

    // MARK: - Initialization

    /// Creates a new record context.
    ///
    /// **Internal use only**. Use `RecordContainer.mainContext` instead.
    ///
    /// - Parameter container: The RecordContainer to use for storage.
    internal init(container: RecordContainer) {
        self.container = container
        self.stateLock = Mutex(ContextState())
    }

    // MARK: - State

    private struct ContextState {
        /// Records pending insertion (preserves type information).
        var insertedModels: [ObjectIdentifier: TypedRecordArray] = [:]

        /// Records pending deletion (preserves type information).
        var deletedModels: [ObjectIdentifier: TypedRecordArray] = [:]

        /// Whether autosave is enabled.
        var autosaveEnabled: Bool = false

        /// Whether a save operation is currently in progress.
        var isSaving: Bool = false

        /// Whether the context has unsaved changes.
        var hasChanges: Bool {
            return !insertedModels.isEmpty || !deletedModels.isEmpty
        }
    }

    /// Type-preserving wrapper for record arrays.
    private struct TypedRecordArray {
        let recordName: String
        let records: [any Recordable]
        let saveAll: (RecordContainer) async throws -> Void
        let deleteAll: (RecordContainer) async throws -> Void
        let saveAllWithTransaction: (RecordContainer, TransactionContext) async throws -> Void
        let deleteAllWithTransaction: (RecordContainer, TransactionContext) async throws -> Void

        init<T: Recordable>(records: [T]) {
            self.recordName = T.recordName
            self.records = records

            // Save operations with Directory auto-resolution
            self.saveAll = { container in
                // Group records by directory path (for multi-tenant support)
                let groups = try await Self.groupByDirectory(records: records, container: container)

                for (subspace, groupRecords) in groups {
                    let store = container.store(for: T.self, subspace: subspace)
                    for record in groupRecords {
                        try await store.save(record)
                    }
                }
            }

            self.deleteAll = { container in
                // Group records by directory path (for multi-tenant support)
                let groups = try await Self.groupByDirectory(records: records, container: container)

                for (subspace, groupRecords) in groups {
                    let store = container.store(for: T.self, subspace: subspace)
                    for record in groupRecords {
                        let primaryKey = record.extractPrimaryKey()
                        try await store.delete(by: primaryKey)
                    }
                }
            }

            // Atomic operations within transaction
            self.saveAllWithTransaction = { container, context in
                // Group records by directory path (for multi-tenant support)
                let groups = try await Self.groupByDirectory(records: records, container: container)

                for (subspace, groupRecords) in groups {
                    let store = container.store(for: T.self, subspace: subspace)
                    for record in groupRecords {
                        try await store.saveInternal(record, context: context)
                    }
                }
            }

            self.deleteAllWithTransaction = { container, context in
                // Group records by directory path (for multi-tenant support)
                let groups = try await Self.groupByDirectory(records: records, container: container)

                for (subspace, groupRecords) in groups {
                    let store = container.store(for: T.self, subspace: subspace)
                    for record in groupRecords {
                        let primaryKey = record.extractPrimaryKey()
                        try await store.deleteInternal(by: primaryKey, context: context)
                    }
                }
            }
        }

        /// Group records by directory path
        ///
        /// Records with different Field values (e.g., different tenantID) are grouped separately.
        private static func groupByDirectory<T: Recordable>(
            records: [T],
            container: RecordContainer
        ) async throws -> [(subspace: Subspace, records: [T])] {
            // Use prefix bytes as key (Subspace is not Hashable)
            var groups: [[UInt8]: (subspace: Subspace, records: [T])] = [:]

            for record in records {
                // Get or open directory for this record
                let subspace = try await container.getOrOpenDirectory(for: T.self, with: record)
                let prefixKey = subspace.prefix

                if var existing = groups[prefixKey] {
                    existing.records.append(record)
                    groups[prefixKey] = existing
                } else {
                    groups[prefixKey] = (subspace: subspace, records: [record])
                }
            }

            return groups.values.map { $0 }
        }
    }

    // MARK: - Public Properties

    /// Whether the context has unsaved changes.
    public var hasChanges: Bool {
        stateLock.withLock { $0.hasChanges }
    }

    /// Whether autosave is enabled.
    ///
    /// When enabled, changes are automatically saved after each operation.
    /// Default is `false` (manual save required).
    public var autosaveEnabled: Bool {
        get { stateLock.withLock { $0.autosaveEnabled } }
        set { stateLock.withLock { $0.autosaveEnabled = newValue } }
    }

    /// Array of inserted models pending save.
    public var insertedModelsArray: [any Recordable] {
        stateLock.withLock { Array($0.insertedModels.values.flatMap { $0.records }) }
    }

    /// Array of deleted models pending save.
    public var deletedModelsArray: [any Recordable] {
        stateLock.withLock { Array($0.deletedModels.values.flatMap { $0.records }) }
    }

    // MARK: - Fetching

    /// Creates a query builder for fetching records.
    ///
    /// **Note**: This method only works for record types with static directory paths
    /// (Path components only). If the record type uses Field components in #Directory,
    /// this method will throw an error. In that case, use the macro-generated store()
    /// method with explicit field values.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let activeUsers = try await context.fetch(User.self)
    ///     .where(\.status, .equals, "active")
    ///     .orderBy(\.createdAt, ascending: false)
    ///     .execute()
    /// ```
    ///
    /// - Parameter recordType: The type of records to fetch.
    /// - Returns: A QueryBuilder for constructing the query.
    /// - Throws: RecordLayerError if the record type has Field components in #Directory
    public func fetch<T: Recordable>(_ recordType: T.Type) async throws -> QueryBuilder<T> {
        // Build static directory (throws if Field components are present)
        let subspace = try await container.buildStaticDirectory(for: T.self)
        let store = container.store(for: recordType, subspace: subspace)
        return store.query()
    }

    // MARK: - Inserting

    /// Inserts a new record into the context.
    ///
    /// The record is tracked as inserted but not persisted until `save()` is called.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let user = User(userID: 123, email: "alice@example.com", name: "Alice")
    /// context.insert(user)
    /// try await context.save()  // Now persisted
    /// ```
    ///
    /// - Parameter record: The record to insert.
    public func insert<T: Recordable>(_ record: T) {
        let typeID = ObjectIdentifier(T.self)

        stateLock.withLock { state in
            // Remove from deleted if it was previously deleted
            if let deletedArray = state.deletedModels[typeID] {
                var records = deletedArray.records.compactMap { $0 as? T }
                records.removeAll { existing in
                    areSamePrimaryKey(existing, record)
                }
                if records.isEmpty {
                    state.deletedModels.removeValue(forKey: typeID)
                } else {
                    state.deletedModels[typeID] = TypedRecordArray(records: records)
                }
            }

            // Add to inserted
            if let insertedArray = state.insertedModels[typeID] {
                var records = insertedArray.records.compactMap { $0 as? T }
                records.append(record)
                state.insertedModels[typeID] = TypedRecordArray(records: records)
            } else {
                state.insertedModels[typeID] = TypedRecordArray(records: [record])
            }
        }

        if autosaveEnabled {
            Task {
                try? await save()
            }
        }
    }

    /// Inserts multiple records into the context.
    ///
    /// - Parameter records: The records to insert.
    public func insert<T: Recordable>(_ records: [T]) {
        for record in records {
            insert(record)
        }
    }

    // MARK: - Deleting

    /// Deletes a record from the context.
    ///
    /// The record is tracked as deleted but not removed from storage until `save()` is called.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let users = try await context.fetch(User.self)
    ///     .where(\.email, .equals, "alice@example.com")
    ///     .execute()
    ///
    /// if let user = users.first {
    ///     context.delete(user)
    ///     try await context.save()  // Now removed from storage
    /// }
    /// ```
    ///
    /// - Parameter record: The record to delete.
    public func delete<T: Recordable>(_ record: T) {
        let typeID = ObjectIdentifier(T.self)

        let wasInserted = stateLock.withLock { state -> Bool in
            // Check if record was pending insertion
            var wasRemoved = false
            if let insertedArray = state.insertedModels[typeID] {
                let initialCount = insertedArray.records.count
                var records = insertedArray.records.compactMap { $0 as? T }
                records.removeAll { existing in
                    areSamePrimaryKey(existing, record)
                }
                let finalCount = records.count
                wasRemoved = initialCount > finalCount

                if records.isEmpty {
                    state.insertedModels.removeValue(forKey: typeID)
                } else {
                    state.insertedModels[typeID] = TypedRecordArray(records: records)
                }
            }

            // Only add to deleted if it was NOT pending insertion
            if !wasRemoved {
                if let deletedArray = state.deletedModels[typeID] {
                    var records = deletedArray.records.compactMap { $0 as? T }
                    records.append(record)
                    state.deletedModels[typeID] = TypedRecordArray(records: records)
                } else {
                    state.deletedModels[typeID] = TypedRecordArray(records: [record])
                }
            }

            return wasRemoved
        }

        if autosaveEnabled && !wasInserted {
            Task {
                try? await save()
            }
        }
    }

    /// Deletes multiple records from the context.
    ///
    /// - Parameter records: The records to delete.
    public func delete<T: Recordable>(_ records: [T]) {
        for record in records {
            delete(record)
        }
    }

    /// Deletes all records of a given type.
    ///
    /// ⚠️ **Warning**: This operation deletes all records of the specified type.
    ///
    /// **Note**: This method only works for record types with static directory paths.
    /// If the record type uses Field components in #Directory, this method will throw an error.
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await context.delete(model: User.self)
    /// ```
    ///
    /// - Parameter model: The record type to delete all instances of.
    /// - Throws: RecordLayerError if deletion fails or if Field components are present.
    public func delete<T: Recordable>(model: T.Type) async throws {
        // Build static directory (throws if Field components are present)
        let subspace = try await container.buildStaticDirectory(for: T.self)
        let store = container.store(for: model, subspace: subspace)

        // Temporarily disable autosave for bulk operation
        let wasAutosaveEnabled = autosaveEnabled
        if wasAutosaveEnabled {
            autosaveEnabled = false
        }

        // Scan all records and delete them
        for try await record in store.scan() {
            delete(record)
        }

        // Restore autosave setting
        if wasAutosaveEnabled {
            autosaveEnabled = true
        }

        // Save the deletions
        try await save()
    }

    // MARK: - Saving

    /// Saves all pending changes to FoundationDB.
    ///
    /// This persists all inserted and deleted records in a single atomic transaction.
    ///
    /// ## Example
    ///
    /// ```swift
    /// context.insert(user1)
    /// context.insert(user2)
    /// context.delete(user3)
    ///
    /// try await context.save()  // All changes committed atomically
    /// ```
    ///
    /// - Throws: RecordLayerError if save fails.
    public func save() async throws {
        // Check if already saving and wait if necessary
        while true {
            let shouldWait = stateLock.withLock { state -> Bool in
                if state.isSaving {
                    return true
                } else {
                    state.isSaving = true
                    return false
                }
            }

            if !shouldWait {
                break
            }

            // Wait a bit before checking again
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        defer {
            stateLock.withLock { state in
                state.isSaving = false
            }
        }

        // Capture pending changes and their ObjectIdentifiers
        let (insertedArrays, deletedArrays, insertedIDs, deletedIDs) = stateLock.withLock { state in
            return (
                Array(state.insertedModels.values),
                Array(state.deletedModels.values),
                Array(state.insertedModels.keys),
                Array(state.deletedModels.keys)
            )
        }

        // Return early if no changes
        guard !insertedArrays.isEmpty || !deletedArrays.isEmpty else {
            return
        }

        // Execute all changes in a single atomic transaction
        do {
            try await container.withTransaction { context in
                // Save inserted records
                for typedArray in insertedArrays {
                    try await typedArray.saveAllWithTransaction(container, context)
                }

                // Delete records
                for typedArray in deletedArrays {
                    try await typedArray.deleteAllWithTransaction(container, context)
                }
            }

            // Clear only the snapshotted changes after successful commit
            // This preserves any changes added during transaction execution
            stateLock.withLock { state in
                for id in insertedIDs {
                    state.insertedModels.removeValue(forKey: id)
                }
                for id in deletedIDs {
                    state.deletedModels.removeValue(forKey: id)
                }
            }
        } catch {
            // Re-throw the error without clearing state
            throw error
        }
    }

    // MARK: - Rollback

    /// Discards all pending changes.
    ///
    /// Clears inserted and deleted tracking without persisting anything.
    ///
    /// ## Example
    ///
    /// ```swift
    /// context.insert(user)
    /// context.rollback()  // user insert is discarded
    /// ```
    public func rollback() {
        stateLock.withLock { state in
            state.insertedModels.removeAll()
            state.deletedModels.removeAll()
        }
    }

    // MARK: - Transactions

    /// Executes a block within a transaction context.
    ///
    /// All operations within the block are tracked, and changes are saved atomically.
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await context.withTransaction {
    ///     let users = try await context.fetch(User.self).execute()
    ///     for user in users {
    ///         context.delete(user)
    ///     }
    ///     // Automatically saved at the end
    /// }
    /// ```
    ///
    /// - Parameter block: The transaction block to execute.
    /// - Returns: The result of the block.
    /// - Throws: RecordLayerError if transaction fails.
    public func withTransaction<T>(_ block: () async throws -> T) async throws -> T {
        let result = try await block()
        try await save()
        return result
    }

    // MARK: - Helper Methods

    /// Compare two records by primary key.
    private func areSamePrimaryKey(_ lhs: any Recordable, _ rhs: any Recordable) -> Bool {
        let lhsType = type(of: lhs)
        let rhsType = type(of: rhs)

        // Different types can't have the same primary key
        guard lhsType == rhsType else { return false }

        // Extract primary keys as Tuples
        let lhsPrimaryKey = lhs.extractPrimaryKey()
        let rhsPrimaryKey = rhs.extractPrimaryKey()

        // Compare the packed byte representations
        return lhsPrimaryKey.pack() == rhsPrimaryKey.pack()
    }
}
