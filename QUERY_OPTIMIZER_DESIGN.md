# Query Planner Optimization - Complete Design

**Version:** 1.0
**Date:** 2025-10-31
**Status:** Design Phase

---

## Table of Contents

1. [Overview](#overview)
2. [Current State Analysis](#current-state-analysis)
3. [Architecture](#architecture)
4. [Statistics Management](#statistics-management)
5. [Cost-Based Optimization](#cost-based-optimization)
6. [Query Rewriting](#query-rewriting)
7. [Plan Enumeration](#plan-enumeration)
8. [Index Selection](#index-selection)
9. [Join Support](#join-support)
10. [Plan Caching](#plan-caching)
11. [Implementation Plan](#implementation-plan)
12. [Testing Strategy](#testing-strategy)
13. [Performance Benchmarks](#performance-benchmarks)

---

## Overview

### Purpose

This document describes the complete design for a production-ready query planner and optimizer for the FDB Record Layer. The optimizer will use cost-based optimization with statistics to generate efficient query execution plans.

### Goals

1. **Cost-Based Optimization**: Use statistics to estimate query costs accurately
2. **Multi-Index Support**: Leverage multiple indexes in a single query (intersection, union)
3. **Query Rewriting**: Transform queries into more efficient equivalent forms
4. **Join Support**: Support queries across multiple record types
5. **Plan Caching**: Cache plans for common query patterns
6. **Extensibility**: Allow custom optimization rules and cost models

### Non-Goals

- Distributed query execution (single FoundationDB cluster)
- SQL parsing (focus on programmatic query API)
- Query compilation to native code

---

## Current State Analysis

### Existing Implementation

**TypedRecordQueryPlanner** (Sources/FDBRecordLayer/Query/TypedRecordQueryPlanner.swift)

**✅ Implemented:**
- Basic index scan planning
- Simple cost estimation (hardcoded values)
- Index range construction for common operators
- Full scan fallback

**❌ Missing:**
- Statistics collection and management
- Accurate cost estimation based on data distribution
- Multiple plan candidate generation
- Query rewriting and normalization
- Join planning
- Plan caching
- Cardinality estimation
- Histogram-based selectivity

### Example: Current vs. Desired Behavior

```swift
// Query: Find users in Tokyo who are over 18
let query = TypedRecordQuery<User>()
    .filter(.and([
        .field("city", .equals("Tokyo")),
        .field("age", .greaterThan(18))
    ]))

// Current behavior:
// - Uses first matching index (city_index OR age_index)
// - Cost: hardcoded (100 for index scan, 1000000 for full scan)
// - No statistics used

// Desired behavior:
// - Collects statistics: city selectivity, age selectivity
// - Generates multiple plans:
//   Plan A: city_index → filter age (cost: 5000)
//   Plan B: age_index → filter city (cost: 12000)
//   Plan C: intersection(city_index, age_index) (cost: 3000)
// - Selects Plan C based on lowest estimated cost
```

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Query Layer                             │
│                  TypedRecordQuery<T>                         │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                 Query Optimizer                              │
│                                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   Query      │→│  Plan         │→│  Cost         │     │
│  │   Rewriter   │  │  Enumerator  │  │  Estimator   │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                           ↓                   ↑              │
│                    ┌──────────────┐   ┌──────────────┐     │
│                    │  Plan Cache  │   │  Statistics  │     │
│                    └──────────────┘   │   Manager    │     │
│                                        └──────────────┘     │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│               Query Execution Plans                          │
│  - IndexScanPlan                                             │
│  - IntersectionPlan                                          │
│  - UnionPlan                                                 │
│  - JoinPlan                                                  │
│  - FullScanPlan                                              │
└──────────────────────────────────────────────────────────────┘
```

### Key Components

1. **QueryRewriter**: Normalizes and rewrites queries to canonical forms
2. **PlanEnumerator**: Generates all valid execution plans for a query
3. **CostEstimator**: Estimates the cost of each plan using statistics
4. **StatisticsManager**: Collects and maintains table/index statistics
5. **PlanCache**: Caches optimized plans for reuse
6. **Execution Plans**: Physical operators that execute queries

---

## Statistics Management

### Overview

Statistics are essential for cost-based optimization. We track:
- **Table Statistics**: Total rows, average row size
- **Index Statistics**: Distinct values, null count, min/max values
- **Histograms**: Data distribution for selectivity estimation

### StatisticsManager

```swift
/// Manages statistics for cost-based optimization
public actor StatisticsManager: Sendable {
    private let database: any DatabaseProtocol
    private let subspace: Subspace

    // Statistics cache
    private var tableStats: [String: TableStatistics] = [:]
    private var indexStats: [String: IndexStatistics] = [:]

    /// Collect statistics for a record type
    /// - Parameters:
    ///   - recordType: The record type to analyze
    ///   - sampleRate: Sampling rate (0.0-1.0), 1.0 = full scan
    public func collectStatistics(
        recordType: String,
        sampleRate: Double = 0.1
    ) async throws {
        // Implementation below
    }

    /// Get table statistics
    public func getTableStatistics(
        recordType: String
    ) async throws -> TableStatistics? {
        if let cached = tableStats[recordType] {
            return cached
        }
        return try await loadTableStatistics(recordType: recordType)
    }

    /// Get index statistics
    public func getIndexStatistics(
        indexName: String
    ) async throws -> IndexStatistics? {
        if let cached = indexStats[indexName] {
            return cached
        }
        return try await loadIndexStatistics(indexName: indexName)
    }

    /// Estimate selectivity of a filter condition
    /// - Returns: Fraction of rows matching the condition (0.0-1.0)
    public func estimateSelectivity(
        filter: any TypedQueryComponent<Record>,
        recordType: String
    ) async throws -> Double {
        // Implementation below
    }
}
```

### Table Statistics

```swift
/// Statistics for a record type (table)
public struct TableStatistics: Codable, Sendable {
    /// Total number of records
    public let rowCount: Int64

    /// Average record size in bytes
    public let avgRowSize: Int

    /// When these statistics were collected
    public let timestamp: Date

    /// Sample rate used for collection
    public let sampleRate: Double
}
```

### Index Statistics

```swift
/// Statistics for an index
public struct IndexStatistics: Codable, Sendable {
    /// Index name
    public let indexName: String

    /// Number of distinct values (cardinality)
    public let distinctValues: Int64

    /// Number of null values
    public let nullCount: Int64

    /// Minimum value
    public let minValue: AnyCodable?

    /// Maximum value
    public let maxValue: AnyCodable?

    /// Histogram for selectivity estimation
    public let histogram: Histogram?

    /// When these statistics were collected
    public let timestamp: Date
}
```

### Histogram

```swift
/// Histogram for estimating data distribution
public struct Histogram: Codable, Sendable {
    /// Histogram buckets
    public let buckets: [Bucket]

    /// Total number of values represented
    public let totalCount: Int64

    public struct Bucket: Codable, Sendable {
        /// Lower bound of bucket (inclusive)
        public let lowerBound: AnyCodable

        /// Upper bound of bucket (exclusive)
        public let upperBound: AnyCodable

        /// Number of values in this bucket
        public let count: Int64

        /// Number of distinct values in this bucket
        public let distinctCount: Int64
    }

    /// Estimate fraction of values in a range
    public func estimateSelectivity(
        comparison: Comparison,
        value: AnyCodable
    ) -> Double {
        switch comparison {
        case .equals:
            return estimateEqualsSelectivity(value)
        case .lessThan:
            return estimateRangeSelectivity(min: nil, max: value, inclusive: false)
        case .lessThanOrEquals:
            return estimateRangeSelectivity(min: nil, max: value, inclusive: true)
        case .greaterThan:
            return estimateRangeSelectivity(min: value, max: nil, inclusive: false)
        case .greaterThanOrEquals:
            return estimateRangeSelectivity(min: value, max: nil, inclusive: true)
        default:
            return 0.1 // Default selectivity for unknown
        }
    }

    private func estimateEqualsSelectivity(_ value: AnyCodable) -> Double {
        guard let bucket = findBucket(value) else {
            return 0.0
        }

        // Assume uniform distribution within bucket
        if bucket.distinctCount > 0 {
            return Double(bucket.count) / Double(bucket.distinctCount * totalCount)
        }
        return 0.0
    }

    private func estimateRangeSelectivity(
        min: AnyCodable?,
        max: AnyCodable?,
        inclusive: Bool
    ) -> Double {
        var matchingCount: Int64 = 0

        for bucket in buckets {
            if rangeOverlaps(
                bucketMin: bucket.lowerBound,
                bucketMax: bucket.upperBound,
                rangeMin: min,
                rangeMax: max,
                inclusive: inclusive
            ) {
                matchingCount += bucket.count
            }
        }

        return Double(matchingCount) / Double(totalCount)
    }

    private func findBucket(_ value: AnyCodable) -> Bucket? {
        // Binary search for bucket containing value
        return buckets.first { bucket in
            value >= bucket.lowerBound && value < bucket.upperBound
        }
    }

    private func rangeOverlaps(
        bucketMin: AnyCodable,
        bucketMax: AnyCodable,
        rangeMin: AnyCodable?,
        rangeMax: AnyCodable?,
        inclusive: Bool
    ) -> Bool {
        // Check if bucket range overlaps with query range
        if let rangeMin = rangeMin, bucketMax <= rangeMin {
            return false
        }
        if let rangeMax = rangeMax, bucketMin >= rangeMax {
            return false
        }
        return true
    }
}
```

### Statistics Storage

```swift
/// Storage layout for statistics
/// Key: [subspace]["statistics"]["table"|"index"][name]
/// Value: Encoded TableStatistics or IndexStatistics

enum StatisticsKeyspace: String {
    case table = "table"
    case index = "index"
}

extension StatisticsManager {
    private func statisticsKey(type: StatisticsKeyspace, name: String) -> FDB.Bytes {
        return subspace
            .subspace("statistics")
            .subspace(type.rawValue)
            .pack(Tuple(name))
    }

    private func saveTableStatistics(
        recordType: String,
        stats: TableStatistics
    ) async throws {
        let key = statisticsKey(type: .table, name: recordType)
        let data = try JSONEncoder().encode(stats)

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            transaction.setValue(Array(data), for: key)
        }

        tableStats[recordType] = stats
    }

    private func loadTableStatistics(
        recordType: String
    ) async throws -> TableStatistics? {
        let key = statisticsKey(type: .table, name: recordType)

        return try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            guard let bytes = try await transaction.getValue(for: key) else {
                return nil
            }
            return try JSONDecoder().decode(TableStatistics.self, from: Data(bytes))
        }
    }
}
```

### Statistics Collection Implementation

```swift
extension StatisticsManager {
    /// Collect table statistics with sampling
    public func collectStatistics(
        recordType: String,
        sampleRate: Double = 0.1
    ) async throws {
        var rowCount: Int64 = 0
        var totalSize: Int64 = 0
        var sampledCount = 0

        // Scan records with sampling
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
            let (begin, end) = recordSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            for try await (key, value) in sequence {
                rowCount += 1

                // Sample based on rate
                if Double.random(in: 0..<1) < sampleRate {
                    totalSize += Int64(key.count + value.count)
                    sampledCount += 1
                }
            }
        }

        let avgRowSize = sampledCount > 0 ? Int(totalSize / Int64(sampledCount)) : 0

        let stats = TableStatistics(
            rowCount: rowCount,
            avgRowSize: avgRowSize,
            timestamp: Date(),
            sampleRate: sampleRate
        )

        try await saveTableStatistics(recordType: recordType, stats: stats)
    }

    /// Collect index statistics with histogram
    public func collectIndexStatistics(
        index: TypedIndex<Record>,
        bucketCount: Int = 100
    ) async throws {
        var distinctValues: Set<AnyCodable> = []
        var nullCount: Int64 = 0
        var minValue: AnyCodable?
        var maxValue: AnyCodable?
        var allValues: [AnyCodable] = []

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(index.subspaceTupleKey)

            let (begin, end) = indexSubspace.range()
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterThan(end),
                snapshot: true
            )

            for try await (key, _) in sequence {
                let tuple = try indexSubspace.unpack(key)
                guard let firstValue = tuple.elements.first else {
                    nullCount += 1
                    continue
                }

                let codableValue = AnyCodable(firstValue)
                distinctValues.insert(codableValue)
                allValues.append(codableValue)

                if minValue == nil || codableValue < minValue! {
                    minValue = codableValue
                }
                if maxValue == nil || codableValue > maxValue! {
                    maxValue = codableValue
                }
            }
        }

        // Build histogram
        let histogram = buildHistogram(
            values: allValues,
            bucketCount: bucketCount
        )

        let stats = IndexStatistics(
            indexName: index.name,
            distinctValues: Int64(distinctValues.count),
            nullCount: nullCount,
            minValue: minValue,
            maxValue: maxValue,
            histogram: histogram,
            timestamp: Date()
        )

        try await saveIndexStatistics(indexName: index.name, stats: stats)
    }

    private func buildHistogram(
        values: [AnyCodable],
        bucketCount: Int
    ) -> Histogram {
        guard !values.isEmpty else {
            return Histogram(buckets: [], totalCount: 0)
        }

        let sortedValues = values.sorted()
        let totalCount = Int64(sortedValues.count)
        let valuesPerBucket = max(1, sortedValues.count / bucketCount)

        var buckets: [Histogram.Bucket] = []

        for i in stride(from: 0, to: sortedValues.count, by: valuesPerBucket) {
            let endIndex = min(i + valuesPerBucket, sortedValues.count)
            let bucketValues = sortedValues[i..<endIndex]

            guard let lowerBound = bucketValues.first,
                  let upperBound = bucketValues.last else {
                continue
            }

            let distinctCount = Set(bucketValues).count

            buckets.append(Histogram.Bucket(
                lowerBound: lowerBound,
                upperBound: upperBound,
                count: Int64(bucketValues.count),
                distinctCount: Int64(distinctCount)
            ))
        }

        return Histogram(buckets: buckets, totalCount: totalCount)
    }
}

/// Type-erased Codable wrapper
public struct AnyCodable: Codable, Sendable, Hashable, Comparable {
    private enum ValueType: Codable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case null
    }

    private let value: ValueType

    public init(_ value: any TupleElement) {
        if let str = value as? String {
            self.value = .string(str)
        } else if let int = value as? Int64 {
            self.value = .int(int)
        } else if let double = value as? Double {
            self.value = .double(double)
        } else if let bool = value as? Bool {
            self.value = .bool(bool)
        } else {
            self.value = .null
        }
    }

    public static func < (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (.string(let l), .string(let r)): return l < r
        case (.int(let l), .int(let r)): return l < r
        case (.double(let l), .double(let r)): return l < r
        case (.bool(let l), .bool(let r)): return !l && r
        default: return false
        }
    }
}
```

---

## Cost-Based Optimization

### Cost Model

The cost estimator predicts the execution cost of a query plan. Cost components:

1. **I/O Cost**: Number of key-value pairs read from FoundationDB
2. **CPU Cost**: Processing overhead (deserialization, filtering)
3. **Network Cost**: Data transfer (usually negligible for local FDB)

```swift
/// Cost estimator for query plans
public struct CostEstimator: Sendable {
    private let statisticsManager: StatisticsManager

    /// Cost constants (tunable)
    private let ioReadCost: Double = 1.0        // Cost per KV read
    private let cpuDeserializeCost: Double = 0.1 // Cost per record deserialization
    private let cpuFilterCost: Double = 0.05    // Cost per filter evaluation

    public init(statisticsManager: StatisticsManager) {
        self.statisticsManager = statisticsManager
    }

    /// Estimate total cost of a plan
    public func estimateCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        return try await estimatePlanCost(plan, recordType: recordType)
    }

    private func estimatePlanCost<Record: Sendable>(
        _ plan: any TypedQueryPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        if let scanPlan = plan as? TypedFullScanPlan<Record> {
            return try await estimateFullScanCost(scanPlan, recordType: recordType)
        } else if let indexPlan = plan as? TypedIndexScanPlan<Record> {
            return try await estimateIndexScanCost(indexPlan, recordType: recordType)
        } else if let intersectionPlan = plan as? TypedIntersectionPlan<Record> {
            return try await estimateIntersectionCost(intersectionPlan, recordType: recordType)
        } else if let unionPlan = plan as? TypedUnionPlan<Record> {
            return try await estimateUnionCost(unionPlan, recordType: recordType)
        } else if let limitPlan = plan as? TypedLimitPlan<Record> {
            return try await estimateLimitCost(limitPlan, recordType: recordType)
        } else {
            // Unknown plan type, return high cost
            return QueryCost(
                ioCost: 1_000_000,
                cpuCost: 100_000,
                estimatedRows: 1_000_000
            )
        }
    }

    private func estimateFullScanCost<Record: Sendable>(
        _ plan: TypedFullScanPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        guard let tableStats = try await statisticsManager.getTableStatistics(recordType: recordType) else {
            // No statistics, use defaults
            return QueryCost(
                ioCost: 1_000_000,
                cpuCost: 100_000,
                estimatedRows: 1_000_000
            )
        }

        var estimatedRows = Double(tableStats.rowCount)
        var selectivity = 1.0

        // Apply filter selectivity
        if let filter = plan.filter {
            selectivity = try await statisticsManager.estimateSelectivity(
                filter: filter,
                recordType: recordType
            )
            estimatedRows *= selectivity
        }

        // Full scan reads all rows
        let ioCost = Double(tableStats.rowCount) * ioReadCost

        // CPU cost: deserialize + filter
        let cpuCost = Double(tableStats.rowCount) * (cpuDeserializeCost + cpuFilterCost)

        return QueryCost(
            ioCost: ioCost,
            cpuCost: cpuCost,
            estimatedRows: Int64(estimatedRows)
        )
    }

    private func estimateIndexScanCost<Record: Sendable>(
        _ plan: TypedIndexScanPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        guard let indexStats = try await statisticsManager.getIndexStatistics(indexName: plan.index.name),
              let tableStats = try await statisticsManager.getTableStatistics(recordType: recordType) else {
            // No statistics, estimate as better than full scan
            return QueryCost(
                ioCost: 10_000,
                cpuCost: 1_000,
                estimatedRows: 10_000
            )
        }

        // Estimate selectivity based on index range
        var selectivity = estimateIndexRangeSelectivity(
            beginValues: plan.beginValues,
            endValues: plan.endValues,
            indexStats: indexStats
        )

        // Apply filter selectivity if present
        if let filter = plan.filter {
            let filterSelectivity = try await statisticsManager.estimateSelectivity(
                filter: filter,
                recordType: recordType
            )
            selectivity *= filterSelectivity
        }

        let estimatedRows = Double(tableStats.rowCount) * selectivity

        // I/O: index scan + record lookups
        let indexIoCost = estimatedRows * ioReadCost
        let recordIoCost = estimatedRows * ioReadCost
        let totalIoCost = indexIoCost + recordIoCost

        // CPU: deserialize + filter
        let cpuCost = estimatedRows * (cpuDeserializeCost + cpuFilterCost)

        return QueryCost(
            ioCost: totalIoCost,
            cpuCost: cpuCost,
            estimatedRows: Int64(estimatedRows)
        )
    }

    private func estimateIntersectionCost<Record: Sendable>(
        _ plan: TypedIntersectionPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
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

        // Result size: product of selectivities (independence assumption)
        let totalSelectivity = childCosts.reduce(1.0) { result, cost in
            guard let tableStats = try? await statisticsManager.getTableStatistics(recordType: recordType) else {
                return result
            }
            let selectivity = Double(cost.estimatedRows) / Double(tableStats.rowCount)
            return result * selectivity
        }

        guard let tableStats = try? await statisticsManager.getTableStatistics(recordType: recordType) else {
            return QueryCost(
                ioCost: totalIoCost,
                cpuCost: 1000,
                estimatedRows: 100
            )
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

    private func estimateUnionCost<Record: Sendable>(
        _ plan: TypedUnionPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        // Union cost: sum of all children
        var totalIoCost = 0.0
        var totalCpuCost = 0.0
        var totalRows: Int64 = 0

        for child in plan.children {
            let cost = try await estimatePlanCost(child, recordType: recordType)
            totalIoCost += cost.ioCost
            totalCpuCost += cost.cpuCost
            totalRows += cost.estimatedRows
        }

        return QueryCost(
            ioCost: totalIoCost,
            cpuCost: totalCpuCost,
            estimatedRows: totalRows
        )
    }

    private func estimateLimitCost<Record: Sendable>(
        _ plan: TypedLimitPlan<Record>,
        recordType: String
    ) async throws -> QueryCost {
        let childCost = try await estimatePlanCost(plan.child, recordType: recordType)

        // Limit reduces cost proportionally
        let limitFactor = min(1.0, Double(plan.limit) / Double(childCost.estimatedRows))

        return QueryCost(
            ioCost: childCost.ioCost * limitFactor,
            cpuCost: childCost.cpuCost * limitFactor,
            estimatedRows: min(Int64(plan.limit), childCost.estimatedRows)
        )
    }

    private func estimateIndexRangeSelectivity(
        beginValues: [any TupleElement],
        endValues: [any TupleElement],
        indexStats: IndexStatistics
    ) -> Double {
        guard let histogram = indexStats.histogram,
              !beginValues.isEmpty || !endValues.isEmpty else {
            return 0.1 // Default selectivity
        }

        // Use histogram to estimate range selectivity
        // Simplified: assume uniform distribution
        if beginValues.isEmpty && endValues.isEmpty {
            return 1.0 // Full range
        }

        // For now, use simple heuristic
        // In production, use histogram properly
        return 0.1
    }
}

/// Query cost breakdown
public struct QueryCost: Sendable {
    /// I/O cost (number of reads)
    public let ioCost: Double

    /// CPU cost (processing)
    public let cpuCost: Double

    /// Estimated number of result rows
    public let estimatedRows: Int64

    /// Total cost (weighted sum)
    public var totalCost: Double {
        return ioCost + cpuCost * 0.1 // I/O dominates
    }
}
```

---

## Query Rewriting

### Query Rewriter

The query rewriter transforms queries into more efficient equivalent forms.

```swift
/// Query rewriter for optimization
public struct QueryRewriter<Record: Sendable> {

    /// Apply all rewrite rules
    public static func rewrite(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        var rewritten = filter

        // Rule 1: Push NOT down (De Morgan's laws)
        rewritten = pushNotDown(rewritten)

        // Rule 2: Convert to DNF (Disjunctive Normal Form)
        rewritten = convertToDNF(rewritten)

        // Rule 3: Flatten nested AND/OR
        rewritten = flattenBooleans(rewritten)

        // Rule 4: Remove redundant conditions
        rewritten = removeRedundant(rewritten)

        // Rule 5: Constant folding
        rewritten = foldConstants(rewritten)

        return rewritten
    }

    // MARK: - Rule 1: Push NOT Down

    private static func pushNotDown(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        if let notFilter = filter as? TypedNotQueryComponent<Record> {
            let inner = notFilter.child

            if let andFilter = inner as? TypedAndQueryComponent<Record> {
                // NOT (A AND B) → (NOT A) OR (NOT B)
                let negatedChildren = andFilter.children.map {
                    pushNotDown(TypedNotQueryComponent(child: $0))
                }
                return TypedOrQueryComponent(children: negatedChildren)
            } else if let orFilter = inner as? TypedOrQueryComponent<Record> {
                // NOT (A OR B) → (NOT A) AND (NOT B)
                let negatedChildren = orFilter.children.map {
                    pushNotDown(TypedNotQueryComponent(child: $0))
                }
                return TypedAndQueryComponent(children: negatedChildren)
            } else if let doubleNot = inner as? TypedNotQueryComponent<Record> {
                // NOT (NOT A) → A
                return pushNotDown(doubleNot.child)
            }
        }

        return filter
    }

    // MARK: - Rule 2: Convert to DNF

    private static func convertToDNF(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
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
                        return convertToDNF(TypedAndQueryComponent(children: newAnd))
                    }

                    return TypedOrQueryComponent(children: distributed)
                }
            }
        }

        return filter
    }

    // MARK: - Rule 3: Flatten Booleans

    private static func flattenBooleans(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            var flattened: [any TypedQueryComponent<Record>] = []

            for child in orFilter.children {
                let flatChild = flattenBooleans(child)
                if let nestedOr = flatChild as? TypedOrQueryComponent<Record> {
                    // Flatten: (A OR B) OR C → A OR B OR C
                    flattened.append(contentsOf: nestedOr.children)
                } else {
                    flattened.append(flatChild)
                }
            }

            return TypedOrQueryComponent(children: flattened)
        } else if let andFilter = filter as? TypedAndQueryComponent<Record> {
            var flattened: [any TypedQueryComponent<Record>] = []

            for child in andFilter.children {
                let flatChild = flattenBooleans(child)
                if let nestedAnd = flatChild as? TypedAndQueryComponent<Record> {
                    // Flatten: (A AND B) AND C → A AND B AND C
                    flattened.append(contentsOf: nestedAnd.children)
                } else {
                    flattened.append(flatChild)
                }
            }

            return TypedAndQueryComponent(children: flattened)
        }

        return filter
    }

    // MARK: - Rule 4: Remove Redundant

    private static func removeRedundant(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            // Remove duplicate conditions in AND
            let unique = removeDuplicates(andFilter.children)
            if unique.count == 1 {
                return unique[0]
            }
            return TypedAndQueryComponent(children: unique)
        } else if let orFilter = filter as? TypedOrQueryComponent<Record> {
            // Remove duplicate conditions in OR
            let unique = removeDuplicates(orFilter.children)
            if unique.count == 1 {
                return unique[0]
            }
            return TypedOrQueryComponent(children: unique)
        }

        return filter
    }

    private static func removeDuplicates(
        _ filters: [any TypedQueryComponent<Record>]
    ) -> [any TypedQueryComponent<Record>] {
        var seen: Set<String> = []
        var unique: [any TypedQueryComponent<Record>] = []

        for filter in filters {
            let key = String(describing: filter)
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(filter)
            }
        }

        return unique
    }

    // MARK: - Rule 5: Constant Folding

    private static func foldConstants(
        _ filter: any TypedQueryComponent<Record>
    ) -> any TypedQueryComponent<Record> {
        // Simplify constant expressions
        // Example: age > 18 AND age > 20 → age > 20

        // This is complex and requires semantic understanding
        // For now, return as-is
        return filter
    }
}
```

---

## Plan Enumeration

### Plan Enumerator

Generates all valid execution plans for a query.

```swift
/// Enumerates candidate execution plans
public struct PlanEnumerator<Record: Sendable> {
    private let recordType: TypedRecordType<Record>
    private let indexes: [TypedIndex<Record>]
    private let maxPlans: Int

