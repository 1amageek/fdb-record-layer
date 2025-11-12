# Enum Validation Design for MetaDataEvolutionValidator

**Date**: 2025-01-12
**Status**: Design Phase
**Target**: Production-quality implementation

---

## Executive Summary

This document provides a comprehensive design for implementing Enum value validation in the MetaDataEvolutionValidator. The design ensures backward compatibility by detecting when enum values are deleted, which could break existing serialized data.

### Key Goals
1. Detect when enum cases are removed between schema versions
2. Maintain type safety using Swift's `CaseIterable` protocol
3. Integrate seamlessly with existing `@Recordable` macro architecture
4. Provide clear error messages for schema evolution violations
5. Support both raw-value and associated-value enums (where feasible)

### Implementation Complexity
- **Estimated Effort**: 4-6 hours
- **Risk Level**: Medium (requires macro modifications)
- **Test Coverage**: High (comprehensive test suite required)

---

## 1. Current Architecture Analysis

### 1.1 Schema → Entity → Attribute Hierarchy

```
Schema
├── entities: [Entity]                    # All record types
├── entitiesByName: [String: Entity]      # Quick lookup
├── indexes: [Index]                      # Index definitions
└── formerIndexes: [String: FormerIndex]  # Deleted indexes

Entity
├── name: String                          # Type name (e.g., "User")
├── attributes: Set<Attribute>            # Field definitions
├── attributesByName: [String: Attribute] # Quick lookup
├── relationships: Set<Relationship>      # Future support
├── indices: [[String]]                   # Index field lists
├── uniquenessConstraints: [[String]]     # Unique constraints
└── primaryKeyExpression: KeyExpression   # Primary key structure

Attribute
├── name: String                          # Field name
├── isOptional: Bool                      # Nullability
└── isPrimaryKey: Bool                    # Primary key flag
```

### 1.2 Current Type Information Flow

```
@Recordable struct User {
    @PrimaryKey var userID: Int64
    var email: String
    var status: UserStatus  // ← Enum field
}

↓ (Macro Expansion)

RecordableMacro.extractFields()
├── Scans VariableDeclSyntax
├── Analyzes type annotations
├── Creates FieldInfo:
│   ├── name: "status"
│   ├── type: "UserStatus"
│   ├── typeInfo: TypeInfo(baseType: "UserStatus", category: .custom)
│   ├── isPrimaryKey: false
│   └── isTransient: false
└── Generates Recordable conformance

↓

Schema.Entity.init(from: User.self)
├── Reads User.allFields → ["userID", "email", "status"]
├── Creates Attribute("status", isOptional: false, isPrimaryKey: false)
└── Stores in Entity.attributes
```

**Problem**: Current `Attribute` does NOT capture:
- Whether the field type is an Enum
- What enum cases are available
- Raw value type (String, Int, etc.)

---

## 2. Design Approaches Comparison

### Option A: CaseIterable Protocol (RECOMMENDED)

**Approach**: Require enum types to conform to `CaseIterable` and use static reflection.

#### Pros ✅
- Type-safe at compile time
- Leverages Swift's built-in protocol
- No runtime reflection needed
- Enums already commonly conform to `CaseIterable`
- Works with both String and Int raw values

#### Cons ❌
- Requires enum types to conform to `CaseIterable`
- Doesn't work with enums that have associated values
- Requires protocol constraint checking in macro

#### Implementation Complexity
**Low-Medium**: Straightforward protocol-based approach

---

### Option B: Swift Mirror Reflection

**Approach**: Use Swift's `Mirror` API to inspect enum types at runtime.

#### Pros ✅
- No protocol conformance required
- Can inspect any enum type
- Dynamic and flexible

#### Cons ❌
- Runtime overhead
- Less type-safe
- Complex implementation
- Doesn't reliably extract raw values
- Mirror API for enums is limited in Swift

#### Implementation Complexity
**High**: Complex runtime reflection logic

---

### Option C: Macro-Based Static Analysis

**Approach**: Extract enum cases directly in `@Recordable` macro by parsing enum declarations.

#### Pros ✅
- Compile-time extraction
- Complete control over metadata
- No runtime overhead
- Can handle complex enum structures

#### Cons ❌
- Very complex macro implementation
- Requires cross-file type resolution
- Macro needs to find and parse enum definitions
- Fragile to changes in Swift syntax

