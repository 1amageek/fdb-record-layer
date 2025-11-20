# Final Design: Range Index Implementation Plan

> **⚠️ DEPRECATED**: This document describes the original hybrid approach (implicit expansion + warning) that was **not implemented**.
>
> **Current Implementation**: See [range-index-explicit-definition.md](./range-index-explicit-definition.md) and [range-index-explicit-migration.md](./range-index-explicit-migration.md)
>
> **Reason for Deprecation**: The project adopted a complete explicit-only approach instead of the hybrid approach described in this document.

- **Status**: ~~Finalized~~ **DEPRECATED**
- **Author**: Gemini
- **Last Updated**: 2025-11-19 (Deprecated: 2025-01-20)
- **Based On**: `docs/range-types.md` (now obsolete)

## 1. Abstract

This document outlines the final, actionable implementation plan for the Range Indexing feature. After a thorough review of the existing detailed design document (`docs/range-types.md`), this plan formally adopts its core design principles while incorporating a critical enhancement to improve developer awareness of performance trade-offs.

The chosen approach is a hybrid: we will implement the **implicit, convenience-oriented index generation** as specified in the original document, but augment it with **explicit compile-time diagnostics** to ensure transparency.

## 2. Core Design (Adopted from `docs/range-types.md`)

We will follow the detailed design laid out in `docs/range-types.md`. The key points of this implementation are:

1.  **Implicit Index Definition**: The developer-facing API remains simple. A single `#Index` macro on a `Range<T>` field is sufficient.
    ```swift
    @Recordable
    struct Event {
        #Index<Event>([\.period]) // User-facing API
        var period: Range<Date>
    }
    ```

2.  **Macro-based Expansion**: The `@Recordable` macro will detect that `\.period` is a `Range` type. It will then automatically generate **two** `IndexDefinition` objects: one for the `lowerBound` and one for the `upperBound`.

3.  **Extended `IndexDefinition`**: The `IndexDefinition` struct will be extended with optional `rangeComponent: RangeComponent?` and `boundaryType: BoundaryType?` fields. This allows the system to differentiate a standard index from a range boundary index.

4.  **`RangeKeyExpression`**: A new `RangeKeyExpression` will be used by the `Schema` to represent a key that accesses a specific boundary of a range field.

5.  **`TypedIntersectionPlan`**: The `TypedRecordQueryPlanner` will recognize an `overlaps` query, identify the two corresponding boundary indexes, and generate a `TypedIntersectionPlan` to efficiently merge-join the results of two parallel index scans.

6.  **Robust `Codable` Support**: All `Range` types will have a custom `Codable` implementation that includes a `"rangeType"` discriminator field in the serialized JSON to ensure type-safe decoding.

## 3. Enhancement: Compile-Time Diagnostics for Transparency (Level 1 Proposal)

While the design in `range-types.md` is technically excellent, it hides the performance cost of creating two indexes from the developer. To remedy this, we will add a compiler diagnostic.

### Implementation

-   The `@Recordable` macro, during its expansion of an `#Index` on a `Range` type, will emit a **compiler warning**.
-   **Warning Message**:
    ```
    @Index on 'period' automatically creates two indexes (on 'lowerBound' and 'upperBound') to optimize 'overlaps' queries. This doubles the write and storage overhead for this field.
    ```
-   **Effect**: This makes the performance trade-off immediately visible to the developer within their IDE, preventing accidental misuse in write-heavy scenarios. It preserves the convenience of the implicit API while eliminating the danger of its opacity.

## 4. Final Implementation Plan

This plan supersedes any previous proposals and directly references the detailed checklist from `docs/range-types.md`, with the addition of the diagnostic step.

1.  **Extend `IndexDefinition.swift`**:
    -   Add `RangeComponent` and `BoundaryType` enums.
    -   Add `rangeComponent: RangeComponent?` and `boundaryType: BoundaryType?` optional properties to `IndexDefinition`.
    -   Ensure the initializer remains backward compatible for non-range indexes.

2.  **Implement `RangeTypeDetector.swift`**:
    -   Create the logic to analyze a type string and determine if it's a `Range`, `ClosedRange`, etc., and what its boundary characteristics are.

3.  **Modify `RecordableMacro.swift`**:
    -   **Locate the `#Index` processing logic.** (Identified in `expandRangeIndexes` and `extractIndexInfo`).
    -   **Implement the implicit expansion**:
        -   In `expandRangeIndexes`, use `RangeTypeDetector` to analyze the field's type.
        -   If it's a range type, **remove the original `IndexInfo`** and **add back one or two new `IndexInfo` objects** with the appropriate `rangeMetadata` populated.
        -   This is the core logic that transforms one logical index into two physical ones.
    -   **Implement the Diagnostic (Warning)**:
        -   At the point of expansion, add a call to `context.diagnose(...)`.
        -   Create a new `RecordableMacroDiagnostic` case for this warning. The message should be informative as specified in Section 3.

4.  **Implement `RangeKeyExpression.swift`**:
    -   Create the `RangeKeyExpression` struct as a new `KeyExpression` type.

5.  **Update `Schema.swift`**:
    -   In the `convertToIndex` (or similar) function, check if `indexDefinition.rangeComponent != nil`.
    -   If it is a range index, create an `Index` object whose `rootExpression` is a `RangeKeyExpression`.
    -   If not, create a `FieldKeyExpression` as before.

6.  **Update `TypedRecordQueryPlanner.swift`**:
    -   Modify the logic that handles `Predicate.Overlaps`.
    -   It should now search the schema for the two indexes whose expressions are `RangeKeyExpression`s corresponding to the `lowerBound` and `upperBound` of the query's target field.
    -   If found, it should generate a `TypedIntersectionPlan` wrapping two `TypedIndexScanPlan`s.

7.  **Update `QueryBuilder.swift`**:
    -   Implement the public-facing `.overlaps()` method. As per the document, this can be overloaded for `Range` and `ClosedRange`.
    -   This method will internally construct a predicate tree that the planner can recognize (e.g., `Predicate.Overlaps(...)`).

8.  **Update Tests (`FDBRecordLayerTests`)**:
    -   Locate existing range index tests. They will now fail.
    -   Update them to reflect the expected behavior. Since the developer-facing API (`#Index([\.period])`) hasn't changed, the tests on the *model definition side* might not need much change.
    -   The main changes will be in tests that inspect the *generated schema* to verify that two `IndexDefinition` objects are now created from a single `#Index` macro.
    -   Add a new test to confirm the compiler warning is generated.

9.  **Update Documentation**:
    -   Update `README.md` and other guides to explicitly mention the automatic dual-index creation for `Range` types and the associated performance trade-offs, pointing developers to the warning for more information.

This finalized plan provides a clear, step-by-step path to implementing a powerful and transparent Range Indexing feature that aligns with the project's existing detailed designs.