    public init(
        recordType: TypedRecordType<Record>,
        indexes: [TypedIndex<Record>],
        maxPlans: Int = 100
    ) {
        self.recordType = recordType
        self.indexes = indexes
        self.maxPlans = maxPlans
    }

    /// Generate all candidate plans
    public func enumeratePlans(
        filter: (any TypedQueryComponent<Record>)?
    ) throws -> [any TypedQueryPlan<Record>] {
        var plans: [any TypedQueryPlan<Record>] = []

        // Plan 1: Full scan
        plans.append(TypedFullScanPlan(filter: filter))

        guard let filter = filter else {
            return plans
        }

        // Plan 2: Single index scans
        plans.append(contentsOf: try generateIndexScans(filter: filter))

        // Plan 3: Intersection plans (for AND conditions)
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            if let intersectionPlan = try generateIntersectionPlan(andFilter: andFilter) {
                plans.append(intersectionPlan)
            }
        }

        // Plan 4: Union plans (for OR conditions in DNF)
        if let orFilter = filter as? TypedOrQueryComponent<Record> {
            if let unionPlan = try generateUnionPlan(orFilter: orFilter) {
                plans.append(unionPlan)
            }
        }

        // Limit number of plans
        if plans.count > maxPlans {
            plans = Array(plans.prefix(maxPlans))
        }

