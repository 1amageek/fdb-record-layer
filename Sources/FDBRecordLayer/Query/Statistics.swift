import Foundation

// MARK: - Table Statistics

/// Statistics for a record type (table)
public struct TableStatistics: Codable, Sendable {
    /// Total number of records
    public let rowCount: Int64

    /// Average record size in bytes
    public let avgRowSize: Int

    /// When these statistics were collected
    public let timestamp: Date

    /// Sample rate used for collection (0.0-1.0)
    public let sampleRate: Double

    public init(
        rowCount: Int64,
        avgRowSize: Int,
        timestamp: Date = Date(),
        sampleRate: Double = 1.0
    ) {
        self.rowCount = max(rowCount, 0)
        self.avgRowSize = max(avgRowSize, 0)
        self.timestamp = timestamp
        self.sampleRate = max(0.0, min(1.0, sampleRate))
    }
}

// MARK: - Index Statistics

/// Statistics for an index
public struct IndexStatistics: Codable, Sendable {
    /// Index name
    public let indexName: String

    /// Number of distinct values (cardinality)
    public let distinctValues: Int64

    /// Number of null values
    public let nullCount: Int64

    /// Minimum value
    public let minValue: ComparableValue?

    /// Maximum value
    public let maxValue: ComparableValue?

    /// Histogram for selectivity estimation
    public let histogram: Histogram?

    /// When these statistics were collected
    public let timestamp: Date

    public init(
        indexName: String,
        distinctValues: Int64,
        nullCount: Int64,
        minValue: ComparableValue?,
        maxValue: ComparableValue?,
        histogram: Histogram?,
        timestamp: Date = Date()
    ) {
        self.indexName = indexName
        self.distinctValues = max(distinctValues, 0)
        self.nullCount = max(nullCount, 0)
        self.minValue = minValue
        self.maxValue = maxValue
        self.histogram = histogram
        self.timestamp = timestamp
    }
}

// MARK: - Histogram

/// Histogram for estimating data distribution and selectivity
public struct Histogram: Codable, Sendable {
    /// Histogram buckets
    public let buckets: [Bucket]

    /// Total number of values represented
    public let totalCount: Int64

    public struct Bucket: Codable, Sendable {
        /// Lower bound of bucket (inclusive)
        public let lowerBound: ComparableValue

        /// Upper bound of bucket (exclusive)
        public let upperBound: ComparableValue

        /// Number of values in this bucket
        public let count: Int64

        /// Number of distinct values in this bucket
        public let distinctCount: Int64

