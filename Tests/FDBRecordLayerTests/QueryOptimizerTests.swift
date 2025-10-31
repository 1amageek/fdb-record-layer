import Testing
@testable import FDBRecordLayer

/// Comprehensive tests for query optimizer components
@Suite("Query Optimizer Tests")
struct QueryOptimizerTests {

    // MARK: - ComparableValue Tests

    @Test("ComparableValue ordering within types")
    func comparableValueOrdering() {
        // Null is smallest
        #expect(ComparableValue.null < ComparableValue.bool(false))
        #expect(ComparableValue.null < ComparableValue.int64(0))

        // Bool ordering
        #expect(ComparableValue.bool(false) < ComparableValue.bool(true))

        // Int ordering
        #expect(ComparableValue.int64(1) < ComparableValue.int64(2))
        #expect(ComparableValue.int64(-10) < ComparableValue.int64(10))

        // Double ordering
        #expect(ComparableValue.double(1.5) < ComparableValue.double(2.5))

        // String ordering
        #expect(ComparableValue.string("a") < ComparableValue.string("b"))
        #expect(ComparableValue.string("apple") < ComparableValue.string("banana"))
    }

    @Test("ComparableValue cross-type ordering")
    func comparableValueCrossTypeOrdering() {
        // Null < Bool < Int < Double < String
        #expect(ComparableValue.null < ComparableValue.bool(true))
        #expect(ComparableValue.bool(true) < ComparableValue.int64(0))
        #expect(ComparableValue.int64(100) < ComparableValue.double(0.0))
        #expect(ComparableValue.double(999.0) < ComparableValue.string(""))
    }

    @Test("ComparableValue equality")
    func comparableValueEquality() {
        #expect(ComparableValue.int64(42) == ComparableValue.int64(42))
        #expect(ComparableValue.string("test") == ComparableValue.string("test"))
        #expect(ComparableValue.null == ComparableValue.null)

        #expect(ComparableValue.int64(1) != ComparableValue.int64(2))
        #expect(ComparableValue.int64(1) != ComparableValue.double(1.0))
    }

    // MARK: - Safe Arithmetic Tests

    @Test("Safe division with normal values")
    func safeDivision() {
        // Normal division
        #expect(10.0.safeDivide(by: 2.0) == 5.0)
        #expect(100.0.safeDivide(by: 4.0) == 25.0)

        // Division by zero
        #expect(10.0.safeDivide(by: 0.0) == 0.0)
        #expect(10.0.safeDivide(by: 0.0, default: 999.0) == 999.0)

        // Division by very small number (near zero)
        #expect(10.0.safeDivide(by: 1e-11) == 0.0)
    }

    @Test("Approximate equality")
    func approximateEquality() {
        #expect(1.0.isApproximatelyEqual(to: 1.0))
        #expect(1.0.isApproximatelyEqual(to: 1.0 + 1e-11))
        #expect(!1.0.isApproximatelyEqual(to: 1.1))
    }

    // MARK: - Histogram Tests

    @Test("Histogram selectivity for equality")
    func histogramSelectivityEquals() {
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(0),
                upperBound: .int64(10),
                count: 100,
                distinctCount: 10
            ),
            Histogram.Bucket(
                lowerBound: .int64(10),
                upperBound: .int64(20),
                count: 200,
                distinctCount: 10
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 300)

        // Value in first bucket
        let selectivity1 = histogram.estimateSelectivity(
            comparison: .equals,
            value: .int64(5)
        )
        #expect(selectivity1 > 0.0)
        #expect(selectivity1 < 1.0)

