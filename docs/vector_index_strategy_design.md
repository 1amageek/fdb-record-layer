# Vector Index Strategy Design

**Document Version**: 1.0
**Date**: 2025-01-16
**Status**: 🔄 Design Proposal
**Authors**: Record Layer Team

---

## Executive Summary

This document proposes a redesign of `VectorIndexOptions` to use an enum-based strategy pattern instead of two independent Boolean flags. The new design improves type safety, eliminates invalid configurations, and provides better extensibility.

**Current Problem**: Two independent Boolean flags (`allowHNSWSearch`, `allowInlineIndexing`) create invalid combinations and unclear intent.

**Proposed Solution**: Enum with associated value (`.flatScan`, `.hnsw(inlineIndexing: Bool)`) that enforces valid configurations at compile time.

---

## Table of Contents

1. [Current Design Problems](#current-design-problems)
2. [Proposed Design](#proposed-design)
3. [Design Rationale](#design-rationale)
4. [API Changes](#api-changes)
5. [Migration Guide](#migration-guide)
6. [Implementation Impact](#implementation-impact)
7. [Testing Strategy](#testing-strategy)

---

## Current Design Problems

### Problem 1: Independent Boolean Flags

**Current Implementation** (`Sources/FDBRecordCore/IndexDefinition.swift`):

```swift
public struct VectorIndexOptions: Sendable {
    public let dimensions: Int
    public let metric: VectorMetric
    public let allowHNSWSearch: Bool  // ❌ Independent flag 1
    public let allowInlineIndexing: Bool  // ❌ Independent flag 2

    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine,
        allowHNSWSearch: Bool = false,
        allowInlineIndexing: Bool = false
    ) { ... }
}
```

### Problem 2: Invalid Combinations

| allowHNSWSearch | allowInlineIndexing | Meaning | Valid? |
|----------------|---------------------|---------|--------|
| `false` | `false` | Flat scan (default) | ✅ Valid |
| `false` | `true` | Flat scan + ??? | ❌ **Invalid** - flat scan always uses inline updates |
| `true` | `false` | HNSW + batch updates | ✅ Valid (recommended) |
| `true` | `true` | HNSW + inline updates | ✅ Valid but dangerous |

**Issue**: The combination `allowHNSWSearch = false, allowInlineIndexing = true` is **semantically meaningless** because:
- Flat scan always performs inline updates (single `setValue()` operation)
- `allowInlineIndexing` only has meaning for HNSW (graph updates)
- However, the type system **cannot prevent** this invalid configuration

### Problem 3: Unclear Intent

```swift
// ❓ What does this mean?
let options = VectorIndexOptions(
    dimensions: 768,
    allowHNSWSearch: false,
    allowInlineIndexing: true  // This is ignored! But the compiler doesn't warn.
)
```

**Developer confusion**:
- Why does `allowInlineIndexing` exist if `allowHNSWSearch` is false?
- Is this a valid configuration or a bug?
- Will this be ignored or cause an error?

### Problem 4: Poor Extensibility

Adding new parameters to HNSW (e.g., `m`, `efConstruction`) would require:
1. New fields in `VectorIndexOptions`
2. Validation logic to check if `allowHNSWSearch = true`
3. More complex invalid combinations

```swift
// Future extension (bad design)
public struct VectorIndexOptions: Sendable {
    public let allowHNSWSearch: Bool
    public let allowInlineIndexing: Bool  // Only for HNSW
    public let m: Int?  // Only for HNSW ❌
    public let efConstruction: Int?  // Only for HNSW ❌
    // Validation nightmare!
}
```

---

## Proposed Design

### Enum with Associated Value

**New Implementation**:

```swift
// Sources/FDBRecordCore/IndexDefinition.swift

/// Strategy for vector index implementation
public enum VectorIndexStrategy: Sendable, Equatable {
    /// Flat scan: O(n) search, low memory (~1.5 GB for 1M vectors, 384 dims)
    ///
    /// **Characteristics**:
    /// - Always uses inline updates (safe - single `setValue()` operation)
    /// - No graph construction required
    /// - Best for small datasets (<10,000 vectors)
    ///
    /// **Memory usage**: ~dimensions × 4 bytes × vector count
    /// - Example: 384 dims × 4 bytes × 1M vectors = ~1.5 GB
    case flatScan

    /// HNSW: O(log n) search, high memory (~15 GB for 1M vectors, 384 dims)
    ///
    /// **Parameters**:
    /// - `inlineIndexing`: If `true`, updates HNSW graph during `RecordStore.save()`
    ///   - ⚠️ **Dangerous**: Graph updates require ~1,320-12,000 FDB operations
    ///   - ⚠️ **Risk**: Transaction timeout (5s limit) and size limit (10MB)
    ///   - ✅ **Only use for tiny graphs** (<1,000 vectors) where timeout risk is acceptable
    ///
    ///   If `false` (recommended), only stores vectors during `save()`:
    ///   - ✅ **Safe**: Single `setValue()` operation per vector
    ///   - ✅ **Graph built separately**: Use `OnlineIndexer.buildHNSWIndex()`
    ///   - ✅ **Best for production**: Large datasets, predictable performance
    ///
    /// **Characteristics**:
    /// - Hierarchical graph structure (multi-level)
    /// - Best for large datasets (>100,000 vectors)
    /// - Requires sufficient memory for graph edges
    ///
    /// **Memory usage**: ~10× flat scan (graph edges + vectors)
    /// - Example: 384 dims × 4 bytes × 1M vectors × 10 = ~15 GB
    case hnsw(inlineIndexing: Bool)

    // Convenience properties

    /// HNSW with batch updates (recommended for production)
    ///
    /// Equivalent to `.hnsw(inlineIndexing: false)`
    public static var hnswBatch: VectorIndexStrategy {
        .hnsw(inlineIndexing: false)
    }

    /// HNSW with inline updates (dangerous - only for tiny graphs)
    ///
    /// Equivalent to `.hnsw(inlineIndexing: true)`
    ///
    /// ⚠️ **Warning**: Only use for graphs with <1,000 vectors where transaction timeout risk is acceptable.
    public static var hnswInline: VectorIndexStrategy {
        .hnsw(inlineIndexing: true)
    }
}

/// Vector index configuration
public struct VectorIndexOptions: Sendable {
    /// Number of vector dimensions (required)
    public let dimensions: Int

    /// Distance metric for similarity calculation
    public let metric: VectorMetric

    /// Index implementation strategy
    ///
    /// **Default**: `.flatScan` (safe for all environments)
    ///
    /// **Production recommendation**: `.hnsw(inlineIndexing: false)` for large datasets (>100,000 vectors)
    public let strategy: VectorIndexStrategy

    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine,
        strategy: VectorIndexStrategy = .flatScan  // Safe default
    ) {
        self.dimensions = dimensions
        self.metric = metric
        self.strategy = strategy
    }
}
```

---

## Design Rationale

### Advantage 1: Type Safety

**Impossible to create invalid configurations**:

```swift
// ❌ OLD: Invalid combination allowed
let badOptions = VectorIndexOptions(
    dimensions: 768,
    allowHNSWSearch: false,
    allowInlineIndexing: true  // Meaningless! But compiles.
)

// ✅ NEW: Invalid combination impossible
// flatScan has no inlineIndexing parameter
let goodOptions = VectorIndexOptions(
    dimensions: 768,
    strategy: .flatScan  // Clean, unambiguous
)
```

### Advantage 2: Clear Intent

```swift
// ✅ Flat scan (small datasets, development)
VectorIndexOptions(dimensions: 384, strategy: .flatScan)

// ✅ HNSW with batch updates (large datasets, production)
VectorIndexOptions(dimensions: 768, strategy: .hnsw(inlineIndexing: false))
// Or use convenience property
VectorIndexOptions(dimensions: 768, strategy: .hnswBatch)

// ⚠️ HNSW with inline updates (tiny graphs only)
VectorIndexOptions(dimensions: 128, strategy: .hnsw(inlineIndexing: true))
// Or use convenience property
VectorIndexOptions(dimensions: 128, strategy: .hnswInline)
```

### Advantage 3: Better Extensibility

Future HNSW parameters can be added to the associated value:

```swift
// Future extension (good design)
public enum VectorIndexStrategy: Sendable, Equatable {
    case flatScan
    case hnsw(
        inlineIndexing: Bool,
        m: Int = 16,  // ✅ New parameter - only exists for HNSW
        efConstruction: Int = 100  // ✅ New parameter - only exists for HNSW
    )
}
```

### Advantage 4: Pattern Matching

Implementation code becomes cleaner:

```swift
// ✅ NEW: Clean pattern matching
switch vectorOptions.strategy {
case .flatScan:
    // Use GenericVectorIndexMaintainer
    return createFlatMaintainer()

case .hnsw(let inlineIndexing):
    // Use GenericHNSWIndexMaintainer
    // Access inlineIndexing flag directly
    return createHNSWMaintainer(inlineIndexing: inlineIndexing)
}

// ❌ OLD: Nested if-let checks
if let vectorOptions = index.options.vectorOptions {
    if vectorOptions.allowHNSWSearch {
        if vectorOptions.allowInlineIndexing {
            // HNSW inline
        } else {
            // HNSW batch
        }
    } else {
        // Flat scan (allowInlineIndexing is ignored)
    }
}
```

---

## API Changes

### Breaking Changes

#### 1. VectorIndexOptions Initializer

**Before**:
```swift
let options = VectorIndexOptions(
    dimensions: 768,
    metric: .cosine,
    allowHNSWSearch: true,
    allowInlineIndexing: false
)
```

**After**:
```swift
let options = VectorIndexOptions(
    dimensions: 768,
    metric: .cosine,
    strategy: .hnsw(inlineIndexing: false)
    // Or use convenience property
    // strategy: .hnswBatch
)
```

#### 2. Conditional Logic in Implementation

**Before**:
```swift
if let vectorOptions = index.options.vectorOptions,
   vectorOptions.allowHNSWSearch {
    // HNSW path
    if vectorOptions.allowInlineIndexing {
        // Inline
    } else {
        // Batch
    }
} else {
    // Flat scan
}
```

**After**:
```swift
guard let vectorOptions = index.options.vectorOptions else {
    throw RecordLayerError.internalError("Vector index options not found")
}

switch vectorOptions.strategy {
case .flatScan:
    // Flat scan path

case .hnsw(let inlineIndexing):
    // HNSW path
    if inlineIndexing {
        // Inline
    } else {
        // Batch
    }
}
```

### Non-Breaking Additions

#### 1. Convenience Properties

```swift
// These are static properties, not breaking changes
VectorIndexStrategy.hnswBatch  // = .hnsw(inlineIndexing: false)
VectorIndexStrategy.hnswInline  // = .hnsw(inlineIndexing: true)
```

#### 2. Equatable Conformance

```swift
// Automatic synthesis
let strategy1 = VectorIndexStrategy.flatScan
let strategy2 = VectorIndexStrategy.flatScan
assert(strategy1 == strategy2)  // true

let strategy3 = VectorIndexStrategy.hnsw(inlineIndexing: false)
let strategy4 = VectorIndexStrategy.hnsw(inlineIndexing: false)
assert(strategy3 == strategy4)  // true
```

---

## Migration Guide

### Step 1: Update VectorIndexOptions Creation

**Development/Small Datasets** (keep flat scan):

```swift
// Before
let devOptions = VectorIndexOptions(
    dimensions: 384,
    metric: .cosine,
    allowHNSWSearch: false,  // ← Remove
    allowInlineIndexing: false  // ← Remove
)

// After
let devOptions = VectorIndexOptions(
    dimensions: 384,
    metric: .cosine,
    strategy: .flatScan  // ✅ Explicit, clear intent
)
```

**Production/Large Datasets** (use HNSW with batch updates):

```swift
// Before
let prodOptions = VectorIndexOptions(
    dimensions: 768,
    metric: .cosine,
    allowHNSWSearch: true,  // ← Remove
    allowInlineIndexing: false  // ← Remove
)

// After
let prodOptions = VectorIndexOptions(
    dimensions: 768,
    metric: .cosine,
    strategy: .hnsw(inlineIndexing: false)
    // Or use convenience property
    // strategy: .hnswBatch
)
```

**Tiny Graphs** (risky inline updates):

```swift
// Before
let tinyOptions = VectorIndexOptions(
    dimensions: 128,
    metric: .cosine,
    allowHNSWSearch: true,  // ← Remove
    allowInlineIndexing: true  // ← Remove
)

// After
let tinyOptions = VectorIndexOptions(
    dimensions: 128,
    metric: .cosine,
    strategy: .hnsw(inlineIndexing: true)
    // Or use convenience property
    // strategy: .hnswInline  // ⚠️ Warning in docs
)
```

### Step 2: Update Conditional Logic

**IndexManager.swift** (lines 318-337):

```swift
// Before
if let vectorOptions = index.options.vectorOptions,
   vectorOptions.allowHNSWSearch {
    let maintainer = try GenericHNSWIndexMaintainer<T>(...)
    return AnyGenericIndexMaintainer(maintainer)
} else {
    let maintainer = try GenericVectorIndexMaintainer<T>(...)
    return AnyGenericIndexMaintainer(maintainer)
}

// After
guard let vectorOptions = index.options.vectorOptions else {
    throw RecordLayerError.internalError("Vector options not found")
}

switch vectorOptions.strategy {
case .flatScan:
    let maintainer = try GenericVectorIndexMaintainer<T>(...)
    return AnyGenericIndexMaintainer(maintainer)

case .hnsw:
    let maintainer = try GenericHNSWIndexMaintainer<T>(...)
    return AnyGenericIndexMaintainer(maintainer)
}
```

**OnlineIndexer.swift** (lines 102-109):

```swift
// Before
if case .vector = index.type,
   let vectorOptions = index.options.vectorOptions,
   vectorOptions.allowHNSWSearch {
    try await buildHNSWIndex(clearFirst: clearFirst)
    return
}

// After
if case .vector = index.type,
   let vectorOptions = index.options.vectorOptions,
   case .hnsw = vectorOptions.strategy {
    try await buildHNSWIndex(clearFirst: clearFirst)
    return
}
```

**GenericHNSWIndexMaintainer.swift** (updateIndex method):

```swift
// Before
if vectorOptions.allowInlineIndexing {
    try await insert(vector: vector, primaryKey: primaryKey, transaction: transaction)
} else {
    transaction.setValue(vectorBytes, for: vectorKey)
}

// After
guard case let .hnsw(inlineIndexing) = vectorOptions.strategy else {
    fatalError("Invalid strategy for HNSW maintainer")
}

if inlineIndexing {
    try await insert(vector: vector, primaryKey: primaryKey, transaction: transaction)
} else {
    transaction.setValue(vectorBytes, for: vectorKey)
}
```

### Step 3: Update Tests

**Example test update**:

```swift
// Before
let options = VectorIndexOptions(
    dimensions: 128,
    metric: .cosine,
    allowHNSWSearch: true,
    allowInlineIndexing: false
)

// After
let options = VectorIndexOptions(
    dimensions: 128,
    metric: .cosine,
    strategy: .hnswBatch  // Convenience property
)
```

---

## Implementation Impact

### Files to Modify

#### Core Definition
1. **`Sources/FDBRecordCore/IndexDefinition.swift`**
   - Add `VectorIndexStrategy` enum (lines ~50-100)
   - Update `VectorIndexOptions` struct (lines ~24-72)
   - **Estimated changes**: ~100 lines

#### Index Management
2. **`Sources/FDBRecordLayer/Index/IndexManager.swift`**
   - Update `createMaintainer()` method (lines 318-337)
   - **Estimated changes**: ~20 lines

3. **`Sources/FDBRecordLayer/Index/OnlineIndexer.swift`**
   - Update `buildIndex()` method (lines 102-109)
   - Update `createMaintainer()` method (lines 413-442)
   - **Estimated changes**: ~30 lines

4. **`Sources/FDBRecordLayer/Index/HNSWIndex.swift`**
   - Update `GenericHNSWIndexMaintainer.updateIndex()` method
   - **Estimated changes**: ~10 lines

#### Query Execution
5. **`Sources/FDBRecordLayer/Query/TypedVectorQuery.swift`**
   - Update `TypedVectorSearchPlan.execute()` method (lines 161-191)
   - **Estimated changes**: ~30 lines

#### Tests
6. **`Tests/FDBRecordLayerTests/Index/HNSWIndexTests.swift`**
   - Update all `VectorIndexOptions` creation
   - **Estimated changes**: ~50 lines

7. **`Tests/FDBRecordLayerTests/Index/VectorIndexTests.swift`**
   - Update all `VectorIndexOptions` creation
   - **Estimated changes**: ~30 lines

8. **Other test files using VectorIndexOptions**
   - Various integration tests
   - **Estimated changes**: ~20 lines

### Total Estimated Impact

| Category | Files | Lines Changed |
|----------|-------|---------------|
| Core Definition | 1 | ~100 |
| Index Management | 3 | ~60 |
| Query Execution | 1 | ~30 |
| Tests | 5+ | ~100 |
| **Total** | **10+** | **~290** |

---

## Testing Strategy

### Unit Tests

#### 1. Enum Equality Tests

```swift
func testVectorIndexStrategyEquality() {
    XCTAssertEqual(VectorIndexStrategy.flatScan, .flatScan)
    XCTAssertEqual(VectorIndexStrategy.hnsw(inlineIndexing: false), .hnswBatch)
    XCTAssertEqual(VectorIndexStrategy.hnsw(inlineIndexing: true), .hnswInline)

    XCTAssertNotEqual(VectorIndexStrategy.flatScan, .hnswBatch)
    XCTAssertNotEqual(
        VectorIndexStrategy.hnsw(inlineIndexing: false),
        .hnsw(inlineIndexing: true)
    )
}
```

#### 2. Pattern Matching Tests

```swift
func testVectorIndexStrategyPatternMatching() {
    let flatStrategy = VectorIndexStrategy.flatScan
    switch flatStrategy {
    case .flatScan:
        XCTAssertTrue(true)
    case .hnsw:
        XCTFail("Should not match .hnsw")
    }

    let hnswStrategy = VectorIndexStrategy.hnsw(inlineIndexing: false)
    switch hnswStrategy {
    case .flatScan:
        XCTFail("Should not match .flatScan")
    case .hnsw(let inlineIndexing):
        XCTAssertFalse(inlineIndexing)
    }
}
```

#### 3. Convenience Property Tests

```swift
func testConvenienceProperties() {
    XCTAssertEqual(VectorIndexStrategy.hnswBatch, .hnsw(inlineIndexing: false))
    XCTAssertEqual(VectorIndexStrategy.hnswInline, .hnsw(inlineIndexing: true))
}
```

### Integration Tests

#### 1. IndexManager Selection

```swift
func testIndexManagerSelectsMaintainer() async throws {
    // Flat scan
    let flatOptions = VectorIndexOptions(dimensions: 128, strategy: .flatScan)
    let flatIndex = Index(name: "flat", type: .vector(flatOptions), ...)
    let flatMaintainer = try indexManager.createMaintainer(for: flatIndex, ...)
    XCTAssertTrue(flatMaintainer is GenericVectorIndexMaintainer<Product>)

    // HNSW
    let hnswOptions = VectorIndexOptions(dimensions: 128, strategy: .hnswBatch)
    let hnswIndex = Index(name: "hnsw", type: .vector(hnswOptions), ...)
    let hnswMaintainer = try indexManager.createMaintainer(for: hnswIndex, ...)
    XCTAssertTrue(hnswMaintainer is GenericHNSWIndexMaintainer<Product>)
}
```

#### 2. OnlineIndexer Delegation

```swift
func testOnlineIndexerDelegatesToBuildHNSW() async throws {
    let hnswOptions = VectorIndexOptions(dimensions: 128, strategy: .hnswBatch)
    let hnswIndex = Index(name: "hnsw", type: .vector(hnswOptions), ...)
    let indexer = OnlineIndexer(database: database, index: hnswIndex, ...)

    // Should delegate to buildHNSWIndex()
    try await indexer.buildIndex()

    // Verify graph was built (check maxLevel, etc.)
    // ...
}
```

#### 3. Inline Indexing Behavior

```swift
func testHNSWInlineIndexingBehavior() async throws {
    let inlineOptions = VectorIndexOptions(
        dimensions: 128,
        strategy: .hnsw(inlineIndexing: true)
    )
    let inlineIndex = Index(name: "inline", type: .vector(inlineOptions), ...)

    // Should update graph during save
    // (Test with tiny graph to avoid timeout)
    // ...

    let batchOptions = VectorIndexOptions(
        dimensions: 128,
        strategy: .hnsw(inlineIndexing: false)
    )
    let batchIndex = Index(name: "batch", type: .vector(batchOptions), ...)

    // Should only store vector during save
    // Graph must be built separately
    // ...
}
```

### Regression Tests

Ensure all existing tests pass after migration:

```bash
swift test --filter VectorIndex
swift test --filter HNSW
swift test --filter TypedVectorQuery
```

---

## Appendix: Comparison Table

| Aspect | Old Design (2 Booleans) | New Design (Enum) |
|--------|------------------------|-------------------|
| **Type Safety** | ❌ Invalid combinations allowed | ✅ Invalid combinations impossible |
| **Clarity** | ❌ `allowInlineIndexing` meaningless for flat scan | ✅ `inlineIndexing` only exists for HNSW |
| **Extensibility** | ❌ New HNSW params pollute top-level struct | ✅ New HNSW params nested in enum case |
| **Pattern Matching** | ❌ Nested if-let checks | ✅ Clean switch statements |
| **Default Safety** | ✅ Both false by default | ✅ `.flatScan` by default |
| **Documentation** | ❌ Must explain when flags are ignored | ✅ Self-documenting enum cases |
| **Migration Cost** | N/A | ~290 lines across 10+ files |

---

## Conclusion

The proposed enum-based design provides:

1. **Type Safety**: Eliminates invalid configurations
2. **Clarity**: Clear intent for each strategy
3. **Extensibility**: Easy to add HNSW-specific parameters
4. **Maintainability**: Cleaner implementation code

**Recommendation**: Proceed with implementation after approval.

---

**Next Steps**:
1. Review and approve this design document
2. Create implementation TODO list
3. Update `Sources/FDBRecordCore/IndexDefinition.swift`
4. Update all affected files (IndexManager, OnlineIndexer, etc.)
5. Update tests
6. Update CLAUDE.md documentation