        return plans
    }

    // MARK: - Index Scan Generation

    private func generateIndexScans(
        filter: any TypedQueryComponent<Record>
    ) throws -> [any TypedQueryPlan<Record>] {
        var plans: [any TypedQueryPlan<Record>] = []

        // Try each index
        for index in indexes {
            if let plan = try generateIndexScan(filter: filter, index: index) {
                plans.append(plan)
            }
        }

        // For AND conditions, try each child
        if let andFilter = filter as? TypedAndQueryComponent<Record> {
            for child in andFilter.children {
                for index in indexes {
                    if let plan = try generateIndexScan(filter: child, index: index) {
                        plans.append(plan)
                    }
                }
            }
        }

        return plans
    }

    private func generateIndexScan(
        filter: any TypedQueryComponent<Record>,
        index: TypedIndex<Record>
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Check if filter matches index
        guard let fieldFilter = filter as? TypedFieldQueryComponent<Record>,
              let fieldExpr = index.rootExpression as? TypedFieldKeyExpression<Record>,
              fieldExpr.fieldName == fieldFilter.fieldName else {
            return nil
        }

        // Build index range
        let (beginValues, endValues) = buildIndexRange(fieldFilter: fieldFilter)

        return TypedIndexScanPlan(
            index: index,
            beginValues: beginValues,
            endValues: endValues,
            filter: filter,
            primaryKeyLength: recordType.primaryKey.columnCount
        )
    }

    private func buildIndexRange(
        fieldFilter: TypedFieldQueryComponent<Record>
    ) -> (beginValues: [any TupleElement], endValues: [any TupleElement]) {
        let value = fieldFilter.value

        switch fieldFilter.comparison {
        case .equals:
            return ([value], [value])
        case .lessThan:
            return ([], [value])
        case .lessThanOrEquals:
            if let strValue = value as? String {
                return ([], [strValue + "\u{FFFF}"])
            }
            return ([], [value])
        case .greaterThan:
            if let strValue = value as? String {
                return ([strValue + "\u{FFFF}"], ["\u{FFFF}"])
            } else if let intValue = value as? Int64 {
                return ([intValue + 1], [Int64.max])
            }
            return ([value], [Int64.max])
        case .greaterThanOrEquals:
            return ([value], [Int64.max])
        case .startsWith:
            if let strValue = value as? String {
                return ([strValue], [strValue + "\u{FFFF}"])
            }
            return ([], [Int64.max])
        default:
            return ([], [Int64.max])
        }
    }

    // MARK: - Intersection Plan Generation

    private func generateIntersectionPlan(
        andFilter: TypedAndQueryComponent<Record>
    ) throws -> (any TypedQueryPlan<Record>)? {
        // Find index scans for each child
        var childPlans: [any TypedQueryPlan<Record>] = []

        for child in andFilter.children {
            for index in indexes {
                if let plan = try generateIndexScan(filter: child, index: index) {
                    childPlans.append(plan)
                    break // Use first matching index
                }
            }
        }

        // Need at least 2 index scans for intersection
        guard childPlans.count >= 2 else {
            return nil
        }

        return TypedIntersectionPlan(
            children: childPlans,
            comparisonKey: recordType.primaryKey.fieldNames
        )
    }

    // MARK: - Union Plan Generation

    private func generateUnionPlan(
        orFilter: TypedOrQueryComponent<Record>
    ) throws -> (any TypedQueryPlan<Record>)? {
        var childPlans: [any TypedQueryPlan<Record>] = []

        for child in orFilter.children {
            // Try to find index scan for each OR term
            var foundPlan: (any TypedQueryPlan<Record>)? = nil

            for index in indexes {
                if let plan = try generateIndexScan(filter: child, index: index) {
                    foundPlan = plan
                    break
                }
            }

            // Fallback to full scan if no index
            childPlans.append(foundPlan ?? TypedFullScanPlan(filter: child))
        }

        return TypedUnionPlan(children: childPlans)
    }
}
```

---

## Index Selection

### Index Selection Algorithm

The index selector chooses the best index(es) for a query based on:
1. Filter conditions
2. Sort order requirements
3. Statistics and selectivity

```swift
/// Index selection strategy
public struct IndexSelector<Record: Sendable> {
    private let indexes: [TypedIndex<Record>]
    private let statisticsManager: StatisticsManager

