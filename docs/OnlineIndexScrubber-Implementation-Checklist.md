# OnlineIndexScrubber Implementation Checklist (CORRECTED)

**Date**: 2025-01-15
**Status**: Updated based on code review
**Reference**: [Corrected Architecture](./OnlineIndexScrubber-Architecture-Fix.md)

---

## ⚠️ IMPORTANT: Previous Design Was Incorrect

This checklist has been updated based on a thorough code review. See [Architecture-Fix.md](./OnlineIndexScrubber-Architecture-Fix.md) for details.

---

## Priority 0: Critical Fixes (Must Fix Immediately)

### ✅ Fix 1: Infinite Loop Prevention (CORRECTED)

**Problem**: If first key exceeds maxTransactionBytes, infinite loop occurs

**Root Cause**: Even with `scannedCount > 0` check, the first oversized key gets processed but causes `transaction_too_large` error, leading to infinite retry on the same key.

**Files to Modify**:
- `Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift`

**Changes Required**:

1. **scrubIndexEntries()** (Line 195-243) - Add error handling:
   ```swift
   while let currentKey = continuation {
       let context = try RecordContext(database: database)
       defer { context.cancel() }

       do {
           let (nextContinuation, batchIssues, batchEndKey, scannedCount) = try await scrubIndexEntriesBatch(...)

           // Progress marking
           if let lastKey = batchEndKey {
               let rangeEnd = nextKey(after: lastKey)
               try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
           }

           try await context.commit()

           // ✅ NEW: Record issues AFTER commit (atomicity fix)
           allIssues.append(contentsOf: batchIssues)
           totalScanned += scannedCount

           continuation = nextContinuation

       } catch let error as FDB.Error where error.errno == 2101 {
           // ✅ NEW: transaction_too_large - skip oversized key
           if configuration.enableProgressLogging {
               print("[OnlineIndexScrubber] WARNING: Oversized key at \(currentKey.hexEncodedString()), skipping")
           }

           let skipKey = nextKey(after: currentKey)
           let skipContext = try RecordContext(database: database)
           defer { skipContext.cancel() }

           try await progress.markPhase1Range(from: currentKey, to: skipKey, context: skipContext)
           try await skipContext.commit()

           continuation = skipKey
       }
   }
   ```

2. **scrubIndexEntriesBatch()** (Line 248-365):
   ```swift
   // OLD (Line 278):
   if scannedBytes + keySize > configuration.maxTransactionBytes {

   // NEW: Forward progress guarantee
   if scannedCount > 0 && scannedBytes + keySize > configuration.maxTransactionBytes {
   ```

3. **scrubRecords()** and **scrubRecordsBatch()**: Same pattern

**Why This Works**:
- First key is always processed (scannedCount=0 bypasses limit check)
- If too large, commit throws transaction_too_large
- Error handler skips the key and continues from next
- Forward progress guaranteed

**Tests**:
- [ ] 5MB first key with maxBytes=1MB - no infinite loop
- [ ] Oversized key is logged and skipped
- [ ] Progress is updated correctly
- [ ] Next key is processed normally

**Estimated Time**: 2 hours (with error handling)

---

### ✅ Fix 2: Repair Atomicity (CORRECTED)

**Problem**: Issues recorded before commit, causing incorrect statistics if commit fails

**Current Code** (OnlineIndexScrubber.swift:227-238):
```swift
// ❌ Issues recorded BEFORE commit
allIssues.append(contentsOf: batchIssues)
totalScanned += scannedCount

// Progress marking
if let lastKey = batchEndKey {
    try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
}

try await context.commit()  // If this fails, issues already recorded!
```

**Files to Modify**:
- `Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift`

**Changes Required**:

1. **scrubIndexEntries()** (Line 212-242):
   ```swift
   // OLD (Lines 227-238):
   allIssues.append(contentsOf: batchIssues)
   totalScanned += scannedCount

   if let lastKey = batchEndKey {
       let rangeEnd = nextKey(after: lastKey)
       try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
   }

   try await context.commit()

   // NEW:
   if let lastKey = batchEndKey {
       let rangeEnd = nextKey(after: lastKey)
       try await progress.markPhase1Range(from: currentKey, to: rangeEnd, context: context)
   }

   // ✅ Commit FIRST
   try await context.commit()

   // ✅ Record issues AFTER successful commit
   allIssues.append(contentsOf: batchIssues)
   totalScanned += scannedCount
   ```