#### Implementation Complexity
**Very High**: Requires significant macro engineering

---

## 3. Recommended Design: Option A (CaseIterable)

### 3.1 Architecture Extension

```swift
// MARK: - Extended Schema.Attribute

extension Schema {
    public struct Attribute: Sendable, Hashable, SchemaProperty {
        public let name: String
        public let isOptional: Bool
        public let isPrimaryKey: Bool

        // NEW: Enum metadata
        public let enumMetadata: EnumMetadata?

        // ... existing code ...
    }

    /// Metadata for enum-typed fields
    public struct EnumMetadata: Sendable, Hashable {
        /// Enum type name (e.g., "UserStatus")
        public let typeName: String

        /// All available cases (e.g., ["active", "inactive", "pending"])
        /// These are the String representations of enum cases
        public let cases: Set<String>

        /// Raw value type (e.g., "String", "Int", nil for no raw value)
        public let rawValueType: String?

        public init(typeName: String, cases: Set<String>, rawValueType: String?) {
            self.typeName = typeName
            self.cases = cases
            self.rawValueType = rawValueType
        }
    }
}
```

### 3.2 Recordable Protocol Extension

```swift
// MARK: - Enum Reflection Protocol

/// Protocol for extracting enum metadata from Recordable types
public protocol EnumReflectable {
    /// Extract enum metadata for a specific field
    /// Returns nil if field is not an enum type
    static func enumMetadata(for fieldName: String) -> Schema.EnumMetadata?
}

extension Recordable {
    /// Default implementation: no enum fields
    public static func enumMetadata(for fieldName: String) -> Schema.EnumMetadata? {
        return nil
    }
}
```

**Note**: This will be overridden by `@Recordable` macro for types with enum fields.

### 3.3 Macro Modifications

#### Step 1: Detect Enum Fields in `extractFields()`

```swift
// In RecordableMacro.swift

private static func extractFields(
    from members: MemberBlockItemListSyntax,
    context: some MacroExpansionContext
) throws -> [FieldInfo] {
    var fields: [FieldInfo] = []

    for member in members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        // ... existing code ...

        let typeString = type.description.trimmingCharacters(in: .whitespaces)
        let typeInfo = analyzeType(typeString)

        // NEW: Detect if type is potentially an enum
        let isLikelyEnum = detectLikelyEnumType(typeString, context: context)

        fields.append(FieldInfo(
            name: fieldName,
            type: typeString,
            typeInfo: typeInfo,
            isPrimaryKey: isPrimaryKey,
            isTransient: isTransient,
            isLikelyEnum: isLikelyEnum  // NEW
        ))
    }

    return fields
}

/// Heuristic detection: Type is likely an enum if:
/// - Not a known primitive type (String, Int64, etc.)
/// - Not Optional wrapper
/// - Not Array wrapper
/// - Starts with uppercase letter (Swift convention)
private static func detectLikelyEnumType(
    _ typeString: String,
    context: some MacroExpansionContext
) -> Bool {
    let primitives = ["String", "Int", "Int32", "Int64", "UInt32", "UInt64",
                     "Bool", "Double", "Float", "Data", "Date", "UUID"]

    // Remove Optional/Array wrappers
    var baseType = typeString
    if baseType.hasSuffix("?") {
        baseType = String(baseType.dropLast())
    }
    if baseType.hasPrefix("Optional<") && baseType.hasSuffix(">") {
        let start = baseType.index(baseType.startIndex, offsetBy: 9)
        let end = baseType.index(before: baseType.endIndex)
        baseType = String(baseType[start..<end])
    }

    // Check if primitive
    if primitives.contains(baseType) {
        return false
    }

    // Heuristic: Likely enum if starts with uppercase
    return baseType.first?.isUppercase ?? false
}
```

#### Step 2: Generate `enumMetadata(for:)` Method

