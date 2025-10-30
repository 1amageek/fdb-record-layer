import Foundation
import FoundationDB

/// Protocol for serializing records to/from bytes
///
/// RecordSerializer handles the conversion between in-memory record representations
/// and byte arrays suitable for storage in FoundationDB.
public protocol RecordSerializer<Record>: Sendable {
    /// The record type this serializer handles
    associatedtype Record: Sendable

    /// Serialize a record to bytes
    /// - Parameter record: The record to serialize
    /// - Returns: The serialized bytes
    /// - Throws: RecordLayerError.serializationFailed if serialization fails
    func serialize(_ record: Record) throws -> FDB.Bytes

    /// Deserialize bytes to a record
    /// - Parameter bytes: The bytes to deserialize
    /// - Returns: The deserialized record
    /// - Throws: RecordLayerError.deserializationFailed if deserialization fails
    func deserialize(_ bytes: FDB.Bytes) throws -> Record

    /// Validate serialization round-trip
    /// - Parameter record: The record to validate
    /// - Throws: RecordLayerError.serializationValidationFailed if validation fails
    func validateSerialization(_ record: Record) throws
}

// MARK: - Default Implementation

extension RecordSerializer where Record: Equatable {
    /// Default implementation of validation using Equatable
    public func validateSerialization(_ record: Record) throws {
        let serialized = try serialize(record)
        let deserialized = try deserialize(serialized)

        guard record == deserialized else {
            throw RecordLayerError.serializationValidationFailed(
                "Round-trip serialization produced different record"
            )
        }
    }
}
