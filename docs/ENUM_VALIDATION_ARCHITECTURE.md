# Enum Validation Architecture - Visual Guide

**Date**: 2025-01-12
**Project**: fdb-record-layer

---

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        @Recordable Macro                             │
│                    (Compile-Time Code Gen)                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Input:                                                               │
│  @Recordable struct User {                                            │
│      @PrimaryKey var userID: Int64                                    │
│      var status: UserStatus  // ← Enum field                         │
│  }                                                                    │
│                                                                       │
│  Detection:                                                           │
│  ┌─────────────────────────────────────────┐                        │
│  │ extractFields()                          │                        │
│  │   └─> analyzeType("UserStatus")          │                        │
│  │         └─> detectLikelyEnumType()        │                        │
│  │               └─> isLikelyEnum = true     │                        │
│  └─────────────────────────────────────────┘                        │
│                                                                       │
│  Code Generation:                                                     │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ extension User: Recordable {                                     ││
│  │     static func enumMetadata(for fieldName: String)              ││
│  │         -> Schema.EnumMetadata? {                                ││
│  │         switch fieldName {                                       ││
│  │         case "status":                                           ││
│  │             if let enumType = UserStatus.self                    ││
│  │                 as? any CaseIterable.Type {                      ││
│  │                 let allCases = enumType.allCases.map("\($0)")    ││
│  │                 return Schema.EnumMetadata(                      ││
│  │                     typeName: "UserStatus",                      ││
│  │                     cases: Set(allCases),                        ││
│  │                     rawValueType: "String"                       ││
│  │                 )                                                ││
│  │             }                                                    ││
│  │         default: return nil                                      ││
│  │         }                                                        ││
│  │     }                                                            ││
│  │ }                                                                ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘

                              ↓ (Generated Code)

┌─────────────────────────────────────────────────────────────────────┐
│                        Schema.Entity                                 │
│                     (Runtime Initialization)                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  init<T: Recordable>(from type: T.Type) {                            │
│      for fieldName in type.allFields {                               │
│          ┌──────────────────────────────────────┐                   │
│          │ Call type.enumMetadata(for: fieldName) │                   │
│          └──────────────┬───────────────────────┘                   │
│                         │                                            │
│                         ↓                                            │
│          ┌──────────────────────────────────────┐                   │
│          │ If enum → Store EnumMetadata          │                   │
│          │ If not  → enumMetadata = nil          │                   │
│          └──────────────────────────────────────┘                   │
│      }                                                               │
│  }                                                                   │
│                                                                       │
│  Result:                                                              │
│  Entity(                                                              │
│      name: "User",                                                    │
│      attributes: [                                                    │
│          Attribute(                                                   │
│              name: "userID",                                          │
│              enumMetadata: nil                                        │
│          ),                                                           │
│          Attribute(                                                   │
│              name: "status",                                          │
│              enumMetadata: EnumMetadata(                              │
│                  typeName: "UserStatus",                              │
│                  cases: ["active", "inactive", "pending"],            │
│                  rawValueType: "String"                               │
│              )                                                        │
│          )                                                            │
│      ]                                                                │
│  )                                                                    │
└─────────────────────────────────────────────────────────────────────┘

                              ↓ (Stored in Schema)

┌─────────────────────────────────────────────────────────────────────┐
│                MetaDataEvolutionValidator                            │
│                    (Schema Evolution Check)                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  validate() async throws -> ValidationResult {                       │
│      var result = ValidationResult.valid                             │
│                                                                       │
│      result = try await validateRecordTypes(result)                  │
│      result = try await validateFields(result)                       │
│      result = try await validateIndexes(result)                      │
│      result = try await validateEnums(result)  // ← NEW              │
│                                                                       │
│      return result                                                   │
│  }                                                                   │
│                                                                       │
│  validateEnums(_ result: ValidationResult) async throws              │
│      -> ValidationResult {                                           │
│                                                                       │
│      For each entity in both old & new schemas:                      │
│          ┌──────────────────────────────────────────┐               │
│          │ For each attribute with enumMetadata:     │               │
│          │                                            │               │
│          │   oldCases = oldAttr.enumMetadata.cases   │               │
│          │   newCases = newAttr.enumMetadata.cases   │               │
│          │                                            │               │
│          │   deletedCases = oldCases - newCases      │               │
│          │                                            │               │
│          │   if deletedCases.isNotEmpty:              │               │
│          │       result.addError(.enumValueDeleted)  │               │
│          └──────────────────────────────────────────┘               │
│                                                                       │
│      return result                                                   │
│  }                                                                   │
│                                                                       │
│  Output:                                                              │
│  ValidationResult(                                                    │
│      isValid: false,                                                  │
│      errors: [                                                        │
│          .enumValueDeleted(                                           │
│              typeName: "User.status (UserStatus)",                    │
│              deletedValues: ["pending"]                               │
│          )                                                            │
│      ]                                                                │
│  )                                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Data Structure Hierarchy

