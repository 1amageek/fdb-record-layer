# FDB Record Layer 改善設計書

## 目次

1. [概要](#概要)
2. [Index State Management](#1-index-state-management)
3. [Online Indexer 改善](#2-online-indexer-改善)
4. [Query Optimization](#3-query-optimization)
5. [実装計画](#4-実装計画)

---

## 概要

### 改善の目的

現在のFDB Record Layer実装を本番環境での大規模利用に対応させるため、以下の3つの主要領域を改善します：

1. **Index State Management** - インデックスの状態遷移を完全実装
2. **Online Indexer** - 大規模データに対応する堅牢なインデックス構築
3. **Query Optimization** - 複雑なクエリの効率的な実行

### 改善の優先順位

| 優先度 | コンポーネント | 理由 |
|--------|---------------|------|
| 🔴 P0 | Index State Management | オンラインインデックス構築の基盤 |
| 🔴 P0 | OnlineIndexer - RangeSet | 大規模データ対応に必須 |
| 🔴 P0 | OnlineIndexer - Throttling | 本番環境での安全性 |
| 🟡 P1 | IntersectionPlan | AND条件の最適化 |
| 🟡 P1 | BooleanNormalizer | OR条件の最適化 |
| 🟢 P2 | InJoinPlan | IN述語の最適化 |

---

## 1. Index State Management

### 1.1 現状の問題

**現在の実装:**
```swift
public enum IndexState: UInt8 {
    case building = 0
    case readable = 1
    case disabled = 2
}
```

**問題点:**
- `WRITE_ONLY` 状態がない
- 状態遷移のロジックがない
- オンラインでのインデックス構築ができない

### 1.2 改善設計

#### 状態定義

```swift
/// Index lifecycle states
public enum IndexState: UInt8, Sendable {
    /// Index is disabled and not being maintained
    case disabled = 0

    /// Index is being written but not yet readable
    /// - New records are indexed
    /// - Existing records are being backfilled
    /// - Queries do not use this index
    case writeOnly = 1

    /// Index is readable and can be used by queries
    case readable = 2
}
```

#### 状態遷移図

```
┌──────────┐
│ DISABLED │
└─────┬────┘
      │ enableIndex()
      ▼
┌──────────┐
│WRITE_ONLY│ ◄─── Background indexing
└─────┬────┘      in progress
      │ markReadable()
      ▼
┌──────────┐
│ READABLE │
└─────┬────┘
      │ disableIndex()
      ▼
┌──────────┐
│ DISABLED │
└──────────┘
```

#### API設計

```swift
/// Index state manager
public actor IndexStateManager {
    private let database: any DatabaseProtocol
    private let subspace: Subspace

    /// Get current index state
    public func getState(indexName: String) async throws -> IndexState

    /// Transition to WRITE_ONLY state
    /// - Enables index maintenance for new writes
    /// - Does not allow queries to use the index yet
    public func enableIndex(indexName: String) async throws

    /// Transition to READABLE state
    /// - Allows queries to use the index
    /// - Should only be called after backfill is complete
    public func markReadable(indexName: String) async throws

    /// Transition to DISABLED state
    /// - Stops index maintenance
    /// - Queries will not use this index
    public func disableIndex(indexName: String) async throws

    /// Check if index is usable for queries
    public func isReadable(indexName: String) async throws -> Bool
}
```

#### ストレージ設計

```swift
/// Subspace layout for index state
/// Key: [subspace_prefix]["index_state"][index_name]
/// Value: UInt8 (IndexState raw value)

struct IndexStateKey {
    static let prefix = "index_state"

    static func key(for indexName: String, in subspace: Subspace) -> FDB.Bytes {
        return subspace.pack(Tuple(prefix, indexName))
    }
}
```

### 1.3 TypedRecordStore との統合

```swift
extension TypedRecordStore {
    /// Execute query with index state awareness
    public func executeQuery(
        _ query: TypedRecordQuery<Record>,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Filter out non-readable indexes before planning
        let readableIndexes = try await filterReadableIndexes(indexes, context: context)

        let planner = TypedRecordQueryPlanner(
            recordType: recordType,
            indexes: readableIndexes
        )

        let plan = try planner.plan(query)

        return try await plan.execute(
            subspace: subspace,
            serializer: serializer,
            accessor: accessor,
            context: context
        )
    }

    private func filterReadableIndexes(
        _ indexes: [TypedIndex<Record>],
        context: RecordContext
    ) async throws -> [TypedIndex<Record>] {
        let stateManager = IndexStateManager(database: database, subspace: subspace)

        var readableIndexes: [TypedIndex<Record>] = []
        for index in indexes {
            let state = try await stateManager.getState(indexName: index.name)
            if state == .readable {
                readableIndexes.append(index)
            }
        }
        return readableIndexes
    }
}
```

---

## 2. Online Indexer 改善

### 2.1 現状の問題

**現在の実装:**
```swift
public func buildIndex() async throws {
    // ✗ 単一トランザクションでスキャン
    // ✗ 進捗保存なし → 中断したら最初から
    // ✗ スロットリングなし → 本番環境で負荷大
    // ✗ バッチサイズ固定
}
```

**問題点:**
1. 大規模データで実行不可（トランザクションタイムアウト）
2. 中断からの再開ができない
3. 本番環境で負荷が高すぎる
4. 並行実行のサポートなし

### 2.2 改善設計

#### 2.2.1 RangeSet - 進捗管理

```swift
/// Tracks which ranges have been indexed
/// Allows resumption from interruption
public actor RangeSet: Sendable {
    private let database: any DatabaseProtocol
    private let subspace: Subspace

    /// Mark a range as complete
    /// - Parameters:
    ///   - begin: Start of range (inclusive)
    ///   - end: End of range (exclusive)
    public func insertRange(begin: FDB.Bytes, end: FDB.Bytes) async throws

    /// Check if a range has been completed
    public func contains(begin: FDB.Bytes, end: FDB.Bytes) async throws -> Bool

    /// Get the next incomplete range to process
    /// - Returns: (begin, end) tuple or nil if all complete
    public func getNextIncompleteRange(
        after: FDB.Bytes,
        limit: Int
    ) async throws -> (begin: FDB.Bytes, end: FDB.Bytes)?

    /// Clear all progress (restart indexing)
    public func clear() async throws

    /// Get completion percentage
    public func getProgress(totalRange: (FDB.Bytes, FDB.Bytes)) async throws -> Double
}
```

**RangeSet ストレージ設計:**

```
Key:   [subspace]["range_set"][index_name][begin_key]
Value: [end_key]

Example:
[prefix]["range_set"]["email_index"]["user:0000"] = "user:1000"
[prefix]["range_set"]["email_index"]["user:1000"] = "user:2000"
[prefix]["range_set"]["email_index"]["user:2000"] = "user:3000"

→ Indexed ranges: [0-1000), [1000-2000), [2000-3000)
→ Next incomplete: [3000-...)
```

#### 2.2.2 Throttling - レート制限

```swift
/// Controls indexing rate to minimize production impact
public struct IndexingThrottle: Sendable {
    /// Maximum records per transaction
    public let maxRecordsPerTransaction: Int

    /// Delay between transactions (milliseconds)
    public let delayBetweenTransactions: UInt64

    /// Maximum transaction size (bytes)
    public let maxTransactionBytes: Int

    /// Adaptive batch sizing
    public let adaptiveBatchSize: Bool

    public static let `default` = IndexingThrottle(
        maxRecordsPerTransaction: 1000,
        delayBetweenTransactions: 10,
        maxTransactionBytes: 9_000_000, // 9MB (留有余地)
        adaptiveBatchSize: true
    )

    public static let aggressive = IndexingThrottle(
        maxRecordsPerTransaction: 5000,
        delayBetweenTransactions: 0,
        maxTransactionBytes: 9_000_000,
        adaptiveBatchSize: true
    )

    public static let conservative = IndexingThrottle(
        maxRecordsPerTransaction: 100,
        delayBetweenTransactions: 100,
        maxTransactionBytes: 1_000_000,
        adaptiveBatchSize: false
    )
}
```

#### 2.2.3 IndexingPolicy - 構築ポリシー

```swift
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

    public static let `default` = IndexingPolicy(
        clearExisting: true,
        enableWriteOnly: true,
        markReadableOnComplete: true,
        allowResume: true,
        throttle: .default
    )

    public static let resume = IndexingPolicy(
        clearExisting: false,
        enableWriteOnly: false,
        markReadableOnComplete: true,
        allowResume: true,
        throttle: .default
    )
}
```

#### 2.2.4 改善された OnlineIndexer

```swift
public final class OnlineIndexer: Sendable {
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
        try await buildInBatches()
        try await finalizeBuild()
    }

    /// Get detailed progress information
    public func getProgress() async throws -> IndexBuildProgress {
        let state = lock.withLock { $0 }
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let totalRange = recordSubspace.range()

        let completionPercentage = try await rangeSet.getProgress(totalRange: totalRange)

        return IndexBuildProgress(
            recordsScanned: state.totalRecordsScanned,
            recordsIndexed: state.totalRecordsIndexed,
            completionPercentage: completionPercentage,
            startTime: state.startTime,
            elapsedTime: state.startTime.map { Date().timeIntervalSince($0) }
        )
    }

    // MARK: - Private Implementation

    private func initializeBuild() async throws {
        lock.withLock { state in
            state.startTime = Date()
            state.currentBatchSize = policy.throttle.maxRecordsPerTransaction
        }

        // Set index to WRITE_ONLY state
        if policy.enableWriteOnly {
            try await stateManager.enableIndex(indexName: index.name)
        }

        // Clear existing data if requested
        if policy.clearExisting {
            try await clearIndexData()
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
                limit: lock.withLock { $0.currentBatchSize }
            ) else {
                // Check if there are any remaining records
                if currentPosition < totalEnd {
                    try await processBatch(begin: currentPosition, end: totalEnd)
                }
                break
            }

            // Process this batch
            try await processBatch(begin: rangeBegin, end: rangeEnd)

            // Mark range as complete
            try await rangeSet.insertRange(begin: rangeBegin, end: rangeEnd)

            // Apply throttling
            try await applyThrottle()

            currentPosition = rangeEnd
        }
    }

    private func processBatch(begin: FDB.Bytes, end: FDB.Bytes) async throws {
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
                snapshot: true
            )

            for try await (key, value) in sequence {
                // Check transaction size limits
                bytesInBatch += key.count + value.count
                if bytesInBatch > self.policy.throttle.maxTransactionBytes {
                    logger.warning("Approaching transaction size limit, committing early")
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
                        // Increase batch size
                        state.currentBatchSize = min(
                            state.currentBatchSize + 100,
                            self.policy.throttle.maxRecordsPerTransaction
                        )
                    } else if bytesInBatch > self.policy.throttle.maxTransactionBytes * 8 / 10 {
                        // Decrease batch size
                        state.currentBatchSize = max(state.currentBatchSize - 100, 100)
                    }
                }
            }
        }

        logger.debug("Processed batch: \(recordsInBatch) records, \(bytesInBatch) bytes")
    }

    private func applyThrottle() async throws {
        if policy.throttle.delayBetweenTransactions > 0 {
            try await Task.sleep(nanoseconds: policy.throttle.delayBetweenTransactions * 1_000_000)
        }
    }

    private func finalizeBuild() async throws {
        lock.withLock { state in
            state.endTime = Date()
        }

        // Mark index as READABLE
        if policy.markReadableOnComplete {
            try await stateManager.markReadable(indexName: index.name)
        }

        let progress = try await getProgress()
        logger.info("Index build complete: \(progress.recordsIndexed) records indexed")
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
        // Same as before...
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

/// Progress information for index building
public struct IndexBuildProgress: Sendable {
    public let recordsScanned: UInt64
    public let recordsIndexed: UInt64
    public let completionPercentage: Double
    public let startTime: Date?
    public let elapsedTime: TimeInterval?

    public var estimatedTimeRemaining: TimeInterval? {
        guard let elapsed = elapsedTime, completionPercentage > 0 else {
            return nil
        }
        let totalEstimated = elapsed / completionPercentage
        return totalEstimated - elapsed
    }
}
```

---

## 3. Query Optimization

### 3.1 IntersectionPlan - AND条件の最適化

#### 3.1.1 現状の問題

```swift
// 現在: AND条件で最初のインデックスしか使わない
query.filter(.and([
    .field("age", .greaterThan(18)),    // age_index を使用
    .field("city", .equals("Tokyo"))    // フィルタリングで処理（非効率）
]))

// 改善後: 両方のインデックスを使って交差
// age_index で age > 18 を取得
// city_index で city = 'Tokyo' を取得
// 両方に存在するレコードのみ返す
```

#### 3.1.2 設計

```swift
/// Intersection plan - uses multiple indexes and intersects results
public struct TypedIntersectionPlan<Record: Sendable>: TypedQueryPlan {
    public let children: [any TypedQueryPlan<Record>]
    public let comparisonKey: [String] // Fields to compare for intersection

    public init(
        children: [any TypedQueryPlan<Record>],
        comparisonKey: [String]
    ) {
        self.children = children
        self.comparisonKey = comparisonKey
    }

    public func execute<A: FieldAccessor, S: RecordSerializer>(
        subspace: Subspace,
        serializer: S,
        accessor: A,
        context: RecordContext
    ) async throws -> AnyTypedRecordCursor<Record>
    where A.Record == Record, S.Record == Record {
        // Execute all child plans
        var cursors: [AnyTypedRecordCursor<Record>] = []
        for child in children {
            let cursor = try await child.execute(
                subspace: subspace,
                serializer: serializer,
                accessor: accessor,
                context: context
            )
            cursors.append(cursor)
        }

        // Create intersection cursor
        let intersectionCursor = IntersectionCursor(
            cursors: cursors,
            accessor: accessor,
            comparisonKey: comparisonKey
        )

        return AnyTypedRecordCursor(intersectionCursor)
    }
}

/// Cursor that performs intersection of multiple sorted cursors
private struct IntersectionCursor<Record: Sendable, A: FieldAccessor>: TypedRecordCursor
where A.Record == Record {
    typealias Element = Record

    let cursors: [AnyTypedRecordCursor<Record>]
    let accessor: A
    let comparisonKey: [String]

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterators: [AnyTypedRecordCursor<Record>.AsyncIterator]
        let accessor: A
        let comparisonKey: [String]

        // Current candidates from each cursor
        var candidates: [Record?]

        mutating func next() async throws -> Record? {
            // Initialize candidates if needed
            if candidates.isEmpty {
                candidates = try await iterators.indices.map { i in
                    try await iterators[i].next()
                }
            }

            while true {
                // Check if any cursor is exhausted
                if candidates.contains(where: { $0 == nil }) {
                    return nil
                }

                // Extract comparison values
                let comparisonValues = try candidates.map { record -> [any TupleElement] in
                    guard let record = record else { throw RecordLayerError.internalError("Unexpected nil") }
                    return comparisonKey.map { fieldName in
                        accessor.getValue(from: record, field: fieldName)
                    }
                }

                // Check if all values are equal
                if allEqual(comparisonValues) {
                    // Found intersection, advance all cursors
                    let result = candidates[0]!

                    for i in candidates.indices {
                        candidates[i] = try await iterators[i].next()
                    }

                    return result
                } else {
                    // Advance the cursor with the smallest value
                    let minIndex = findMinIndex(comparisonValues)
                    candidates[minIndex] = try await iterators[minIndex].next()
                }
            }
        }

        private func allEqual(_ values: [[any TupleElement]]) -> Bool {
            guard let first = values.first else { return false }
            return values.allSatisfy { compareValues($0, first) == 0 }
        }

        private func findMinIndex(_ values: [[any TupleElement]]) -> Int {
            var minIndex = 0
            for i in 1..<values.count {
                if compareValues(values[i], values[minIndex]) < 0 {
                    minIndex = i
                }
            }
            return minIndex
        }

        private func compareValues(_ lhs: [any TupleElement], _ rhs: [any TupleElement]) -> Int {
            // Simplified comparison
            // In real implementation, use proper Tuple comparison
            for (l, r) in zip(lhs, rhs) {
                if let li = l as? Int64, let ri = r as? Int64 {
                    if li < ri { return -1 }
                    if li > ri { return 1 }
                } else if let ls = l as? String, let rs = r as? String {
                    if ls < rs { return -1 }
                    if ls > rs { return 1 }
                }
            }
            return 0
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            iterators: cursors.map { $0.makeAsyncIterator() },
            accessor: accessor,
            comparisonKey: comparisonKey,
            candidates: []
        )
    }
}
```

#### 3.1.3 Planner統合

```swift
extension TypedRecordQueryPlanner {
    private func planIntersection(filter: TypedAndQueryComponent<Record>) throws -> (any TypedQueryPlan<Record>)? {
        // Try to find index scans for each child
        var childPlans: [any TypedQueryPlan<Record>] = []

        for child in filter.children {
            if let indexPlan = try? planIndexScan(filter: child) {
                childPlans.append(indexPlan)
            }
        }

        // If we found multiple index scans, use intersection
        if childPlans.count >= 2 {
            return TypedIntersectionPlan(
                children: childPlans,
                comparisonKey: recordType.primaryKey.fieldNames
            )
        }

        return nil
    }
}
```

### 3.2 BooleanNormalizer - OR条件の正規化

#### 3.2.1 DNF変換

```swift
/// Converts boolean expressions to Disjunctive Normal Form (DNF)
/// DNF: OR of ANDs - (A AND B) OR (C AND D)
public struct BooleanNormalizer<Record: Sendable> {

    /// Normalize a filter to DNF
    public static func normalize(_ filter: any TypedQueryComponent<Record>) -> any TypedQueryComponent<Record> {
        // Step 1: Push NOT down (De Morgan's laws)
        let pushed = pushNotDown(filter)

        // Step 2: Convert to DNF
        let dnf = convertToDNF(pushed)

        // Step 3: Simplify
        return simplify(dnf)
    }

    private static func pushNotDown(_ filter: any TypedQueryComponent<Record>) -> any TypedQueryComponent<Record> {
        // NOT (A AND B) → (NOT A) OR (NOT B)
        // NOT (A OR B) → (NOT A) AND (NOT B)
        // NOT (NOT A) → A

        if let notFilter = filter as? TypedNotQueryComponent<Record> {
            let inner = notFilter.child

            if let andFilter = inner as? TypedAndQueryComponent<Record> {
                // NOT (A AND B) → (NOT A) OR (NOT B)
                let negatedChildren = andFilter.children.map {
                    TypedNotQueryComponent(child: $0)
                }
                return TypedOrQueryComponent(children: negatedChildren)
            } else if let orFilter = inner as? TypedOrQueryComponent<Record> {
                // NOT (A OR B) → (NOT A) AND (NOT B)
                let negatedChildren = orFilter.children.map {
                    TypedNotQueryComponent(child: $0)
                }
                return TypedAndQueryComponent(children: negatedChildren)
            } else if let doubleNot = inner as? TypedNotQueryComponent<Record> {
                // NOT (NOT A) → A
                return doubleNot.child
            }
        }

        return filter
    }

    private static func convertToDNF(_ filter: any TypedQueryComponent<Record>) -> any TypedQueryComponent<Record> {
        // Convert to DNF using distributive law:
        // A AND (B OR C) → (A AND B) OR (A AND C)

        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // Check if any child is an OR
            for (index, child) in andFilter.children.enumerated() {
                if let orChild = child as? TypedOrQueryComponent<Record> {
                    // Distribute: A AND (B OR C) → (A AND B) OR (A AND C)
                    var otherChildren = andFilter.children
                    otherChildren.remove(at: index)

                    let distributed = orChild.children.map { orTerm in
                        var newAnd = otherChildren
                        newAnd.append(orTerm)
                        return TypedAndQueryComponent(children: newAnd)
                    }

                    return TypedOrQueryComponent(children: distributed)
                }
            }
        }

        return filter
    }

    private static func simplify(_ filter: any TypedQueryComponent<Record>) -> any TypedQueryComponent<Record> {
        // Remove redundant conditions
        // Flatten nested ORs and ANDs

        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            var simplified: [any TypedQueryComponent<Record>] = []

            for child in orFilter.children {
                if let nestedOr = child as? TypedOrQueryComponent<Record> {
                    // Flatten: (A OR B) OR C → A OR B OR C
                    simplified.append(contentsOf: nestedOr.children)
                } else {
                    simplified.append(child)
                }
            }

            return TypedOrQueryComponent(children: simplified)
        }

        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            var simplified: [any TypedQueryComponent<Record>] = []

            for child in andFilter.children {
                if let nestedAnd = child as? TypedAndQueryComponent<Record> {
                    // Flatten: (A AND B) AND C → A AND B AND C
                    simplified.append(contentsOf: nestedAnd.children)
                } else {
                    simplified.append(child)
                }
            }

            return TypedAndQueryComponent(children: simplified)
        }

        return filter
    }
}
```

#### 3.2.2 NOT コンポーネント

```swift
/// NOT query component
public struct TypedNotQueryComponent<Record: Sendable>: TypedQueryComponent {
    public let child: any TypedQueryComponent<Record>

    public init(child: any TypedQueryComponent<Record>) {
        self.child = child
    }

    public func matches(record: Record, accessor: any FieldAccessor<Record>) -> Bool {
        return !child.matches(record: record, accessor: accessor)
    }
}
```

#### 3.2.3 Planner統合

```swift
extension TypedRecordQueryPlanner {
    public func plan(_ query: TypedRecordQuery<Record>) throws -> any TypedQueryPlan<Record> {
        var basePlan: any TypedQueryPlan<Record>

        // Normalize filter if present
        let normalizedFilter = query.filter.map { filter in
            BooleanNormalizer.normalize(filter)
        }

        // After normalization, we have DNF: (A AND B) OR (C AND D) OR ...
        if let orFilter = normalizedFilter as? TypedOrQueryComponent<Record> {
            // Plan each AND clause separately
            var unionChildren: [any TypedQueryPlan<Record>] = []

            for orTerm in orFilter.children {
                if let andTerm = orTerm as? TypedAndQueryComponent<Record> {
                    // Try intersection plan
                    if let intersectionPlan = try? planIntersection(filter: andTerm) {
                        unionChildren.append(intersectionPlan)
                    } else if let indexPlan = try? planIndexScan(filter: orTerm) {
                        unionChildren.append(indexPlan)
                    } else {
                        unionChildren.append(TypedFullScanPlan(filter: orTerm))
                    }
                } else {
                    // Single condition
                    if let indexPlan = try? planIndexScan(filter: orTerm) {
                        unionChildren.append(indexPlan)
                    } else {
                        unionChildren.append(TypedFullScanPlan(filter: orTerm))
                    }
                }
            }

            // Union all the plans
            basePlan = TypedUnionPlan(children: unionChildren)
        } else if let andFilter = normalizedFilter as? TypedAndQueryComponent<Record> {
            // Try intersection plan
            if let intersectionPlan = try? planIntersection(filter: andFilter) {
                basePlan = intersectionPlan
            } else if let indexPlan = try? planIndexScan(filter: andFilter) {
                basePlan = indexPlan
            } else {
                basePlan = TypedFullScanPlan(filter: andFilter)
            }
        } else if let filter = normalizedFilter,
                  let indexPlan = try? planIndexScan(filter: filter) {
            basePlan = indexPlan
        } else {
            basePlan = TypedFullScanPlan(filter: normalizedFilter)
        }

        // Apply limit
        if let limit = query.limit {
            basePlan = TypedLimitPlan(child: basePlan, limit: limit)
        }

        return basePlan
    }
}
```

---

## 4. 実装計画

### 4.1 Phase 1: Index State Management (Week 1)

**タスク:**
- [ ] `IndexState` enum の拡張
- [ ] `IndexStateManager` actor の実装
- [ ] `TypedRecordStore` の統合
- [ ] Unit tests

**成果物:**
- `Sources/FDBRecordLayer/Core/IndexState.swift`
- `Sources/FDBRecordLayer/Index/IndexStateManager.swift`
- `Tests/FDBRecordLayerTests/IndexStateTests.swift`

**検証:**
```swift
// Test: State transitions
let manager = IndexStateManager(database: db, subspace: subspace)
try await manager.enableIndex(indexName: "test_index")
let state = try await manager.getState(indexName: "test_index")
XCTAssertEqual(state, .writeOnly)

try await manager.markReadable(indexName: "test_index")
let readableState = try await manager.getState(indexName: "test_index")
XCTAssertEqual(readableState, .readable)
```

### 4.2 Phase 2: RangeSet (Week 2)

**タスク:**
- [ ] `RangeSet` actor の実装
- [ ] ストレージレイアウトの設計
- [ ] Range merging logic
- [ ] Unit tests

**成果物:**
- `Sources/FDBRecordLayer/Index/RangeSet.swift`
- `Tests/FDBRecordLayerTests/RangeSetTests.swift`

**検証:**
```swift
// Test: Range tracking
let rangeSet = RangeSet(database: db, subspace: subspace, indexName: "test")
try await rangeSet.insertRange(begin: key1, end: key2)
let contains = try await rangeSet.contains(begin: key1, end: key2)
XCTAssertTrue(contains)

let next = try await rangeSet.getNextIncompleteRange(after: key2, limit: 1000)
XCTAssertNotNil(next)
```

### 4.3 Phase 3: OnlineIndexer 改善 (Week 3-4)

**タスク:**
- [ ] `IndexingPolicy` struct の実装
- [ ] `IndexingThrottle` struct の実装
- [ ] `OnlineIndexer` のリファクタリング
- [ ] Progress tracking の実装
- [ ] Integration tests

**成果物:**
- `Sources/FDBRecordLayer/Index/IndexingPolicy.swift`
- `Sources/FDBRecordLayer/Index/OnlineIndexer.swift` (改善版)
- `Tests/FDBRecordLayerTests/OnlineIndexerTests.swift`

**検証:**
```swift
// Test: Large dataset indexing with throttling
let indexer = OnlineIndexer(
    database: db,
    subspace: subspace,
    metaData: metadata,
    index: index,
    serializer: serializer,
    policy: .default
)

try await indexer.buildIndex()
let progress = try await indexer.getProgress()
XCTAssertEqual(progress.completionPercentage, 1.0)

// Test: Resume from interruption
let indexer2 = OnlineIndexer(/* same config */, policy: .resume)
try await indexer2.resumeBuild()
```

### 4.4 Phase 4: Query Optimization - Intersection (Week 5)

**タスク:**
- [ ] `TypedIntersectionPlan` の実装
- [ ] `IntersectionCursor` の実装
- [ ] Planner統合
- [ ] Performance tests

**成果物:**
- `Sources/FDBRecordLayer/Query/TypedQueryPlan.swift` (更新)
- `Tests/FDBRecordLayerTests/IntersectionPlanTests.swift`

**検証:**
```swift
// Test: AND query uses intersection
let query = TypedRecordQuery<User>()
    .filter(.and([
        .field("age", .greaterThan(18)),
        .field("city", .equals("Tokyo"))
    ]))

let plan = try planner.plan(query)
XCTAssertTrue(plan is TypedIntersectionPlan<User>)
```

### 4.5 Phase 5: Query Optimization - Boolean Normalization (Week 6)

**タスク:**
- [ ] `BooleanNormalizer` の実装
- [ ] `TypedNotQueryComponent` の実装
- [ ] DNF conversion logic
- [ ] Planner統合
- [ ] Unit tests

**成果物:**
- `Sources/FDBRecordLayer/Query/BooleanNormalizer.swift`
- `Sources/FDBRecordLayer/Query/TypedQueryComponent.swift` (更新)
- `Tests/FDBRecordLayerTests/BooleanNormalizerTests.swift`

**検証:**
```swift
// Test: OR query uses union of index scans
let query = TypedRecordQuery<User>()
    .filter(.or([
        .field("city", .equals("Tokyo")),
        .field("city", .equals("Osaka"))
    ]))

let plan = try planner.plan(query)
XCTAssertTrue(plan is TypedUnionPlan<User>)
```

### 4.6 Phase 6: Integration & Documentation (Week 7)

**タスク:**
- [ ] End-to-end integration tests
- [ ] Performance benchmarks
- [ ] API documentation
- [ ] Usage examples
- [ ] Migration guide

**成果物:**
- `Tests/FDBRecordLayerTests/IntegrationTests.swift`
- `Examples/` directory
- `MIGRATION.md`
- Updated `README.md`

### 4.7 タイムライン

```
Week 1: Index State Management
Week 2: RangeSet
Week 3-4: OnlineIndexer改善
Week 5: IntersectionPlan
Week 6: BooleanNormalizer
Week 7: Integration & Documentation

Total: 7 weeks
```

### 4.8 成功基準

#### 機能要件

- [ ] インデックス状態管理が完全に動作
- [ ] 1000万レコードのインデックス構築が安全に完了
- [ ] 中断からの再開が正常に動作
- [ ] AND/OR条件がインデックスを活用して最適化
- [ ] スロットリングが本番環境で機能

#### パフォーマンス要件

- [ ] 1000万レコードのインデックス構築が2時間以内
- [ ] AND条件クエリが10倍以上高速化
- [ ] OR条件クエリがフルスキャンより高速

#### 品質要件

- [ ] Unit test coverage > 80%
- [ ] Integration tests すべてパス
- [ ] Zero compilation warnings
- [ ] API documentation 100%

---

## 5. リスクと軽減策

### 5.1 技術的リスク

| リスク | 影響 | 確率 | 軽減策 |
|--------|------|------|--------|
| RangeSet のパフォーマンス | 高 | 中 | 早期プロトタイプとベンチマーク |
| Intersection の正確性 | 高 | 中 | 徹底的な Unit tests |
| Throttling の効果不足 | 中 | 低 | 本番環境テストと調整 |

### 5.2 スケジュールリスク

| リスク | 影響 | 確率 | 軽減策 |
|--------|------|------|--------|
| OnlineIndexer 実装の遅延 | 高 | 中 | Phase分割、早期着手 |
| テストケース作成の遅延 | 中 | 低 | TDD approach |

---

## 6. 次のステップ

1. **レビュー**: この設計ドキュメントをレビュー
2. **承認**: 実装アプローチの承認
3. **実装開始**: Phase 1 から順次実装

---

## Appendix A: API Examples

### Example 1: Building an Index Online

```swift
import FDBRecordLayer

// Define your record type
struct User: Codable, Sendable {
    let id: Int64
    let email: String
    let age: Int
    let city: String
}

// Setup
let database = try FDBClient.openDatabase()
let subspace = Subspace(prefix: "myapp")

// Create index
let emailIndex = TypedIndex(
    name: "email_index",
    type: .value,
    rootExpression: TypedFieldKeyExpression(fieldName: "email")
)

// Build index online with throttling
let indexer = OnlineIndexer(
    database: database,
    subspace: subspace,
    metaData: metadata,
    index: emailIndex,
    serializer: ProtobufSerializer(),
    policy: IndexingPolicy(
        clearExisting: true,
        enableWriteOnly: true,
        markReadableOnComplete: true,
        allowResume: true,
        throttle: IndexingThrottle.conservative  // Safe for production
    )
)

// Monitor progress
Task {
    while true {
        let progress = try await indexer.getProgress()
        print("Progress: \(progress.completionPercentage * 100)%")
        print("Estimated time remaining: \(progress.estimatedTimeRemaining ?? 0)s")
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
    }
}

// Build
try await indexer.buildIndex()
print("Index build complete!")
```

### Example 2: Optimized Queries

```swift
// Complex query with AND condition
let query = TypedRecordQuery<User>()
    .filter(.and([
        .field("age", .greaterThan(18)),
        .field("city", .equals("Tokyo"))
    ]))

// Planner automatically uses intersection of indexes
let results = try await store.queryRecords(query, context: context)
// → Uses age_index ∩ city_index

// OR query
let orQuery = TypedRecordQuery<User>()
    .filter(.or([
        .field("city", .equals("Tokyo")),
        .field("city", .equals("Osaka"))
    ]))

// Planner automatically uses union of index scans
let orResults = try await store.queryRecords(orQuery, context: context)
// → Uses city_index(Tokyo) ∪ city_index(Osaka)
```

### Example 3: Resuming Interrupted Index Build

```swift
// Start building
let indexer = OnlineIndexer(/* config */, policy: .default)

do {
    try await indexer.buildIndex()
} catch {
    print("Build interrupted: \(error)")
    // Progress is saved in RangeSet
}

// Later, resume from where we left off
let resumeIndexer = OnlineIndexer(/* same config */, policy: .resume)
try await resumeIndexer.resumeBuild()  // Continues from saved progress
print("Build completed!")
```

---

**Document Version:** 1.0
**Last Updated:** 2025-01-31
**Status:** Draft for Review
