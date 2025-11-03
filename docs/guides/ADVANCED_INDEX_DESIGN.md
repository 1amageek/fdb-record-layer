# Advanced Index Types Design Document

## Overview

This document provides comprehensive design specifications for three advanced index types:
1. **Version Index**: Optimistic locking and record versioning
2. **Permuted Index**: Multi-ordering compound indexes
3. **Rank Index**: Leaderboard and ranking functionality

---

## 1. Version Index Design

### 1.1 Purpose

Provide automatic versioning for records with optimistic concurrency control (OCC) to prevent lost updates in concurrent environments.

### 1.2 Use Cases

- Document editing systems (Google Docs-style)
- Wiki systems with revision history
- CMS content management
- Distributed optimistic locking
- Audit trails

### 1.3 Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    RecordStore                          │
│  save(record, expectedVersion: Version?)                │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│              VersionIndexMaintainer                      │
│  - updateIndex()                                         │
│  - scanRecord()                                          │
│  - checkVersion()                                        │
│  - generateVersion()                                     │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│                FDB Versionstamp                          │
│  - 10 bytes: transaction version                        │
│  - 2 bytes: batch order                                 │
│  - Assigned atomically at commit time                   │
└─────────────────────────────────────────────────────────┘
```

### 1.4 Data Model

#### Key Structure

```
Version Index Key:
  [index_subspace] + [primary_key] + [versionstamp]

Example:
  [version_idx][user:123][0x0000000000000001ABCD]
  ├─ index_subspace: "version_idx"
  ├─ primary_key: "user:123"
  └─ versionstamp: 12-byte unique version
```

#### Value Structure

```
Version Index Value:
  Empty (all data in key)

Record Metadata:
  Stored in record itself:
  {
    "_version": <versionstamp bytes>,
    "user_id": 123,
    "name": "Alice",
    ...
  }
```

### 1.5 API Design

```swift
// 1. Version Index Definition
let versionIndex = Index(
    name: "document_version",
    type: .version,
    rootExpression: EmptyKeyExpression(),  // Version entire record
    options: IndexOptions(
        versionField: "_version",           // Field to store version
        versionHistory: .keepLast(10)       // Keep last 10 versions
    )
)

// 2. Optimistic Locking
try await database.withRecordContext { context in
    // Load record with current version
    let (document, currentVersion) = try await recordStore.loadWithVersion(
        primaryKey: Tuple("doc_123"),
        context: context
    )

    // Modify document
    var updated = document
    updated["content"] = "New content"

    // Save with version check
    try await recordStore.save(
        updated,
        expectedVersion: currentVersion,  // Will throw if version changed
        context: context
    )
}
// Throws: RecordLayerError.versionMismatch if concurrent update detected

// 3. Version History Query
try await database.withRecordContext { context in
    // Get all versions of a record
    let versions = try await recordStore.loadVersionHistory(
        primaryKey: Tuple("doc_123"),
        context: context
    )
    // Returns: [(version: Version, record: Document)]

    // Get specific version
    let historicalDoc = try await recordStore.loadVersion(
        primaryKey: Tuple("doc_123"),
        version: specificVersion,
        context: context
    )

    // Get version range
    let recentVersions = try await recordStore.queryVersionRange(
        primaryKey: Tuple("doc_123"),
        fromVersion: v90,
        toVersion: v100,
        context: context
    )
}

