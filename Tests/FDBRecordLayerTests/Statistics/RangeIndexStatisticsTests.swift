import Testing
import Foundation
@testable import FDBRecordLayer

/// Unit tests for RangeIndexStatistics
///
/// **Test Coverage**:
/// - Statistics construction and properties
/// - Selectivity estimation for different query widths
/// - Staleness check
/// - Codable conformance (JSON encoding/decoding)
/// - CustomStringConvertible output
@Suite("RangeIndexStatistics Tests")
struct RangeIndexStatisticsTests {

    // MARK: - Basic Properties

    @Test("Statistics construction with valid values")
    func testConstruction() throws {
        let now = Date()
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,  // 1 day in seconds
            overlapFactor: 5.2,
            selectivity: 0.05,
            collectedAt: now,
            sampleSize: 1_000
        )

        #expect(stats.totalRecords == 10_000)
        #expect(stats.avgRangeWidth == 86400)
        #expect(stats.overlapFactor == 5.2)
        #expect(stats.selectivity == 0.05)
        #expect(stats.collectedAt == now)
        #expect(stats.sampleSize == 1_000)
    }

    // MARK: - Selectivity Estimation

    @Test("Estimate selectivity for query width equal to average")
    func testEstimateSelectivityEqualToAverage() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,  // 1 day
            overlapFactor: 5.0,
            selectivity: 0.01,
            sampleSize: 1_000
        )

        // Query width = avgRangeWidth
        let queryWidth: Double = 86400
        let estimated = stats.estimateSelectivity(for: queryWidth)

        // Expected: (86400 / 86400) * 5.0 * 0.01 = 1.0 * 5.0 * 0.01 = 0.05
        #expect(estimated == 0.05)
    }

    @Test("Estimate selectivity for query width larger than average")
    func testEstimateSelectivityLargerThanAverage() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,  // 1 day
            overlapFactor: 5.0,
            selectivity: 0.01,
            sampleSize: 1_000
        )

        // Query width = 7 days (7x average)
        let queryWidth: Double = 7 * 86400
        let estimated = stats.estimateSelectivity(for: queryWidth)

        // Expected: (7 * 86400 / 86400) * 5.0 * 0.01 = 7.0 * 5.0 * 0.01 = 0.35
        // Use tolerance for floating point comparison
        #expect(abs(estimated - 0.35) < 0.0001)
    }

    @Test("Estimate selectivity for query width smaller than average")
    func testEstimateSelectivitySmallerThanAverage() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,  // 1 day
            overlapFactor: 5.0,
            selectivity: 0.01,
            sampleSize: 1_000
        )

        // Query width = 6 hours (0.25x average)
        let queryWidth: Double = 6 * 3600
        let estimated = stats.estimateSelectivity(for: queryWidth)

        // Expected: (6 * 3600 / 86400) * 5.0 * 0.01 = 0.25 * 5.0 * 0.01 = 0.0125
        #expect(estimated == 0.0125)
    }

    @Test("Selectivity is clamped to [0, 1]")
    func testSelectivityClampedToOne() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 100,
            overlapFactor: 50.0,  // High overlap
            selectivity: 0.5,
            sampleSize: 1_000
        )

        // Query width >> avgRangeWidth → selectivity would exceed 1.0
        let queryWidth: Double = 10_000
        let estimated = stats.estimateSelectivity(for: queryWidth)

        // Should be clamped to 1.0
        #expect(estimated <= 1.0)
    }

    @Test("Selectivity with zero avgRangeWidth returns base selectivity")
    func testSelectivityWithZeroAvgRangeWidth() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 0,  // Edge case
            overlapFactor: 5.0,
            selectivity: 0.05,
            sampleSize: 1_000
        )

        let queryWidth: Double = 86400
        let estimated = stats.estimateSelectivity(for: queryWidth)

        // Should return base selectivity
        #expect(estimated == 0.05)
    }

    // MARK: - Staleness Check

    @Test("Fresh statistics are not stale")
    func testFreshStatisticsNotStale() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,
            overlapFactor: 5.0,
            selectivity: 0.05,
            collectedAt: Date(),  // Now
            sampleSize: 1_000
        )

        #expect(!stats.isStale(threshold: 3600))  // 1 hour threshold
    }

    @Test("Old statistics are stale")
    func testOldStatisticsAreStale() throws {
        let twoHoursAgo = Date().addingTimeInterval(-7200)  // 2 hours ago
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,
            overlapFactor: 5.0,
            selectivity: 0.05,
            collectedAt: twoHoursAgo,
            sampleSize: 1_000
        )

        #expect(stats.isStale(threshold: 3600))  // 1 hour threshold
    }

    @Test("Statistics at threshold boundary")
    func testStalenessBoundary() throws {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,
            overlapFactor: 5.0,
            selectivity: 0.05,
            collectedAt: oneHourAgo,
            sampleSize: 1_000
        )

        // At the boundary (≈3600 seconds old), should be stale
        #expect(stats.isStale(threshold: 3600))
    }

    // MARK: - Codable Conformance

    @Test("JSON encoding and decoding")
    func testCodable() throws {
        let original = RangeIndexStatistics(
            totalRecords: 12_345,
            avgRangeWidth: 123.456,
            overlapFactor: 7.89,
            selectivity: 0.123,
            collectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sampleSize: 2_000
        )

        // Encode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(RangeIndexStatistics.self, from: data)

        // Verify
        #expect(decoded.totalRecords == original.totalRecords)
        #expect(decoded.avgRangeWidth == original.avgRangeWidth)
        #expect(decoded.overlapFactor == original.overlapFactor)
        #expect(decoded.selectivity == original.selectivity)
        #expect(decoded.sampleSize == original.sampleSize)
        #expect(abs(decoded.collectedAt.timeIntervalSince(original.collectedAt)) < 1.0)
    }

    // MARK: - CustomStringConvertible

    @Test("Description contains all key metrics")
    func testDescription() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,
            overlapFactor: 5.2,
            selectivity: 0.05,
            collectedAt: Date(),
            sampleSize: 1_000
        )

        let description = stats.description

        #expect(description.contains("10000"))  // totalRecords
        #expect(description.contains("86400"))  // avgRangeWidth
        #expect(description.contains("5.2"))    // overlapFactor
        #expect(description.contains("0.05"))   // selectivity
        #expect(description.contains("1000"))   // sampleSize
    }

    // MARK: - Edge Cases

    @Test("Statistics with zero totalRecords")
    func testZeroTotalRecords() throws {
        let stats = RangeIndexStatistics(
            totalRecords: 0,
            avgRangeWidth: 0,
            overlapFactor: 1.0,
            selectivity: 0.0,
            sampleSize: 0
        )

        #expect(stats.totalRecords == 0)
        #expect(stats.sampleSize == 0)
    }

    @Test("Statistics with maximum values")
    func testMaximumValues() throws {
        let stats = RangeIndexStatistics(
            totalRecords: UInt64.max,
            avgRangeWidth: Double.greatestFiniteMagnitude,
            overlapFactor: 1000.0,
            selectivity: 1.0,
            sampleSize: UInt64.max
        )

        #expect(stats.totalRecords == UInt64.max)
        #expect(stats.selectivity == 1.0)
    }

    @Test("Hashable conformance")
    func testHashable() throws {
        let stats1 = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,
            overlapFactor: 5.0,
            selectivity: 0.05,
            collectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sampleSize: 1_000
        )

        let stats2 = RangeIndexStatistics(
            totalRecords: 10_000,
            avgRangeWidth: 86400,
            overlapFactor: 5.0,
            selectivity: 0.05,
            collectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sampleSize: 1_000
        )

        #expect(stats1 == stats2)
        #expect(stats1.hashValue == stats2.hashValue)
    }
}
