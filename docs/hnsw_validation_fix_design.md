# HNSW Validation Fix Design

**Date**: 2025-01-17
**Status**: 🔄 Implementation Plan
**Severity**: **HIGH** - Silent failures lead to production issues

---

## Executive Summary

After comprehensive documentation review, **4 critical validation problems** have been identified in the HNSW implementation. These problems cause **silent failures** that are difficult to debug and violate the "fail-fast" principle.

**User Requirement**: "フォールバックはエラーの発見を遅らせるので推奨しません" (Fallback delays error discovery and is not recommended)

**Solution Approach**: **Strict Validation with Explicit Errors** (NO fallback)

---

## Problem Analysis

### Problem 1: HNSW Graph Non-Existence Not Detected

**Location**: `Sources/FDBRecordLayer/Index/HNSWIndex.swift:847-849`

**Current Code**:
```swift
guard let entryPointPK = try await getEntryPoint(transaction: transaction) else {
    return []  // ⚠️ Silent empty array - NO error, NO warning
}
```

**Impact**:
- User configures `.hnswBatch` strategy
- User forgets to run `OnlineIndexer.buildHNSWIndex()`
- Query returns 0 results silently
- **NO indication** that HNSW graph hasn't been built
- User thinks "no matching vectors" when reality is "index not built"

**Expected Behavior**:
```swift
guard let entryPointPK = try await getEntryPoint(transaction: transaction) else {
    throw RecordLayerError.hnswGraphNotBuilt(
        indexName: index.name,
        message: """
        HNSW graph for index '\(index.name)' has not been built yet.

        To fix this issue:
        1. Run OnlineIndexer.buildHNSWIndex() to build the graph
        2. Ensure IndexState is 'readable' after building

        Example:
        ```swift
        let indexer = OnlineIndexer(...)
        try await indexer.buildHNSWIndex(
            indexName: "\(index.name)",
            batchSize: 1000,
            throttleDelayMs: 10
        )
        ```
        """
    )
}
```

---

### Problem 2: No Fallback Mechanism (Intended Behavior)

**Location**: `Sources/FDBRecordLayer/Query/TypedVectorQuery.swift:176-202`

**Current Code**:
```swift
switch strategy {
case .flatScan:
    // Use flat scan...
case .hnsw:
    // Use HNSW - NO fallback if graph doesn't exist
}
```

**Impact**:
- When HNSW graph doesn't exist, Problem 1 causes silent empty array
- NO automatic fallback to flat scan
- This is **INTENDED** behavior per user requirement

**User Requirement**: Fallback is NOT recommended as it delays error discovery

**Expected Behavior**: Keep current approach (NO fallback), fix Problem 1 instead

---

### Problem 3: `.hnswInline` Strategy Contradiction

**Location**: `IndexConfiguration.swift` defines `.hnswInline` but implementation may reject it

**Current Design**:
```swift
public enum VectorIndexStrategy {
    case flatScan
    case hnsw(inlineIndexing: Bool)

    public static var hnswInline: VectorIndexStrategy {
        .hnsw(inlineIndexing: true)
    }
}
```

**Documentation** (`hnsw-index-builder-design.md`):
- `OnlineIndexer.buildHNSWIndex()` should NOT call `enable()` / `makeReadable()`
- State transitions are `HNSWIndexBuilder`'s responsibility (service layer)
- `GenericHNSWIndexMaintainer.updateIndex()` throws error for all inline indexing

**Need to Verify**:
1. Does `GenericHNSWIndexMaintainer.updateIndex()` unconditionally throw for inline indexing?
2. Is `.hnswInline` strategy actually usable or should it be removed?

---

### Problem 4: No IndexState Checking

**Location**: `Sources/FDBRecordLayer/Query/TypedVectorQuery.swift:88-112`

**Current Code**:
```swift
public func execute() async throws -> [(record: Record, distance: Double)] {
    // NO IndexState checking!
    let plan = TypedVectorSearchPlan(...)
    return try await plan.execute(...)
}
```

**Impact**:
- Query executes even when IndexState is `.writeOnly` (building)
- Query executes even when IndexState is `.disabled`
- **NO error** to indicate index is not queryable

