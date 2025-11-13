import Foundation
import FoundationDB
import Logging

/// RecordStore conformance to AnyRecordStore for migration operations
///
/// Provides type-erased access to RecordStore functionality, enabling
/// migration operations without exposing the generic Record type.
extension RecordStore: AnyRecordStore {
    /// The record type name
    public var recordName: String {
        Record.recordName
    }

    // database is now internal in RecordStore, so we can access it directly via extension

    /// Build a specific index
    ///
    /// Creates an OnlineIndexer internally with the correct Record type.
    ///
    /// **Implementation**:
    /// 1. Find index in schema
    /// 2. Create RecordAccess with concrete Record type
    /// 3. Create IndexStateManager
    /// 4. Create OnlineIndexer with concrete Record type
    /// 5. Build index
    ///
    /// - Parameters:
    ///   - indexName: Name of the index to build
    ///   - batchSize: Number of records per batch (default: 1000)
    ///   - throttleDelayMs: Delay between batches in milliseconds (default: 10)
    /// - Throws: RecordLayerError if index not found or build fails
    public func buildIndex(
        indexName: String,
        batchSize: Int = 1000,
        throttleDelayMs: UInt64 = 10
    ) async throws {
        // 1. Find index
        guard let index = schema.index(named: indexName) else {
            throw RecordLayerError.indexNotFound("Index '\(indexName)' not found in schema")
        }

        // 2. Create RecordAccess with concrete Record type
        let recordAccess = GenericRecordAccess<Record>()

        // 3. Create IndexStateManager
        let indexStateManager = IndexStateManager(
            database: self.database,
            subspace: self.subspace
        )

        // 4. Create logger
        let logger = Logger(label: "com.fdb.recordlayer.migration.indexer")

        // 5. Create OnlineIndexer with concrete Record type
        let indexer = OnlineIndexer(
            database: self.database,
            subspace: self.subspace,
            schema: self.schema,
            entityName: Record.recordName,
            index: index,
            recordAccess: recordAccess,
            indexStateManager: indexStateManager,
            batchSize: batchSize,
            throttleDelayMs: throttleDelayMs,
            logger: logger
        )

        // 6. Build index
        try await indexer.buildIndex(clearFirst: false)
    }

    /// Scan all records with a predicate
    ///
    /// - Parameter predicate: Predicate function (operates on serialized Data)
    /// - Returns: Async throwing stream of matching records (as Data)
    /// - Throws: RecordLayerError if scan fails
    public func scanRecords(
        where predicate: @Sendable @escaping (Data) -> Bool
    ) -> AsyncThrowingStream<Data, Error> {
        let recordAccess = GenericRecordAccess<Record>()

        return AsyncThrowingStream(Data.self) { continuation in
            Task {
                do {
                    for try await record in self.scan() {
                        let bytes = try recordAccess.serialize(record)
                        let data = Data(bytes)

                        if predicate(data) {
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                } catch {
                    // Propagate error to caller
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
