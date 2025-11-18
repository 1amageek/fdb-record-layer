import Foundation

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
public struct Vector: Equatable, Sendable {
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