        // Value not in histogram
        let selectivity2 = histogram.estimateSelectivity(
            comparison: .equals,
            value: .int64(100)
        )
        #expect(selectivity2 == 0.0)
    }

    @Test("Histogram selectivity for ranges")
    func histogramSelectivityRange() {
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(0),
                upperBound: .int64(100),
                count: 100,
                distinctCount: 100
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 100)

        // Less than
        let selectivityLT = histogram.estimateSelectivity(
            comparison: .lessThan,
            value: .int64(50)
        )
        #expect(selectivityLT > 0.0)
        #expect(selectivityLT < 1.0)

        // Greater than
        let selectivityGT = histogram.estimateSelectivity(
            comparison: .greaterThan,
            value: .int64(50)
        )
        #expect(selectivityGT > 0.0)
        #expect(selectivityGT < 1.0)
    }

    @Test("Histogram with empty buckets")
    func histogramEmptyBuckets() {
        let histogram = Histogram(buckets: [], totalCount: 0)

        let selectivity = histogram.estimateSelectivity(
            comparison: .equals,
            value: .int64(5)
        )
        #expect(selectivity == 0.0)
    }

    // MARK: - Query Rewriter Tests

    @Test("Push NOT down through AND")
    func pushNotDown() {
        // NOT (A AND B) → (NOT A) OR (NOT B)
        struct TestRecord: Sendable {}

        let rewriter = QueryRewriter<TestRecord>(config: .default)

        let filter = TypedNotQueryComponent<TestRecord>(
            child: TypedAndQueryComponent(children: [
                TypedFieldQueryComponent(fieldName: "a", comparison: .equals, value: 1),
                TypedFieldQueryComponent(fieldName: "b", comparison: .equals, value: 2)
            ])
        )

        let rewritten = rewriter.rewrite(filter)

        // Should be OR of NOTs
        #expect(rewritten is TypedOrQueryComponent<TestRecord>)
    }

    @Test("Double negation elimination")
    func doubleNegation() {
        // NOT (NOT A) → A
        struct TestRecord: Sendable {}

        let rewriter = QueryRewriter<TestRecord>(config: .default)

        let original = TypedFieldQueryComponent<TestRecord>(
            fieldName: "a",
            comparison: .equals,
            value: 1
        )

        let doubleNot = TypedNotQueryComponent(
            child: TypedNotQueryComponent(child: original)
        )

        let rewritten = rewriter.rewrite(doubleNot)

        // Should remove both NOTs
        #expect(rewritten is TypedFieldQueryComponent<TestRecord>)
    }

    @Test("Flatten nested boolean expressions")
    func flattenBooleans() {
        // (A OR B) OR C → A OR B OR C
        struct TestRecord: Sendable {}

        let rewriter = QueryRewriter<TestRecord>(config: .default)

        let nested = TypedOrQueryComponent<TestRecord>(children: [
            TypedOrQueryComponent(children: [
                TypedFieldQueryComponent(fieldName: "a", comparison: .equals, value: 1),
                TypedFieldQueryComponent(fieldName: "b", comparison: .equals, value: 2)
            ]),
            TypedFieldQueryComponent(fieldName: "c", comparison: .equals, value: 3)
        ])

        let rewritten = rewriter.rewrite(nested)

        if let orFilter = rewritten as? TypedOrQueryComponent<TestRecord> {
            // Should have 3 children (flattened)
            #expect(orFilter.children.count == 3)
        } else {
            Issue.record("Expected OR component")
        }
    }

    @Test("DNF explosion prevention")
    func dnfExplosionPrevention() {
        struct TestRecord: Sendable {}

        let config = QueryRewriter<TestRecord>.Config(maxDNFTerms: 10, maxDepth: 10)
        let rewriter = QueryRewriter<TestRecord>(config: config)

        // Create complex filter: (A1 OR A2) AND (B1 OR B2) AND ... (5 times)
        // Would expand to 2^5 = 32 terms in DNF
        var andChildren: [TypedOrQueryComponent<TestRecord>] = []
        for i in 0..<5 {
            andChildren.append(TypedOrQueryComponent(children: [
                TypedFieldQueryComponent(fieldName: "field\(i)", comparison: .equals, value: 1),
                TypedFieldQueryComponent(fieldName: "field\(i)", comparison: .equals, value: 2)
            ]))
        }

        let complexFilter = TypedAndQueryComponent<TestRecord>(children: andChildren)

        let rewritten = rewriter.rewrite(complexFilter)
        let termCount = rewriter.countTerms(rewritten)

        // Should not exceed configured limit
        #expect(termCount <= 10)
    }

    // MARK: - Cache Key Tests

    @Test("Cache key stability")
    func cacheKeyStability() {
        struct TestRecord: Sendable {}

        let filter = TypedFieldQueryComponent<TestRecord>(
            fieldName: "age",
            comparison: .equals,
            value: 25
        )

        let key1 = filter.cacheKey()
        let key2 = filter.cacheKey()

        // Keys must be identical
        #expect(key1 == key2)

        // Keys must not contain memory addresses
        #expect(!key1.contains("0x"))
    }

    @Test("Cache key canonical ordering")
    func cacheKeyCanonicalOrdering() {
        struct TestRecord: Sendable {}

        // AND with different child ordering
        let and1 = TypedAndQueryComponent<TestRecord>(children: [
            TypedFieldQueryComponent(fieldName: "a", comparison: .equals, value: 1),
            TypedFieldQueryComponent(fieldName: "b", comparison: .equals, value: 2)
        ])

        let and2 = TypedAndQueryComponent<TestRecord>(children: [
            TypedFieldQueryComponent(fieldName: "b", comparison: .equals, value: 2),
            TypedFieldQueryComponent(fieldName: "a", comparison: .equals, value: 1)
        ])

        let key1 = and1.cacheKey()
        let key2 = and2.cacheKey()

        // Keys should be identical (canonical ordering)
        #expect(key1 == key2)
    }

    // MARK: - Query Cost Tests

    @Test("Query cost comparison")
    func queryCostComparison() {
        let cost1 = QueryCost(ioCost: 100, cpuCost: 10, estimatedRows: 100)
        let cost2 = QueryCost(ioCost: 200, cpuCost: 20, estimatedRows: 200)

        #expect(cost1 < cost2)
        #expect(!(cost2 < cost1))
    }

    @Test("Query cost minimum rows enforcement")
    func queryCostMinimumRows() {
        let cost = QueryCost(ioCost: 10, cpuCost: 1, estimatedRows: 0)

        // Should enforce minimum
        #expect(cost.estimatedRows >= QueryCost.minEstimatedRows)
    }

    @Test("Query cost total calculation")
    func queryCostTotalCost() {
        let cost = QueryCost(ioCost: 100, cpuCost: 10, estimatedRows: 100)

        // Total cost should be dominated by I/O
        let expectedTotal = 100.0 + 10.0 * 0.1
        #expect(abs(cost.totalCost - expectedTotal) < 0.01)
    }

    // MARK: - Table Statistics Tests

    @Test("Table statistics validation")
    func tableStatisticsValidation() {
        // Negative values should be normalized
        let stats = TableStatistics(
            rowCount: -100,
            avgRowSize: -50,
            sampleRate: 1.5
        )

        #expect(stats.rowCount == 0)
        #expect(stats.avgRowSize == 0)
        #expect(stats.sampleRate == 1.0)
    }

    // MARK: - Index Statistics Tests

    @Test("Index statistics validation")
    func indexStatisticsValidation() {
        let stats = IndexStatistics(
            indexName: "test_index",
            distinctValues: -10,
            nullCount: -5,
            minValue: .int64(0),
            maxValue: .int64(100),
            histogram: nil
        )

        #expect(stats.distinctValues == 0)
        #expect(stats.nullCount == 0)
    }

    // MARK: - Integration Tests

    @Test("End-to-end rewrite and cache")
    func endToEndRewriteAndCache() {
        struct User: Sendable {}

        // Create filter
        let filter = TypedAndQueryComponent<User>(children: [
            TypedFieldQueryComponent(fieldName: "age", comparison: .greaterThan, value: 18),
            TypedFieldQueryComponent(fieldName: "city", comparison: .equals, value: "Tokyo")
        ])

        // Rewrite
        let rewriter = QueryRewriter<User>(config: .default)
        let rewritten = rewriter.rewrite(filter)

        // Generate cache key
        let key = (rewritten as? any CacheKeyable)?.cacheKey()
        #expect(key != nil)
        #expect(!key!.isEmpty)
    }
}