2. **scrubRecords()** (Line 368+): Same pattern

**Why This Matters**:
- If commit fails, batchIssues are discarded (not added to allIssues)
- Next batch will re-detect the same issues (from continuation)
- Statistics are always accurate (only committed repairs counted)

**Tests**:
- [ ] Mock commit failure, verify no false positives in result
- [ ] Verify statistics accuracy after retry
- [ ] Verify no lost issues (re-detected on retry)

**Estimated Time**: 1 hour

**Note**: This fix is already included in Fix 1's code example above.

---

## Priority 1: High Priority (Fix Soon)

### ✅ Fix 3A: Implement transactionTimeoutMillis (CORRECTED)

**Problem**: Configuration field defined but not used, causing default 5s timeout

**Issue**: `RecordContext` does not have `setTransactionTimeout()` method

**Files to Modify**:
- `Sources/FDBRecordLayer/Transaction/RecordContext.swift` (add new API)
- `Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift` (use the API)

**Changes Required**:

1. **RecordContext.swift** - Add new API:
   ```swift
   extension RecordContext {
       /// Set transaction timeout
       /// - Parameter milliseconds: Timeout in milliseconds (0 = no timeout)
       /// - Throws: FDB errors if setting fails
       public func setTimeout(milliseconds: Int) throws {
           // Note: Requires investigation of fdb-swift-bindings API
           // Possible approaches:
           // 1. transaction.setOption(.timeout, value: milliseconds)
           // 2. transaction.setTimeout(milliseconds: milliseconds)
           //
           // TODO: Confirm exact API from fdb-swift-bindings
       }
   }
   ```

2. **scrubIndexEntriesBatch()** (Line 248):
   ```swift
   private func scrubIndexEntriesBatch(context: RecordContext, ...) async throws -> (...) {
       // ✅ Set timeout at start
       if configuration.transactionTimeoutMillis > 0 {
           try context.setTimeout(milliseconds: configuration.transactionTimeoutMillis)
       }

       let transaction = context.getTransaction()
       // ... rest of method ...
   }
   ```

3. **scrubRecordsBatch()**: Same addition

**Prerequisites**:
- [ ] Investigate `fdb-swift-bindings` TransactionProtocol API
- [ ] Determine correct method for setting transaction timeout
- [ ] Implement RecordContext.setTimeout()

**Tests**:
- [ ] Long-running scrub (20+ seconds) with 30s timeout
- [ ] Verify no timeout with extended timeout
- [ ] Verify timeout with default 5s on slow operation

**Estimated Time**: 2 hours (including API investigation)

---

### ✅ Fix 3D: Implement Retry Logic

**Problem**: Transient errors (conflicts) abort entire scrubbing operation

**Files to Modify**:
- `Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift`

**Changes Required**:

1. **Add retry helper** (new method around Line 160):
   ```swift
   private func withRetry<T>(
       operation: () async throws -> T
   ) async throws -> T {
       var attempts = 0

       while true {
           do {
               return try await operation()
           } catch let error as FDB.Error where error.isRetryable {
               attempts += 1

               if attempts >= configuration.maxRetries {
                   logProgress("Max retries (\(configuration.maxRetries)) exceeded")
                   throw error
               }

               logProgress("Retryable error: \(error). Attempt \(attempts)/\(configuration.maxRetries)")

               // Exponential backoff
               let delay = configuration.retryDelayMillis * (1 << (attempts - 1))
               try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
           } catch {
               throw error  // Non-retryable error
           }
       }
   }
   ```

2. **Use in scrubPhase1()** (Line 233):
   ```swift
   try await withRetry {
       try await context.commit()
       try await progressContext.commit()
   }
   ```

3. **Use in scrubPhase2()** (Line 368):
   Same pattern

4. **Add FDB.Error extension** (new file or at end):
   ```swift
   extension FDB.Error {
       var isRetryable: Bool {
           switch errno {
           case 1020:  // not_committed
               return true
           case 1007:  // transaction_too_old
               return true
           case 1009:  // future_version
               return true
           default:
               return false
           }
       }
   }
   ```

