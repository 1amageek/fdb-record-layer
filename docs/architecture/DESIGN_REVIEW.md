# FDB Record Layer 設計レビューと改訂版設計

**Version:** 2.0 (Updated)
**Date:** 2025-01-31
**Status:** ⚠️ **Partially Outdated**

> **注意**: このドキュメントの一部は古くなっています。
>
> **最新のAPI情報**: [API-MIGRATION-GUIDE.md](../API-MIGRATION-GUIDE.md) を参照してください。
>
> **主な変更点**:
> - `RecordSerializer` プロトコルは削除されました
> - `GenericRecordAccess<T: Recordable>` が新しい標準APIです

---

## 📋 Executive Summary

### ✅ 決定事項

1. **IndexState定義:** **3状態のみ (readable, disabled, writeOnly)** - 運用前のためシンプル化
2. **実装戦略:** 段階的実装、クリーンな設計を優先
3. **スケジュール:** 全7週間（Phase 0 完了済み）

### 🎯 主要目標

- ✅ クリーンで保守性の高い設計
- ✅ 1000万レコードのインデックス構築を2時間以内
- ✅ 複雑なクエリの10倍以上の高速化
- ✅ プロダクション対応の堅牢性

---

## 1. Critical Issues と解決策

### Issue 1: IndexState 定義 ✅ RESOLVED

#### 決定: 3状態のみ (運用前のためシンプル化)

**最終的な定義:**

```swift
/// Index lifecycle states
///
/// State transition diagram:
/// ```
///     ┌──────────┐
///     │ DISABLED │ ◄─────────────┐
///     └─────┬────┘               │
///           │ enableIndex()      │
///           ▼                    │ disableIndex()
///     ┌──────────┐               │
///     │WRITE_ONLY│               │
///     └─────┬────┘               │
///           │ markReadable()     │
///           ▼                    │
///     ┌──────────┐               │
///     │ READABLE │ ──────────────┘
///     └──────────┘
/// ```
public enum IndexState: UInt8, Sendable {
    /// Index is fully operational and can be used by queries
    case readable = 0

    /// Index is disabled
    /// - Not maintained on writes
    /// - Not used by queries
    case disabled = 1

    /// Index is being built or rebuilt
    /// - Maintained on writes
    /// - Not yet usable for queries
    case writeOnly = 2

    // MARK: - Helper Properties

    /// Returns true if this index can be used by queries
    public var isReadable: Bool {
        return self == .readable
    }