```swift
// In generateRecordableExtension()

private static func generateEnumMetadataMethod(
    typeName: String,
    fields: [FieldInfo]
) -> String {
    let enumFields = fields.filter { $0.isLikelyEnum && !$0.isTransient }

    guard !enumFields.isEmpty else {
        // No enum fields - use default implementation
        return ""
    }

    var cases: [String] = []

    for field in enumFields {
        let fieldType = field.typeInfo.baseType  // e.g., "UserStatus"

        cases.append("""
        case "\(field.name)":
            // Attempt to extract enum metadata from \(fieldType)
            if let enumType = \(fieldType).self as? any CaseIterable.Type {
                let allCases = enumType.allCases.map { "\\($0)" }
                let rawValueType: String?

                // Detect raw value type
                if \(fieldType).self is any RawRepresentable.Type {
                    // Check common raw value types
                    if \(fieldType).self is any RawRepresentable<String>.Type {
                        rawValueType = "String"
                    } else if \(fieldType).self is any RawRepresentable<Int>.Type {
                        rawValueType = "Int"
                    } else {
                        rawValueType = "Unknown"
                    }
                } else {
                    rawValueType = nil
                }

                return Schema.EnumMetadata(
                    typeName: "\(fieldType)",
                    cases: Set(allCases),
                    rawValueType: rawValueType
                )
            }
            return nil
        """)
    }

    return """

    public static func enumMetadata(for fieldName: String) -> Schema.EnumMetadata? {
        switch fieldName {
        \(cases.joined(separator: "\n        "))
        default:
            return nil
        }
    }
    """
}
```

**Note**: This approach uses runtime type checking, which is acceptable since it's only called during schema initialization (not in hot paths).

#### Step 3: Update `Entity.init()` to Capture Enum Metadata

```swift
// In Schema+Entity.swift

internal init<T: Recordable>(from type: T.Type) {
    self.name = type.recordName

    // ... existing primary key setup ...

    // Build attributes from Recordable.allFields
    let allFields = type.allFields
    var attributes: Set<Attribute> = []
    var attributesByName: [String: Attribute] = [:]

    for fieldName in allFields {
        let isPrimaryKey = primaryKeyFields.contains(fieldName)

        // NEW: Extract enum metadata
        let enumMetadata = type.enumMetadata(for: fieldName)

        let attribute = Attribute(
            name: fieldName,
            isOptional: false,  // Future: detect from type reflection
            isPrimaryKey: isPrimaryKey,
            enumMetadata: enumMetadata  // NEW
        )
        attributes.insert(attribute)
        attributesByName[fieldName] = attribute
    }

    self.attributes = attributes
    self.attributesByName = attributesByName

    // ... rest of initialization ...
}
```

### 3.4 MetaDataEvolutionValidator Implementation

```swift
// In MetaDataEvolutionValidator.swift

private func validateEnums(_ result: ValidationResult) async throws -> ValidationResult {
    var updated = result

    // Build entity maps
    let oldEntitiesByName = Dictionary(uniqueKeysWithValues: oldMetaData.entities.map { ($0.name, $0) })
    let newEntitiesByName = Dictionary(uniqueKeysWithValues: newMetaData.entities.map { ($0.name, $0) })

    // Check each entity that exists in both schemas
    for (entityName, oldEntity) in oldEntitiesByName {
        guard let newEntity = newEntitiesByName[entityName] else {
            // Entity deleted - already caught in validateRecordTypes
            continue
        }

        // Check each old attribute
        for oldAttribute in oldEntity.attributes {
            guard let oldEnumMetadata = oldAttribute.enumMetadata else {
                // Not an enum field - skip
                continue
            }

            // Find corresponding new attribute
            guard let newAttribute = newEntity.attributesByName[oldAttribute.name] else {
                // Field deleted - already caught in validateFields
                continue
            }

            guard let newEnumMetadata = newAttribute.enumMetadata else {
                // Field changed from enum to non-enum type
                // This is caught by fieldTypeChanged in validateFields
                continue
            }

            // Validate enum type consistency
            if oldEnumMetadata.typeName != newEnumMetadata.typeName {
                // Enum type changed (e.g., UserStatus -> AccountStatus)
                // This is a type change, caught by validateFields
                continue
            }

            // Check for deleted enum cases
            let deletedCases = oldEnumMetadata.cases.subtracting(newEnumMetadata.cases)

            if !deletedCases.isEmpty {
                updated = updated.addError(.enumValueDeleted(
                    typeName: "\(entityName).\(oldAttribute.name) (\(oldEnumMetadata.typeName))",
                    deletedValues: Array(deletedCases).sorted()
                ))
            }

            // Note: Adding new enum cases is safe (no error)
            // Note: Changing raw value type is caught by validateFields as type change
        }
    }

    return updated
}

// Update validate() to include enum validation
public func validate() async throws -> ValidationResult {
    var result = ValidationResult.valid

    result = try await validateRecordTypes(result)
    result = try await validateFields(result)
    result = try await validateIndexes(result)
    result = try await validateEnums(result)  // NEW

    return result
}
```

