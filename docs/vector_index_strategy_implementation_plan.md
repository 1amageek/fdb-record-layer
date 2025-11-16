# Vector Index Strategy Implementation Plan

**Document Version**: 1.0
**Date**: 2025-01-16
**Status**: 🔄 Implementation Plan
**Reference**: [Design Document](./vector_index_strategy_design.md)

---

## Overview

This document provides a detailed implementation plan for migrating from two Boolean flags (`allowHNSWSearch`, `allowInlineIndexing`) to an enum-based strategy pattern (`VectorIndexStrategy`).

**Total Estimated Changes**: ~290 lines across 10+ files
**Estimated Implementation Time**: 4-6 hours
**Risk Level**: Medium (Breaking API changes)

---

## Implementation Phases

### Phase 1: Core Definition (FDBRecordCore)

**Goal**: Add `VectorIndexStrategy` enum and update `VectorIndexOptions`

**Files to Modify**: 1 file
**Estimated Changes**: ~100 lines

#### Task 1.1: Add VectorIndexStrategy Enum

**File**: `Sources/FDBRecordCore/IndexDefinition.swift`
**Location**: After line ~20 (before `VectorIndexOptions`)
**Changes**: Add ~80 lines

**Implementation**:

```swift
// Add after VectorMetric enum definition

/// Strategy for vector index implementation
///
/// This enum determines whether to use flat scan (O(n), low memory) or
/// HNSW (O(log n), high memory) for vector similarity search.
///
/// **Design Decision**: Enum with associated value instead of two Boolean flags
/// to prevent invalid configurations (e.g., `allowHNSWSearch = false` with
/// `allowInlineIndexing = true` is meaningless).
public enum VectorIndexStrategy: Sendable, Equatable {
    /// Flat scan: O(n) search, low memory (~1.5 GB for 1M vectors, 384 dims)
    ///
    /// **Characteristics**:
    /// - Always uses inline updates (safe - single `setValue()` operation)
    /// - No graph construction required
    /// - Best for small datasets (<10,000 vectors)
    /// - Memory usage: ~dimensions × 4 bytes × vector count
    ///
    /// **Use Cases**:
    /// - Development/testing environments
    /// - Small production datasets
    /// - Memory-constrained environments
    case flatScan

    /// HNSW: O(log n) search, high memory (~15 GB for 1M vectors, 384 dims)
    ///
    /// **Parameters**:
    /// - `inlineIndexing`: Controls when HNSW graph is updated
    ///
    /// **When `inlineIndexing = false` (RECOMMENDED)**:
    /// - `RecordStore.save()` only stores vector data (single `setValue()`)
    /// - HNSW graph built separately via `OnlineIndexer.buildHNSWIndex()`
    /// - ✅ Safe: No transaction timeout risk
    /// - ✅ Predictable performance
    /// - ✅ Best for production with large datasets
    ///
    /// **When `inlineIndexing = true` (DANGEROUS)**:
    /// - `RecordStore.save()` updates HNSW graph immediately
    /// - Requires ~1,320-12,000 FDB operations per insertion
    /// - ⚠️ Risk: Transaction timeout (5s limit)
    /// - ⚠️ Risk: Transaction size limit (10MB)
    /// - ⚠️ Only use for tiny graphs (<1,000 vectors)
    ///
    /// **Characteristics**:
    /// - Hierarchical graph structure (multi-level)
    /// - Best for large datasets (>100,000 vectors)
    /// - Memory usage: ~10× flat scan (graph edges + vectors)
    case hnsw(inlineIndexing: Bool)

    // MARK: - Convenience Properties

    /// HNSW with batch updates (recommended for production)
    ///
    /// Equivalent to `.hnsw(inlineIndexing: false)`
    ///
    /// This is the **recommended strategy** for production environments with
    /// large vector datasets (>100,000 vectors) and sufficient memory.
    public static var hnswBatch: VectorIndexStrategy {
        .hnsw(inlineIndexing: false)
    }

    /// HNSW with inline updates (dangerous - only for tiny graphs)
    ///
    /// Equivalent to `.hnsw(inlineIndexing: true)`
    ///
    /// ⚠️ **Warning**: Only use for graphs with <1,000 vectors where
    /// transaction timeout risk is acceptable. For larger graphs, use
    /// `.hnswBatch` and build the graph with `OnlineIndexer`.
    public static var hnswInline: VectorIndexStrategy {
        .hnsw(inlineIndexing: true)
    }
}
```