    public init(
        indexes: [TypedIndex<Record>],
        statisticsManager: StatisticsManager
    ) {
        self.indexes = indexes
        self.statisticsManager = statisticsManager
    }

    /// Select best index for a filter
    public func selectIndex(
        filter: any TypedQueryComponent<Record>,
        recordType: String
    ) async throws -> TypedIndex<Record>? {
        var candidates: [(TypedIndex<Record>, Double)] = []

        for index in indexes {
            if let selectivity = try await estimateIndexSelectivity(
                index: index,
                filter: filter,
                recordType: recordType
            ) {
                candidates.append((index, selectivity))
            }
        }

        // Select index with lowest selectivity (most selective)
        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    /// Select multiple indexes for intersection
    public func selectIntersectionIndexes(
        andFilter: TypedAndQueryComponent<Record>,
        recordType: String
    ) async throws -> [TypedIndex<Record>] {
        var selected: [TypedIndex<Record>] = []

        for child in andFilter.children {
            if let index = try await selectIndex(
                filter: child,
                recordType: recordType
            ) {
                selected.append(index)
            }
        }

        return selected
    }

    private func estimateIndexSelectivity(
        index: TypedIndex<Record>,
        filter: any TypedQueryComponent<Record>,
        recordType: String
    ) async throws -> Double? {
        // Check if index matches filter
        guard canUseIndex(index: index, filter: filter) else {
            return nil
        }

        // Get index statistics
        guard let indexStats = try await statisticsManager.getIndexStatistics(
            indexName: index.name
        ) else {
            return 0.1 // Default selectivity
        }

        // Estimate selectivity based on filter
        if let fieldFilter = filter as? TypedFieldQueryComponent<Record> {
            if let histogram = indexStats.histogram {
                return histogram.estimateSelectivity(
                    comparison: fieldFilter.comparison,
                    value: AnyCodable(fieldFilter.value)
                )
            }
        }

        return 0.1 // Default
    }

    private func canUseIndex(
        index: TypedIndex<Record>,
        filter: any TypedQueryComponent<Record>
    ) -> Bool {
        // Check if index can be used for this filter
        guard let fieldFilter = filter as? TypedFieldQueryComponent<Record>,
              let fieldExpr = index.rootExpression as? TypedFieldKeyExpression<Record> else {
            return false
        }

        return fieldExpr.fieldName == fieldFilter.fieldName
    }
}
```

---

## Join Support

### Join Planning

Support queries across multiple record types.

```swift
/// Join plan for querying multiple record types
public struct TypedJoinPlan<LeftRecord: Sendable, RightRecord: Sendable>: Sendable {
    public let leftPlan: any TypedQueryPlan<LeftRecord>
    public let rightPlan: any TypedQueryPlan<RightRecord>
    public let joinCondition: JoinCondition<LeftRecord, RightRecord>
    public let joinType: JoinType

