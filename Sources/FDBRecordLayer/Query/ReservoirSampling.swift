import Foundation

/// Reservoir Sampling for histogram construction
///
/// Memory-efficient sampling algorithm that maintains a fixed-size sample
/// from a stream of unknown length. Each element has equal probability of
/// being included in the final sample.
///
/// **Usage:**
/// ```swift
/// var sampler = ReservoirSampling(reservoirSize: 10000)
/// for value in values {
///     sampler.add(value)
/// }
/// let histogram = sampler.buildHistogram(bucketCount: 100)
/// ```
///
/// **References:**
/// - J. Vitter, "Random Sampling with a Reservoir"
/// - https://en.wikipedia.org/wiki/Reservoir_sampling
public struct ReservoirSampling: Sendable {
    // MARK: - Properties

    /// Maximum number of samples to keep
    private let reservoirSize: Int

    /// Reservoir of sampled values
    private var reservoir: [ComparableValue]

    /// Total number of elements seen
    private var elementsSeen: Int64

    /// Random number generator for sampling
    private var rng: SeededRandomNumberGenerator

    // MARK: - Initialization

    /// Initialize reservoir sampling
    ///
    /// - Parameters:
    ///   - reservoirSize: Maximum number of samples to keep (default: 10,000)
    ///   - seed: Seed for random number generator (default: 0 for deterministic results)
    public init(reservoirSize: Int = 10_000, seed: UInt64 = 0) {
        self.reservoirSize = reservoirSize
        self.reservoir = []
        self.elementsSeen = 0
        self.rng = SeededRandomNumberGenerator(seed: seed)
    }

    // MARK: - Public API

    /// Add a value to the reservoir
    ///
    /// Uses Algorithm R (Vitter, 1985) for uniform random sampling.
    ///
    /// - Parameter value: The value to potentially sample
    public mutating func add(_ value: ComparableValue) {
        elementsSeen += 1

        if reservoir.count < reservoirSize {
            // Reservoir not full yet, add directly
            reservoir.append(value)
        } else {
            // Reservoir full, randomly replace with probability reservoirSize/elementsSeen
            let randomIndex = Int64.random(in: 0..<elementsSeen, using: &rng)
            if randomIndex < reservoirSize {
                reservoir[Int(randomIndex)] = value
            }
        }
    }

    /// Build histogram from sampled values
    ///
    /// Divides the value range into equal-width buckets and counts
    /// how many samples fall into each bucket.
    ///
    /// - Parameter bucketCount: Number of histogram buckets (default: 100)
    /// - Returns: Histogram with bucket boundaries and counts
    public func buildHistogram(bucketCount: Int = 100) -> Histogram {
        guard !reservoir.isEmpty else {
            return Histogram(buckets: [], totalCount: 0)
        }

        // Sort reservoir to find min/max and build histogram
        let sorted = reservoir.sorted()

        guard let minValue = sorted.first,
              let maxValue = sorted.last else {
            return Histogram(buckets: [], totalCount: 0)
        }

        // If all values are the same, return single bucket
        if minValue == maxValue {
            return Histogram(
                buckets: [Histogram.Bucket(
                    lowerBound: minValue,
                    upperBound: maxValue,
                    count: Int64(sorted.count),
                    distinctCount: 1
                )],
                totalCount: elementsSeen
            )
        }

        // Calculate bucket boundaries
        var buckets: [Histogram.Bucket] = []
        let actualBucketCount = min(bucketCount, sorted.count)

        for i in 0..<actualBucketCount {
            let startIdx = i * sorted.count / actualBucketCount
            let endIdx = (i + 1) * sorted.count / actualBucketCount

            guard startIdx < sorted.count else { break }

            let lowerBound = sorted[startIdx]
            let upperBound = (endIdx < sorted.count) ? sorted[endIdx - 1] : sorted.last!

            // Count values in this bucket
            let bucketValues = sorted[startIdx..<min(endIdx, sorted.count)]
            let count = Int64(bucketValues.count)

            // Estimate distinct count in bucket
            let distinctCount = Int64(Set(bucketValues).count)

            buckets.append(Histogram.Bucket(
                lowerBound: lowerBound,
                upperBound: upperBound,
                count: count,
                distinctCount: distinctCount
            ))
        }

        return Histogram(buckets: buckets, totalCount: elementsSeen)
    }

    /// Get current sample size
    ///
    /// - Returns: Number of values currently in the reservoir
    public func sampleSize() -> Int {
        return reservoir.count
    }

    /// Get total elements seen
    ///
    /// - Returns: Total number of elements that have been added
    public func totalElementsSeen() -> Int64 {
        return elementsSeen
    }

    /// Reset the sampler
    public mutating func reset() {
        reservoir.removeAll()
        elementsSeen = 0
    }
}

// MARK: - SeededRandomNumberGenerator

/// A simple seed-based random number generator that conforms to Sendable
///
/// Uses Linear Congruential Generator (LCG) algorithm for deterministic random numbers.
/// This is useful for reproducible sampling in statistics collection.
private struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xcbf29ce484222325 : seed
    }

    mutating func next() -> UInt64 {
        // LCG parameters (MMIX by Donald Knuth)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