    /// Returns true if this index should be maintained on writes
    public var shouldMaintain: Bool {
        switch self {
        case .readable, .writeOnly:
            return true
        case .disabled:
            return false
        }
    }
}
```

**理由:**
1. ✅ まだ運用されていないため後方互換性不要
2. ✅ シンプルで保守しやすい設計
3. ✅ 不要な `.building` state を削除
4. ✅ クリーンな状態遷移

---

### Issue 2: IndexStateManager の実装 ✅ 完全仕様

#### 完全なAPI仕様

```swift
/// Manages index state transitions with validation
///
/// IndexStateManager enforces the following transition rules:
/// - DISABLED → WRITE_ONLY: enableIndex()
/// - WRITE_ONLY → READABLE: markReadable()
/// - Any state → DISABLED: disableIndex()
///
/// Thread-safe through Actor isolation.
public actor IndexStateManager {
    // MARK: - Properties

    private let database: any DatabaseProtocol
    private let subspace: Subspace

    // Cache for frequently accessed states
    private var stateCache: [String: CachedState] = [:]

    private struct CachedState {
        let state: IndexState
        let timestamp: Date
        let isValid: Bool

        func isExpired(ttl: TimeInterval = 5.0) -> Bool {
            return Date().timeIntervalSince(timestamp) > ttl
        }
    }

    // MARK: - Initialization

    public init(database: any DatabaseProtocol, subspace: Subspace) {
        self.database = database
        self.subspace = subspace
    }

    // MARK: - State Queries

    /// Get the current state of an index
    ///
    /// - Parameter indexName: Name of the index
    /// - Returns: Current IndexState
    /// - Throws: RecordLayerError if state value is invalid
    public func getState(indexName: String) async throws -> IndexState {
        // Check cache first
        if let cached = stateCache[indexName], !cached.isExpired() {
            return cached.state
        }

        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let stateKey = self.stateKey(for: indexName)

            guard let bytes = try await transaction.getValue(for: stateKey),
                  let stateValue = bytes.first else {
                // Default: new indexes start as DISABLED
                // They must be explicitly enabled and built
                let defaultState = IndexState.disabled
                self.updateCache(indexName: indexName, state: defaultState)
                return defaultState
            }

            guard let state = IndexState(rawValue: stateValue) else {
                throw RecordLayerError.invalidIndexState(stateValue)
            }

            // Update cache
            self.updateCache(indexName: indexName, state: state)

            return state.canonical
        }
    }

    /// Check if an index is readable
    ///
    /// - Parameter indexName: Name of the index
    /// - Returns: true if index state is READABLE
    public func isReadable(indexName: String) async throws -> Bool {
        let state = try await getState(indexName: indexName)
        return state.isReadable
    }

    /// Check if an index should be maintained on writes
    ///
    /// - Parameter indexName: Name of the index
    /// - Returns: true if index should be maintained
    public func shouldMaintain(indexName: String) async throws -> Bool {
        let state = try await getState(indexName: indexName)
        return state.shouldMaintain
    }

    // MARK: - State Transitions

    /// Enable an index (transition to WRITE_ONLY state)
    ///
    /// This sets the index to WRITE_ONLY state, meaning:
    /// - New writes will maintain the index
    /// - Queries will not use the index yet
    /// - Background index building can proceed
    ///
    /// - Parameter indexName: Name of the index
    /// - Throws: RecordLayerError.invalidStateTransition if not in DISABLED state
    public func enableIndex(indexName: String) async throws {
        try await database.withRecordContext { context in
            let currentState = try await self.getState(indexName: indexName)

            // Validate transition: only from DISABLED
            guard currentState == .disabled else {
                throw RecordLayerError.invalidStateTransition(
                    from: currentState,
                    to: .writeOnly,
                    index: indexName,
                    reason: "Index must be DISABLED before enabling"
                )
            }

            let transaction = context.getTransaction()
            let stateKey = self.stateKey(for: indexName)
            transaction.setValue([IndexState.writeOnly.rawValue], for: stateKey)

            // Invalidate cache
            self.invalidateCache(indexName: indexName)
        }
    }

    /// Mark an index as readable (transition to READABLE state)
    ///
    /// This should only be called after index building is complete.
    ///
    /// - Parameter indexName: Name of the index
    /// - Throws: RecordLayerError.invalidStateTransition if not in WRITE_ONLY state
    public func markReadable(indexName: String) async throws {
        try await database.withRecordContext { context in
            let currentState = try await self.getState(indexName: indexName)

            // Validate transition: only from WRITE_ONLY
            guard currentState == .writeOnly else {
                throw RecordLayerError.invalidStateTransition(
                    from: currentState,
                    to: .readable,
                    index: indexName,
                    reason: "Index must be in WRITE_ONLY state before marking readable"
                )
            }

            let transaction = context.getTransaction()
            let stateKey = self.stateKey(for: indexName)
            transaction.setValue([IndexState.readable.rawValue], for: stateKey)

            // Invalidate cache
            self.invalidateCache(indexName: indexName)
        }
    }

    /// Disable an index (transition to DISABLED state)
    ///
    /// This can be called from any state.
    ///
    /// - Parameter indexName: Name of the index
    public func disableIndex(indexName: String) async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let stateKey = self.stateKey(for: indexName)
            transaction.setValue([IndexState.disabled.rawValue], for: stateKey)

            // Invalidate cache
            self.invalidateCache(indexName: indexName)
        }
    }

    // MARK: - Batch Operations

    /// Get states for multiple indexes efficiently
    ///
    /// - Parameter indexNames: List of index names
    /// - Returns: Dictionary mapping index names to states
    public func getStates(indexNames: [String]) async throws -> [String: IndexState] {
        var results: [String: IndexState] = [:]

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            for indexName in indexNames {
                // Check cache first
                if let cached = self.stateCache[indexName], !cached.isExpired() {
                    results[indexName] = cached.state
                    continue
                }

                let stateKey = self.stateKey(for: indexName)
                guard let bytes = try await transaction.getValue(for: stateKey),
                      let stateValue = bytes.first,
                      let state = IndexState(rawValue: stateValue) else {
                    results[indexName] = .disabled
                    continue
                }

                let canonicalState = state.canonical
                results[indexName] = canonicalState
                self.updateCache(indexName: indexName, state: canonicalState)
            }
        }

        return results
    }

    // MARK: - Cache Management

    private func updateCache(indexName: String, state: IndexState) {
        stateCache[indexName] = CachedState(
            state: state,
            timestamp: Date(),
            isValid: true
        )
    }

    private func invalidateCache(indexName: String) {
        stateCache.removeValue(forKey: indexName)
    }

    /// Clear all cached states
    public func clearCache() {
        stateCache.removeAll()
    }

    // MARK: - Private Helpers

    private func stateKey(for indexName: String) -> FDB.Bytes {
        let stateSubspace = subspace.subspace(RecordStoreKeyspace.indexState.rawValue)
        return stateSubspace.pack(Tuple(indexName))
    }
}
```

#### RecordLayerError の拡張

```swift
extension RecordLayerError {
    /// Invalid state transition error
    public static func invalidStateTransition(
        from: IndexState,
        to: IndexState,
        index: String,
        reason: String = ""
    ) -> RecordLayerError {
        let message = "Invalid state transition for index '\(index)': \(from) → \(to)"
        let fullMessage = reason.isEmpty ? message : "\(message). \(reason)"
        return .internalError(fullMessage)
    }