**Verification**:
```bash
# Compile check
swift build --target FDBRecordCore
```

#### Task 1.2: Update VectorIndexOptions Struct

**File**: `Sources/FDBRecordCore/IndexDefinition.swift`
**Location**: Lines 24-72 (current `VectorIndexOptions`)
**Changes**: Replace ~50 lines

**Before**:
```swift
public struct VectorIndexOptions: Sendable {
    public let dimensions: Int
    public let metric: VectorMetric
    public let allowHNSWSearch: Bool  // ← Remove
    public let allowInlineIndexing: Bool  // ← Remove

    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine,
        allowHNSWSearch: Bool = false,
        allowInlineIndexing: Bool = false
    ) {
        self.dimensions = dimensions
        self.metric = metric
        self.allowHNSWSearch = allowHNSWSearch
        self.allowInlineIndexing = allowInlineIndexing
    }
}
```

**After**:
```swift
/// Vector index configuration
///
/// Configures how vector similarity search is performed, including the
/// implementation strategy (flat scan vs HNSW), distance metric, and
/// vector dimensions.
public struct VectorIndexOptions: Sendable {
    /// Number of vector dimensions (required)
    ///
    /// **Valid Range**: 1 to 10,000
    /// **Common Values**:
    /// - 128: Small embeddings (word2vec)
    /// - 384: Sentence transformers (all-MiniLM-L6-v2)
    /// - 768: BERT-base
    /// - 1536: OpenAI text-embedding-ada-002
    public let dimensions: Int

    /// Distance metric for similarity calculation
    ///
    /// **Supported Metrics**:
    /// - `.cosine`: Cosine similarity (default, normalized vectors)
    /// - `.euclidean`: L2 Euclidean distance
    /// - `.dotProduct`: Inner product (not normalized)
    public let metric: VectorMetric

    /// Index implementation strategy
    ///
    /// **Default**: `.flatScan` (safe for all environments)
    ///
    /// **Recommended Strategies by Dataset Size**:
    /// - <10,000 vectors: `.flatScan` (low memory, fast enough)
    /// - 10,000-100,000 vectors: `.flatScan` or `.hnswBatch` (depends on memory)
    /// - >100,000 vectors: `.hnswBatch` (high memory, O(log n) search)
    ///
    /// **Production Recommendation**: `.hnswBatch` for large datasets
    public let strategy: VectorIndexStrategy

    /// Initialize vector index options
    ///
    /// - Parameters:
    ///   - dimensions: Number of vector dimensions (required)
    ///   - metric: Distance metric (default: `.cosine`)
    ///   - strategy: Implementation strategy (default: `.flatScan`)
    ///
    /// **Example** (development environment):
    /// ```swift
    /// let devOptions = VectorIndexOptions(
    ///     dimensions: 384,
    ///     metric: .cosine,
    ///     strategy: .flatScan
    /// )
    /// ```
    ///
    /// **Example** (production environment):
    /// ```swift
    /// let prodOptions = VectorIndexOptions(
    ///     dimensions: 768,
    ///     metric: .cosine,
    ///     strategy: .hnswBatch  // Recommended
    /// )
    /// ```
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

**Verification**:
```bash
# Compile check
swift build --target FDBRecordCore
# Should fail - FDBRecordLayer still uses old API
```

**Expected Errors**:
- `IndexManager.swift`: `allowHNSWSearch` not found
- `OnlineIndexer.swift`: `allowHNSWSearch` not found
- `HNSWIndex.swift`: `allowInlineIndexing` not found
- `TypedVectorQuery.swift`: `allowHNSWSearch` not found

