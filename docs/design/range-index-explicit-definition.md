# Explicit Range Index Definition

- **Status**: ✅ Implemented
- **Author**: Gemini
- **Last Updated**: 2025-01-20
- **Related Issues**: Implicit Range Index overhead, Lack of developer control
- **Implementation**: RecordableMacro.swift lines 606-627

## Abstract

This document describes the implemented explicit Range indexing mechanism in the FDB Record Layer. The implicit, "magical" generation of indexes for `Range<T>` types has been **completely removed** and replaced with an explicit, transparent, and more flexible mechanism. Developers are now **required** to define indexes directly on the `lowerBound` and `upperBound` properties of a range field, giving them full control over the physical database schema and its associated performance trade-offs.

**Implementation Date**: January 20, 2025
**Breaking Change**: Yes - Range direct indexing now produces compile-time error

## 1. Motivation & Problem Statement

The current implementation, where applying `#Index` to a `Range<T>` field automatically creates two separate B-Tree indexes, was designed for convenience. However, this convenience comes at a significant cost and introduces several critical issues:

1.  **Hidden Performance Costs**: The creation of two indexes is not apparent to the developer. This doubles the write overhead (on every `save`, `update`, `delete`) and storage consumption compared to a single-field index. In write-heavy applications, this hidden cost can become a major, unexpected performance bottleneck.

2.  **Lack of Developer Control**: The system is all-or-nothing. It is impossible to create an index on only one bound of a range. For applications that only query for records starting after a certain date (`lowerBound`), the automatically created `upperBound` index is pure overhead, consuming resources for no benefit.

3.  **Opacity and Debugging Difficulty**: The abstraction hides the physical reality. When a query is slow, a developer's mental model of "one range index" does not match the underlying implementation of "two intersecting B-Tree scans." This makes performance analysis and tuning non-intuitive and unnecessarily complex.

Given that this is a new project without backward compatibility constraints, we have the opportunity to establish a more robust and transparent foundation from the start.

## 2. Proposed Solution

The core of the proposal is to eliminate the magic and empower the developer with explicit control.

### 2.1. Removal of Implicit Generation

The special-cased logic within the `#Index` macro for `Range<T>` types will be completely removed. The macro will no longer automatically generate two indexes.

### 2.2. Introduction of Explicit, Bound-Based Index Definition

Developers will now define indexes by specifying a `KeyPath` that drills into the `lowerBound` or `upperBound` properties of the range field.

#### Example:

**Old Syntax (to be removed):**
```swift
@Recordable
struct Event {
    #PrimaryKey<Event>([\.id])
    #Index<Event>([\.period]) // Implicitly creates 2 indexes

    var id: UUID
    var period: Range<Date>
}
```

**New, Explicit Syntax:**
```swift
@Recordable
struct Event {
    #PrimaryKey<Event>([\.id])

    // To optimize 'overlaps' queries, define both indexes explicitly.
    #Index<Event>([\.period.lowerBound])
    #Index<Event>([\.period.upperBound])

    var id: UUID
    var period: Range<Date>
}
```

A developer whose application only needs to query based on the start date can choose to create only one index, saving 50% of the write and storage overhead:
```swift
// Optimized for start-date queries ONLY
#Index<Event>([\.period.lowerBound])
```

### 2.3. Compile-Time Diagnostics

To guide developers away from the old syntax, the `#Index` macro will be updated to produce a hard compile-time error if it encounters a `KeyPath` pointing directly to a `Range<T>` type.

-   **Error Message**:
    `@Index cannot be applied directly to a Range type. Define indexes on its bounds explicitly (e.g., '\.period.lowerBound' and '\.period.upperBound').`

This error provides immediate, actionable feedback, enforcing the new, explicit paradigm.

### 2.4. Query Planner Behavior

The `TypedRecordQueryPlanner` will be updated to support this new schema:
- When planning an `.overlaps(with: \.period, ...)` query, it will no longer look for a single logical "range index".
- Instead, it will search the schema for two distinct physical indexes: one on `\.period.lowerBound` and one on `\.period.upperBound`.
- If both are found, it will generate the efficient `TypedIntersectionPlan` as before.
- If only one is found, it will use that single index to partially satisfy the query and then apply the remaining filter condition in memory. This may be less performant than the intersection, but it will still be vastly better than a full table scan.

## 3. Implementation Status

✅ **Completed** - January 20, 2025

The implementation has been completed across all components:

1.  **`FDBRecordLayerMacros`** ✅:
    -   **Modified**: `RecordableMacro.swift` lines 606-627
    -   **Removed**: All implicit Range auto-expansion logic
    -   **Added**: Compile-time diagnostic for direct Range indexing
    -   **Error Message**:
        ```
        Cannot create index directly on Range field 'period'.

        Range fields require explicit boundary indexing.
        Use one or both of the following:
          #Index<Event>([\.period.lowerBound])  // Start index
          #Index<Event>([\.period.upperBound])  // End index
        ```
    -   The macro now validates that Range fields are not directly indexed and emits a clear error with fix instructions.

2.  **`FDBRecordLayer`** ✅:
    -   **Modified**: `TypedRecordQueryPlanner.swift` lines 727-777
    -   **Verified**: Hybrid intersection strategy correctly implemented (hash Range plans + sorted-merge PK plans)
    -   **Modified**: `TypedQueryPlan.swift` lines 264-285, 318-339
    -   **Extended**: RangeWindow support for all Comparable types (Date, Int, Int32, Int64, UInt, UInt32, UInt64, Float, Double, String)
    -   The query planner now correctly handles both explicit boundary indexes and single-boundary indexes.

3.  **`FDBRecordLayerTests`** 🔲:
    -   **Status**: Tests need updating to reflect new explicit syntax
    -   **Required**: Update `RangeIndexEndToEndTests.swift` to use `\.period.lowerBound` / `\.period.upperBound`
    -   **Required**: Add macro diagnostic test to verify compile error for `#Index([\.period])`
    -   **Required**: Add tests for single-boundary index scenarios

4.  **`docs/`** ✅ (This Document):
    -   **Updated**: This document to reflect completed implementation
    -   **Required**: Update `README.md` examples with new syntax
    -   **Required**: Update `CLAUDE.md` Part 4 Range index section
    -   **Required**: Deprecate or archive `range-index-implementation-plan.md` (old hybrid approach)

## 4. Benefits of the New Design

This change, while breaking with the initial design, provides significant long-term benefits:

-   **Full Transparency**: The code is now self-documenting. The physical index structure is clearly and explicitly defined in the model, eliminating ambiguity.
-   **Granular Control**: Developers have the power to make conscious performance trade-offs, creating only the indexes their specific query patterns require.
-   **Reduced Overhead**: For many common use cases (e.g., finding all ranges starting after a certain time), the ability to create a single bound index will halve the write and storage overhead, leading to a more performant and efficient system.
-   **Improved Debuggability**: When performance issues arise, the path from query to index is direct and intuitive, simplifying the tuning and debugging process.