// 4. Auto-versioning (no expected version)
try await database.withRecordContext { context in
    // Automatically assigns new version on save
    try await recordStore.save(newDocument, context: context)
    // Version is assigned at commit time via Versionstamp
}
```

### 1.6 Implementation Details

#### VersionIndexMaintainer

```swift
public struct VersionIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace
    private let versionField: String

    // Main operations
    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // 1. Check expected version if provided
        if let expectedVersion = transaction.expectedVersion {
            try await checkVersion(
                primaryKey: extractPrimaryKey(newRecord ?? oldRecord),
                expectedVersion: expectedVersion,
                transaction: transaction
            )
        }

        // 2. Generate new versionstamp
        let versionstampKey = try buildVersionIndexKey(
            record: newRecord ?? oldRecord!,
            useIncompleteVersionstamp: true  // FDB will fill at commit
        )

        // 3. Store version entry
        transaction.setVersionstampedKey(versionstampKey, value: FDB.Bytes())

        // 4. Update record with version field placeholder
        // (FDB will replace with actual versionstamp at commit)
    }

    private func checkVersion(
        primaryKey: Tuple,
        expectedVersion: Version,
        transaction: any TransactionProtocol
    ) async throws {
        // Get current version from index
        let currentVersion = try await getCurrentVersion(
            primaryKey: primaryKey,
            transaction: transaction
        )

        guard currentVersion == expectedVersion else {
            throw RecordLayerError.versionMismatch(
                expected: expectedVersion,
                actual: currentVersion
            )
        }
    }

    private func buildVersionIndexKey(
        record: [String: Any],
        useIncompleteVersionstamp: Bool
    ) throws -> FDB.Bytes {
        let primaryKey = extractPrimaryKey(record)
        let pkTuple = TupleHelpers.toTuple(primaryKey)

        // Build key with versionstamp placeholder
        var key = subspace.pack(pkTuple)

        if useIncompleteVersionstamp {
            // Append incomplete versionstamp (10 bytes 0xFF + 2 bytes for position)
            key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))
            key.append(contentsOf: [0x00, 0x00])  // Batch order
        }

        return key
    }
}
```

#### Version Struct

```swift
/// Represents a record version (FDB Versionstamp)
public struct Version: Sendable, Comparable, Hashable {
    public let bytes: FDB.Bytes  // 12 bytes

    public init(bytes: FDB.Bytes) {
        precondition(bytes.count == 12, "Version must be 12 bytes")
        self.bytes = bytes
    }

    // Compare versions lexicographically
    public static func < (lhs: Version, rhs: Version) -> Bool {
        return lhs.bytes.lexicographicallyCompares(rhs.bytes)
    }

    // Parse from versionstamp bytes
    public static func fromVersionstamp(_ bytes: FDB.Bytes) -> Version {
        return Version(bytes: bytes)
    }
}
```

### 1.7 FDB Integration

#### Versionstamp Operations

```swift
extension TransactionProtocol {
    /// Set value with versionstamp in key
    func setVersionstampedKey(_ key: FDB.Bytes, value: FDB.Bytes) {
        // FDB C API: fdb_transaction_set_versionstamped_key()
        // Key must contain incomplete versionstamp (0xFF bytes + position)
    }

    /// Set value with versionstamp in value
    func setVersionstampedValue(key: FDB.Bytes, _ value: FDB.Bytes) {
        // FDB C API: fdb_transaction_set_versionstamped_value()
    }

    /// Get committed version after transaction commit
    func getVersionstamp() async throws -> FDB.Bytes {
        // FDB C API: fdb_transaction_get_versionstamp()
        // Only valid after successful commit
    }
}
```

### 1.8 Version History Management

#### Strategy Options

```swift
public enum VersionHistoryStrategy: Sendable {
    case keepAll                    // Keep all versions (unlimited)
    case keepLast(Int)             // Keep last N versions
    case keepForDuration(TimeInterval)  // Keep versions for X seconds
    case custom((Version) -> Bool) // Custom retention predicate
}
```

#### Cleanup Implementation

```swift
actor VersionHistoryManager {
    private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let strategy: VersionHistoryStrategy

    /// Cleanup old versions based on strategy
    func cleanup(primaryKey: Tuple) async throws {
        switch strategy {
        case .keepLast(let count):
            try await keepLastNVersions(primaryKey: primaryKey, count: count)
        case .keepForDuration(let duration):
            try await keepVersionsForDuration(primaryKey: primaryKey, duration: duration)
        case .keepAll:
            return  // No cleanup
        case .custom(let predicate):
            try await cleanupCustom(primaryKey: primaryKey, predicate: predicate)
        }
    }

    private func keepLastNVersions(primaryKey: Tuple, count: Int) async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            // Get all versions for this primary key
            let versions = try await getAllVersions(primaryKey: primaryKey, transaction: transaction)

            // Keep only last N
            let toDelete = versions.dropLast(count)

            for version in toDelete {
                let key = buildVersionKey(primaryKey: primaryKey, version: version)
                transaction.clear(key: key)
            }
        }
    }
}
```

### 1.9 Error Handling

```swift
extension RecordLayerError {
    /// Version mismatch during optimistic lock check
    case versionMismatch(expected: Version, actual: Version)

    /// Version not found (deleted or never existed)
    case versionNotFound(version: Version)