```
Schema
├── version: Version
├── entities: [Entity] ────────────┐
├── indexes: [Index]               │
└── formerIndexes: [String: FormerIndex]
                                   │
                                   ↓
                              Entity
                              ├── name: String
                              ├── attributes: Set<Attribute> ─────┐
                              ├── relationships: Set<Relationship> │
                              ├── indices: [[String]]              │
                              └── primaryKeyExpression: KeyExpression
                                                                   │
                                                                   ↓
                                                         Attribute (EXTENDED)
                                                         ├── name: String
                                                         ├── isOptional: Bool
                                                         ├── isPrimaryKey: Bool
                                                         └── enumMetadata: EnumMetadata? ← NEW
                                                                          │
                                                                          ↓
                                                               EnumMetadata (NEW)
                                                               ├── typeName: String
                                                               ├── cases: Set<String>
                                                               └── rawValueType: String?
```

---

## Sequence Diagram: Schema Initialization

```
User Code                @Recordable Macro           Schema.Entity            Recordable Protocol
    │                          │                          │                          │
    │ let schema =             │                          │                          │
    │ Schema([User.self])      │                          │                          │
    ├──────────────────────────┼──────────────────────────>│                          │
    │                          │                          │                          │
    │                          │                          │ Entity.init(from: User.self)
    │                          │                          ├─────────────────────────>│
    │                          │                          │                          │
    │                          │                          │ User.allFields            │
    │                          │                          │<─────────────────────────┤
    │                          │                          │ ["userID", "status"]      │
    │                          │                          │                          │
    │                          │                          │ For fieldName in allFields:
    │                          │                          │                          │
    │                          │                          │ User.enumMetadata(for: "userID")
    │                          │                          ├─────────────────────────>│
    │                          │ (Generated method)       │<─────────────────────────┤
    │                          │ switch "userID":         │ nil (not enum)            │
    │                          │   default → nil          │                          │
    │                          │                          │                          │
    │                          │                          │ User.enumMetadata(for: "status")
    │                          │                          ├─────────────────────────>│
    │                          │ (Generated method)       │<─────────────────────────┤
    │                          │ switch "status":         │ EnumMetadata(             │
    │                          │   UserStatus.self        │   typeName: "UserStatus", │
    │                          │   as? CaseIterable       │   cases: ["active", ...], │
    │                          │   → return EnumMetadata  │   rawValueType: "String"  │
    │                          │                          │ )                         │
    │                          │                          │                          │
    │                          │                          │ Create Attribute:         │
    │                          │                          │ Attribute(                │
    │                          │                          │   name: "status",         │
    │                          │                          │   enumMetadata: EnumMetadata(...)
    │                          │                          │ )                         │
    │                          │                          │                          │
    │<─────────────────────────┼──────────────────────────┤                          │
    │ schema (ready)           │                          │                          │
```

---

## Sequence Diagram: Validation

