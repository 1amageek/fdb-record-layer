import Foundation
import FoundationDB

extension DatabaseProtocol {
    /// Execute a block within a record context with automatic retry
    ///
    /// This is a convenience method that creates a TransactionContext and automatically
    /// handles transaction lifecycle (commit/cancel) and retries.
    ///
    /// - Parameter block: The block to execute with the context
    /// - Returns: The value returned by the block
    /// - Throws: Errors from the block or transaction failures
    internal func withTransactionContext<T: Sendable>(
        _ block: @Sendable (TransactionContext) async throws -> T
    ) async throws -> T {
        return try await withTransaction { transaction in
            let context = TransactionContext(transaction: transaction)
            // Note: withTransaction handles commit/cancel, so we don't call it here
            return try await block(context)
        }
    }
}