**Tests**:
- [ ] Simulate transient conflict (mock)
- [ ] Verify retry behavior
- [ ] Verify max retries limit
- [ ] Verify exponential backoff timing

**Estimated Time**: 2 hours

---

## Priority 2: Medium Priority (Nice to Have)

### ✅ Fix 3C: Implement Progress Logging (CORRECTED)

**Problem**: Silent operation, no visibility into long-running scrubs

**Configuration Name**: `enableProgressLogging` (NOT `progressLogging`)

**Files to Modify**:
- `Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift`

**Changes Required**:

1. **Add logging helper** (around Line 160):
   ```swift
   private func logProgress(_ message: String) {
       if configuration.enableProgressLogging {  // ✅ Correct name
           print("[OnlineIndexScrubber] \(Date()) \(message)")
       }
   }
   ```

2. **scrubIndexEntries()** - Add log statements:
   ```swift
   logProgress("Starting Phase 1: Index→Record validation")

   while let currentKey = continuation {
       logProgress("Processing batch from \(currentKey.hexEncodedString())")

       // ... batch processing ...

       logProgress("Batch complete: scanned=\(scannedCount), issues=\(batchIssues.count)")
   }

   logProgress("Phase 1 complete: total scanned=\(totalScanned), total issues=\(allIssues.count)")
   ```

3. **scrubRecords()** - Same pattern for Phase 2

4. **Error handling** - Log warnings:
   ```swift
   } catch let error as FDB.Error where error.errno == 2101 {
       if configuration.enableProgressLogging {  // ✅ Correct name
           print("[OnlineIndexScrubber] WARNING: Oversized key at \(currentKey.hexEncodedString()), skipping")
       }
       // ...
   }
   ```

**Tests**:
- [ ] Run with enableProgressLogging=true, verify output
- [ ] Verify no output with enableProgressLogging=false

**Estimated Time**: 1 hour

---

## Priority 3: Low Priority (Future Enhancement)

### ✅ Fix 3B: Make readYourWrites Configurable (CORRECTED)

**Problem**: Only `getRange()` uses snapshot flag; `get()` calls are hardcoded. Also, FDB transaction option not set.

**Current Code Issues**:
1. `scrubIndexEntriesBatch()` Line 268-272: Only `getRange()` uses `snapshot: true`
2. Line 309-310: `transaction.get()` also uses `snapshot: true` (hardcoded)
3. No transaction-level ReadYourWrites option set

**Files to Modify**:
- `Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift`

**Changes Required**:

1. **scrubIndexEntriesBatch()** (Line 248-365):
   ```swift
   private func scrubIndexEntriesBatch(context: RecordContext, ...) async throws -> (...) {
       let transaction = context.getTransaction()

       // ✅ Step 1: Set transaction option (FDB level)
       let snapshot = !configuration.readYourWrites
       if !configuration.readYourWrites {
           // Disable ReadYourWrites for memory optimization
           // TODO: Confirm API - likely: transaction.setOption(.readYourWritesDisable)
       }

       var scannedBytes = 0
       var scannedCount = 0
       // ...

       // ✅ Step 2: Apply snapshot flag to getRange
       let sequence = transaction.getRange(
           begin: startKey,
           end: endKey,
           snapshot: snapshot  // ← Was: snapshot: true
       )

       for try await (indexKey, _) in sequence {
           // ...

           for recordTypeName in recordTypeNames {
               // ...
               let recordKey = recordSubspace.pack(...)

               // ✅ Step 3: Apply snapshot flag to get
               let recordData = try await transaction.get(
                   recordKey,
                   snapshot: snapshot  // ← Was: snapshot: true
               )
               // ...
           }
       }
   }
   ```

2. **scrubRecordsBatch()** - Same 3-step pattern:
   - Set transaction option
   - Apply snapshot to getRange (record scan)
   - Apply snapshot to get (index entry check)

**Prerequisites**:
- [ ] Investigate fdb-swift-bindings API for ReadYourWrites option
- [ ] Confirm option name (likely `.readYourWritesDisable`)

**Tests**:
- [ ] Test with readYourWrites=true (consistency mode)
- [ ] Test with readYourWrites=false (memory-optimized mode - current behavior)
- [ ] Verify memory usage difference

**Estimated Time**: 1.5 hours (including API investigation)