    public enum JoinType: Sendable {
        case inner
        case leftOuter
        case rightOuter
        case fullOuter
    }

    public struct JoinCondition<L: Sendable, R: Sendable>: Sendable {
        public let leftKey: KeyExpression
        public let rightKey: KeyExpression
        public let comparison: Comparison

        public enum Comparison: Sendable {
            case equals
            case lessThan
            case greaterThan
        }
    }

    /// Execute join plan
    public func execute<LA: FieldAccessor, LS: RecordSerializer, RA: FieldAccessor, RS: RecordSerializer>(
        leftSubspace: Subspace,
        leftSerializer: LS,
        leftAccessor: LA,
        rightSubspace: Subspace,
        rightSerializer: RS,
        rightAccessor: RA,
        context: RecordContext
    ) async throws -> AnyJoinCursor<LeftRecord, RightRecord>
    where LA.Record == LeftRecord, LS.Record == LeftRecord,
          RA.Record == RightRecord, RS.Record == RightRecord {

        // Execute both sides
        let leftCursor = try await leftPlan.execute(
            subspace: leftSubspace,
            serializer: leftSerializer,
            accessor: leftAccessor,
            context: context
        )

        let rightCursor = try await rightPlan.execute(
            subspace: rightSubspace,
            serializer: rightSerializer,
            accessor: rightAccessor,
            context: context
        )

        // Create join cursor based on type
        switch joinType {
        case .inner:
            let joinCursor = InnerJoinCursor(
                leftCursor: leftCursor,
                rightCursor: rightCursor,
                joinCondition: joinCondition,
                leftAccessor: leftAccessor,
                rightAccessor: rightAccessor
            )
            return AnyJoinCursor(joinCursor)
        default:
            fatalError("Join type \(joinType) not yet implemented")
        }
    }
}

/// Join cursor for combining results
public protocol JoinCursor<Left, Right>: AsyncSequence where Element == (Left, Right) {
    associatedtype Left: Sendable
    associatedtype Right: Sendable
}

/// Inner join cursor
private struct InnerJoinCursor<Left: Sendable, Right: Sendable, LA: FieldAccessor, RA: FieldAccessor>: JoinCursor
where LA.Record == Left, RA.Record == Right {
    typealias Element = (Left, Right)

    let leftCursor: AnyTypedRecordCursor<Left>
    let rightCursor: AnyTypedRecordCursor<Right>
    let joinCondition: TypedJoinPlan<Left, Right>.JoinCondition<Left, Right>
    let leftAccessor: LA
    let rightAccessor: RA

    struct AsyncIterator: AsyncIteratorProtocol {
        var leftIterator: AnyTypedRecordCursor<Left>.AsyncIterator
        var rightIterator: AnyTypedRecordCursor<Right>.AsyncIterator
        let joinCondition: TypedJoinPlan<Left, Right>.JoinCondition<Left, Right>
        let leftAccessor: LA
        let rightAccessor: RA

        var rightRecords: [Right] = []
        var currentLeft: Left?
        var rightIndex: Int = 0

        mutating func next() async throws -> (Left, Right)? {
            // Nested loop join implementation
            while true {
                // Check if we have right records to join with current left
                if let left = currentLeft, rightIndex < rightRecords.count {
                    let right = rightRecords[rightIndex]
                    rightIndex += 1

                    if matchesJoinCondition(left: left, right: right) {
                        return (left, right)
                    }
                } else {
                    // Get next left record
                    guard let left = try await leftIterator.next() else {
                        return nil
                    }

                    currentLeft = left
                    rightIndex = 0

                    // Load all right records (for nested loop join)
                    // In production, use hash join or merge join
                    if rightRecords.isEmpty {
                        while let right = try await rightIterator.next() {
                            rightRecords.append(right)
                        }
                    }
                }
            }
        }

        private func matchesJoinCondition(left: Left, right: Right) -> Bool {
            // Evaluate join condition
            // For simplicity, only support equality for now
            guard case .equals = joinCondition.comparison else {
                return false
            }

            let leftValues = joinCondition.leftKey.evaluate(record: left as! any Message)
            let rightValues = joinCondition.rightKey.evaluate(record: right as! any Message)

            return leftValues == rightValues
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            leftIterator: leftCursor.makeAsyncIterator(),
            rightIterator: rightCursor.makeAsyncIterator(),
            joinCondition: joinCondition,
            leftAccessor: leftAccessor,
            rightAccessor: rightAccessor
        )
    }
}

/// Type-erased join cursor
public struct AnyJoinCursor<Left: Sendable, Right: Sendable>: JoinCursor {
    public typealias Element = (Left, Right)

