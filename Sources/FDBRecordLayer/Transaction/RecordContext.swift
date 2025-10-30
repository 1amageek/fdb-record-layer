import Foundation
import FoundationDB
import Synchronization

/// Record context managing a single transaction
///
/// RecordContext wraps a FoundationDB transaction and manages its lifecycle.
/// It ensures proper cleanup and prevents use after commit/cancel.
public final class RecordContext: Sendable {
    // MARK: - Properties

    private let transaction: any TransactionProtocol
    private let isClosed: Mutex<Bool>

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

    /// Get the underlying transaction
    ///
    /// - Returns: The wrapped transaction
    /// - Warning: The transaction should only be used within the scope of this context
    public func getTransaction() -> any TransactionProtocol {
        return transaction
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
