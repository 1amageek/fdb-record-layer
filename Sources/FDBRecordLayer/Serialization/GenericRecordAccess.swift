import Foundation
import FoundationDB

/// Generic RecordAccess implementation using the Recordable protocol
///
/// For any type conforming to the `Recordable` protocol, this class enables
/// automatic serialization/deserialization.
///
/// **Usage Example**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///     var email: String
///     var name: String
/// }
///
/// // Can be used automatically if conforming to Recordable
/// let recordAccess = GenericRecordAccess<User>()
///
/// // Serialize
/// let data = try recordAccess.serialize(user)
///
/// // Deserialize
/// let user = try recordAccess.deserialize(data)
/// ```
///
/// **Design Intent**:
/// - Reuse the `Recordable` protocol implementation
/// - If a macro implements `Recordable`, it can automatically be used as `RecordAccess`
/// - Reduce boilerplate code
public struct GenericRecordAccess<Record: Recordable>: RecordAccess {
    /// Default initializer
    ///
    /// Can be used without special configuration for any type
    /// conforming to the `Recordable` protocol.
    public init() {}

    // MARK: - RecordAccess Implementation

    /// Get the record type name
    public func recordName(for record: Record) -> String {
        return Record.recordName
    }

    /// Extract a single field value
    public func extractField(
        from record: Record,
        fieldName: String
    ) throws -> [any TupleElement] {
        return record.extractField(fieldName)
    }

    /// Serialize a record to bytes
    public func serialize(_ record: Record) throws -> FDB.Bytes {
        let data = try record.toProtobuf()
        return FDB.Bytes(data)
    }

    /// Deserialize bytes to a record
    public func deserialize(_ bytes: FDB.Bytes) throws -> Record {
        let data = Data(bytes)
        return try Record.fromProtobuf(data)
    }

    /// Check if this RecordAccess supports reconstruction
    public var supportsReconstruction: Bool {
        return true  // GenericRecordAccess always supports reconstruction
    }

    /// Reconstruct a record from index key and value
    ///
    /// This implementation uses the Recordable.reconstruct() method to
    /// rebuild records from covering index data without fetching from storage.
    ///
    /// **Requirements**:
    /// - The Record type must implement Recordable.reconstruct()
    /// - The index must have coveringFields defined
    ///
    /// **Performance**:
    /// - 2-10x faster than regular index scan (no getValue() calls)
    ///
    /// - Parameters:
    ///   - indexKey: Index key (unpacked tuple)
    ///   - indexValue: Index value (packed covering fields)
    ///   - index: Index definition
    ///   - primaryKeyExpression: Primary key expression
    /// - Returns: Reconstructed record
    /// - Throws: RecordLayerError if reconstruction fails
    public func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record {
        return try Record.reconstruct(
            indexKey: indexKey,
            indexValue: indexValue,
            index: index,
            primaryKeyExpression: primaryKeyExpression
        )
    }

    // MARK: - Additional Helpers (not in RecordAccess protocol)

    /// Extract primary key
    ///
    /// Not included in the RecordAccess protocol, but used by RecordStore.
    ///
    /// - Parameter record: Record
    /// - Returns: Primary key Tuple
    public func extractPrimaryKey(from record: Record) -> Tuple {
        return record.extractPrimaryKey()
    }
}

// MARK: - Convenience Methods

extension GenericRecordAccess {
    /// Get record type name (static method)
    ///
    /// Can retrieve the record type name without creating an instance.
    ///
    /// - Returns: Record type name
    public static var recordName: String {
        return Record.recordName
    }

    /// Get list of primary key fields
    ///
    /// - Returns: List of primary key field names
    public static var primaryKeyFields: [String] {
        return Record.primaryKeyFields
    }

    /// Get list of all field names
    ///
    /// - Returns: List of field names
    public static var allFields: [String] {
        return Record.allFields
    }
}
