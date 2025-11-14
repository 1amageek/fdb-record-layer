import Foundation

// MARK: - VectorRepresentable Protocol

/// Protocol for types that can be indexed as vectors
///
/// Any type conforming to this protocol can be used with the @Vector macro.
/// This allows users to define custom vector types (sparse vectors, quantized vectors, etc.)
/// while still benefiting from HNSW-based similarity search.
///
/// **Performance Consideration**:
/// The default implementations of distance methods call `toFloatArray()` multiple times:
/// - `dot()`: 2 calls (self + other)
/// - `l2Distance()`: 2 calls (self + other)
/// - `cosineSimilarity()`: 6 calls (self.dot(other): 2, self.dot(self): 2, other.dot(other): 2)
///
/// For types with expensive `toFloatArray()` conversion (e.g., SparseVector, QuantizedVector),
/// consider providing optimized custom implementations of these methods.
public protocol VectorRepresentable: Sendable {
    /// Number of dimensions in the vector
    var dimensions: Int { get }

    /// Convert to array of Float elements for indexing and distance calculations
    ///
    /// **Performance Note**: This method may be called multiple times per distance calculation.
    /// If conversion is expensive, consider:
    /// 1. Implementing custom distance methods (recommended)
    /// 2. Using lazy caching (memory tradeoff)
    ///
    /// - Returns: Dense float array representation
    func toFloatArray() -> [Float]

    /// Dot product with another vector
    ///
    /// Default implementation provided in protocol extension.
    /// Override for performance-critical types (e.g., SparseVector).
    ///
    /// - Parameter other: Another vector of the same type
    /// - Returns: Dot product value
    func dot(_ other: Self) -> Float

    /// L2 (Euclidean) distance to another vector
    ///
    /// Default implementation provided in protocol extension.
    /// Override for performance-critical types.
    ///
    /// - Parameter other: Another vector of the same type
    /// - Returns: L2 distance
    func l2Distance(to other: Self) -> Float

    /// Cosine similarity to another vector
    ///
    /// Default implementation provided in protocol extension.
    /// Override for performance-critical types.
    ///
    /// - Parameter other: Another vector of the same type
    /// - Returns: Cosine similarity (range: [-1, 1])
    func cosineSimilarity(to other: Self) -> Float
}

// MARK: - VectorRepresentable Default Implementations

extension VectorRepresentable {
    /// Default implementation of dot product using toFloatArray()
    ///
    /// **Performance**: Calls `toFloatArray()` twice (self + other)
    public func dot(_ other: Self) -> Float {
        let a = self.toFloatArray()
        let b = other.toFloatArray()
        precondition(a.count == b.count, "Vector dimensions must match")
        return zip(a, b).map(*).reduce(0, +)
    }

    /// Default implementation of L2 distance using toFloatArray()
    ///
    /// **Performance**: Calls `toFloatArray()` twice (self + other)
    public func l2Distance(to other: Self) -> Float {
        let a = self.toFloatArray()
        let b = other.toFloatArray()
        precondition(a.count == b.count, "Vector dimensions must match")
        let diff = zip(a, b).map { $0 - $1 }
        return sqrt(diff.map { $0 * $0 }.reduce(0, +))
    }

    /// Default implementation of cosine similarity using toFloatArray()
    ///
    /// **Performance**: Calls `toFloatArray()` 6 times
    /// (self.dot(other): 2, self.dot(self): 2, other.dot(other): 2)
    public func cosineSimilarity(to other: Self) -> Float {
        let dotProduct = self.dot(other)
        let magnitudeA = sqrt(self.dot(self))
        let magnitudeB = sqrt(other.dot(other))
        guard magnitudeA > 0 && magnitudeB > 0 else {
            return 0  // Zero vector
        }
        return dotProduct / (magnitudeA * magnitudeB)
    }
}

// MARK: - Vector (Standard Dense Vector Implementation)

/// Standard dense vector implementation for ML embeddings
///
/// This is the recommended type for most use cases (text embeddings, image embeddings, etc.)
///
/// **Usage**:
/// ```swift
/// // Basic initialization
/// let embedding = Vector([0.1, 0.2, 0.3, ...])  // 768 elements
///
/// // With dimension validation (recommended)
/// let embedding = try Vector(elements: data, expectedDimensions: 768)
/// ```
public struct Vector: VectorRepresentable, Equatable, Sendable {
    /// Vector elements (dense representation)
    public let elements: [Float]

    /// Number of dimensions
    public var dimensions: Int { elements.count }

    // MARK: - Initialization

    /// Initialize with Float array
    ///
    /// - Parameter elements: Vector elements
    /// - Note: For type safety, use `init(elements:expectedDimensions:)` when dimensions are known at compile time
    public init(_ elements: [Float]) {
        self.elements = elements
    }