**Note**: For Scrubber, `readYourWrites=false` (snapshot reads) is recommended for large scans.

---

## Test Plan

### Unit Tests (Swift Testing)

Create file: `Tests/FDBRecordLayerTests/OnlineIndexScrubberTests.swift`

```swift
import Testing
import FDB
@testable import FDBRecordLayer

@Suite("OnlineIndexScrubber Tests")
struct OnlineIndexScrubberTests {

    @Test("Infinite loop prevention - oversized first key")
    func testOversizedFirstKey() async throws {
        // TODO: Implement
    }

    @Test("Repair atomicity - commit failure")
    func testRepairAtomicity() async throws {
        // TODO: Implement
    }

    @Test("Byte limit before, scan limit after")
    func testLimitTiming() async throws {
        // TODO: Implement
    }

    @Test("Transaction timeout configuration")
    func testTimeout() async throws {
        // TODO: Implement
    }

    @Test("Retry logic - transient errors")
    func testRetry() async throws {
        // TODO: Implement
    }

    @Test("Progress logging")
    func testLogging() async throws {
        // TODO: Implement
    }
}
```

### Integration Tests

Create file: `Tests/FDBRecordLayerTests/OnlineIndexScrubberIntegrationTests.swift`

```swift
@Suite("OnlineIndexScrubber Integration Tests")
struct OnlineIndexScrubberIntegrationTests {

    @Test("Full scrub - large dataset")
    func testFullScrubLarge() async throws {
        // TODO: 100K records, 5 indexes
    }

    @Test("Resume after interruption")
    func testResume() async throws {
        // TODO: Implement
    }
}
```

---

## Implementation Order (CORRECTED)

### Prerequisites (Before Implementation)
- [ ] Investigate fdb-swift-bindings API:
  - Transaction timeout setting method
  - ReadYourWrites disable option
  - Retryable error codes
- [ ] Estimated time: 2 hours

### Day 1: P0 Fixes (Critical)
- [ ] Morning: Fix 1 (Infinite Loop + Atomicity) - 2 hours
  - Both fixes are integrated in the same code change
  - Add error handling for transaction_too_large
  - Move allIssues.append() after commit
- [ ] Afternoon: Tests for P0 fixes - 2 hours
  - Oversized key scenarios
  - Commit failure scenarios
  - Forward progress verification
- [ ] End of day: Code review + build verification

### Day 2: P1 Fixes (High Priority)
- [ ] Morning: Fix 3A (Timeout) - 2 hours
  - Implement RecordContext.setTimeout()
  - Apply in batch methods
  - Tests
- [ ] Afternoon: Fix 3B (ReadYourWrites) - 1.5 hours
  - Apply snapshot flag to all reads
  - Set transaction option
  - Tests
- [ ] Late afternoon: Fix 3D (Retry) - 2 hours (if time permits)

### Day 3: P1 (continued) + P2 + Documentation
- [ ] Morning: Fix 3D (Retry) if not done - 2 hours
  - Implement withRetry helper
  - Apply to commits
  - Tests
- [ ] Morning/Afternoon: Fix 3C (Logging) - 1 hour
  - Add logProgress helper
  - Add log statements
- [ ] Afternoon: Integration tests - 2 hours
- [ ] End of day: Documentation update

**Total Estimated Time**: 14.5 hours (including prerequisites)
**Actual Days**: 3 days (with buffer for debugging)

---

## Validation Checklist

Before marking as complete:

- [ ] All P0 fixes implemented
- [ ] All P0 tests pass
- [ ] All P1 fixes implemented
- [ ] All P1 tests pass
- [ ] Build succeeds with no warnings
- [ ] Integration test: 100K records
- [ ] Resumability test passes
- [ ] Documentation updated
- [ ] Code review completed
- [ ] Performance regression check

---

## Current Status

**As of 2025-01-15**:

- ✅ Issues 1-4 from original list: FIXED
  - Composite index corruption
  - Progress tracking
  - Limit enforcement
  - Null field handling

- 🔴 NEW Issues identified in architecture review:
  - Issue 5: Infinite loop risk - **NOT FIXED**
  - Issue 6: Repair atomicity - **NOT FIXED**
  - Issue 7: Unused config fields - **NOT FIXED**

**Next Action**: Begin P0 implementation (Fix 1: Infinite Loop)
