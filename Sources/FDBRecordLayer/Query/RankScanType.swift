import Foundation

/// Rank index scan type
///
/// Determines how to scan a rank index:
/// - `.byValue`: Scan by indexed values (returns records in value order)
/// - `.byRank`: Scan by rank positions (returns top N or bottom N records)
///
/// **Example**:
/// ```swift
/// // By value: Get all users with score >= 100
/// let plan = RankIndexScanPlan(scanType: .byValue, valueRange: (100, Int64.max))
///
/// // By rank: Get top 10 users
/// let plan = RankIndexScanPlan(scanType: .byRank, rankRange: RankRange(begin: 0, end: 10))
/// ```
public enum RankScanType: Sendable, Equatable {
    /// Scan by indexed values
    ///
    /// Returns records in value order (e.g., sorted by score).
    /// This is the default scan type, equivalent to regular index scan.
    case byValue

    /// Scan by rank positions
    ///
    /// Returns records in rank order (e.g., top N highest scores).
    /// Requires RankRange to specify which ranks to retrieve.
    case byRank
}

/// Rank range for rank-based scanning
///
/// Specifies a range of ranks to retrieve (0-based, end-exclusive).
///
/// **Example**:
/// ```swift
/// // Top 10 records (ranks 0-9)
/// let topTen = RankRange(begin: 0, end: 10)
///
/// // Ranks 10-19
/// let nextTen = RankRange(begin: 10, end: 20)
///
/// // Single rank (e.g., rank 0 = #1)
/// let first = RankRange(begin: 0, end: 1)
/// ```
public struct RankRange: Sendable, Equatable {
    /// Start rank (inclusive, 0-based)
    public let begin: Int

    /// End rank (exclusive)
    public let end: Int

    /// Initialize a rank range
    ///
    /// - Parameters:
    ///   - begin: Start rank (inclusive, 0-based)
    ///   - end: End rank (exclusive)
    ///
    /// - Precondition: `begin >= 0` and `end > begin`
    public init(begin: Int, end: Int) {
        precondition(begin >= 0, "begin must be non-negative")
        precondition(end > begin, "end must be greater than begin")
        self.begin = begin
        self.end = end
    }

    /// Number of ranks in this range
    public var count: Int {
        return end - begin
    }

    /// Check if a rank is within this range
    ///
    /// - Parameter rank: Rank to check (0-based)
    /// - Returns: `true` if rank is in [begin, end)
    public func contains(_ rank: Int) -> Bool {
        return rank >= begin && rank < end
    }
}