    /// Initialize with Float array and validate dimensions
    ///
    /// This initializer validates that the number of elements matches the expected dimensions,
    /// catching dimension mismatches at initialization time rather than at save/query time.
    ///
    /// - Parameters:
    ///   - elements: Vector elements
    ///   - expectedDimensions: Expected number of dimensions (from @Vector macro)
    /// - Throws: `RecordLayerError.invalidArgument` if dimensions don't match
    ///
    /// **Recommended usage** when dimensions are known:
    /// ```swift
    /// // ✅ Good: Runtime validation
    /// let embedding = try Vector(elements: data, expectedDimensions: 768)
    ///
    /// // ⚠️ Risky: No validation
    /// let embedding = Vector(data)
    /// ```
    public init(elements: [Float], expectedDimensions: Int) throws {
        guard elements.count == expectedDimensions else {
            throw RecordLayerError.invalidArgument(
                "Vector dimension mismatch: expected \(expectedDimensions), got \(elements.count)"
            )
        }
        self.elements = elements
    }

    // MARK: - VectorRepresentable Implementation

    public func toFloatArray() -> [Float] {
        return elements  // O(1) - returns reference
    }

    // Note: dot(), l2Distance(), cosineSimilarity() use default implementations
    // from VectorRepresentable extension, which is optimal for dense vectors.

    // MARK: - Utility Methods

    /// Returns a normalized copy of this vector (unit length)
    ///
    /// Normalization is useful for:
    /// - Cosine similarity (pre-normalized vectors can use dot product directly)
    /// - Neural network inputs (some models expect normalized vectors)
    ///
    /// - Returns: Normalized vector (magnitude = 1.0), or self if magnitude is zero
    public func normalized() -> Vector {
        let magnitude = sqrt(elements.map { $0 * $0 }.reduce(0, +))
        guard magnitude > 0 else { return self }
        return Vector(elements.map { $0 / magnitude })
    }

    /// Computes the magnitude (length) of this vector
    ///
    /// - Returns: L2 norm (Euclidean length)
    public func magnitude() -> Float {
        return sqrt(elements.map { $0 * $0 }.reduce(0, +))
    }
}

// MARK: - Vector CustomStringConvertible

extension Vector: CustomStringConvertible {
    public var description: String {
        if elements.count <= 5 {
            return "Vector(\(elements))"
        } else {
            let preview = elements.prefix(3).map { String(format: "%.3f", $0) }.joined(separator: ", ")
            return "Vector([\(preview), ... (\(elements.count) dims)])"
        }
    }
}

// MARK: - Example Custom Vector Types (for reference)

/*
/// Example: Sparse vector for high-dimensional data with many zeros
///
/// This type demonstrates how to implement VectorRepresentable with optimized
/// distance calculations that avoid converting to dense representation.
///
/// **Performance**: O(nnz) instead of O(n) for dot product, where nnz = number of non-zero elements
public struct SparseVector: VectorRepresentable {
    public let indices: [Int]   // Indices of non-zero elements
    public let values: [Float]  // Non-zero values
    public let dimensions: Int  // Total dimensions (including zeros)

    public init(indices: [Int], values: [Float], dimensions: Int) {
        precondition(indices.count == values.count, "Indices and values must have same length")
        precondition(indices.allSatisfy { $0 >= 0 && $0 < dimensions }, "Indices must be in range [0, dimensions)")
        self.indices = indices
        self.values = values
        self.dimensions = dimensions
    }

    public func toFloatArray() -> [Float] {
        var dense = [Float](repeating: 0, count: dimensions)
        for (i, value) in zip(indices, values) {
            dense[i] = value
        }
        return dense
    }

    // ✅ Optimized implementation: O(nnz) instead of O(n)
    public func dot(_ other: Self) -> Float {
        var result: Float = 0
        var i = 0, j = 0
        while i < self.indices.count && j < other.indices.count {
            if self.indices[i] == other.indices[j] {
                result += self.values[i] * other.values[j]
                i += 1
                j += 1
            } else if self.indices[i] < other.indices[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    // l2Distance and cosineSimilarity can also be optimized similarly
}

/// Example: Quantized vector for memory-efficient storage (8-bit quantization)
///
/// This type demonstrates 8-bit quantization to reduce memory footprint by 4x
/// (4 bytes Float → 1 byte UInt8) with minimal accuracy loss.
public struct QuantizedVector: VectorRepresentable {
    public let quantized: [UInt8]  // 8-bit quantization
    public let scale: Float        // Dequantization scale
    public let offset: Float       // Dequantization offset
    public var dimensions: Int { quantized.count }

    public init(from vector: [Float]) {
        let min = vector.min() ?? 0
        let max = vector.max() ?? 1
        self.scale = (max - min) / 255.0
        self.offset = min
        self.quantized = vector.map { value in
            let normalized = (value - min) / (max - min)
            return UInt8(normalized * 255.0)
        }
    }

    public func toFloatArray() -> [Float] {
        return quantized.map { Float($0) * scale + offset }
    }

    // For better performance, implement custom distance methods that work
    // directly on quantized values where possible
}
*/
