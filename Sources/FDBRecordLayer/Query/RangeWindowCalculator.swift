import Foundation

/// Utility for calculating intersection windows of Range filters
///
/// When multiple Range conditions are specified, pre-calculating their intersection window
/// allows narrowing the index scan range and significantly reducing false-positives.
///
/// Example:
/// ```swift
/// let range1 = Date(timeIntervalSince1970: 1000)..<Date(timeIntervalSince1970: 4000)
/// let range2 = Date(timeIntervalSince1970: 2000)..<Date(timeIntervalSince1970: 3000)
///
/// let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])
/// // window = Date(2000)..<Date(3000)  // max(1000, 2000)..<min(4000, 3000)
/// ```
public struct RangeWindowCalculator {

    // MARK: - Generic Comparable Types

    /// Calculate the intersection window of multiple Range<T> filters (generic)
    ///
    /// Supports any Comparable type including Int, Double, String, Date, and custom types.
    ///
    /// - Parameter ranges: Array of Range<T: Comparable>
    /// - Returns: Intersection window, or nil if no intersection
    ///
    /// Algorithm:
    /// 1. Calculate max lowerBound (latest start point)
    /// 2. Calculate min upperBound (earliest end point)
    /// 3. If maxLower < minUpper, intersection exists; otherwise nil
    ///
    /// Example:
    /// ```swift
    /// // Int ranges
    /// let range1 = 10..<40
    /// let range2 = 20..<30
    /// let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])
    /// // window = 20..<30
    ///
    /// // Double ranges
    /// let range1 = 100.0..<400.0
    /// let range2 = 200.0..<300.0
    /// let window = RangeWindowCalculator.calculateIntersectionWindow([range1, range2])
    /// // window = 200.0..<300.0
    /// ```
    public static func calculateIntersectionWindow<T: Comparable>(_ ranges: [Range<T>]) -> Range<T>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate max lowerBound and min upperBound
        let maxLower = ranges.map(\.lowerBound).max()!
        let minUpper = ranges.map(\.upperBound).min()!

        // No intersection
        guard maxLower < minUpper else {
            return nil
        }

