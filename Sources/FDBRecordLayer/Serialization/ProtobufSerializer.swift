import Foundation
import FoundationDB
import SwiftProtobuf

/// Protobuf-based record serializer
///
/// This serializer converts SwiftProtobuf messages to/from bytes for storage.
public struct ProtobufRecordSerializer<M: SwiftProtobuf.Message & Sendable>: RecordSerializer {
    public typealias Record = M

    public init() {}

    public func serialize(_ record: M) throws -> FDB.Bytes {
        do {
            return try Array(record.serializedData())
        } catch {
            throw RecordLayerError.serializationFailed("Protobuf serialization failed: \(error)")
        }
    }

    public func deserialize(_ bytes: FDB.Bytes) throws -> M {
        do {
            return try M(serializedBytes: bytes)
        } catch {
            throw RecordLayerError.deserializationFailed("Protobuf deserialization failed: \(error)")
        }
    }

    public func validateSerialization(_ record: M) throws {
        // Protobuf messages don't have a simple way to compare for equality
        // So we just do a round-trip and check that deserialization doesn't fail
        let serialized = try serialize(record)
        _ = try deserialize(serialized)
    }
}

// MARK: - Validation

extension ProtobufRecordSerializer where M: Equatable {
    public func validateSerialization(_ record: M) throws {
        let serialized = try serialize(record)
        let deserialized = try deserialize(serialized)

        guard record == deserialized else {
            throw RecordLayerError.serializationValidationFailed(
                "Round-trip serialization produced different record"
            )
        }
    }
}
