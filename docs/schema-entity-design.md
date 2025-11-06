# Schema/Entity Design - Current Implementation

## Overview

This document describes the current implementation of the Schema/Entity architecture after the RecordMetadata/RecordType refactoring.

## Architecture

### Schema (Definition Layer)

```swift
public final class Schema {
    public let version: Version
    public let entities: [Entity]
    public let entitiesByName: [String: Entity]

    // FoundationDB extensions
    public let indexes: [Index]  // Full Index objects
    public let indexesByName: [String: Index]
    public let formerIndexes: [String: FormerIndex]
}
```

**Design Pattern**: SwiftData-compatible schema definition with FoundationDB extensions.

### Entity (Record Type Definition)

```swift
public struct Entity {
    public let name: String
    public let attributes: Set<Attribute>
    public let attributesByName: [String: Attribute]

    // FoundationDB extensions
    public let primaryKeyFields: [String]  // Field names only
    public let primaryKeyExpression: KeyExpression  // Built from primaryKeyFields
}
```

**Key Design Decisions**:

1. **primaryKeyFields**: SwiftData-compatible, stores field names only
2. **primaryKeyExpression**: FoundationDB extension, built once during Entity.init()
3. **Canonical Source**: Entity.primaryKeyExpression is used everywhere for consistency

## Primary Key Handling

### Current Implementation

```swift
// Entity.init(from:)
internal init(from type: any Recordable.Type) {
    self.primaryKeyFields = type.primaryKeyFields

    // Build canonical KeyExpression
    self.primaryKeyExpression = if primaryKeyFields.count == 1 {
        FieldKeyExpression(fieldName: primaryKeyFields[0])
    } else {
        ConcatenateKeyExpression(children: primaryKeyFields.map {
            FieldKeyExpression(fieldName: $0)
        })
    }
}
```

### Usage Locations

**Query Planning**:
```swift
// TypedRecordQueryPlanner.swift
let unionPlan = TypedUnionPlan(
    childPlans: branchPlans,
    primaryKeyExpression: entity.primaryKeyExpression  // ✅ Canonical
)
```

**Validation**:
```swift
// RecordAccessValidator.swift
try validateKeyExpression(
    entity.primaryKeyExpression,  // ✅ Canonical
    context: "Primary key for \(entity.name)"
)
```

**Runtime Extraction**:
```swift
// Index maintainers
if let recordableRecord = record as? any Recordable {
    let primaryKey = recordableRecord.extractPrimaryKey()  // ✅ Runtime
}
```

### Consistency Guarantee

The current implementation guarantees consistency by:

1. **Single Construction Point**: primaryKeyExpression built once in Entity.init()
2. **Immutability**: Entity.primaryKeyExpression is `let` (immutable)
3. **Canonical Usage**: All query planning uses entity.primaryKeyExpression

## Current Constraints

### Constraint 1: Simple FieldKeyExpression Only

**Supported**:
```swift
static var primaryKeyFields = ["userID"]  // ✅ Single field
static var primaryKeyFields = ["tenantID", "userID"]  // ✅ Composite
```

**NOT Supported**:
```swift
// ❌ NestExpression
static var primaryKeyFields = ["user.profile.id"]

// ❌ Custom KeyExpression
static var primaryKeyExpression = MyCustomExpression()
```

**Reason**: Entity.init() assumes `primaryKeyFields.map { FieldKeyExpression(fieldName: $0) }`

**Impact**: 99% of use cases are covered. Complex keys require future enhancement.

### Constraint 2: No Compile-Time Validation

**Issue**:
```swift
struct User: Recordable {
    static var primaryKeyFields = ["userID"]  // 1 field

    func extractPrimaryKey() -> Tuple {
        return Tuple(tenantID, userID)  // 2 fields - MISMATCH!
    }
}
```

**Current Behavior**: No compile-time error, runtime inconsistency possible

**Mitigation**: Developer discipline + code review

**Future Enhancement**: See `docs/future-primarykey-design.md`

## Index Filtering

### Index.recordTypes

```swift
public struct Index {
    public let name: String
    public let type: IndexType
    public let rootExpression: KeyExpression

    // Optional: specific entities
    public let recordTypes: Set<String>?
}
```