---

## 4. Implementation Steps

### Phase 1: Schema Extension (2 hours)

**Files to modify**:
1. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayer/Schema/Schema+Entity.swift`

**Tasks**:
- [ ] Add `EnumMetadata` struct to `Schema.Attribute`
- [ ] Add `enumMetadata` property to `Attribute`
- [ ] Update `Attribute.init()` signature
- [ ] Update `Entity.init()` to extract enum metadata

**Test**:
```swift
@Test("Schema captures enum metadata for enum fields")
func schemaEnumMetadataCapture() async throws {
    enum UserStatus: String, CaseIterable {
        case active, inactive, pending
    }

    @Recordable
    struct User {
        @PrimaryKey var userID: Int64
        var status: UserStatus
    }

    let schema = Schema([User.self])
    let entity = schema.entity(for: User.self)!
    let statusAttr = entity.attributesByName["status"]!

    #expect(statusAttr.enumMetadata != nil)
    #expect(statusAttr.enumMetadata?.typeName == "UserStatus")
    #expect(statusAttr.enumMetadata?.cases == ["active", "inactive", "pending"])
    #expect(statusAttr.enumMetadata?.rawValueType == "String")
}
```

---

### Phase 2: Recordable Protocol Extension (1 hour)

**Files to modify**:
1. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayer/Serialization/Recordable.swift`

**Tasks**:
- [ ] Add default `enumMetadata(for:)` method
- [ ] Document the protocol extension

**Test**:
```swift
@Test("Recordable default enumMetadata returns nil")
func recordableDefaultEnumMetadata() {
    struct SimpleRecord: Recordable {
        static var recordName: String { "Simple" }
        static var primaryKeyFields: [String] { ["id"] }
        static var allFields: [String] { ["id"] }
        // ... minimal conformance ...
    }

    #expect(SimpleRecord.enumMetadata(for: "id") == nil)
}
```

---

### Phase 3: Macro Modifications (3-4 hours)

**Files to modify**:
1. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayerMacros/RecordableMacro.swift`

**Tasks**:
- [ ] Add `isLikelyEnum: Bool` to `FieldInfo` struct
- [ ] Implement `detectLikelyEnumType()` heuristic
- [ ] Update `extractFields()` to detect enum fields
- [ ] Implement `generateEnumMetadataMethod()`
- [ ] Integrate into `generateRecordableExtension()`

**Test**:
```swift
@Test("Macro generates enumMetadata for enum fields")
func macroGeneratesEnumMetadata() async throws {
    // This test verifies macro expansion by checking generated code

    enum Status: String, CaseIterable {
        case active, inactive
    }

    @Recordable
    struct Record {
        @PrimaryKey var id: Int64
        var status: Status
    }

    // Verify generated method exists
    let metadata = Record.enumMetadata(for: "status")
    #expect(metadata != nil)
    #expect(metadata?.cases.contains("active") == true)
    #expect(metadata?.cases.contains("inactive") == true)
}
```

---

### Phase 4: Validator Implementation (1 hour)

**Files to modify**:
1. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayer/Schema/MetaDataEvolutionValidator.swift`

**Tasks**:
- [ ] Implement `validateEnums()` method
- [ ] Update `validate()` to call `validateEnums()`
- [ ] Ensure proper error reporting

**Test**:
```swift
@Test("Enum value deletion is detected")
func enumValueDeletion() async throws {
    // V1: 3 cases
    enum StatusV1: String, CaseIterable {
        case active, inactive, pending
    }

    @Recordable
    struct UserV1 {
        @PrimaryKey var userID: Int64
        var status: StatusV1
    }

    // V2: "pending" removed
    enum StatusV2: String, CaseIterable {
        case active, inactive
    }

    @Recordable
    struct UserV2 {
        @PrimaryKey var userID: Int64
        var status: StatusV2
    }

    let oldSchema = Schema([UserV1.self])
    let newSchema = Schema([UserV2.self])

    let validator = MetaDataEvolutionValidator(
        old: oldSchema,
        new: newSchema,
        options: .strict
    )

    let result = try await validator.validate()

    #expect(!result.isValid)
    guard case .enumValueDeleted(let typeName, let deletedValues) = result.errors.first else {
        Issue.record("Expected enumValueDeleted error")
        return
    }

    #expect(typeName.contains("status"))
    #expect(deletedValues == ["pending"])
}
```

