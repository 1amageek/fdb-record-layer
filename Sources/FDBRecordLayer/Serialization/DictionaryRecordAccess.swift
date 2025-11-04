import Foundation
import FoundationDB

/// RecordAccess implementation for dictionary-based records
///
/// DictionaryRecordAccess provides backward compatibility with the legacy
/// dictionary-based record storage.
///
/// **Record Format:**
/// ```swift
/// let record: [String: Any] = [
///     "_type": "User",
///     "id": 1,
///     "name": "Alice",
///     "email": "alice@example.com"
/// ]
/// ```
///
/// **Features:**
/// - Supports dot notation for nested fields: "user.address.city"
/// - Automatic type conversion to TupleElement
/// - JSON serialization
///
/// **Usage:**
/// ```swift
/// let dictionaryAccess = DictionaryRecordAccess()
///
/// let recordStore = try RecordStore(
///     database: database,
///     subspace: subspace,
///     metaData: metaData,
///     recordAccess: dictionaryAccess
/// )
/// ```
public struct DictionaryRecordAccess: RecordAccess {
    public typealias Record = [String: Any]

    public init() {}

    // MARK: - RecordAccess

    public func recordTypeName(for record: [String: Any]) -> String {
        return record["_type"] as? String ?? "Unknown"
    }

    public func extractField(
        from record: [String: Any],
        fieldName: String
    ) throws -> [any TupleElement] {
        // Support dot notation: "user.address.city"
        let components = fieldName.split(separator: ".")
        var current: Any = record

        for component in components {
            guard let dict = current as? [String: Any],
                  let value = dict[String(component)] else {
                throw RecordLayerError.invalidKey("Field not found: \(fieldName)")
            }
            current = value
        }

        // Convert to TupleElement
        guard let element = convertToTupleElement(current) else {
            throw RecordLayerError.invalidKey("Cannot convert to TupleElement: \(current)")
        }

        return [element]
    }

    public func serialize(_ record: [String: Any]) throws -> FDB.Bytes {
        do {
            // Use JSONSerialization for better compatibility with Any types
            let data = try JSONSerialization.data(withJSONObject: record, options: [])
            return Array(data)
        } catch {
            throw RecordLayerError.serializationFailed("Dictionary serialization failed: \(error)")
        }
    }

    public func deserialize(_ bytes: FDB.Bytes) throws -> [String: Any] {
        do {
            let data = Data(bytes)
            guard let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                throw RecordLayerError.deserializationFailed("Not a dictionary")
            }
            return dict
        } catch {
            throw RecordLayerError.deserializationFailed("Dictionary deserialization failed: \(error)")
        }
    }

    // MARK: - Helper

    private func convertToTupleElement(_ value: Any) -> (any TupleElement)? {
        switch value {
        case let int as Int:
            return Int64(int)
        case let int64 as Int64:
            return int64
        case let int32 as Int32:
            return Int64(int32)
        case let int16 as Int16:
            return Int64(int16)
        case let int8 as Int8:
            return Int64(int8)
        case let uint as UInt:
            return Int64(uint)
        case let uint64 as UInt64:
            return Int64(uint64)
        case let uint32 as UInt32:
            return Int64(uint32)
        case let uint16 as UInt16:
            return Int64(uint16)
        case let uint8 as UInt8:
            return Int64(uint8)
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let data as Data:
            return Array(data)
        case let bytes as [UInt8]:
            return bytes
        case let double as Double:
            // Convert double to string to preserve precision
            return String(double)
        case let float as Float:
            return String(float)
        default:
            return nil
        }
    }
}