**Filtering Logic**:

```swift
// Schema.indexes(for:)
public func indexes(for recordTypeName: String) -> [Index] {
    return indexes.filter { index in
        if let recordTypes = index.recordTypes {
            return recordTypes.contains(recordTypeName)  // Specific entities
        } else {
            return true  // Universal index (nil = all entities)
        }
    }
}
```

**Usage**:
- `IndexManager.getApplicableIndexes(for:)`: Filter indexes for record type
- `OnlineIndexScrubber`: Determine which entities to scrub
- Query planning: Filter available indexes

## Type Safety

### Generic Type Constraints

**Pattern**:
```swift
public struct GenericValueIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
    func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Cast to Recordable for primary key extraction
        if let recordableRecord = newRecord as? any Recordable {
            let primaryKey = recordableRecord.extractPrimaryKey()
        }
    }
}
```

**Safety**:
- ✅ Generic constraint: `Record: Sendable`
- ✅ Runtime cast: `as? any Recordable` (safe optional)
- ✅ Error handling: Throws if cast fails

### RecordStore Cache

**Type Erasure**:
```swift
// RecordContainer.swift
private let storeCache: Mutex<[StoreCacheKey: Any]>  // Type-erased

func store<Record: Recordable>(for type: Record.Type, path: String) -> RecordStore<Record> {
    // Safe cast with type check
    if let cached = storeCache.withLock({ $0[cacheKey] as? RecordStore<Record> }) {
        return cached
    }

    // Create new with concrete type
    let store = RecordStore<Record>(...)
    storeCache.withLock { $0[cacheKey] = store }  // Store as Any
    return store
}
```

**Safety**:
- ✅ Cache key includes type name
- ✅ Safe optional cast on retrieval
- ✅ Type information preserved in generics

## Schema Evolution

### Version Comparison

```swift
// Schema.Version: Comparable
extension Schema.Version: Comparable {
    public static func < (lhs: Schema.Version, rhs: Schema.Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

### MetaDataEvolutionValidator

**Validation Rules**:

1. **Version Progression**: `newSchema.version >= oldSchema.version`
2. **Entity Preservation**: Cannot remove entities
3. **Primary Key Immutability**: `entity.primaryKeyFields` cannot change
4. **Index Compatibility**: Cannot change index disk format without rebuild
5. **FormerIndex Persistence**: FormerIndexes must never be removed

**Usage**:
```swift
let validator = try MetaDataEvolutionValidator(
    oldSchema: oldSchema,
    newSchema: newSchema,
    allowIndexRebuilds: false
)

let result = validator.validate()
if !result.isValid {
    for error in result.errors {
        print(error.description)
    }
}
```

## Best Practices

### 1. Always Use entity.primaryKeyExpression

❌ **Don't**:
```swift
// Building KeyExpression ad-hoc
let expr = FieldKeyExpression(fieldName: entity.primaryKeyFields[0])
```

✅ **Do**:
```swift
// Use canonical expression
let expr = entity.primaryKeyExpression
```

### 2. Validate primaryKeyFields Consistency

```swift
struct User: Recordable {
    static var primaryKeyFields: [String] {
        // ✅ Derive from actual primary key structure
        return ["tenantID", "userID"]
    }

    func extractPrimaryKey() -> Tuple {
        // ✅ Must match primaryKeyFields
        return Tuple(tenantID, userID)
    }
}
```

### 3. Use Index.recordTypes for Filtering

```swift
// Specific entities only
let userEmailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email"),
    recordTypes: ["User"]  // ✅ Specific
)

// Universal index
let createdAtIndex = Index(
    name: "all_by_created_at",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "createdAt"),
    recordTypes: nil  // ✅ Universal (all entities)
)
```

## Future Enhancements

See `docs/future-primarykey-design.md` for planned improvements:

1. **Static primaryKeyExpression in Recordable protocol**
2. **Compile-time validation**
3. **Support for complex KeyExpressions (NestExpression, etc.)**
4. **Runtime consistency checks**

## Related Documentation

- `CLAUDE.md`: FoundationDB usage guide
- `docs/future-primarykey-design.md`: Future primary key design
- `docs/swift-macro-design.md`: SwiftData-style macro API design
