# Primary Key Design: Fundamental Solution

## Problem Statement

Current design has a fundamental flaw:

```swift
struct User: Recordable {
    static var primaryKeyFields = ["userID"]  // Manual definition #1

    func extractPrimaryKey() -> Tuple {
        return Tuple(tenantID, userID)  // Manual definition #2 - MISMATCH!
    }
}
```

**Issues**:
1. Two manual definitions → High risk of inconsistency
2. No compile-time validation
3. Silent runtime bugs
4. Developer discipline required

## Design Goals

1. **Single Source of Truth**: Define primary key once
2. **Compile-Time Safety**: Type system prevents inconsistency
3. **Zero Runtime Overhead**: No performance penalty
4. **Backward Compatible**: Gradual migration path
5. **Flexible**: Support complex keys (nested, computed)

## Proposed Solution: KeyPath-Based Primary Key

### Design Overview

```swift
protocol Recordable: Sendable {
    associatedtype PrimaryKeyValue: PrimaryKeyProtocol

    /// KeyPaths to primary key fields (compile-time validated)
    static var primaryKeyPaths: PrimaryKeyPaths<Self, PrimaryKeyValue> { get }

    /// Extract primary key value (generated from keyPaths)
    var primaryKeyValue: PrimaryKeyValue { get }
}
```

### Core Types

```swift
/// Primary key protocol
protocol PrimaryKeyProtocol: Sendable, Hashable {
    /// Convert to Tuple for FDB storage
    func toTuple() -> Tuple

    /// Field names for schema definition
    static var fieldNames: [String] { get }
}

/// Type-safe container for KeyPaths
struct PrimaryKeyPaths<Record, Value> {
    let keyPaths: [PartialKeyPath<Record>]
    let extract: (Record) -> Value
    let fieldNames: [String]
}
```

### Simple Primary Key (Single Field)

```swift
struct User: Recordable {
    var userID: String
    var email: String

    // ✅ Single definition using KeyPath
    static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
        PrimaryKeyPaths(
            keyPath: \.userID,
            fieldName: "userID"
        )
    }

    // ✅ Auto-generated (or default implementation)
    var primaryKeyValue: String { userID }
}

// PrimaryKeyPaths extension for single field
extension PrimaryKeyPaths {
    init<T: PrimaryKeyProtocol>(
        keyPath: KeyPath<Record, T>,
        fieldName: String
    ) where Value == T {
        self.keyPaths = [keyPath]
        self.extract = { $0[keyPath: keyPath] }
        self.fieldNames = [fieldName]
    }
}

// String conforms to PrimaryKeyProtocol
extension String: PrimaryKeyProtocol {
    func toTuple() -> Tuple { Tuple(self) }
    static var fieldNames: [String] { ["value"] }
}
```

### Composite Primary Key

```swift
struct Order: Recordable {
    var tenantID: String
    var orderID: String
    var createdAt: Date

    // ✅ Composite key with type safety
    struct PrimaryKey: PrimaryKeyProtocol {
        let tenantID: String
        let orderID: String

        func toTuple() -> Tuple {
            Tuple(tenantID, orderID)
        }

        static var fieldNames: [String] {
            ["tenantID", "orderID"]
        }
    }

    static var primaryKeyPaths: PrimaryKeyPaths<Order, PrimaryKey> {
        PrimaryKeyPaths(
            keyPaths: (\.tenantID, \.orderID),
            fieldNames: ("tenantID", "orderID")
        )
    }

    var primaryKeyValue: PrimaryKey {
        PrimaryKey(tenantID: tenantID, orderID: orderID)
    }
}

// PrimaryKeyPaths extension for composite keys
extension PrimaryKeyPaths {
    init<T1, T2>(
        keyPaths: (KeyPath<Record, T1>, KeyPath<Record, T2>),
        fieldNames: (String, String)
    ) where Value: PrimaryKeyProtocol {
        self.keyPaths = [keyPaths.0, keyPaths.1]
        self.extract = { record in
            // Value must have init(T1, T2) or similar
            // This is enforced by PrimaryKeyProtocol
            fatalError("Must be implemented by Value type")
        }
        self.fieldNames = [fieldNames.0, fieldNames.1]
    }
}
```

### Nested Primary Key (Future)

```swift
struct NestedUser: Recordable {
    struct Profile {
        var id: String
        var name: String
    }

    var profile: Profile
    var email: String

    // ✅ Nested field using KeyPath composition
    static var primaryKeyPaths: PrimaryKeyPaths<NestedUser, String> {
        PrimaryKeyPaths(
            keyPath: \.profile.id,
            fieldName: "profile.id"  // Nested notation
        )
    }

    var primaryKeyValue: String { profile.id }
}
```

