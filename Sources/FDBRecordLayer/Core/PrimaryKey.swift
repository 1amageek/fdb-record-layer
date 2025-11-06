import Foundation

// MARK: - PrimaryKeyProtocol

/// Protocol for type-safe primary key values
///
/// PrimaryKeyProtocol provides compile-time guarantees for primary key consistency.
/// By conforming a type to this protocol, you ensure that:
/// - Primary key can be converted to Tuple for FDB storage
/// - Field names are statically defined
/// - Type system prevents mismatches between definition and implementation
///
/// **Example:**
/// ```swift
/// struct User: Recordable {
///     typealias PrimaryKeyValue = String
///
///     static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
///         PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
///     }
///
///     var primaryKeyValue: String { userID }
/// }
/// ```
public protocol PrimaryKeyProtocol: Sendable, Hashable {
    /// Convert primary key value to Tuple for FDB storage
    func toTuple() -> Tuple

    /// Field names that comprise this primary key
    ///
    /// For simple keys: `["userID"]`
    /// For composite keys: `["tenantID", "userID"]`
    static var fieldNames: [String] { get }

    /// Build KeyExpression from this primary key structure
    ///
    /// Default implementation builds from fieldNames.
    /// Override for complex keys (NestExpression, etc.)
    static var keyExpression: KeyExpression { get }
}

// MARK: - Default KeyExpression Implementation

extension PrimaryKeyProtocol {
    /// Default implementation: builds FieldKeyExpression or ConcatenateKeyExpression
    public static var keyExpression: KeyExpression {
        if fieldNames.count == 1 {
            return FieldKeyExpression(fieldName: fieldNames[0])
        } else {
            return ConcatenateKeyExpression(
                children: fieldNames.map { FieldKeyExpression(fieldName: $0) }
            )
        }
    }
}

// MARK: - Common Type Conformances

extension String: PrimaryKeyProtocol {
    public func toTuple() -> Tuple {
        return Tuple(self)
    }

    public static var fieldNames: [String] {
        return ["value"]
    }
}

extension Int: PrimaryKeyProtocol {
    public func toTuple() -> Tuple {
        return Tuple(Int64(self))
    }

    public static var fieldNames: [String] {
        return ["value"]
    }
}

extension Int64: PrimaryKeyProtocol {
    public func toTuple() -> Tuple {
        return Tuple(self)
    }

    public static var fieldNames: [String] {
        return ["value"]
    }
}

extension UUID: PrimaryKeyProtocol {
    public func toTuple() -> Tuple {
        return Tuple(self.uuidString)
    }

    public static var fieldNames: [String] {
        return ["value"]
    }
}

// MARK: - Tuple Conformance (backward compatibility - LIMITED USE)

// ⚠️ WARNING: Tuple conformance to PrimaryKeyProtocol is provided for backward
// compatibility ONLY. It returns empty arrays/expressions which can cause issues
// with index building and query planning.
//
// DO NOT USE Tuple as PrimaryKeyValue in new code. Instead:
// - Use String, Int, Int64, UUID for simple keys
// - Define custom struct conforming to PrimaryKeyProtocol for composite keys
//
// This conformance exists only to allow:
//   associatedtype PrimaryKeyValue: PrimaryKeyProtocol = Tuple
// to compile for types that haven't migrated to the new API yet.

extension Tuple: PrimaryKeyProtocol {
    public func toTuple() -> Tuple {
        return self
    }

    public static var fieldNames: [String] {
        // ⚠️ Returns empty array - cannot statically determine from Tuple
        // This will cause validation failures if used as PrimaryKeyValue
        return []
    }

    public static var keyExpression: KeyExpression {
        // ⚠️ Returns empty expression - cannot statically determine
        // This will cause issues in query planning if used as PrimaryKeyValue
        return EmptyKeyExpression()
    }
}

// MARK: - PrimaryKeyPaths

/// Type-safe container for primary key KeyPaths
///
/// PrimaryKeyPaths provides compile-time validation that primary key definition
/// matches the actual record structure. It uses Swift's KeyPath system to ensure
/// type safety.
///
/// **Single Field Example:**
/// ```swift
/// struct User: Recordable {
///     var userID: String
///
///     static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
///         PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
///     }
/// }
/// ```
///
/// **Composite Key Example:**
/// ```swift
/// struct Order: Recordable {
///     struct PrimaryKey: PrimaryKeyProtocol {
///         let tenantID: String
///         let orderID: String
///
///         func toTuple() -> Tuple { Tuple(tenantID, orderID) }
///         static var fieldNames: [String] { ["tenantID", "orderID"] }
///     }
///
///     static var primaryKeyPaths: PrimaryKeyPaths<Order, PrimaryKey> {
///         PrimaryKeyPaths(
///             extract: { PrimaryKey(tenantID: $0.tenantID, orderID: $0.orderID) },
///             fieldNames: ["tenantID", "orderID"]
///         )
///     }
/// }
/// ```
public struct PrimaryKeyPaths<Record, Value: PrimaryKeyProtocol>: @unchecked Sendable {
    /// Partial key paths (for reflection/debugging)
    ///
    /// Note: KeyPath is a value type and thread-safe by design.
    /// Using @unchecked Sendable because stdlib doesn't mark KeyPath as Sendable yet.
    public let keyPaths: [PartialKeyPath<Record>]

