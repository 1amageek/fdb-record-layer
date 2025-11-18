import Foundation
import FoundationDB
import FDBRecordCore
import Synchronization

/// A context that manages CRUD operations and change tracking for models.
///
/// ModelContext provides a SwiftData-like API for managing records with automatic
/// change tracking. It wraps RecordContainer and provides a simplified interface.
///
/// ## Usage
///
/// ```swift
/// let container = try RecordContainer(for: User.self, Product.self)
/// let context = ModelContext(container: container, subspace: Subspace(path: "app"))
///
/// // Fetch records
/// let users = try await context.fetch(User.self)
///     .where(\.email, .equals, "alice@example.com")
///     .execute()
///
/// // Insert new record
/// let newUser = User(userID: 123, email: "bob@example.com", name: "Bob")
/// context.insert(newUser)
///
/// // Delete record
/// context.delete(users[0])
///
/// // Save all changes
/// try await context.save()
/// ```
///
/// ## Change Tracking
///
/// ModelContext tracks two sets of changes:
/// - **Inserted**: New records to be saved
/// - **Deleted**: Records to be removed
///
/// Changes are only persisted when `save()` is called explicitly.
///
/// **Note**: Update tracking is not yet implemented. To update a record,
/// fetch it, modify it, and call `store.save()` directly.
public final class ModelContext: Sendable {
    /// The container that owns this context.
    public let container: RecordContainer

    /// Subspace for this context.
    public let subspace: Subspace

    /// Change tracking state.
    private let stateLock: Mutex<ContextState>

    // MARK: - Initialization

    /// Creates a new model context.
    ///
    /// - Parameters:
    ///   - container: The RecordContainer to use for storage.
    ///   - subspace: The subspace for this context's operations.
    public init(container: RecordContainer, subspace: Subspace) {
        self.container = container
        self.subspace = subspace
        self.stateLock = Mutex(ContextState())
    }

    /// Creates a new model context with a path-based subspace.
    ///
    /// - Parameters:
    ///   - container: The RecordContainer to use for storage.
    ///   - path: Firestore-style path (e.g., "accounts/acct-001/users").
    public convenience init(container: RecordContainer, path: String) {
        self.init(container: container, subspace: Subspace(path: path))
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

        /// The current record type being tracked (for single-type enforcement).
        var currentType: ObjectIdentifier? = nil

        /// Whether the context has unsaved changes.
        var hasChanges: Bool {
            return !insertedModels.isEmpty || !deletedModels.isEmpty
        }
    }

    /// Type-preserving wrapper for record arrays.
    private struct TypedRecordArray {
        let recordName: String
        let records: [any Recordable]
        let saveAll: (RecordContainer, Subspace) async throws -> Void
        let deleteAll: (RecordContainer, Subspace) async throws -> Void
        let saveAllWithTransaction: (RecordContainer, Subspace, RecordContext) async throws -> Void
        let deleteAllWithTransaction: (RecordContainer, Subspace, RecordContext) async throws -> Void

