import Foundation
import FDBRecordLayer

// MARK: - Example 1: Simple Primary Key (Single Field)

/// User with simple String primary key
struct User: Recordable {
    var userID: String
    var email: String
    var name: String
    var age: Int

    // ✅ New API: Type-safe primary key definition
    typealias PrimaryKeyValue = String

    static var recordTypeName: String { "User" }

    static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
        PrimaryKeyPaths(
            keyPath: \.userID,
            fieldName: "userID"
        )
    }

    var primaryKeyValue: String {
        userID
    }

    // Old API: Can be derived from new API
    // ⚠️ NOTE: This uses force-unwrap for brevity in example
    // In production code, use safe unwrapping or let @Recordable macro generate this
    static var primaryKeyFields: [String] {
        primaryKeyPaths!.fieldNames  // Force-unwrap safe here because we implement primaryKeyPaths
    }

    func extractPrimaryKey() -> Tuple {
        primaryKeyValue!.toTuple()  // Force-unwrap safe here because we implement primaryKeyValue
    }

    // Recordable conformance
    static var allFields: [String] {
        ["userID", "email", "name", "age"]
    }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "userID": return 1
        case "email": return 2
        case "name": return 3
        case "age": return 4
        default: return nil
        }
    }

    func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "userID": return [userID]
        case "email": return [email]
        case "name": return [name]
        case "age": return [Int64(age)]
        default: return []
        }
    }

    func toProtobuf() throws -> Data {
        // Implementation omitted for brevity
        fatalError("Not implemented in example")
    }

    static func fromProtobuf(_ data: Data) throws -> User {
        // Implementation omitted for brevity
        fatalError("Not implemented in example")
    }
}

// MARK: - Example 2: Composite Primary Key

/// Order with composite primary key (tenantID + orderID)
struct Order: Recordable {
    var tenantID: String
    var orderID: String
    var amount: Double
    var createdAt: Date

    // ✅ Define composite key type
    struct PrimaryKey: PrimaryKeyProtocol {
        let tenantID: String
        let orderID: String

        func toTuple() -> Tuple {
            Tuple(tenantID, orderID)
        }

        static var fieldNames: [String] {
            ["tenantID", "orderID"]
        }

        static var keyExpression: KeyExpression {
            ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "tenantID"),
                FieldKeyExpression(fieldName: "orderID")
            ])
        }
    }

    // ✅ New API: Type-safe composite primary key
    typealias PrimaryKeyValue = PrimaryKey

    static var recordTypeName: String { "Order" }

    static var primaryKeyPaths: PrimaryKeyPaths<Order, PrimaryKey> {
        PrimaryKeyPaths(
            keyPaths: (\.tenantID, \.orderID),
            fieldNames: ("tenantID", "orderID"),
            build: { PrimaryKey(tenantID: $0, orderID: $1) }
        )
    }

    var primaryKeyValue: PrimaryKey {
        PrimaryKey(tenantID: tenantID, orderID: orderID)
    }

    // Old API: Can be derived from new API
    // ⚠️ NOTE: This uses force-unwrap for brevity in example
    // In production code, use safe unwrapping or let @Recordable macro generate this
    static var primaryKeyFields: [String] {
        primaryKeyPaths!.fieldNames  // Force-unwrap safe here because we implement primaryKeyPaths
    }

    func extractPrimaryKey() -> Tuple {
        primaryKeyValue!.toTuple()  // Force-unwrap safe here because we implement primaryKeyValue
    }

    // Recordable conformance
    static var allFields: [String] {
        ["tenantID", "orderID", "amount", "createdAt"]
    }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "tenantID": return 1
        case "orderID": return 2
        case "amount": return 3
        case "createdAt": return 4
        default: return nil
        }
    }

    func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "tenantID": return [tenantID]
        case "orderID": return [orderID]
        case "amount": return [amount]
        case "createdAt": return [Int64(createdAt.timeIntervalSince1970)]
        default: return []
        }
    }

    func toProtobuf() throws -> Data {
        fatalError("Not implemented in example")
    }

    static func fromProtobuf(_ data: Data) throws -> Order {
        fatalError("Not implemented in example")
    }
}

// MARK: - Example 3: Using Int64 Primary Key

/// Product with Int64 primary key
struct Product: Recordable {
    var productID: Int64
    var name: String
    var price: Double

    // ✅ New API: Int64 primary key
    typealias PrimaryKeyValue = Int64

    static var recordTypeName: String { "Product" }

    static var primaryKeyPaths: PrimaryKeyPaths<Product, Int64> {
        PrimaryKeyPaths(
            keyPath: \.productID,
            fieldName: "productID"
        )
    }

    var primaryKeyValue: Int64 {
        productID
    }

    // Old API
    static var primaryKeyFields: [String] {
        primaryKeyPaths!.fieldNames
    }