```
User Code               MetaDataEvolutionValidator      Schema.Entity          EvolutionError
    │                             │                          │                      │
    │ validator.validate()        │                          │                      │
    ├────────────────────────────>│                          │                      │
    │                             │                          │                      │
    │                             │ validateEnums()          │                      │
    │                             ├─────────────────────────>│                      │
    │                             │                          │                      │
    │                             │ For entity "User":       │                      │
    │                             │   oldEntity.attributes   │                      │
    │                             │<─────────────────────────┤                      │
    │                             │ [Attribute("status", enumMetadata: ...)]        │
    │                             │                          │                      │
    │                             │   newEntity.attributes   │                      │
    │                             │<─────────────────────────┤                      │
    │                             │ [Attribute("status", enumMetadata: ...)]        │
    │                             │                          │                      │
    │                             │ Compare:                 │                      │
    │                             │   oldCases = ["active", "inactive", "pending"]  │
    │                             │   newCases = ["active", "inactive"]             │
    │                             │   deleted  = ["pending"] │                      │
    │                             │                          │                      │
    │                             │ Create error:            │                      │
    │                             ├──────────────────────────┼─────────────────────>│
    │                             │                          │ .enumValueDeleted(   │
    │                             │                          │   "User.status",     │
    │                             │                          │   ["pending"]        │
    │                             │                          │ )                    │
    │                             │<─────────────────────────┼──────────────────────┤
    │                             │                          │                      │
    │<────────────────────────────┤                          │                      │
    │ ValidationResult(           │                          │                      │
    │   isValid: false,           │                          │                      │
    │   errors: [.enumValueDeleted(...)]                     │                      │
    │ )                           │                          │                      │
```

---

## Type Hierarchy: EnumMetadata

```
┌────────────────────────────────────────────────────────────┐
│                   Schema.EnumMetadata                       │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  Properties:                                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ typeName: String                                     │  │
│  │   - Fully qualified enum type name                   │  │
│  │   - Example: "UserStatus"                            │  │
│  │   - Used for error messages                          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ cases: Set<String>                                   │  │
│  │   - All enum case names as strings                   │  │
│  │   - Example: ["active", "inactive", "pending"]       │  │
│  │   - Used for deletion detection                      │  │
│  │   - Set for O(1) lookup and subtraction             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ rawValueType: String?                                │  │
│  │   - Type of raw value (if any)                       │  │
│  │   - "String" | "Int" | nil                           │  │
│  │   - Future: Detect raw value type changes           │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  Protocols:                                                 │
│  - Sendable (thread-safe)                                   │
│  - Hashable (can be used in Set/Dictionary keys)           │
│  - Equatable (automatic via Hashable)                       │
│                                                             │
└────────────────────────────────────────────────────────────┘

                    Created by:
                        ↓
┌────────────────────────────────────────────────────────────┐
│         Generated enumMetadata(for:) Method                 │
├────────────────────────────────────────────────────────────┤
│                                                             │
│  static func enumMetadata(for fieldName: String)            │
│      -> Schema.EnumMetadata? {                              │
│                                                             │
│      1. Switch on fieldName                                 │
│      2. For enum fields:                                    │
│         - Check if type conforms to CaseIterable            │
│         - Extract all cases via allCases                    │
│         - Detect raw value type (String, Int, etc.)         │
│         - Return EnumMetadata                               │
│      3. For non-enum fields:                                │
│         - Return nil                                        │
│  }                                                          │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

---

## Decision Tree: Enum Type Detection

```
                    Field Type Analysis
                            │
                            ↓
            ┌───────────────────────────────┐
            │ Is type in primitive list?    │
            │ (String, Int, Bool, etc.)     │
            └───────────┬───────────────────┘
                        │
            ┌───────────┴───────────┐
            │ YES                   │ NO
            ↓                       ↓
    ┌───────────────┐   ┌───────────────────────┐
    │ Not an enum   │   │ Strip Optional wrapper │
    │ Return false  │   │ Strip Array wrapper    │
    └───────────────┘   └───────────┬───────────┘
                                    ↓
                        ┌───────────────────────┐
                        │ Does baseType start   │
                        │ with uppercase letter?│
                        └───────────┬───────────┘
                                    │
                        ┌───────────┴───────────┐
                        │ YES                   │ NO
                        ↓                       ↓
                ┌───────────────┐   ┌───────────────┐
                │ Likely enum   │   │ Likely custom │
                │ isLikelyEnum  │   │ struct/class  │
                │ = true        │   │ isLikelyEnum  │
                │               │   │ = true (*)    │
                └───────┬───────┘   └───────────────┘
                        │
                        ↓
            ┌───────────────────────────────┐
            │ Runtime check in              │
            │ enumMetadata(for:)             │
            │                                │
            │ if Type is CaseIterable:       │
            │   → Extract cases              │
            │   → Return EnumMetadata        │
            │ else:                          │
            │   → Return nil (safe)          │
            └───────────────────────────────┘

(*) Conservative approach: Mark custom types as potential enums.
    Runtime CaseIterable check provides final confirmation.
