import Foundation
import FoundationDB
import SwiftProtobuf

/// Protobuf message field extractor
///
/// ProtobufFieldExtractor provides a mapping from field names to field values
/// for Protobuf messages. This mapping must be defined manually for each message type.
///
/// **Implementation Methods:**
/// 1. **Manual mapping (Recommended)**: Define extractors for each message type
/// 2. Code generation: Auto-generate from .proto files (future enhancement)
/// 3. Reflection: Use SwiftProtobuf reflection API (performance impact)
///
/// **Usage:**
/// ```swift
/// extension ProtobufFieldExtractor where M == User {
///     public static func forUser() -> ProtobufFieldExtractor<User> {
///         return ProtobufFieldExtractor(extractors: [
///             "userID": { user in [user.userID] },
///             "name": { user in [user.name] },
///             "email": { user in [user.email] }
///         ])
///     }
/// }
/// ```
public struct ProtobufFieldExtractor<M: SwiftProtobuf.Message & Sendable>: Sendable {
    private let extractors: [String: @Sendable (M) throws -> [any TupleElement]]

    /// Initialize with field extractors
    ///
    /// - Parameter extractors: Dictionary mapping field names to extractor closures
    public init(
        extractors: [String: @Sendable (M) throws -> [any TupleElement]]
    ) {
        self.extractors = extractors
    }

    /// Extract field value from a Protobuf message
    ///
    /// - Parameters:
    ///   - record: The Protobuf message
    ///   - fieldPath: Field name (supports dot notation for nested fields)
    /// - Returns: Array of tuple elements
    /// - Throws: RecordLayerError.invalidKey if field not found
    public func extract(
        from record: M,
        fieldPath: String
    ) throws -> [any TupleElement] {
        // Check for direct field mapping first
        if let extractor = extractors[fieldPath] {
            return try extractor(record)
        }

        // TODO (Phase 5): Support dot notation for nested Protobuf fields
        // For now, if the field path contains dots, it must be explicitly
        // defined in the extractors dictionary
        if fieldPath.contains(".") {
            throw RecordLayerError.invalidKey(
                "Nested field '\(fieldPath)' not found in extractors for \(M.self). " +
                "Dot notation for nested Protobuf fields requires explicit mapping."
            )
        }

        throw RecordLayerError.invalidKey("Unknown field: \(fieldPath) in \(M.self)")
    }
}

/// RecordAccess implementation for Protobuf messages
///
/// ProtobufRecordAccess provides type-safe access to Protobuf message fields
/// using a manually-defined ProtobufFieldExtractor.
///
/// **Usage:**
/// ```swift
/// let userAccess = ProtobufRecordAccess(
///     typeName: "User",
///     fieldExtractor: .forUser()
/// )
///
/// let recordStore = try RecordStore(
///     database: database,
///     subspace: subspace,
///     metaData: metaData,
///     recordAccess: userAccess
/// )
/// ```
public struct ProtobufRecordAccess<M: SwiftProtobuf.Message & Sendable>: RecordAccess {
    public typealias Record = M

    private let typeName: String
    private let fieldExtractor: ProtobufFieldExtractor<M>

    /// Initialize Protobuf record access
    ///
    /// - Parameters:
    ///   - typeName: Record type name (must match RecordMetaData)
    ///   - fieldExtractor: Field extractor for this message type
    public init(
        typeName: String,
        fieldExtractor: ProtobufFieldExtractor<M>
    ) {
        self.typeName = typeName
        self.fieldExtractor = fieldExtractor
    }

    // MARK: - RecordAccess

    public func recordTypeName(for record: M) -> String {
        return typeName
    }

    public func extractField(
        from record: M,
        fieldName: String
    ) throws -> [any TupleElement] {
        return try fieldExtractor.extract(from: record, fieldPath: fieldName)
    }

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
}