---

### Phase 2: Index Management (FDBRecordLayer)

**Goal**: Update index maintainer creation and online indexing logic

**Files to Modify**: 3 files
**Estimated Changes**: ~60 lines

#### Task 2.1: Update IndexManager.createMaintainer()

**File**: `Sources/FDBRecordLayer/Index/IndexManager.swift`
**Location**: Lines 318-337 (case .vector)
**Changes**: ~20 lines

**Before**:
```swift
case .vector:
    // Check if HNSW is enabled for this index
    if let vectorOptions = index.options.vectorOptions,
       vectorOptions.allowHNSWSearch {
        // Use HNSW for large-scale vector search (O(log n))
        let maintainer = try GenericHNSWIndexMaintainer<T>(
            index: index,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)
    } else {
        // Use flat scan for small-scale vector search (lower memory)
        let maintainer = try GenericVectorIndexMaintainer<T>(
            index: index,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)
    }
```

**After**:
```swift
case .vector:
    guard let vectorOptions = index.options.vectorOptions else {
        throw RecordLayerError.internalError(
            "Vector index '\(index.name)' missing VectorIndexOptions"
        )
    }

    switch vectorOptions.strategy {
    case .flatScan:
        // Use flat scan for small-scale vector search (O(n), low memory)
        let maintainer = try GenericVectorIndexMaintainer<T>(
            index: index,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)

    case .hnsw:
        // Use HNSW for large-scale vector search (O(log n), high memory)
        let maintainer = try GenericHNSWIndexMaintainer<T>(
            index: index,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )
        return AnyGenericIndexMaintainer(maintainer)
    }
```

**Verification**:
```bash
# Compile check
swift build --target FDBRecordLayer
# Should still fail - other files not updated yet
```

#### Task 2.2: Update OnlineIndexer.buildIndex()

**File**: `Sources/FDBRecordLayer/Index/OnlineIndexer.swift`
**Location**: Lines 102-109
**Changes**: ~10 lines

**Before**:
```swift
public func buildIndex(clearFirst: Bool = false) async throws {
    // For HNSW-enabled vector indexes, delegate to buildHNSWIndex()
    if case .vector = index.type,
       let vectorOptions = index.options.vectorOptions,
       vectorOptions.allowHNSWSearch {
        try await buildHNSWIndex(clearFirst: clearFirst)
        return
    }
    // ... rest of method
}
```

**After**:
```swift
public func buildIndex(clearFirst: Bool = false) async throws {
    // For HNSW vector indexes, delegate to buildHNSWIndex()
    if case .vector = index.type,
       let vectorOptions = index.options.vectorOptions,
       case .hnsw = vectorOptions.strategy {
        try await buildHNSWIndex(clearFirst: clearFirst)
        return
    }
    // ... rest of method (unchanged)
}
```

**Verification**:
```bash
# Compile check - should progress
swift build --target FDBRecordLayer
```

#### Task 2.3: Update OnlineIndexer.createMaintainer()

**File**: `Sources/FDBRecordLayer/Index/OnlineIndexer.swift`
**Location**: Lines 413-442 (case .vector)
**Changes**: ~30 lines

**Before**:
```swift
case .vector:
    // Check if HNSW is enabled for this index
    if let vectorOptions = index.options.vectorOptions,
       vectorOptions.allowHNSWSearch {
        // Use HNSW for large-scale vector search
        do {
            let maintainer = try GenericHNSWIndexMaintainer<Record>(...)
            return AnyGenericIndexMaintainer(maintainer)
        } catch {
            logger.error("Failed to create HNSW index maintainer: \(error)")
            throw RecordLayerError.internalError("Invalid HNSW config: \(error)")
        }
    } else {
        // Use flat scan for small-scale vector search (lower memory)
        do {
            let maintainer = try GenericVectorIndexMaintainer<Record>(...)
            return AnyGenericIndexMaintainer(maintainer)
        } catch {
            logger.error("Failed to create flat vector index maintainer: \(error)")
            throw RecordLayerError.internalError("Invalid vector config: \(error)")
        }
    }
```

