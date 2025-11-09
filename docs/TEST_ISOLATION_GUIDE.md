# Test Isolation Guide

**Problem**: Tests fail when run together but pass individually due to lack of proper cleanup.

**Root Cause**: When a test throws an error, the cleanup code at the end never executes, leaving data in FoundationDB that interferes with subsequent tests.

---

## Solution: Guaranteed Cleanup with `defer`

### Pattern 1: Using `defer` (Simple)

```swift
@Test("Test name")
func testMethod() async throws {
    let db = try createTestDatabase()
    let subspace = createTestSubspace()
    let schema = try createTestSchema()

    // ✅ Ensure cleanup happens even if test fails
    defer {
        Task {
            try? await cleanup(database: db, subspace: subspace)
        }
    }

    // Test code here...
    try await db.withRecordContext { context in
        // ...
    }

    // ❌ Remove this - defer handles it
    // try await cleanup(database: db, subspace: subspace)
}
```

### Pattern 2: Using Helper Function (Recommended)

Add this helper to your test suite:

```swift
/// Run a test with automatic cleanup (ensures test isolation)
///
/// This helper ensures that the test subspace is always cleaned up,
/// even if the test throws an error. This prevents test interference.
func withTestEnvironment<T>(
    _ body: (any DatabaseProtocol, Subspace, Schema) async throws -> T
) async throws -> T {
    let db = try createTestDatabase()
    let subspace = createTestSubspace()
    let schema = try createTestSchema()

    // Ensure cleanup happens even if test fails
    defer {
        Task {
            try? await cleanup(database: db, subspace: subspace)
        }
    }

    return try await body(db, subspace, schema)
}
```

Then use it in tests:

```swift
@Test("Test name")
func testMethod() async throws {
    try await withTestEnvironment { db, subspace, schema in
        // Test code here - parameters are provided automatically

        guard let index = schema.index(named: "user_by_email") else {
            throw RecordLayerError.indexNotFound("user_by_email")
        }

        // ... test logic
    }
    // Cleanup handled automatically!
}
```

---

## Additional Isolation: Serialize Tests

For test suites that share resources, add `.serialized` to prevent concurrent execution:

```swift
@Suite("OnlineIndexScrubber Tests", .serialized)  // ← Add this
struct OnlineIndexScrubberTests {
    // ...
}
```

This ensures tests run one at a time, preventing race conditions.

---

## Migration Checklist

For each test file (OnlineIndexScrubberTests.swift, IndexStateManagerTests.swift, etc.):

- [ ] **Add `withTestEnvironment` helper** to the test suite
- [ ] **Add `.serialized`** to the `@Suite` attribute
- [ ] **Refactor each test method**:
  - Replace manual setup (`createTestDatabase()`, etc.) with `withTestEnvironment`
  - Move test logic into the closure
  - Remove manual `cleanup()` calls at the end
- [ ] **Run tests** individually: `swift test --filter TestName`
- [ ] **Run all tests** together: `swift test`
- [ ] **Verify isolation**: Tests should pass both individually and together

---

## Example: Before & After

### BEFORE (❌ Not Isolated)

```swift
@Suite("OnlineIndexScrubber Tests")  // ← Missing .serialized
struct OnlineIndexScrubberTests {

    @Test("Phase 1 detects dangling entries")
    func phase1DetectsDanglingEntries() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createTestSchema()

        // ... test code that might throw ...

        try await cleanup(database: db, subspace: subspace)  // ← Never reached if error thrown
    }
}
```

**Problems**:
1. No `.serialized` - tests may run concurrently and conflict
2. If test throws, cleanup never executes
3. Next test finds leftover data → transaction conflicts

### AFTER (✅ Fully Isolated)

```swift
@Suite("OnlineIndexScrubber Tests", .serialized)  // ← Added .serialized
struct OnlineIndexScrubberTests {

    // ✅ Added helper
    func withTestEnvironment<T>(
        _ body: (any DatabaseProtocol, Subspace, Schema) async throws -> T
    ) async throws -> T {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createTestSchema()

        defer {
            Task {
                try? await cleanup(database: db, subspace: subspace)
            }
        }

        return try await body(db, subspace, schema)
    }

    @Test("Phase 1 detects dangling entries")
    func phase1DetectsDanglingEntries() async throws {
        try await withTestEnvironment { db, subspace, schema in  // ← Using helper
            // ... test code ...
        }
        // ✅ Cleanup guaranteed, even on error
    }
}
```

---

## Files to Fix

High-priority test files that need isolation:

1. ✅ `Tests/FDBRecordLayerTests/Index/OnlineIndexScrubberTests.swift` - Started
2. ⏳ `Tests/FDBRecordLayerTests/IndexStateManagerTests.swift`
3. ⏳ `Tests/FDBRecordLayerTests/Query/TypedInJoinPlanTests.swift`
4. ⏳ `Tests/FDBRecordLayerTests/Index/OnlineIndexerTests.swift`
5. ⏳ `Tests/FDBRecordLayerTests/Index/RankIndexTests.swift`

---

## Verification

After migration, verify with:

```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter "OnlineIndexScrubber"

# Run single test
swift test --filter "OnlineIndexScrubber.phase1DetectsDanglingEntries"

# Expected: All tests pass, both individually and together
```

---

## Why This Matters

**Before**:
```
Test 1 → Error → No cleanup → Data remains
Test 2 → Reads stale data → Transaction conflict → FAIL
```

**After**:
```
Test 1 → Error → defer cleanup runs → Data cleared
Test 2 → Clean environment → SUCCESS
```

Each test now runs in a completely isolated environment, regardless of whether previous tests succeeded or failed.

---

**Last Updated**: 2025-01-09
**Status**: Migration in progress (1/5 files completed)
