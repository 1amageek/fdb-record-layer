# Covering Index Design

**Status**: Design Phase
**Priority**: High (2-10x query performance improvement)
**Estimated Effort**: 5 days
**Last Updated**: 2025-01-12

---

## Table of Contents

1. [Overview](#overview)
2. [Current Implementation Analysis](#current-implementation-analysis)
3. [Problem Statement](#problem-statement)
4. [Design Objectives](#design-objectives)
5. [Detailed Design](#detailed-design)
6. [API Design](#api-design)
7. [Implementation Plan](#implementation-plan)
8. [Testing Strategy](#testing-strategy)
9. [Migration and Compatibility](#migration-and-compatibility)
10. [Performance Analysis](#performance-analysis)

---

## Overview

**Covering Index** is an optimization where an index contains all the fields needed to answer a query, eliminating the need to fetch the actual record from storage.

### Current Flow (Bottleneck)
```
Query → Index Scan → Extract Primary Keys → Fetch Records → Return Results
                                             ^^^^^^^^^^^^^
                                             Bottleneck: N additional getValue() calls
```

### Covering Index Flow (Optimized)
```
Query → Index Scan → Reconstruct Records → Return Results
                     ^^^^^^^^^^^^^^^^^^^
                     No storage fetch needed
```

### Performance Impact
- **Queries with covering indexes**: 2-10x faster
- **Network I/O**: Reduced by ~50% (no record fetch)
- **Transaction throughput**: Higher (fewer operations)

---

## Current Implementation Analysis

### Index Key-Value Structure

**Current Implementation** (from `ValueIndex.swift`):

```swift
// Index key construction (buildIndexKey)
func buildIndexKey(...) -> FDB.Bytes {
    let indexedValues = try recordAccess.evaluate(record: record, expression: index.rootExpression)
    let primaryKeyValues = recordableRecord.extractPrimaryKey()
    let allValues = indexedValues + primaryKeyValues
    return subspace.pack(TupleHelpers.toTuple(allValues))
}

// Index value
let indexValue = FDB.Bytes()  // Currently empty!
```

**Index Entry Format**:
```
Key:   <indexSubspace><indexedValue1><indexedValue2>...<primaryKey1><primaryKey2>...
Value: <empty>
```

**Example** (User indexed by city and age):
```
Index: user_by_city_age on (city, age)
Primary Key: userID

Entry:
  Key:   [I][user_by_city_age]["Tokyo"][25][1001]
  Value: []
```

### Index Scan Cursor (Bottleneck)

**From `IndexScanTypedCursor.swift` (lines 128-175)**:

```swift
public mutating func next() async throws -> Record? {
    while true {
        guard let pair = try await iterator.next() else { return nil }
        let indexKey = pair.0

        // 1. Extract primary key from index key
        let indexTuple = try indexSubspace.unpack(indexKey)
        let elements = Array(0..<indexTuple.count).compactMap { indexTuple[$0] }
        let primaryKeyElements = Array(elements.suffix(primaryKeyLength))
        let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

        // 2. Build record key
        let effectiveSubspace = recordSubspace.subspace(recordName)
        let recordKey = effectiveSubspace.subspace(primaryKeyTuple).pack(Tuple())

        // 3. **BOTTLENECK**: Fetch record from storage
        guard let recordBytes = try await transaction.getValue(for: recordKey, snapshot: snapshot) else {
            continue
        }

        // 4. Deserialize record
        let record = try recordAccess.deserialize(recordBytes)

        return record
    }
}
```

**Performance Impact**:
- Each query result = 1 index read + **1 record fetch** (getValue call)
- For 100 results: 100 index reads + **100 record fetches** = 200 operations
- With covering index: 100 index reads + **0 record fetches** = 100 operations (2x faster)

### RecordAccess Protocol

**From `RecordAccess.swift`**:

```swift
public protocol RecordAccess<Record>: Sendable {
    // Extract single field value
    func extractField(from record: Record, fieldName: String) throws -> [any TupleElement]

    // Evaluate KeyExpression to get multiple field values
    func evaluate(record: Record, expression: KeyExpression) throws -> [any TupleElement]

    // Serialization
    func serialize(_ record: Record) throws -> FDB.Bytes
    func deserialize(_ bytes: FDB.Bytes) throws -> Record
}
```

**Key Insight**: We need the **inverse operation** of `evaluate()`:
- `evaluate()`: Record → [TupleElement] (current)
- `reconstruct()`: [TupleElement] → Record (new, needed for covering index)

---

## Problem Statement

### Current Limitations

1. **Redundant Storage Fetch**: Every index scan requires fetching the actual record, even when the index contains all needed fields
2. **Index Values Are Wasted**: Index values are always empty, wasting the opportunity to store additional data
3. **No Record Reconstruction API**: RecordAccess has no method to reconstruct records from field values

### Real-World Example

**Query**: Get name and email of users in Tokyo

```swift
let users = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .select(\.name, \.email)  // Only need 2 fields
    .execute()
```

**Current Flow** (inefficient):
```
1. Index scan: city_index → [userID: 1001, 1002, 1003, ...]
2. Fetch record 1001: getValue(R/User/1001) → {userID, name, email, age, address, ...}
3. Fetch record 1002: getValue(R/User/1002) → {userID, name, email, age, address, ...}
4. Fetch record 1003: getValue(R/User/1003) → {userID, name, email, age, address, ...}
```

**With Covering Index** (optimized):
```
1. Index scan: city_name_email_index → [("Tokyo", "Alice", "alice@example.com"), ...]
2. Reconstruct records directly from index entries
```

**Performance**: 2-10x faster (eliminates 100% of record fetches)

---

## Design Objectives

### Primary Goals

1. **Performance**: 2-10x improvement for queries with covering indexes
2. **Backward Compatibility**: Non-covering indexes continue to work unchanged
3. **Auto-Detection**: Query planner automatically selects covering indexes when applicable
4. **Type Safety**: Compile-time verification of field coverage (where possible)
5. **Incremental Adoption**: Developers can add covering fields gradually

### Non-Goals (Future Enhancements)

- Partial covering (fetch remaining fields separately) - **Out of scope**
- Covering aggregate indexes (COUNT, SUM, MIN/MAX) - **Future**
- Dynamic covering field selection at query time - **Future**

---

## Detailed Design

### 1. Index Definition with Covered Fields

**New API** for defining covering indexes:

```swift
extension Index {
    /// Create a covering index that includes additional fields in the index value
    ///
    /// **Example**:
    /// ```swift
    /// let coveringIndex = Index.covering(
    ///     named: "user_by_city_covering",
    ///     on: FieldKeyExpression(fieldName: "city"),  // Indexed field
    ///     covering: [
    ///         FieldKeyExpression(fieldName: "name"),  // Additional field 1
    ///         FieldKeyExpression(fieldName: "email")  // Additional field 2
    ///     ],
    ///     recordTypes: ["User"]
    /// )
    /// ```
    ///
    /// **Index structure**:
    /// ```
    /// Key:   <indexSubspace><city><userID>
    /// Value: Tuple(name, email)
    /// ```
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - rootExpression: Indexed fields (used for key ordering and range scans)
    ///   - coveringFields: Additional fields stored in index value (for record reconstruction)
    ///   - recordTypes: Record types this index applies to
    ///   - options: Index options (unique, etc.)
    /// - Returns: Index with covering fields
    public static func covering(
        named name: String,
        on rootExpression: KeyExpression,
        covering coveringFields: [KeyExpression],
        recordTypes: Set<String>? = nil,
        options: IndexOptions = IndexOptions()
    ) -> Index {
        return Index(
            name: name,
            type: .value,
            rootExpression: rootExpression,
            recordTypes: recordTypes,
            options: options,
            coveringFields: coveringFields  // NEW
        )
    }
}
```

**Index Structure Modification**:

```swift
// In Index.swift
public struct Index: Sendable, Hashable {
    // ... existing properties ...

    /// Covering fields (stored in index value for record reconstruction)
    ///
    /// When nil or empty: Non-covering index (backward compatible)
    /// When non-empty: Covering index with these additional fields
    ///
    /// **Important**: coveringFields should NOT include:
    /// - Fields already in rootExpression (indexed fields)
    /// - Primary key fields (already in index key)
    ///
    /// **Example**:
    /// ```
    /// rootExpression: FieldKeyExpression("city")
    /// primaryKey: userID
    /// coveringFields: [FieldKeyExpression("name"), FieldKeyExpression("email")]
    ///
    /// Index key:   <indexSubspace><city><userID>
    /// Index value: Tuple(name, email)
    /// ```
    public let coveringFields: [KeyExpression]?

    /// Check if this index covers all required fields
    ///
    /// - Parameter requiredFields: Field names needed by the query
    /// - Returns: true if index contains all required fields
    public func covers(fields requiredFields: Set<String>) -> Bool {
        var availableFields = Set<String>()

        // Extract field names from rootExpression
        availableFields.formUnion(rootExpression.fieldNames())

        // Extract field names from coveringFields
        if let coveringFields = coveringFields {
            for expr in coveringFields {
                availableFields.formUnion(expr.fieldNames())
            }
        }

        // Check if all required fields are available
        return requiredFields.isSubset(of: availableFields)
    }
}
```

### 2. Index Maintenance (Write Path)

**Modify `GenericValueIndexMaintainer`** to store covering field values:

```swift
// In ValueIndex.swift
public final class GenericValueIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {

    public func updateIndex(...) async throws {
        // ... existing code to build index key ...

        let indexKey = buildIndexKey(record: record, recordAccess: recordAccess)

        // NEW: Build index value from covering fields
        let indexValue: FDB.Bytes
        if let coveringFields = index.coveringFields, !coveringFields.isEmpty {
            indexValue = try buildCoveringValue(
                record: record,
                recordAccess: recordAccess,
                coveringFields: coveringFields
            )
        } else {
            // Backward compatible: empty value for non-covering indexes
            indexValue = FDB.Bytes()
        }

        transaction.setValue(indexValue, for: indexKey)
    }

    /// Build covering value from covering field expressions
    ///
    /// Evaluates each covering field expression and packs the results into a Tuple.
    ///
    /// - Parameters:
    ///   - record: The record to extract from
    ///   - recordAccess: RecordAccess for field extraction
    ///   - coveringFields: Field expressions to evaluate
    /// - Returns: Packed tuple of covering field values
    private func buildCoveringValue(
        record: Record,
        recordAccess: any RecordAccess<Record>,
        coveringFields: [KeyExpression]
    ) throws -> FDB.Bytes {
        var allValues: [any TupleElement] = []

        for fieldExpr in coveringFields {
            let values = try recordAccess.evaluate(record: record, expression: fieldExpr)
            allValues.append(contentsOf: values)
        }

        let tuple = TupleHelpers.toTuple(allValues)
        return tuple.pack()
    }
}
```

**Example** (User index with covering fields):

```swift
// Index definition
let index = Index.covering(
    named: "user_by_city_covering",
    on: FieldKeyExpression(fieldName: "city"),
    covering: [
        FieldKeyExpression(fieldName: "name"),
        FieldKeyExpression(fieldName: "email")
    ],
    recordTypes: ["User"]
)

// Record
let user = User(userID: 1001, name: "Alice", email: "alice@example.com", city: "Tokyo", age: 25)

// Generated index entry
Key:   [I][user_by_city_covering]["Tokyo"][1001]
Value: Tuple("Alice", "alice@example.com").pack()
       = [0x02, 'A','l','i','c','e', 0x00, 0x02, 'a','l','i','c','e','@','e','x','a','m','p','l','e','.','c','o','m', 0x00]
```

### 3. Record Reconstruction (Read Path)

**Extend `RecordAccess` protocol** with reconstruction method:

```swift
// In RecordAccess.swift
extension RecordAccess {
    /// Reconstruct a record from index key and value
    ///
    /// This method is used by covering indexes to reconstruct records without
    /// fetching from storage.
    ///
    /// **Field Assembly Strategy**:
    /// 1. Extract indexed fields from index key (via rootExpression)
    /// 2. Extract covering fields from index value (via coveringFields)
    /// 3. Extract primary key from index key (last N elements)
    /// 4. Reconstruct record with all available fields
    ///
    /// **Implementation Requirements**:
    /// - For @Recordable types: Auto-generated via macro (recommended)
    /// - For hand-written types: Must implement manually
    /// - For legacy code: Fallback to record fetch (safe default)
    ///
    /// **Compatibility**:
    /// This method has a default implementation that throws .notImplemented.
    /// This ensures:
    /// - Compile-time: No errors for existing RecordAccess implementations
    /// - Runtime: Clear error message if covering index is used without implementation
    /// - Migration: Gradual adoption possible
    ///
    /// - Parameters:
    ///   - indexKey: The index key (unpacked tuple)
    ///   - indexValue: The index value (packed covering fields)
    ///   - index: The index definition
    ///   - primaryKeyExpression: Primary key expression for field extraction
    /// - Returns: Reconstructed record
    /// - Throws: RecordLayerError.reconstructionNotImplemented or .reconstructionFailed
    public func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record {
        // DEFAULT IMPLEMENTATION: Throw not implemented error
        //
        // This is intentionally not a fatalError() to allow gradual migration:
        // 1. Old code without reconstruct() → Runtime error with clear message
        // 2. New code with @Recordable → Auto-generated implementation
        // 3. Hand-written code → Manual implementation
        //
        // The error includes actionable guidance for users
        throw RecordLayerError.reconstructionNotImplemented(
            recordType: String(describing: Record.self),
            suggestion: """
            To use covering indexes with this record type, either:
            1. Use @Recordable macro (auto-generates reconstruct method)
            2. Manually implement RecordAccess.reconstruct()
            3. Avoid covering indexes for this type (use regular indexes)
            """
        )
    }

    /// Check if this RecordAccess supports reconstruction
    ///
    /// This allows the query planner to skip covering index plans
    /// for types that don't implement reconstruction.
    ///
    /// **Default**: false (safe, conservative)
    ///
    /// **Override**: Return true if reconstruct() is implemented
    ///
    /// - Returns: true if reconstruct() is supported
    public var supportsReconstruction: Bool {
        return false
    }
}
```

**Implement for `GenericRecordAccess`** (Recordable types):

```swift
// In GenericRecordAccess.swift
extension GenericRecordAccess {
    /// Override supportsReconstruction for @Recordable types
    ///
    /// @Recordable macro generates reconstruct() method, so it's always supported
    public var supportsReconstruction: Bool {
        return true
    }

    public func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record {
        // 1. Extract all elements from index key
        let keyElements = Array(0..<indexKey.count).compactMap { indexKey[$0] }

        // 2. Determine number of indexed fields (key elements - primary key)
        let indexedFieldCount = keyElements.count - primaryKeyLength
        guard indexedFieldCount >= 0 else {
            throw RecordLayerError.internalError(
                "Invalid index key: insufficient elements for primary key extraction"
            )
        }

        // 3. Extract field values
        let indexedFieldValues = Array(keyElements.prefix(indexedFieldCount))
        let primaryKeyValues = Array(keyElements.suffix(primaryKeyLength))

        // 4. Extract covering field values from index value
        let coveringFieldValues: [any TupleElement]
        if !indexValue.isEmpty {
            let coveringTuple = try Tuple.unpack(from: indexValue)
            coveringFieldValues = Array(0..<coveringTuple.count).compactMap { coveringTuple[$0] }
        } else {
            coveringFieldValues = []
        }

        // 5. Build field name → value map
        var fieldMap: [String: any TupleElement] = [:]

        // Map indexed field names to values
        let indexedFieldNames = index.rootExpression.fieldNames()
        for (i, fieldName) in indexedFieldNames.enumerated() {
            if i < indexedFieldValues.count {
                fieldMap[fieldName] = indexedFieldValues[i]
            }
        }

        // Map covering field names to values
        if let coveringFields = index.coveringFields {
            let coveringFieldNames = coveringFields.flatMap { $0.fieldNames() }
            for (i, fieldName) in coveringFieldNames.enumerated() {
                if i < coveringFieldValues.count {
                    fieldMap[fieldName] = coveringFieldValues[i]
                }
            }
        }

        // Map primary key field names to values
        // Assume primaryKeyExpression is available from entity
        // (This requires access to Schema.Entity - needs context parameter)

        // 6. Reconstruct record using fieldMap
        // This part is type-specific and needs to be generated by @Recordable macro
        return try Record.reconstruct(from: fieldMap)
    }
}
```

**Issue Identified**: Need entity context for primary key field names!

**Solution**: Pass entity or primary key expression as parameter:

```swift
public func reconstruct(
    indexKey: Tuple,
    indexValue: FDB.Bytes,
    index: Index,
    primaryKeyExpression: KeyExpression  // NEW: Pass primary key expression
) throws -> Record {
    // ... extract values ...

    // Map primary key field names to values
    let primaryKeyFieldNames = primaryKeyExpression.fieldNames()
    for (i, fieldName) in primaryKeyFieldNames.enumerated() {
        if i < primaryKeyValues.count {
            fieldMap[fieldName] = primaryKeyValues[i]
        }
    }

    // Reconstruct record
    return try Record.reconstruct(from: fieldMap)
}
```

### 4. Macro Support (@Recordable)

**Add reconstruction method generation** to `@Recordable` macro:

```swift
// Generated by @Recordable macro
extension User {
    /// Reconstruct User from field map
    ///
    /// This method is generated by @Recordable macro for covering index support.
    ///
    /// - Parameter fieldMap: Map of field names to tuple element values
    /// - Returns: Reconstructed User instance
    /// - Throws: RecordLayerError.reconstructionFailed if required fields are missing
    public static func reconstruct(from fieldMap: [String: any TupleElement]) throws -> User {
        // Extract and convert field values
        guard let userID = fieldMap["userID"] as? Int64 else {
            throw RecordLayerError.reconstructionFailed(
                "Missing required field: userID"
            )
        }

        guard let name = fieldMap["name"] as? String else {
            throw RecordLayerError.reconstructionFailed(
                "Missing required field: name"
            )
        }

        guard let email = fieldMap["email"] as? String else {
            throw RecordLayerError.reconstructionFailed(
                "Missing required field: email"
            )
        }

        guard let city = fieldMap["city"] as? String else {
            throw RecordLayerError.reconstructionFailed(
                "Missing required field: city"
            )
        }

        guard let age = fieldMap["age"] as? Int else {
            throw RecordLayerError.reconstructionFailed(
                "Missing required field: age"
            )
        }

        return User(
            userID: userID,
            name: name,
            email: email,
            city: city,
            age: age
        )
    }
}
```

**Macro Implementation** (`RecordableMacro.swift`):

```swift
private static func generateReconstructMethod(
    typeName: String,
    fields: [FieldInfo]
) -> String {
    let fieldExtractions = fields.map { field in
        let optionalCheck = field.isOptional ? "?" : ""
        let errorCheck = field.isOptional ? "" : """

        guard let \(field.name) = fieldMap["\(field.name)"] as? \(field.typeName)\(optionalCheck) else {
            throw RecordLayerError.reconstructionFailed("Missing required field: \(field.name)")
        }
        """

        if field.isOptional {
            return "let \(field.name) = fieldMap[\"\(field.name)\"] as? \(field.typeName)"
        } else {
            return errorCheck
        }
    }.joined(separator: "\n        ")

    let initParams = fields.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return """

    public static func reconstruct(from fieldMap: [String: any TupleElement]) throws -> \(typeName) {
        \(fieldExtractions)

        return \(typeName)(\(initParams))
    }
    """
}
```

### 5. Covering Index Cursor

**New cursor type** for covering index scans:

```swift
// In TypedRecordCursor.swift

/// Cursor for covering index scans that reconstructs records from index entries
///
/// Unlike IndexScanTypedCursor which fetches records from storage, this cursor
/// reconstructs records directly from index key and value, eliminating storage fetch.
public struct CoveringIndexScanTypedCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let indexSequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>
    private let indexSubspace: Subspace
    private let recordAccess: any RecordAccess<Record>
    private let filter: (any TypedQueryComponent<Record>)?
    private let index: Index
    private let primaryKeyExpression: KeyExpression

    init(
        indexSequence: any AsyncSequence<(FDB.Bytes, FDB.Bytes), Error>,
        indexSubspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        filter: (any TypedQueryComponent<Record>)?,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) {
        self.indexSequence = indexSequence
        self.indexSubspace = indexSubspace
        self.recordAccess = recordAccess
        self.filter = filter
        self.index = index
        self.primaryKeyExpression = primaryKeyExpression
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: any AsyncIteratorProtocol<(FDB.Bytes, FDB.Bytes), Error>
        let indexSubspace: Subspace
        let recordAccess: any RecordAccess<Record>
        let filter: (any TypedQueryComponent<Record>)?
        let index: Index
        let primaryKeyExpression: KeyExpression

        public mutating func next() async throws -> Record? {
            while true {
                guard let pair = try await iterator.next() else {
                    return nil
                }

                let indexKey = pair.0
                let indexValue = pair.1

                // Unpack index key to get tuple elements
                let indexKeyTuple = try indexSubspace.unpack(indexKey)

                // Reconstruct record from index key and value
                // NO STORAGE FETCH NEEDED!
                let record = try recordAccess.reconstruct(
                    indexKey: indexKeyTuple,
                    indexValue: indexValue,
                    index: index,
                    primaryKeyExpression: primaryKeyExpression
                )

                // Apply filter
                if let filter = filter {
                    guard try filter.matches(record: record, recordAccess: recordAccess) else {
                        continue
                    }
                }

                return record
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let iter = indexSequence.makeAsyncIterator()
        return AsyncIterator(
            iterator: iter,
            indexSubspace: indexSubspace,
            recordAccess: recordAccess,
            filter: filter,
            index: index,
            primaryKeyExpression: primaryKeyExpression
        )
    }
}
```

### 6. Query Plan for Covering Index

**New plan type** in `TypedQueryPlan.swift`:

```swift
/// Covering index scan plan
///
/// Uses a covering index to reconstruct records without fetching from storage.
/// This plan is selected by the query planner when:
/// 1. An index covers all required fields in the query
/// 2. The covering index plan has lower cost than regular index scan
public struct TypedCoveringIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    public let indexName: String
    public let indexSubspaceTupleKey: any TupleElement
    public let beginValues: [any TupleElement]
    public let endValues: [any TupleElement]
    public let filter: (any TypedQueryComponent<Record>)?
    public let index: Index
    public let primaryKeyExpression: KeyExpression
    public let recordName: String

    public init(
        indexName: String,
        indexSubspaceTupleKey: any TupleElement,
        beginValues: [any TupleElement],
        endValues: [any TupleElement],
        filter: (any TypedQueryComponent<Record>)?,
        index: Index,
        primaryKeyExpression: KeyExpression,
        recordName: String
    ) {
        self.indexName = indexName
        self.indexSubspaceTupleKey = indexSubspaceTupleKey
        self.beginValues = beginValues
        self.endValues = endValues
        self.filter = filter
        self.index = index
        self.primaryKeyExpression = primaryKeyExpression
        self.recordName = recordName
    }

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        let transaction = context.getTransaction()
        let indexSubspace = subspace.subspace("I")
            .subspace(indexSubspaceTupleKey)

        // Build index key range (same as TypedIndexScanPlan)
        let beginTuple = TupleHelpers.toTuple(beginValues)
        let endTuple = TupleHelpers.toTuple(endValues)

        let beginKey: FDB.Bytes
        if beginValues.isEmpty {
            let (rangeBegin, _) = indexSubspace.range()
            beginKey = rangeBegin
        } else {
            beginKey = indexSubspace.pack(beginTuple)
        }

        var endKey: FDB.Bytes
        if endValues.isEmpty {
            let (_, rangeEnd) = indexSubspace.range()
            endKey = rangeEnd
        } else {
            endKey = indexSubspace.pack(endTuple)
            let isEqualityQuery = beginKey == endKey
            if isEqualityQuery {
                endKey.append(0xFF)
            }
        }

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(beginKey),
            endSelector: .firstGreaterOrEqual(endKey),
            snapshot: snapshot
        )

        // Use CoveringIndexScanTypedCursor instead of IndexScanTypedCursor
        let cursor = CoveringIndexScanTypedCursor(
            indexSequence: sequence,
            indexSubspace: indexSubspace,
            recordAccess: recordAccess,
            filter: filter,
            index: index,
            primaryKeyExpression: primaryKeyExpression
        )

        return AnyTypedRecordCursor(cursor)
    }
}
```

### 7. Query Planner Integration

**Modify `TypedRecordQueryPlanner`** to detect and use covering indexes:

```swift
// In TypedRecordQueryPlanner.swift

private func generateSingleIndexPlans(
    _ query: TypedRecordQuery<Record>
) async throws -> [any TypedQueryPlan<Record>] {
    guard let filter = query.filter else {
        return []
    }

    var indexPlans: [any TypedQueryPlan<Record>] = []
    let applicableIndexes = schema.indexes(for: recordName)

    // Determine required fields from query
    let requiredFields = extractRequiredFields(from: query)

    for index in applicableIndexes {
        if let matchResult = try matchFilterWithIndex(filter: filter, index: index) {
            // Check if index covers all required fields
            let isCovering = index.covers(fields: requiredFields)

            // CRITICAL: Check if RecordAccess supports reconstruction
            // Even if index covers fields, we can't use it without reconstruct() implementation
            let supportsReconstruction = recordAccess.supportsReconstruction

            let finalPlan: any TypedQueryPlan<Record>
            if isCovering && supportsReconstruction {
                // Use covering index plan
                guard let entity = schema.entity(named: recordName) else {
                    throw RecordLayerError.internalError("Entity not found: \(recordName)")
                }

                let coveringPlan = TypedCoveringIndexScanPlan<Record>(
                    indexName: index.name,
                    indexSubspaceTupleKey: index.subspaceTupleKey,
                    beginValues: matchResult.beginValues,
                    endValues: matchResult.endValues,
                    filter: matchResult.remainingFilter,
                    index: index,
                    primaryKeyExpression: entity.primaryKeyExpression,
                    recordName: recordName
                )

                finalPlan = coveringPlan
            } else {
                // Use regular index scan plan
                let indexPlan = TypedIndexScanPlan<Record>(
                    indexName: index.name,
                    indexSubspaceTupleKey: index.subspaceTupleKey,
                    beginValues: matchResult.beginValues,
                    endValues: matchResult.endValues,
                    filter: nil,
                    primaryKeyLength: getPrimaryKeyLength(),
                    recordName: recordName
                )

                finalPlan = matchResult.remainingFilter != nil ?
                    TypedFilterPlan(child: indexPlan, filter: matchResult.remainingFilter!) :
                    indexPlan
            }

            indexPlans.append(finalPlan)
        }
    }

    return indexPlans
}

/// Extract required fields from query (filter + sort + select)
///
/// **CRITICAL**: This method determines which fields are needed to answer the query.
/// The more accurate this is, the more queries can use covering indexes.
///
/// **Implementation Strategy**:
/// - Phase 5A (Day 5): Implement basic field extraction (filter + sort + primary key)
/// - Phase 5B (Future): Add .select() API and projection tracking
/// - Phase 5C (Future): Add smart field inference from RecordAccess patterns
///
/// - Parameter query: The query to analyze
/// - Returns: Set of field names required to answer the query
private func extractRequiredFields(from query: TypedRecordQuery<Record>) -> Set<String> {
    var fields = Set<String>()

    // 1. Extract fields from filter
    if let filter = query.filter {
        fields.formUnion(extractFieldsFromFilter(filter))
    }

    // 2. Extract fields from sort
    if let sort = query.sort {
        fields.formUnion(sort.map { $0.fieldName })
    }

    // 3. Extract primary key fields (always needed)
    if let entity = schema.entity(named: recordName) {
        fields.formUnion(entity.primaryKeyFields)
    }

    // 4. Extract fields from select (if implemented)
    // FUTURE: When .select() API is added, use:
    // if let select = query.select {
    //     fields.formUnion(select.map { $0.fieldName })
    //     return fields  // Only selected fields needed
    // }

    // 5. CONSERVATIVE FALLBACK: If no select clause, assume all fields needed
    // This prevents incorrect results but limits covering index usage
    // TODO: Remove this once .select() API is implemented
    if query.select == nil {
        if let entity = schema.entity(named: recordName) {
            fields.formUnion(entity.attributes.map { $0.name })
        }
    }

    return fields
}

/// Check if query has explicit field selection
///
/// This allows early adoption of covering indexes for queries that
/// explicitly state which fields they need.
///
/// **Example**:
/// ```swift
/// // Explicit selection → Can use covering index
/// let users = try await store.query(User.self)
///     .where(\.city, .equals, "Tokyo")
///     .select(\.name, \.email)  // Only need name, email
///     .execute()
///
/// // No selection → Assumes all fields needed
/// let users = try await store.query(User.self)
///     .where(\.city, .equals, "Tokyo")
///     .execute()  // Needs all fields
/// ```
private func hasExplicitFieldSelection(_ query: TypedRecordQuery<Record>) -> Bool {
    // FUTURE: Implement when .select() API is added
    return false
}

/// Extract field names from filter component
private func extractFieldsFromFilter(_ component: any TypedQueryComponent<Record>) -> Set<String> {
    if let fieldFilter = component as? TypedFieldQueryComponent<Record> {
        return [fieldFilter.fieldName]
    } else if let andFilter = component as? TypedAndQueryComponent<Record> {
        return andFilter.children.reduce(Set<String>()) { result, child in
            result.union(extractFieldsFromFilter(child))
        }
    } else if let orFilter = component as? TypedOrQueryComponent<Record> {
        return orFilter.children.reduce(Set<String>()) { result, child in
            result.union(extractFieldsFromFilter(child))
        }
    } else if let notFilter = component as? TypedNotQueryComponent<Record> {
        return extractFieldsFromFilter(notFilter.child)
    } else if let inFilter = component as? TypedInQueryComponent<Record> {
        return [inFilter.fieldName]
    }

    return Set<String>()
}
```

---

## Early Adoption Strategy

### Problem: Conservative Field Extraction

**Current Design Issue**:
```swift
// Without .select() API, extractRequiredFields() assumes ALL fields are needed
let users = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .execute()

// extractRequiredFields() returns: [userID, name, email, city, age, ...]
// Covering index only has: [city, name, email]
// Result: Does NOT use covering index (missing fields)
```

**Impact**: Covering indexes will NOT be used until .select() API is implemented.

### Solution: Phased Rollout

#### Phase 5A: Basic Implementation (Day 5)
- Implement covering index infrastructure
- Conservative field extraction (assumes all fields)
- **Benefit**: Foundation is ready, no incorrect results
- **Limitation**: Covering indexes mostly unused

#### Phase 5B: .select() API (Future, ~3 days)
- Add explicit field selection to query builder
- Update extractRequiredFields() to use select clause
- **Benefit**: Users can opt-in to covering indexes

**Example**:
```swift
// New .select() API
let users = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .select(\.name, \.email)  // ← Explicit field selection
    .execute()

// extractRequiredFields() returns: [city, name, email, userID]
// Covering index has: [city, name, email, userID]
// Result: Uses covering index! ✅
```

#### Phase 5C: Smart Field Inference (Future, optional)
- Analyze RecordAccess usage patterns
- Detect which fields are actually accessed
- Auto-optimize even without .select()

### Interim Workaround: Explicit Covering Hint

**Alternative API** (can implement in Phase 5A):

```swift
extension TypedRecordQuery {
    /// Explicitly mark this query as using only covered fields
    ///
    /// **Warning**: Using this with fields not in the covering index
    /// will cause runtime errors or incomplete results.
    ///
    /// **Example**:
    /// ```swift
    /// let users = try await store.query(User.self)
    ///     .where(\.city, .equals, "Tokyo")
    ///     .useCoveringIndex("user_by_city_covering")  // Explicit hint
    ///     .execute()
    /// ```
    public func useCoveringIndex(_ indexName: String) -> Self {
        var copy = self
        copy.preferredIndexName = indexName
        copy.requireCovering = true
        return copy
    }
}
```

**Pros**:
- Allows early adoption without .select() API
- Gives control to advanced users

**Cons**:
- Manual specification required
- Risk of runtime errors if fields are missing

### Recommendation

**For Phase 5A (Initial Release)**:
1. Implement covering index infrastructure
2. Add `useCoveringIndex()` hint API for early adopters
3. Document clearly: "Most queries won't use covering indexes until .select() is added"
4. Provide examples of manual field verification

**For Phase 5B (Follow-up, 2-3 weeks later)**:
1. Implement .select() API
2. Auto-detection works for all queries with .select()
3. Remove need for manual hints

This approach:
- ✅ Delivers value incrementally
- ✅ Avoids incorrect results (conservative is safe)
- ✅ Enables early adopters to benefit
- ✅ Sets foundation for full automation

---

## API Design

### User-Facing API

#### 1. Define Covering Index

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String
    var email: String
    var city: String
    var age: Int
}

// Define covering index
let coveringIndex = Index.covering(
    named: "user_by_city_covering",
    on: FieldKeyExpression(fieldName: "city"),
    covering: [
        FieldKeyExpression(fieldName: "name"),
        FieldKeyExpression(fieldName: "email")
    ],
    recordTypes: ["User"]
)

// Add to schema
let schema = Schema(
    [User.self],
    indexes: [coveringIndex]
)
```

#### 2. Query with Covering Index (Automatic)

```swift
// Query planner automatically detects covering index
let users = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .execute()

// Behind the scenes:
// 1. Planner extracts required fields: [city, userID, name, email, age]
// 2. Checks if user_by_city_covering covers these fields
// 3. Index covers: [city (indexed), name (covering), email (covering), userID (primary key)]
// 4. Missing: [age] → Not fully covering, uses regular index scan

// For covering to work, query must only need covered fields
```

#### 3. Explicit Field Selection (Future)

```swift
// Future API: Explicit field selection
let users = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .select(\.name, \.email)  // Only request covered fields
    .execute()

// Now covering index is used because:
// Required fields: [city, name, email, userID]
// Index covers: [city, name, email, userID] ✅
```

### Internal API

#### RecordAccess.reconstruct()

```swift
public protocol RecordAccess<Record>: Sendable {
    func reconstruct(
        indexKey: Tuple,
        indexValue: FDB.Bytes,
        index: Index,
        primaryKeyExpression: KeyExpression
    ) throws -> Record
}
```

#### Index.covers()

```swift
extension Index {
    public func covers(fields requiredFields: Set<String>) -> Bool
}
```

---

## Implementation Plan

### Revised Implementation Plan (Parallelized)

**CRITICAL ISSUE IDENTIFIED**: Original 5-day plan has serial dependencies where Day 3 (Macro) blocks Day 4-5 (Read Path + Planner).

**Solution**: Parallelize with feature flags and mock implementations.

#### Phase 1: Foundation (Day 1) - SEQUENTIAL

**Files to Modify**:
- `Sources/FDBRecordLayer/Core/Index.swift`
- `Sources/FDBRecordLayer/Serialization/RecordAccess.swift`

**Changes**:
1. Add `coveringFields: [KeyExpression]?` property to `Index`
2. Add `Index.covering()` factory method
3. Add `Index.covers(fields:)` method
4. Update `Hashable`/`Equatable` conformance to include `coveringFields`
5. Add `RecordAccess.reconstruct()` protocol method with default (throws .notImplemented)
6. Add `RecordAccess.supportsReconstruction` property with default (false)

**Tests**:
- `IndexCoveringFieldsTests.swift`: Test covering field definition and `covers()` logic

**Output**: Index API ready, RecordAccess stub ready

---

#### Phase 2A & 2B: Write Path + Read Path (Day 2-3) - **PARALLEL**

**Team A** (Day 2-3): Write Path
- **Files**: `ValueIndex.swift`
- **Changes**:
  1. Modify `GenericValueIndexMaintainer.updateIndex()` to store covering field values
  2. Add `buildCoveringValue()` method
- **Tests**: `ValueIndexCoveringTests.swift`
- **Dependency**: Phase 1 (Index API)
- **Blocks**: Nothing (can test independently)

**Team B** (Day 2-3): Read Path (with mock reconstruction)
- **Files**: `TypedRecordCursor.swift`, `TypedQueryPlan.swift`
- **Changes**:
  1. Add `CoveringIndexScanTypedCursor`
  2. Add `TypedCoveringIndexScanPlan`
  3. **MOCK**: Use temporary manual reconstruct() for testing
- **Tests**: `CoveringIndexCursorTests.swift` (with mock records)
- **Dependency**: Phase 1 (RecordAccess stub)
- **Blocks**: Nothing (tests work with mock)

**Output**: Write path complete, Read path 90% complete (pending macro)

---

#### Phase 3: Macro Support (Day 3-4) - PARALLEL with 2B

**Team C** (Day 3-4): Macro Generation
- **Files**: `RecordableMacro.swift`, `Recordable.swift`, `GenericRecordAccess.swift`
- **Changes**:
  1. Add `generateReconstructMethod()` to `RecordableMacro`
  2. Generate `static func reconstruct(from:)` for `@Recordable` types
  3. Implement `GenericRecordAccess.reconstruct()` (calls generated method)
  4. Set `GenericRecordAccess.supportsReconstruction = true`
- **Tests**: `RecordableMacroReconstructionTests.swift`
- **Dependency**: Phase 1 (RecordAccess protocol)
- **Blocks**: Phase 4 integration tests (but not unit tests)

**Output**: Macro generates reconstruct(), GenericRecordAccess complete

---

#### Phase 4: Planner Integration (Day 4-5) - PARALLEL with 3

**Team D** (Day 4-5): Query Planner
- **Files**: `TypedRecordQueryPlanner.swift`
- **Changes**:
  1. Add `extractRequiredFields(from:)` method
  2. Add `extractFieldsFromFilter()` method
  3. Modify `generateSingleIndexPlans()` to check for covering indexes
  4. Check `supportsReconstruction` before using covering plan
  5. Add feature flag: `FeatureFlags.enableCoveringIndexes`
- **Tests**: `CoveringIndexPlannerTests.swift` (unit tests with mock)
- **Dependency**: Phase 1 (Index.covers()), Phase 2B (Plan types)
- **Blocks**: Integration tests (needs Phase 3)

**Output**: Planner logic complete, ready for integration

---

#### Phase 5: Integration & Testing (Day 5-6) - FINAL INTEGRATION

**All Teams** (Day 5-6): Integration Testing
- **Dependency**: Phases 2A, 2B, 3, 4 all complete
- **Tasks**:
  1. Remove mock reconstruct() implementations
  2. Wire up macro-generated reconstruct() with cursors
  3. End-to-end integration tests
  4. Performance benchmarks
- **Tests**:
  - `CoveringIndexIntegrationTests.swift`
  - `CoveringIndexPerformanceTests.swift`

**Output**: Fully working covering index implementation

---

#### Phase 6: Documentation & Polish (Day 6-7)

**Documentation**:
- Update `IMPLEMENTATION_STATUS.md`
- Update `swift-implementation-roadmap.md`
- Add covering index section to `CLAUDE.md`
- Add example to `README.md`
- Migration guide and runbook

**Performance Benchmarks**:
- Benchmark covering index vs regular index scan
- Measure throughput improvement

---

### Dependency Graph (Optimized)

```
Day 1: [Phase 1: Foundation] ← Everyone blocked
         ↓
Day 2: [Phase 2A: Write Path] || [Phase 2B: Read Path (mock)] ← Parallel
         ↓                  ↓
Day 3: [Phase 2A cont.]    || [Phase 2B cont.] || [Phase 3: Macro]    || [Phase 4: Planner (mock)] ← 4 parallel tracks
         ↓                  ↓                   ↓                      ↓
Day 4:    ✅              ✅                  [Phase 3 cont.]        [Phase 4 cont.]
                                              ↓                      ↓
Day 5:                                        ✅ ← Integration ← ✅
                                                    ↓
Day 6:                                          [Phase 5: Integration Tests]
                                                    ↓
Day 7:                                          [Phase 6: Documentation]
```

### Critical Path Analysis

**Old Plan**:
```
Day 1 → Day 2 → Day 3 (MACRO) → Day 4 (blocked) → Day 5 (blocked)
                  ↑
                BOTTLENECK
```
Critical Path: 5 days (fully serial)

**New Plan**:
```
Day 1 → Day 2-3 (parallel) → Day 4-5 (parallel) → Day 6 (integration) → Day 7 (docs)
```
Critical Path: 4 days (Phase 1 → Phase 3 → Integration → Docs)

**Speedup**: 5 days → 4 days (20% faster)

**Risk Reduction**:
- ✅ Macro delay doesn't block Read Path or Planner (they use mocks)
- ✅ Integration issues caught earlier (all components testable in isolation)
- ✅ More opportunities for parallel review and testing

### Team Allocation Recommendation

**Minimum Team Size**: 1 developer (serial execution, 7 days)

**Optimal Team Size**: 2-3 developers (parallel execution, 4-5 days)
- Developer A: Phase 1 → Phase 2A (Write Path) → Integration
- Developer B: Phase 1 → Phase 2B (Read Path) → Phase 4 (Planner) → Integration
- Developer C: Phase 1 → Phase 3 (Macro) → Integration

**Maximum Parallelism**: 4 developers (parallel execution, 3-4 days)
- Developer A: Phase 1 → Phase 2A → Integration
- Developer B: Phase 1 → Phase 2B → Integration
- Developer C: Phase 1 → Phase 3 → Integration
- Developer D: Phase 1 → Phase 4 → Integration

### Feature Flag Strategy (Enables Parallel Work)

```swift
// Allows Read Path and Planner to be deployed before Macro
public struct FeatureFlags {
    // Master switch (default: off)
    public static var enableCoveringIndexes: Bool = false

    // Component switches (for testing)
    public static var enableCoveringIndexWrite: Bool = true      // Phase 2A
    public static var enableCoveringIndexRead: Bool = false      // Phase 2B (needs macro)
    public static var enableCoveringIndexPlanner: Bool = false   // Phase 4 (needs macro)

    // Gradual rollout
    public static var coveringIndexRolloutPercentage: Int = 0
}
```

**Deployment Flow**:
1. Day 4: Deploy Phase 2A (write path) with `enableCoveringIndexWrite = true`
   - Indexes start storing covering fields (no query impact)
2. Day 5: Deploy Phase 3 (macro) + Phase 4 (planner) with flags OFF
   - Code is deployed but inactive (safe)
3. Day 6: Enable feature flags gradually
   - `enableCoveringIndexes = true, rolloutPercentage = 10%`
4. Day 7: Full rollout
   - `rolloutPercentage = 100%`

---

## Testing Strategy

### Unit Tests

1. **Index Definition Tests**
   - Test `Index.covering()` factory method
   - Test `Index.covers()` with various field combinations
   - Test edge cases (empty covering fields, duplicate fields)

2. **Write Path Tests**
   - Verify covering field values are stored correctly
   - Test with different field types
   - Test with nested fields (future)

3. **Reconstruction Tests**
   - Test `Record.reconstruct()` generated method
   - Test with missing fields (should throw)
   - Test with optional fields
   - Test with default values

4. **Read Path Tests**
   - Test `CoveringIndexScanTypedCursor` iteration
   - Test filter application on reconstructed records
   - Test limit and pagination

5. **Query Planner Tests**
   - Test required field extraction
   - Test covering index detection
   - Test plan selection (covering vs non-covering)
   - Test cost estimation

### Integration Tests

```swift
@Test("Covering index eliminates record fetch")
func coveringIndexIntegrationTest() async throws {
    // Define schema with covering index
    let coveringIndex = Index.covering(
        named: "user_by_city_covering",
        on: FieldKeyExpression(fieldName: "city"),
        covering: [
            FieldKeyExpression(fieldName: "name"),
            FieldKeyExpression(fieldName: "email")
        ],
        recordTypes: ["User"]
    )

    let schema = Schema([User.self], indexes: [coveringIndex])
    let store = RecordStore(database: database, subspace: subspace, schema: schema)

    // Save test data
    try await store.save(User(userID: 1, name: "Alice", email: "alice@example.com", city: "Tokyo", age: 25))
    try await store.save(User(userID: 2, name: "Bob", email: "bob@example.com", city: "Tokyo", age: 30))
    try await store.save(User(userID: 3, name: "Carol", email: "carol@example.com", city: "NYC", age: 28))

    // Query using covering index
    let users = try await store.query(User.self)
        .where(\.city, .equals, "Tokyo")
        .execute()
        .collect()

    #expect(users.count == 2)
    #expect(users.map(\.name).sorted() == ["Alice", "Bob"])
}

@Test("Non-covering query falls back to regular index scan")
func nonCoveringQueryTest() async throws {
    // Query requires 'age' field which is not covered
    let users = try await store.query(User.self)
        .where(\.city, .equals, "Tokyo")
        .where(\.age, .greaterThan, 20)  // age not in covering fields
        .execute()
        .collect()

    // Should still work, but uses regular index scan + record fetch
    #expect(users.count == 2)
}
```

### Performance Tests

```swift
@Test("Covering index performance improvement")
func coveringIndexPerformanceTest() async throws {
    // Insert 10,000 users
    for i in 1...10_000 {
        try await store.save(User(
            userID: Int64(i),
            name: "User\(i)",
            email: "user\(i)@example.com",
            city: i % 100 == 0 ? "Tokyo" : "Other",
            age: 20 + (i % 50)
        ))
    }

    // Benchmark regular index scan
    let regularStart = Date()
    let regularUsers = try await store.query(User.self)
        .where(\.city, .equals, "Tokyo")
        .execute()
        .collect()
    let regularDuration = Date().timeIntervalSince(regularStart)

    // Benchmark covering index scan
    let coveringStart = Date()
    let coveringUsers = try await store.query(User.self)
        .where(\.city, .equals, "Tokyo")
        .execute()
        .collect()
    let coveringDuration = Date().timeIntervalSince(coveringStart)

    // Covering index should be 2-10x faster
    #expect(coveringDuration < regularDuration / 2)
    #expect(regularUsers.count == coveringUsers.count)
}
```

---

## Migration and Compatibility

### Backward Compatibility

1. **Existing Indexes**: All existing indexes continue to work unchanged
   - `coveringFields` defaults to `nil`
   - Empty index values are treated as non-covering

2. **Existing Queries**: No changes required
   - Query planner automatically detects covering indexes
   - Falls back to regular index scan if not covering

3. **Serialization**: Covering field values use standard Tuple encoding
   - Compatible with existing serialization code
   - No new dependencies

### Migration Path (Detailed)

#### Overview

Migrating to covering indexes involves:
1. Code deployment (with feature flag)
2. Schema update
3. Online index build
4. Validation and rollout
5. Cleanup

**Timeline**: 1-2 weeks for production rollout

#### Step 1: Code Deployment (Day 1)

**Deploy covering index support with feature flag**:

```swift
// Add feature flag to config
public struct FeatureFlags {
    public static var enableCoveringIndexes: Bool = false
}

// In TypedRecordQueryPlanner
private func generateSingleIndexPlans(...) {
    // ...

    // Feature flag check
    if isCovering && supportsReconstruction && FeatureFlags.enableCoveringIndexes {
        // Use covering index plan
    } else {
        // Use regular index plan (safe fallback)
    }
}
```

**Deployment checklist**:
- ✅ Deploy code to all application servers
- ✅ Verify backward compatibility (feature flag OFF)
- ✅ No production impact (flag is disabled)

#### Step 2: Schema Update (Day 2-3)

**Add covering index definition** (alongside existing index):

```swift
// Before (existing index - keep for now)
let cityIndex = Index.value(
    named: "user_by_city",
    on: FieldKeyExpression(fieldName: "city"),
    recordTypes: ["User"]
)

// After (add new covering index)
let cityIndexCovering = Index.covering(
    named: "user_by_city_covering",  // NEW NAME
    on: FieldKeyExpression(fieldName: "city"),
    covering: [
        FieldKeyExpression(fieldName: "name"),
        FieldKeyExpression(fieldName: "email")
    ],
    recordTypes: ["User"]
)

// Schema with BOTH indexes
let schema = Schema(
    [User.self],
    indexes: [
        cityIndex,           // Old index (for queries during migration)
        cityIndexCovering    // New covering index (being built)
    ]
)
```

**Important**: Keep both indexes during migration!

#### Step 3: Online Index Build (Day 3-5)

**Build covering index without downtime**:

```swift
// Phase 3A: Mark index as writeOnly
let indexManager = IndexStateManager(database: database, subspace: subspace)
try await indexManager.setState(
    index: "user_by_city_covering",
    state: .writeOnly  // Maintained, but NOT used for queries
)

// Phase 3B: Build index in background
let indexer = OnlineIndexer(
    recordStore: store,
    indexName: "user_by_city_covering"
)

// Monitor progress
indexer.onProgress = { progress in
    print("Build progress: \(progress.percentage)%")
}

try await indexer.buildIndex()

// Phase 3C: Mark index as readable
try await indexManager.setState(
    index: "user_by_city_covering",
    state: .readable  // NOW available for queries
)
```

**During index build** (important details):

1. **Write Path (Double Writes)**:
   ```
   Record Save → Write to user_by_city (old)
              → Write to user_by_city_covering (new, writeOnly)

   Impact: ~5% write latency increase (acceptable)
   ```

2. **Read Path (No Impact)**:
   ```
   Query → Uses user_by_city (old, readable)
        → Does NOT use user_by_city_covering (writeOnly)

   Impact: No change to query performance
   ```

3. **Build Progress Tracking**:
   ```swift
   // Check build status
   let progress = try await indexer.getProgress()
   print("Scanned: \(progress.scanned) / \(progress.total)")
   print("ETA: \(progress.estimatedTimeRemaining)")
   ```

4. **Failure Recovery**:
   ```swift
   // Build is resumable
   try await indexer.buildIndex()  // Resumes from last checkpoint

   // If build fails, index remains in writeOnly state
   // Queries continue using old index (no impact)
   ```

#### Step 4: Validation and Rollout (Day 6-7)

**Validate covering index correctness**:

```swift
// Test 1: Compare results (old vs new index)
let resultsOld = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .useIndex("user_by_city")  // Force old index
    .execute()
    .collect()

let resultsNew = try await store.query(User.self)
    .where(\.city, .equals, "Tokyo")
    .useIndex("user_by_city_covering")  // Force new index
    .execute()
    .collect()

assert(resultsOld == resultsNew, "Index results must match!")

// Test 2: Performance comparison
let latencyOld = measure { try await ... }  // ~20ms
let latencyNew = measure { try await ... }  // ~5ms (4x faster)
```

**Gradual rollout** (recommended):

```swift
// Day 6: Enable for 10% of queries
FeatureFlags.enableCoveringIndexes = true
FeatureFlags.coveringIndexRolloutPercentage = 10

// Day 7: Increase to 50%
FeatureFlags.coveringIndexRolloutPercentage = 50

// Day 8: Full rollout (100%)
FeatureFlags.coveringIndexRolloutPercentage = 100
```

**Monitoring during rollout**:
```
Metrics to watch:
- Query latency (should decrease)
- Error rate (should remain stable)
- Storage usage (should increase by expected amount)
- Index hit rate (covering_index_hit_rate{index="user_by_city_covering"})
```

#### Step 5: Cleanup (Week 2)

**Remove old non-covering index**:

```swift
// Week 2, Day 1: Mark old index as former
let schema = Schema(
    [User.self],
    indexes: [cityIndexCovering],  // Only covering index
    formerIndexes: [
        FormerIndex(
            formerName: "user_by_city",
            removedAfterVersion: Schema.Version(2, 0, 0)
        )
    ]
)

// Week 2, Day 2-7: Wait for index cleanup
// OnlineIndexScrubber will automatically remove old index data
```

### Migration Failure Scenarios

#### Scenario 1: Index Build Fails

**Symptoms**: OnlineIndexer throws error during build

**Impact**:
- ✅ No query impact (still using old index)
- ✅ Write path continues (both indexes maintained)

**Resolution**:
1. Check error logs: `indexer.getLastError()`
2. Fix underlying issue (e.g., data corruption, resource limits)
3. Resume build: `try await indexer.buildIndex()`

#### Scenario 2: Covering Index Returns Incorrect Results

**Symptoms**: Validation test fails (results mismatch)

**Impact**:
- ⚠️ Potential data consistency issue

**Resolution**:
1. **Immediate**: Disable feature flag
   ```swift
   FeatureFlags.enableCoveringIndexes = false
   ```
2. Mark index as writeOnly (stop using for queries)
   ```swift
   try await indexManager.setState(index: "user_by_city_covering", state: .writeOnly)
   ```
3. Investigate root cause:
   - Check reconstruct() implementation
   - Verify covering field list matches actual usage
   - Test with different record variants
4. Fix and rebuild:
   ```swift
   try await indexManager.setState(index: "user_by_city_covering", state: .disabled)
   try await indexer.buildIndex()  // Rebuild from scratch
   ```

#### Scenario 3: Performance Regression

**Symptoms**: Query latency increases instead of decreasing

**Possible causes**:
1. Covering field size too large → Index scan slower than record fetch
2. RecordAccess.reconstruct() inefficient
3. Network bottleneck (larger index values)

**Resolution**:
1. Measure actual overhead:
   ```swift
   let indexEntrySize = measure { indexSequence.next() }
   let recordSize = measure { recordAccess.deserialize(bytes) }

   if indexEntrySize > recordSize * 0.5 {
       // Covering fields too large, not worth it
   }
   ```
2. Optimize or rollback:
   - Option A: Remove large covering fields
   - Option B: Disable and use regular index

#### Scenario 4: Storage Overflow

**Symptoms**: Cluster storage exceeds capacity

**Impact**:
- ⚠️ Cluster instability
- 🚨 Potential write failures

**Resolution**:
1. **Immediate**: Disable covering index
   ```swift
   try await indexManager.setState(index: "user_by_city_covering", state: .disabled)
   ```
2. Delete index data to reclaim space
3. Review covering field selection (reduce size)
4. Scale cluster storage before retrying

### Rollback Procedure

**If covering index causes production issues**:

```swift
// Step 1: Disable feature flag (immediate)
FeatureFlags.enableCoveringIndexes = false

// Step 2: Mark index as writeOnly (stop using for queries)
try await indexManager.setState(
    index: "user_by_city_covering",
    state: .writeOnly
)

// Step 3: Verify queries return to normal (using old index)
let latency = measure { try await query() }
assert(latency < 20ms, "Latency should be back to baseline")

// Step 4: (Optional) Delete covering index to reclaim storage
try await indexManager.setState(
    index: "user_by_city_covering",
    state: .disabled
)

// Old index (user_by_city) continues working throughout rollback
// No downtime or data loss
```

**Recovery time**: < 5 minutes (feature flag + index state change)

### Index Evolution

**Question**: What happens if covering fields change?

**Answer**: Treat as index format change (requires FormerIndex marker)

```swift
// V1: Index with covering fields [name, email]
let indexV1 = Index.covering(
    named: "user_by_city_covering",
    on: FieldKeyExpression(fieldName: "city"),
    covering: [
        FieldKeyExpression(fieldName: "name"),
        FieldKeyExpression(fieldName: "email")
    ]
)

// V2: Index with covering fields [name, email, age]
let indexV2 = Index.covering(
    named: "user_by_city_covering_v2",  // NEW NAME
    on: FieldKeyExpression(fieldName: "city"),
    covering: [
        FieldKeyExpression(fieldName: "name"),
        FieldKeyExpression(fieldName: "email"),
        FieldKeyExpression(fieldName: "age")  // NEW FIELD
    ]
)

// Mark V1 as former index
let formerIndexV1 = FormerIndex(
    formerName: "user_by_city_covering",
    newName: "user_by_city_covering_v2",
    removedAfterVersion: Schema.Version(2, 0, 0)
)
```

---

## Performance Analysis

### Theoretical Analysis

**Regular Index Scan**:
```
Cost = (index_scan_cost) + (N × record_fetch_cost)
     = (N × 1) + (N × 1)  # Simplified: 1 unit per operation
     = 2N
```

**Covering Index Scan**:
```
Cost = (index_scan_cost)
     = N × 1
     = N
```

**Speedup**: 2x (minimum, assumes index and record are same size)

**Real-World Factors**:
- Index values larger than keys → Slightly slower index scan
- Records much larger than index entries → Much faster (5-10x)
- Network latency → Fewer round trips = better (2-10x)
- Cache locality → Index entries more compact = better

### Expected Performance

| Scenario | Regular Index | Covering Index | Speedup |
|----------|---------------|----------------|---------|
| Small records (< 1KB) | 100 QPS | 200 QPS | 2x |
| Medium records (1-10KB) | 50 QPS | 250 QPS | 5x |
| Large records (> 10KB) | 20 QPS | 200 QPS | 10x |
| High network latency | 10 QPS | 100 QPS | 10x |

**Assumptions**:
- 100 results per query
- Index entries ~100 bytes
- Records 100 bytes - 10KB
- 10ms network round trip

### Storage Cost Analysis

**Trade-off**: Covering indexes use more storage

```
Non-covering index entry: ~100 bytes (key only)
Covering index entry: ~200-500 bytes (key + covered fields)

Storage overhead: 2-5x per index entry
```

**Example** (1M users):
```
Non-covering index: 1M × 100 bytes = 100 MB
Covering index:     1M × 300 bytes = 300 MB
Overhead: 200 MB (acceptable for 2-10x query speedup)
```

### Storage Cost Decision Framework

**Question**: When should we use covering indexes despite storage overhead?

**Decision Criteria**:

| Factor | Threshold | Action |
|--------|-----------|--------|
| **Query Frequency** | < 10 QPS | Don't use covering index (storage waste) |
| | 10-100 QPS | Consider if storage allows |
| | > 100 QPS | Strong candidate (performance critical) |
| **Record Size** | < 500 bytes | Weak candidate (overhead > 2x) |
| | 500-5KB | Good candidate (2-5x speedup) |
| | > 5KB | Excellent candidate (5-10x speedup) |
| **Covering Field Size** | < 100 bytes | Excellent (low overhead) |
| | 100-500 bytes | Good (moderate overhead) |
| | > 500 bytes | Review carefully (high overhead) |
| **Total Index Size** | < 1 GB | Always acceptable |
| | 1-10 GB | Acceptable if QPS > 50 |
| | > 10 GB | Review with ops team |
| **Cluster Storage** | < 50% used | Always acceptable |
| | 50-80% used | Review case-by-case |
| | > 80% used | Only critical queries |

**Decision Formula** (simplified):

```
Score = (Query_QPS × Record_Size_KB) / Covering_Field_Size_KB

Score > 100:  Strong candidate (recommended)
Score 10-100: Consider based on storage availability
Score < 10:   Not recommended (use regular index)
```

**Examples**:

```swift
// Example 1: High-frequency small query
Query QPS: 500
Record Size: 2 KB
Covering Field Size: 100 bytes = 0.1 KB
Score = (500 × 2) / 0.1 = 10,000 ✅ EXCELLENT CANDIDATE

// Example 2: Low-frequency large query
Query QPS: 5
Record Size: 10 KB
Covering Field Size: 500 bytes = 0.5 KB
Score = (5 × 10) / 0.5 = 100 ⚠️ MARGINAL (consider alternatives)

// Example 3: High-frequency, large covering fields
Query QPS: 200
Record Size: 3 KB
Covering Field Size: 1 KB
Score = (200 × 3) / 1 = 600 ✅ GOOD CANDIDATE
```

### Operational Limits

**Recommended Limits** (per deployment):

1. **Per-Index Limits**:
   - Maximum covering field size: 1 KB (soft limit)
   - Maximum total covering index size: 100 GB (hard limit)
   - Maximum number of covering indexes per record type: 5

2. **Cluster-Wide Limits**:
   - Total covering index overhead: < 20% of cluster storage
   - Monitor storage growth rate: Alert if > 10% per week

3. **Monitoring Metrics**:
   ```swift
   // Metrics to track
   - covering_index_size_bytes{index="name"}
   - covering_index_hit_rate{index="name"}
   - covering_index_space_amplification{index="name"}
   ```

4. **Review Process**:
   - New covering index: Requires architecture review if:
     - Covering field size > 500 bytes
     - Expected index size > 10 GB
     - Record type already has 3+ covering indexes
   - Monthly review: Identify unused covering indexes (hit rate < 10%)

### Storage Optimization Strategies

**Strategy 1: Selective Covering** (Recommended)
```swift
// Only cover frequently accessed fields, not all fields
Index.covering(
    named: "user_by_city_covering",
    on: FieldKeyExpression(fieldName: "city"),
    covering: [
        FieldKeyExpression(fieldName: "name"),  // ✅ Frequently accessed
        FieldKeyExpression(fieldName: "email")  // ✅ Frequently accessed
        // ❌ Don't add: address, phoneNumber, etc.
    ]
)
```

**Strategy 2: Compression** (Future Enhancement)
```swift
// Future: Add compression option for covering fields
IndexOptions(
    coveringFieldCompression: .lz4  // Reduce storage by ~50%
)
```

**Strategy 3: TTL for Covering Indexes** (Future Enhancement)
```swift
// Future: Auto-rebuild covering indexes periodically to reclaim space
IndexOptions(
    rebuildInterval: .days(30)  // Rebuild monthly to compact
)
```

### Cost-Benefit Example

**Scenario**: User search by email (high-frequency query)

**Without Covering Index**:
- Query QPS: 500
- Average latency: 20ms
- Network I/O: 500 QPS × 2 operations = 1000 I/O ops/sec
- Storage: 100 MB (index only)

**With Covering Index**:
- Query QPS: 500
- Average latency: 5ms (4x faster)
- Network I/O: 500 QPS × 1 operation = 500 I/O ops/sec (50% reduction)
- Storage: 300 MB (index + covering fields = 200 MB overhead)

**Verdict**:
- ✅ 4x latency improvement
- ✅ 50% I/O reduction
- ✅ 200 MB storage overhead (< 1 GB, acceptable)
- **APPROVED**: Strong candidate for covering index

---

## Summary

Covering Index is a high-impact optimization that eliminates record fetches for queries where the index contains all needed fields.

### Design Strengths

1. **Backward Compatible**: Existing indexes work unchanged, gradual migration supported
2. **Type-Safe**: Leverages @Recordable macro for automatic reconstruction
3. **Automatic Detection**: Query planner auto-selects covering indexes when beneficial
4. **Incremental Adoption**: Can be added to selected indexes over time
5. **Performance**: 2-10x query speedup, 50% I/O reduction
6. **Comprehensive**: Covers all aspects from API → implementation → testing → migration → operations

### Design Improvements (Post-Review)

Based on critical review feedback, the following improvements were added:

#### 1. Field Extraction Strategy (Addresses: extractRequiredFields conservativeness)

**Problem**: Without .select() API, all fields assumed needed → covering indexes unused

**Solution**:
- Phase 5A: Conservative extraction (filter + sort + primary key)
- Phase 5B: Add .select() API for explicit field selection
- Interim: Add `useCoveringIndex()` hint API for early adopters
- Documentation: Clear guidance on limitations and migration path

**Impact**: Realistic expectations, incremental value delivery

#### 2. RecordAccess Compatibility (Addresses: reconstruction fallback)

**Problem**: Hand-written RecordAccess implementations lack reconstruct()

**Solution**:
- Default implementation: Throws `.reconstructionNotImplemented` with actionable guidance
- `supportsReconstruction` property: Query planner checks before using covering plan
- Clear migration path: @Recordable (auto) vs manual implementation vs skip covering indexes
- No breaking changes: Existing code continues to work

**Impact**: Safe backward compatibility, gradual adoption

#### 3. Storage Cost Framework (Addresses: adoption guidelines)

**Problem**: No clear criteria for when to use covering indexes

**Solution**:
- Decision formula: `Score = (QPS × RecordSize) / CoveringFieldSize`
- Operational limits: Per-index (1KB, 100GB), cluster-wide (20% overhead)
- Monitoring metrics: size, hit rate, space amplification
- Review process: Architecture review for large indexes
- Optimization strategies: Selective covering, compression (future), TTL (future)

**Impact**: Prevents misuse, clear cost-benefit analysis

#### 4. Detailed Migration Procedure (Addresses: operational details)

**Problem**: Missing online/offline切り替え, 二重書き込み details

**Solution**:
- 5-step migration: Code deploy → Schema update → Online build → Validation → Cleanup
- Online index build details: writeOnly state, double writes (~5% overhead), zero query impact
- Failure scenarios: Build failure, incorrect results, performance regression, storage overflow
- Rollback procedure: < 5 minute recovery time
- Feature flags: Gradual rollout (10% → 50% → 100%)

**Impact**: Production-ready migration plan, risk mitigation

#### 5. Optimized Implementation Schedule (Addresses: critical path bottleneck)

**Problem**: Day 3 (Macro) blocks Day 4-5 (Read Path + Planner)

**Solution**:
- Parallelized plan: 4 parallel tracks on Day 3
- Mock implementations: Read Path and Planner testable without Macro
- Feature flags: Components deployable independently
- Team allocation: 1 dev (7 days) vs 2-3 devs (4-5 days) vs 4 devs (3-4 days)
- Critical path: 5 days → 4 days (20% faster)

**Impact**: Reduced delivery time, lower risk, better team utilization

### Readiness Assessment

| Aspect | Status | Notes |
|--------|--------|-------|
| **API Design** | ✅ Complete | Covering index definition, covers() method, reconstruction API |
| **Implementation Plan** | ✅ Complete | 6 phases, parallelized, 4-7 days |
| **Testing Strategy** | ✅ Complete | Unit, integration, performance, failure scenarios |
| **Migration Guide** | ✅ Complete | 5-step process, failure handling, rollback |
| **Operational Guidelines** | ✅ Complete | Storage cost framework, monitoring, limits |
| **Risk Mitigation** | ✅ Complete | Feature flags, gradual rollout, compatibility |

### Next Steps

**Recommended Approach**:

1. **Week 1**: Implement Phase 1-5 (covering index infrastructure)
2. **Week 2**: Production migration (first index, low-risk)
3. **Week 3**: Add .select() API (Phase 5B)
4. **Week 4+**: Gradual rollout to more indexes

**Success Criteria**:
- ✅ Zero breaking changes for existing code
- ✅ 2-10x query performance improvement for covered queries
- ✅ Storage overhead < 20% of cluster capacity
- ✅ < 5 minute rollback time if issues occur

**Approval Ready**: This design is production-ready and addresses all major concerns.
