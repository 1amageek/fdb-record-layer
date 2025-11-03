# fdb-record-layer Architecture Reference

## Layered Architecture Overview

This project is part of the **FoundationDB Swift ecosystem** which follows a layered architecture pattern.

```
┌──────────────────────────────────────────────────┐
│          Your Application Code                   │
└────────────────────┬─────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────┐
│     fdb-record-layer (THIS PROJECT)              │
│  - RecordStore, Indexes, Query Planning          │
│  - Schema Management, Aggregations               │
└────────────────────┬─────────────────────────────┘
                     │ depends on
┌────────────────────▼─────────────────────────────┐
│     fdb-swift-bindings (FOUNDATION LAYER)        │
│  - Tuple, Subspace, Versionstamp, Directory      │
│  - Client, Database, Transaction                 │
└────────────────────┬─────────────────────────────┘
                     │ wraps
┌────────────────────▼─────────────────────────────┐
│     CFoundationDB (C API)                        │
│  - fdb_transaction_get/set                       │
│  - Raw key-value operations                      │
└──────────────────────────────────────────────────┘
```

## Design Principles

### 1. Single Source of Truth

**❌ WRONG** (Current state):
```swift
// fdb-record-layer/Sources/FDBRecordLayer/Core/Subspace.swift
public struct Subspace { ... }  // ⚠️ Duplicate implementation
```

**✅ CORRECT** (Target state):
```swift
// Use Subspace from fdb-swift-bindings
import FoundationDB

public final class RecordStore<M> {
    private let subspace: Subspace  // ← From fdb-swift-bindings
}
```

### 2. Layer Responsibilities

**This Project (fdb-record-layer)**:
- ✅ RecordStore, RecordMetaData
- ✅ Index maintenance (Value, Count, Sum, Rank)
- ✅ Query planning and optimization
- ✅ Online index building
- ✅ Statistics management
- ✅ Schema validation

**Foundation Layer (fdb-swift-bindings)**:
- ✅ Tuple encoding/decoding
- ✅ Subspace management
- ✅ Versionstamp support
- ✅ Directory Layer
- ✅ Tenant Management
- ✅ Locality information

**Rule of Thumb**: If multiple applications would use it, it belongs in `fdb-swift-bindings`.

## Migration Plan

### Phase 1: Remove Local Subspace ⚠️ REQUIRED

**Current** (fdb-record-layer has its own Subspace):
```
Sources/FDBRecordLayer/Core/
└── Subspace.swift  ← Remove this
```

**After** (Use Subspace from fdb-swift-bindings):
```swift
import FoundationDB  // Provides Subspace

// No changes to usage code needed
let subspace = Subspace(rootPrefix: "my-app")
```

**Timeline**: After fdb-swift-bindings implements Subspace (Q4 2025)

### Phase 2: Use Versionstamp from Bindings ⚠️ REQUIRED

**Current** (Manual versionstamp handling):
```swift
var key = tuple.encode()
key.append(contentsOf: [0xFF, 0xFF, ...])  // Manual
```

**After** (Type-safe Versionstamp):
```swift
import FoundationDB

let vs = Versionstamp.incomplete(userVersion: 0)
let key = try Tuple("event", vs).packWithVersionstamp()
```

**Timeline**: After fdb-swift-bindings implements Versionstamp (Q4 2025)

### Phase 3: Use Directory Layer ⏳ OPTIONAL

**Future** (When Directory Layer is implemented):
```swift
import FoundationDB

let recordDir = try await directory.createOrOpen(["records", "users"])
let recordStore = RecordStore(
    database: database,
    subspace: recordDir,  // DirectorySubspace is a Subspace
    metaData: metaData
)
```

## Dependency Management

### Current Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/foundationdb/fdb-swift-bindings.git", branch: "main")
]
```

**Status**: ✅ Correct - Record Layer depends on bindings

### What NOT to Do

❌ **DO NOT** implement features that belong in fdb-swift-bindings:
- Tuple layer enhancements
- Subspace utilities
- Versionstamp handling
- Directory Layer
- Tenant Management

❌ **DO NOT** copy code from fdb-swift-bindings into this project

✅ **DO** propose new features to fdb-swift-bindings via issues/PRs

## Reference Documentation

For the complete architecture design, see:
- [fdb-swift-bindings/LAYERED_ARCHITECTURE_DESIGN.md](../fdb-swift-bindings/LAYERED_ARCHITECTURE_DESIGN.md)

## Java Ecosystem Comparison

This architecture mirrors the Java ecosystem:

| Java | Swift |
|------|-------|
| `fdb-java` | `fdb-swift-bindings` |
| `fdb-record-layer` (Java) | `fdb-record-layer` (Swift) |

**Java Example**:
```java
// fdb-record-layer (Java) depends on fdb-java
import com.apple.foundationdb.tuple.Tuple;
import com.apple.foundationdb.subspace.Subspace;
```

**Swift Equivalent**:
```swift
// fdb-record-layer (Swift) depends on fdb-swift-bindings
import FoundationDB  // Provides Tuple, Subspace, etc.
```

## Contact

Questions about architecture? Open an issue at:
- https://github.com/foundationdb/fdb-swift-bindings/issues

---

**Last Updated**: 2025-11-01
**Status**: Reference Document
