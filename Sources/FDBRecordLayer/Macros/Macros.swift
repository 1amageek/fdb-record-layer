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
///
/// // With custom record name:
/// @Recordable(recordName: "UserRecord")
/// struct User {
///     @PrimaryKey var userID: Int64
/// }
/// ```
///
/// **Parameters**:
/// - `recordName`: Optional custom name for the record type. Defaults to the struct name.
///
/// **Generated Code**:
/// - `Recordable` protocol conformance
/// - Protobuf serialization methods
/// - Field extraction methods
/// - Primary key extraction
@attached(member, names: named(recordName), named(primaryKeyFields), named(allFields), named(fieldNumber), named(toProtobuf), named(fromProtobuf), named(extractField), named(extractPrimaryKey), named(fieldName))
@attached(extension, conformances: Recordable, names: named(recordName), named(primaryKeyFields), named(allFields), named(fieldNumber), named(toProtobuf), named(fromProtobuf), named(extractField), named(extractPrimaryKey), named(fieldName), named(store), named(indexDefinitions), arbitrary)
public macro Recordable(recordName: String? = nil) = #externalMacro(module: "FDBRecordLayerMacros", type: "RecordableMacro")

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
/// Supports multiple independent indexes using variadic arguments.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     // Single field index
///     #Index<User>([\.email])
///
///     // Multiple independent indexes
///     #Index<User>([\.email], [\.username])
///
///     // Compound index (country + city combination)
///     #Index<User>([\.country, \.city])
///
///     // Named index
///     #Index<User>([\.country, \.city], name: "location_index")
///
///     @PrimaryKey var userID: Int64
///     var email: String
///     var username: String
///     var country: String
///     var city: String
/// }
/// ```
@freestanding(declaration)
public macro Index<T>(_ indices: [PartialKeyPath<T>]...) = #externalMacro(module: "FDBRecordLayerMacros", type: "IndexMacro")

/// Defines a named index on specified fields
///
/// Use this overload when you need to specify a custom index name.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     #Index<User>([\.country, \.city], name: "location_index")
///
///     @PrimaryKey var userID: Int64
///     var country: String
///     var city: String
/// }
/// ```
@freestanding(declaration)
public macro Index<T>(_ indices: [PartialKeyPath<T>], name: String) = #externalMacro(module: "FDBRecordLayerMacros", type: "IndexMacro")

/// Defines a unique index on specified fields
///
/// Unique indexes enforce uniqueness constraint on the specified fields.
/// Supports multiple independent constraints using variadic arguments.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     // Single field unique constraint
///     #Unique<User>([\.email])
///
///     // Multiple independent unique constraints
///     #Unique<User>([\.email], [\.username])
///
///     // Compound unique constraint (firstName + lastName combination)
///     #Unique<User>([\.firstName, \.lastName])
///
///     @PrimaryKey var userID: Int64
///     var email: String
///     var username: String
///     var firstName: String
///     var lastName: String
/// }
/// ```
@freestanding(declaration)
public macro Unique<T>(_ constraints: [PartialKeyPath<T>]...) = #externalMacro(module: "FDBRecordLayerMacros", type: "UniqueMacro")

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
@freestanding(declaration)
public macro FieldOrder<T>(_ keyPaths: [PartialKeyPath<T>]) = #externalMacro(module: "FDBRecordLayerMacros", type: "FieldOrderMacro")

/// Represents an element in a directory path
///
/// Can be either a string literal or a PartialKeyPath for dynamic interpolation.
///
/// **Usage**:
/// ```swift
/// #Directory<Order>(["tenants", \.accountID, "orders"], layer: .partition)
/// //                 ^^^^^^^^^  ^^^^^^^^^^      ^^^^^^^^
/// //                 String     PartialKeyPath  String
/// ```
public enum DirectoryPathElement<T> {
    case literal(String)
    case keyPath(PartialKeyPath<T>)
}

// ExpressibleByStringLiteral conformance for convenient syntax
extension DirectoryPathElement: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .literal(value)
    }
}

/// Defines a directory path using FoundationDB Directory Layer
///
/// This macro validates the directory path and layer parameter, and serves as a marker
/// for the @Recordable macro to generate type-safe store() methods.
///
/// **Basic Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     #Directory<User>(["app", "users"])
///
///     @PrimaryKey var userID: Int64
///     var name: String
/// }
/// ```
///
/// **Multi-tenant with Partition**:
/// ```swift
/// @Recordable
/// struct Order {
///     #Directory<Order>(
///         ["tenants", \.accountID, "orders"],
///         layer: .partition
///     )
///
///     @PrimaryKey var orderID: Int64
///     var accountID: String  // Partition key
/// }
///
/// // @Recordable generates:
/// // extension Order {
/// //     static func openDirectory(
/// //         accountID: String,
/// //         database: any DatabaseProtocol
/// //     ) async throws -> DirectorySubspace
/// //
/// //     static func store(
/// //         accountID: String,
/// //         database: any DatabaseProtocol,
/// //         metaData: RecordMetaData
/// //     ) async throws -> RecordStore<Order>
/// // }
///
/// // Usage:
/// let orderStore = try await Order.store(
///     accountID: "account-123",
///     database: database,
///     metaData: metaData
/// )
/// ```
///
/// **Multi-level partitioning**:
/// ```swift
/// @Recordable
/// struct Message {
///     #Directory<Message>(
///         ["tenants", \.accountID, "channels", \.channelID, "messages"],
///         layer: .partition
///     )
///
///     @PrimaryKey var messageID: Int64
///     var accountID: String  // First partition key
///     var channelID: String  // Second partition key
/// }
/// ```
///
/// **Directory Layers**:
/// - `.recordStore` (default): Standard RecordStore directory
/// - `.partition`: Multi-tenant partition (requires at least one KeyPath)
/// - `.luceneIndex`: Lucene full-text search index
/// - `.timeSeries`: Time-series data storage
/// - `.vectorIndex`: Vector search index
/// - Custom: `"my_custom_format_v2"`
///
/// **Validation**:
/// - Generic type parameter `<T>` is required
/// - Path must be an array literal
/// - Array elements must be string literals or KeyPath expressions
/// - If `layer: .partition`, at least one KeyPath is required
@freestanding(declaration)
public macro Directory<T>(
    _ path: [DirectoryPathElement<T>],
    layer: DirectoryLayer = .recordStore
) = #externalMacro(module: "FDBRecordLayerMacros", type: "DirectoryMacro")

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
