# OnlineIndexScrubber Architecture and Design Document

**Version**: 1.0 (DEPRECATED - See Architecture-Fix.md)
**Date**: 2025-01-15
**Status**: Superseded

---

## ⚠️ WARNING: This Document Contains Errors

This document has been superseded by [OnlineIndexScrubber-Architecture-Fix.md](./OnlineIndexScrubber-Architecture-Fix.md).

**Critical Issues Identified**:
1. Infinite loop fix is incomplete
2. API references are incorrect (scrubPhase1, progressContext, etc.)
3. Configuration field names are wrong
4. Transaction option APIs need investigation

**Please use the corrected document**: [Architecture-Fix.md](./OnlineIndexScrubber-Architecture-Fix.md)

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Current Implementation](#current-implementation)
4. [Architectural Issues](#architectural-issues)
5. [Proposed Fixes](#proposed-fixes)
6. [Implementation Guidelines](#implementation-guidelines)
7. [Testing Strategy](#testing-strategy)
8. [References](#references)

---

## 1. Overview

### Purpose

OnlineIndexScrubber validates and repairs index consistency in FoundationDB Record Layer. It detects:
- **Dangling Entries**: Index entries pointing to non-existent records
- **Missing Entries**: Records that should have index entries but don't

### Design Goals

1. **Resumability**: Can be interrupted and resumed without losing progress
2. **Incremental Processing**: Processes data in batches to avoid transaction timeouts
3. **Atomic Repairs**: Repairs are transactional (all-or-nothing)
4. **Accurate Progress Tracking**: Uses RangeSet for half-open interval `[from, to)` semantics
5. **Resource Limits**: Respects maxTransactionBytes, entriesScanLimit, and timeout

### Key Constraints

| Constraint | Limit | Source |
|------------|-------|--------|
| Transaction Size | 10 MB (default) | FoundationDB |
| Transaction Time | 5 seconds | FoundationDB |
| Single Key Size | 10 KB | FoundationDB |
| Single Value Size | 100 KB | FoundationDB |

---

## 2. Architecture

### 2.1 Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                   OnlineIndexScrubber                        │
│                                                              │
│  ┌────────────────┐         ┌──────────────────┐           │
│  │  Configuration │────────▶│ Scrubber Result  │           │
│  └────────────────┘         └──────────────────┘           │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │          Two-Phase Validation                       │    │
│  │                                                      │    │
│  │  ┌──────────────┐         ┌──────────────────┐    │    │
│  │  │   Phase 1    │────────▶│     Phase 2      │    │    │
│  │  │ Index→Record │         │  Record→Index    │    │    │
│  │  │              │         │                  │    │    │
│  │  │ - Scan Index │         │ - Scan Records   │    │    │
│  │  │ - Check if   │         │ - Rebuild Index  │    │    │
│  │  │   Record     │         │   Keys           │    │    │
│  │  │   Exists     │         │ - Compare with   │    │    │
│  │  │              │         │   Actual Index   │    │    │
│  │  └──────────────┘         └──────────────────┘    │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │         Progress Tracking (RangeSet)                │    │
│  │                                                      │    │
│  │  [from1, to1), [from2, to2), [from3, to3), ...     │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
         │                            │
         │                            │
         ▼                            ▼
┌──────────────────┐        ┌──────────────────┐
│  RecordStore     │        │  RangeSet        │
│                  │        │  (Progress)      │
│ - getIndexState  │        │                  │
│ - loadRecord     │        │ - insertRange    │
│ - deleteRecord   │        │ - missingRanges  │
│ - saveRecord     │        │                  │
└──────────────────┘        └──────────────────┘
```

### 2.2 Data Flow

#### Phase 1: Index → Record Validation

```
1. Get missing ranges from progress tracker
   ├─ If no missing ranges → Phase 1 complete
   └─ Select first missing range

2. For each missing range:
   ├─ Scan index entries in batches
   │  ├─ Read index key
   │  ├─ Extract primary key from index key
   │  ├─ Check if record exists (snapshot read)
   │  └─ If not exists → Dangling Entry
   │
   ├─ If policy.allowRepair:
   │  ├─ Delete dangling index entries
   │  └─ Commit transaction
   │
   ├─ Mark processed range in RangeSet
   └─ Update progress

3. Return Phase 1 result
```

#### Phase 2: Record → Index Validation

```
1. Get missing ranges from progress tracker
   ├─ If no missing ranges → Phase 2 complete
   └─ Select first missing range

2. For each missing range:
   ├─ Scan records in batches
   │  ├─ Load record
   │  ├─ Rebuild expected index keys
   │  ├─ Check if index entries exist
   │  └─ If missing → Missing Entry
   │
   ├─ If policy.allowRepair:
   │  ├─ Insert missing index entries
   │  └─ Commit transaction
   │
   ├─ Mark processed range in RangeSet
   └─ Update progress

3. Return Phase 2 result
```

### 2.3 Batch Processing Lifecycle

```mermaid
sequenceDiagram
    participant Client
    participant Scrubber
    participant Transaction
    participant RangeSet
    participant FDB

    Client->>Scrubber: scrubIndexAsync()

    loop Phase 1 Batches
        Scrubber->>RangeSet: Get missing ranges
        RangeSet-->>Scrubber: [from, to)

        Scrubber->>Transaction: Begin

        loop Until Limit
            Scrubber->>FDB: Scan index entry
            FDB-->>Scrubber: indexKey
            Scrubber->>FDB: Check record exists
            FDB-->>Scrubber: exists/not

            alt Dangling Entry
                Scrubber->>Scrubber: Record issue
                alt allowRepair
                    Scrubber->>Transaction: Delete index entry
                end
            end

            alt Byte Limit Reached
                break Exit batch
            end

            alt Scan Limit Reached
                break Exit batch
            end
        end

        alt allowRepair
            Scrubber->>Transaction: Commit
        end

        Scrubber->>RangeSet: Mark [from, processedTo)
        Scrubber->>RangeSet: Commit progress
    end

    Scrubber-->>Client: Phase 1 Result
```

### 2.4 Key Design Patterns

#### Pattern 1: Half-Open Interval Progress Tracking

```swift
// RangeSet uses [from, to) semantics
// Last processed key: 0x0102
// Next batch starts from: nextKey(after: 0x0102) = 0x010200

let lastProcessedKey = indexKey  // e.g., [0x01, 0x02]
let continuationKey = nextKey(after: lastProcessedKey)  // [0x01, 0x02, 0x00]

// Mark progress: [rangeStart, continuationKey)
try await progress.insertRange(from: rangeStart, to: continuationKey)
```

**Why Half-Open Intervals?**
- `to` is exclusive: already processed keys won't be re-scanned
- Boundary keys are unambiguous: `to` of range N = `from` of range N+1
- Standard in FDB: `getRange(begin: inclusive, end: exclusive)`

#### Pattern 2: Cartesian Product for Composite Indexes

```swift
// Example: ConcatenateKeyExpression(city, tags[])
// Record: {city: "Tokyo", tags: ["swift", "fdb"]}

// Step 1: Evaluate city → [["Tokyo"]]
// Step 2: Evaluate tags → [["swift"], ["fdb"]]
// Step 3: Cartesian product:
//   ["Tokyo"] × ["swift"] → ["Tokyo", "swift"]
//   ["Tokyo"] × ["fdb"]   → ["Tokyo", "fdb"]
// Result: [["Tokyo", "swift"], ["Tokyo", "fdb"]]

func evaluateKeyExpression(...) -> [[any TupleElement]] {
    case let concat as ConcatenateKeyExpression:
        var result: [[any TupleElement]] = [[]]
        for child in concat.children {
            let childEntries = try evaluateKeyExpression(child, record)
            var newResult: [[any TupleElement]] = []
            for existing in result {
                for childEntry in childEntries {
                    newResult.append(existing + childEntry)
                }
            }
            result = newResult
        }
        return result
}
```

#### Pattern 3: VALUE Index Null Semantics

```swift
// Standard RDBMS behavior: NULL is not indexed
// Empty field evaluation → [] (no index entries)

if values.isEmpty {
    return []  // NOT [[]] - no entries at all
}

// Later in buildIndexKeys:
if indexEntries.isEmpty {
    return []  // No keys to build
}
```

#### Pattern 4: Limit Semantics (Critical!)

```swift
// TWO TYPES OF LIMITS with different timing:

// 1. BYTE LIMIT (Physical): Check BEFORE processing
//    - Prevent transaction from exceeding 10MB
//    - Unprocessed key = Continuation at SAME key
if scannedBytes + keySize > maxBytes {
    return (currentKey, ...)  // Current key NOT processed
}

// 2. SCAN LIMIT (Logical): Check AFTER processing
//    - Control batch size for performance
//    - Processed key = Continuation at NEXT key
lastProcessedKey = currentKey
if scannedCount >= scanLimit {
    return (nextKey(after: currentKey), ...)
}
```

---

## 3. Current Implementation

### 3.1 File Structure

```
Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift
├── Configuration (Lines 78-141)
├── ScrubberResult (Lines 836-885)
├── Public API
│   ├── scrubIndexAsync() (Lines 178-230)
│   └── getProgress() (Lines 887-896)
├── Phase 1: Index→Record
│   ├── scrubPhase1() (Lines 233-244)
│   └── scrubIndexEntriesBatch() (Lines 248-365)
└── Phase 2: Record→Index
    ├── scrubPhase2() (Lines 368-379)
    └── scrubRecordsBatch() (Lines 383-591)
```

### 3.2 Key Methods

#### scrubIndexEntriesBatch() - Phase 1 Batch Processing

```swift
private func scrubIndexEntriesBatch(
    context: FDBRecordContext,
    rangeStart: FDB.Bytes,
    rangeEnd: FDB.Bytes
) async throws -> (
    continuationKey: FDB.Bytes?,
    issues: [Issue],
    lastProcessedKey: FDB.Bytes?,
    scannedCount: Int
) {
    var scannedBytes = 0
    var scannedCount = 0
    var lastProcessedKey: FDB.Bytes? = nil
    var issues: [Issue] = []

    let sequence = try await context.getRange(
        begin: rangeStart,
        end: rangeEnd,
        limit: nil,
        mode: .iterator,
        snapshot: true  // ✅ Snapshot read - no conflict detection
    )

    for try await (indexKey, _) in sequence {
        // ✅ Check byte limit BEFORE processing
        let keySize = indexKey.count
        if scannedBytes + keySize > configuration.maxTransactionBytes {
            return (indexKey, issues, lastProcessedKey, scannedCount)
        }

        scannedBytes += keySize
        scannedCount += 1

        // Extract primary key and check record
        let primaryKey = try extractPrimaryKey(from: indexKey)
        let recordKey = recordSubspace.pack(TupleHelpers.toTuple(primaryKey))

        let recordExists = try await context.get(recordKey, snapshot: true) != nil

        if !recordExists {
            issues.append(Issue(
                type: .danglingEntry,
                indexKey: indexKey,
                primaryKey: primaryKey
            ))

            if configuration.scrubbingPolicy.allowRepair {
                try await context.clear(indexKey)
            }
        }

        lastProcessedKey = indexKey

        // ✅ Check scan limit AFTER processing
        if scannedCount >= configuration.entriesScanLimit {
            let continuationKey = nextKey(after: indexKey)
            return (continuationKey, issues, lastProcessedKey, scannedCount)
        }
    }

    return (nil, issues, lastProcessedKey, scannedCount)
}
```

### 3.3 Progress Tracking Flow

```swift
// 1. Get missing ranges
let missingRanges = try await progress.missingRanges(
    in: Range(from: indexSubspace.bytes, to: endKey)
)

// 2. Process first missing range
guard let firstRange = missingRanges.first else {
    return ScrubberResult(...)  // Complete
}

// 3. Process batch
let (continuation, issues, lastKey, count) = try await scrubIndexEntriesBatch(
    context: context,
    rangeStart: firstRange.from,
    rangeEnd: firstRange.to
)

// 4. Mark progress
if let lastKey = lastKey {
    let progressEnd = continuation ?? firstRange.to
    try await progress.insertRange(
        from: firstRange.from,
        to: progressEnd,
        context: progressContext
    )
}

// 5. Commit
try await context.commit()
try await progressContext.commit()
```

---

## 4. Architectural Issues

### Issue 1: Repair Atomicity Problem

#### Description

Issues are recorded in memory **before** transaction commits. If commit fails, issues are marked as "repaired" but the repair didn't happen.

#### Current Flow (WRONG)

```swift
// scrubPhase1() - Lines 233-244
while !missingRanges.isEmpty {
    let (continuation, batchIssues, lastKey, count) = try await scrubIndexEntriesBatch(...)

    // ❌ PROBLEM: Issues recorded BEFORE commit
    allIssues.append(contentsOf: batchIssues)

    // Mark progress
    try await progress.insertRange(...)

    // ❌ If commit fails here, issues are already in allIssues
    try await context.commit()
    try await progressContext.commit()
}

return ScrubberResult(
    danglingEntries: allIssues.count,  // ❌ Includes uncommitted repairs!
    ...
)
```

#### Why This Is Wrong

**Scenario: Commit Failure**

```
1. Batch 1: Find 10 dangling entries
2. Record 10 issues in allIssues
3. Delete 10 index entries in transaction
4. Commit FAILS (conflict, timeout, network error)
5. Return ScrubberResult: danglingEntries=10, repaired=10
   ❌ But nothing was actually repaired!
```

**Consequences**:
- Incorrect statistics (reports repairs that didn't happen)
- Loss of issue information (can't retry because issues are "recorded")
- No way to distinguish committed vs. uncommitted repairs

#### Root Cause

Architectural flaw: **Issue recording happens in a different scope than commit**
- Issues accumulated in `allIssues` (scrubPhase1 scope)
- Commit happens in inner loop (per-batch scope)
- No mechanism to rollback `allIssues` if commit fails

### Issue 2: Infinite Loop Risk

#### Description

If the **first key** in a batch exceeds `maxTransactionBytes`, the batch makes no forward progress, causing an infinite loop.

#### Current Flow (WRONG)

```swift
for try await (indexKey, _) in sequence {
    let keySize = indexKey.count

    // ❌ PROBLEM: Check happens BEFORE processing any entry
    if scannedBytes + keySize > configuration.maxTransactionBytes {
        // scannedCount = 0 (no entries processed)
        return (indexKey, issues, lastProcessedKey, scannedCount)
    }

    scannedBytes += keySize
    scannedCount += 1
    // ... process entry ...
}
```

#### Infinite Loop Scenario

**Given**:
- `maxTransactionBytes = 1 MB`
- First key in range = `5 MB` (large composite key)

**Execution**:

```
Batch 1:
  scannedBytes = 0
  Read first key (5 MB)
  Check: 0 + 5MB > 1MB → true
  Return (firstKey, [], nil, 0)  ❌ No progress!

Batch 2:
  Start from firstKey (same key)
  scannedBytes = 0
  Read first key (5 MB)
  Check: 0 + 5MB > 1MB → true
  Return (firstKey, [], nil, 0)  ❌ No progress again!

... INFINITE LOOP ...
```

#### Why This Happens

**Forward Progress Guarantee Violation**

Every batch MUST process at least 1 entry, otherwise:
1. Continuation key = same as start key
2. Next batch starts from same position
3. Same limit check fails
4. Loop forever

**Root Cause**: Byte limit checked before ANY entry is processed

#### Real-World Trigger

This can happen with:
- Large composite indexes: `Concat(field1, field2, field3, ...)`
- Long string fields in indexes
- Conservative `maxTransactionBytes` setting (e.g., 100 KB)

### Issue 3: Unused Configuration Fields

#### Description

Multiple configuration fields are defined but never used, making the implementation incomplete.

#### Unused Fields

| Field | Type | Purpose | Impact |
|-------|------|---------|--------|
| `transactionTimeoutMillis` | Int | Set transaction timeout | **Critical**: Prevents stuck transactions |
| `readYourWrites` | Bool | Control ReadYourWrites semantics | **Important**: Affects consistency |
| `progressLogging` | Bool | Enable progress logging | **Useful**: Debugging and monitoring |
| `maxRetries` | Int | Retry limit | **Important**: Prevents infinite retries |
| `retryDelayMillis` | Int | Delay between retries | **Important**: Backoff for transient errors |

#### Current Implementation

```swift
// Configuration.swift - Lines 78-141
public struct Configuration: Sendable {
    // ... fields defined ...

    // ❌ But never used:
    let transactionTimeoutMillis: Int
    let readYourWrites: Bool
    let progressLogging: Bool
    let maxRetries: Int
    let retryDelayMillis: Int
}

// OnlineIndexScrubber.swift - No usage of these fields
```

#### Impact Analysis

**Critical (transactionTimeoutMillis)**:
- Default FDB timeout: 5 seconds
- Large indexes may need more time
- Without timeout control, scrubbing fails on large batches

**Important (maxRetries, retryDelayMillis)**:
- Current: No retry logic → single failure aborts scrubbing
- Should: Retry transient errors (conflicts, timeouts)

**Useful (progressLogging)**:
- Current: Silent operation (no visibility)
- Should: Log progress for long-running scrubs

---

## 5. Proposed Fixes

### Fix 1: Repair Atomicity (Critical)

#### Option A: Record Issues After Commit (Preferred)

**Design**: Move issue recording to happen only after successful commit

```swift
// NEW: Result type for batch processing
private struct BatchResult {
    let continuationKey: FDB.Bytes?
    let issues: [Issue]  // Only returned if commit succeeded
    let lastProcessedKey: FDB.Bytes?
    let scannedCount: Int
}

// Modified scrubPhase1()
private func scrubPhase1(...) async throws -> ScrubberResult {
    var allIssues: [Issue] = []

    while !missingRanges.isEmpty {
        let context = recordStore.createContext()
        let progressContext = recordStore.createContext()

        let (continuation, batchIssues, lastKey, count) = try await scrubIndexEntriesBatch(...)

        // Mark progress
        if let lastKey = lastKey {
            let progressEnd = continuation ?? firstRange.to
            try await progress.insertRange(from: firstRange.from, to: progressEnd, context: progressContext)
        }

        // ✅ COMMIT FIRST
        try await context.commit()
        try await progressContext.commit()

        // ✅ THEN record issues (only if commit succeeded)
        allIssues.append(contentsOf: batchIssues)

        // Get updated missing ranges
        missingRanges = try await progress.missingRanges(...)
    }

    return ScrubberResult(
        danglingEntries: allIssues.count,
        // ... accurate statistics
    )
}
```

**Pros**:
- Simple: Just reorder operations
- Atomic: Issues only recorded if commit succeeds
- Accurate: Statistics always reflect committed repairs

**Cons**:
- None (this is the correct approach)

#### Option B: Rollback Issues on Commit Failure (Alternative)

**Design**: Record issues tentatively, rollback if commit fails

```swift
private func scrubPhase1(...) async throws -> ScrubberResult {
    var allIssues: [Issue] = []

    while !missingRanges.isEmpty {
        let batchStartCount = allIssues.count  // Checkpoint

        let (continuation, batchIssues, lastKey, count) = try await scrubIndexEntriesBatch(...)

        // Tentatively record issues
        allIssues.append(contentsOf: batchIssues)

        do {
            try await context.commit()
            try await progressContext.commit()
            // ✅ Commit succeeded - keep issues
        } catch {
            // ❌ Commit failed - rollback issues
            allIssues.removeLast(batchIssues.count)
            throw error
        }
    }

    return ScrubberResult(danglingEntries: allIssues.count, ...)
}
```

**Pros**:
- Clear error handling
- Easy to add retry logic

**Cons**:
- More complex
- Redundant (Option A is simpler and correct)

**Recommendation**: Use Option A (simpler and correct)

### Fix 2: Infinite Loop Prevention (Critical)

#### Design: Always Process At Least 1 Entry

**Principle**: Every batch MUST make forward progress

```swift
private func scrubIndexEntriesBatch(...) async throws -> (...) {
    var scannedBytes = 0
    var scannedCount = 0
    var lastProcessedKey: FDB.Bytes? = nil
    var issues: [Issue] = []

    let sequence = try await context.getRange(...)

    for try await (indexKey, _) in sequence {
        let keySize = indexKey.count

        // ✅ FIX: Only check limit if we've processed at least 1 entry
        if scannedCount > 0 && scannedBytes + keySize > configuration.maxTransactionBytes {
            // We've made progress (scannedCount > 0)
            // Current key is unprocessed - return it as continuation
            return (indexKey, issues, lastProcessedKey, scannedCount)
        }

        // ✅ Always process first entry (even if it exceeds limit)
        scannedBytes += keySize
        scannedCount += 1

        // ... process entry ...

        lastProcessedKey = indexKey

        // Scan limit check (unchanged)
        if scannedCount >= configuration.entriesScanLimit {
            let continuationKey = nextKey(after: indexKey)
            return (continuationKey, issues, lastProcessedKey, scannedCount)
        }
    }

    return (nil, issues, lastProcessedKey, scannedCount)
}
```

#### Why This Works

**Guarantee**: `scannedCount ≥ 1` at end of batch
- If `scannedCount = 0`: Never hits limit check (processes first entry)
- If `scannedCount ≥ 1`: Made progress (continuation moves forward)

**Large Key Handling**:
- First key is always processed (even if 5 MB)
- Transaction may exceed 10 MB temporarily
- FDB will reject at commit with `transaction_too_large` error
- This is correct behavior (fail fast, don't loop)

#### Error Handling for Oversized Keys

```swift
// In scrubPhase1()
do {
    try await context.commit()
} catch let error as FDB.Error where error.errno == 2101 {  // transaction_too_large
    // Log warning: Key at <lastProcessedKey> is too large
    // Skip this key and continue
    let skipKey = nextKey(after: lastProcessedKey!)
    try await progress.insertRange(from: rangeStart, to: skipKey, context: progressContext)
    try await progressContext.commit()
    continue
} catch {
    throw error
}
```

### Fix 3: Implement Critical Configuration Fields (High Priority)

#### 3A: transactionTimeoutMillis (Critical)

```swift
// In scrubIndexEntriesBatch() and scrubRecordsBatch()
private func scrubIndexEntriesBatch(...) async throws -> (...) {
    // ✅ Set transaction timeout at start
    if configuration.transactionTimeoutMillis > 0 {
        try await context.setTransactionTimeout(milliseconds: configuration.transactionTimeoutMillis)
    }

    // ... rest of batch processing ...
}
```

**Usage**:
```swift
let config = OnlineIndexScrubber.Configuration(
    maxTransactionBytes: 1_000_000,
    entriesScanLimit: 10_000,
    transactionTimeoutMillis: 30_000,  // 30 seconds (instead of default 5s)
    scrubbingPolicy: policy
)
```

#### 3B: readYourWrites (Important)

```swift
// In scrubIndexEntriesBatch()
private func scrubIndexEntriesBatch(...) async throws -> (...) {
    // ✅ Control ReadYourWrites semantics
    // For scrubbing, we typically want snapshot reads (no RYW)
    // This is already correct: using snapshot: true parameter

    let sequence = try await context.getRange(
        begin: rangeStart,
        end: rangeEnd,
        limit: nil,
        mode: .iterator,
        snapshot: true  // ✅ Snapshot = no ReadYourWrites
    )

    // ... rest of processing ...
}
```

**Note**: Current implementation is correct (snapshot reads), but we should make it configurable:

```swift
let snapshot = !configuration.readYourWrites
let sequence = try await context.getRange(..., snapshot: snapshot)
```

#### 3C: progressLogging (Useful)

```swift
// Add logging helper
private func logProgress(message: String) {
    if configuration.progressLogging {
        print("[OnlineIndexScrubber] \(message)")
    }
}

// Use throughout scrubbing
private func scrubPhase1(...) async throws -> ScrubberResult {
    logProgress("Starting Phase 1: Index→Record validation")

    while !missingRanges.isEmpty {
        logProgress("Processing range: \(firstRange.from.hexString) to \(firstRange.to.hexString)")

        let (continuation, issues, lastKey, count) = try await scrubIndexEntriesBatch(...)

        logProgress("Batch complete: scanned=\(count), issues=\(issues.count), continuation=\(continuation != nil)")

        // ... commit ...
    }

    logProgress("Phase 1 complete: total issues=\(allIssues.count)")
    return ScrubberResult(...)
}
```

#### 3D: maxRetries and retryDelayMillis (Important)

```swift
// Add retry wrapper
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

// Use in scrubPhase1() and scrubPhase2()
private func scrubPhase1(...) async throws -> ScrubberResult {
    // ...

    try await withRetry {
        try await context.commit()
        try await progressContext.commit()
    }

    // ...
}
```

**Retryable Errors**:
- `not_committed` (1020): Transaction conflict
- `transaction_too_old` (1007): Transaction exceeded 5 seconds
- `future_version` (1009): Read version too far in future

---

## 6. Implementation Guidelines

### 6.1 Priority Order

| Priority | Fix | Rationale | Estimated Effort |
|----------|-----|-----------|------------------|
| **P0** | Fix 2: Infinite Loop | Blocks scrubbing on large keys | 30 minutes |
| **P0** | Fix 1: Repair Atomicity | Incorrect statistics, loss of issues | 1 hour |
| **P1** | Fix 3A: transactionTimeoutMillis | Large indexes timeout | 30 minutes |
| **P1** | Fix 3D: Retry logic | Transient failures abort scrubbing | 2 hours |
| **P2** | Fix 3C: Progress logging | Debugging and monitoring | 1 hour |
| **P3** | Fix 3B: readYourWrites config | Already correct, just make configurable | 30 minutes |

### 6.2 Implementation Steps

#### Step 1: Fix Infinite Loop (P0)

1. Modify `scrubIndexEntriesBatch()`:
   - Change byte limit check to: `if scannedCount > 0 && scannedBytes + keySize > maxBytes`
   - Same change in `scrubRecordsBatch()`

2. Add error handling in `scrubPhase1()` and `scrubPhase2()`:
   - Catch `transaction_too_large` (2101)
   - Skip oversized key by inserting progress for `[rangeStart, nextKey(after: lastKey))`
   - Log warning with key details

3. Test cases:
   - Oversized first key (5 MB)
   - Normal batch with limit hit
   - Verify forward progress in all cases

#### Step 2: Fix Repair Atomicity (P0)

1. Modify `scrubPhase1()`:
   - Move `allIssues.append(contentsOf: batchIssues)` to AFTER commit
   - Same change in `scrubPhase2()`

2. Test cases:
   - Simulate commit failure (mock)
   - Verify statistics accuracy
   - Verify no lost issues

#### Step 3: Implement transactionTimeoutMillis (P1)

1. Add timeout setting in batch methods:
   ```swift
   if configuration.transactionTimeoutMillis > 0 {
       try await context.setTransactionTimeout(milliseconds: configuration.transactionTimeoutMillis)
   }
   ```

2. Test cases:
   - Long-running scrub (20+ seconds)
   - Verify no timeout with 30s setting
   - Verify timeout with default 5s

#### Step 4: Implement Retry Logic (P1)

1. Add `withRetry()` helper function
2. Wrap commit calls with retry
3. Add exponential backoff
4. Test cases:
   - Simulate transient conflicts
   - Verify retry behavior
   - Verify max retries limit

#### Step 5: Implement Progress Logging (P2)

1. Add `logProgress()` helper
2. Add log statements at key points:
   - Phase start/end
   - Batch processing
   - Issue detection
   - Repairs

3. Test: Run with `progressLogging: true`, verify output

#### Step 6: Make readYourWrites Configurable (P3)

1. Change snapshot parameter: `snapshot: !configuration.readYourWrites`
2. Test with both `true` and `false`

### 6.3 Backward Compatibility

**Configuration Changes**:
- All new fields have defaults (already defined)
- Existing code continues to work
- No breaking changes

**Behavioral Changes**:
- Fix 1 (Atomicity): More accurate statistics (improvement)
- Fix 2 (Infinite Loop): May see `transaction_too_large` errors for oversized keys (correct behavior)
- Fix 3A (Timeout): No change if timeout = 0 (default)
- Fix 3D (Retry): Automatic retries (improvement)

**Migration**: None required (backward compatible)

### 6.4 Testing Requirements

#### Unit Tests (Swift Testing)

```swift
@Test("Infinite loop prevention - oversized first key")
func testOversizedFirstKey() async throws {
    // Setup: Create index with first key = 5 MB
    // Config: maxTransactionBytes = 1 MB
    // Execute: Scrub
    // Verify: No infinite loop, transaction_too_large error, progress made
}

@Test("Repair atomicity - commit failure")
func testRepairAtomicity() async throws {
    // Setup: Create dangling entries
    // Mock: Commit throws error
    // Execute: Scrub with allowRepair
    // Verify: Statistics = 0 (no false positives)
}

@Test("Byte limit before processing, scan limit after")
func testLimitTiming() async throws {
    // Setup: 10 entries, each 200 KB
    // Config: maxBytes = 500 KB, scanLimit = 10
    // Execute: Scrub
    // Verify: Batch 1 processes 2 entries (2*200KB < 500KB, 3*200KB > 500KB)
}

@Test("Transaction timeout configuration")
func testTimeout() async throws {
    // Setup: Large index
    // Config: transactionTimeoutMillis = 30000
    // Execute: Long-running scrub
    // Verify: No timeout
}

@Test("Retry logic - transient errors")
func testRetry() async throws {
    // Mock: First 2 commits throw not_committed
    // Config: maxRetries = 3
    // Execute: Scrub
    // Verify: Success after 2 retries
}
```

#### Integration Tests

```swift
@Test("Full scrub - large dataset")
func testFullScrubLarge() async throws {
    // Setup: 100,000 records, 5 indexes
    // Create: 100 dangling entries, 100 missing entries
    // Execute: Full scrub
    // Verify: All issues detected and repaired, progress tracking correct
}

@Test("Resume after interruption")
func testResume() async throws {
    // Setup: Large dataset
    // Execute: Scrub halfway, then stop
    // Execute: Resume scrub
    // Verify: Continues from checkpoint, no duplicate work
}
```

---

## 7. Testing Strategy

### 7.1 Test Categories

| Category | Purpose | Coverage |
|----------|---------|----------|
| **Unit Tests** | Verify individual methods | Each fix independently |
| **Integration Tests** | Verify full scrubbing flow | End-to-end scenarios |
| **Edge Case Tests** | Boundary conditions | Oversized keys, empty ranges, etc. |
| **Performance Tests** | Large datasets | 100K+ records |
| **Resumability Tests** | Interruption handling | Checkpoint/resume |

### 7.2 Test Data Setup

```swift
// Helper: Create test data with known issues
struct TestDataBuilder {
    func createDanglingEntries(count: Int) async throws -> [FDB.Bytes]
    func createMissingEntries(count: Int) async throws -> [FDB.Bytes]
    func createOversizedKey(size: Int) async throws -> FDB.Bytes
    func createCompositeIndexWithNulls() async throws -> [Record]
}
```

### 7.3 Validation Checklist

Before considering implementation complete:

- [ ] All P0 fixes implemented and tested
- [ ] All P1 fixes implemented and tested
- [ ] Unit tests pass (100% coverage of fixes)
- [ ] Integration tests pass
- [ ] Performance test: 100K records in <5 minutes
- [ ] Resumability test: Interrupt at 50%, resume completes
- [ ] Documentation updated
- [ ] Code review completed

---

## 8. References

### 8.1 Related Files

| File | Relevance |
|------|-----------|
| `Sources/FDBRecordLayer/Index/OnlineIndexScrubber.swift` | Main implementation |
| `Sources/FDBRecordLayer/Index/IndexState.swift` | Index state management |
| `Sources/FDBRecordLayer/Index/RangeSet.swift` | Progress tracking |
| `Sources/FDBRecordLayer/Core/RecordStore.swift` | Record operations |
| `Sources/FDBRecordLayer/Core/FDBRecordContext.swift` | Transaction management |

### 8.2 External References

- [FoundationDB Java Record Layer - OnlineIndexer](https://github.com/FoundationDB/fdb-record-layer/blob/main/fdb-record-layer-core/src/main/java/com/apple/foundationdb/record/provider/foundationdb/OnlineIndexer.java)
- [FoundationDB Java Record Layer - IndexingThrottle](https://github.com/FoundationDB/fdb-record-layer/blob/main/fdb-record-layer-core/src/main/java/com/apple/foundationdb/record/provider/foundationdb/IndexingThrottle.java)
- [FoundationDB Documentation - Transaction Limits](https://apple.github.io/foundationdb/api-error-codes.html)

### 8.3 Design Documents

- [OnlineIndexer Architecture](./OnlineIndexer-Architecture.md)
- [RangeSet Design](./RangeSet-Design.md)
- [Swift Macro Design](./swift-macro-design.md)

---

**Document Status**: Draft for Review
**Next Steps**: Implement fixes in priority order (P0 → P1 → P2 → P3)
