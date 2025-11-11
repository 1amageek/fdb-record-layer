import Foundation
import FoundationDB
import Synchronization

/// Record context managing a single transaction
///
/// RecordContext wraps a FoundationDB transaction and manages its lifecycle.
/// It ensures proper cleanup and prevents use after commit/cancel.
///
/// **Metadata Storage:**
/// RecordContext can store arbitrary metadata for use by index maintainers.
/// This is used by Version Index to store expected versions for optimistic locking.
public final class RecordContext: Sendable {
    // MARK: - Properties

    private let transaction: any TransactionProtocol
    private let isClosed: Mutex<Bool>

    /// Metadata storage for context-specific data
    private let metadata: Mutex<[String: Any]>

    /// Pre-commit hooks (executed before transaction commits)
    private let preCommitHooks: Mutex<[any CommitHook]>

    /// Post-commit hooks (executed after transaction commits)
    private let postCommitHooks: Mutex<[@Sendable () async throws -> Void]>

    /// Whether this context has been closed (committed or cancelled)
    public var closed: Bool {
        return isClosed.withLock { $0 }
    }

    // MARK: - Initialization

    /// Create a context with an existing transaction
    /// - Parameter transaction: The transaction to wrap
    public init(transaction: any TransactionProtocol) {
        self.transaction = transaction
        self.isClosed = Mutex(false)
        self.metadata = Mutex([:])
        self.preCommitHooks = Mutex([])
        self.postCommitHooks = Mutex([])
    }

    /// Create a new context with a new transaction
    /// - Parameter database: The database to create a transaction from
    /// - Throws: If transaction creation fails
    public convenience init(database: any DatabaseProtocol) throws {
        let transaction = try database.createTransaction()
        self.init(transaction: transaction)
    }

    // MARK: - Commit Hooks

    /// Add a pre-commit hook that executes before transaction commits
    /// - Parameter hook: The hook to execute
    public func addPreCommitHook(_ hook: any CommitHook) {
        preCommitHooks.withLock { hooks in
            hooks.append(hook)
        }
    }

    /// Add a post-commit hook that executes after transaction commits successfully
    /// - Parameter closure: The closure to execute after commit
    public func addPostCommitHook(_ closure: @escaping @Sendable () async throws -> Void) {
        postCommitHooks.withLock { hooks in
            hooks.append(closure)
        }
    }

    // MARK: - Transaction Operations

    /// Commit the transaction
    /// - Throws: RecordLayerError.contextAlreadyClosed if already closed
    /// - Throws: FDB errors if commit fails
    public func commit() async throws {
        // Check if closed
        let alreadyClosed = isClosed.withLock { $0 }
        if alreadyClosed {
            throw RecordLayerError.contextAlreadyClosed
        }

        // Execute pre-commit hooks
        let preHooks = preCommitHooks.withLock { Array($0) }
        for hook in preHooks {
            try await hook.execute(context: self)
        }

        // Commit transaction
        _ = try await transaction.commit()

        // Mark as closed
        isClosed.withLock { $0 = true }

        // Execute post-commit hooks
        let postHooks = postCommitHooks.withLock { Array($0) }
        for hook in postHooks {
            try await hook()
        }
    }

    /// Cancel the transaction
    ///
    /// This is safe to call multiple times or on an already-closed context.
    public func cancel() {
        isClosed.withLock { closed in
            guard !closed else { return }
            transaction.cancel()
            closed = true
        }
    }

    /// Mark the context as closed without cancelling the transaction
    ///
    /// This is used when the transaction is managed externally (e.g., by withTransaction)
    /// and we want to prevent the deinit from cancelling it.
    internal func markClosed() {
        isClosed.withLock { $0 = true }
    }

    /// Get the underlying transaction
    ///
    /// - Returns: The wrapped transaction
    /// - Warning: The transaction should only be used within the scope of this context
    public func getTransaction() -> any TransactionProtocol {
        return transaction
    }

    // MARK: - Metadata Management

    /// Set metadata value for a key
    /// - Parameters:
    ///   - value: The value to store
    ///   - key: The key to store the value under
    public func setMetadata<T>(_ value: T, forKey key: String) {
        metadata.withLock { (dict: inout [String: Any]) in
            dict[key] = value
        }
    }

    /// Get metadata value for a key
    /// - Parameter key: The key to retrieve
    /// - Returns: The value if it exists, nil otherwise
    public func getMetadata<T>(forKey key: String) -> T? {
        return metadata.withLock { dict in
            dict[key] as? T
        }
    }

    /// Remove metadata value for a key
    /// - Parameter key: The key to remove
    public func removeMetadata(forKey key: String) {
        _ = metadata.withLock { dict in
            dict.removeValue(forKey: key)
        }
    }

    // MARK: - Transaction Options

    /// Set transaction timeout
    ///
    /// Sets a timeout in milliseconds which, when elapsed, will cause the transaction
    /// automatically to be cancelled.
    ///
    /// - Parameter milliseconds: Timeout in milliseconds (0 = disable all timeouts)
    /// - Throws: FDB errors if setting the option fails
    public func setTimeout(milliseconds: Int) throws {
        guard milliseconds >= 0 else {
            throw RecordLayerError.invalidArgument("Timeout must be non-negative")
        }

        // Convert Int to Bytes (little-endian 64-bit integer)
        var value = Int64(milliseconds)
        let bytes = withUnsafeBytes(of: &value) { Array($0) }

        try transaction.setOption(to: bytes, forOption: .timeout)
    }

    /// Disable read-your-writes isolation for this transaction
    ///
    /// Reads performed by this transaction will not see any prior mutations that occurred
    /// in that transaction, instead seeing the value which was in the database at the
    /// transaction's read version.
    ///
    /// This option may provide a small performance benefit and reduces memory usage for
    /// transactions that read and write many keys.
    ///
    /// - Throws: FDB errors if setting the option fails
    /// - Warning: Must be called before performing any reads or writes
    public func disableReadYourWrites() throws {
        try transaction.setOption(to: nil, forOption: .readYourWritesDisable)
    }

    // MARK: - Deinitialization

    deinit {
        // Ensure transaction is cancelled if not committed
        isClosed.withLock { closed in
            guard !closed else { return }
            transaction.cancel()
            closed = true
        }
    }
}
