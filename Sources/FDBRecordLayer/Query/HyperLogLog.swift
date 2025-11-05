import Foundation

/// HyperLogLog cardinality estimator
///
/// Memory-efficient cardinality estimation using HyperLogLog algorithm.
/// Uses only ~12KB memory (16,384 registers × 6 bits) with ±2% accuracy.
///
/// **Usage:**
/// ```swift
/// var hll = HyperLogLog()
/// for value in values {
///     hll.add(value)
/// }
/// let estimatedCardinality = hll.cardinality()
/// ```
///
/// **References:**
/// - P. Flajolet et al., "HyperLogLog: the analysis of a near-optimal cardinality estimation algorithm"
/// - http://algo.inria.fr/flajolet/Publications/FlFuGaMe07.pdf
public struct HyperLogLog: Sendable {
    // MARK: - Properties

    /// Number of registers (2^14 = 16,384)
    private let numRegisters = 16384

    /// Registers storing the maximum number of leading zeros for each bucket
    private var registers: [UInt8]

    /// Alpha constant for bias correction
    /// alpha_m = 0.7213 / (1 + 1.079 / m) where m = numRegisters
    private let alpha: Double

    // MARK: - Initialization

    /// Initialize HyperLogLog estimator
    public init() {
        self.registers = Array(repeating: 0, count: 16384)
        // Alpha constant for 16,384 registers
        self.alpha = 0.7213 / (1.0 + 1.079 / 16384.0)
    }

    // MARK: - Public API

    /// Add a value to the estimator
    ///
    /// - Parameter value: The value to add
    public mutating func add(_ value: ComparableValue) {
        let hash = value.stableHash()

        // Use lower 14 bits for register index (2^14 = 16,384)
        let registerIndex = Int(hash & 0x3FFF)

        // Count leading zeros in remaining 50 bits
        let remainingBits = hash >> 14
        let leadingZeros = remainingBits == 0 ? 51 : remainingBits.leadingZeroBitCount
        let rho = UInt8(min(leadingZeros + 1, 255))

        // Update register with maximum
        registers[registerIndex] = max(registers[registerIndex], rho)
    }

    /// Estimate cardinality
    ///
    /// - Returns: Estimated number of distinct elements
    public func cardinality() -> Int64 {
        // Raw HyperLogLog estimate: alpha * m^2 / sum(2^(-M[j]))
        let harmonicMean = registers.reduce(0.0) { sum, register in
            sum + pow(2.0, -Double(register))
        }

        var estimate = alpha * Double(numRegisters * numRegisters) / harmonicMean

        // Small range correction (E < 5/2 * m)
        if estimate < 2.5 * Double(numRegisters) {
            let zeros = registers.filter { $0 == 0 }.count
            if zeros > 0 {
                // Small range correction using linear counting
                estimate = Double(numRegisters) * log(Double(numRegisters) / Double(zeros))
            }
        }

        // Large range correction (E > 1/30 * 2^32)
        if estimate > (1.0 / 30.0) * pow(2.0, 32.0) {
            estimate = -pow(2.0, 32.0) * log(1.0 - estimate / pow(2.0, 32.0))
        }

        return Int64(estimate)
    }

    /// Merge another HyperLogLog estimator into this one
    ///
    /// This allows combining estimates from multiple sources.
    ///
    /// - Parameter other: Another HyperLogLog estimator
    public mutating func merge(_ other: HyperLogLog) {
        for i in 0..<numRegisters {
            registers[i] = max(registers[i], other.registers[i])
        }
    }

    /// Reset the estimator
    public mutating func reset() {
        registers = Array(repeating: 0, count: numRegisters)
    }
}

// MARK: - ComparableValue Extension

extension ComparableValue {
    /// Compute a stable 64-bit hash for HyperLogLog
    ///
    /// This hash function must be:
    /// - Deterministic: same value always produces same hash
    /// - Uniformly distributed: minimize hash collisions
    /// - Stable across runs: same value produces same hash even after restart
    ///
    /// - Returns: 64-bit hash value
    func stableHash() -> UInt64 {
        var hasher = StableHasher()

        switch self {
        case .int64(let value):
            hasher.combine(Int64(0)) // Type discriminator
            hasher.combine(value)

        case .double(let value):
            hasher.combine(Int64(1)) // Type discriminator
            hasher.combine(value.bitPattern)

        case .string(let value):
            hasher.combine(Int64(2)) // Type discriminator
            hasher.combine(value)

        case .bool(let value):
            hasher.combine(Int64(3)) // Type discriminator
            hasher.combine(value)

        case .null:
            hasher.combine(Int64(4)) // Type discriminator
        }

        return hasher.finalize()
    }
}

// MARK: - StableHasher

/// A hasher that produces stable, deterministic hashes
///
/// Unlike Swift's built-in Hasher, this produces the same hash value
/// across different runs of the program, which is essential for
/// database statistics that need to be persisted.
private struct StableHasher {
    private var state: UInt64 = 0xcbf29ce484222325 // FNV-1a offset basis

    mutating func combine(_ value: Int64) {
        combine(UInt64(bitPattern: value))
    }

    mutating func combine(_ value: UInt64) {
        // FNV-1a hash algorithm
        let bytes = withUnsafeBytes(of: value) { Array($0) }
        for byte in bytes {
            state ^= UInt64(byte)
            state = state &* 0x100000001b3 // FNV-1a prime
        }
    }

    mutating func combine(_ value: String) {
        let bytes = value.utf8
        for byte in bytes {
            state ^= UInt64(byte)
            state = state &* 0x100000001b3
        }
    }

    mutating func combine(_ value: Bool) {
        combine(value ? Int64(1) : Int64(0))
    }

    func finalize() -> UInt64 {
        return state
    }
}
