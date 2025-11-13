import Foundation
import FoundationDB

/// Type-erased RecordStore wrapper for migration operations
///
/// Provides type-safe access to RecordStore operations without exposing
/// the generic Record type.
///
/// **Design Rationale**:
/// - Avoids `Any` casting by using protocol methods
/// - Enables type-safe operations without knowing concrete Record type
/// - Compatible with existing RecordStore implementations
///
/// **Usage**:
/// ```swift
/// let userStore: RecordStore<User> = ...
/// let anyStore: any AnyRecordStore = userStore
///
/// // Build index without knowing Record type
/// try await anyStore.buildIndex(indexName: "email_index", batchSize: 1000, throttleDelayMs: 10)
/// ```
public protocol AnyRecordStore: Sendable {
    /// The record type name
    var recordName: String { get }

    /// Get the record subspace
    var recordSubspace: Subspace { get }

    /// Get the index subspace
    var indexSubspace: Subspace { get }

    /// Get the root subspace
    var subspace: Subspace { get }

    /// Get the schema
    var schema: Schema { get }

    /// Build a specific index
    ///
    /// Creates an OnlineIndexer internally with the correct Record type.
    ///
    /// - Parameters:
    ///   - indexName: Name of the index to build
    ///   - batchSize: Number of records per batch (default: 1000)
    ///   - throttleDelayMs: Delay between batches in milliseconds (default: 10)
    /// - Throws: RecordLayerError if index not found or build fails
    func buildIndex(
        indexName: String,
        batchSize: Int,
        throttleDelayMs: UInt64
    ) async throws

    /// Scan all records with a predicate
    ///
    /// - Parameter predicate: Predicate function (operates on serialized Data)
    /// - Returns: Async throwing stream of matching records (as Data)
    /// - Throws: RecordLayerError if scan fails (propagated through stream)
    func scanRecords(
        where predicate: @Sendable @escaping (Data) -> Bool
    ) -> AsyncThrowingStream<Data, Error>

    /// Get the database instance
    ///
    /// **Internal use only**: For creating IndexStateManager
    var database: any DatabaseProtocol { get }
}
