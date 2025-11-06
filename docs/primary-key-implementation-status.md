# Primary Key Implementation Status

## Summary

Type-safe primary key system has been implemented to solve the fundamental consistency problem between `primaryKeyFields` and `extractPrimaryKey()`.

**Status**: ✅ Phase 1-3 Complete (Backward Compatible)

## Problem Solved

### Before (Inconsistency Risk)

```swift
struct User: Recordable {
    static var primaryKeyFields = ["userID"]  // Manual definition #1

    func extractPrimaryKey() -> Tuple {
        return Tuple(tenantID, userID)  // Manual definition #2 - MISMATCH!
    }
}
```

**Issues**:
- Two manual definitions → High risk of inconsistency
- No compile-time validation
- Silent runtime bugs

### After (Type-Safe)

```swift
struct User: Recordable {
    typealias PrimaryKeyValue = String

    static var primaryKeyPaths: PrimaryKeyPaths<User, String> {
        PrimaryKeyPaths(keyPath: \.userID, fieldName: "userID")
    }

    var primaryKeyValue: String { userID }
}
```

**Benefits**:
- ✅ Single source of truth
- ✅ Compile-time type checking
- ✅ Zero runtime overhead
- ✅ Backward compatible

## Implementation Details

### Phase 1: Foundation Types (Complete)

**File**: `Sources/FDBRecordLayer/Core/PrimaryKey.swift`

Created core types:
- `PrimaryKeyProtocol` - Protocol for primary key values
- `PrimaryKeyPaths<Record, Value>` - Type-safe KeyPath container
- Common type conformances: `String`, `Int`, `Int64`, `UUID`, `Tuple`

**Key Features**:
- Uses `@unchecked Sendable` for KeyPath storage (safe because KeyPath is a value type)
- Provides convenience initializers for single and composite keys
- Supports up to 3-field composite keys out of the box

### Phase 2: Protocol Extension (Complete)

**File**: `Sources/FDBRecordLayer/Serialization/Recordable.swift`

Updated `Recordable` protocol:
- Added `associatedtype PrimaryKeyValue: PrimaryKeyProtocol = Tuple`
- Added optional `primaryKeyPaths` property (defaults to `nil`)
- Added optional `primaryKeyValue` property (defaults to `nil`)

**Backward Compatibility**:
- Old API (`primaryKeyFields`, `extractPrimaryKey()`) still required
- New API is optional with `nil` defaults
- Both APIs coexist during migration

### Phase 3: Entity Integration (Complete)

**File**: `Sources/FDBRecordLayer/Schema/Schema+Entity.swift`

Updated `Entity.init()`:
- Tries new API (`primaryKeyPaths`) first
- Falls back to old API (`primaryKeyFields`) if not available
- Validates consistency in debug builds

**Logic**:
```swift
if let primaryKeyPaths = type.primaryKeyPaths {
    // ✅ Use new API (type-safe)
    self.primaryKeyFields = primaryKeyPaths.fieldNames
    self.primaryKeyExpression = primaryKeyPaths.keyExpression
} else {
    // ✅ Fallback to old API
    self.primaryKeyFields = type.primaryKeyFields
    self.primaryKeyExpression = buildFromFields(primaryKeyFields)
}
```

## Documentation

### Design Documents

1. **`docs/design-primarykey-solution.md`**
   - Complete design specification
   - Problem analysis
   - Solution architecture
   - 5-phase implementation plan
   - Code examples

2. **`docs/primary-key-migration-guide.md`**
   - Step-by-step migration instructions
   - Before/after comparisons
   - Troubleshooting guide
   - Common patterns

3. **`docs/schema-entity-design.md`**
   - Updated with new Entity behavior
   - Documents how Entity.init() uses both APIs

### Examples

**File**: `Examples/PrimaryKeyExample.swift`

Demonstrates:
- Simple primary key (String, Int64, UUID)
- Composite primary key
- Old API (still supported)
- Type safety at compile time

## Build Status

✅ All builds passing
✅ No breaking changes
✅ Full backward compatibility

```bash
$ swift build
Build complete! (0.11s)
```

## Migration Timeline

### Phase 1-3: Complete ✅

- [x] PrimaryKeyProtocol and PrimaryKeyPaths types
- [x] Recordable protocol extension with new API
- [x] Entity.init() integration with fallback logic
- [x] Documentation and examples

### Phase 4: Gradual Migration (In Progress)

Next steps for users:
1. Update existing record types to use new API
2. Test and validate
3. Remove old API implementations (keep for compatibility)

### Phase 5: Deprecation (Future)

Timeline: 6-12 months after Phase 4
- Mark old API as deprecated
- Eventually remove in v2.0

## Usage Statistics

### Current Codebase

- Total Recordable types: ~10 (in tests)
- Using new API: 0 (just completed implementation)
- Using old API: ~10 (existing types)

### Migration Progress

- [ ] Migrate test types
- [ ] Update examples in README
- [ ] Create migration checklist

## Known Limitations

1. **Complex Key Expressions**: Current implementation assumes simple FieldKeyExpressions or ConcatenateKeyExpressions. For complex keys (NestExpression, etc.), override `keyExpression` in PrimaryKeyProtocol conformance.

2. **Reflection Limitations**: `keyPaths` property stores PartialKeyPath for debugging, but doesn't provide full reflection capabilities yet.

3. **Validation**: Debug builds validate consistency, but production builds trust the implementation.

## Future Enhancements

### Nested Primary Keys (Planned)

Support for nested fields:

```swift
struct NestedUser: Recordable {
    struct Profile {
        var id: String
    }
    var profile: Profile

    static var primaryKeyPaths: PrimaryKeyPaths<NestedUser, String> {
        PrimaryKeyPaths(
            keyPath: \.profile.id,
            fieldName: "profile.id"  // Nested notation
        )
    }
}
```

**Requirements**:
- Implement `NestExpression` detection from KeyPath
- Parse dotted field names ("profile.id")
- Build appropriate KeyExpression tree

### Macro-Based Generation (Future)

Integrate with `@Recordable` macro:

```swift
@Recordable
struct User {
    @PrimaryKey var userID: String
    var email: String
}
// Macro generates:
// - primaryKeyPaths
// - primaryKeyValue
// - All Recordable conformance
```

## Testing

### Unit Tests

Required test coverage:
- [ ] PrimaryKeyProtocol conformances (String, Int, UUID)
- [ ] PrimaryKeyPaths initialization
- [ ] Entity.init() with new API
- [ ] Entity.init() with old API (fallback)
- [ ] Consistency validation

### Integration Tests

- [ ] RecordStore with new API types
- [ ] Index maintainers with new API types
- [ ] Query planning with new primary keys

## References

- **Design**: `docs/design-primarykey-solution.md`
- **Migration**: `docs/primary-key-migration-guide.md`
- **Examples**: `Examples/PrimaryKeyExample.swift`
- **Implementation**: `Sources/FDBRecordLayer/Core/PrimaryKey.swift`
- **Protocol**: `Sources/FDBRecordLayer/Serialization/Recordable.swift`
- **Entity**: `Sources/FDBRecordLayer/Schema/Schema+Entity.swift`

---

**Last Updated**: 2025-01-15
**Status**: Phase 1-3 Complete ✅
**Next Step**: Migrate existing types to new API