    private let _makeAsyncIterator: () -> AnyAsyncIterator

    init<C: JoinCursor>(_ cursor: C) where C.Left == Left, C.Right == Right {
        _makeAsyncIterator = {
            AnyAsyncIterator(cursor.makeAsyncIterator())
        }
    }

    public struct AnyAsyncIterator: AsyncIteratorProtocol {
        private var _next: () async throws -> (Left, Right)?

        init<I: AsyncIteratorProtocol>(_ iterator: I) where I.Element == (Left, Right) {
            var iterator = iterator
            _next = {
                try await iterator.next()
            }
        }

        public mutating func next() async throws -> (Left, Right)? {
            return try await _next()
        }
    }

    public func makeAsyncIterator() -> AnyAsyncIterator {
        return _makeAsyncIterator()
    }
}
```

---

## Plan Caching

### Plan Cache

Cache optimized plans for reuse.

```swift
/// Cache for query plans
public actor PlanCache<Record: Sendable> {
    private var cache: [String: CachedPlan] = [:]
    private let maxSize: Int

    struct CachedPlan {
        let plan: any TypedQueryPlan<Record>
        let cost: QueryCost
        let timestamp: Date
        var hitCount: Int
    }

    public init(maxSize: Int = 1000) {
        self.maxSize = maxSize
    }

    /// Get cached plan for query
    public func get(query: TypedRecordQuery<Record>) -> (any TypedQueryPlan<Record>)? {
        let key = cacheKey(query: query)

        guard var cached = cache[key] else {
            return nil
        }

        // Update hit count
        cached.hitCount += 1
        cache[key] = cached

        return cached.plan
    }

    /// Store plan in cache
    public func put(
        query: TypedRecordQuery<Record>,
        plan: any TypedQueryPlan<Record>,
        cost: QueryCost
    ) {
        let key = cacheKey(query: query)

        // Evict if cache is full
        if cache.count >= maxSize {
            evictLRU()
        }

        cache[key] = CachedPlan(
            plan: plan,
            cost: cost,
            timestamp: Date(),
            hitCount: 0
        )
    }

    /// Clear cache
    public func clear() {
        cache.removeAll()
    }

    /// Get cache statistics
    public func getStats() -> CacheStats {
        let totalHits = cache.values.reduce(0) { $0 + $1.hitCount }
        return CacheStats(
            size: cache.count,
            totalHits: totalHits,
            avgHits: cache.isEmpty ? 0 : Double(totalHits) / Double(cache.count)
        )
    }

    private func cacheKey(query: TypedRecordQuery<Record>) -> String {
        // Generate cache key from query
        var key = ""

        if let filter = query.filter {
            key += String(describing: filter)
        }

        if let limit = query.limit {
            key += "_limit:\(limit)"
        }

        return key
    }

    private func evictLRU() {
        // Evict least recently used entry
        guard let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) else {
            return
        }
        cache.removeValue(forKey: oldest.key)
    }
}