    /// Invalid indexing policy error
    public static func invalidIndexingPolicy(_ message: String) -> RecordLayerError {
        return .internalError("Invalid indexing policy: \(message)")
    }
}
```

---

### Issue 3: RangeSet の完全仕様

#### RangeSet の設計

```swift
/// Tracks which key ranges have been processed during index building
///
/// RangeSet stores completed ranges in FDB and provides:
/// - Insert completed ranges
/// - Merge adjacent ranges automatically
/// - Query next incomplete range
/// - Calculate completion percentage
///
/// Storage format:
/// Key:   [subspace]["range_set"][index_name][begin_key]
/// Value: [end_key]
///
/// Example:
/// ```
/// Key: [prefix]["range_set"]["email_idx"]["user:0000"]
/// Value: "user:1000"
/// ```
/// This indicates range ["user:0000", "user:1000") is complete.
public actor RangeSet {
    // MARK: - Properties

    private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let indexName: String

    // MARK: - Initialization

    public init(database: any DatabaseProtocol, subspace: Subspace, indexName: String) {
        self.database = database
        self.subspace = subspace
        self.indexName = indexName
    }

    // MARK: - Range Operations

    /// Insert a completed range
    ///
    /// Automatically merges with adjacent ranges if possible.
    ///
    /// - Parameters:
    ///   - begin: Start of range (inclusive)
    ///   - end: End of range (exclusive)
    public func insertRange(begin: FDB.Bytes, end: FDB.Bytes) async throws {
        guard begin < end else {
            throw RecordLayerError.internalError("Invalid range: begin must be < end")
        }

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            // Check if we can merge with previous range
            let mergedBegin = try await self.findMergeableBegin(
                before: begin,
                transaction: transaction
            ) ?? begin

            // Check if we can merge with next range
            let mergedEnd = try await self.findMergeableEnd(
                after: end,
                transaction: transaction
            ) ?? end

            // Store the merged range
            let rangeKey = self.rangeKey(begin: mergedBegin)
            transaction.setValue(mergedEnd, for: rangeKey)

            // Clean up ranges that were merged
            if mergedBegin != begin {
                transaction.clear(key: self.rangeKey(begin: begin))
            }
            if mergedEnd != end {
                // Find and remove the next range that was merged
                let sequence = transaction.getRange(
                    beginSelector: .firstGreaterThan(self.rangeKey(begin: end)),
                    endSelector: .firstGreaterOrEqual(self.rangeKey(begin: mergedEnd)),
                    limit: 10,
                    snapshot: false
                )

                for try await (key, _) in sequence {
                    transaction.clear(key: key)
                }
            }
        }
    }

    /// Check if a range is complete
    ///
    /// - Parameters:
    ///   - begin: Start of range
    ///   - end: End of range
    /// - Returns: true if entire range is marked as complete
    public func contains(begin: FDB.Bytes, end: FDB.Bytes) async throws -> Bool {
        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            // Find ranges that overlap with [begin, end)
            let sequence = transaction.getRange(
                beginSelector: .lastLessOrEqual(self.rangeKey(begin: begin)),
                endSelector: .firstGreaterOrEqual(self.rangeKey(begin: end)),
                snapshot: true
            )

            for try await (key, value) in sequence {
                let rangeBegin = try self.rangeSubspace().unpack(key)
                guard let beginBytes = rangeBegin.first as? FDB.Bytes else {
                    continue
                }

                let rangeEnd = value

                // Check if this range covers [begin, end)
                if beginBytes <= begin && rangeEnd >= end {
                    return true
                }
            }

            return false
        }
    }

    /// Get the next incomplete range to process
    ///
    /// - Parameters:
    ///   - after: Start searching after this position
    ///   - totalEnd: The end of the total range being indexed
    ///   - limit: Maximum size of the returned range (in records, estimated)
    /// - Returns: (begin, end) of next incomplete range, or nil if all complete
    public func getNextIncompleteRange(
        after: FDB.Bytes,
        totalEnd: FDB.Bytes,
        limit: Int = 1000
    ) async throws -> (begin: FDB.Bytes, end: FDB.Bytes)? {
        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            // Find the last completed range at or before 'after'
            let lastCompleted = try await self.findLastCompletedRange(
                before: after,
                transaction: transaction
            )

            let searchStart: FDB.Bytes
            if let (_, completedEnd) = lastCompleted, completedEnd > after {
                // The last completed range extends beyond 'after'
                searchStart = completedEnd
            } else {
                searchStart = after
            }

            if searchStart >= totalEnd {
                // Already at the end
                return nil
            }

            // Find the next completed range
            let nextCompleted = try await self.findFirstCompletedRange(
                after: searchStart,
                transaction: transaction
            )

            if let (nextBegin, _) = nextCompleted {
                // There's a gap between searchStart and nextBegin
                let gapEnd = min(nextBegin, totalEnd)
                return (begin: searchStart, end: gapEnd)
            } else {
                // No more completed ranges, return [searchStart, totalEnd)
                return (begin: searchStart, end: totalEnd)
            }
        }
    }

    /// Calculate completion percentage
    ///
    /// - Parameter totalRange: The total range (begin, end) being indexed
    /// - Returns: Completion percentage (0.0 to 1.0)
    public func getProgress(totalRange: (FDB.Bytes, FDB.Bytes)) async throws -> Double {
        let (totalBegin, totalEnd) = totalRange

        // Estimate: count completed ranges and assume uniform distribution
        // More accurate: integrate range sizes (requires key distribution knowledge)

        let completedRanges = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(self.rangeKey(begin: totalBegin)),
                endSelector: .firstGreaterOrEqual(self.rangeKey(begin: totalEnd)),
                snapshot: true
            )

            var count = 0
            for try await _ in sequence {
                count += 1
            }
            return count
        }

        // Simple heuristic: assume total range will have ~100 sub-ranges
        // This is a rough estimate
        let estimatedTotalRanges = 100
        let progress = min(1.0, Double(completedRanges) / Double(estimatedTotalRanges))

        return progress
    }

    /// Clear all progress (restart indexing)
    public func clear() async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = self.rangeSubspace().range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Private Helpers

    private func rangeKey(begin: FDB.Bytes) -> FDB.Bytes {
        return rangeSubspace().pack(Tuple(begin))
    }

    private func rangeSubspace() -> Subspace {
        return subspace
            .subspace(RecordStoreKeyspace.indexRange.rawValue)
            .subspace(Tuple(indexName))
    }

    private func findMergeableBegin(
        before: FDB.Bytes,
        transaction: any TransactionProtocol
    ) async throws -> FDB.Bytes? {
        let sequence = transaction.getRange(
            beginSelector: .lastLessOrEqual(rangeKey(begin: before)),
            endSelector: .firstGreaterOrEqual(rangeKey(begin: before)),
            limit: 1,
            snapshot: false
        )

        for try await (key, value) in sequence {
            let rangeBegin = try rangeSubspace().unpack(key)
            guard let beginBytes = rangeBegin.first as? FDB.Bytes else {
                continue
            }
            let rangeEnd = value

            // Check if this range ends exactly at 'before'
            if rangeEnd == before {
                return beginBytes
            }
        }

        return nil
    }

    private func findMergeableEnd(
        after: FDB.Bytes,
        transaction: any TransactionProtocol
    ) async throws -> FDB.Bytes? {
        // Check if there's a range that starts exactly at 'after'
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(rangeKey(begin: after)),
            endSelector: .firstGreaterThan(rangeKey(begin: after)),
            limit: 1,
            snapshot: false
        )

        for try await (key, value) in sequence {
            let rangeBegin = try rangeSubspace().unpack(key)
            guard let beginBytes = rangeBegin.first as? FDB.Bytes else {
                continue
            }

            if beginBytes == after {
                return value
            }
        }

        return nil
    }

    private func findLastCompletedRange(
        before: FDB.Bytes,
        transaction: any TransactionProtocol
    ) async throws -> (begin: FDB.Bytes, end: FDB.Bytes)? {
        let sequence = transaction.getRange(
            beginSelector: .lastLessOrEqual(rangeKey(begin: before)),
            endSelector: .firstGreaterOrEqual(rangeKey(begin: before)),
            limit: 1,
            snapshot: true
        )

        for try await (key, value) in sequence {
            let rangeBegin = try rangeSubspace().unpack(key)
            guard let beginBytes = rangeBegin.first as? FDB.Bytes else {
                continue
            }
            return (begin: beginBytes, end: value)
        }

        return nil
    }

    private func findFirstCompletedRange(
        after: FDB.Bytes,
        transaction: any TransactionProtocol
    ) async throws -> (begin: FDB.Bytes, end: FDB.Bytes)? {
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterThan(rangeKey(begin: after)),
            endSelector: .lastLessOrEqual(rangeKey(begin: [0xFF, 0xFF, 0xFF])),
            limit: 1,
            snapshot: true
        )

        for try await (key, value) in sequence {
            let rangeBegin = try rangeSubspace().unpack(key)
            guard let beginBytes = rangeBegin.first as? FDB.Bytes else {
                continue
            }
            return (begin: beginBytes, end: value)
        }

        return nil
    }
}
```

---

## 2. 改訂版実装計画

### Phase 0: IndexState シンプル化 ✅ COMPLETED

**目標:** IndexStateを3状態に整理（運用前のため後方互換性不要）

**実施内容:**

```swift
// Task 1: Remove .building state ✅
// File: Sources/FDBRecordLayer/Core/Types.swift

