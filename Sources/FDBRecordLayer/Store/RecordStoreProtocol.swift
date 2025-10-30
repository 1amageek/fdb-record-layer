import Foundation
import FoundationDB

/// Protocol defining the record store interface
///
/// This protocol allows for different implementations and easy mocking in tests.
public protocol RecordStoreProtocol: Sendable {
    /// The record type this store handles
    associatedtype Record: Sendable

    /// Get the metadata for this store
    var metaData: RecordMetaData { get }

    /// Get the subspace for this store
    var subspace: Subspace { get }

    /// Save a record
    /// - Parameters:
    ///   - record: The record to save
    ///   - context: The transaction context
    func saveRecord(_ record: Record, context: RecordContext) async throws

    /// Load a record by primary key
    /// - Parameters:
    ///   - primaryKey: The primary key tuple
    ///   - context: The transaction context
    /// - Returns: The record, or nil if not found
    func loadRecord(primaryKey: Tuple, context: RecordContext) async throws -> Record?

    /// Delete a record by primary key
    /// - Parameters:
    ///   - primaryKey: The primary key tuple
    ///   - context: The transaction context
    func deleteRecord(primaryKey: Tuple, context: RecordContext) async throws

    /// Get index state
    /// - Parameters:
    ///   - indexName: The index name
    ///   - context: The transaction context
    /// - Returns: The index state
    func getIndexState(_ indexName: String, context: RecordContext) async throws -> IndexState

    /// Set index state
    /// - Parameters:
    ///   - indexName: The index name
    ///   - state: The new state
    ///   - context: The transaction context
    func setIndexState(_ indexName: String, state: IndexState, context: RecordContext)
}
