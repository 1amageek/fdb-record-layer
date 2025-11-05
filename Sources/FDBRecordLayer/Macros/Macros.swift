import Foundation

/// Marks a struct as a persistable record type
///
/// This macro generates all necessary protocol conformances and methods
/// for the record to be stored in FDB Record Layer.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///     var email: String
///     var name: String
/// }
/// ```
///
/// **Generated Code**:
/// - `Recordable` protocol conformance
/// - Protobuf serialization methods
/// - Field extraction methods
/// - Primary key extraction
@attached(member, names: named(recordTypeName), named(primaryKeyFields), named(allFields), named(fieldNumber), named(toProtobuf), named(fromProtobuf), named(extractField), named(extractPrimaryKey), named(fieldName))
@attached(extension, conformances: Recordable, names: named(recordTypeName), named(primaryKeyFields), named(allFields), named(fieldNumber), named(toProtobuf), named(fromProtobuf), named(extractField), named(extractPrimaryKey), named(fieldName))
public macro Recordable() = #externalMacro(module: "FDBRecordLayerMacros", type: "RecordableMacro")

/// Marks a property as the primary key
///
/// Every `@Recordable` struct must have exactly one `@PrimaryKey` property.
/// The primary key can be a single field or multiple fields (compound key).
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64  // Single primary key
/// }
///
/// @Recordable
/// struct TenantUser {
///     @PrimaryKey var tenantID: String
///     @PrimaryKey var userID: Int64    // Compound primary key
/// }
/// ```
@attached(peer)
public macro PrimaryKey() = #externalMacro(module: "FDBRecordLayerMacros", type: "PrimaryKeyMacro")

/// Marks a property as transient (not persisted)
///
/// Transient properties are excluded from serialization and will not be stored in the database.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///     var name: String
///
///     @Transient var isLoggedIn: Bool = false  // Not stored
/// }
/// ```
@attached(peer)
public macro Transient() = #externalMacro(module: "FDBRecordLayerMacros", type: "TransientMacro")

/// Provides a default value for a property
///
/// If a field is not present during deserialization, the default value will be used.
/// This is useful for schema evolution when adding new fields.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///     var name: String
///
///     @Default(value: Date())
///     var createdAt: Date
///
///     @Default(value: 0)
///     var loginCount: Int
/// }
/// ```
@attached(peer)
public macro Default(value: Any) = #externalMacro(module: "FDBRecordLayerMacros", type: "DefaultMacro")

/// Defines an index on specified fields
///
/// Indexes improve query performance for specific field combinations.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     #Index<User>([\.email])
///     #Index<User>([\.country, \.city], name: "location_index")
///
///     @PrimaryKey var userID: Int64
///     var email: String
///     var country: String
///     var city: String
/// }
/// ```
@freestanding(declaration, names: arbitrary)
public macro Index<T>(_ keyPaths: [KeyPath<T, Any>], name: String? = nil) = #externalMacro(module: "FDBRecordLayerMacros", type: "IndexMacro")

/// Defines a unique index on specified fields
///
/// Unique indexes enforce uniqueness constraint on the specified fields.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     #Unique<User>([\.email])  // Email must be unique
///
///     @PrimaryKey var userID: Int64
///     var email: String
/// }
/// ```
@freestanding(declaration, names: arbitrary)
public macro Unique<T>(_ keyPaths: [KeyPath<T, Any>], name: String? = nil) = #externalMacro(module: "FDBRecordLayerMacros", type: "UniqueMacro")

/// Explicitly specifies the order of fields for Protobuf compatibility
///
/// By default, fields are numbered in declaration order. Use this macro
/// only when you need to maintain compatibility with existing Protobuf schemas.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     #FieldOrder<User>([\.userID, \.email, \.name, \.age])
///
///     @PrimaryKey var userID: Int64  // field_number = 1
///     var email: String               // field_number = 2
///     var name: String                // field_number = 3
///     var age: Int                    // field_number = 4
/// }
/// ```
@freestanding(declaration, names: arbitrary)
public macro FieldOrder<T>(_ keyPaths: [KeyPath<T, Any>]) = #externalMacro(module: "FDBRecordLayerMacros", type: "FieldOrderMacro")

/// Defines a relationship to another record type
///
/// Relationships maintain referential integrity between record types.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///
///     @Relationship(deleteRule: .cascade, inverse: \Order.userID)
///     var orders: [Int64] = []
/// }
///
/// @Recordable
/// struct Order {
///     @PrimaryKey var orderID: Int64
///
///     @Relationship(inverse: \User.orders)
///     var userID: Int64
/// }
/// ```
@attached(peer)
public macro Relationship(deleteRule: DeleteRule = .noAction, inverse: AnyKeyPath) = #externalMacro(module: "FDBRecordLayerMacros", type: "RelationshipMacro")

/// Provides metadata about a property for schema evolution
///
/// Used to track field renames and other schema changes.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///
///     @Attribute(originalName: "username")
///     var name: String  // Renamed from "username"
/// }
/// ```
@attached(peer)
public macro Attribute(originalName: String) = #externalMacro(module: "FDBRecordLayerMacros", type: "AttributeMacro")
