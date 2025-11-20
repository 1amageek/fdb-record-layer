import Foundation
import FoundationDB
import Synchronization

/// Internal transaction context for managing transaction lifecycle
///
/// TransactionContext wraps a FoundationDB transaction and provides
/// lifecycle management including commit, rollback, and metadata storage.
///
/// **Note**: This is an internal implementation. For high-level CRUD operations,
/// use `RecordContext` instead.
internal final class TransactionContext: Sendable {
    /// The underlying FoundationDB transaction
    private let transaction: TransactionProtocol

    // MARK: - Initialization

    /// Creates a transaction context from an existing transaction
    ///
    /// - Parameter transaction: The FoundationDB transaction to wrap
    internal init(transaction: TransactionProtocol) {
        self.transaction = transaction
    }

    /// Creates a new transaction context from a database
    ///
    /// - Parameter database: The database to create a transaction from
    /// - Throws: RecordLayerError if transaction creation fails
    internal convenience init(database: any DatabaseProtocol) throws {
        let transaction = try database.createTransaction()
        self.init(transaction: transaction)
    }

    // MARK: - Transaction Access

    /// Gets the underlying transaction
    ///
    /// - Returns: The underlying FoundationDB transaction
    internal func getTransaction() -> TransactionProtocol {
        return transaction
    }

    // MARK: - Transaction Operations

    /// Gets a value from the database
    ///
    /// - Parameters:
    ///   - key: The key to fetch
    ///   - snapshot: Whether to use snapshot read (no conflict tracking)
    /// - Returns: The value bytes, or nil if not found
    /// - Throws: RecordLayerError if read fails
    internal func getValue(for key: FDB.Bytes, snapshot: Bool = false) async throws -> FDB.Bytes? {
        return try await transaction.getValue(for: key, snapshot: snapshot)
    }

    /// Sets a value in the database
    ///
    /// - Parameters:
    ///   - value: The value bytes to store
    ///   - key: The key to store at
    internal func setValue(_ value: FDB.Bytes, for key: FDB.Bytes) {
        transaction.setValue(value, for: key)
    }

    /// Clears a key from the database
    ///
    /// - Parameter key: The key to clear
    internal func clear(key: FDB.Bytes) {
        transaction.clear(key: key)
    }

    /// Clears a range of keys from the database
    ///
    /// - Parameters:
    ///   - beginKey: The start of the range (inclusive)
    ///   - endKey: The end of the range (exclusive)
    internal func clearRange(beginKey: FDB.Bytes, endKey: FDB.Bytes) {
        transaction.clearRange(beginKey: beginKey, endKey: endKey)
    }

    /// Gets a range of key-value pairs
    ///
    /// - Parameters:
    ///   - beginSelector: The start key selector
    ///   - endSelector: The end key selector
    ///   - snapshot: Whether to use snapshot read
    /// - Returns: An async sequence of key-value pairs
    internal func getRange(
        beginSelector: FDB.KeySelector,
        endSelector: FDB.KeySelector,
        snapshot: Bool = false
    ) -> FDB.AsyncKVSequence {
        return transaction.getRange(
            beginSelector: beginSelector,
            endSelector: endSelector,
            snapshot: snapshot
        )
    }

    /// Performs an atomic operation
    ///
    /// - Parameters:
    ///   - key: The key to operate on
    ///   - param: The parameter bytes for the operation
    ///   - mutationType: The type of atomic mutation
    internal func atomicOp(
        key: FDB.Bytes,
        param: FDB.Bytes,
        mutationType: FDB.MutationType
    ) {
        transaction.atomicOp(
            key: key,
            param: param,
            mutationType: mutationType
        )
    }

    // MARK: - Transaction Options

    /// Sets the transaction timeout
    ///
    /// - Parameter milliseconds: Timeout in milliseconds
    /// - Throws: RecordLayerError if setting option fails
    internal func setTimeout(_ milliseconds: Int64) throws {
        let bytes = withUnsafeBytes(of: milliseconds.littleEndian) { Array($0) }
        try transaction.setOption(to: bytes, forOption: .timeout)
    }

    /// Disables read-your-writes optimization
    ///
    /// - Throws: RecordLayerError if setting option fails
    internal func disableReadYourWrites() throws {
        try transaction.setOption(to: [], forOption: .readYourWritesDisable)
    }

    // MARK: - Commit and Rollback

    /// Commits the transaction
    ///
    /// - Throws: RecordLayerError if commit fails
    internal func commit() async throws {
        _ = try await transaction.commit()
    }

    /// Cancels the transaction (rollback)
    internal func cancel() {
        transaction.cancel()
    }
}