**After**:
```swift
case .vector:
    guard let vectorOptions = index.options.vectorOptions else {
        throw RecordLayerError.internalError(
            "Vector index '\(index.name)' missing VectorIndexOptions"
        )
    }

    switch vectorOptions.strategy {
    case .flatScan:
        // Use flat scan for small-scale vector search (O(n), low memory)
        do {
            let maintainer = try GenericVectorIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)
        } catch {
            logger.error("Failed to create flat vector index maintainer for '\(index.name)': \(error)")
            throw RecordLayerError.internalError(
                "Invalid flat vector index configuration for '\(index.name)': \(error)"
            )
        }

    case .hnsw:
        // Use HNSW for large-scale vector search (O(log n), high memory)
        do {
            let maintainer = try GenericHNSWIndexMaintainer<Record>(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
            return AnyGenericIndexMaintainer(maintainer)
        } catch {
            logger.error("Failed to create HNSW index maintainer for '\(index.name)': \(error)")
            throw RecordLayerError.internalError(
                "Invalid HNSW index configuration for '\(index.name)': \(error)"
            )
        }
    }
```

**Verification**:
```bash
swift build --target FDBRecordLayer
```

#### Task 2.4: Update GenericHNSWIndexMaintainer.updateIndex()

**File**: `Sources/FDBRecordLayer/Index/HNSWIndex.swift`
**Location**: Search for `allowInlineIndexing` usage in `updateIndex()` method
**Changes**: ~10 lines

**Before** (approximate - need to find actual implementation):
```swift
public func updateIndex(...) async throws {
    guard let vectorOptions = index.options.vectorOptions else {
        throw RecordLayerError.internalError("Vector index options not found")
    }

    if vectorOptions.allowInlineIndexing {
        // Inline graph update (dangerous)
        try await insert(vector: vector, primaryKey: primaryKey, transaction: transaction)
    } else {
        // Only store vector (recommended)
        transaction.setValue(vectorBytes, for: vectorKey)
    }
}
```

**After**:
```swift
public func updateIndex(...) async throws {
    guard let vectorOptions = index.options.vectorOptions else {
        throw RecordLayerError.internalError("Vector index options not found")
    }

    guard case let .hnsw(inlineIndexing) = vectorOptions.strategy else {
        fatalError("GenericHNSWIndexMaintainer used with non-HNSW strategy")
    }

    if inlineIndexing {
        // ⚠️ Inline graph update (dangerous - only for tiny graphs)
        try await insert(vector: vector, primaryKey: primaryKey, transaction: transaction)
    } else {
        // ✅ Only store vector (recommended - graph built via OnlineIndexer)
        transaction.setValue(vectorBytes, for: vectorKey)
    }
}
```

**Verification**:
```bash
swift build --target FDBRecordLayer
# Should compile successfully now
```

---

### Phase 3: Query Execution (FDBRecordLayer)

**Goal**: Update vector query execution logic

**Files to Modify**: 1 file
**Estimated Changes**: ~30 lines

#### Task 3.1: Update TypedVectorQuery.execute()

**File**: `Sources/FDBRecordLayer/Query/TypedVectorQuery.swift`
**Location**: Lines 161-191
**Changes**: ~30 lines

**Before**:
```swift
// ✅ FIX: Select maintainer based on allowHNSWSearch flag
let searchResults: [(primaryKey: Tuple, distance: Double)]

// Check if HNSW is enabled for this vector index
if case .vector = index.type,
   let vectorOptions = index.options.vectorOptions,
   vectorOptions.allowHNSWSearch {
    // Use HNSW for O(log n) search (large-scale datasets)
    let hnswMaintainer = try GenericHNSWIndexMaintainer<Record>(...)
    searchResults = try await hnswMaintainer.search(...)
} else {
    // Use flat scan for O(n) search (small-scale datasets, lower memory)
    let flatMaintainer = try GenericVectorIndexMaintainer<Record>(...)
    searchResults = try await flatMaintainer.search(...)
}
```