public struct CacheStats: Sendable {
    public let size: Int
    public let totalHits: Int
    public let avgHits: Double
}
```

---

## Implementation Plan

### Phase 1: Statistics Foundation (Week 1-2)

**Tasks:**
- [ ] Implement `StatisticsManager` actor
- [ ] Implement `TableStatistics` and `IndexStatistics`
- [ ] Implement `Histogram` with selectivity estimation
- [ ] Statistics storage and persistence
- [ ] Statistics collection algorithms

**Deliverables:**
- `Sources/FDBRecordLayer/Query/StatisticsManager.swift`
- `Sources/FDBRecordLayer/Query/Statistics.swift`
- `Tests/FDBRecordLayerTests/StatisticsTests.swift`

**Validation:**
```swift
// Test: Collect and retrieve statistics
let manager = StatisticsManager(database: db, subspace: subspace)
try await manager.collectStatistics(recordType: "User", sampleRate: 0.1)

let stats = try await manager.getTableStatistics(recordType: "User")
XCTAssertNotNil(stats)
XCTAssertGreaterThan(stats!.rowCount, 0)
```

### Phase 2: Cost Estimator (Week 3)

**Tasks:**
- [ ] Implement `CostEstimator`
- [ ] Implement `QueryCost` model
- [ ] Cost estimation for all plan types
- [ ] Integration with statistics

**Deliverables:**
- `Sources/FDBRecordLayer/Query/CostEstimator.swift`
- `Tests/FDBRecordLayerTests/CostEstimatorTests.swift`

**Validation:**
```swift
// Test: Cost estimation with statistics
let estimator = CostEstimator(statisticsManager: manager)
let fullScanCost = try await estimator.estimateCost(fullScanPlan, recordType: "User")
let indexCost = try await estimator.estimateCost(indexScanPlan, recordType: "User")

XCTAssertLessThan(indexCost.totalCost, fullScanCost.totalCost)
```

### Phase 3: Query Rewriter (Week 4)

**Tasks:**
- [ ] Implement `QueryRewriter`
- [ ] Implement rewrite rules (NOT push-down, DNF, etc.)
- [ ] Integration with planner

**Deliverables:**
- `Sources/FDBRecordLayer/Query/QueryRewriter.swift`
- `Tests/FDBRecordLayerTests/QueryRewriterTests.swift`

**Validation:**
```swift
// Test: Query rewriting
let filter = TypedAndQueryComponent<User>(children: [
    TypedNotQueryComponent(
        child: TypedOrQueryComponent(children: [a, b])
    )
])

let rewritten = QueryRewriter.rewrite(filter)
// Should be: (NOT a) AND (NOT b)
```

### Phase 4: Plan Enumeration (Week 5)

**Tasks:**
- [ ] Implement `PlanEnumerator`
- [ ] Generate index scan, intersection, union plans
- [ ] Integration with planner

**Deliverables:**
- `Sources/FDBRecordLayer/Query/PlanEnumerator.swift`
- `Tests/FDBRecordLayerTests/PlanEnumeratorTests.swift`

**Validation:**
```swift
// Test: Plan enumeration
let enumerator = PlanEnumerator(recordType: userType, indexes: indexes)
let plans = try enumerator.enumeratePlans(filter: andFilter)

