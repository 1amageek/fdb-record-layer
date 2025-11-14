import Foundation

// MARK: - Index Type for Macro Usage

/// Index type for #Index macro (mirrors IndexType from Core/Types.swift)
///
/// Used to specify the type of index when using #Index macro.
/// Avoids name collision with IndexType enum in Core module.
public enum MacroIndexType {
    case value
    case rank
    case count
    case sum
    case min
    case max
}

/// Index scope for #Index macro (mirrors IndexScope from Core/Index.swift)
///
/// Used to specify whether an index is partition-local or global.
/// Avoids name collision with IndexScope enum in Core module.
public enum MacroIndexScope {
    case partition
    case global
}

// MARK: - Record Macros

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

/// Defines the primary key fields for a record type
///
/// Every `@Recordable` struct must have exactly one `#PrimaryKey` definition.
///
/// **Single Primary Key**:
/// ```swift
/// @Recordable
/// struct User {
///     #PrimaryKey<User>([\.userID])
///
///     var userID: Int64
///     var email: String
/// }
/// ```
///
/// **Composite Primary Key**:
/// ```swift
/// @Recordable
/// struct Hotel {
///     #PrimaryKey<Hotel>([\.ownerID, \.hotelID])  // Order matters!
///
///     var ownerID: String
///     var hotelID: Int64
///     var name: String
///     var rating: Double
/// }
/// ```
///
/// **When to use composite primary keys**:
/// - Global uniqueness across partitions with global indexes
/// - Multi-category rankings (e.g., game modes, regions)
/// - Time-series data partitioning
///
/// **Note**: This is a marker macro that generates no code itself.
/// The `@Recordable` macro detects `#PrimaryKey` calls and uses the KeyPath information
/// to generate primary key extraction logic.
@freestanding(declaration)
public macro PrimaryKey<T>(_ keyPaths: [PartialKeyPath<T>]) = #externalMacro(module: "FDBRecordLayerMacros", type: "PrimaryKeyMacroDeclaration")

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