    /// Extraction function (type-safe)
    ///
    /// This function is used at runtime to extract the primary key value
    /// from a record instance. The compiler ensures type safety.
    ///
    /// **Thread-Safety Requirements**:
    /// - The closure MUST be pure (no side effects)
    /// - The closure MUST NOT capture mutable state
    /// - The closure MUST only access properties of the record parameter
    ///
    /// **Example (Safe)**:
    /// ```swift
    /// let extract = { record in record.userID }  // ✅ Pure function
    /// ```
    ///
    /// **Example (Unsafe)**:
    /// ```swift
    /// var capturedState = someValue
    /// let extract = { record in computeKey(record, capturedState) }  // ❌ Captures mutable state
    /// ```
    ///
    /// Using @unchecked Sendable because:
    /// 1. KeyPath is a thread-safe value type
    /// 2. Closure is expected to be pure and only access record properties
    /// 3. Callers must ensure closure safety (documented requirement)
    public let extract: (Record) -> Value

    /// Field names (for schema definition)
    public let fieldNames: [String]

    /// Initialize with custom extraction function
    ///
    /// Use this initializer for composite keys or complex primary key structures.
    ///
    /// - Parameters:
    ///   - extract: Function to extract primary key value from record
    ///   - fieldNames: Array of field names comprising the primary key
    ///   - keyPaths: Optional array of PartialKeyPaths for reflection (defaults to empty)
    public init(
        extract: @escaping (Record) -> Value,
        fieldNames: [String],
        keyPaths: [PartialKeyPath<Record>] = []
    ) {
        self.extract = extract
        self.fieldNames = fieldNames
        self.keyPaths = keyPaths
    }
}

// MARK: - Single Field Convenience

extension PrimaryKeyPaths {
    /// Initialize with single KeyPath (for simple primary keys)
    ///
    /// **Example:**
    /// ```swift
    /// static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
    ///     PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - keyPath: KeyPath to the primary key field
    ///   - fieldName: Name of the field (must match KeyPath)
    public init(
        keyPath: KeyPath<Record, Value>,
        fieldName: String
    ) {
        self.keyPaths = [keyPath]
        // Capture keyPath directly - safe because KeyPath is a value type
        self.extract = { $0[keyPath: keyPath] }
        self.fieldNames = [fieldName]
    }
}

// MARK: - Composite Key Conveniences

extension PrimaryKeyPaths {
    /// Initialize with two KeyPaths (composite key)
    ///
    /// **Example:**
    /// ```swift
    /// struct Order: Recordable {
    ///     struct PrimaryKey: PrimaryKeyProtocol {
    ///         let tenantID: String
    ///         let orderID: String
    ///     }
    ///
    ///     static var primaryKeyPaths: PrimaryKeyPaths<Order, PrimaryKey> {
    ///         PrimaryKeyPaths(
    ///             keyPaths: (\.tenantID, \.orderID),
    ///             fieldNames: ("tenantID", "orderID"),
    ///             build: { PrimaryKey(tenantID: $0, orderID: $1) }
    ///         )
    ///     }
    /// }
    /// ```
    public init<T1, T2>(
        keyPaths: (KeyPath<Record, T1>, KeyPath<Record, T2>),
        fieldNames: (String, String),
        build: @escaping (T1, T2) -> Value
    ) {
        self.keyPaths = [keyPaths.0, keyPaths.1]
        // Capture keyPaths directly - safe because KeyPath is a value type
        self.extract = { record in
            build(record[keyPath: keyPaths.0], record[keyPath: keyPaths.1])
        }
        self.fieldNames = [fieldNames.0, fieldNames.1]
    }

    /// Initialize with three KeyPaths (composite key)
    public init<T1, T2, T3>(
        keyPaths: (KeyPath<Record, T1>, KeyPath<Record, T2>, KeyPath<Record, T3>),
        fieldNames: (String, String, String),
        build: @escaping (T1, T2, T3) -> Value
    ) {
        self.keyPaths = [keyPaths.0, keyPaths.1, keyPaths.2]
        // Capture keyPaths directly - safe because KeyPath is a value type
        self.extract = { record in
            build(
                record[keyPath: keyPaths.0],
                record[keyPath: keyPaths.1],
                record[keyPath: keyPaths.2]
            )
        }
        self.fieldNames = [fieldNames.0, fieldNames.1, fieldNames.2]
    }
}

// MARK: - Helper Extensions

extension PrimaryKeyPaths {
    /// Build KeyExpression from this PrimaryKeyPaths
    ///
    /// Uses Value.keyExpression by default.
    /// For custom expressions, override Value.keyExpression.
    public var keyExpression: KeyExpression {
        return Value.keyExpression
    }
}