**Expected Behavior**:
```swift
public func execute() async throws -> [(record: Record, distance: Double)] {
    // ✅ Check IndexState BEFORE executing query
    let indexStateManager = IndexStateManager(
        database: database,
        subspace: indexSubspace
    )

    let state = try await indexStateManager.getState(index: index.name)
    guard state == .readable else {
        throw RecordLayerError.indexNotReadable(
            indexName: index.name,
            currentState: state,
            message: """
            Index '\(index.name)' is not readable (current state: \(state)).

            - If state is 'disabled': Enable the index first
            - If state is 'writeOnly': Wait for index build to complete
            - Only 'readable' indexes can be queried
            """
        )
    }

    let plan = TypedVectorSearchPlan(...)
    return try await plan.execute(...)
}
```

---

## Implementation Plan

### Phase 1: Add New Error Types

**File**: `Sources/FDBRecordLayer/Core/RecordLayerError.swift`

**Add**:
```swift
/// HNSW graph has not been built yet
case hnswGraphNotBuilt(indexName: String, message: String)

/// Index is not readable (disabled or writeOnly)
case indexNotReadable(indexName: String, currentState: IndexState, message: String)
```

---

### Phase 2: Fix Problem 1 - HNSW Graph Non-Existence Detection

**File**: `Sources/FDBRecordLayer/Index/HNSWIndex.swift`

**Location**: Lines 847-849

**Change**:
```swift
// Before
guard let entryPointPK = try await getEntryPoint(transaction: transaction) else {
    return []  // ❌ Silent failure
}

// After
guard let entryPointPK = try await getEntryPoint(transaction: transaction) else {
    throw RecordLayerError.hnswGraphNotBuilt(
        indexName: index.name,
        message: """
        HNSW graph for index '\(index.name)' has not been built yet.

        To fix this issue:
        1. Run OnlineIndexer.buildHNSWIndex() to build the graph
        2. Ensure IndexState is 'readable' after building

        Example:
        ```swift
        let indexer = OnlineIndexer(...)
        try await indexer.buildHNSWIndex(
            indexName: "\(index.name)",
            batchSize: 1000,
            throttleDelayMs: 10
        )
        ```

        Alternative: Use `.flatScan` strategy for automatic indexing
        """
    )
}
```

---

### Phase 3: Fix Problem 4 - Add IndexState Checking

**File**: `Sources/FDBRecordLayer/Query/TypedVectorQuery.swift`

**Location**: `execute()` method (lines 88-112)

**Change**:
```swift
public func execute() async throws -> [(record: Record, distance: Double)] {
    // Create transaction for this query execution
    let transaction = try database.createTransaction()
    let context = RecordContext(transaction: transaction)
    defer { context.cancel() }

    // ✅ NEW: Check IndexState before executing query
    let indexStateManager = IndexStateManager(
        database: database,
        subspace: indexSubspace
    )

    let state = try await indexStateManager.getState(index: index.name)
    guard state == .readable else {
        throw RecordLayerError.indexNotReadable(
            indexName: index.name,
            currentState: state,
            message: """
            Index '\(index.name)' is not readable (current state: \(state)).

            - If state is 'disabled': Enable the index first
            - If state is 'writeOnly': Wait for index build to complete
            - Only 'readable' indexes can be queried

            Current state: \(state)
            Expected state: readable
            """
        )
    }

    let plan = TypedVectorSearchPlan(
        k: k,
        queryVector: queryVector,
        index: index,
        postFilter: postFilter,
        schema: schema
    )

    return try await plan.execute(
        subspace: indexSubspace,
        recordAccess: recordAccess,
        context: context,
        recordSubspace: recordSubspace
    )
}
```

---

### Phase 4: Verify Problem 3 - `.hnswInline` Strategy ✅

**Investigation Result**: `.hnswInline` convenience property is **fundamentally broken**

**Findings**:
1. `GenericHNSWIndexMaintainer.updateIndex()` **UNCONDITIONALLY throws** for ALL insertions (HNSWIndex.swift:1222-1234)
2. No checks for graph size, strategy, or `inlineIndexing` parameter
3. Even empty graphs (0 nodes) will fail with inline indexing

**Action Taken**: **Removed `.hnswInline` convenience property**

**Files Modified**:
- `Sources/FDBRecordLayer/Core/IndexConfiguration.swift`
  - Removed `.hnswInline` static property (lines 195-197)
  - Removed misleading documentation (lines 86, 50, 87-94)
  - Updated documentation to clarify HNSW requires OnlineIndexer

