import Foundation
import FDBRecordLayer
import SwiftProtobuf
import FoundationDB

/// Recordable conformance for User
///
/// This extension makes the Protobuf-generated User type compatible
/// with the FDB Record Layer's type-safe API.
extension User: Recordable {
    /// Record type name (must match metadata)
    public static var recordName: String {
        return "User"
    }

    /// Primary key fields
    public static var primaryKeyFields: [String] {
        return ["user_id"]
    }

    /// All fields (for serialization)
    public static var allFields: [String] {
        return ["user_id", "name", "email", "age"]
    }

    /// Field number mapping
    public static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "user_id": return 1
        case "name": return 2
        case "email": return 3
        case "age": return 4
        default: return nil
        }
    }

    /// Serialize to Protobuf
    public func toProtobuf() throws -> Data {
        return try self.serializedData()
    }

    /// Deserialize from Protobuf
    public static func fromProtobuf(_ data: Data) throws -> User {
        return try User(serializedData: data)
    }

    /// Extract field value for indexing
    public func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "user_id":
            return [self.userID]
        case "name":
            return [self.name]
        case "email":
            return [self.email]
        case "age":
            return [self.age]
        default:
            return []
        }
    }

    /// Extract primary key as Tuple
    public func extractPrimaryKey() -> Tuple {
        return Tuple(self.userID)
    }

    /// Field name mapping using KeyPath
    public static func fieldName<Value>(for keyPath: KeyPath<User, Value>) -> String {
        switch keyPath {
        case \User.userID:
            return "user_id"
        case \User.name:
            return "name"
        case \User.email:
            return "email"
        case \User.age:
            return "age"
        default:
            fatalError("Unknown keyPath: \(keyPath)")
        }
    }
}
