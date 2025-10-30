import Foundation
import SwiftProtobuf

/// Protocol for accessing fields from records
///
/// This abstraction allows KeyExpression to work with different record types
/// (Protobuf, Codable, etc.) in a type-safe manner.
public protocol FieldAccessor<Record>: Sendable {
    associatedtype Record: Sendable

    /// Extract a field value from a record
    /// - Parameters:
    ///   - fieldName: The field name to extract
    ///   - record: The record to extract from
    /// - Returns: The field value as a TupleElement, or nil if not found
    func extractField(_ fieldName: String, from record: Record) -> (any TupleElement)?

    /// Extract nested field value
    /// - Parameters:
    ///   - parentField: The parent field name
    ///   - childAccessor: Accessor for the child
    ///   - record: The record
    /// - Returns: The nested value
    func extractNested<A: FieldAccessor>(
        _ parentField: String,
        childAccessor: A,
        from record: Record
    ) -> (any TupleElement)? where A.Record == Record
}

// MARK: - Protobuf Field Accessor

/// Field accessor for SwiftProtobuf messages
public struct ProtobufFieldAccessor<M: SwiftProtobuf.Message & Sendable>: FieldAccessor {
    public typealias Record = M

    public init() {}

    public func extractField(_ fieldName: String, from record: M) -> (any TupleElement)? {
        // Use Protobuf reflection to get field value
        let mirror = Mirror(reflecting: record)

        for child in mirror.children {
            if child.label == fieldName {
                return convertToTupleElement(child.value)
            }
        }

        return nil
    }

    public func extractNested<A: FieldAccessor>(
        _ parentField: String,
        childAccessor: A,
        from record: M
    ) -> (any TupleElement)? where A.Record == M {
        // For simplicity, nested access is not yet implemented
        // This would require proper Protobuf descriptor access
        return nil
    }

    // MARK: - Private

    private func convertToTupleElement(_ value: Any) -> (any TupleElement)? {
        if let str = value as? String {
            return str
        } else if let int32 = value as? Int32 {
            return Int64(int32)
        } else if let int64 = value as? Int64 {
            return int64
        } else if let uint32 = value as? UInt32 {
            return UInt64(uint32)
        } else if let uint64 = value as? UInt64 {
            return uint64
        } else if let bool = value as? Bool {
            return bool
        } else if let float = value as? Float {
            return float
        } else if let double = value as? Double {
            return double
        } else if let bytes = value as? Data {
            return Array(bytes)
        }

        return nil
    }
}

// MARK: - Codable Field Accessor

/// Field accessor for Codable types
public struct CodableFieldAccessor<T: Codable & Sendable>: FieldAccessor {
    public typealias Record = T

    public init() {}

    public func extractField(_ fieldName: String, from record: T) -> (any TupleElement)? {
        let mirror = Mirror(reflecting: record)

        for child in mirror.children {
            if child.label == fieldName {
                return convertToTupleElement(child.value)
            }
        }

        return nil
    }

    public func extractNested<A: FieldAccessor>(
        _ parentField: String,
        childAccessor: A,
        from record: T
    ) -> (any TupleElement)? where A.Record == T {
        return nil
    }

    private func convertToTupleElement(_ value: Any) -> (any TupleElement)? {
        if let str = value as? String {
            return str
        } else if let int = value as? Int {
            return Int64(int)
        } else if let int64 = value as? Int64 {
            return int64
        } else if let uint64 = value as? UInt64 {
            return uint64
        } else if let bool = value as? Bool {
            return bool
        } else if let double = value as? Double {
            return double
        }

        return nil
    }
}
