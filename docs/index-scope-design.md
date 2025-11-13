# IndexScope Design: Partition Isolation and Global Queries

**Version**: 1.0
**Date**: 2025-01-13
**Status**: Design Proposal

---

## Table of Contents

1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Design Solution: IndexScope](#design-solution-indexscope)
4. [Macro Roles](#macro-roles)
5. [Key Structures](#key-structures)
6. [Use Cases](#use-cases)
7. [Implementation Details](#implementation-details)
8. [Validation Rules](#validation-rules)
9. [Migration Guide](#migration-guide)

---

## Overview

This document describes the design of `IndexScope`, a feature that enables both **partition-local indexes** and **cross-partition global indexes** in the FDB Record Layer.

### Motivation

Modern multi-tenant applications (e.g., AirBnB, Uber, Amazon Marketplace) require:
1. **Tenant isolation**: Data physically separated by tenant for security and performance
2. **Global queries**: Cross-tenant analytics and rankings (e.g., global hotel ratings)

The `#Directory` macro with `layer: .partition` provides tenant isolation, but prevents cross-partition queries. **IndexScope** solves this by allowing indexes to be either partition-local or globally accessible.

---

## Problem Statement

### Current Limitation

```swift
@Recordable
struct Hotel {
    #PrimaryKey<Hotel>([\.hotelID])
    #Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)
    #Index<Hotel>([\.rating], type: .rank)

    var ownerID: String
    var hotelID: Int64
    var rating: Double
}
```

**Physical structure**:
```
owner-A: [owner-A-prefix][records][Hotel][hotelID]
         [owner-A-prefix][indexes][rating][rating][hotelID]
owner-B: [owner-B-prefix][records][Hotel][hotelID]
         [owner-B-prefix][indexes][rating][rating][hotelID]
```

**Problem**: Cannot query global hotel ratings across all owners.

### Real-World Example: AirBnB-like Marketplace

**Requirements**:
- Hotel owners manage their properties independently (tenant isolation)
- Users search ALL hotels by rating, price, location (global queries)
- Platform needs global statistics (total hotels, average rating, etc.)

**Trade-off**: Partition isolation vs cross-partition queries

---

## Design Solution: IndexScope

### IndexScope Enum

```swift
public enum IndexScope: String, Sendable {
    /// Index is local to each partition (default)
    case partition

    /// Index spans across all partitions globally
    case global
}
```

### Usage Example

```swift
@Recordable
struct Hotel {
    // Composite primary key for global uniqueness
    #PrimaryKey<Hotel>([\.ownerID, \.hotelID])

    // Partition by owner
    #Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)

    // Partition-local index (owner-specific queries)
    #Index<Hotel>([\.name], name: "by_name", scope: .partition)

    // Global index (cross-owner rankings)
    #Index<Hotel>([\.rating], type: .rank, name: "global_rating", scope: .global)

    var ownerID: String
    var hotelID: Int64
    var name: String
    var rating: Double
}
```

---

## Macro Roles

### Design Principle: Separation of Concerns

| Concern | Macro | Level |
|---------|-------|-------|
| **Record identification** | `#PrimaryKey` | Type |
| **Uniqueness constraints (single field)** | `@Attribute(.unique)` | Property |
| **Uniqueness constraints (composite)** | `#Unique` | Type |
| **Search optimization** | `#Index` | Type |
| **Physical placement** | `#Directory` | Type |
| **Schema evolution** | `@Attribute(.originalName)` | Property |

**Important**: `#Index` does NOT handle uniqueness. Use `@Attribute(.unique)` or `#Unique` instead.

### Uniqueness: @Attribute vs #Unique

| Use Case | Recommended Macro | Alternative | Notes |
|----------|-------------------|-------------|-------|
| **Single field** | `@Attribute(.unique)` | `#Unique<T>([\.field])` | Property-level preferred |
| **Composite (2+ fields)** | `#Unique<T>([\.f1, \.f2])` | N/A | Type-level only |

**Important Rules**:

1. ✅ **Single field**: Use `@Attribute(.unique)` (recommended)
   ```swift
   @Attribute(.unique) var email: String
   ```

2. ✅ **Single field alternative**: `#Unique<T>([\.field])` also works
   ```swift
   #Unique<User>([\.email])  // Same as @Attribute(.unique)
   ```

3. ✅ **Composite uniqueness**: Use `#Unique<T>([\.field1, \.field2])`
   ```swift
   #Unique<User>([\.firstName, \.lastName])
   ```

4. ✅ **Both on same field**: Automatically deduplicated (no error)
   ```swift
   @Attribute(.unique) var email: String
   #Unique<User>([\.email])  // OK: Generates single unique index
   ```

**Deduplication**: `RecordableMacro` automatically removes duplicates:
```swift
// Input:
@Attribute(.unique) var email: String
#Unique<User>([\.email])

// Generated (only one index):
Index(
    name: "email_unique",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email"),
    options: IndexOptions(unique: true)
)
```

**Why no error?**
- Both generate the same unique index
- No harm in specifying both
- Flexible for migration scenarios
- Developer-friendly

### Deprecated Macros

| Macro | Replacement | Reason |
|-------|-------------|--------|
| `@PrimaryKey var field` | `#PrimaryKey<T>([\.field])` | Use type-level macro for consistency |

---

### 1. #PrimaryKey - Record Identification

**Responsibility**: Define fields that uniquely identify a record.

**Syntax**:
```swift
// Single primary key
#PrimaryKey<User>([\.userID])

// Composite primary key
#PrimaryKey<Hotel>([\.ownerID, \.hotelID])
```

**Key characteristics**:
- Required: Every `@Recordable` struct must have exactly one `#PrimaryKey`
- Order matters: Field order defines the key structure
- Global uniqueness: Must ensure uniqueness across all partitions

**When to use composite primary keys**:
1. **Multi-tenant with global indexes**: `[\.tenantID, \.recordID]`
2. **Multi-category rankings**: `[\.gameMode, \.userID]`
3. **Time-series data**: `[\.year, \.month, \.eventID]`

---

### 2. #Index - Search Optimization

**Responsibility**: Define secondary indexes for query optimization.

**Syntax**:
```swift
#Index<T>([\.field...],
    type: .value | .rank | .count | .sum | .min | .max,
    name: "index_name",
    scope: .partition | .global
)
```

**Note**: For uniqueness constraints, use `@Attribute(.unique)` on the property instead.

**Index types**:

| Type | Purpose | Key Structure | Use Case |
|------|---------|---------------|----------|
| `.value` | Standard B-tree index | `[index][field...][pk...]` | Equality, range queries |
| `.rank` | Leaderboard rankings | `[index][grouping...][score][pk...]` | Top N, rankings |
| `.count` | Record counting | `[index][grouping...]` | Group counts |
| `.sum` | Value aggregation | `[index][grouping...]` | Sum by group |
| `.min/.max` | Min/max values | `[index][grouping...][value][pk...]` | Min/max by group |

**Scope**:

| Scope | Placement | Use Case |
|-------|-----------|----------|
| `.partition` (default) | Within partition subspace | Tenant-specific queries |
| `.global` | Shared global subspace | Cross-tenant queries |

---

### 3. #Directory - Physical Placement

**Responsibility**: Define physical layout and partitioning strategy.

**Syntax**:
```swift
#Directory<T>(["static", Field(\.dynamicField), "path"], layer: .partition)
```

**Layer types**:
- `.recordStore` (default): Standard storage
- `.partition`: Multi-tenant isolation with separate key spaces

**Partition keys**:
- Use `Field(\.fieldName)` for dynamic partition keys
- Fields must exist in the record struct
- Used for tenant isolation

---

### 4. @Attribute - Field Metadata

**Responsibility**: Define field-level metadata (unique constraints, schema evolution).

**Syntax**:
```swift
@Attribute(
    _ options: Schema.Attribute.Option...,  // Variadic options
    originalName: String? = nil,            // Named parameter
    hashModifier: String? = nil             // Named parameter
)
```

**Usage examples**:
```swift
// Unique constraint
@Attribute(.unique)

// Schema evolution (renamed field)
@Attribute(originalName: "username")

// Multiple options
@Attribute(.unique, .spotlight)

// Options + originalName
@Attribute(.unique, originalName: "email_address")

// All parameters
@Attribute(.unique, originalName: "old_name", hashModifier: "v2")
```

**Options**:

| Option | Purpose | Auto-generates | Status |
|--------|---------|----------------|--------|
| `.unique` | Enforce uniqueness | Unique index | ✅ Implemented |
| `.encrypted` | Encrypt field value | - | 🔮 Future |
| `.externalStorage` | Store large binary data externally | - | 🔮 Future |
| `.transformable(by:)` | Custom value transformation | - | 🔮 Future |

**Named Parameters**:

| Parameter | Purpose | Default | Status |
|-----------|---------|---------|--------|
| `originalName` | Previous field name (schema evolution) | `nil` | ✅ Implemented |
| `hashModifier` | Version hash for schema changes | `nil` | 🔮 Future |

**Reference**: Based on [SwiftData @Attribute](https://developer.apple.com/documentation/swiftdata/attribute(_:originalname:hashmodifier:))

**Example**:
```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    // Automatically generates a unique index
    @Attribute(.unique)
    var email: String

    // Schema evolution: field was renamed from "username" to "displayName"
    @Attribute(originalName: "username")
    var displayName: String

    // Multiple options + schema evolution
    @Attribute(.unique, .spotlight, originalName: "user_handle")
    var handle: String

    var userID: Int64
}
```

**Auto-generated indexes**:
```swift
// RecordableMacro generates:
Index(
    name: "email_unique",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email"),
    options: IndexOptions(unique: true)
)

Index(
    name: "handle_unique",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "handle"),
    options: IndexOptions(unique: true)
)
```

**Deserialization behavior**:
```swift
// When deserializing, if "displayName" is missing, try "username"
if record["displayName"] == nil {
    record["displayName"] = record["username"]
}
```

---

## Key Structures

### Record Keys (Partition-local)

```
[owner-A-prefix][records][Hotel][ownerID][hotelID]
[owner-B-prefix][records][Hotel][ownerID][hotelID]
```

**Characteristics**:
- Physically separated by partition
- Fast access within partition

---

### Partition-local Index (scope: .partition)

```
[owner-A-prefix][indexes][by_name][name][ownerID][hotelID]
[owner-B-prefix][indexes][by_name][name][ownerID][hotelID]
```

**Characteristics**:
- Index per partition
- Query scoped to current partition
- Fast (only scans partition data)

**Query example**:
```swift
let store = try await Hotel.store(ownerID: "owner-123", database: db, schema: schema)
let hotels = try await store.query(Hotel.self)
    .where(\.name, .startsWith, "Grand")
    .execute()
// → Only owner-123's hotels
```

---

### Global Index (scope: .global)

```
[root-subspace][global-indexes][global_rating][rating][ownerID][hotelID]
```

**Characteristics**:
- Single shared index across all partitions
- Partition key (ownerID) included for uniqueness
- Query accesses all partitions

**Query example**:
```swift
let store = try await Hotel.store(database: db, schema: schema)  // No ownerID
let rankQuery = try store.rankQuery(named: "global_rating")
let top100 = try await rankQuery.top(100)
// → All owners' hotels, globally ranked
```

---

## Use Cases

### Use Case 1: Single-Tenant Application

**Scenario**: Simple application with no multi-tenancy.

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    // Unique constraint on email
    @Attribute(.unique)
    var email: String

    var userID: Int64
    var name: String
}
```

**Characteristics**:
- No `#Directory` (default placement)
- Single primary key
- Standard indexes

---

### Use Case 2: Multi-Tenant SaaS (Partition-only)

**Scenario**: Slack-like workspace isolation, no cross-tenant queries needed.

```swift
@Recordable
struct Message {
    #PrimaryKey<Message>([\.messageID])
    #Directory<Message>(["workspaces", Field(\.workspaceID), "messages"], layer: .partition)
    #Index<Message>([\.timestamp], scope: .partition)

    var workspaceID: String
    var messageID: Int64
    var content: String
    var timestamp: Date
}
```

**Characteristics**:
- Partition by workspace
- Single primary key (unique within workspace)
- Partition-local indexes
- No cross-workspace queries

---

### Use Case 3: Marketplace (Partition + Global)

**Scenario**: AirBnB-like marketplace with owner isolation and global search.

```swift
@Recordable
struct Hotel {
    #PrimaryKey<Hotel>([\.ownerID, \.hotelID])
    #Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)

    // Owner-specific queries
    #Index<Hotel>([\.name], name: "by_name", scope: .partition)

    // Global marketplace queries
    #Index<Hotel>([\.rating], type: .rank, name: "global_rating", scope: .global)
    #Index<Hotel>([\.location, \.price], name: "global_search", scope: .global)

    var ownerID: String
    var hotelID: Int64
    var name: String
    var rating: Double
    var location: String
    var price: Int64
}
```

**Query patterns**:

```swift
// 1. Owner dashboard (partition-local)
let store = try await Hotel.store(ownerID: "owner-123", database: db, schema: schema)
let myHotels = try await store.query(Hotel.self)
    .where(\.name, .contains, "Grand")
    .execute()

// 2. Global hotel search (cross-partition)
let globalStore = try await Hotel.store(database: db, schema: schema)
let topRated = try await globalStore.query(Hotel.self)
    .where(\.rating, .greaterThan, 4.5)
    .where(\.location, .equals, "Tokyo")
    .execute()

// 3. Global rankings
let rankQuery = try globalStore.rankQuery(named: "global_rating")
let top100 = try await rankQuery.top(100)
```

---

### Use Case 4: Multi-Category Rankings

**Scenario**: Game with multiple modes, rankings per mode AND global.

```swift
@Recordable
struct GameScore {
    #PrimaryKey<GameScore>([\.gameMode, \.userID])

    // Per-mode rankings
    #Index<GameScore>([\.gameMode, \.score], type: .rank, name: "mode_rank")

    // Global rankings across all modes
    #Index<GameScore>([\.score], type: .rank, name: "global_rank", scope: .global)

    var gameMode: String  // "normal", "hard", "extreme"
    var userID: Int64
    var score: Int64
}
```

**Query patterns**:

```swift
// Mode-specific ranking
let modeRank = try store.rankQuery(named: "mode_rank")
let hardModeTop10 = try await modeRank.getRecordsByRankRange(
    groupingValues: ["hard"],
    startRank: 1,
    endRank: 10
)

// Global ranking (all modes)
let globalRank = try store.rankQuery(named: "global_rank")
let globalTop100 = try await globalRank.top(100)
```

---

## Implementation Details

### Index Struct Changes

```swift
public struct Index: Sendable {
    public let name: String
    public let type: IndexType
    public let rootExpression: KeyExpression
    public let scope: IndexScope  // NEW
    // ... existing fields

    public init(
        name: String,
        type: IndexType = .value,
        rootExpression: KeyExpression,
        scope: IndexScope = .partition,  // Default: partition-local
        // ... existing parameters
    ) {
        self.scope = scope
        // ...
    }
}
```

---

### IndexManager Changes

```swift
class IndexManager {
    private let rootSubspace: Subspace
    private let partitionSubspace: Subspace

    func getIndexSubspace(index: Index) -> Subspace {
        switch index.scope {
        case .partition:
            // Existing behavior: within partition
            return partitionSubspace.subspace("I").subspace(index.name)

        case .global:
            // New behavior: global shared space
            return rootSubspace.subspace("global-indexes").subspace(index.name)
        }
    }

    func updateIndex(
        index: Index,
        record: Record,
        transaction: TransactionProtocol
    ) async throws {
        let indexSubspace = getIndexSubspace(index: index)
        let indexKey = buildIndexKey(
            subspace: indexSubspace,
            record: record,
            index: index
        )
        transaction.setValue([], for: indexKey)
    }
}
```

---

### #Index Macro Changes

```swift
// IndexMacro.swift

public struct IndexMacro: DeclarationMacro {
    public static func expansion(...) throws -> [DeclSyntax] {
        // Extract scope parameter
        // scope: .partition (default)
        // scope: .global

        // Validate: global scope requires composite primary key
        // (validation delegated to RecordableMacro)

        return []  // Marker macro
    }
}
```

---

### RecordableMacro Validation

```swift
// RecordableMacro.swift

// Validation logic
func validateGlobalIndexes(
    indexes: [IndexInfo],
    primaryKeyFields: [String],
    directoryPartitionFields: [String]
) throws {

    let globalIndexes = indexes.filter { $0.scope == .global }

    if !globalIndexes.isEmpty && !directoryPartitionFields.isEmpty {
        // Global indexes with partitions require composite primary key

        // Check: partition fields must be in primary key
        for partitionField in directoryPartitionFields {
            guard primaryKeyFields.contains(partitionField) else {
                throw Error("""
                Global scope index requires partition field '\(partitionField)' \
                in #PrimaryKey for global uniqueness.

                Fix:
                #PrimaryKey<\(typeName)>([\\.\(partitionField), ...])
                """)
            }
        }
    }
}
```

---

## Validation Rules

### Rule 1: Global Index + Partition → Composite Primary Key

**Condition**: If ANY index has `scope: .global` AND `#Directory` has `layer: .partition`

**Requirement**: Primary key MUST include all partition fields.

**Example**:

```swift
// ✅ Valid
#PrimaryKey<Hotel>([\.ownerID, \.hotelID])
#Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)
#Index<Hotel>([\.rating], scope: .global)

// ❌ Invalid - Missing ownerID in primary key
#PrimaryKey<Hotel>([\.hotelID])
#Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)
#Index<Hotel>([\.rating], scope: .global)
// Error: Global scope index requires partition field 'ownerID' in #PrimaryKey
```

---

### Rule 2: Partition Field Order in Primary Key

**Condition**: Partition fields should appear FIRST in primary key.

**Reason**: Ensures records are physically grouped by partition key.

**Example**:

```swift
// ✅ Recommended
#PrimaryKey<Hotel>([\.ownerID, \.hotelID])

// ⚠️ Works but not optimal
#PrimaryKey<Hotel>([\.hotelID, \.ownerID])
```

---

### Rule 3: Single #PrimaryKey Definition

**Condition**: Only ONE `#PrimaryKey` macro per record type.

**Example**:

```swift
// ❌ Invalid - Multiple #PrimaryKey
#PrimaryKey<Hotel>([\.ownerID])
#PrimaryKey<Hotel>([\.hotelID])
// Error: Multiple #PrimaryKey definitions found
```

---

## Migration Guide

### Before: Partition-only Design

```swift
@Recordable
struct Hotel {
    @PrimaryKey var hotelID: Int64
    var ownerID: String
    var rating: Double
}

// Problem: Cannot query global ratings
```

---

### After: With IndexScope

```swift
@Recordable
struct Hotel {
    #PrimaryKey<Hotel>([\.ownerID, \.hotelID])
    #Directory<Hotel>(["owners", Field(\.ownerID), "hotels"], layer: .partition)
    #Index<Hotel>([\.rating], type: .rank, name: "global_rating", scope: .global)

    var ownerID: String
    var hotelID: Int64
    var rating: Double
}
```

**Migration steps**:

1. Replace `@PrimaryKey` with `#PrimaryKey<T>([\.field...])`
2. Add partition fields to primary key: `[\.ownerID, \.hotelID]`
3. Add `scope: .global` to indexes that need cross-partition access
4. Update queries to use appropriate store instances

---

## Performance Considerations

### Partition-local Index (scope: .partition)

**Advantages**:
- ✅ Fast queries (only scans partition data)
- ✅ Better cache locality
- ✅ Lower storage overhead per partition

**Trade-offs**:
- ❌ Cannot query across partitions
- ❌ No global statistics

**When to use**:
- Tenant-specific queries (user messages, orders, etc.)
- High query volume within partition
- No need for cross-tenant analytics

---

### Global Index (scope: .global)

**Advantages**:
- ✅ Cross-partition queries
- ✅ Global rankings and statistics
- ✅ Marketplace-style search

**Trade-offs**:
- ⚠️ Larger index (contains all partitions)
- ⚠️ Write amplification (updates both record + global index)
- ⚠️ Requires composite primary key

**When to use**:
- Marketplace search (all products, all hotels)
- Global leaderboards
- Cross-tenant analytics
- Platform-wide statistics

---

## Design Trade-offs Summary

| Aspect | Partition-only | Partition + Global Index |
|--------|---------------|--------------------------|
| **Tenant isolation** | ✅ Complete | ✅ Complete (records) |
| **Global queries** | ❌ Not possible | ✅ Possible |
| **Primary key** | Single field OK | Composite required |
| **Storage overhead** | Lower | Higher (global indexes) |
| **Write performance** | Faster | Slower (writes to global index) |
| **Query flexibility** | Limited | High |

---

## References

- [FoundationDB Record Layer (Java)](https://github.com/FoundationDB/fdb-record-layer)
- [Directory Layer Design](https://apple.github.io/foundationdb/developer-guide.html#directories)
- [RANK Index Design](./rank-index-design.md)
- [Multi-Tenant Best Practices](./best-practices.md)

---

## Changelog

- **2025-01-13**: Initial design proposal
