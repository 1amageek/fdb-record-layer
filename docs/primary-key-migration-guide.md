# Primary Key Migration Guide

## Overview

This guide explains how to migrate from the old manual primary key definition to the new type-safe KeyPath-based API.

## Problem with Old API

The old API required manual definition in two places with no compile-time validation:

```swift
struct User: Recordable {
    static var primaryKeyFields = ["userID"]  // Manual definition #1

    func extractPrimaryKey() -> Tuple {
        return Tuple(tenantID, userID)  // Manual definition #2 - MISMATCH!
    }
}
```

**Issues:**
- Two separate definitions can easily get out of sync
- No compile-time validation
- Silent runtime bugs
- Developer discipline required

## New Type-Safe API

The new API uses Swift's KeyPath system for compile-time safety:

```swift
struct User: Recordable {
    typealias PrimaryKeyValue = String

    static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
        PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
    }

    var primaryKeyValue: String { userID }

    // Old API automatically satisfied
    static var primaryKeyFields: [String] { primaryKeyPaths!.fieldNames }
    func extractPrimaryKey() -> Tuple { primaryKeyValue!.toTuple() }
}
```

**Benefits:**
- ✅ Single source of truth
- ✅ Compile-time safety (KeyPath must exist and have correct type)
- ✅ Type system prevents mismatches
- ✅ Zero runtime overhead

## Migration Steps

### Step 1: Simple Primary Key (Single Field)

**Before (Old API):**
```swift
struct User: Recordable {
    var userID: String
    var email: String
    var name: String

    static var recordTypeName: String { "User" }

    static var primaryKeyFields: [String] {
        return ["userID"]
    }

    func extractPrimaryKey() -> Tuple {
        return Tuple(userID)
    }

    // ... other Recordable methods
}
```

**After (New API):**
```swift
struct User: Recordable {
    var userID: String
    var email: String
    var name: String

    // ✅ Specify PrimaryKeyValue type
    typealias PrimaryKeyValue = String

    static var recordTypeName: String { "User" }

    // ✅ Define primary key with KeyPath
    static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
        PrimaryKeyPaths(
            keyPath: \.userID,
            fieldName: "userID"
        )
    }

    // ✅ Extract primary key value (type-safe)
    var primaryKeyValue: String { userID }

    // Old API methods can be removed or kept for backward compatibility
    static var primaryKeyFields: [String] {
        return primaryKeyPaths!.fieldNames
    }

    func extractPrimaryKey() -> Tuple {
        return primaryKeyValue!.toTuple()
    }

    // ... other Recordable methods
}
```

### Step 2: Composite Primary Key

**Before (Old API):**
```swift
struct Order: Recordable {
    var tenantID: String
    var orderID: String
    var amount: Double

    static var primaryKeyFields: [String] {
        return ["tenantID", "orderID"]
    }

    func extractPrimaryKey() -> Tuple {
        return Tuple(tenantID, orderID)
    }
}
```

**After (New API):**
```swift
struct Order: Recordable {
    var tenantID: String
    var orderID: String
    var amount: Double

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
    }

    typealias PrimaryKeyValue = PrimaryKey

    // ✅ Define primary key with KeyPaths
    static var primaryKeyPaths: PrimaryKeyPaths<Order, PrimaryKey> {
        PrimaryKeyPaths(
            keyPaths: (\.tenantID, \.orderID),
            fieldNames: ("tenantID", "orderID"),
            build: { PrimaryKey(tenantID: $0, orderID: $1) }
        )
    }

    // ✅ Extract composite key value
    var primaryKeyValue: PrimaryKey {
        PrimaryKey(tenantID: tenantID, orderID: orderID)
    }

    // Old API methods can be removed
    static var primaryKeyFields: [String] {
        return primaryKeyPaths!.fieldNames
    }

    func extractPrimaryKey() -> Tuple {
        return primaryKeyValue!.toTuple()
    }
}
```

**Alternative (more concise):**
```swift
static var primaryKeyPaths: PrimaryKeyPaths<Order, PrimaryKey> {
    PrimaryKeyPaths(
        extract: { PrimaryKey(tenantID: $0.tenantID, orderID: $0.orderID) },
        fieldNames: ["tenantID", "orderID"]
    )
}
```

## Common Types

The following types already conform to `PrimaryKeyProtocol`:

- `String`
- `Int`
- `Int64`
- `UUID`
- `Tuple` (for backward compatibility)

## Validation

In debug builds, Entity.init() validates consistency between old and new APIs:

```swift
#if DEBUG
let oldFields = type.primaryKeyFields
if oldFields != primaryKeyPaths.fieldNames {
    print("""
        ⚠️ WARNING: Primary key mismatch in \(type.recordTypeName)
           primaryKeyFields: \(oldFields)
           primaryKeyPaths.fieldNames: \(primaryKeyPaths.fieldNames)
           Using primaryKeyPaths (new API).
        """)
}
#endif
```

## Gradual Migration

Both APIs coexist during migration:

1. **Phase 1**: Add `primaryKeyPaths` and `primaryKeyValue` to new types
2. **Phase 2**: Migrate existing types one by one
3. **Phase 3**: Remove old API implementations (keep protocol requirements for compatibility)
4. **Phase 4**: Eventually deprecate old API

## Troubleshooting

### Error: `KeyPath` is not Sendable

**Solution**: Already handled internally with `@unchecked Sendable`. KeyPath is a thread-safe value type.

### Error: Type mismatch in `primaryKeyValue`

**Problem**: `primaryKeyValue` returns wrong type

**Solution**: Ensure `typealias PrimaryKeyValue` matches the returned type:

```swift
typealias PrimaryKeyValue = String  // Must match primaryKeyValue type
var primaryKeyValue: String { userID }
```

### Error: `primaryKeyPaths.fieldNames` doesn't match fields

**Problem**: Field names in `primaryKeyPaths` don't match actual fields

**Solution**: Ensure field names exactly match the property names:

```swift
// ❌ Wrong
PrimaryKeyPaths(keyPath: \.userID, fieldName: "user_id")

// ✅ Correct
PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
```

## Future: Nested Primary Keys

The new API will support nested keys:

```swift
struct NestedUser: Recordable {
    struct Profile {
        var id: String
        var name: String
    }

    var profile: Profile
    var email: String

    static var primaryKeyPaths: PrimaryKeyPaths<NestedUser, String> {
        PrimaryKeyPaths(
            keyPath: \.profile.id,
            fieldName: "profile.id"  // Nested notation
        )
    }

    var primaryKeyValue: String { profile.id }
}
```

This will require implementing `NestExpression` support in `PrimaryKeyPaths.keyExpression`.

## Summary

The new type-safe primary key API provides:

1. ✅ Compile-time safety - Type system enforces consistency
2. ✅ Single source of truth - Define once with KeyPath
3. ✅ Zero runtime overhead - KeyPath access is optimized
4. ✅ Backward compatible - Gradual migration path
5. ✅ Flexible - Supports simple, composite, and (future) nested keys

For more details, see:
- `/docs/design-primarykey-solution.md` - Complete design document
- `/Sources/FDBRecordLayer/Core/PrimaryKey.swift` - Implementation