## Implementation Plan

### Phase 1: Add PrimaryKeyProtocol (Non-Breaking)

```swift
// New protocol (coexists with old API)
protocol PrimaryKeyProtocol: Sendable, Hashable {
    func toTuple() -> Tuple
    static var fieldNames: [String] { get }
}

// Extend common types
extension String: PrimaryKeyProtocol { ... }
extension Int: PrimaryKeyProtocol { ... }
extension UUID: PrimaryKeyProtocol { ... }
```

### Phase 2: Add PrimaryKeyPaths (Non-Breaking)

```swift
struct PrimaryKeyPaths<Record, Value> {
    let keyPaths: [PartialKeyPath<Record>]
    let extract: (Record) -> Value
    let fieldNames: [String]
}

// Add to Recordable as optional (backward compatible)
protocol Recordable {
    associatedtype PrimaryKeyValue: PrimaryKeyProtocol = Tuple

    // Old API (still works)
    static var primaryKeyFields: [String] { get }
    func extractPrimaryKey() -> Tuple

    // New API (optional, provides type safety)
    static var primaryKeyPaths: PrimaryKeyPaths<Self, PrimaryKeyValue>? { get }
    var primaryKeyValue: PrimaryKeyValue? { get }
}

extension Recordable {
    // Default: use old API
    static var primaryKeyPaths: PrimaryKeyPaths<Self, PrimaryKeyValue>? { nil }
    var primaryKeyValue: PrimaryKeyValue? { nil }
}
```

### Phase 3: Migrate Entity to Use primaryKeyPaths

```swift
// Entity.init(from:)
internal init(from type: any Recordable.Type) {
    self.name = type.recordTypeName

    // Try new API first
    if let primaryKeyPaths = type.primaryKeyPaths {
        // ✅ Use KeyPath-based definition
        self.primaryKeyFields = primaryKeyPaths.fieldNames
        self.primaryKeyExpression = buildExpression(from: primaryKeyPaths)
    } else {
        // ✅ Fallback to old API
        self.primaryKeyFields = type.primaryKeyFields
        self.primaryKeyExpression = buildExpression(from: primaryKeyFields)
    }
}

private func buildExpression(from keyPaths: PrimaryKeyPaths) -> KeyExpression {
    // Build KeyExpression from KeyPaths
    // Can detect nested keys, computed properties, etc.
    if keyPaths.keyPaths.count == 1 {
        let keyPath = keyPaths.keyPaths[0]
        // Check if nested
        let fieldName = keyPaths.fieldNames[0]
        if fieldName.contains(".") {
            // Build NestExpression
            return buildNestExpression(fieldName)
        } else {
            return FieldKeyExpression(fieldName: fieldName)
        }
    } else {
        return ConcatenateKeyExpression(
            children: zip(keyPaths.keyPaths, keyPaths.fieldNames).map { _, fieldName in
                FieldKeyExpression(fieldName: fieldName)
            }
        )
    }
}
```

### Phase 4: Add Runtime Validation

```swift
// Entity.init(from:)
#if DEBUG
// Validate consistency between old and new API
if let primaryKeyPaths = type.primaryKeyPaths {
    // Create dummy instance to test extraction
    // (This requires a factory or mock)

    // Validate field names match
    let oldFields = type.primaryKeyFields
    let newFields = primaryKeyPaths.fieldNames
    assert(oldFields == newFields,
           "primaryKeyFields \(oldFields) doesn't match primaryKeyPaths.fieldNames \(newFields)")
}
#endif
```

### Phase 5: Deprecate Old API

```swift
protocol Recordable {
    // ✅ Required (new API)
    associatedtype PrimaryKeyValue: PrimaryKeyProtocol
    static var primaryKeyPaths: PrimaryKeyPaths<Self, PrimaryKeyValue> { get }
    var primaryKeyValue: PrimaryKeyValue { get }

    // ⚠️ Deprecated (old API)
    @available(*, deprecated, message: "Use primaryKeyPaths instead")
    static var primaryKeyFields: [String] { get }

    @available(*, deprecated, message: "Use primaryKeyValue instead")
    func extractPrimaryKey() -> Tuple
}
```

## Benefits

### 1. Compile-Time Safety

```swift
struct User: Recordable {
    var userID: String

    static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
        PrimaryKeyPaths(
            keyPath: \.userID,  // ✅ Type-checked by compiler
            fieldName: "userID"
        )
    }

    var primaryKeyValue: String {
        userID  // ✅ Must return String (enforced by associatedtype)
    }
}

// ❌ Compile error if mismatch:
// static var primaryKeyPaths: PrimaryKeyPaths<User, Int> { ... }
//                                                     ^^^ Error: Cannot convert String to Int
```