**After**:
```swift
// Select maintainer based on strategy
let searchResults: [(primaryKey: Tuple, distance: Double)]

guard let vectorOptions = index.options.vectorOptions else {
    throw RecordLayerError.internalError(
        "Vector index '\(index.name)' missing VectorIndexOptions"
    )
}

switch vectorOptions.strategy {
case .flatScan:
    // Use flat scan for O(n) search (small-scale datasets, low memory)
    let flatMaintainer = try GenericVectorIndexMaintainer<Record>(
        index: index,
        subspace: indexNameSubspace,
        recordSubspace: recordSubspace
    )
    searchResults = try await flatMaintainer.search(
        queryVector: queryVector,
        k: fetchK,
        transaction: transaction
    )

case .hnsw:
    // Use HNSW for O(log n) search (large-scale datasets, high memory)
    let hnswMaintainer = try GenericHNSWIndexMaintainer<Record>(
        index: index,
        subspace: indexNameSubspace,
        recordSubspace: recordSubspace
    )
    searchResults = try await hnswMaintainer.search(
        queryVector: queryVector,
        k: fetchK,
        transaction: transaction
    )
}
```

**Verification**:
```bash
swift build --target FDBRecordLayer
# Should compile successfully
```

---

### Phase 4: Tests

**Goal**: Add new tests and update existing tests

**Files to Modify**: 3+ files
**Estimated Changes**: ~100 lines

#### Task 4.1: Create VectorIndexStrategyTests.swift

**File**: `Tests/FDBRecordLayerTests/Index/VectorIndexStrategyTests.swift` (NEW)
**Changes**: ~50 lines

**Implementation**:
```swift
import Testing
import FDBRecordCore

@Suite("VectorIndexStrategy Tests")
struct VectorIndexStrategyTests {

    @Test("Enum equality")
    func testEnumEquality() {
        // flatScan
        #expect(VectorIndexStrategy.flatScan == .flatScan)

        // hnsw with same parameter
        #expect(VectorIndexStrategy.hnsw(inlineIndexing: false) == .hnsw(inlineIndexing: false))
        #expect(VectorIndexStrategy.hnsw(inlineIndexing: true) == .hnsw(inlineIndexing: true))

        // Different strategies
        #expect(VectorIndexStrategy.flatScan != .hnsw(inlineIndexing: false))
        #expect(VectorIndexStrategy.hnsw(inlineIndexing: false) != .hnsw(inlineIndexing: true))
    }

    @Test("Convenience properties")
    func testConvenienceProperties() {
        // hnswBatch
        #expect(VectorIndexStrategy.hnswBatch == .hnsw(inlineIndexing: false))

        // hnswInline
        #expect(VectorIndexStrategy.hnswInline == .hnsw(inlineIndexing: true))

        // Not equal
        #expect(VectorIndexStrategy.hnswBatch != .hnswInline)
    }

    @Test("Pattern matching - flatScan")
    func testPatternMatchingFlatScan() {
        let strategy = VectorIndexStrategy.flatScan

        switch strategy {
        case .flatScan:
            // Expected path
            #expect(true)
        case .hnsw:
            Issue.record("Should not match .hnsw")
        }
    }

    @Test("Pattern matching - hnsw with value extraction")
    func testPatternMatchingHNSW() {
        let batchStrategy = VectorIndexStrategy.hnsw(inlineIndexing: false)
        let inlineStrategy = VectorIndexStrategy.hnsw(inlineIndexing: true)

        // Extract inlineIndexing value
        if case let .hnsw(inlineIndexing) = batchStrategy {
            #expect(inlineIndexing == false)
        } else {
            Issue.record("Should match .hnsw")
        }

        if case let .hnsw(inlineIndexing) = inlineStrategy {
            #expect(inlineIndexing == true)
        } else {
            Issue.record("Should match .hnsw")
        }
    }

    @Test("VectorIndexOptions initialization")
    func testVectorIndexOptionsInitialization() {
        // Default strategy (flatScan)
        let defaultOptions = VectorIndexOptions(dimensions: 384)
        #expect(defaultOptions.strategy == .flatScan)
        #expect(defaultOptions.metric == .cosine)

        // Explicit flatScan
        let flatOptions = VectorIndexOptions(
            dimensions: 384,
            metric: .euclidean,
            strategy: .flatScan
        )
        #expect(flatOptions.strategy == .flatScan)
        #expect(flatOptions.metric == .euclidean)

        // HNSW batch
        let hnswBatchOptions = VectorIndexOptions(
            dimensions: 768,
            strategy: .hnswBatch
        )
        #expect(hnswBatchOptions.strategy == .hnsw(inlineIndexing: false))

        // HNSW inline
        let hnswInlineOptions = VectorIndexOptions(
            dimensions: 128,
            strategy: .hnsw(inlineIndexing: true)
        )
        #expect(hnswInlineOptions.strategy == .hnswInline)
    }
}
```