public enum IndexState: UInt8, Sendable {
    case readable = 0
    case disabled = 1
    case writeOnly = 2

    // Helper properties added:
    public var isReadable: Bool { ... }
    public var shouldMaintain: Bool { ... }
}

// Task 2: Update default state to .writeOnly ✅
// Files updated:
// - Sources/FDBRecordLayer/Store/RecordStore.swift
// - Sources/FDBRecordLayer/Store/TypedRecordStore.swift

// Before:
// return .building

// After:
return .writeOnly

// Task 3: Test fixes ✅
// Fixed compilation errors in:
// - Tests/FDBRecordLayerTests/Core/KeyExpressionTests.swift
// - Tests/FDBRecordLayerTests/Core/SubspaceTests.swift
```

**完了条件:**
- [x] `.building` state完全削除
- [x] 3状態のみ (readable, disabled, writeOnly)
- [x] Test suite compiles 100%
- [x] Build succeeds with no errors

**完了日:** 2025-01-31

---

### Phase 1: IndexStateManager (Week 1-1.5)

**目標:** 状態管理の集中化と検証

**実装ファイル:**

```
Sources/FDBRecordLayer/Index/IndexStateManager.swift  (新規作成)
Tests/FDBRecordLayerTests/IndexStateManagerTests.swift (新規作成)
```

**統合箇所:**

```swift
// File: Sources/FDBRecordLayer/Store/TypedRecordStore.swift

public final class TypedRecordStore<Record: Sendable>: Sendable {
    // Add new property
    private let indexStateManager: IndexStateManager

    public init(...) {
        // ...
        self.indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )
    }

    // Update executeQuery to filter readable indexes
    public func executeQuery(
        _ query: TypedRecordQuery<Record>,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Get only readable indexes
        let readableIndexes = try await filterReadableIndexes()

        let planner = TypedRecordQueryPlanner(
            recordType: recordType,
            indexes: readableIndexes
        )

        let plan = try planner.plan(query)
        return try await plan.execute(...)
    }

    private func filterReadableIndexes() async throws -> [TypedIndex<Record>] {
        let indexNames = indexes.map { $0.name }
        let states = try await indexStateManager.getStates(indexNames: indexNames)

        return indexes.filter { index in
            states[index.name]?.isReadable ?? false
        }
    }

    // Update saveRecord to check if index should be maintained
    public func saveRecord(_ record: Record, context: RecordContext) async throws {
        // ...

        // Filter indexes that should be maintained
        let maintainedIndexes = try await filterMaintainedIndexes()

        try await updateIndexesForRecord(
            oldRecord: existingRecord,
            newRecord: record,
            primaryKey: primaryKey,
            transaction: transaction,
            indexes: maintainedIndexes
        )
    }

    private func filterMaintainedIndexes() async throws -> [TypedIndex<Record>] {
        let indexNames = indexes.map { $0.name }
        let states = try await indexStateManager.getStates(indexNames: indexNames)

        return indexes.filter { index in
            states[index.name]?.shouldMaintain ?? false
        }
    }
}
```

**テスト:**

```swift
// File: Tests/FDBRecordLayerTests/IndexStateManagerTests.swift