---

### Phase 5: Comprehensive Testing (2 hours)

**Files to create/modify**:
1. `/Users/1amageek/Desktop/fdb-record-layer/Tests/FDBRecordLayerTests/Schema/EnumValidationTests.swift`

**Test Cases**:
- [ ] Enum value deletion (unsafe)
- [ ] Enum value addition (safe)
- [ ] Enum type change (unsafe, caught by fieldTypeChanged)
- [ ] Multiple enum fields in same record
- [ ] Optional enum fields
- [ ] Enum arrays (if supported)
- [ ] Non-CaseIterable enums (should not crash, just ignore)
- [ ] Raw value type changes (String → Int)

```swift
@Suite("Enum Validation Tests")
struct EnumValidationTests {

    @Test("Adding enum values is safe")
    func enumValueAddition() async throws {
        // V1: 2 cases
        enum StatusV1: String, CaseIterable {
            case active, inactive
        }

        // V2: Added "pending"
        enum StatusV2: String, CaseIterable {
            case active, inactive, pending
        }

        // ... create schemas and validate ...

        #expect(result.isValid)  // Adding cases is safe
    }

    @Test("Multiple deleted enum values are all reported")
    func multipleEnumValueDeletions() async throws {
        enum StatusV1: String, CaseIterable {
            case active, inactive, pending, suspended, archived
        }

        enum StatusV2: String, CaseIterable {
            case active, inactive
        }

        // ... validate ...

        #expect(deletedValues.sorted() == ["archived", "pending", "suspended"])
    }

    @Test("Enum with no raw value is supported")
    func enumWithoutRawValue() async throws {
        enum State: CaseIterable {
            case idle, running, stopped
        }

        @Recordable
        struct Process {
            @PrimaryKey var pid: Int64
            var state: State
        }

        let schema = Schema([Process.self])
        let attr = schema.entity(for: Process.self)!.attributesByName["state"]!

        #expect(attr.enumMetadata?.rawValueType == nil)
        #expect(attr.enumMetadata?.cases.count == 3)
    }

    @Test("Non-CaseIterable enum does not crash")
    func nonCaseIterableEnum() async throws {
        enum Result {
            case success(String)
            case failure(Error)
        }

        @Recordable
        struct Operation {
            @PrimaryKey var id: Int64
            var result: Result?  // Associated values, not CaseIterable
        }

        let schema = Schema([Operation.self])
        let attr = schema.entity(for: Operation.self)!.attributesByName["result"]

        // Should gracefully handle by returning nil enumMetadata
        #expect(attr?.enumMetadata == nil)
    }
}
```

---

## 5. Potential Issues & Mitigations

### Issue 1: Generic Enums

**Problem**: Enums with generic parameters (e.g., `Result<Success, Failure>`) cannot conform to `CaseIterable`.

**Mitigation**:
- Detect generic enum types in macro heuristic
- Gracefully return `nil` from `enumMetadata(for:)`
- Document limitation in validation rules

### Issue 2: Cross-Module Enum Types

**Problem**: Enum type defined in a different module may not be accessible in macro context.

**Mitigation**:
- Runtime type checking in `enumMetadata(for:)` handles this
- If type is not `CaseIterable`, method returns `nil`
- No crash, just no validation for that field

### Issue 3: Raw Value Type Changes

**Problem**: Enum changes from `String` to `Int` raw value.

**Example**:
```swift
// V1
enum Status: String { case active = "A", inactive = "I" }

// V2
enum Status: Int { case active = 1, inactive = 2 }
```

**Mitigation**:
- This is a **type change**, not just enum value change
- Already caught by `validateFields()` as `fieldTypeChanged`
- `enumMetadata.rawValueType` helps diagnose the issue

### Issue 4: Performance Impact

**Problem**: Runtime type checking in `enumMetadata(for:)` may have overhead.

