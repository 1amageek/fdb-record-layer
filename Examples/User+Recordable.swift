import Foundation
import FDBRecordLayer
import SwiftProtobuf

/// Recordable conformance for User
///
/// This extension makes the Protobuf-generated User type compatible
/// with the FDB Record Layer's type-safe API.
extension User: Recordable {
    /// Record type name (must match metadata)
    public static var recordTypeName: String {
        return "User"
    }

    /// Primary key fields
    public static var primaryKeyFields: [String] {
        return ["user_id"]
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