```

---

## Validation Logic Flow

```
                    validateEnums() Entry
                            │
                            ↓
            ┌───────────────────────────────┐
            │ Get oldEntities, newEntities  │
            └───────────────┬───────────────┘
                            │
                            ↓
            ┌───────────────────────────────┐
            │ For each (entityName, oldEntity) in oldEntities
            └───────────────┬───────────────┘
                            │
                            ↓
            ┌───────────────────────────────┐
            │ Does entity exist in new?     │
            └───────────┬───────────────────┘
                        │
            ┌───────────┴───────────┐
            │ NO                    │ YES
            ↓                       ↓
    ┌───────────────┐   ┌───────────────────────────┐
    │ Skip          │   │ For each oldAttribute     │
    │ (deleted      │   │   in oldEntity.attributes │
    │  entity)      │   └───────────┬───────────────┘
    └───────────────┘               │
                                    ↓
                        ┌───────────────────────────┐
                        │ Does oldAttribute have    │
                        │ enumMetadata?             │
                        └───────────┬───────────────┘
                                    │
                        ┌───────────┴───────────┐
                        │ NO                    │ YES
                        ↓                       ↓
                ┌───────────────┐   ┌───────────────────────────┐
                │ Skip          │   │ Find newAttribute by name │
                │ (not enum)    │   └───────────┬───────────────┘
                └───────────────┘               │
                                                ↓
                                    ┌───────────────────────────┐
                                    │ Does newAttribute exist?  │
                                    └───────────┬───────────────┘
                                                │
                                    ┌───────────┴───────────┐
                                    │ NO                    │ YES
                                    ↓                       ↓
                            ┌───────────────┐   ┌───────────────────────────┐
                            │ Skip          │   │ Does newAttribute have    │
                            │ (field        │   │ enumMetadata?             │
                            │  deleted)     │   └───────────┬───────────────┘
                            └───────────────┘               │
                                                ┌───────────┴───────────┐
                                                │ NO                    │ YES
                                                ↓                       ↓
                                        ┌───────────────┐   ┌───────────────────────┐
                                        │ Skip          │   │ Compare cases:        │
                                        │ (type changed │   │   deletedCases =      │
                                        │  from enum)   │   │   old.cases - new.cases
                                        └───────────────┘   └───────────┬───────────┘
                                                                        │
                                                                        ↓
                                                            ┌───────────────────────┐
                                                            │ deletedCases.isEmpty? │
                                                            └───────────┬───────────┘
                                                                        │
                                                            ┌───────────┴───────────┐
                                                            │ YES                   │ NO
                                                            ↓                       ↓
                                                    ┌───────────────┐   ┌─────────────────────┐
                                                    │ OK            │   │ Add error:          │
                                                    │ (no deletion) │   │ .enumValueDeleted   │
                                                    └───────────────┘   │   (entityName,      │
                                                                        │    fieldName,       │
                                                                        │    deletedCases)    │
                                                                        └─────────────────────┘
                                                                                    │
                                                                                    ↓
                                                                        ┌─────────────────────┐
                                                                        │ Continue loop       │
                                                                        └─────────────────────┘
                                                                                    │
                                                                                    ↓
                                                                        ┌─────────────────────┐
                                                                        │ Return              │
                                                                        │ ValidationResult    │
                                                                        └─────────────────────┘