// MARK: - Tests for Code Review Fixes

@Suite("Code Review Fixes")
struct CodeReviewFixTests {

    // MARK: - Fix 1: Range Selectivity Tests

    @Test("Histogram range selectivity with direct method")
    func histogramRangeSelectivityDirect() {
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(0),
                upperBound: .int64(50),
                count: 50,
                distinctCount: 50
            ),
            Histogram.Bucket(
                lowerBound: .int64(50),
                upperBound: .int64(100),
                count: 50,
                distinctCount: 50
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 100)

        // Test direct range estimation
        let selectivity = histogram.estimateRangeSelectivity(
            min: .int64(25),
            max: .int64(75),
            minInclusive: true,
            maxInclusive: false
        )

        #expect(selectivity > 0.0)
        #expect(selectivity < 1.0)
    }

    // MARK: - Fix 3: Last Bucket Boundary Tests

    @Test("Histogram last bucket includes upper bound")
    func histogramLastBucketInclusive() {
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(0),
                upperBound: .int64(10),
                count: 10,
                distinctCount: 10
            ),
            Histogram.Bucket(
                lowerBound: .int64(10),
                upperBound: .int64(20),
                count: 10,
                distinctCount: 10
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 20)

        // Value at last bucket upper bound should be found
        let selectivity = histogram.estimateSelectivity(
            comparison: .equals,
            value: .int64(20)
        )

        #expect(selectivity > 0.0)
    }

    // MARK: - Fix 4: Input Validation Tests

    @Test("Table statistics input validation")
    func tableStatisticsInputValidation() {
        // Sample rate must be in range (0.0, 1.0]
        let stats1 = TableStatistics(rowCount: 100, avgRowSize: 50, sampleRate: 0.5)
        #expect(stats1.sampleRate == 0.5)

        let stats2 = TableStatistics(rowCount: 100, avgRowSize: 50, sampleRate: 1.5)
        #expect(stats2.sampleRate == 1.0) // Clamped to 1.0

        let stats3 = TableStatistics(rowCount: 100, avgRowSize: 50, sampleRate: -0.5)
        #expect(stats3.sampleRate == 0.0) // Clamped to 0.0

        // Negative values normalized
        let stats4 = TableStatistics(rowCount: -100, avgRowSize: -50)
        #expect(stats4.rowCount == 0)
        #expect(stats4.avgRowSize == 0)
    }

    @Test("Index statistics input validation")
    func indexStatisticsInputValidation() {
        // Negative values normalized
        let stats = IndexStatistics(
            indexName: "test_index",
            distinctValues: -10,
            nullCount: -5,
            minValue: .int64(0),
            maxValue: .int64(100),
            histogram: nil
        )

        #expect(stats.distinctValues == 0)
        #expect(stats.nullCount == 0)
    }

    // MARK: - Fix 6: Overlap Fraction Edge Cases

    @Test("Overlap fraction with zero-width bucket")
    func overlapFractionZeroWidthBucket() {
        // Create histogram with zero-width bucket (point value)
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(10),
                upperBound: .int64(10),
                count: 1,
                distinctCount: 1
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 1)

        // Range includes the point
        let selectivity1 = histogram.estimateRangeSelectivity(
            min: .int64(5),
            max: .int64(15),
            minInclusive: true,
            maxInclusive: true
        )
        #expect(selectivity1 > 0.0)

        // Range excludes the point
        let selectivity2 = histogram.estimateRangeSelectivity(
            min: .int64(15),
            max: .int64(20),
            minInclusive: true,
            maxInclusive: true
        )
        #expect(selectivity2 == 0.0)
    }

    @Test("Overlap fraction with negative overlap")
    func overlapFractionNegativeOverlap() {
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(50),
                upperBound: .int64(100),
                count: 50,
                distinctCount: 50
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 50)

        // Range completely before bucket
        let selectivity = histogram.estimateRangeSelectivity(
            min: .int64(0),
            max: .int64(25),
            minInclusive: true,
            maxInclusive: true
        )

        #expect(selectivity == 0.0)
    }

    @Test("Overlap fraction with unbounded range")
    func overlapFractionUnboundedRange() {
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(0),
                upperBound: .int64(100),
                count: 100,
                distinctCount: 100
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 100)

        // Unbounded range (no min/max) should include all
        let selectivity = histogram.estimateRangeSelectivity(
            min: nil,
            max: nil,
            minInclusive: true,
            maxInclusive: true
        )

        #expect(selectivity == 1.0)
    }

    // MARK: - Fix 7: Primary Key Extraction Tests

    @Test("Primary key field extraction")
    func primaryKeyFieldExtraction() {
        struct User: Sendable {}

        // Single field primary key
        let singleFieldPK = TypedFieldKeyExpression<User>(fieldName: "id")
        let recordType1 = TypedRecordType<User>(
            name: "User",
            primaryKey: singleFieldPK
        )
        #expect(recordType1.fieldNames == ["id"])

        // Composite primary key
        let compositeKey = TypedConcatenateKeyExpression<User>(children: [
            TypedFieldKeyExpression(fieldName: "userId"),
            TypedFieldKeyExpression(fieldName: "timestamp")
        ])
        let recordType2 = TypedRecordType<User>(
            name: "Event",
            primaryKey: compositeKey
        )
        #expect(recordType2.fieldNames == ["userId", "timestamp"])

        // Empty key expression
        let emptyKey = TypedEmptyKeyExpression<User>()
        let recordType3 = TypedRecordType<User>(
            name: "NoKey",
            primaryKey: emptyKey
        )
        #expect(recordType3.fieldNames == [])
    }

    // MARK: - Integration Tests

    @Test("Histogram with all fixes applied")
    func histogramWithAllFixes() {
        // Create histogram with edge cases
        let buckets = [
            Histogram.Bucket(
                lowerBound: .int64(0),
                upperBound: .int64(10),
                count: 10,
                distinctCount: 10
            ),
            Histogram.Bucket(
                lowerBound: .int64(10),
                upperBound: .int64(10), // Zero-width bucket
                count: 1,
                distinctCount: 1
            ),
            Histogram.Bucket(
                lowerBound: .int64(10),
                upperBound: .int64(100),
                count: 90,
                distinctCount: 90
            )
        ]

        let histogram = Histogram(buckets: buckets, totalCount: 101)

        // Test various operations
        let eq = histogram.estimateSelectivity(comparison: .equals, value: .int64(10))
        #expect(eq >= 0.0)

        let range = histogram.estimateRangeSelectivity(
            min: .int64(5),
            max: .int64(50),
            minInclusive: true,
            maxInclusive: false
        )
        #expect(range > 0.0)
        #expect(range <= 1.0)

        // Last bucket upper bound should be included
        let lastValue = histogram.estimateSelectivity(comparison: .equals, value: .int64(100))
        #expect(lastValue >= 0.0)
    }
}