/// Defines an index with optional type, scope, and name parameters
///
/// Use this overload when you need to specify index type (rank, count, sum, min, max)
/// or scope (partition-local vs global).
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct Hotel {
///     #PrimaryKey<Hotel>([\.ownerID, \.hotelID])
///     #Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)
///
///     // Partition-local index (default)
///     #Index<Hotel>([\.name], name: "by_name", scope: .partition)
///
///     // Global rank index (cross-partition)
///     #Index<Hotel>([\.rating], type: .rank, name: "global_rating", scope: .global)
///
///     // Count aggregation index
///     #Index<Hotel>([\.city], type: .count, name: "city_count")
///
///     var ownerID: String
///     var hotelID: Int64
///     var name: String
///     var rating: Double
///     var city: String
/// }
/// ```
///
/// **Parameters**:
/// - `indices`: KeyPath array for indexed fields
/// - `type`: Index type (.value, .rank, .count, .sum, .min, .max) - defaults to .value
/// - `scope`: Index scope (.partition, .global) - defaults to .partition
/// - `name`: Optional custom index name
///
/// **Index Types**:
/// - `.value`: Standard B-tree index for lookups and range queries
/// - `.rank`: Rank/leaderboard index for ordering by score
/// - `.count`: Count aggregation index (grouped by field)
/// - `.sum`: Sum aggregation index (grouped by field)
/// - `.min`: MIN aggregation index (grouped by field)
/// - `.max`: MAX aggregation index (grouped by field)
///
/// **Index Scopes**:
/// - `.partition`: Index is local to each partition (default)
/// - `.global`: Index spans across all partitions
///
/// **Important**: Global indexes with partitions MUST include partition key in primary key.
@freestanding(declaration)
public macro Index<T>(
    _ indices: [PartialKeyPath<T>],
    type: MacroIndexType? = nil,
    scope: MacroIndexScope? = nil,
    name: String? = nil
) = #externalMacro(module: "FDBRecordLayerMacros", type: "IndexMacro")

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

/// Marks a Vector property for HNSW-based similarity search indexing
///
/// This macro generates index metadata for vector similarity search using
/// Hierarchical Navigable Small World (HNSW) algorithm.
///
/// **Basic Usage**:
/// ```swift
/// @Recordable
/// struct Product {
///     #PrimaryKey<Product>([\.productID])
///
///     @Vector(dimensions: 768)
///     var embedding: Vector
///
///     var productID: Int64
///     var name: String
/// }
/// ```
///
/// **Advanced Usage with Custom Parameters**:
/// ```swift
/// @Vector(
///     dimensions: 1536,
///     metric: .l2,
///     m: 32,
///     efConstruction: 200,
///     efSearch: 100
/// )
/// var embedding: Vector
/// ```
///
/// **Parameters**:
/// - `dimensions`: Required. Vector dimensions (e.g., 768 for BERT, 1536 for GPT-3)
/// - `metric`: Distance metric (default: `.cosine` - 99% of ML use cases)
/// - `m`: HNSW M parameter (default: 16) - connections per layer
/// - `efConstruction`: Build-time search depth (default: 100)
/// - `efSearch`: Query-time search depth (default: 50)
///
/// **Performance Characteristics**:
/// - Build time: O(N log N * M * efConstruction)
/// - Query time: O(log N * efSearch)
/// - Memory: O(N * M * dimensions * 4 bytes)
///
/// **Important**:
/// - Property type MUST conform to `VectorRepresentable` protocol
/// - Dimensions must match vector data at runtime
/// - Metric cannot be changed after index creation (affects HNSW graph structure)
/// - HNSW parameters (m, efConstruction, efSearch) are determined by the index implementation
@attached(peer)
public macro Vector(
    dimensions: Int,
    metric: VectorMetric = .cosine
) = #externalMacro(module: "FDBRecordLayerMacros", type: "VectorMacro")

/// Marks a GeoCoordinate property for spatial indexing using Z-order curve
///
/// This macro generates index metadata for efficient spatial queries such as
/// bounding box searches and radius queries.
///
/// **Basic Usage (2D Geographic)**:
/// ```swift
/// @Recordable
/// struct Restaurant {
///     #PrimaryKey<Restaurant>([\.restaurantID])
///
///     @Spatial  // Defaults to geographic coordinates
///     var location: GeoCoordinate
///
///     var restaurantID: Int64
///     var name: String
/// }
/// ```
///
/// **3D Usage (with Altitude)**:
/// ```swift
/// @Recordable
/// struct Drone {
///     #PrimaryKey<Drone>([\.droneID])
///
///     @Spatial(type: .geo3D)
///     var position: GeoCoordinate
///
///     var droneID: Int64
/// }
/// ```
///
/// **Cartesian Coordinates**:
/// ```swift
/// @Recordable
/// struct GameEntity {
///     #PrimaryKey<GameEntity>([\.entityID])
///
///     @Spatial(type: .cartesian3D)
///     var position: CartesianCoordinate
///
///     var entityID: Int64
/// }
/// ```
///
/// **Parameters**:
/// - `type`: Spatial type (default: `.geo`)
///   - `.geo`: 2D geographic coordinates (latitude, longitude)
///   - `.geo3D`: 3D geographic coordinates (latitude, longitude, altitude)
///   - `.cartesian`: 2D Cartesian coordinates (x, y)
///   - `.cartesian3D`: 3D Cartesian coordinates (x, y, z)
///
/// **Index Structure**:
/// - 2D: 32 bits per dimension (latitude, longitude) → ~1cm accuracy
/// - 3D: 21 bits per dimension (lat, lon, alt) → ~50cm accuracy
///
/// **Query Support**:
/// - Bounding box: `within(minLat, minLon, maxLat, maxLon)`
/// - Circle: `withinRadius(centerLat, centerLon, radiusMeters)`
/// - Nearest: `nearest(lat, lon, k: 10)`
///
/// **Important**:
/// - Property type MUST conform to `SpatialRepresentable` protocol
/// - For geographic coordinates: use `GeoCoordinate` (standard implementation)
/// - For custom coordinates: implement `SpatialRepresentable` protocol
@attached(peer)
public macro Spatial(
    type: SpatialType = .geo
) = #externalMacro(module: "FDBRecordLayerMacros", type: "SpatialMacro")

/// Protocol for directory path elements
///
/// Directory paths can contain string literals and KeyPath references.
/// This protocol allows type-safe specification of heterogeneous path elements.
///
/// **Usage**:
/// ```swift
/// #Directory<Order>(
///     "tenants",           // Literal (ExpressibleByStringLiteral)
///     Field(\.accountID),  // Field (KeyPath wrapper)
///     "orders",
///     layer: .partition
/// )
/// ```
public protocol DirectoryPathElement {
    associatedtype Value
    var value: Value { get }
}

/// String literal path element
///
/// Automatically created from string literals via `ExpressibleByStringLiteral`.
public struct Path: DirectoryPathElement, ExpressibleByStringLiteral {
    public let value: String

    public init(stringLiteral value: String) {
        self.value = value
    }

    public init(_ value: String) {
        self.value = value
    }
}

extension String: DirectoryPathElement {
    public var value: String { self }
}

/// KeyPath-based path element for dynamic partitioning
///
/// Wraps a KeyPath to a field in the record type, used for multi-tenant directories.
///
/// **Usage**:
/// ```swift
/// #Directory<Order>(
///     "tenants",
///     Field(\.tenantID),  // KeyPath to tenantID field
///     "orders",
///     layer: .partition
/// )
/// ```
public struct Field<Root>: DirectoryPathElement {
    public var value: PartialKeyPath<Root>

    public init(_ keyPath: PartialKeyPath<Root>) {
        self.value = keyPath
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
///     #Directory<User>("app", "users")
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
///         "tenants",
///         Field(\.accountID),
///         "orders",
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
/// //         schema: Schema
/// //     ) async throws -> RecordStore<Order>
/// // }
///
/// // Usage:
/// let orderStore = try await Order.store(
///     accountID: "account-123",
///     database: database,
///     schema: schema
/// )
/// ```
///
/// **Multi-level partitioning**:
/// ```swift
/// @Recordable
/// struct Message {
///     #Directory<Message>(
///         "tenants",
///         Field(\.accountID),
///         "channels",
///         Field(\.channelID),
///         "messages",
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
/// - Path elements must be string literals or `Field(\.propertyName)` expressions
/// - If `layer: .partition`, at least one `Field` is required
@freestanding(declaration)
public macro Directory<T>(
    _ pathElements: any DirectoryPathElement...,
    layer: DirectoryLayerType = .recordStore
) = #externalMacro(module: "FDBRecordLayerMacros", type: "DirectoryMacro")

/// Directory layer type for #Directory macro
///
/// This enum is used as a type-safe parameter for the #Directory macro.
/// It will be converted to fdb-swift-bindings' DirectoryType at compile time.
public enum DirectoryLayerType: Sendable {
    case partition
    case recordStore
    case luceneIndex
    case timeSeries
    case vectorIndex
    case custom(String)
}

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

/// Attribute option for @Attribute macro (SwiftData compatible)
///
/// Matches Schema.Entity.Attribute.Option for compatibility
public enum AttributeOption: Sendable {
    /// Mark the property as unique, creating a unique constraint
    case unique
}

/// Provides metadata about a property for schema evolution and constraints
///
/// SwiftData-compliant macro that supports variadic options, field renaming, and hash modifiers.
///
/// **Usage**:
/// ```swift
/// @Recordable
/// struct User {
///     #PrimaryKey<User>([\.userID])
///
///     // Unique constraint
///     @Attribute(.unique)
///     var email: String
///
///     // Field rename (schema evolution)
///     @Attribute(originalName: "username")
///     var name: String
///
///     // Multiple options
///     @Attribute(.unique, originalName: "old_email", hashModifier: "v2")
///     var primaryEmail: String
/// }
/// ```
///
/// **Parameters**:
/// - `options`: Variadic attribute options (e.g., `.unique`)
/// - `originalName`: Previous field name for schema migration (optional)
/// - `hashModifier`: Hash modifier for property uniqueness calculation (optional)
@attached(peer)
public macro Attribute(
    _ options: AttributeOption...,
    originalName: String? = nil,
    hashModifier: String? = nil
) = #externalMacro(module: "FDBRecordLayerMacros", type: "AttributeMacro")