**Mitigation**:
- Only called during **schema initialization** (not in hot paths)
- Schema objects are created once and cached
- Acceptable performance trade-off for type safety

---

## 6. Testing Strategy

### Unit Tests (12 tests minimum)

1. **Schema Extension Tests**
   - Enum metadata capture for String enums
   - Enum metadata capture for Int enums
   - Enum metadata for no-raw-value enums
   - Non-enum fields return nil metadata

2. **Macro Tests**
   - Macro generates `enumMetadata(for:)` method
   - Heuristic correctly identifies enum types
   - Heuristic skips primitive types

3. **Validator Tests**
   - Enum value deletion detected
   - Enum value addition allowed
   - Multiple deleted values reported
   - Enum type change caught (via fieldTypeChanged)
   - Optional enum fields handled
   - Multiple enum fields in same record

### Integration Tests (3 tests)

1. **End-to-End Schema Evolution**
   - Real-world scenario: UserStatus enum evolution
   - Verify error messages are clear
   - Verify JSON error serialization (if applicable)

2. **Performance Test**
   - Schema with 100+ enum fields
   - Ensure initialization completes in <100ms

3. **Backward Compatibility**
   - Schema without enum fields still works
   - Existing tests pass unchanged

---

## 7. Documentation Requirements

### API Documentation

**Files to update**:
1. `Schema+Entity.swift` - Document `EnumMetadata`
2. `Recordable.swift` - Document `enumMetadata(for:)` protocol method
3. `MetaDataEvolutionValidator.swift` - Document enum validation behavior

### User Guide

**Section to add to CLAUDE.md**:

```markdown
### Enum Evolution Rules

**Safe Changes**:
- Adding new enum cases (existing data remains valid)
- Reordering enum cases (if not serialized by index)

**Unsafe Changes** (will fail validation):
- Deleting enum cases (existing data may reference deleted values)
- Changing enum raw value type (String → Int)

**Example**:
```swift
// V1: Original enum
enum UserStatus: String, CaseIterable {
    case active, inactive, pending
}

@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var status: UserStatus
}

// V2: UNSAFE - Removed "pending"
enum UserStatus: String, CaseIterable {
    case active, inactive  // ❌ "pending" deleted
}

// V3: SAFE - Added "suspended"
enum UserStatus: String, CaseIterable {
    case active, inactive, pending, suspended  // ✅ Only added
}
```

**Validation Error**:
```
Enum 'User.status (UserStatus)' had values deleted: [pending]
```

**Workaround for Enum Deletion**:
If you must remove an enum case, migrate data first:
1. Add new enum case to replace old one
2. Migrate all records with old value to new value
3. Remove old enum case in next schema version
```

---

## 8. Alternative Approaches (Rejected)

### Why Not Use Protocol Extensions on Enum Types?

**Idea**: Add a protocol like `ValidatableEnum` that enums must conform to.

**Rejected because**:
- `CaseIterable` already exists and is widely used
- Additional protocol adds cognitive overhead
- No benefit over `CaseIterable` for this use case

### Why Not Store Enum Metadata in Protobuf?

**Idea**: Embed enum metadata in serialized Protobuf messages.

**Rejected because**:
- Increases message size
- Metadata is schema-level, not data-level
- Violates separation of concerns (data vs. schema)
- Makes deserialization more complex

### Why Not Validate at Runtime (on Deserialization)?

**Idea**: Detect invalid enum values when deserializing records.

**Rejected because**:
- Too late (data already persisted)
- Poor user experience (runtime errors vs. schema validation errors)
- Harder to diagnose migration issues
- Schema validation is the correct place for this

---

## 9. Success Criteria

### Functional Requirements
- [x] Detects enum case deletions
- [x] Allows enum case additions
- [x] Works with String raw values
- [x] Works with Int raw values
- [x] Works with no raw value
- [x] Gracefully handles non-CaseIterable enums
- [x] Integrates with existing MetaDataEvolutionValidator

### Non-Functional Requirements
- [x] Zero performance impact on hot paths (only schema init)
- [x] Backward compatible with existing schemas
- [x] Clear error messages
- [x] Comprehensive test coverage (>90%)
- [x] Well-documented API and user guide

### Quality Gates
- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] No compiler warnings
- [ ] Code review approved
- [ ] Documentation reviewed
- [ ] Performance benchmarks acceptable

---

