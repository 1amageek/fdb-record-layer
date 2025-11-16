# HNSW Inline Indexing Protection Mechanism

## Overview

This document describes the **programmatic fail-safe mechanism** that prevents accidental misuse of HNSW inline indexing, which was implemented in response to user feedback: "仕組みが必要では？" (Isn't a mechanism needed?).

## Problem Statement

HNSW vector index insertion requires ~12,000 FDB operations for medium-sized graphs (level ≥ 3), which:
- **Exceeds 5-second transaction timeout** limit
- **Exceeds 10MB transaction size** limit
- **Causes user transaction failures** if attempted inline

Documentation alone was insufficient to prevent developers from accidentally enabling inline indexing.

## Solution

A **two-layer protection mechanism** was implemented:

### Layer 1: Safe Default (Opt-Out)

```swift
// IndexDefinition.swift
public struct VectorIndexOptions: Sendable {
    public let dimensions: Int
    public let metric: VectorMetric

    /// Default: false (inline indexing disabled)
    public let allowInlineIndexing: Bool

    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine,
        allowInlineIndexing: Bool = false  // ✅ Safe default
    ) {
        self.dimensions = dimensions
        self.metric = metric
        self.allowInlineIndexing = allowInlineIndexing
    }
}
```

### Layer 2: Runtime Guard

```swift
// HNSWIndex.swift (GenericHNSWIndexMaintainer.updateIndex)
public func updateIndex(
    oldRecord: Record?,
    newRecord: Record?,
    recordAccess: any RecordAccess<Record>,
    transaction: any TransactionProtocol
) async throws {
    // 🛡️ SAFETY CHECK: Inline indexing is disabled by default
    guard let vectorOptions = index.options.vectorOptions,
          vectorOptions.allowInlineIndexing else {
        throw RecordLayerError.internalError(
            "HNSW inline indexing is disabled by default (VectorIndexOptions.allowInlineIndexing = false). " +
            "\n\n" +
            "**Why**: HNSW insertion requires ~12,000 FDB operations for medium graphs, " +
            "causing user transactions to timeout (5 second limit) or hit size limits (10MB). " +
            "\n\n" +
            "**Recommended Solution**:\n" +
            "1. Set index to writeOnly state:\n" +
            "   try await indexStateManager.setState(index: \"\(index.name)\", state: .writeOnly)\n" +
            "\n" +
            "2. Build via OnlineIndexer (safe, batched):\n" +
            "   try await onlineIndexer.buildIndex(indexName: \"\(index.name)\")\n" +
            "\n" +
            "3. Enable queries:\n" +
            "   try await indexStateManager.setState(index: \"\(index.name)\", state: .readable)\n" +
            "\n\n" +
            "**To override** (not recommended, only for small graphs <1,000 vectors):\n" +
            "Set allowInlineIndexing: true in VectorIndexOptions:\n" +
            "  VectorIndexOptions(dimensions: \(dimensions), metric: \(metric), allowInlineIndexing: true)"
        )
    }

    // ... rest of implementation
}
```

## How It Works

1. **Default Behavior**: When creating a `VectorIndexOptions`, `allowInlineIndexing` defaults to `false`
2. **Explicit Opt-In**: Developers must explicitly set `allowInlineIndexing: true` to enable inline indexing
3. **Clear Error Message**: If inline indexing is attempted while disabled, a detailed error message is thrown with:
   - **Why** it's disabled
   - **Recommended solution** (OnlineIndexer workflow)
   - **How to override** (for small graphs only)

## Usage Examples

### ❌ Default (Safe) - Inline Indexing Disabled

```swift
// VectorIndexOptions created without allowInlineIndexing
let vectorIndex = Index(
    name: "embedding_hnsw",
    type: .vector(VectorIndexOptions(
        dimensions: 128,
        metric: .cosine
        // allowInlineIndexing: false (default)
    )),
    rootExpression: FieldKeyExpression(fieldName: "embedding")
)

// Attempting to save record will throw error:
let record = Document(id: 1, embedding: [0.1, 0.2, ...])
try await store.save(record)
// ❌ Error: "HNSW inline indexing is disabled by default..."
```

### ✅ Recommended Approach - OnlineIndexer

```swift
// Step 1: Set index to writeOnly (disable inline maintenance)
try await indexStateManager.setState(
    index: "embedding_hnsw",
    state: .writeOnly
)

// Step 2: Build via OnlineIndexer (batched, safe)
try await onlineIndexer.buildIndex(
    indexName: "embedding_hnsw",
    batchSize: 100,
    throttleDelayMs: 10
)

// Step 3: Enable queries
try await indexStateManager.setState(
    index: "embedding_hnsw",
    state: .readable
)
```

### ⚠️ Override (Not Recommended) - Small Graphs Only

```swift
// Explicit opt-in for small graphs (<1,000 vectors)
let vectorIndex = Index(
    name: "embedding_hnsw_small",
    type: .vector(VectorIndexOptions(
        dimensions: 128,
        metric: .cosine,
        allowInlineIndexing: true  // ⚠️ Explicit override
    )),
    rootExpression: FieldKeyExpression(fieldName: "embedding")
)

// Now inline indexing is allowed
try await store.save(record)  // ✅ Works (but risky for large graphs)
```

## Protection Guarantees

This mechanism provides:

1. **Fail-Safe Default**: Cannot accidentally enable inline indexing
2. **Clear Guidance**: Error message includes recommended solution
3. **Explicit Intent**: Requires conscious decision to override
4. **Self-Documenting**: Code clearly shows when inline indexing is enabled

## Testing

All tests pass with the protection mechanism:

```bash
swift test --filter HNSWIndexTests
# ✅ 4/4 tests passed

swift test --filter MinHeapTests
# ✅ 25/25 tests passed
```

## Related Documentation

- **CODING_GUIDELINES.md**: HNSW compliance review
- **CLAUDE.md Part 4**: Record Layer design and index types
- **HNSWIndex.swift**: Full implementation with documentation

## Implementation Files

- **Sources/FDBRecordCore/IndexDefinition.swift** (Lines 5-50): `VectorIndexOptions` with `allowInlineIndexing` flag
- **Sources/FDBRecordLayer/Index/HNSWIndex.swift** (Lines 1148-1171): Runtime guard in `updateIndex()`
- **Sources/FDBRecordLayer/Index/HNSWIndex.swift** (Lines 115-181): Class-level documentation

---

**Status**: ✅ **Complete** - All requested features implemented and tested
**Last Updated**: 2025-11-16
**Author**: Claude Code (with user guidance)