**Verification**:
```bash
swift test --filter VectorIndexStrategyTests
```

#### Task 4.2: Update HNSWIndexTests.swift

**File**: `Tests/FDBRecordLayerTests/Index/HNSWIndexTests.swift`
**Changes**: ~30 lines

**Strategy**: Find all `VectorIndexOptions` creation and replace:

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
    strategy: .hnswBatch
)
```

**Verification**:
```bash
swift test --filter HNSWIndexTests
```

#### Task 4.3: Update VectorIndexTests.swift

**File**: `Tests/FDBRecordLayerTests/Index/VectorIndexTests.swift`
**Changes**: ~20 lines

**Strategy**: Replace all `VectorIndexOptions` creation (similar to Task 4.2)

**Verification**:
```bash
swift test --filter VectorIndexTests
```

#### Task 4.4: Run Regression Tests

**Goal**: Ensure all existing tests pass

**Command**:
```bash
# Run all vector-related tests
swift test --filter Vector
swift test --filter HNSW
swift test --filter TypedVectorQuery

# Run full test suite
swift test
```

**Expected Result**: All tests pass

**If Tests Fail**:
1. Check error messages for remaining `allowHNSWSearch` or `allowInlineIndexing` usage
2. Search codebase: `grep -r "allowHNSWSearch" Sources/ Tests/`
3. Search codebase: `grep -r "allowInlineIndexing" Sources/ Tests/`
4. Fix remaining occurrences

---

### Phase 5: Documentation

**Goal**: Update project documentation

**Files to Modify**: 1 file
**Estimated Changes**: ~50 lines

#### Task 5.1: Update CLAUDE.md

**File**: `CLAUDE.md`
**Location**: Search for "VectorIndexOptions" or "allowHNSWSearch"
**Changes**: ~50 lines

**Add New Section**:
```markdown
### VectorIndexStrategy (Vector Search Configuration)

**Purpose**: Configure vector similarity search implementation strategy

**Design**: Enum with associated value (type-safe, prevents invalid configurations)

**Strategies**:

| Strategy | Complexity | Memory | Use Case |
|----------|-----------|--------|----------|
| `.flatScan` | O(n) | Low (~1.5 GB for 1M vectors) | <10,000 vectors, development |
| `.hnsw(inlineIndexing: false)` | O(log n) | High (~15 GB for 1M vectors) | >100,000 vectors, production |
| `.hnsw(inlineIndexing: true)` | O(log n) | High | Tiny graphs (<1,000 vectors), risky |

**Examples**:

```swift
// Development environment (small datasets)
let devOptions = VectorIndexOptions(
    dimensions: 384,
    metric: .cosine,
    strategy: .flatScan  // Default, safe
)

// Production environment (large datasets)
let prodOptions = VectorIndexOptions(
    dimensions: 768,
    metric: .cosine,
    strategy: .hnswBatch  // Recommended for production
)

// Tiny graphs (risky inline updates)
let tinyOptions = VectorIndexOptions(
    dimensions: 128,
    metric: .cosine,
    strategy: .hnswInline  // ⚠️ Only for <1,000 vectors
)
```

