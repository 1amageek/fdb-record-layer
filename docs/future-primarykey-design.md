# Future Design: Static Primary Key Expression in Recordable

## Problem

Current implementation has a potential inconsistency:
- `Entity.primaryKeyFields: [String]` (schema definition)
- `Recordable.extractPrimaryKey() -> Tuple` (runtime implementation)

These two must match, but there's no compile-time guarantee.

## Proposed Solution

Add `static var primaryKeyExpression` to `Recordable` protocol:

```swift
protocol Recordable {
    static var recordTypeName: String { get }
    static var primaryKeyFields: [String] { get }

    // ✅ NEW: Canonical primary key expression
    static var primaryKeyExpression: KeyExpression { get }

    func extractPrimaryKey() -> Tuple
}
```

### Default Implementation

```swift
extension Recordable {
    /// Default implementation: builds simple FieldKeyExpression
    /// Override for complex primary keys (NestExpression, etc.)
    static var primaryKeyExpression: KeyExpression {
        if primaryKeyFields.count == 1 {
            return FieldKeyExpression(fieldName: primaryKeyFields[0])
        } else {
            return ConcatenateKeyExpression(
                children: primaryKeyFields.map { FieldKeyExpression(fieldName: $0) }
            )
        }
    }
}
```

### Complex Primary Key Example

```swift
struct NestedUser: Recordable {
    static var primaryKeyFields = ["profile.id"]

    // ✅ Override for complex expression
    static var primaryKeyExpression: KeyExpression {
        return NestExpression(
            parentField: "profile",
            child: FieldKeyExpression(fieldName: "id")
        )
    }

    func extractPrimaryKey() -> Tuple {
        return Tuple(profile.id)
    }
}
```

### Benefits

1. **Compile-time safety**: Type system enforces consistency
2. **Flexibility**: Supports complex KeyExpressions (NestExpression, custom)
3. **Single source of truth**: Primary key expression defined once in protocol
4. **Backward compatible**: Default implementation works for simple cases

### Migration Path

1. Add `primaryKeyExpression` to `Recordable` with default implementation
2. Update `Entity.init()` to use `type.primaryKeyExpression` instead of building from fields
3. Add compile-time validation that `primaryKeyExpression.fieldNames()` matches `primaryKeyFields`

### Implementation

```swift
// Entity.init()
internal init(from type: any Recordable.Type) {
    self.name = type.recordTypeName
    self.primaryKeyFields = type.primaryKeyFields

    // ✅ Use Recordable's canonical expression
    self.primaryKeyExpression = type.primaryKeyExpression

    // ✅ Validate consistency (debug builds)
    #if DEBUG
    let expressionFields = Set(primaryKeyExpression.fieldNames())
    let declaredFields = Set(primaryKeyFields)
    assert(expressionFields == declaredFields,
           "primaryKeyExpression fields \(expressionFields) don't match primaryKeyFields \(declaredFields)")
    #endif

    // ...
}
```

## Timeline

- **Current (v1.0)**: Entity.primaryKeyExpression built from primaryKeyFields
- **Future (v1.1)**: Add static var to Recordable with default implementation
- **Future (v2.0)**: Make primaryKeyExpression required, remove default

## Related Issues

- Primary key extraction consistency
- Support for NestExpression and complex keys
- Compile-time validation