```

---

## State Transition Diagram: Enum Evolution

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Schema Version 1                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  enum UserStatus: String, CaseIterable {                             │
│      case active                                                     │
│      case inactive                                                   │
│      case pending                                                    │
│  }                                                                   │
│                                                                       │
│  EnumMetadata(                                                        │
│      typeName: "UserStatus",                                          │
│      cases: ["active", "inactive", "pending"]                        │
│  )                                                                   │
└─────────────────────────────────────────────────────────────────────┘

                              │
                              │ Evolution Attempt
                              ↓

┌─────────────────────────────────────────────────────────────────────┐
│                      Schema Version 2 Options                        │
└─────────────────────────────────────────────────────────────────────┘

┌────────────────────────────┐   ┌────────────────────────────┐
│ Option A: Add Case (SAFE)  │   │ Option B: Delete Case      │
├────────────────────────────┤   │         (UNSAFE)           │
│                            │   ├────────────────────────────┤
│ enum UserStatus {          │   │                            │
│     case active            │   │ enum UserStatus {          │
│     case inactive          │   │     case active            │
│     case pending           │   │     case inactive          │
│     case suspended  ← NEW  │   │     // pending DELETED     │
│ }                          │   │ }                          │
│                            │   │                            │
│ Validation: ✅ PASS        │   │ Validation: ❌ FAIL        │
│                            │   │                            │
│ oldCases: [a, i, p]        │   │ oldCases: [a, i, p]        │
│ newCases: [a, i, p, s]     │   │ newCases: [a, i]           │
│ deleted:  []               │   │ deleted:  [p] ← ERROR      │
│                            │   │                            │
└────────────────────────────┘   └────────────────────────────┘

┌────────────────────────────┐   ┌────────────────────────────┐
│ Option C: Reorder (SAFE)   │   │ Option D: Type Change      │
│ (if not serialized by index)│  │         (UNSAFE)           │
├────────────────────────────┤   ├────────────────────────────┤
│                            │   │                            │
│ enum UserStatus {          │   │ enum AccountState {  ← NEW │
│     case pending           │   │     case active            │
│     case active            │   │     case inactive          │
│     case inactive          │   │ }                          │
│ }                          │   │                            │
│                            │   │ Validation: ❌ FAIL        │
│ Validation: ✅ PASS        │   │                            │
│                            │   │ Caught by:                 │
│ oldCases: [a, i, p]        │   │ validateFields()           │
│ newCases: [p, a, i]        │   │   fieldTypeChanged         │
│ deleted:  []               │   │   (UserStatus →            │
│                            │   │    AccountState)           │
└────────────────────────────┘   └────────────────────────────┘
```

---

## Error Message Examples

### Example 1: Single Enum Value Deleted

```
Input:
  oldSchema: UserStatus = [active, inactive, pending]
  newSchema: UserStatus = [active, inactive]

Output:
  EvolutionError.enumValueDeleted(
      typeName: "User.status (UserStatus)",
      deletedValues: ["pending"]
  )

Formatted Message:
  "Enum 'User.status (UserStatus)' had values deleted: [pending]"
```

### Example 2: Multiple Enum Values Deleted

```
Input:
  oldSchema: OrderState = [pending, processing, shipped, delivered, cancelled]
  newSchema: OrderState = [pending, processing, delivered]

Output:
  EvolutionError.enumValueDeleted(
      typeName: "Order.state (OrderState)",
      deletedValues: ["cancelled", "shipped"]  // Sorted
  )

Formatted Message:
  "Enum 'Order.state (OrderState)' had values deleted: [cancelled, shipped]"
```

### Example 3: Multiple Fields with Enum Deletions

```
Input:
  User.status: active, inactive, pending → active, inactive
  User.role:   admin, user, guest → admin, user

Output:
  [
      EvolutionError.enumValueDeleted(
          typeName: "User.status (UserStatus)",
          deletedValues: ["pending"]
      ),
      EvolutionError.enumValueDeleted(
          typeName: "User.role (UserRole)",
          deletedValues: ["guest"]
      )
  ]

Formatted Messages:
  "Enum 'User.status (UserStatus)' had values deleted: [pending]"
  "Enum 'User.role (UserRole)' had values deleted: [guest]"
```

---

## Performance Characteristics

### Time Complexity

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `enumMetadata(for:)` generation (macro) | O(1) per field | Compile-time code generation |
| `enumMetadata(for:)` call (runtime) | O(1) | Simple switch statement + type check |
| Enum case extraction via `CaseIterable` | O(n) where n = # of cases | Typically <20 cases |
| `Entity.init()` with enum metadata | O(f) where f = # of fields | Linear scan of all fields |
| `validateEnums()` | O(e × a × c) where e = entities, a = attributes, c = cases | Typically e<100, a<50, c<20 |

### Space Complexity

| Structure | Size | Notes |
|-----------|------|-------|
| `EnumMetadata` | ~100 bytes | Overhead per enum field |
| `Set<String>` (cases) | ~50 bytes + (n × 24 bytes) | n = number of cases |
| Total per enum field | ~200 bytes | Negligible for typical schemas |

### Benchmark Targets

- Schema initialization with 100 enum fields: **<1ms**
- Validation with 50 enum fields: **<5ms**
- Memory overhead: **<20KB** per schema

---

**END OF ARCHITECTURE GUIDE**
