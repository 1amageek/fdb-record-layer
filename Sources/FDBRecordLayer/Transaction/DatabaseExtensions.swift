import Foundation
import FoundationDB

extension DatabaseProtocol {
    /// Execute a block within a record context with automatic retry
    ///
    /// This is a convenience method that creates a RecordContext and automatically
    /// handles transaction lifecycle (commit/cancel) and retries.
    ///
    /// - Parameter block: The block to execute with the context
    /// - Returns: The value returned by the block
    /// - Throws: Errors from the block or transaction failures
    public func withRecordContext<T: Sendable>(
        _ block: @Sendable (RecordContext) async throws -> T
    ) async throws -> T {
        return try await withTransaction { transaction in
            let context = RecordContext(transaction: transaction)
            return try await block(context)
        }
    }
}
