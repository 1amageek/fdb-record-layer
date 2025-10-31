import Foundation

/// Type-safe comparable value for statistics and histogram operations
///
/// This enum provides a type-safe way to compare values across different types
/// without relying on unsafe type erasure. It supports the common types used
/// in FoundationDB tuple encoding.
public enum ComparableValue: Codable, Sendable, Hashable {
    case string(String)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null

    /// Initialize from a TupleElement
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

    /// Extract the underlying value as Any
    public func asAny() -> Any {
        switch self {
        case .string(let v): return v
        case .int64(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        }
    }

    /// Get string representation for debugging
    public var debugDescription: String {
        switch self {
        case .string(let v): return "\"\(v)\""
        case .int64(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .bool(let v): return "\(v)"
        case .null: return "null"
        }
    }
}

// MARK: - Comparable

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
            return !l && r  // false < true
        case (.null, .null):
            return false
        case (.null, _):
            return true  // null is always smallest
        case (_, .null):
            return false
        default:
            // Different types: use type ordering
            return lhs.typeOrder < rhs.typeOrder
        }
    }

    /// Order for cross-type comparison
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

// MARK: - Numeric Operations

extension ComparableValue {
    /// Check if this value is numeric
    public var isNumeric: Bool {
        switch self {
        case .int64, .double:
            return true
        default:
            return false
        }
    }

    /// Convert to Double if numeric
    public func asDouble() -> Double? {
        switch self {
        case .int64(let v):
            return Double(v)
        case .double(let v):
            return v
        default:
            return nil
        }
    }

    /// Add two values if both are numeric
    public static func + (lhs: ComparableValue, rhs: ComparableValue) -> ComparableValue? {
        guard let l = lhs.asDouble(), let r = rhs.asDouble() else {
            return nil
        }
        return .double(l + r)
    }

    /// Subtract two values if both are numeric
    public static func - (lhs: ComparableValue, rhs: ComparableValue) -> ComparableValue? {
        guard let l = lhs.asDouble(), let r = rhs.asDouble() else {
            return nil
        }
        return .double(l - r)
    }
}

// MARK: - Safe Arithmetic Helpers

extension Double {
    /// Epsilon for floating-point comparisons
    public static let epsilon: Double = 1e-10

    /// Safe division with default value
    public func safeDivide(by divisor: Double, default defaultValue: Double = 0.0) -> Double {
        guard abs(divisor) > Self.epsilon else {
            return defaultValue
        }
        return self / divisor
    }

    /// Check if approximately equal
    public func isApproximatelyEqual(to other: Double, epsilon: Double = Self.epsilon) -> Bool {
        return abs(self - other) < epsilon
    }
}

extension Int64 {
    /// Minimum value to avoid zero in estimates
    public static let minEstimate: Int64 = 1
}
