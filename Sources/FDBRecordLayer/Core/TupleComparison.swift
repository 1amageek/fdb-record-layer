import Foundation

/// Utility for comparing TupleElement values
///
/// Provides type-safe comparison operations for TupleElement protocol.
/// Used by query components and index operations.
public enum TupleComparison {

    /// Check if two TupleElement values are equal
    ///
    /// Supports:
    /// - String
    /// - Int64 (with Int conversion)
    /// - Int (with Int64 conversion)
    /// - Bool
    /// - Double
    /// - Float
    ///
    /// - Parameters:
    ///   - lhs: Left-hand side value
    ///   - rhs: Right-hand side value
    /// - Returns: true if values are equal, false otherwise
    public static func areEqual(_ lhs: any TupleElement, _ rhs: any TupleElement) -> Bool {
        // String comparison
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr == rhsStr
        }

        // Int64 comparison
        if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
            return lhsInt == rhsInt
        }

        // Int vs Int64 comparison
        if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int64 {
            return Int64(lhsInt) == rhsInt
        }
        if let lhsInt64 = lhs as? Int64, let rhsInt = rhs as? Int {
            return lhsInt64 == Int64(rhsInt)
        }

        // Bool comparison
        if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
            return lhsBool == rhsBool
        }

        // Double comparison
        if let lhsDouble = lhs as? Double, let rhsDouble = rhs as? Double {
            return lhsDouble == rhsDouble
        }

        // Float comparison
        if let lhsFloat = lhs as? Float, let rhsFloat = rhs as? Float {
            return lhsFloat == rhsFloat
        }

        return false
    }

    /// Compare two TupleElement values (less than)
    ///
    /// Supports ordered types: String, Int64, Int, Double, Float
    ///
    /// - Parameters:
    ///   - lhs: Left-hand side value
    ///   - rhs: Right-hand side value
    /// - Returns: true if lhs < rhs, false otherwise
    public static func isLessThan(_ lhs: any TupleElement, _ rhs: any TupleElement) -> Bool {
        // String comparison
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            return lhsStr < rhsStr
        }

        // Int64 comparison
        if let lhsInt = lhs as? Int64, let rhsInt = rhs as? Int64 {
            return lhsInt < rhsInt
        }

        // Int vs Int64 comparison
        if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int64 {
            return Int64(lhsInt) < rhsInt
        }
        if let lhsInt64 = lhs as? Int64, let rhsInt = rhs as? Int {
            return lhsInt64 < Int64(rhsInt)
        }

        // Double comparison
        if let lhsDouble = lhs as? Double, let rhsDouble = rhs as? Double {
            return lhsDouble < rhsDouble
        }

        // Float comparison
        if let lhsFloat = lhs as? Float, let rhsFloat = rhs as? Float {
            return lhsFloat < rhsFloat
        }

        return false
    }

    /// Check if a string starts with a prefix
    ///
    /// - Parameters:
    ///   - value: The value to check
    ///   - prefix: The prefix to match
    /// - Returns: true if value starts with prefix, false otherwise
    public static func startsWith(_ value: any TupleElement, _ prefix: any TupleElement) -> Bool {
        if let valueStr = value as? String, let prefixStr = prefix as? String {
            return valueStr.hasPrefix(prefixStr)
        }
        return false
    }

    /// Check if a string contains a substring
    ///
    /// - Parameters:
    ///   - value: The value to check
    ///   - substring: The substring to find
    /// - Returns: true if value contains substring, false otherwise
    public static func contains(_ value: any TupleElement, _ substring: any TupleElement) -> Bool {
        if let valueStr = value as? String, let substringStr = substring as? String {
            return valueStr.contains(substringStr)
        }
        return false
    }
}