final class IndexStateManagerTests: XCTestCase {
    var database: FDBDatabase!
    var subspace: Subspace!
    var manager: IndexStateManager!

    override func setUp() async throws {
        try await FDBClient.initialize()
        database = try FDBClient.openDatabase()
        subspace = Subspace(prefix: "test_state_\(UUID().uuidString)")
        manager = IndexStateManager(database: database, subspace: subspace)
    }

    func testInitialStateIsDisabled() async throws {
        let state = try await manager.getState(indexName: "test_index")
        XCTAssertEqual(state, .disabled)
    }

    func testEnableIndex() async throws {
        try await manager.enableIndex(indexName: "test_index")
        let state = try await manager.getState(indexName: "test_index")
        XCTAssertEqual(state, .writeOnly)
    }

    func testMarkReadable() async throws {
        try await manager.enableIndex(indexName: "test_index")
        try await manager.markReadable(indexName: "test_index")
        let state = try await manager.getState(indexName: "test_index")
        XCTAssertEqual(state, .readable)
    }

    func testInvalidTransitionThrows() async throws {
        // Try to mark readable without enabling first
        do {
            try await manager.markReadable(indexName: "test_index")
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is RecordLayerError)
        }
    }

    func testDisableFromAnyState() async throws {
        try await manager.enableIndex(indexName: "test_index")
        try await manager.disableIndex(indexName: "test_index")
        let state = try await manager.getState(indexName: "test_index")
        XCTAssertEqual(state, .disabled)
    }

    func testBatchGetStates() async throws {
        try await manager.enableIndex(indexName: "index1")
        try await manager.enableIndex(indexName: "index2")
        try await manager.markReadable(indexName: "index2")

        let states = try await manager.getStates(indexNames: ["index1", "index2", "index3"])

        XCTAssertEqual(states["index1"], .writeOnly)
        XCTAssertEqual(states["index2"], .readable)
        XCTAssertEqual(states["index3"], .disabled)
    }

    func testCacheInvalidation() async throws {
        try await manager.enableIndex(indexName: "test_index")

        // First read (cached)
        let state1 = try await manager.getState(indexName: "test_index")
        XCTAssertEqual(state1, .writeOnly)

        // External modification (simulate)
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let stateSubspace = self.subspace.subspace(RecordStoreKeyspace.indexState.rawValue)
            let key = stateSubspace.pack(Tuple("test_index"))
            transaction.setValue([IndexState.readable.rawValue], for: key)
        }

        // Cache should still return old value
        let state2 = try await manager.getState(indexName: "test_index")
        XCTAssertEqual(state2, .writeOnly)

        // Clear cache
        await manager.clearCache()

        // Now should read new value
        let state3 = try await manager.getState(indexName: "test_index")
        XCTAssertEqual(state3, .readable)
    }
}
```

**完了条件:**
- [ ] All tests pass
- [ ] Integration with TypedRecordStore complete
- [ ] Queries only use readable indexes
- [ ] Writes only maintain appropriate indexes
- [ ] Code coverage > 90%

---

### Phase 2: RangeSet (Week 2-2.5)

**目標:** 進捗管理とレジューム機能の基盤

**実装ファイル:**

```
Sources/FDBRecordLayer/Index/RangeSet.swift  (新規作成)
Tests/FDBRecordLayerTests/RangeSetTests.swift (新規作成)
```

**テスト:**

```swift
// File: Tests/FDBRecordLayerTests/RangeSetTests.swift

final class RangeSetTests: XCTestCase {
    var database: FDBDatabase!
    var subspace: Subspace!
    var rangeSet: RangeSet!

    override func setUp() async throws {
        try await FDBClient.initialize()
        database = try FDBClient.openDatabase()
        subspace = Subspace(prefix: "test_range_\(UUID().uuidString)")
        rangeSet = RangeSet(database: database, subspace: subspace, indexName: "test_index")
    }

    func testInsertRange() async throws {
        let begin: FDB.Bytes = [0x00, 0x00]
        let end: FDB.Bytes = [0x00, 0x10]

        try await rangeSet.insertRange(begin: begin, end: end)

        let contains = try await rangeSet.contains(begin: begin, end: end)
        XCTAssertTrue(contains)
    }

    func testMergeAdjacentRanges() async throws {
        // Insert [0x00, 0x10)
        try await rangeSet.insertRange(begin: [0x00], end: [0x10])

        // Insert [0x10, 0x20) - should merge to [0x00, 0x20)
        try await rangeSet.insertRange(begin: [0x10], end: [0x20])

        // Check merged range
        let contains = try await rangeSet.contains(begin: [0x00], end: [0x20])
        XCTAssertTrue(contains)
    }

    func testGetNextIncompleteRange() async throws {
        let totalBegin: FDB.Bytes = [0x00]
        let totalEnd: FDB.Bytes = [0xFF]

        // Mark [0x00, 0x10) as complete
        try await rangeSet.insertRange(begin: [0x00], end: [0x10])

        // Get next incomplete range
        let next = try await rangeSet.getNextIncompleteRange(
            after: [0x00],
            totalEnd: totalEnd
        )

        XCTAssertNotNil(next)
        XCTAssertEqual(next?.begin, [0x10])
    }