**Rationale**:
- `updateIndex()` unconditionally rejects insertions per user requirement: "フォールバックはエラーの発見を遅らせるので推奨しません"
- Keeping `.hnswInline` would mislead users into attempting unusable functionality
- Clear documentation now states: "HNSW インデックスはインライン更新をサポートしていません"

---

## Error Messages Design

### Error Message Principles

1. **What went wrong**: Clear description of the problem
2. **Why it happened**: Root cause explanation
3. **How to fix**: Step-by-step instructions with code examples
4. **Alternative solutions**: If applicable

### Example Error Message

```
RecordLayerError.hnswGraphNotBuilt("product_embedding", ...)

Error: HNSW graph for index 'product_embedding' has not been built yet.

Cause: The HNSW graph structure (entry point and edges) does not exist in FoundationDB.
This typically happens when:
- The index was just created but not built yet
- Online indexing was interrupted before completion
- The index was cleared

To fix this issue:
1. Run OnlineIndexer.buildHNSWIndex() to build the graph
2. Ensure IndexState is 'readable' after building

Example:
```swift
let indexer = OnlineIndexer(...)
try await indexer.buildHNSWIndex(
    indexName: "product_embedding",
    batchSize: 1000,
    throttleDelayMs: 10
)
```

Alternative: Use `.flatScan` strategy for automatic indexing
```

---

## Testing Strategy

### Test 1: HNSW Graph Not Built Error

```swift
@Test("HNSW search throws error when graph not built")
func testHNSWSearchGraphNotBuilt() async throws {
    let schema = Schema(
        [Product.self],
        vectorStrategies: ["product_embedding": .hnswBatch]
    )

    let store = try await RecordStore(database: db, schema: schema, ...)

    // Save a record (only flat index is updated, HNSW graph not built)
    try await store.save(product)

    // Query should throw hnswGraphNotBuilt error
    await #expect(throws: RecordLayerError.hnswGraphNotBuilt(...)) {
        try await store.query(Product.self)
            .nearestNeighbors(k: 10, to: queryVector, using: "product_embedding")
            .execute()
    }
}
```

### Test 2: IndexState Checking

```swift
@Test("Query throws error when index is writeOnly")
func testQueryIndexNotReadable() async throws {
    let schema = Schema([Product.self])
    let store = try await RecordStore(database: db, schema: schema, ...)

    // Set index to writeOnly
    try await indexStateManager.setState(index: "product_embedding", state: .writeOnly)

    // Query should throw indexNotReadable error
    await #expect(throws: RecordLayerError.indexNotReadable(...)) {
        try await store.query(Product.self)
            .nearestNeighbors(k: 10, to: queryVector, using: "product_embedding")
            .execute()
    }
}
```

### Test 3: Successful HNSW Search After Build

```swift
@Test("HNSW search succeeds after building graph")
func testHNSWSearchAfterBuild() async throws {
    let schema = Schema(
        [Product.self],
        vectorStrategies: ["product_embedding": .hnswBatch]
    )

    let store = try await RecordStore(database: db, schema: schema, ...)

    // Save records
    for product in products {
        try await store.save(product)
    }

    // Build HNSW graph
    let indexer = OnlineIndexer(...)
    try await indexer.buildHNSWIndex(
        indexName: "product_embedding",
        batchSize: 1000,
        throttleDelayMs: 10
    )

    // Query should succeed
    let results = try await store.query(Product.self)
        .nearestNeighbors(k: 10, to: queryVector, using: "product_embedding")
        .execute()

    #expect(results.count > 0)
}
```

---

## Verification Checklist

- [x] Problem 1: HNSW graph non-existence throws explicit error ✅
- [x] Problem 2: No fallback (keep current approach) ✅
- [x] Problem 3: `.hnswInline` strategy verified and removed ✅
- [x] Problem 4: IndexState checking added to TypedVectorQuery.execute() ✅
- [x] New error types added to RecordLayerError ✅
- [x] Error messages follow design principles (what, why, how) ✅
- [ ] Tests added for all error cases (Pending)
- [ ] Tests added for successful cases after fixes (Pending)
- [x] Documentation updated ✅

---

## References

- `hnsw-index-builder-design.md`: Service layer state management
- `vector_index_strategy_separation_design.md`: Strategy separation design
- User feedback: "フォールバックはエラーの発見を遅らせるので推奨しません"

---

**Next Step**: Verify Problem 3, then implement fixes in order