    /// Invalid version format
    case invalidVersion(message: String)
}
```

### 1.10 Testing Strategy

```swift
@Suite("Version Index Tests")
struct VersionIndexTests {
    @Test("Auto-versioning assigns unique versions")
    func autoVersioning() async throws { }

    @Test("Optimistic locking detects concurrent updates")
    func optimisticLocking() async throws { }

    @Test("Version history retrieves all versions")
    func versionHistory() async throws { }

    @Test("Cleanup strategy removes old versions")
    func cleanupStrategy() async throws { }

    @Test("Versionstamp ordering is monotonic")
    func versionstampOrdering() async throws { }
}
```

---

## 2. Permuted Index Design

### 2.1 Purpose

Enable efficient querying on compound indexes with different field orderings without duplicating all data.

### 2.2 Use Cases

- Multi-dimensional data queries
- Dashboard with multiple sort orders
- Search engines with compound indexes
- Time-series data with various access patterns

### 2.3 Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Query Planner                           │
│  - Selects optimal permutation for query                │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│            Permuted Index Selector                       │
│  - Matches query filter to permutation                  │
│  - Estimates cost for each permutation                  │
└──────────────────┬──────────────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
┌─────────────┐      ┌─────────────────┐
│ Base Index  │      │ Permuted Index  │
│ (city, age) │      │ (age, city)     │
│ Full Data   │      │ Primary Key Only│
└─────────────┘      └─────────────────┘
```

### 2.4 Data Model

#### Base Index

```
Base Index: (city, age, name) → primary_key
Key:   [index_subspace][city][age][name][primary_key]
Value: Empty

Example:
  [user_idx][Tokyo][25][Alice][user:123] → ∅
```

#### Permuted Index

```
Permuted Index: (age, city, name) → primary_key
Key:   [permuted_subspace][age][city][name][primary_key]
Value: Empty (data retrieved via primary key lookup)

Example:
  [user_perm1][25][Tokyo][Alice][user:123] → ∅
```

### 2.5 Index Definition

```swift
// Base index definition
let baseIndex = Index(
    name: "user_by_city_age_name",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "age"),
        FieldKeyExpression(fieldName: "name")
    ])
)

// Permuted index definition
let permutedIndex = Index(
    name: "user_by_age_city_name",
    type: .permuted,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "age"),
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "name")
    ]),
    options: IndexOptions(
        baseIndexName: "user_by_city_age_name",
        permutation: [1, 0, 2]  // Swap first two fields
    )
)
```

### 2.6 API Design

```swift
// 1. Define base and permuted indexes
let cityAgeIndex = Index(
    name: "user_by_city_age",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "age")
    ])
)

let ageCityIndex = Index(
    name: "user_by_age_city",
    type: .permuted,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "age"),
        FieldKeyExpression(fieldName: "city")
    ]),
    options: IndexOptions(
        baseIndexName: "user_by_city_age",
        permutation: [1, 0]
    )
)

// 2. Query automatically selects optimal permutation
let query1 = RecordQuery(
    recordType: "User",
    filter: FieldQueryComponent(fieldName: "city", comparison: .equals, value: "Tokyo")
)
// Uses base index: user_by_city_age

let query2 = RecordQuery(
    recordType: "User",
    filter: FieldQueryComponent(fieldName: "age", comparison: .greaterThan, value: 18)
)
// Uses permuted index: user_by_age_city

// 3. Manual permutation selection
let plan = try await planner.plan(query, preferredIndex: "user_by_age_city")
```

### 2.7 Implementation Details

#### PermutedIndexMaintainer

```swift
public struct PermutedIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace
    private let baseIndexName: String
    private let permutation: [Int]

    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old permuted entry
        if let oldRecord = oldRecord {
            let oldKey = try buildPermutedKey(record: oldRecord)
            transaction.clear(key: oldKey)
        }

        // Add new permuted entry
        if let newRecord = newRecord {
            let newKey = try buildPermutedKey(record: newRecord)
            // Value is empty - data retrieved via primary key
            transaction.setValue(FDB.Bytes(), for: newKey)
        }
    }

    private func buildPermutedKey(record: [String: Any]) throws -> FDB.Bytes {
        // 1. Evaluate base expression
        let baseValues = index.rootExpression.evaluate(record: record)

        // 2. Apply permutation
        let permutedValues = permutation.map { baseValues[$0] }

        // 3. Append primary key
        let primaryKey = extractPrimaryKey(record)
        let allValues = permutedValues + [primaryKey]

        // 4. Build key
        let tuple = TupleHelpers.toTuple(allValues)
        return subspace.pack(tuple)
    }
}
```