    func testProgress() async throws {
        let totalRange: (FDB.Bytes, FDB.Bytes) = ([0x00], [0xFF])

        // Initially 0%
        let progress1 = try await rangeSet.getProgress(totalRange: totalRange)
        XCTAssertEqual(progress1, 0.0, accuracy: 0.01)

        // Insert some ranges
        try await rangeSet.insertRange(begin: [0x00], end: [0x10])
        try await rangeSet.insertRange(begin: [0x10], end: [0x20])

        // Should show progress
        let progress2 = try await rangeSet.getProgress(totalRange: totalRange)
        XCTAssertGreaterThan(progress2, 0.0)
    }

    func testClear() async throws {
        try await rangeSet.insertRange(begin: [0x00], end: [0x10])

        try await rangeSet.clear()

        let contains = try await rangeSet.contains(begin: [0x00], end: [0x10])
        XCTAssertFalse(contains)
    }
}
```

**完了条件:**
- [ ] All tests pass
- [ ] Range merging works correctly
- [ ] Next incomplete range query is efficient
- [ ] Code coverage > 85%

---

### Phase 3: OnlineIndexer Enhancement (Week 3-4.5)

**目標:** 堅牢なインデックス構築

**新しい構造体:**

```swift
// File: Sources/FDBRecordLayer/Index/IndexingPolicy.swift

/// Policy for index building behavior
public struct IndexingPolicy: Sendable {
    /// Clear existing index data before building
    public let clearExisting: Bool

    /// Set index to WRITE_ONLY before building
    public let enableWriteOnly: Bool

    /// Mark index as READABLE after completion
    public let markReadableOnComplete: Bool

    /// Allow resuming from previous progress
    public let allowResume: Bool

    /// Throttling configuration
    public let throttle: IndexingThrottle

    public init(
        clearExisting: Bool = true,
        enableWriteOnly: Bool = true,
        markReadableOnComplete: Bool = true,
        allowResume: Bool = true,
        throttle: IndexingThrottle = .default
    ) {
        self.clearExisting = clearExisting
        self.enableWriteOnly = enableWriteOnly
        self.markReadableOnComplete = markReadableOnComplete
        self.allowResume = allowResume
        self.throttle = throttle
    }

    /// Default policy for new index builds
    public static let `default` = IndexingPolicy()

    /// Policy for resuming interrupted builds
    public static let resume = IndexingPolicy(
        clearExisting: false,
        enableWriteOnly: false,
        markReadableOnComplete: true,
        allowResume: true,
        throttle: .default
    )

    /// Aggressive policy for fast builds (use with caution)
    public static let aggressive = IndexingPolicy(
        clearExisting: true,
        enableWriteOnly: true,
        markReadableOnComplete: true,
        allowResume: true,
        throttle: .aggressive
    )

    /// Conservative policy for production environments
    public static let conservative = IndexingPolicy(
        clearExisting: true,
        enableWriteOnly: true,
        markReadableOnComplete: true,
        allowResume: true,
        throttle: .conservative
    )
}

/// Throttling configuration for index building
public struct IndexingThrottle: Sendable {
    /// Maximum records per transaction
    public let maxRecordsPerTransaction: Int

    /// Delay between transactions (milliseconds)
    public let delayBetweenTransactions: UInt64

    /// Maximum transaction size (bytes)
    public let maxTransactionBytes: Int

    /// Enable adaptive batch sizing
    public let adaptiveBatchSize: Bool

    public init(
        maxRecordsPerTransaction: Int = 1000,
        delayBetweenTransactions: UInt64 = 10,
        maxTransactionBytes: Int = 9_000_000,
        adaptiveBatchSize: Bool = true
    ) {
        self.maxRecordsPerTransaction = maxRecordsPerTransaction
        self.delayBetweenTransactions = delayBetweenTransactions
        self.maxTransactionBytes = maxTransactionBytes
        self.adaptiveBatchSize = adaptiveBatchSize
    }

    /// Default throttling (balanced)
    public static let `default` = IndexingThrottle()

    /// Aggressive throttling (faster but higher load)
    public static let aggressive = IndexingThrottle(
        maxRecordsPerTransaction: 5000,
        delayBetweenTransactions: 0,
        maxTransactionBytes: 9_000_000,
        adaptiveBatchSize: true
    )

    /// Conservative throttling (slower but minimal impact)
    public static let conservative = IndexingThrottle(
        maxRecordsPerTransaction: 100,
        delayBetweenTransactions: 100,
        maxTransactionBytes: 1_000_000,
        adaptiveBatchSize: false
    )
}

/// Progress information for index building
public struct IndexBuildProgress: Sendable {
    public let recordsScanned: UInt64
    public let recordsIndexed: UInt64
    public let completionPercentage: Double
    public let startTime: Date?
    public let currentBatchSize: Int

    public var elapsedTime: TimeInterval? {
        guard let start = startTime else { return nil }
        return Date().timeIntervalSince(start)
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard let elapsed = elapsedTime, completionPercentage > 0 else {
            return nil
        }
        let totalEstimated = elapsed / completionPercentage
        return totalEstimated - elapsed
    }