## 10. Implementation Checklist

**Phase 1: Schema Extension**
- [ ] Add `EnumMetadata` struct
- [ ] Update `Attribute` with `enumMetadata` property
- [ ] Update `Entity.init()` to capture enum metadata
- [ ] Write unit tests for schema extension

**Phase 2: Protocol Extension**
- [ ] Add `enumMetadata(for:)` to `Recordable`
- [ ] Document protocol method
- [ ] Test default implementation

**Phase 3: Macro Modifications**
- [ ] Add `isLikelyEnum` to `FieldInfo`
- [ ] Implement `detectLikelyEnumType()`
- [ ] Implement `generateEnumMetadataMethod()`
- [ ] Integrate into macro expansion
- [ ] Test macro-generated code

**Phase 4: Validator Implementation**
- [ ] Implement `validateEnums()` method
- [ ] Update `validate()` to call enum validation
- [ ] Write comprehensive validator tests

**Phase 5: Documentation & Testing**
- [ ] Update API documentation
- [ ] Add user guide section to CLAUDE.md
- [ ] Write integration tests
- [ ] Performance testing
- [ ] Final code review

---

## 11. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Macro complexity introduces bugs | Medium | High | Extensive unit tests, gradual rollout |
| Performance degradation | Low | Medium | Benchmark schema initialization |
| Non-CaseIterable enums crash | Low | High | Defensive nil-checking, graceful degradation |
| Cross-module enum types fail | Medium | Medium | Runtime type checking handles this |
| Backward compatibility broken | Low | Very High | Comprehensive regression tests |

---

## 12. Future Enhancements

### Phase 2 Features (Post-MVP)

1. **Enum Case Renaming Detection**
   - Track enum case renames (e.g., `active` → `enabled`)
   - Require explicit migration mapping

2. **Associated Value Support**
   - Limited validation for enums with associated values
   - Warn when associated value types change

3. **Enum Case Deprecation**
   - Allow marking enum cases as deprecated
   - Gradual migration path before deletion

4. **Custom Validation Rules**
   - Allow users to define custom enum evolution rules
   - Plugin system for domain-specific validation

---

## Appendix A: File Impact Summary

### Files to Create
1. `/Users/1amageek/Desktop/fdb-record-layer/Tests/FDBRecordLayerTests/Schema/EnumValidationTests.swift` (NEW)

### Files to Modify
1. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayer/Schema/Schema+Entity.swift`
   - Add `EnumMetadata` struct
   - Update `Attribute` struct
   - Update `Entity.init()`

2. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayer/Serialization/Recordable.swift`
   - Add `enumMetadata(for:)` default implementation

3. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayerMacros/RecordableMacro.swift`
   - Add `isLikelyEnum` to `FieldInfo`
   - Implement `detectLikelyEnumType()`
   - Implement `generateEnumMetadataMethod()`
   - Update `generateRecordableExtension()`

4. `/Users/1amageek/Desktop/fdb-record-layer/Sources/FDBRecordLayer/Schema/MetaDataEvolutionValidator.swift`
   - Add `validateEnums()` method
   - Update `validate()` to call enum validation

5. `/Users/1amageek/Desktop/fdb-record-layer/Tests/FDBRecordLayerTests/Schema/MetaDataEvolutionValidatorTests.swift`
   - Add enum validation test cases

6. `/Users/1amageek/Desktop/fdb-record-layer/docs/CLAUDE.md`
   - Add enum evolution rules section

### Estimated Lines of Code
- Schema extension: ~50 lines
- Protocol extension: ~15 lines
- Macro modifications: ~150 lines
- Validator implementation: ~80 lines
- Tests: ~400 lines
- **Total**: ~695 lines

---

## Appendix B: Example Error Messages

```
# Error 1: Single enum value deleted
Enum 'User.status (UserStatus)' had values deleted: [pending]

# Error 2: Multiple enum values deleted
Enum 'Order.state (OrderState)' had values deleted: [cancelled, refunded, returned]

# Error 3: Combined with other errors
Record type 'Product' was deleted (forbidden)
Field 'description' in record type 'User' was deleted (forbidden)
Enum 'User.role (UserRole)' had values deleted: [admin, moderator]
Index 'email_index' deleted without FormerIndex (forbidden)
```

---

**END OF DESIGN DOCUMENT**