XCTAssertGreaterThan(plans.count, 1) // Multiple candidate plans
```

### Phase 5: Complete Planner (Week 6)

**Tasks:**
- [ ] Refactor `TypedRecordQueryPlanner` to use new components
- [ ] Integrate rewriter, enumerator, cost estimator
- [ ] Plan selection logic

**Deliverables:**
- Updated `Sources/FDBRecordLayer/Query/TypedRecordQueryPlanner.swift`
- Integration tests

**Validation:**
```swift
// Test: End-to-end optimization
let planner = TypedRecordQueryPlanner(recordType: userType, indexes: indexes)
let plan = try await planner.plan(complexQuery)

// Should select intersection plan for AND conditions
XCTAssertTrue(plan is TypedIntersectionPlan<User>)
```

### Phase 6: Plan Caching (Week 7)

**Tasks:**
- [ ] Implement `PlanCache`
- [ ] Cache key generation
- [ ] LRU eviction
- [ ] Integration with planner

**Deliverables:**
- `Sources/FDBRecordLayer/Query/PlanCache.swift`
- `Tests/FDBRecordLayerTests/PlanCacheTests.swift`

**Validation:**
```swift
// Test: Plan caching
let cache = PlanCache<User>()
cache.put(query: query, plan: plan, cost: cost)

let cached = cache.get(query: query)
XCTAssertNotNil(cached)
```

### Phase 7: Join Support (Week 8-9)

**Tasks:**
- [ ] Implement `TypedJoinPlan`
- [ ] Implement join cursors (inner, outer)
- [ ] Join cost estimation
- [ ] Join planner

**Deliverables:**
- `Sources/FDBRecordLayer/Query/JoinPlan.swift`
- `Tests/FDBRecordLayerTests/JoinTests.swift`

**Validation:**
```swift
// Test: Join execution
let joinPlan = TypedJoinPlan(
    leftPlan: userPlan,
    rightPlan: orderPlan,
    joinCondition: equalityCondition,
    joinType: .inner
)

let results = try await joinPlan.execute(...)
var count = 0
for try await (user, order) in results {
    count += 1
}
XCTAssertGreaterThan(count, 0)
```

### Phase 8: Performance Tuning (Week 10)

**Tasks:**
- [ ] Benchmark query performance
- [ ] Tune cost model constants
- [ ] Optimize statistics collection
- [ ] Performance regression tests

**Deliverables:**
- Performance benchmarks
- Tuning guide
- Benchmark suite

### Phase 9: Documentation (Week 11)

**Tasks:**
- [ ] API documentation
- [ ] Usage guide
- [ ] Migration guide
- [ ] Best practices

**Deliverables:**
- Complete API docs
- `QUERY_OPTIMIZATION_GUIDE.md`
- Examples

---

## Testing Strategy

### Unit Tests

**Coverage targets:**
- Statistics collection: 90%
- Cost estimation: 85%
- Query rewriting: 90%
- Plan enumeration: 85%

**Test categories:**
- Correctness tests
- Edge case tests
- Performance tests

### Integration Tests

**Scenarios:**
- End-to-end query optimization
- Statistics-driven plan selection
- Multi-index queries
- Join queries

### Performance Tests

**Benchmarks:**
- Query latency (p50, p99)
- Statistics collection time
- Plan enumeration time
- Memory usage

**Baseline:**
- Simple queries: < 1ms
- Complex queries: < 10ms
- Statistics collection (1M records): < 30s

---

## Performance Benchmarks

### Target Performance

| Metric | Target |
|--------|--------|
| Simple index scan | < 1ms |
| Complex AND query (intersection) | < 5ms |
| OR query (union) | < 10ms |
| Join query (10K x 10K) | < 100ms |
| Statistics collection (1M records, 10% sample) | < 30s |
| Plan cache hit | < 0.1ms |

### Comparison with Current Implementation

| Query Type | Current | Optimized | Improvement |
|------------|---------|-----------|-------------|
| AND (2 conditions) | 50ms (full scan) | 5ms (intersection) | 10x |
| OR (2 conditions) | 100ms (full scan) | 10ms (union) | 10x |
| Complex filter | 200ms | 20ms | 10x |

---

## Appendix A: Example Usage

### Example 1: Cost-Based Index Selection

```swift
import FDBRecordLayer

// Setup
let database = try FDBClient.openDatabase()
let subspace = Subspace(prefix: "myapp")

// Collect statistics
let statsManager = StatisticsManager(database: database, subspace: subspace)
try await statsManager.collectStatistics(recordType: "User", sampleRate: 0.1)

// Create planner with statistics
let planner = TypedRecordQueryPlanner(
    recordType: userType,
    indexes: [cityIndex, ageIndex],
    statisticsManager: statsManager
)

// Query: Users in Tokyo over 18
let query = TypedRecordQuery<User>()
    .filter(.and([
        .field("city", .equals("Tokyo")),      // 10% selectivity
        .field("age", .greaterThan(18))        // 80% selectivity
    ]))

// Planner generates candidates:
// 1. city_index → filter age (cost: 5000)
// 2. age_index → filter city (cost: 40000)
// 3. intersection(city_index, age_index) (cost: 3000)

let plan = try await planner.plan(query)
// Selects Plan 3: intersection (lowest cost)
```

### Example 2: Query Rewriting

```swift
// Query with NOT and OR
let query = TypedRecordQuery<User>()
    .filter(.not(
        .or([
            .field("status", .equals("inactive")),
            .field("deleted", .equals(true))
        ])
    ))

// Rewriter transforms to:
// AND(NOT(status = 'inactive'), NOT(deleted = true))

// Planner can now use indexes on 'status' and 'deleted'
let plan = try await planner.plan(query)
// Uses intersection of two index scans
```

### Example 3: Join Query

```swift
// Query: Users with their orders
let userQuery = TypedRecordQuery<User>()
    .filter(.field("status", .equals("active")))

let orderQuery = TypedRecordQuery<Order>()
    .filter(.field("status", .equals("pending")))

let joinPlan = TypedJoinPlan(
    leftPlan: try planner.plan(userQuery),
    rightPlan: try orderPlanner.plan(orderQuery),
    joinCondition: JoinCondition(
        leftKey: TypedFieldKeyExpression(fieldName: "id"),
        rightKey: TypedFieldKeyExpression(fieldName: "userId"),
        comparison: .equals
    ),
    joinType: .inner
)

let results = try await joinPlan.execute(...)

for try await (user, order) in results {
    print("User: \(user.name), Order: \(order.id)")
}
```

---

**Document Version:** 1.0
**Last Updated:** 2025-10-31
**Status:** Design Phase - Ready for Review
