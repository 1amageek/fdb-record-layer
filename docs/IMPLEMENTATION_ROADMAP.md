# Implementation Roadmap - Swift Record Layer

**Version:** 2.0
**Status:** Phase 2 Planning
**Last Updated:** 2025-01-15

---

## Table of Contents

1. [Overview](#overview)
2. [Implementation Strategy](#implementation-strategy)
3. [Phase 2a: Core Features Completion](#phase-2a-core-features-completion)
4. [Phase 2b: Enhanced Features](#phase-2b-enhanced-features)
5. [Phase 3: Advanced Features](#phase-3-advanced-features)
6. [Implementation Levels](#implementation-levels)
7. [Success Criteria](#success-criteria)

---

## Overview

This document outlines the implementation plan for bringing Swift Record Layer to feature parity with Java Record Layer. The roadmap is divided into three phases, with clear implementation levels and success criteria for each feature.

### Current Status

**Phase 1**: ✅ **COMPLETE** (Type-safe core, query optimizer, basic indexes)

**Phase 2a**: 🎯 **TARGET** (Core features completion)
**Phase 2b**: 📋 **PLANNED** (Enhanced features)
**Phase 3**: 🔮 **FUTURE** (Advanced features)

### Comparison with Java Record Layer

| Category | Java | Swift (Current) | Target |
|----------|------|-----------------|--------|
| **Core Indexes** | 5 types | 5 types | ✅ Complete |
| **Advanced Indexes** | 4 types | 0 types | 2 types (Phase 2b) |
| **Query Operations** | 15+ plans | 8 plans | 12 plans (Phase 2a) |
| **Schema Evolution** | Full validator | Basic | Full validator (Phase 2a) |
| **Data Integrity** | Scrubber + Validator | None | Full support (Phase 2a) |
| **Aggregate API** | Full API | Index only | Full API (Phase 2a) |

---

## Implementation Strategy

### Design Principles

1. **Production First**: Prioritize features critical for production reliability
2. **Complete Over Broad**: Fully implement core features before adding advanced ones
3. **API Compatibility**: Maintain Swift-idiomatic API while preserving Java concepts
4. **Test-Driven**: Each feature must have comprehensive tests
5. **Documentation Required**: No feature complete without documentation

### Implementation Levels

We define four implementation levels:

| Level | Description | Test Coverage | Documentation | Production Ready |
|-------|-------------|---------------|---------------|------------------|
| **Full** | Complete feature implementation | ≥80% | Complete | ✅ Yes |
| **Partial** | Core functionality only | ≥60% | Basic | ⚠️ Limited |
| **Stub** | API only, no logic | N/A | API docs only | ❌ No |
| **Planned** | Design only | N/A | Design doc | ❌ No |

---

## Phase 2a: Core Features Completion

**Goal**: Production-grade reliability and data integrity
**Timeline**: 3-4 months
**Priority**: 🔴 **CRITICAL**

All Phase 2a features are **required** for production deployment.

---

### 1. OnlineIndexScrubber

**Implementation Level**: 🟢 **FULL**

**Description**: Detect and repair index inconsistencies

**Scope**:

#### 1.1 Core Detection Logic
```swift
public final class OnlineIndexScrubber {
    // Detect dangling entries (index → no record)
    func detectDanglingEntries() async throws -> [IndexEntry]

    // Detect missing entries (record → no index)
    func detectMissingEntries() async throws -> [MissingEntry]

    // Detect mismatched values (index value ≠ record value)
    func detectMismatchedValues() async throws -> [Mismatch]
}
```

#### 1.2 Repair Operations
```swift
extension OnlineIndexScrubber {
    struct ScrubbingPolicy: Sendable {
        var allowRepair: Bool = false
        var logWarningsLimit: Int = 100
        var entriesScanLimit: Int = 10_000
        var repairDanglingEntries: Bool = true
        var repairMissingEntries: Bool = true
    }

    func scrubIndex(
        indexName: String,
        policy: ScrubbingPolicy
    ) async throws -> ScrubbingResult

    func repairDanglingEntry(_ entry: IndexEntry) async throws
    func repairMissingEntry(_ missing: MissingEntry) async throws
}
```

#### 1.3 Progress Tracking
```swift
public struct ScrubbingResult: Sendable {
    let recordsScanned: Int64
    let danglingEntriesFound: Int64
    let danglingEntriesRepaired: Int64
    let missingEntriesFound: Int64
    let missingEntriesRepaired: Int64
    let mismatchedValuesFound: Int64
    let duration: TimeInterval
}
```

**Why Full Implementation**:
- Critical for production data integrity
- Users need automatic repair capability
- Must handle all inconsistency types

**Dependencies**:
- ✅ RangeSet (already implemented)
- ✅ IndexManager (already implemented)

**Estimated Effort**: 2-3 weeks

**Test Requirements**:
- Unit tests: Detect each inconsistency type
- Integration tests: Repair workflows
- Stress tests: Large-scale scanning

**Success Criteria**:
- [ ] Detect all three inconsistency types
- [ ] Automatic repair with configurable policy
- [ ] Resume capability using RangeSet
- [ ] Performance: Scan 100k records in <10 seconds
- [ ] Zero false positives in test suite

---

### 2. MetaDataEvolutionValidator

**Implementation Level**: 🟢 **FULL**

**Description**: Validate schema changes are safe and compatible

**Scope**:

#### 2.1 Validation Rules
```swift
public struct MetaDataEvolutionValidator {
    // Core validation
    func validate(
        oldMetaData: RecordMetaData,
        newMetaData: RecordMetaData,
        config: ValidationConfig
    ) throws

    struct ValidationConfig {
        var allowIndexRebuilds: Bool = true
        var allowFieldAdditions: Bool = true
        var allowFieldDeletions: Bool = false  // Breaking change
        var allowTypeChanges: Bool = false     // Breaking change
    }
}
```

#### 2.2 Validation Checks
```swift
extension MetaDataEvolutionValidator {
    // Record type validations
    func validateRecordTypes() throws
    func validateFieldConsistency() throws
    func validatePrimaryKeyUnchanged() throws

    // Index validations
    func validateIndexCompatibility() throws
    func validateIndexFormatUnchanged() throws
    func validateFormerIndexTracking() throws

    // Schema version
    func validateVersionProgression() throws
}
```

#### 2.3 FormerIndex Abstraction
```swift
public struct FormerIndex: Sendable {
    let name: String
    let addedVersion: Int
    let removedVersion: Int
    let formerType: IndexType
    let subspaceKey: String

    // Prevent index name reuse with different definition
    func validateNotReused(in newMetaData: RecordMetaData) throws
}

extension RecordMetaData {
    var formerIndexes: [FormerIndex] { get }

    mutating func addFormerIndex(_ index: FormerIndex)
}
```

#### 2.4 Migration Plan Generation
```swift
public struct MigrationPlan: Sendable {
    enum Step: Sendable {
        case addField(recordType: String, field: String)
        case rebuildIndex(indexName: String)
        case updateFormerIndexes([FormerIndex])
        case incrementVersion
    }

    let steps: [Step]
    let isBreaking: Bool
    let warnings: [String]

    func execute(store: RecordStore) async throws
}

extension MetaDataEvolutionValidator {
    func generateMigrationPlan() -> MigrationPlan
}
```

**Why Full Implementation**:
- Prevents data corruption during schema updates
- Essential for production deployments
- Enables safe continuous deployment

**Dependencies**:
- ✅ RecordMetaData (already implemented)
- 🆕 FormerIndex abstraction

**Estimated Effort**: 3-4 weeks

**Test Requirements**:
- Unit tests: Each validation rule
- Integration tests: Safe vs unsafe migrations
- Regression tests: Real-world migration scenarios

**Success Criteria**:
- [ ] Detect all breaking changes
- [ ] Generate safe migration plans
- [ ] FormerIndex prevents name reuse
- [ ] Zero false positives in validation
- [ ] Comprehensive error messages

---

### 3. Aggregate Function API

**Implementation Level**: 🟢 **FULL**

**Description**: Query API for aggregate indexes (COUNT, SUM, MIN, MAX)

**Scope**:

#### 3.1 Core API
```swift
extension RecordStore {
    // Execute aggregate function on index
    func evaluateAggregate<T: Sendable>(
        _ function: AggregateFunction,
        recordType: String,
        range: TupleRange = .all
    ) async throws -> T
}

public protocol AggregateFunction: Sendable {
    associatedtype Result: Sendable

    var indexName: String { get }
    var aggregateType: AggregateType { get }

    func evaluate(
        store: RecordStore,
        range: TupleRange
    ) async throws -> Result
}
```

#### 3.2 Built-in Aggregates
```swift
public enum AggregateType: Sendable {
    case count
    case sum
    case min
    case max
    case avg
}

// Factory methods
extension AggregateFunction {
    static func count(indexName: String) -> CountFunction
    static func sum(indexName: String) -> SumFunction
    static func min(indexName: String) -> MinFunction
    static func max(indexName: String) -> MaxFunction
}

// Concrete implementations
public struct CountFunction: AggregateFunction {
    public typealias Result = Int64
    public let indexName: String
    public let aggregateType: AggregateType = .count
}

public struct SumFunction: AggregateFunction {
    public typealias Result = Int64
    public let indexName: String
    public let aggregateType: AggregateType = .sum
}
```

#### 3.3 Group By Support
```swift
extension RecordStore {
    // Aggregate with grouping
    func evaluateAggregateGrouped<T: Sendable>(
        _ function: AggregateFunction,
        recordType: String,
        groupBy: [String]
    ) async throws -> [Tuple: T]
}

// Example usage
let countByCity = try await store.evaluateAggregateGrouped(
    .count(indexName: "user_count_by_city"),
    recordType: "User",
    groupBy: ["city"]
)
// Returns: ["Tokyo": 1000, "NYC": 500, ...]
```

#### 3.4 MIN/MAX Index Types
```swift
// New index types
extension IndexType {
    static let min = IndexType(rawValue: "MIN")
    static let max = IndexType(rawValue: "MAX")
}

extension Index {
    static func min(
        _ name: String,
        on expression: KeyExpression
    ) -> Index

    static func max(
        _ name: String,
        on expression: KeyExpression
    ) -> Index
}

// MIN/MAX maintainers
final class MinIndexMaintainer: IndexMaintainer {
    func updateIndex(/* ... */) async throws
}

final class MaxIndexMaintainer: IndexMaintainer {
    func updateIndex(/* ... */) async throws
}
```

**Why Full Implementation**:
- Completes existing COUNT/SUM index functionality
- Common requirement in analytics
- Relatively low complexity

**Dependencies**:
- ✅ COUNT Index (already implemented)
- ✅ SUM Index (already implemented)
- 🆕 MIN/MAX Index types

**Estimated Effort**: 2 weeks

**Test Requirements**:
- Unit tests: Each aggregate type
- Integration tests: Group by operations
- Performance tests: Large aggregations

**Success Criteria**:
- [ ] COUNT, SUM, MIN, MAX all working
- [ ] Group by support
- [ ] O(log n) lookup performance
- [ ] Works with compound keys
- [ ] Type-safe API

---

### 4. RecordQueryFilterPlan

**Implementation Level**: 🟢 **FULL**

**Description**: Post-scan filtering for conditions not satisfied by index

**Scope**:

#### 4.1 Filter Plan Implementation
```swift
public struct TypedFilterPlan<Record: Sendable>: TypedQueryPlan {
    let child: any TypedQueryPlan<Record>
    let filter: any TypedQueryComponent<Record>

    public func execute(
        context: RecordContext,
        continuation: Continuation?
    ) async throws -> TypedRecordCursor<Record>
}
```

#### 4.2 Predicate Evaluation
```swift
extension TypedQueryComponent {
    // Evaluate predicate on record
    func evaluate(record: Record) throws -> Bool
}

// Implementation for each component type
extension TypedFieldQueryComponent {
    func evaluate(record: Record) throws -> Bool {
        let value = extractValue(from: record, fieldName: fieldName)
        return comparison.evaluate(value, comparand)
    }
}

extension TypedAndQueryComponent {
    func evaluate(record: Record) throws -> Bool {
        return try children.allSatisfy { try $0.evaluate(record: record) }
    }
}

extension TypedOrQueryComponent {
    func evaluate(record: Record) throws -> Bool {
        return try children.contains { try $0.evaluate(record: record) }
    }
}
```

#### 4.3 Planner Integration
```swift
extension TypedRecordQueryPlanner {
    // Generate filter plan when needed
    private func generateFilterPlan(
        indexPlan: any TypedQueryPlan<Record>,
        remainingFilter: any TypedQueryComponent<Record>?
    ) -> any TypedQueryPlan<Record> {
        guard let filter = remainingFilter else {
            return indexPlan
        }

        return TypedFilterPlan(
            child: indexPlan,
            filter: filter
        )
    }
}
```

**Why Full Implementation**:
- Fundamental query operation
- Enables complex predicates not expressible in index
- Low implementation complexity

**Dependencies**:
- ✅ TypedQueryPlan framework (already implemented)
- ✅ TypedQueryComponent (already implemented)

**Estimated Effort**: 1 week

**Test Requirements**:
- Unit tests: Each predicate type
- Integration tests: Complex filter combinations
- Performance tests: Filter on large result sets

**Success Criteria**:
- [ ] All comparison operators work
- [ ] AND/OR/NOT combinations
- [ ] Type-safe evaluation
- [ ] Minimal performance overhead
- [ ] Works with all query plans

---

### 5. RecordQueryInJoinPlan

**Implementation Level**: 🟢 **FULL**

**Description**: Optimize IN clauses with index lookups

**Scope**:

#### 5.1 IN Join Plan
```swift
public struct TypedInJoinPlan<Record: Sendable>: TypedQueryPlan {
    let indexName: String
    let values: [any TupleElement]
    let sortKeys: [TypedSortKey<Record>]?

    public func execute(
        context: RecordContext,
        continuation: Continuation?
    ) async throws -> TypedRecordCursor<Record>
}
```

#### 5.2 IN Clause Detection
```swift
extension TypedRecordQueryPlanner {
    // Extract IN values from OR chain
    private func extractInClause(
        from filter: any TypedQueryComponent<Record>
    ) -> InClauseInfo? {
        guard let orComponent = filter as? TypedOrQueryComponent<Record> else {
            return nil
        }

        // Check if all children are equality on same field
        var fieldName: String?
        var values: [any TupleElement] = []

        for child in orComponent.children {
            guard let field = child as? TypedFieldQueryComponent<Record>,
                  field.comparison == .equals else {
                return nil
            }

            if let existing = fieldName {
                guard existing == field.fieldName else {
                    return nil  // Different fields
                }
            } else {
                fieldName = field.fieldName
            }

            values.append(field.value)
        }

        return InClauseInfo(fieldName: fieldName!, values: values)
    }
}
```

#### 5.3 Execution Strategy
```swift
extension TypedInJoinPlan {
    func execute(
        context: RecordContext,
        continuation: Continuation?
    ) async throws -> TypedRecordCursor<Record> {
        // Strategy 1: If index exists for field, use it
        if let index = findIndex(for: fieldName) {
            return executeWithIndex(index, values, context)
        }

        // Strategy 2: Primary key lookups
        if fieldName in primaryKeyFields {
            return executeWithPrimaryKey(values, context)
        }

        // Fallback: Full scan with filter
        return executeFallback(values, context)
    }

    private func executeWithIndex(
        _ index: Index,
        _ values: [any TupleElement],
        _ context: RecordContext
    ) async throws -> TypedRecordCursor<Record> {
        // Perform multiple index lookups (parallel if possible)
        let cursors = try await values.asyncMap { value in
            try await lookupInIndex(index, value: value, context: context)
        }

        // Merge results (removing duplicates)
        return MergeCursor(cursors, removeDuplicates: true)
    }
}
```

**Why Full Implementation**:
- Common query pattern (user_id IN (1,2,3,...))
- Significant performance improvement over OR
- Enables bulk operations

**Dependencies**:
- ✅ Index system (already implemented)
- 🆕 Merge cursor for combining results

**Estimated Effort**: 2 weeks

**Test Requirements**:
- Unit tests: IN clause detection
- Integration tests: Index vs primary key vs full scan
- Performance tests: Large IN lists (1000+ values)

**Success Criteria**:
- [ ] Automatic OR → IN conversion
- [ ] Index-based lookups when available
- [ ] Primary key batch lookup
- [ ] Duplicate removal
- [ ] 10x faster than OR for 100+ values

---

## Phase 2b: Enhanced Features

**Goal**: Enhanced functionality and user experience
**Timeline**: 2-3 months
**Priority**: 🟡 **RECOMMENDED**

Phase 2b features are **recommended** but not critical for initial production deployment.

---

### 6. DISTINCT Operation

**Implementation Level**: 🟡 **PARTIAL**

**Description**: Remove duplicate records from query results

**Scope**:

#### 6.1 Index-Based DISTINCT (Full Implementation)
```swift
public struct TypedDistinctPlan<Record: Sendable>: TypedQueryPlan {
    let child: any TypedQueryPlan<Record>
    let distinctFields: [String]
    let useIndex: Bool

    // Use index if available for distinct fields
    static func withIndex(
        indexName: String,
        fields: [String]
    ) -> TypedDistinctPlan<Record>
}
```

#### 6.2 In-Memory DISTINCT (Stub Only)
```swift
// API only, no implementation
extension TypedDistinctPlan {
    // In-memory deduplication (for small result sets)
    static func inMemory(
        child: any TypedQueryPlan<Record>,
        fields: [String]
    ) -> TypedDistinctPlan<Record> {
        fatalError("In-memory DISTINCT not yet implemented")
    }
}
```

**Why Partial Implementation**:
- Index-based DISTINCT is efficient and common
- In-memory DISTINCT has memory concerns for large datasets
- Can add in-memory version later if needed

**Implementation Includes**:
- ✅ Index-based DISTINCT
- ❌ In-memory DISTINCT (API stub only)

**Dependencies**:
- ✅ Index system (already implemented)

**Estimated Effort**: 1 week (index-based only)

**Success Criteria**:
- [ ] Index-based DISTINCT working
- [ ] API documented
- [ ] Performance comparable to Java version

---

### 7. TIME_WINDOW_LEADERBOARD Index

**Implementation Level**: 🟡 **PARTIAL**

**Description**: Time-windowed ranking for leaderboards

**Scope**:

#### 7.1 Time Window Configuration (Full)
```swift
extension IndexOptions {
    var timeWindowSize: Int?  // Window size in seconds
    var timeWindowType: TimeWindowType?

    enum TimeWindowType {
        case allTime
        case sliding(windowSeconds: Int)
        case fixed(windowSeconds: Int)
    }
}
```

#### 7.2 Basic Time Window Support (Full)
```swift
extension RankIndexMaintainer {
    // Add time window support to existing rank index
    func updateWithTimeWindow(
        record: Record,
        windowConfig: TimeWindowConfig
    ) async throws
}
```

#### 7.3 Advanced Features (Stub)
```swift
// API only, no implementation
extension RecordStore {
    func queryTimeWindowRank(
        indexName: String,
        window: TimeWindow,
        range: TupleRange
    ) async throws -> [(Record, rank: Int64)] {
        fatalError("Time window queries not yet implemented")
    }
}
```

**Why Partial Implementation**:
- Basic time window support enables most use cases
- Advanced querying can be added incrementally
- Reduces initial implementation complexity

**Implementation Includes**:
- ✅ Time window configuration
- ✅ Basic window-aware indexing
- ❌ Time window queries (API stub)
- ❌ Historical rank lookups (API stub)

**Dependencies**:
- ✅ RankIndex (already implemented)

**Estimated Effort**: 2 weeks (partial implementation)

**Success Criteria**:
- [ ] Configure time windows
- [ ] Index records with timestamps
- [ ] Basic rank queries work

---

### 8. Directory Layer

**Implementation Level**: 🟢 **FULL**

**Description**: Hierarchical path management with short prefix allocation

**Scope**:

#### 8.1 Core Directory Layer
```swift
public final class DirectoryLayer: Sendable {
    func createOrOpen(
        _ path: [String],
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace

    func create(
        _ path: [String],
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace

    func open(
        _ path: [String],
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace?

    func move(
        _ oldPath: [String],
        _ newPath: [String],
        database: any DatabaseProtocol
    ) async throws

    func remove(
        _ path: [String],
        database: any DatabaseProtocol
    ) async throws

    func exists(
        _ path: [String],
        database: any DatabaseProtocol
    ) async throws -> Bool

    func list(
        _ path: [String],
        database: any DatabaseProtocol
    ) async throws -> [String]
}
```

#### 8.2 Directory Subspace
```swift
public struct DirectorySubspace: Sendable {
    let path: [String]
    let prefix: FDB.Bytes  // Short allocated prefix
    let layer: String?

    // Acts as Subspace
    func subspace(_ tuple: Tuple) -> Subspace
    func pack(_ tuple: Tuple) -> FDB.Bytes
    func unpack(_ key: FDB.Bytes) throws -> Tuple
    func range() -> (begin: FDB.Bytes, end: FDB.Bytes)
}
```

#### 8.3 Directory Partitions
```swift
extension DirectoryLayer {
    func createPartition(
        _ path: [String],
        database: any DatabaseProtocol
    ) async throws -> DirectorySubspace
}
```

**Why Full Implementation**:
- Critical for multi-tenant systems
- Relatively straightforward implementation
- Aligns with FoundationDB best practices

**Dependencies**:
- ✅ Subspace (already implemented)
- ✅ Tuple (already implemented)

**Estimated Effort**: 2-3 weeks

**Success Criteria**:
- [ ] All directory operations working
- [ ] Efficient prefix allocation
- [ ] Move operations preserve data
- [ ] Partition support
- [ ] Compatible with Java version

---

### 9. Commit Checks

**Implementation Level**: 🟢 **FULL**

**Description**: Custom validation before transaction commit

**Scope**:

#### 9.1 Commit Check API
```swift
public protocol CommitCheck: Sendable {
    func check(context: RecordContext) async throws
}

extension RecordContext {
    private var commitChecks: [CommitCheck] = []

    public func addCommitCheck(_ check: CommitCheck)

    public func commit() async throws {
        // Run all commit checks before committing
        for check in commitChecks {
            try await check.check(context: self)
        }

        try await transaction.commit()
    }
}
```

#### 9.2 Common Checks
```swift
// Built-in commit checks
public struct UniqueConstraintCheck: CommitCheck {
    let recordType: String
    let fields: [String]

    public func check(context: RecordContext) async throws {
        // Verify uniqueness before commit
    }
}

public struct ReferentialIntegrityCheck: CommitCheck {
    let sourceType: String
    let targetType: String
    let foreignKey: String

    public func check(context: RecordContext) async throws {
        // Verify foreign key exists
    }
}
```

**Why Full Implementation**:
- Simple to implement
- High value for business logic validation
- Enables complex constraints

**Dependencies**:
- ✅ RecordContext (already implemented)

**Estimated Effort**: 1 week

**Success Criteria**:
- [ ] Commit check API working
- [ ] Built-in checks provided
- [ ] Custom checks supported
- [ ] Proper error handling
- [ ] Atomic rollback on failure

---

### 10. Format Versioning

**Implementation Level**: 🟢 **FULL**

**Description**: Track and manage record store format versions

**Scope**:

#### 10.1 Format Version Tracking
```swift
extension RecordStore {
    private(set) var formatVersion: Int

    static let currentFormatVersion: Int = 1
    static let minimumSupportedVersion: Int = 1

    func setFormatVersion(_ version: Int) async throws {
        guard version >= Self.minimumSupportedVersion else {
            throw RecordLayerError.unsupportedFormatVersion(version)
        }

        guard version <= Self.currentFormatVersion else {
            throw RecordLayerError.futureFormatVersion(version)
        }

        try await updateFormatVersionInHeader(version)
        self.formatVersion = version
    }
}
```

#### 10.2 Format Migration
```swift
public protocol FormatMigration: Sendable {
    var fromVersion: Int { get }
    var toVersion: Int { get }

    func migrate(store: RecordStore) async throws
}

extension RecordStore {
    func migrateFormat(to targetVersion: Int) async throws {
        let migrations = FormatMigrationRegistry.shared
            .getMigrations(from: formatVersion, to: targetVersion)

        for migration in migrations {
            try await migration.migrate(store: self)
        }
    }
}
```

**Why Full Implementation**:
- Critical for safe upgrades
- Simple to implement
- Prevents version mismatch issues

**Dependencies**:
- ✅ RecordStore header (already exists)

**Estimated Effort**: 1 week

**Success Criteria**:
- [ ] Version tracking in header
- [ ] Migration framework
- [ ] Backward compatibility checks
- [ ] Clear error messages

---

## Phase 3: Advanced Features

**Goal**: Advanced capabilities for specialized use cases
**Timeline**: 6+ months
**Priority**: 🔵 **OPTIONAL**

Phase 3 features are **optional** and targeted at specialized use cases.

---

### 11. TEXT (Lucene) Index

**Implementation Level**: 🔴 **NOT PLANNED FOR PHASE 3**

**Reason**: Extremely high complexity, consider alternative solutions:
- Use external search service (Elasticsearch, Typesense)
- Implement simplified text search (trigram indexes)
- Wait for community contribution

**If Implemented**: Would require 3-6 months of dedicated effort

---

### 12. SPATIAL Index

**Implementation Level**: 🟡 **PARTIAL** (If needed)

**Scope**: Basic geohash-based indexing only
- ✅ Geohash encoding/decoding
- ✅ Bounding box queries
- ❌ Complex spatial operations
- ❌ PostGIS compatibility

**Estimated Effort**: 3-4 weeks (partial)

---

### 13. Cascades Planner

**Implementation Level**: 🟡 **PARTIAL** (If needed)

**Scope**: Enhanced cost-based optimization
- ✅ Logical/physical plan separation
- ✅ Additional transformation rules
- ❌ Full Cascades framework
- ❌ Relational algebra optimization

**Estimated Effort**: 4-6 weeks (partial)

---

### 14. SQL Support

**Implementation Level**: 🔴 **NOT PLANNED FOR PHASE 3**

**Reason**:
- Very high complexity (6+ months)
- Limited value for Swift applications
- Consider alternative: GraphQL or native Swift DSL

---

## Implementation Levels

### Level Definitions

#### 🟢 Full Implementation
- **Complete feature**: All functionality from Java version
- **Test coverage**: ≥80%
- **Documentation**: Complete user guide + API reference
- **Production ready**: Yes
- **Examples**: Provided

**Quality Checklist**:
- [ ] All APIs implemented
- [ ] Comprehensive unit tests
- [ ] Integration tests
- [ ] Performance benchmarks
- [ ] Error handling
- [ ] API documentation
- [ ] Usage examples
- [ ] Migration guide (if applicable)

---

#### 🟡 Partial Implementation
- **Core functionality**: Essential features only
- **Test coverage**: ≥60%
- **Documentation**: Basic usage guide
- **Production ready**: Limited use cases
- **Examples**: Basic examples only

**Quality Checklist**:
- [ ] Core APIs implemented
- [ ] Essential unit tests
- [ ] Basic integration test
- [ ] API documentation
- [ ] Basic usage example
- [ ] Known limitations documented

---

#### 🔵 Stub Implementation
- **API only**: No implementation
- **Test coverage**: N/A
- **Documentation**: API signature only
- **Production ready**: No
- **Purpose**: Reserve API namespace

**Example**:
```swift
extension RecordStore {
    /// Future feature: Full-text search
    /// - Note: Not yet implemented, API reserved
    func textSearch(
        _ query: String,
        indexName: String
    ) async throws -> [Record] {
        fatalError("Text search not yet implemented")
    }
}
```

---

#### 🔴 Not Planned
- **No implementation**: Feature will not be added
- **Reason documented**: Why it's excluded
- **Alternative provided**: Suggested workaround

---

## Success Criteria

### Phase 2a Completion Criteria

**All of the following must be met**:

1. **Data Integrity** ✅
   - [ ] OnlineIndexScrubber working with all inconsistency types
   - [ ] MetaDataEvolutionValidator catching all breaking changes
   - [ ] Zero data loss in migration tests

2. **Query Functionality** ✅
   - [ ] IN Join 10x faster than OR for 100+ values
   - [ ] Filter plan supports all predicates
   - [ ] Aggregate API completes COUNT/SUM/MIN/MAX

3. **Test Coverage** ✅
   - [ ] Overall coverage ≥75%
   - [ ] All Phase 2a features ≥80% coverage
   - [ ] Zero failing tests

4. **Documentation** ✅
   - [ ] All Phase 2a features documented
   - [ ] Migration guide from Phase 1
   - [ ] Example code for each feature

5. **Performance** ✅
   - [ ] Scrubber: 100k records in <10 seconds
   - [ ] IN Join: 10x faster than OR (100 values)
   - [ ] Aggregate: O(log n) lookup

---

### Phase 2b Completion Criteria

**At least 3 of 5 features complete**:

1. **DISTINCT** ✅
   - [ ] Index-based DISTINCT working
   - [ ] Performance tests passing

2. **TIME_WINDOW_LEADERBOARD** ✅
   - [ ] Basic time window support
   - [ ] Configuration API

3. **Directory Layer** ✅
   - [ ] All directory operations working
   - [ ] Partition support

4. **Commit Checks** ✅
   - [ ] Commit check API working
   - [ ] Built-in checks provided

5. **Format Versioning** ✅
   - [ ] Version tracking implemented
   - [ ] Migration framework working

---

## Implementation Timeline

### Phase 2a (3-4 months)

```
Month 1:
  Week 1-2: OnlineIndexScrubber
  Week 3-4: MetaDataEvolutionValidator (Part 1)

Month 2:
  Week 1-2: MetaDataEvolutionValidator (Part 2)
  Week 3-4: Aggregate Function API

Month 3:
  Week 1: Filter Plan
  Week 2-3: IN Join Plan
  Week 4: Integration Testing

Month 4:
  Week 1-2: Bug fixes and polish
  Week 3: Documentation
  Week 4: Release preparation
```

### Phase 2b (2-3 months)

```
Month 1:
  Week 1: DISTINCT (index-based)
  Week 2-3: TIME_WINDOW_LEADERBOARD
  Week 4: Commit Checks

Month 2:
  Week 1-2: Directory Layer
  Week 3: Format Versioning
  Week 4: Integration Testing

Month 3:
  Week 1-2: Bug fixes
  Week 3: Documentation
  Week 4: Release
```

---

## Appendix: Implementation Details

### OnlineIndexScrubber Implementation Notes

**Algorithm**:
1. Forward pass: Scan index → verify record exists
2. Backward pass: Scan records → verify index entry exists
3. Value comparison: For found pairs, verify values match

**Performance Considerations**:
- Use RangeSet for progress tracking
- Batch operations (1000 per transaction)
- Parallel scanning (if safe)
- Throttling to avoid overwhelming system

**Edge Cases**:
- Deleted records during scan
- Concurrent index updates
- Transient inconsistencies (writeOnly state)

---

### MetaDataEvolutionValidator Implementation Notes

**Breaking Changes** (Must reject):
- Field deletion
- Field type change (incompatible)
- Primary key change
- Index format change

**Safe Changes** (Allow):
- Field addition
- New index creation
- Index deletion (with FormerIndex)
- Schema version increment

**Validation Order**:
1. Version progression check
2. Record type compatibility
3. Field compatibility
4. Index compatibility
5. FormerIndex tracking

---

## Summary

This roadmap provides a clear path to achieving feature parity with Java Record Layer while maintaining Swift-idiomatic design and production quality.

**Key Principles**:
1. **Phase 2a is required** for production deployments
2. **Full implementation** for all Phase 2a features
3. **Partial implementation acceptable** for Phase 2b
4. **Test-driven development** throughout
5. **Documentation is mandatory**

**Expected Outcome**:
After Phase 2a completion, Swift Record Layer will be production-ready with:
- ✅ Data integrity guarantees
- ✅ Safe schema evolution
- ✅ Complete query functionality
- ✅ Enterprise-grade reliability

---

**Questions or feedback?** Please file an issue on GitHub.