    func extractPrimaryKey() -> Tuple {
        primaryKeyValue!.toTuple()
    }

    // Recordable conformance
    static var allFields: [String] {
        ["productID", "name", "price"]
    }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "productID": return 1
        case "name": return 2
        case "price": return 3
        default: return nil
        }
    }

    func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "productID": return [productID]
        case "name": return [name]
        case "price": return [price]
        default: return []
        }
    }

    func toProtobuf() throws -> Data {
        fatalError("Not implemented in example")
    }

    static func fromProtobuf(_ data: Data) throws -> Product {
        fatalError("Not implemented in example")
    }
}

// MARK: - Example 4: Using UUID Primary Key

/// Session with UUID primary key
struct Session: Recordable {
    var sessionID: UUID
    var userID: String
    var expiresAt: Date

    // ✅ New API: UUID primary key
    typealias PrimaryKeyValue = UUID

    static var recordTypeName: String { "Session" }

    static var primaryKeyPaths: PrimaryKeyPaths<Session, UUID> {
        PrimaryKeyPaths(
            keyPath: \.sessionID,
            fieldName: "sessionID"
        )
    }

    var primaryKeyValue: UUID {
        sessionID
    }

    // Old API
    static var primaryKeyFields: [String] {
        primaryKeyPaths!.fieldNames
    }

    func extractPrimaryKey() -> Tuple {
        primaryKeyValue!.toTuple()
    }

    // Recordable conformance
    static var allFields: [String] {
        ["sessionID", "userID", "expiresAt"]
    }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "sessionID": return 1
        case "userID": return 2
        case "expiresAt": return 3
        default: return nil
        }
    }

    func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "sessionID": return [sessionID.uuidString]
        case "userID": return [userID]
        case "expiresAt": return [Int64(expiresAt.timeIntervalSince1970)]
        default: return []
        }
    }

    func toProtobuf() throws -> Data {
        fatalError("Not implemented in example")
    }

    static func fromProtobuf(_ data: Data) throws -> Session {
        fatalError("Not implemented in example")
    }
}

// MARK: - Example 5: Old API (Still Supported)

/// Legacy User using old API (for comparison)
struct LegacyUser: Recordable {
    var userID: String
    var email: String

    // ❌ Old API: Manual definition, no compile-time safety
    static var recordTypeName: String { "LegacyUser" }

    static var primaryKeyFields: [String] {
        ["userID"]
    }

    func extractPrimaryKey() -> Tuple {
        Tuple(userID)
    }

    // Note: No primaryKeyPaths or primaryKeyValue
    // Entity.init() will fall back to building from primaryKeyFields

    static var allFields: [String] {
        ["userID", "email"]
    }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "userID": return 1
        case "email": return 2
        default: return nil
        }
    }

    func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "userID": return [userID]
        case "email": return [email]
        default: return []
        }
    }

    func toProtobuf() throws -> Data {
        fatalError("Not implemented in example")
    }

    static func fromProtobuf(_ data: Data) throws -> LegacyUser {
        fatalError("Not implemented in example")
    }
}

// MARK: - Usage Example

func exampleUsage() async throws {
    // Entity automatically uses new API when available
    let userEntity = Schema.Entity(from: User.self)
    print("User entity:")
    print("  Primary key fields: \(userEntity.primaryKeyFields)")
    print("  Primary key expression: \(userEntity.primaryKeyExpression)")

    let orderEntity = Schema.Entity(from: Order.self)
    print("Order entity:")
    print("  Primary key fields: \(orderEntity.primaryKeyFields)")
    print("  Primary key expression: \(orderEntity.primaryKeyExpression)")

    // Legacy entity uses old API
    let legacyEntity = Schema.Entity(from: LegacyUser.self)
    print("Legacy entity:")
    print("  Primary key fields: \(legacyEntity.primaryKeyFields)")
    print("  Primary key expression: \(legacyEntity.primaryKeyExpression)")
}

// MARK: - Compile-Time Safety Demonstration

func demonstrateTypeSafety() {
    let user = User(
        userID: "user123",
        email: "user@example.com",
        name: "John Doe",
        age: 30
    )

    // ✅ Type-safe primary key extraction
    let primaryKey: String = user.primaryKeyValue!
    print("Primary key: \(primaryKey)")

    // ✅ Compile-time error if types don't match
    // let wrongType: Int64 = user.primaryKeyValue  // ❌ Error: Cannot convert String to Int64

    let order = Order(
        tenantID: "tenant_a",
        orderID: "order_123",
        amount: 99.99,
        createdAt: Date()
    )

    // ✅ Type-safe composite key extraction
    let compositeKey: Order.PrimaryKey = order.primaryKeyValue!
    print("Composite key: \(compositeKey.tenantID) / \(compositeKey.orderID)")
}
