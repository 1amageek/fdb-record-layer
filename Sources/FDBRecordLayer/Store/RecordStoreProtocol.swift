import Foundation
import FoundationDB

/// Protocol defining the record store interface
///
/// This protocol allows for different implementations and easy mocking in tests.
internal protocol RecordStoreProtocol: Sendable {
    /// The record type this store handles
    associatedtype Record: Sendable

    /// Get the schema for this store
    var schema: Schema { get }

    /// Get the subspace for this store
    var subspace: Subspace { get }

    /// Save a record
    /// - Parameters:
    ///   - record: The record to save
    ///   - context: The transaction context
    func save(_ record: Record, context: TransactionContext) async throws

    /// Fetch a record by primary key
    /// - Parameters:
    ///   - primaryKey: The primary key tuple
    ///   - context: The transaction context
    /// - Returns: The record, or nil if not found
    func fetch(primaryKey: Tuple, context: TransactionContext) async throws -> Record?

    /// Delete a record by primary key
    /// - Parameters:
    ///   - primaryKey: The primary key tuple
    ///   - context: The transaction context
    func delete(primaryKey: Tuple, context: TransactionContext) async throws

    /// Get index state
    /// - Parameters:
    ///   - indexName: The index name
    ///   - context: The transaction context
    /// - Returns: The index state
    func indexState(of indexName: String, context: TransactionContext) async throws -> IndexState
}