**DB Initialization Pattern**:

```swift
// Override strategy based on environment
let schema = Schema([Product.self])

let indexes = schema.indexes.map { index in
    guard case .vector(let options) = index.type else { return index }

    // Production: Use HNSW batch
    let productionOptions = VectorIndexOptions(
        dimensions: options.dimensions,
        metric: options.metric,
        strategy: .hnswBatch  // Override
    )

    return Index(
        name: index.name,
        type: .vector(productionOptions),
        rootExpression: index.rootExpression,
        recordTypes: index.recordTypes
    )
}
```

**Migration from Old API**:

| Old API | New API |
|---------|---------|
| `allowHNSWSearch: false` | `strategy: .flatScan` |
| `allowHNSWSearch: true, allowInlineIndexing: false` | `strategy: .hnswBatch` |
| `allowHNSWSearch: true, allowInlineIndexing: true` | `strategy: .hnswInline` |
```

**Verification**: Review CLAUDE.md for clarity and completeness

---

## Risk Mitigation

### Breaking Changes

**Impact**: All existing code using `VectorIndexOptions` will break

**Mitigation**:
1. **Clear compiler errors**: Old API fields removed, compiler will report all usage
2. **Simple migration**: 1:1 mapping from old API to new API
3. **Documentation**: Migration guide in design document

### Testing Strategy

**Approach**: Incremental verification

1. **After Phase 1**: Compile FDBRecordCore (expect failures in FDBRecordLayer)
2. **After Phase 2**: Compile FDBRecordLayer (should succeed)
3. **After Phase 3**: Run quick smoke tests
4. **After Phase 4**: Full regression test suite

### Rollback Plan

**If Critical Issues Found**:

1. **Option 1**: Revert all changes
   ```bash
   git reset --hard HEAD~1  # If single commit
   git revert <commit-hash>  # If already pushed
   ```

2. **Option 2**: Temporary compatibility shim (not recommended)
   ```swift
   // Add deprecated initializer (temporary)
   @available(*, deprecated, message: "Use strategy parameter instead")
   public init(
       dimensions: Int,
       metric: VectorMetric = .cosine,
       allowHNSWSearch: Bool = false,
       allowInlineIndexing: Bool = false
   ) {
       self.dimensions = dimensions
       self.metric = metric
       // Map old API to new API
       if allowHNSWSearch {
           self.strategy = .hnsw(inlineIndexing: allowInlineIndexing)
       } else {
           self.strategy = .flatScan
       }
   }
   ```

---

## Verification Checklist

After implementation, verify:

- [ ] FDBRecordCore compiles without errors
- [ ] FDBRecordLayer compiles without errors
- [ ] VectorIndexStrategyTests pass (6 tests)
- [ ] HNSWIndexTests pass (all existing tests)
- [ ] VectorIndexTests pass (all existing tests)
- [ ] No occurrences of `allowHNSWSearch` in codebase
- [ ] No occurrences of `allowInlineIndexing` in codebase
- [ ] CLAUDE.md updated with new API
- [ ] Design document marked as "Implemented"

---

## Timeline Estimate

| Phase | Tasks | Estimated Time |
|-------|-------|---------------|
| Phase 1 | Core Definition | 1 hour |
| Phase 2 | Index Management | 1.5 hours |
| Phase 3 | Query Execution | 0.5 hours |
| Phase 4 | Tests | 1.5 hours |
| Phase 5 | Documentation | 0.5 hours |
| **Total** | **12 tasks** | **5 hours** |

**Buffer**: +1 hour for unexpected issues

**Total with Buffer**: 6 hours

---

## Next Steps

1. **Review this implementation plan**
2. **Approval**: Get sign-off on approach
3. **Execute**: Proceed phase-by-phase using TodoWrite for tracking
4. **Verify**: Run tests after each phase
5. **Document**: Update CLAUDE.md and mark design doc as implemented