        init<T: Recordable>(records: [T]) {
            self.recordName = T.recordName
            self.records = records

            // Legacy: Each save/delete creates its own transaction
            self.saveAll = { container, subspace in
                let store = container.store(for: T.self, subspace: subspace)
                for record in records {
                    try await store.save(record)
                }
            }
            self.deleteAll = { container, subspace in
                let store = container.store(for: T.self, subspace: subspace)
                for record in records {
                    let primaryKey = record.extractPrimaryKey()
                    try await store.delete(by: primaryKey)
                }
            }

            // Atomic: All operations in single transaction
            self.saveAllWithTransaction = { container, subspace, context in
                let store = container.store(for: T.self, subspace: subspace)
                for record in records {
                    try await store.saveInternal(record, context: context)
                }
            }
            self.deleteAllWithTransaction = { container, subspace, context in
                let store = container.store(for: T.self, subspace: subspace)
                for record in records {
                    let primaryKey = record.extractPrimaryKey()
                    try await store.deleteInternal(by: primaryKey, context: context)
                }
            }
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
    public func fetch<T: Recordable>(_ recordType: T.Type) -> QueryBuilder<T> {
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
            // Enforce single-type context
            if let currentType = state.currentType, currentType != typeID {
                fatalError(
                    "ModelContext only supports single record type per context. " +
                    "Current type: \(state.insertedModels[currentType]?.recordName ?? "unknown"), " +
                    "attempted type: \(T.recordName)"
                )
            }
            state.currentType = typeID

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
            // Enforce single-type context
            if let currentType = state.currentType, currentType != typeID {
                fatalError(
                    "ModelContext only supports single record type per context. " +
                    "Current type: \(state.insertedModels[currentType]?.recordName ?? "unknown"), " +
                    "attempted type: \(T.recordName)"
                )
            }
            state.currentType = typeID

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
            // (i.e., it exists in the database)
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
    /// ## Example
    ///
    /// ```swift
    /// try await context.delete(model: User.self)
    /// ```
    ///
    /// - Parameter model: The record type to delete all instances of.
    /// - Throws: RecordLayerError if deletion fails.
    public func delete<T: Recordable>(model: T.Type) async throws {
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

        // Capture pending changes (TypedRecordArray preserves type information)
        let (insertedArrays, deletedArrays) = stateLock.withLock { state in
            return (
                Array(state.insertedModels.values),
                Array(state.deletedModels.values)
            )
        }

        // Return early if no changes
        // IMPORTANT: Reset currentType to allow different record type in next operation
        guard !insertedArrays.isEmpty || !deletedArrays.isEmpty else {
            stateLock.withLock { state in
                state.currentType = nil
            }
            return
        }

        // ✅ Execute all changes in a single atomic transaction
        // All operations succeed together or fail together (all-or-nothing semantics)
        do {
            try await container.withTransaction { context in
                // Save inserted records using type-preserving closures
                for typedArray in insertedArrays {
                    try await typedArray.saveAllWithTransaction(container, subspace, context)
                }

                // Delete records using type-preserving closures
                for typedArray in deletedArrays {
                    try await typedArray.deleteAllWithTransaction(container, subspace, context)
                }
            }

            // Clear change tracking only after successful commit
            stateLock.withLock { state in
                state.insertedModels.removeAll()
                state.deletedModels.removeAll()
                state.currentType = nil
            }
        } catch {
            // Re-throw the error without clearing state
            // This allows the user to retry save() later
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
            state.currentType = nil
            // Don't clear isSaving - that's managed by save() itself
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
    /// try await context.transaction {
    ///     let users = try await context.fetch(User.self).execute()
    ///     for user in users {
    ///         context.delete(user)
    ///     }
    ///     // Automatically saved at the end
    /// }
    /// ```
    ///
    /// - Parameter block: The transaction block to execute.
    /// - Throws: RecordLayerError if transaction fails.
    public func transaction(block: () async throws -> Void) async throws {
        // Execute the block
        try await block()

        // Save changes
        try await save()
    }

    // MARK: - Helper Methods

    /// Compare two records by primary key.
    private func areSamePrimaryKey(_ lhs: any Recordable, _ rhs: any Recordable) -> Bool {
        // Extract primary keys and compare
        let lhsType = type(of: lhs)
        let rhsType = type(of: rhs)

        // Different types can't have the same primary key
        guard lhsType == rhsType else { return false }

        // Extract primary keys as Tuples
        let lhsPrimaryKey = lhs.extractPrimaryKey()
        let rhsPrimaryKey = rhs.extractPrimaryKey()

        // Compare the packed byte representations
        // This is more reliable than String(describing:) for all types
        return lhsPrimaryKey.pack() == rhsPrimaryKey.pack()
    }
}

// MARK: - RecordContainer Extension

extension RecordContainer {
    /// Creates a main model context for UI operations.
    ///
    /// This context should be used on the main thread for UI-bound operations.
    ///
    /// - Parameter subspace: The subspace for this context.
    /// - Returns: A new ModelContext instance.
    @MainActor
    public func mainContext(subspace: Subspace) -> ModelContext {
        return ModelContext(container: self, subspace: subspace)
    }

    /// Creates a main model context with a path.
    ///
    /// - Parameter path: Firestore-style path.
    /// - Returns: A new ModelContext instance.
    @MainActor
    public func mainContext(path: String) -> ModelContext {
        return ModelContext(container: self, path: path)
    }

    /// Creates a background model context.
    ///
    /// This context can be used for async/background operations.
    ///
    /// - Parameter subspace: The subspace for this context.
    /// - Returns: A new ModelContext instance.
    public func makeContext(subspace: Subspace) -> ModelContext {
        return ModelContext(container: self, subspace: subspace)
    }

    /// Creates a background model context with a path.
    ///
    /// - Parameter path: Firestore-style path.
    /// - Returns: A new ModelContext instance.
    public func makeContext(path: String) -> ModelContext {
        return ModelContext(container: self, path: path)
    }
}