#### Query Planner Integration

```swift
extension TypedRecordQueryPlannerV2 {
    /// Select best permutation for query
    private func selectPermutation(
        query: TypedRecordQuery<Record>,
        permutedIndexes: [Index]
    ) async throws -> Index? {
        guard let filter = query.filter else { return nil }

        var bestPermutation: Index? = nil
        var bestCost = Double.infinity

        for permIndex in permutedIndexes {
            // Calculate cost for this permutation
            let cost = try await estimateCost(query: query, index: permIndex)

            if cost < bestCost {
                bestCost = cost
                bestPermutation = permIndex
            }
        }

        return bestPermutation
    }

    private func estimateCost(
        query: TypedRecordQuery<Record>,
        index: Index
    ) async throws -> Double {
        // Cost = number of leading fields in index that match query filter
        let filterFields = extractFilterFields(query.filter)
        let indexFields = extractIndexFields(index)

        // Count matching prefix
        var matchingPrefix = 0
        for (filterField, indexField) in zip(filterFields, indexFields) {
            if filterField == indexField {
                matchingPrefix += 1
            } else {
                break
            }
        }

        // Cost inversely proportional to matching prefix length
        return 1.0 / Double(matchingPrefix + 1)
    }
}
```

### 2.8 Storage Optimization

#### Comparison with Duplicate Indexes

```
Scenario: 3 field orders on 1M records, 100 bytes/record

Traditional Approach (3 separate indexes):
  Base:       (city, age, name) → 100MB
  Index 2:    (age, city, name) → 100MB
  Index 3:    (name, city, age) → 100MB
  Total:      300MB

Permuted Index Approach:
  Base:       (city, age, name) → 100MB (full data)
  Permuted 1: (age, city, name) → 10MB  (primary key only)
  Permuted 2: (name, city, age) → 10MB  (primary key only)
  Total:      120MB (60% reduction)
```

### 2.9 Metadata Management

```swift
public struct PermutedIndexMetadata: Sendable, Codable {
    public let name: String
    public let baseIndexName: String
    public let permutation: [Int]
    public let createdAt: Date

    /// Validate permutation
    public func validate() throws {
        // Check permutation is valid
        let sorted = permutation.sorted()
        guard sorted == Array(0..<permutation.count) else {
            throw RecordLayerError.invalidPermutation(
                "Permutation must be valid reordering of indices"
            )
        }
    }
}
```

### 2.10 Testing Strategy

```swift
@Suite("Permuted Index Tests")
struct PermutedIndexTests {
    @Test("Permuted index maintains correct ordering")
    func permutedOrdering() async throws { }

    @Test("Query planner selects optimal permutation")
    func queryPlannerSelection() async throws { }

    @Test("Storage efficiency vs duplicate indexes")
    func storageEfficiency() async throws { }

    @Test("Permutation validation rejects invalid permutations")
    func permutationValidation() async throws { }
}
```

---

## 3. Rank Index Design

### 3.1 Purpose

Efficiently compute rankings and retrieve records by rank without scanning entire datasets.

### 3.2 Use Cases

- Game leaderboards
- Sales rankings
- Social media trending
- Search result scoring
- Recommendation systems

### 3.3 Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Application                           │
│  getRank(record) → 42nd                                  │
│  getRecordByRank(10) → Top 10 player                    │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│              RankIndexMaintainer                         │
│  - updateRankTree()                                      │
│  - calculateRank() - O(log n)                           │
│  - getRankedRecord() - O(log n)                         │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│                  Range Tree                              │
│  Each node stores:                                       │
│  - count: number of records in subtree                  │
│  - min/max: score range                                 │
│  Tree is balanced via score distribution                │
└─────────────────────────────────────────────────────────┘
```

### 3.4 Data Model

#### Value Index (base)

```
Score Index: score → primary_key
Key:   [score_idx][score][primary_key]
Value: Empty

Example:
  [score_idx][9500][player:123] → ∅
  [score_idx][8900][player:456] → ∅