### 2. Single Source of Truth

```swift
// ✅ Define once with KeyPath
static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
    PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
}

// ✅ Auto-derived:
// - primaryKeyFields: ["userID"]
// - extractPrimaryKey(): Tuple(userID)
// - primaryKeyExpression: FieldKeyExpression("userID")
```

### 3. Supports Complex Keys

```swift
// Nested keys
PrimaryKeyPaths(keyPath: \.profile.id, fieldName: "profile.id")

// Computed properties
PrimaryKeyPaths(keyPath: \.computedID, fieldName: "computedID")

// Multiple fields
PrimaryKeyPaths(keyPaths: (\.tenantID, \.userID), fieldNames: ("tenantID", "userID"))
```

### 4. Zero Runtime Overhead

```swift
// KeyPath access is optimized by Swift compiler
record[keyPath: \.userID]  // Same as record.userID

// Extract closure inlined
let extract: (User) -> String = { $0.userID }
extract(user)  // Optimized to direct access
```

## Migration Path

### Step 1: Add new types (non-breaking)

- PrimaryKeyProtocol
- PrimaryKeyPaths
- Conformances for String, Int, UUID, etc.

### Step 2: Update Entity (backward compatible)

- Try primaryKeyPaths first
- Fallback to primaryKeyFields

### Step 3: Add validation (debug builds)

- Assert consistency
- Warn on mismatch

### Step 4: Migrate existing types

- User → primaryKeyPaths
- Order → primaryKeyPaths
- Document migration guide

### Step 5: Deprecate old API

- Mark as deprecated
- Eventually remove in v2.0

## Example: Complete Implementation

```swift
// User with simple primary key
struct User: Recordable {
    var userID: String
    var email: String
    var name: String

    typealias PrimaryKeyValue = String

    static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
        PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
    }

    var primaryKeyValue: String { userID }

    // Old API (generated by default implementation)
    static var primaryKeyFields: [String] { primaryKeyPaths.fieldNames }
    func extractPrimaryKey() -> Tuple { primaryKeyValue.toTuple() }
}

// Order with composite primary key
struct Order: Recordable {
    var tenantID: String
    var orderID: String
    var amount: Double

    struct PrimaryKey: PrimaryKeyProtocol {
        let tenantID: String
        let orderID: String

        func toTuple() -> Tuple { Tuple(tenantID, orderID) }
        static var fieldNames: [String] { ["tenantID", "orderID"] }
    }

    static var primaryKeyPaths: PrimaryKeyPaths<Order, PrimaryKey> {
        PrimaryKeyPaths(
            extract: { Order.PrimaryKey(tenantID: $0.tenantID, orderID: $0.orderID) },
            fieldNames: ["tenantID", "orderID"]
        )
    }

    var primaryKeyValue: PrimaryKey {
        PrimaryKey(tenantID: tenantID, orderID: orderID)
    }
}
```

## Timeline

- **Week 1**: Implement PrimaryKeyProtocol + PrimaryKeyPaths
- **Week 2**: Update Entity to support both APIs
- **Week 3**: Add validation + tests
- **Week 4**: Migrate User + Order examples
- **Month 2-3**: Migrate all existing types
- **v2.0**: Deprecate old API

## Alternatives Considered

### Alternative 1: Macro-based Generation

```swift
@Recordable
struct User {
    @PrimaryKey var userID: String
    var email: String
}
```

**Pros**: Most ergonomic, no boilerplate
**Cons**: Requires Swift 5.9+, complex implementation, delayed timeline

**Decision**: Use macros in Phase 3, after KeyPath-based API is stable

### Alternative 2: Protocol Requirements Only

```swift
protocol Recordable {
    static var primaryKeyExpression: KeyExpression { get }
}
```

**Pros**: Simple, no new types
**Cons**: No compile-time validation, still manual definition

**Decision**: Not sufficient for compile-time safety

### Alternative 3: Reflection-based

```swift
// Auto-detect from property names
static var primaryKeyFields: [String] = Mirror(reflecting: Self).detectPrimaryKey()
```

**Pros**: Zero boilerplate
**Cons**: Runtime overhead, fragile, no type safety

**Decision**: Too magical, not type-safe

## Conclusion

KeyPath-based primary key definition provides:

1. ✅ Compile-time safety (type system enforces consistency)
2. ✅ Single source of truth (define once)
3. ✅ Zero runtime overhead (compiler optimizes KeyPath access)
4. ✅ Backward compatible (gradual migration)
5. ✅ Flexible (supports simple, composite, nested keys)

This is the **fundamental solution** to the primary key consistency problem.
