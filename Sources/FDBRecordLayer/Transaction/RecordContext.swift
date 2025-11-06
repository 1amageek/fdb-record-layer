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
    }

    /// Create a new context with a new transaction
    /// - Parameter database: The database to create a transaction from
    /// - Throws: If transaction creation fails
    public convenience init(database: any DatabaseProtocol) throws {
        let transaction = try database.createTransaction()
        self.init(transaction: transaction)
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

        _ = try await transaction.commit()

        isClosed.withLock { $0 = true }
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