```

#### Range Tree Nodes

```
Range Tree Node: [range_start, range_end] → count
Key:   [rank_tree][range_start][range_end]
Value: count (8 bytes)

Example:
  [rank_tree][0][10000] → 1000  (1000 records in range 0-10000)
  [rank_tree][0][5000]  → 300   (300 records in range 0-5000)
  [rank_tree][5000][10000] → 700 (700 records in range 5000-10000)
```

### 3.5 Index Definition

```swift
let scoreRankIndex = Index(
    name: "game_score_rank",
    type: .rank,
    rootExpression: FieldKeyExpression(fieldName: "score"),
    options: IndexOptions(
        rankOrder: .descending,        // Higher score = better rank
        tieBreaker: .primaryKey,       // Tie-break by primary key
        bucketSize: 100                // Range tree bucket size
    )
)
```

### 3.6 API Design

```swift
// 1. Get rank of a record
try await database.withRecordContext { context in
    let player = try await recordStore.load(
        primaryKey: Tuple("player:123"),
        context: context
    )

    let rank = try await recordStore.getRank(
        index: "game_score_rank",
        record: player,
        context: context
    )
    // Returns: 42 (0-indexed, so 43rd place)
}

// 2. Get record by rank
try await database.withRecordContext { context in
    let topPlayer = try await recordStore.getRecordByRank(
        index: "game_score_rank",
        rank: 0,  // First place
        context: context
    )
}

// 3. Get rank range
try await database.withRecordContext { context in
    let top10 = try await recordStore.getRecordsByRankRange(
        index: "game_score_rank",
        rankRange: 0..<10,
        context: context
    )
    // Returns: Array of top 10 records
}

// 4. Get nearby ranks
try await database.withRecordContext { context in
    let nearby = try await recordStore.getRecordsByRankNearby(
        index: "game_score_rank",
        record: player,
        before: 5,  // 5 ranks above
        after: 5,   // 5 ranks below
        context: context
    )
    // Returns: 11 records (player + 5 before + 5 after)
}
```

### 3.7 Range Tree Algorithm

#### Structure

```
Range Tree for scores [0, 10000] with 1000 records:

Level 0 (root):
  [0, 10000] → count: 1000

Level 1:
  [0, 5000] → count: 300
  [5000, 10000] → count: 700

Level 2:
  [0, 2500] → count: 100
  [2500, 5000] → count: 200
  [5000, 7500] → count: 400
  [7500, 10000] → count: 300

Level 3: ... (continues recursively)
```

#### Rank Calculation

```swift
/// Calculate rank for a given score
func calculateRank(score: Int64) async throws -> Int {
    var rank = 0
    var currentRange = (min: Int64(0), max: maxScore)

    while true {
        let midpoint = (currentRange.min + currentRange.max) / 2

        if score >= midpoint {
            // Score is in upper half
            // Add count of all records in lower half to rank
            let lowerCount = try await getRangeCount(
                min: currentRange.min,
                max: midpoint
            )
            rank += lowerCount

            // Search upper half
            currentRange.min = midpoint
        } else {
            // Score is in lower half
            // Search lower half
            currentRange.max = midpoint
        }

        // Base case: reached leaf node
        if currentRange.max - currentRange.min <= bucketSize {
            // Scan bucket to find exact rank
            rank += try await scanBucketForRank(
                score: score,
                range: currentRange
            )
            break
        }
    }

    return rank
}
```

### 3.8 Implementation Details

#### RankIndexMaintainer

```swift
public struct RankIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let rangeTreeSubspace: Subspace
    public let recordSubspace: Subspace
    private let rankOrder: RankOrder
    private let tieBreaker: TieBreaker
    private let bucketSize: Int

    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // 1. Update value index (base)
        if let oldRecord = oldRecord {
            let oldKey = try buildScoreKey(record: oldRecord)
            transaction.clear(key: oldKey)
        }

        if let newRecord = newRecord {
            let newKey = try buildScoreKey(record: newRecord)
            transaction.setValue(FDB.Bytes(), for: newKey)
        }

        // 2. Update range tree
        try await updateRangeTree(
            oldRecord: oldRecord,
            newRecord: newRecord,
            transaction: transaction
        )
    }

    private func updateRangeTree(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // Calculate affected ranges
        let oldScore = oldRecord.flatMap { extractScore($0) }
        let newScore = newRecord.flatMap { extractScore($0) }

        // Update counts in all affected range nodes
        if let oldScore = oldScore {
            try await decrementRangeCounts(score: oldScore, transaction: transaction)
        }

        if let newScore = newScore {
            try await incrementRangeCounts(score: newScore, transaction: transaction)
        }
    }

    private func incrementRangeCounts(
        score: Int64,
        transaction: any TransactionProtocol
    ) async throws {
        var currentRange = (min: Int64(0), max: maxScore)

        while currentRange.max - currentRange.min > bucketSize {
            // Increment count for this range
            let rangeKey = rangeTreeSubspace.pack(
                Tuple(currentRange.min, currentRange.max)
            )
            let increment = TupleHelpers.int64ToBytes(1)
            transaction.atomicOp(key: rangeKey, param: increment, mutationType: .add)

            // Navigate to child range containing score
            let midpoint = (currentRange.min + currentRange.max) / 2
            if score >= midpoint {
                currentRange.min = midpoint
            } else {
                currentRange.max = midpoint
            }
        }
    }
}
```

#### Tie-Breaking Strategy

```swift
public enum TieBreaker: Sendable {
    case primaryKey        // Use primary key for stable ordering
    case timestamp         // Use insertion timestamp
    case custom(String)    // Use custom field
}

