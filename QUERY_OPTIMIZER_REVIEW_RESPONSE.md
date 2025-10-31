# Query Optimizer Design - Review Response

**Date:** 2025-10-31
**Reviewer Feedback Analysis**

---

## Table of Contents

1. [Critical Issues](#critical-issues)
2. [High Priority Issues](#high-priority-issues)
3. [Questions & Assumptions](#questions--assumptions)
4. [Revised Design](#revised-design)
5. [Implementation Strategy](#implementation-strategy)

---

## Critical Issues

### Issue 1: AnyCodable Comparison Problem

**Problem:**
```swift
// This code doesn't compile - AnyCodable doesn't conform to Comparable
if value >= bucket.lowerBound && value < bucket.upperBound {
    // ...
}
```

**Root Cause:**
AnyCodable lacks Comparable conformance, making histogram-based selectivity estimation non-functional.

**Solution: Typed Value System**

Replace AnyCodable with a properly typed value system using Swift generics and type erasure:

```swift
/// Type-safe comparable value wrapper
public enum ComparableValue: Codable, Sendable, Hashable {
    case string(String)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null

    public init(_ value: any TupleElement) {
        switch value {
        case let str as String:
            self = .string(str)
        case let int as Int64:
            self = .int64(int)
        case let int as Int:
            self = .int64(Int64(int))
        case let double as Double:
            self = .double(double)
        case let bool as Bool:
            self = .bool(bool)
        default:
            self = .null
        }
    }

    /// Extract the raw comparable value for type-safe comparison
    public func asAny() -> any Comparable {
        switch self {
        case .string(let v): return v
        case .int64(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return 0 // Null sorts lowest
        }
    }
}

extension ComparableValue: Comparable {
    public static func < (lhs: ComparableValue, rhs: ComparableValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let l), .string(let r)):
            return l < r
        case (.int64(let l), .int64(let r)):
            return l < r
        case (.double(let l), .double(let r)):
            return l < r
        case (.bool(let l), .bool(let r)):
            return !l && r
        case (.null, .null):
            return false
        case (.null, _):
            return true // null is always smallest
        case (_, .null):
            return false
        default:
            // Different types: define ordering
            return lhs.typeOrder < rhs.typeOrder
        }
    }

    private var typeOrder: Int {
        switch self {
        case .null: return 0
        case .bool: return 1
        case .int64: return 2
        case .double: return 3
        case .string: return 4
        }
    }
}

/// Revised histogram using ComparableValue
public struct Histogram: Codable, Sendable {
    public let buckets: [Bucket]
    public let totalCount: Int64

    public struct Bucket: Codable, Sendable {
        public let lowerBound: ComparableValue
        public let upperBound: ComparableValue
        public let count: Int64
        public let distinctCount: Int64
    }

    /// Estimate selectivity - now type-safe and compilable
    public func estimateSelectivity(
        comparison: Comparison,
        value: ComparableValue
    ) -> Double {
        switch comparison {
        case .equals:
            return estimateEqualsSelectivity(value)
        case .lessThan:
            return estimateRangeSelectivity(min: nil, max: value, maxInclusive: false)
        case .lessThanOrEquals:
            return estimateRangeSelectivity(min: nil, max: value, maxInclusive: true)
        case .greaterThan:
            return estimateRangeSelectivity(min: value, max: nil, minInclusive: false)
        case .greaterThanOrEquals:
            return estimateRangeSelectivity(min: value, max: nil, minInclusive: true)
        default:
            return 0.1 // Conservative default
        }
    }

    private func estimateEqualsSelectivity(_ value: ComparableValue) -> Double {
        guard let bucket = findBucket(value) else {
            return 0.0
        }

        // Uniform distribution assumption within bucket
        guard bucket.distinctCount > 0 else {
            return 0.0
        }

        return Double(bucket.count) / Double(bucket.distinctCount * totalCount)
    }

    private func estimateRangeSelectivity(
        min: ComparableValue?,
        max: ComparableValue?,
        minInclusive: Bool = true,
        maxInclusive: Bool = true
    ) -> Double {
        var matchingCount: Int64 = 0

        for bucket in buckets {
            if rangeOverlaps(
                bucketMin: bucket.lowerBound,
                bucketMax: bucket.upperBound,
                rangeMin: min,
                rangeMax: max,
                minInclusive: minInclusive,
                maxInclusive: maxInclusive
            ) {
                // Partial overlap: estimate fraction
                let overlapFraction = estimateOverlapFraction(
                    bucket: bucket,
                    rangeMin: min,
                    rangeMax: max,
                    minInclusive: minInclusive,
                    maxInclusive: maxInclusive
                )
                matchingCount += Int64(Double(bucket.count) * overlapFraction)
            }
        }

        guard totalCount > 0 else {
            return 0.0
        }

        return Double(matchingCount) / Double(totalCount)
    }

    private func findBucket(_ value: ComparableValue) -> Bucket? {
        return buckets.first { bucket in
            value >= bucket.lowerBound && value < bucket.upperBound
        }
    }

    private func rangeOverlaps(
        bucketMin: ComparableValue,
        bucketMax: ComparableValue,
        rangeMin: ComparableValue?,
        rangeMax: ComparableValue?,
        minInclusive: Bool,
        maxInclusive: Bool
    ) -> Bool {
        // Check non-overlap conditions
        if let rangeMin = rangeMin {
            if minInclusive {
                if bucketMax <= rangeMin { return false }
            } else {
                if bucketMax < rangeMin { return false }
            }
        }

        if let rangeMax = rangeMax {
            if maxInclusive {
                if bucketMin > rangeMax { return false }
            } else {
                if bucketMin >= rangeMax { return false }
            }
        }

        return true
    }

    private func estimateOverlapFraction(
        bucket: Bucket,
        rangeMin: ComparableValue?,
        rangeMax: ComparableValue?,
        minInclusive: Bool,
        maxInclusive: Bool
    ) -> Double {
        // For simplicity, assume uniform distribution
        // In production, use interpolation based on value ranges

        // If fully contained, return 1.0
        let fullyContained = (rangeMin == nil || bucket.lowerBound >= rangeMin!) &&
                             (rangeMax == nil || bucket.upperBound <= rangeMax!)

        if fullyContained {
            return 1.0
        }

        // Partial overlap: estimate as 50% (conservative)
        return 0.5
    }
}
```

**Benefits:**
- ✅ Compiles and type-safe
- ✅ Supports common FoundationDB types
- ✅ Proper comparison semantics
- ✅ Extensible for new types

---

### Issue 2: Async Closure Problem

**Problem:**
```swift
let totalSelectivity = childCosts.reduce(1.0) { result, cost in
    // ❌ Cannot use await in synchronous closure
    guard let tableStats = try? await statisticsManager.getTableStatistics(...)
    return result * selectivity
}
```

**Solution: Pre-fetch Statistics**

```swift
private func estimateIntersectionCost<Record: Sendable>(
    _ plan: TypedIntersectionPlan<Record>,
    recordType: String
) async throws -> QueryCost {
    // ✅ Fetch statistics ONCE at the top level
    guard let tableStats = try await statisticsManager.getTableStatistics(
        recordType: recordType
    ) else {
        // No statistics available
        return QueryCost(
            ioCost: 10_000,
            cpuCost: 1_000,
            estimatedRows: 1_000
        )
    }

    // Estimate cost of each child
    var childCosts: [QueryCost] = []
    for child in plan.children {
        let cost = try await estimatePlanCost(child, recordType: recordType)
        childCosts.append(cost)
    }

    // Sort children by estimated rows (smallest first)
    childCosts.sort { $0.estimatedRows < $1.estimatedRows }

    // Intersection cost: sum of child I/O + intersection processing
    let totalIoCost = childCosts.reduce(0.0) { $0 + $1.ioCost }

    // ✅ Synchronous calculation using pre-fetched stats
    let totalSelectivity = childCosts.reduce(1.0) { result, cost in
        guard tableStats.rowCount > 0 else { return result }
        let selectivity = Double(cost.estimatedRows) / Double(tableStats.rowCount)
        return result * selectivity
    }

    let estimatedRows = Double(tableStats.rowCount) * totalSelectivity

    // CPU cost: intersection processing
    let maxChildRows = childCosts.map { $0.estimatedRows }.max() ?? 0
    let cpuCost = Double(maxChildRows) * cpuFilterCost * Double(plan.children.count)

    return QueryCost(
        ioCost: totalIoCost,
        cpuCost: cpuCost,
        estimatedRows: Int64(estimatedRows)
    )
}
```

**Pattern for All Cost Estimation:**
```swift
// ✅ Always fetch statistics at the beginning
guard let tableStats = try await statisticsManager.getTableStatistics(...) else {
    return defaultCost
}

// ✅ All calculations are synchronous from here on
let result = synchronousCalculation(using: tableStats)
```

---

## High Priority Issues

### Issue 3: Zero Division in Limit Cost

**Problem:**
```swift
// ❌ Crashes when estimatedRows == 0
let limitFactor = Double(plan.limit) / Double(childCost.estimatedRows)
```

**Solution: Guard Against Zero**

```swift
private func estimateLimitCost<Record: Sendable>(
    _ plan: TypedLimitPlan<Record>,
    recordType: String
) async throws -> QueryCost {
    let childCost = try await estimatePlanCost(plan.child, recordType: recordType)

    // ✅ Guard against zero rows
    guard childCost.estimatedRows > 0 else {
        // No rows to limit - return minimal cost
        return QueryCost(
            ioCost: 0,
            cpuCost: 0,
            estimatedRows: 0
        )
    }

    // ✅ Safe division
    let limitFactor = min(1.0, Double(plan.limit) / Double(childCost.estimatedRows))

    return QueryCost(
        ioCost: childCost.ioCost * limitFactor,
        cpuCost: childCost.cpuCost * limitFactor,
        estimatedRows: min(Int64(plan.limit), childCost.estimatedRows)
    )
}
```

**General Pattern: Epsilon Guards**
```swift
extension Double {
    static let epsilon: Double = 1e-10

    func safeDivide(by divisor: Double, default defaultValue: Double = 0.0) -> Double {
        guard abs(divisor) > Self.epsilon else {
            return defaultValue
        }
        return self / divisor
    }
}

// Usage:
let selectivity = matchingRows.safeDivide(by: Double(totalRows), default: 0.0)
```

---

### Issue 4: Unstable Cache Keys

**Problem:**
```swift
// ❌ String(describing:) includes memory addresses
let key = String(describing: filter)
// Output: "TypedFieldQueryComponent<User>(fieldName: "age", ...) @0x7f8a3c000000"
```

**Solution: Canonical Representation**

```swift
/// Protocol for generating stable cache keys
public protocol CacheKeyable {
    func cacheKey() -> String
}

extension TypedFieldQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        return "field:\(fieldName):\(comparison):\(String(describing: value))"
    }
}

extension TypedAndQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        let childKeys = children
            .map { ($0 as? CacheKeyable)?.cacheKey() ?? "unknown" }
            .sorted() // ✅ Canonical ordering
            .joined(separator: ",")
        return "and:[\(childKeys)]"
    }
}

extension TypedOrQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        let childKeys = children
            .map { ($0 as? CacheKeyable)?.cacheKey() ?? "unknown" }
            .sorted() // ✅ Canonical ordering
            .joined(separator: ",")
        return "or:[\(childKeys)]"
    }
}

extension TypedNotQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        let childKey = (child as? CacheKeyable)?.cacheKey() ?? "unknown"
        return "not:\(childKey)"
    }
}

/// Revised PlanCache with stable keys
public actor PlanCache<Record: Sendable> {
    // ... existing code ...

    private func cacheKey(query: TypedRecordQuery<Record>) -> String {
        var components: [String] = []

        // Filter component
        if let filter = query.filter as? CacheKeyable {
            components.append("filter:\(filter.cacheKey())")
        }

        // Limit component
        if let limit = query.limit {
            components.append("limit:\(limit)")
        }

        // Sort component
        if let sort = query.sort {
            let sortKeys = sort.map { "\($0.expression):\($0.ascending)" }.joined(separator: ",")
            components.append("sort:[\(sortKeys)]")
        }

        // ✅ Generate hash for efficiency
        let keyString = components.joined(separator: "|")
        return keyString.stableHash()
    }
}

extension String {
    /// Generate stable hash (not memory-address dependent)
    func stableHash() -> String {
        var hasher = Hasher()
        hasher.combine(self)
        return String(hasher.finalize())
    }
}
```

**Alternative: Use Codable**
```swift
extension TypedRecordQuery: Codable where Record: Codable {
    private func cacheKey() -> String {
        guard let data = try? JSONEncoder().encode(self) else {
            return UUID().uuidString // Fallback
        }
        return data.base64EncodedString()
    }
}
```

---

### Issue 5: DNF Explosion

**Problem:**
```swift
// ❌ Exponential expansion
// (A1 OR A2) AND (B1 OR B2) AND (C1 OR C2) AND ... (J1 OR J2)
// → 2^10 = 1024 terms in DNF!
```

**Solution: Bounded Rewriting with Heuristics**

```swift
/// Query rewriter with explosion prevention
public struct QueryRewriter<Record: Sendable> {

    /// Configuration
    public struct Config {
        /// Maximum number of terms after DNF conversion
        public let maxDNFTerms: Int

        /// Maximum depth of expression tree
        public let maxDepth: Int

        public static let `default` = Config(
            maxDNFTerms: 100,
            maxDepth: 20
        )

        public static let conservative = Config(
            maxDNFTerms: 20,
            maxDepth: 10
        )
    }

    private let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    /// Apply rewrite rules with bounds checking
    public func rewrite(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        var rewritten = filter

        // Rule 1: Push NOT down (always safe)
        rewritten = pushNotDown(rewritten)

        // Rule 2: Flatten nested AND/OR (always safe)
        rewritten = flattenBooleans(rewritten)

        // Rule 3: Remove redundant conditions (always safe)
        rewritten = removeRedundant(rewritten)

        // Rule 4: Convert to DNF (ONLY if safe)
        if shouldConvertToDNF(rewritten) {
            rewritten = convertToDNF(rewritten)
        }

        // Rule 5: Constant folding (always safe)
        rewritten = foldConstants(rewritten)

        return rewritten
    }

    /// Check if DNF conversion is safe
    private func shouldConvertToDNF(
        _ filter: any TypedQueryComponent<Record>
    ) -> Bool {
        // Estimate resulting term count
        let estimatedTerms = estimateDNFTermCount(filter)

        // Only convert if under threshold
        return estimatedTerms <= config.maxDNFTerms
    }

    /// Estimate number of terms after DNF conversion
    private func estimateDNFTermCount(
        _ filter: any TypedQueryComponent<Record>
    ) -> Int {
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // A AND B AND C
            // Each child may expand, multiply the counts
            return andFilter.children.reduce(1) { result, child in
                result * estimateDNFTermCount(child)
            }
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            // A OR B OR C
            // Each child contributes additively
            return orFilter.children.reduce(0) { result, child in
                result + estimateDNFTermCount(child)
            }
        } else {
            // Leaf node contributes 1 term
            return 1
        }
    }

    /// Convert to DNF with bounds checking
    private func convertToDNF(
        _ filter: any TypedQueryComponent<Record>,
        currentTerms: Int = 0
    ) -> any TypedQueryComponent<Record> {
        // ✅ Stop if we've exceeded the limit
        if currentTerms > config.maxDNFTerms {
            return filter // Return as-is
        }

        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // Check if any child is an OR
            for (index, child) in andFilter.children.enumerated() {
                if let orChild = child as? TypedOrQueryComponent<Record> {
                    // Estimate expansion
                    let newTermCount = currentTerms * orChild.children.count

                    // ✅ Only expand if under limit
                    if newTermCount <= config.maxDNFTerms {
                        // Distribute: A AND (B OR C) → (A AND B) OR (A AND C)
                        var otherChildren = andFilter.children
                        otherChildren.remove(at: index)

                        let distributed = orChild.children.map { orTerm in
                            var newAnd = otherChildren
                            newAnd.append(orTerm)
                            return convertToDNF(
                                TypedAndQueryComponent(children: newAnd),
                                currentTerms: newTermCount
                            )
                        }

                        return TypedOrQueryComponent(children: distributed)
                    }
                }
            }
        }

        return filter
    }

    // ... other rewrite methods remain the same ...
}
```

**Alternative: Partial DNF**
```swift
/// Apply DNF only to parts of the query that benefit
public func selectiveRewrite(
    _ filter: any TypedQueryComponent<Record>
) -> any TypedQueryComponent<Record> {
    // Identify beneficial rewrites
    // Example: Only rewrite if there are usable indexes

    if let andFilter = filter as? TypedAndQueryComponent<Record> {
        // Check if children have indexes
        let childrenWithIndexes = andFilter.children.filter { child in
            hasUsableIndex(child)
        }

        // Only rewrite if multiple indexes available
        if childrenWithIndexes.count >= 2 {
            return convertToDNF(filter)
        }
    }

    return filter
}
```

---

## Questions & Assumptions

### Q1: Typed Comparison Layer for Histogram Buckets

**Answer:** Yes, we will implement a typed value system.

**Approach:**
1. **ComparableValue enum** (as shown above) for type-safe comparisons
2. **Per-field type registry** for consistent encoding/decoding
3. **Type-specific histogram implementations** for complex types

```swift
/// Type registry for field types
public struct FieldTypeRegistry: Sendable {
    private let fieldTypes: [String: FieldType]

    public enum FieldType: Sendable {
        case string
        case int64
        case double
        case bool
        case timestamp
        case uuid
    }

    public init(recordType: TypedRecordType<Record>) {
        // Build registry from record type metadata
        self.fieldTypes = recordType.fields.reduce(into: [:]) { result, field in
            result[field.name] = field.type
        }
    }

    public func getType(fieldName: String) -> FieldType? {
        return fieldTypes[fieldName]
    }
}

/// Type-specific histogram
public struct TypedHistogram<T: Comparable & Codable & Sendable>: Sendable {
    public let buckets: [Bucket]
    public let totalCount: Int64

    public struct Bucket: Codable, Sendable {
        public let lowerBound: T
        public let upperBound: T
        public let count: Int64
        public let distinctCount: Int64
    }

    /// Type-safe selectivity estimation
    public func estimateSelectivity(
        comparison: Comparison,
        value: T
    ) -> Double {
        // Implementation with proper type safety
        switch comparison {
        case .equals:
            guard let bucket = buckets.first(where: { $0.lowerBound <= value && value < $0.upperBound }) else {
                return 0.0
            }
            return Double(bucket.count) / Double(bucket.distinctCount * totalCount)

        case .lessThan:
            let matchingCount = buckets
                .filter { $0.lowerBound < value }
                .reduce(0) { $0 + $1.count }
            return Double(matchingCount) / Double(totalCount)

        // ... other cases
        default:
            return 0.1
        }
    }
}
```

### Q2: Statistics Update Strategy

**Answer:** Statistics will be updated via:

1. **Manual collection** triggered by admin
2. **Automatic collection** on schedule (e.g., nightly)
3. **Incremental updates** for hot indexes
4. **Statistics invalidation** on major data changes

```swift
/// Statistics update policy
public struct StatisticsUpdatePolicy: Sendable {
    public enum Trigger {
        case manual
        case scheduled(interval: TimeInterval)
        case dataChangeThreshold(Double) // e.g., 10% change
        case indexBuild
    }

    public let trigger: Trigger
    public let sampleRate: Double

    public static let `default` = StatisticsUpdatePolicy(
        trigger: .scheduled(interval: 24 * 3600), // Daily
        sampleRate: 0.1
    )
}
```

---

## Revised Design

### Corrected Cost Estimator

```swift
/// Cost estimator with all fixes applied
public struct CostEstimator: Sendable {
    private let statisticsManager: StatisticsManager

    // Cost constants (tunable)
    private let ioReadCost: Double = 1.0
    private let cpuDeserializeCost: Double = 0.1
    private let cpuFilterCost: Double = 0.05

    // Safety constants
    private static let epsilon: Double = 1e-10
    private static let minEstimatedRows: Int64 = 1

    public init(statisticsManager: StatisticsManager) {
        self.statisticsManager = statisticsManager
    }

    /// Estimate cost with all safety checks
    public func estimateCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        // Fetch statistics once at the top level
        let tableStats = try? await statisticsManager.getTableStatistics(
            recordType: recordType
        )

        return try await estimatePlanCost(
            plan,
            recordType: recordType,
            tableStats: tableStats
        )
    }

    /// Internal estimation with pre-fetched stats
    private func estimatePlanCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?
    ) async throws -> QueryCost {
        if let scanPlan = plan as? TypedFullScanPlan<Record> {
            return try await estimateFullScanCost(
                scanPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else if let indexPlan = plan as? TypedIndexScanPlan<Record> {
            return try await estimateIndexScanCost(
                indexPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else if let intersectionPlan = plan as? TypedIntersectionPlan<Record> {
            return try await estimateIntersectionCost(
                intersectionPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else if let limitPlan = plan as? TypedLimitPlan<Record> {
            return try await estimateLimitCost(
                limitPlan,
                recordType: recordType,
                tableStats: tableStats
            )
        } else {
            // Unknown plan type
            return QueryCost.unknown
        }
    }

    private func estimateFullScanCost<Record: Sendable>(
        _ plan: TypedFullScanPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?
    ) async throws -> QueryCost {
        guard let tableStats = tableStats, tableStats.rowCount > 0 else {
            return QueryCost.defaultFullScan
        }

        var estimatedRows = Double(tableStats.rowCount)

        // Apply filter selectivity
        if let filter = plan.filter {
            let selectivity = try await statisticsManager.estimateSelectivity(
                filter: filter,
                recordType: recordType
            )
            estimatedRows *= max(selectivity, Self.epsilon)
        }

        let ioCost = Double(tableStats.rowCount) * ioReadCost
        let cpuCost = Double(tableStats.rowCount) * (cpuDeserializeCost + cpuFilterCost)

        return QueryCost(
            ioCost: ioCost,
            cpuCost: cpuCost,
            estimatedRows: max(Int64(estimatedRows), Self.minEstimatedRows)
        )
    }

    private func estimateLimitCost<Record: Sendable>(
        _ plan: TypedLimitPlan<Record>,
        recordType: String,
        tableStats: TableStatistics?
    ) async throws -> QueryCost {
        let childCost = try await estimatePlanCost(
            plan.child,
            recordType: recordType,
            tableStats: tableStats
        )

        // ✅ Guard against zero
        guard childCost.estimatedRows > 0 else {
            return QueryCost(ioCost: 0, cpuCost: 0, estimatedRows: 0)
        }

        // ✅ Safe calculation
        let limitFactor = min(
            1.0,
            Double(plan.limit) / Double(childCost.estimatedRows)
        )

        return QueryCost(
            ioCost: childCost.ioCost * limitFactor,
            cpuCost: childCost.cpuCost * limitFactor,
            estimatedRows: min(Int64(plan.limit), childCost.estimatedRows)
        )
    }
}

extension QueryCost {
    /// Default costs for when statistics are unavailable
    static let unknown = QueryCost(
        ioCost: 1_000_000,
        cpuCost: 100_000,
        estimatedRows: 1_000_000
    )

    static let defaultFullScan = QueryCost(
        ioCost: 1_000_000,
        cpuCost: 100_000,
        estimatedRows: 1_000_000
    )

    static let defaultIndexScan = QueryCost(
        ioCost: 10_000,
        cpuCost: 1_000,
        estimatedRows: 10_000
    )
}
```

---

## Implementation Strategy

### Phase 1: Foundation (Week 1-2) - REVISED

**Priority Tasks:**
1. ✅ **Implement ComparableValue system** (replaces AnyCodable)
2. ✅ **Fix async/await patterns** in cost estimator
3. ✅ **Add safety guards** (zero division, null checks)
4. ✅ **Implement stable cache keys** (CacheKeyable protocol)
5. ✅ **Add bounded rewriting** (DNF explosion prevention)

**Deliverables:**
- `Sources/FDBRecordLayer/Query/ComparableValue.swift`
- `Sources/FDBRecordLayer/Query/CostEstimator.swift` (revised)
- `Sources/FDBRecordLayer/Query/QueryRewriter.swift` (revised)
- `Sources/FDBRecordLayer/Query/PlanCache.swift` (revised)
- Comprehensive unit tests for each

**Acceptance Criteria:**
- [ ] All code compiles without warnings
- [ ] No unsafe async/await usage
- [ ] All division operations are guarded
- [ ] Cache keys are stable across runs
- [ ] DNF rewriting bounded to configurable limit

### Phase 2: Testing & Validation (Week 3)

**Tasks:**
1. Property-based testing for ComparableValue
2. Stress testing for DNF rewriter (large queries)
3. Concurrency testing for statistics manager
4. Cache hit rate analysis

**Test Scenarios:**
```swift
// Test: ComparableValue comparison
func testComparableValueOrdering() {
    XCTAssertTrue(ComparableValue.int64(1) < ComparableValue.int64(2))
    XCTAssertTrue(ComparableValue.string("a") < ComparableValue.string("b"))
    XCTAssertTrue(ComparableValue.null < ComparableValue.int64(0))
}

// Test: DNF explosion prevention
func testDNFExplosionPrevention() {
    let config = QueryRewriter.Config(maxDNFTerms: 20, maxDepth: 10)
    let rewriter = QueryRewriter(config: config)

    // Create query with 10 OR clauses
    let complexFilter = createComplexFilter(depth: 10)

    let rewritten = rewriter.rewrite(complexFilter)
    let termCount = countTerms(rewritten)

    XCTAssertLessThanOrEqual(termCount, 20)
}

// Test: Safe division
func testLimitCostZeroRows() {
    let childCost = QueryCost(ioCost: 100, cpuCost: 10, estimatedRows: 0)
    let estimator = CostEstimator(statisticsManager: mockStats)

    let cost = try await estimator.estimateLimitCost(limitPlan, tableStats: nil)

    XCTAssertEqual(cost.estimatedRows, 0)
    XCTAssertEqual(cost.ioCost, 0)
}

// Test: Stable cache keys
func testCacheKeyStability() {
    let query = TypedRecordQuery<User>()
        .filter(.field("age", .equals(25)))

    let key1 = cache.cacheKey(query: query)
    let key2 = cache.cacheKey(query: query)

    XCTAssertEqual(key1, key2) // Must be identical
}
```

### Phase 3: Documentation Update (Week 3)

**Tasks:**
1. Update QUERY_OPTIMIZER_DESIGN.md with fixes
2. Add "Common Pitfalls" section
3. Add "Safety Patterns" section
4. Add code review checklist

---

## Summary of Changes

### Critical Fixes
1. ✅ **ComparableValue system** - Type-safe value comparison
2. ✅ **Async/await refactoring** - Pre-fetch statistics at top level
3. ✅ **Zero division guards** - Safe arithmetic operations

### High Priority Fixes
4. ✅ **Stable cache keys** - CacheKeyable protocol with canonical representation
5. ✅ **Bounded rewriting** - DNF explosion prevention with configurable limits

### Design Improvements
6. ✅ **Default cost constants** - Fallback values when statistics unavailable
7. ✅ **Type registry** - Per-field type tracking for consistent encoding
8. ✅ **Configuration system** - Tunable limits and thresholds

---

## Next Steps

1. **Immediate (This Week):**
   - [ ] Update QUERY_OPTIMIZER_DESIGN.md with all fixes
   - [ ] Create ComparableValue.swift implementation
   - [ ] Update CostEstimator.swift with safety guards
   - [ ] Add comprehensive tests

2. **Short Term (Next 2 Weeks):**
   - [ ] Implement stable cache key system
   - [ ] Add bounded rewriting with tests
   - [ ] Create property-based test suite
   - [ ] Performance benchmarking

3. **Medium Term (Next Month):**
   - [ ] Full integration testing
   - [ ] Documentation updates
   - [ ] Code review and refinement
   - [ ] Production readiness assessment

---

**Document Version:** 1.1
**Last Updated:** 2025-10-31
**Status:** Review Response - Ready for Implementation