        return maxLower..<minUpper
    }

    /// Calculate the intersection window of multiple PartialRangeFrom<T> filters (generic)
    ///
    /// - Parameter ranges: Array of PartialRangeFrom<T: Comparable>
    /// - Returns: Intersection window (PartialRangeFrom with max lowerBound)
    ///
    /// Example:
    /// ```swift
    /// let range1 = 10...  // [10, ∞)
    /// let range2 = 20...  // [20, ∞)
    /// let window = calculateIntersectionWindow([range1, range2])
    /// // window = 20...  // max(10, 20) = 20
    /// ```
    public static func calculateIntersectionWindow<T: Comparable>(_ ranges: [PartialRangeFrom<T>]) -> PartialRangeFrom<T>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate max lowerBound (most restrictive condition)
        let maxLower = ranges.map(\.lowerBound).max()!
        return maxLower...
    }

    /// Calculate the intersection window of multiple PartialRangeThrough<T> filters (generic)
    ///
    /// - Parameter ranges: Array of PartialRangeThrough<T: Comparable>
    /// - Returns: Intersection window (PartialRangeThrough with min upperBound)
    ///
    /// Example:
    /// ```swift
    /// let range1 = ...40  // (-∞, 40]
    /// let range2 = ...30  // (-∞, 30]
    /// let window = calculateIntersectionWindow([range1, range2])
    /// // window = ...30  // min(40, 30) = 30
    /// ```
    public static func calculateIntersectionWindow<T: Comparable>(_ ranges: [PartialRangeThrough<T>]) -> PartialRangeThrough<T>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate min upperBound (most restrictive condition)
        let minUpper = ranges.map(\.upperBound).min()!
        return ...minUpper
    }

    /// Calculate the intersection window of multiple PartialRangeUpTo<T> filters (generic)
    ///
    /// - Parameter ranges: Array of PartialRangeUpTo<T: Comparable>
    /// - Returns: Intersection window (PartialRangeUpTo with min upperBound)
    ///
    /// Example:
    /// ```swift
    /// let range1 = ..<40  // (-∞, 40)
    /// let range2 = ..<30  // (-∞, 30)
    /// let window = calculateIntersectionWindow([range1, range2])
    /// // window = ..<30  // min(40, 30) = 30
    /// ```
    public static func calculateIntersectionWindow<T: Comparable>(_ ranges: [PartialRangeUpTo<T>]) -> PartialRangeUpTo<T>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate min upperBound (most restrictive condition)
        let minUpper = ranges.map(\.upperBound).min()!
        return ..<minUpper
    }

    // MARK: - Range<Date>

    /// Calculate the intersection window of multiple Range<Date> filters
    ///
    /// - Parameter ranges: Array of Range<Date>
    /// - Returns: Intersection window, or nil if no intersection
    ///
    /// Algorithm:
    /// 1. Calculate max lowerBound (latest start point)
    /// 2. Calculate min upperBound (earliest end point)
    /// 3. If maxLower < minUpper, intersection exists; otherwise nil
    public static func calculateIntersectionWindow(_ ranges: [Range<Date>]) -> Range<Date>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate max lowerBound and min upperBound
        let maxLower = ranges.map(\.lowerBound).max()!
        let minUpper = ranges.map(\.upperBound).min()!

        // No intersection
        guard maxLower < minUpper else {
            return nil
        }

        return maxLower..<minUpper
    }

    // MARK: - PartialRangeFrom<Date>

    /// Calculate the intersection window of multiple PartialRangeFrom<Date> filters
    ///
    /// - Parameter ranges: Array of PartialRangeFrom<Date>
    /// - Returns: Intersection window (PartialRangeFrom with max lowerBound)
    ///
    /// Example:
    /// ```swift
    /// let range1 = Date(1000)...  // [1000, ∞)
    /// let range2 = Date(2000)...  // [2000, ∞)
    /// let window = calculateIntersectionWindow([range1, range2])
    /// // window = Date(2000)...  // max(1000, 2000) = 2000
    /// ```
    public static func calculateIntersectionWindow(_ ranges: [PartialRangeFrom<Date>]) -> PartialRangeFrom<Date>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate max lowerBound (most restrictive condition)
        let maxLower = ranges.map(\.lowerBound).max()!
        return maxLower...
    }

    // MARK: - PartialRangeThrough<Date>

    /// Calculate the intersection window of multiple PartialRangeThrough<Date> filters
    ///
    /// - Parameter ranges: Array of PartialRangeThrough<Date>
    /// - Returns: Intersection window (PartialRangeThrough with min upperBound)
    ///
    /// Example:
    /// ```swift
    /// let range1 = ...Date(4000)  // (-∞, 4000]
    /// let range2 = ...Date(3000)  // (-∞, 3000]
    /// let window = calculateIntersectionWindow([range1, range2])
    /// // window = ...Date(3000)  // min(4000, 3000) = 3000
    /// ```
    public static func calculateIntersectionWindow(_ ranges: [PartialRangeThrough<Date>]) -> PartialRangeThrough<Date>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate min upperBound (most restrictive condition)
        let minUpper = ranges.map(\.upperBound).min()!
        return ...minUpper
    }

    // MARK: - PartialRangeUpTo<Date>

    /// Calculate the intersection window of multiple PartialRangeUpTo<Date> filters
    ///
    /// - Parameter ranges: Array of PartialRangeUpTo<Date>
    /// - Returns: Intersection window (PartialRangeUpTo with min upperBound)
    ///
    /// Example:
    /// ```swift
    /// let range1 = ..<Date(4000)  // (-∞, 4000)
    /// let range2 = ..<Date(3000)  // (-∞, 3000)
    /// let window = calculateIntersectionWindow([range1, range2])
    /// // window = ..<Date(3000)  // min(4000, 3000) = 3000
    /// ```
    public static func calculateIntersectionWindow(_ ranges: [PartialRangeUpTo<Date>]) -> PartialRangeUpTo<Date>? {
        guard !ranges.isEmpty else { return nil }
        guard ranges.count > 1 else { return ranges.first }

        // Calculate min upperBound (most restrictive condition)
        let minUpper = ranges.map(\.upperBound).min()!
        return ..<minUpper
    }

    // MARK: - Mixed Range Types

    /// Calculate the intersection window of mixed Range type conditions (for future extension)
    ///
    /// Calculates intersection when Range<Date>, PartialRangeFrom<Date>, PartialRangeThrough<Date>
    /// are mixed.
    ///
    /// - Parameters:
    ///   - lowerBounds: All lowerBounds from Range conditions (nil for PartialRangeThrough/UpTo)
    ///   - upperBounds: All upperBounds from Range conditions (nil for PartialRangeFrom)
    /// - Returns: (lowerBound, upperBound) of intersection window, or nil if no intersection
    ///
    /// Internal helper method (may become public in the future)
    internal static func calculateMixedIntersectionWindow(
        lowerBounds: [Date?],
        upperBounds: [Date?]
    ) -> (lowerBound: Date?, upperBound: Date?)? {
        // Calculate max from lowerBounds (nil treated as -∞)
        let maxLower = lowerBounds.compactMap { $0 }.max()

        // Calculate min from upperBounds (nil treated as +∞)
        let minUpper = upperBounds.compactMap { $0 }.min()

        // Check intersection
        if let maxLower = maxLower, let minUpper = minUpper {
            // Both are finite
            guard maxLower < minUpper else {
                return nil  // No intersection
            }
            return (maxLower, minUpper)
        } else if maxLower != nil {
            // Only lowerBound is finite (upperBound is +∞)
            return (maxLower, nil)
        } else if minUpper != nil {
            // Only upperBound is finite (lowerBound is -∞)
            return (nil, minUpper)
        } else {
            // Both are infinite ranges
            return (nil, nil)
        }
    }
}