extension RankIndexMaintainer {
    private func buildScoreKey(record: [String: Any]) throws -> FDB.Bytes {
        let score = extractScore(record) ?? 0
        let primaryKey = extractPrimaryKey(record)

        // Build key with tie-breaker
        let keyElements: [any TupleElement]
        switch tieBreaker {
        case .primaryKey:
            keyElements = [score, primaryKey]
        case .timestamp:
            let timestamp = record["_timestamp"] as? Int64 ?? 0
            keyElements = [score, timestamp, primaryKey]
        case .custom(let field):
            let customValue = record[field] ?? ""
            keyElements = [score, customValue, primaryKey]
        }

        let tuple = TupleHelpers.toTuple(keyElements)
        return subspace.pack(tuple)
    }
}
```

### 3.9 Performance Characteristics

| Operation | Time Complexity | Space Complexity |
|-----------|----------------|------------------|
| Insert/Update | O(log n) | O(log n) range nodes |
| Delete | O(log n) | O(log n) range nodes |
| Get Rank | O(log n) | O(1) |
| Get by Rank | O(log n) | O(1) |
| Get Range | O(log n + k) | O(k) where k = result size |

### 3.10 Testing Strategy

```swift
@Suite("Rank Index Tests")
struct RankIndexTests {
    @Test("getRank returns correct position")
    func rankCalculation() async throws { }

    @Test("getRecordByRank retrieves correct record")
    func rankRetrieval() async throws { }

    @Test("Tie-breaker provides stable ordering")
    func tieBreaking() async throws { }

    @Test("Range tree maintains correct counts")
    func rangeTreeCounts() async throws { }

    @Test("Large dataset rank queries are efficient")
    func largeDatasetPerformance() async throws { }

    @Test("Concurrent updates maintain consistency")
    func concurrentUpdates() async throws { }
}
```

---

## 4. Implementation Roadmap

### Phase 1: Version Index (2-3 weeks)

**Week 1: Core Implementation**
- [ ] Implement `VersionIndexMaintainer`
- [ ] Integrate FDB Versionstamp operations
- [ ] Add `Version` struct
- [ ] Implement version checking logic

**Week 2: API & Features**
- [ ] Add `expectedVersion` parameter to RecordStore.save()
- [ ] Implement `loadWithVersion()` API
- [ ] Implement version history queries
- [ ] Add version metadata to records

**Week 3: Testing & Cleanup**
- [ ] Write comprehensive unit tests
- [ ] Write integration tests
- [ ] Performance testing
- [ ] Documentation

### Phase 2: Permuted Index (2-3 weeks)

**Week 1: Core Implementation**
- [ ] Implement `PermutedIndexMaintainer`
- [ ] Add permutation validation logic
- [ ] Implement permutation metadata storage

**Week 2: Query Planner Integration**
- [ ] Extend QueryPlannerV2 to select permutations
- [ ] Implement cost estimation for permutations
- [ ] Add permutation preference hints

**Week 3: Testing & Optimization**
- [ ] Write comprehensive tests
- [ ] Benchmark storage savings
- [ ] Query performance comparison
- [ ] Documentation

### Phase 3: Rank Index (4-6 weeks)

**Week 1-2: Range Tree Implementation**
- [ ] Design range tree structure
- [ ] Implement range tree node operations
- [ ] Implement range count queries

**Week 3-4: Rank Operations**
- [ ] Implement `getRank()` algorithm
- [ ] Implement `getRecordByRank()` algorithm
- [ ] Implement rank range queries
- [ ] Add tie-breaking logic

**Week 5: Integration**
- [ ] Integrate with RecordStore
- [ ] Add rank-specific APIs
- [ ] Implement maintenance operations

**Week 6: Testing & Optimization**
- [ ] Write comprehensive tests
- [ ] Large-scale performance testing
- [ ] Concurrent update testing
- [ ] Documentation

---

## 5. Common Infrastructure

### 5.1 Index Options Extension

```swift
extension IndexOptions {
    // Version Index options
    public var versionField: String? { get set }
    public var versionHistory: VersionHistoryStrategy? { get set }