        public init(
            lowerBound: ComparableValue,
            upperBound: ComparableValue,
            count: Int64,
            distinctCount: Int64
        ) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
            self.count = max(count, 0)
            self.distinctCount = max(distinctCount, 0)
        }
    }

    public init(buckets: [Bucket], totalCount: Int64) {
        self.buckets = buckets
        self.totalCount = max(totalCount, 0)
    }

    // MARK: - Selectivity Estimation

    /// Estimate fraction of values matching a comparison
    ///
    /// - Parameters:
    ///   - comparison: The comparison operator
    ///   - value: The value to compare against
    /// - Returns: Estimated selectivity (0.0-1.0)
    public func estimateSelectivity(
        comparison: Comparison,
        value: ComparableValue
    ) -> Double {
        switch comparison {
        case .equals:
            return estimateEqualsSelectivity(value)
        case .notEquals:
            return 1.0 - estimateEqualsSelectivity(value)
        case .lessThan:
            return estimateRangeSelectivity(min: nil, max: value, maxInclusive: false)
        case .lessThanOrEquals:
            return estimateRangeSelectivity(min: nil, max: value, maxInclusive: true)
        case .greaterThan:
            return estimateRangeSelectivity(min: value, max: nil, minInclusive: false)
        case .greaterThanOrEquals:
            return estimateRangeSelectivity(min: value, max: nil, minInclusive: true)
        case .startsWith, .contains:
            // Conservative estimate for string operations
            return 0.1
        }
    }

    /// Estimate selectivity for equality comparison
    private func estimateEqualsSelectivity(_ value: ComparableValue) -> Double {
        guard totalCount > 0 else {
            return 0.0
        }

        guard let bucket = findBucket(value) else {
            return 0.0
        }

        // Uniform distribution assumption within bucket
        guard bucket.distinctCount > 0 else {
            return 0.0
        }

        return Double(bucket.count).safeDivide(
            by: Double(bucket.distinctCount * totalCount),
            default: 0.0
        )
    }

    /// Estimate selectivity for range comparison
    public func estimateRangeSelectivity(
        min: ComparableValue?,
        max: ComparableValue?,
        minInclusive: Bool = true,
        maxInclusive: Bool = true
    ) -> Double {
        guard totalCount > 0 else {
            return 0.0
        }

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
                // Estimate overlap fraction
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

        return Double(matchingCount).safeDivide(
            by: Double(totalCount),
            default: 0.0
        )
    }

    /// Find bucket containing a value
    private func findBucket(_ value: ComparableValue) -> Bucket? {
        // Check all buckets except last
        for (index, bucket) in buckets.enumerated() {
            let isLastBucket = (index == buckets.count - 1)

            if isLastBucket {
                // Last bucket: include upper bound
                if value >= bucket.lowerBound && value <= bucket.upperBound {
                    return bucket
                }
            } else {
                // Regular bucket: exclude upper bound
                if value >= bucket.lowerBound && value < bucket.upperBound {
                    return bucket
                }
            }
        }

        return nil
    }

    /// Check if a range overlaps with a bucket
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

    /// Estimate fraction of bucket overlapping with range
    private func estimateOverlapFraction(
        bucket: Bucket,
        rangeMin: ComparableValue?,
        rangeMax: ComparableValue?,
        minInclusive: Bool,
        maxInclusive: Bool
    ) -> Double {
        // Check if bucket is fully contained in range
        let fullyContained: Bool
        if let rangeMin = rangeMin, let rangeMax = rangeMax {
            fullyContained = bucket.lowerBound >= rangeMin && bucket.upperBound <= rangeMax
        } else if let rangeMin = rangeMin {
            fullyContained = bucket.lowerBound >= rangeMin
        } else if let rangeMax = rangeMax {
            fullyContained = bucket.upperBound <= rangeMax
        } else {
            // No bounds: fully contained
            fullyContained = true
        }

        if fullyContained {
            return 1.0
        }

        // Partial overlap: for numeric types, interpolate
        if bucket.lowerBound.isNumeric && bucket.upperBound.isNumeric,
           let bucketLower = bucket.lowerBound.asDouble(),
           let bucketUpper = bucket.upperBound.asDouble() {

            let effectiveMin: Double
            let effectiveMax: Double

            if let rangeMin = rangeMin?.asDouble() {
                effectiveMin = max(bucketLower, rangeMin)
            } else {
                effectiveMin = bucketLower
            }

            if let rangeMax = rangeMax?.asDouble() {
                effectiveMax = min(bucketUpper, rangeMax)
            } else {
                effectiveMax = bucketUpper
            }

            // Handle zero-width buckets
            let bucketWidth = bucketUpper - bucketLower
            guard bucketWidth > Double.epsilon else {
                // Zero-width bucket: check if range includes the point
                if let rangeMin = rangeMin?.asDouble(), let rangeMax = rangeMax?.asDouble() {
                    let pointInRange = bucketLower >= rangeMin && bucketLower <= rangeMax
                    return pointInRange ? 1.0 : 0.0
                }
                return 0.5 // Conservative estimate
            }

            // Handle invalid overlap (shouldn't happen, but be defensive)
            let overlapWidth = effectiveMax - effectiveMin
            guard overlapWidth >= -Double.epsilon else {
                return 0.0 // No overlap
            }

            return max(0.0, min(1.0, overlapWidth / bucketWidth))
        }

        // For non-numeric or mixed types: conservative estimate
        return 0.5
    }
}

// MARK: - Comparison Operators

public enum Comparison: String, Codable, Sendable {
    case equals
    case notEquals
    case lessThan
    case lessThanOrEquals
    case greaterThan
    case greaterThanOrEquals
    case startsWith
    case contains
}