    public var recordsPerSecond: Double? {
        guard let elapsed = elapsedTime, elapsed > 0 else {
            return nil
        }
        return Double(recordsScanned) / elapsed
    }
}
```

**改善された OnlineIndexer:**

```swift
// File: Sources/FDBRecordLayer/Index/OnlineIndexer.swift (改訂)

public final class OnlineIndexer: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let metaData: RecordMetaData
    private let index: Index
    private let serializer: any RecordSerializer<[String: Any]>
    private let logger: Logger
    private let lock: Mutex<IndexBuildState>

    // New components
    private let rangeSet: RangeSet
    private let stateManager: IndexStateManager
    private let policy: IndexingPolicy

    // MARK: - Build State

    private struct IndexBuildState {
        var totalRecordsScanned: UInt64 = 0
        var totalRecordsIndexed: UInt64 = 0
        var startTime: Date?
        var endTime: Date?
        var currentBatchSize: Int
        var lastError: Error?
    }

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        index: Index,
        serializer: any RecordSerializer<[String: Any]>,
        policy: IndexingPolicy = .default,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.index = index
        self.serializer = serializer
        self.policy = policy
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.indexer")

        self.rangeSet = RangeSet(
            database: database,
            subspace: subspace,
            indexName: index.name
        )
        self.stateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )
        self.lock = Mutex(IndexBuildState(
            currentBatchSize: policy.throttle.maxRecordsPerTransaction
        ))
    }

    // MARK: - Public API

    /// Build index with progress tracking and resumption support
    public func buildIndex() async throws {
        logger.info("Starting index build for: \(index.name)")

        // Phase 1: Initialize
        try await initializeBuild()

        // Phase 2: Build index in batches
        try await buildInBatches()

        // Phase 3: Finalize
        try await finalizeBuild()

        logger.info("Index build completed for: \(index.name)")
    }

    /// Continue building from previous progress
    public func resumeBuild() async throws {
        guard policy.allowResume else {
            throw RecordLayerError.invalidIndexingPolicy("Resume not allowed by policy")
        }

        logger.info("Resuming index build for: \(index.name)")

        // Check current state
        let currentState = try await stateManager.getState(indexName: index.name)
        guard currentState == .writeOnly else {
            throw RecordLayerError.invalidIndexingPolicy(
                "Cannot resume: index is in \(currentState) state, expected writeOnly"
            )
        }

        lock.withLock { state in
            state.startTime = Date()
        }

        try await buildInBatches()
        try await finalizeBuild()
    }

    /// Get detailed progress information
    public func getProgress() async throws -> IndexBuildProgress {
        let state = lock.withLock { $0 }
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let (totalBegin, totalEnd) = recordSubspace.range()

        let completionPercentage = try await rangeSet.getProgress(
            totalRange: (totalBegin, totalEnd)
        )

        return IndexBuildProgress(
            recordsScanned: state.totalRecordsScanned,
            recordsIndexed: state.totalRecordsIndexed,
            completionPercentage: completionPercentage,
            startTime: state.startTime,
            currentBatchSize: state.currentBatchSize
        )
    }

    // MARK: - Private Implementation

    private func initializeBuild() async throws {
        lock.withLock { state in
            state.startTime = Date()
            state.totalRecordsScanned = 0
            state.totalRecordsIndexed = 0
        }

        // Set index to WRITE_ONLY state
        if policy.enableWriteOnly {
            let currentState = try await stateManager.getState(indexName: index.name)
            if currentState == .disabled {
                try await stateManager.enableIndex(indexName: index.name)
                logger.info("Index enabled and set to WRITE_ONLY state")
            }
        }

        // Clear existing data if requested
        if policy.clearExisting {
            try await clearIndexData()
            try await rangeSet.clear()
            logger.info("Cleared existing index data and progress")
        }
    }

    private func buildInBatches() async throws {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let (totalBegin, totalEnd) = recordSubspace.range()

        var currentPosition = totalBegin

        while currentPosition < totalEnd {
            // Get next incomplete range
            guard let (rangeBegin, rangeEnd) = try await rangeSet.getNextIncompleteRange(
                after: currentPosition,
                totalEnd: totalEnd,
                limit: lock.withLock { $0.currentBatchSize }
            ) else {
                logger.info("No more incomplete ranges")
                break
            }

            logger.debug("Processing range: \(rangeBegin.count) bytes to \(rangeEnd.count) bytes")

            // Process this batch
            let recordsProcessed = try await processBatch(begin: rangeBegin, end: rangeEnd)

            if recordsProcessed > 0 {
                // Mark range as complete
                try await rangeSet.insertRange(begin: rangeBegin, end: rangeEnd)
                logger.debug("Marked range as complete: \(recordsProcessed) records")
            }

            // Apply throttling
            try await applyThrottle()

            currentPosition = rangeEnd

            // Log progress periodically
            let progress = try await getProgress()
            logger.info(
                "Progress: \(String(format: "%.1f", progress.completionPercentage * 100))%, " +
                "Rate: \(progress.recordsPerSecond.map { String(format: "%.0f", $0) } ?? "?") rec/sec"
            )
        }
    }

    private func processBatch(begin: FDB.Bytes, end: FDB.Bytes) async throws -> Int {
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(index.subspaceTupleKey)

        var recordsInBatch = 0
        var bytesInBatch = 0

        try await database.withRecordContext { [weak self] context in
            guard let self = self else { return }
            let transaction = context.getTransaction()
            let recordSubspace = self.subspace.subspace(RecordStoreKeyspace.record.rawValue)

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                limit: self.policy.throttle.maxRecordsPerTransaction,
                snapshot: true
            )

            for try await (key, value) in sequence {
                // Check transaction size limits
                bytesInBatch += key.count + value.count

                if bytesInBatch > self.policy.throttle.maxTransactionBytes {
                    self.logger.debug("Approaching transaction size limit, committing early")
                    break
                }

                // Deserialize and index record
                let record = try self.serializer.deserialize(value)
                let primaryKey = try recordSubspace.unpack(key)

                let maintainer = self.createIndexMaintainer(indexSubspace: indexSubspace)
                try await maintainer.scanRecord(record, primaryKey: primaryKey, transaction: transaction)

                recordsInBatch += 1

                // Check batch size limit
                if recordsInBatch >= self.policy.throttle.maxRecordsPerTransaction {
                    break
                }
            }

            // Update statistics
            self.lock.withLock { state in
                state.totalRecordsScanned += UInt64(recordsInBatch)
                state.totalRecordsIndexed += UInt64(recordsInBatch)

                // Adaptive batch sizing
                if self.policy.throttle.adaptiveBatchSize {
                    if bytesInBatch < self.policy.throttle.maxTransactionBytes / 2 {
                        // Can increase batch size
                        state.currentBatchSize = min(
                            state.currentBatchSize + 100,
                            self.policy.throttle.maxRecordsPerTransaction
                        )
                    } else if bytesInBatch > self.policy.throttle.maxTransactionBytes * 8 / 10 {
                        // Should decrease batch size
                        state.currentBatchSize = max(state.currentBatchSize - 100, 100)
                    }
                }
            }
        }

        return recordsInBatch
    }

    private func applyThrottle() async throws {
        if policy.throttle.delayBetweenTransactions > 0 {
            try await Task.sleep(
                nanoseconds: policy.throttle.delayBetweenTransactions * 1_000_000
            )
        }
    }

    private func finalizeBuild() async throws {
        lock.withLock { state in
            state.endTime = Date()
        }

        // Mark index as READABLE
        if policy.markReadableOnComplete {
            try await stateManager.markReadable(indexName: index.name)
            logger.info("Index marked as READABLE")
        }

        let progress = try await getProgress()
        logger.info(
            "Index build complete: \(progress.recordsIndexed) records indexed " +
            "in \(progress.elapsedTime.map { String(format: "%.1f", $0) } ?? "?") seconds"
        )
    }

    private func clearIndexData() async throws {
        try await database.withRecordContext { [weak self] context in
            guard let self = self else { return }
            let transaction = context.getTransaction()
            let indexSubspace = self.subspace.subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(self.index.subspaceTupleKey)

            let (begin, end) = indexSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    private func createIndexMaintainer(indexSubspace: Subspace) -> any IndexMaintainer {
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        switch index.type {
        case .value:
            return ValueIndexMaintainer(
                index: index,
                subspace: indexSubspace,
                recordSubspace: recordSubspace
            )
        case .count:
            return CountIndexMaintainer(index: index, subspace: indexSubspace)
        case .sum:
            return SumIndexMaintainer(index: index, subspace: indexSubspace)
        case .rank, .version, .permuted:
            fatalError("Index type \(index.type) not yet implemented")
        }
    }
}
```

**完了条件:**
- [ ] Build 10M records in < 2 hours
- [ ] Resume from interruption works
- [ ] Throttling keeps transactions < 9MB
- [ ] Integration tests pass
- [ ] Performance benchmarks meet targets

---

## 3. タイムライン

```
Week 0.5:  Phase 0 - Preparation
Week 1-1.5: Phase 1 - IndexStateManager
Week 2-2.5: Phase 2 - RangeSet
Week 3-4.5: Phase 3 - OnlineIndexer Enhancement
Week 5-5.5: Phase 4 - Query Optimization (Intersection)
Week 6-6.5: Phase 5 - Query Optimization (Boolean Normalization)
Week 7:    Phase 6 - Integration & Documentation

Total: 7.5 weeks
```

---

## 4. Success Criteria (詳細)

### Phase 0
- [x] Design review complete
- [ ] Deprecation warnings added
- [ ] Existing code identified for migration
- [ ] All tests pass

### Phase 1
- [ ] IndexStateManager implemented
- [ ] State transitions validated
- [ ] TypedRecordStore integration complete
- [ ] Queries respect index state
- [ ] Unit test coverage > 90%

### Phase 2
- [ ] RangeSet implemented
- [ ] Range merging works
- [ ] Progress calculation accurate
- [ ] Unit test coverage > 85%

### Phase 3
- [ ] IndexingPolicy implemented
- [ ] IndexingThrottle implemented
- [ ] OnlineIndexer refactored
- [ ] Resume functionality works
- [ ] 10M records in < 2 hours
- [ ] Integration tests pass

### Phases 4-6
- [ ] Query optimizations implemented
- [ ] Performance targets met
- [ ] Documentation complete

---

## 5. Next Steps

### Immediate (今すぐ)

1. ✅ このレビューを確認
2. ✅ IndexState定義の決定 → **Option A 採用決定**
3. ✅ 改訂版設計書の作成 → **このドキュメント**

### Short-term (今週)

4. [ ] Phase 0の実装開始
   - [ ] Add deprecation to Types.swift
   - [ ] Update OnlineIndexer
   - [ ] Run test suite

### Next Week

5. [ ] Phase 1の実装
   - [ ] Create IndexStateManager.swift
   - [ ] Write tests
   - [ ] Integrate with TypedRecordStore

---

**Status:** ✅ Ready for Implementation
**Approved by:** Pending Review
**Implementation Start:** After approval of this document