    // Permuted Index options
    public var baseIndexName: String? { get set }
    public var permutation: [Int]? { get set }

    // Rank Index options
    public var rankOrder: RankOrder? { get set }
    public var tieBreaker: TieBreaker? { get set }
    public var bucketSize: Int? { get set }
}
```

### 5.2 RecordStore API Extensions

```swift
extension RecordStore {
    // Version Index APIs
    func save(_ record: Record, expectedVersion: Version?, context: RecordContext) async throws
    func loadWithVersion(primaryKey: Tuple, context: RecordContext) async throws -> (Record?, Version?)
    func loadVersion(primaryKey: Tuple, version: Version, context: RecordContext) async throws -> Record?
    func loadVersionHistory(primaryKey: Tuple, context: RecordContext) async throws -> [(Version, Record)]

    // Rank Index APIs
    func getRank(index: String, record: Record, context: RecordContext) async throws -> Int
    func getRecordByRank(index: String, rank: Int, context: RecordContext) async throws -> Record?
    func getRecordsByRankRange(index: String, rankRange: Range<Int>, context: RecordContext) async throws -> [Record]
    func getRecordsByRankNearby(index: String, record: Record, before: Int, after: Int, context: RecordContext) async throws -> [Record]
}
```

---

## 6. Migration Strategy

### 6.1 Backward Compatibility

All existing code continues to work without changes. Advanced index types are opt-in.

### 6.2 Incremental Rollout

1. **Phase 1**: Ship Version Index
   - Low risk, high value
   - Independent of other features

2. **Phase 2**: Ship Permuted Index
   - Depends on QueryPlannerV2
   - Requires cost model updates

3. **Phase 3**: Ship Rank Index
   - Most complex, ship last
   - Can be used independently

### 6.3 Feature Flags

```swift
public struct RecordStoreConfig {
    public var enableVersionIndex: Bool = true
    public var enablePermutedIndex: Bool = true
    public var enableRankIndex: Bool = true
}
```

---

## 7. Performance Targets

### Version Index
- Version check: < 1ms
- Version history retrieval (10 versions): < 5ms
- Storage overhead: ~12 bytes per version

### Permuted Index
- Storage savings vs duplicate indexes: 60-80%
- Query performance: Within 10% of dedicated index
- Permutation selection: < 1ms

### Rank Index
- Rank calculation: < 10ms for 1M records
- Rank retrieval: < 10ms for 1M records
- Storage overhead: ~50KB per 1M records (range tree)

---

## 8. Open Questions

1. **Version Index**: How to handle schema evolution for old versions?
2. **Permuted Index**: Should we support automatic permutation generation?
3. **Rank Index**: How to handle score distribution changes efficiently?
4. **All**: Should we support index-specific query hints?

---

## 9. References

- [FoundationDB Versionstamp Documentation](https://apple.github.io/foundationdb/developer-guide.html#versionstamps)
- [Java Record Layer Rank Index](https://github.com/FoundationDB/fdb-record-layer/blob/main/docs/RankIndexes.md)
- [Range Tree Algorithm](https://en.wikipedia.org/wiki/Range_tree)

---

**Document Version**: 1.0
**Last Updated**: 2025-10-31
**Authors**: Claude Code Design Team
