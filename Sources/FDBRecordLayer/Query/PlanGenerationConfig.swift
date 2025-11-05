import Foundation

/// Configuration for query plan generation
///
/// Controls the complexity and resource usage of the query planning process.
/// Different configurations allow tuning the trade-off between planning time
/// and plan quality.
///
/// **Usage:**
/// ```swift
/// // Default configuration (balanced)
/// let planner = TypedRecordQueryPlanner(
///     metaData: metaData,
///     recordTypeName: "User",
///     statisticsManager: statsManager,
///     config: .default
/// )
///
/// // Aggressive optimization (slower planning, better plans)
/// let aggressivePlanner = TypedRecordQueryPlanner(
///     metaData: metaData,
///     recordTypeName: "User",
///     statisticsManager: statsManager,
///     config: .aggressive
/// )
///
/// // Conservative optimization (faster planning, good enough plans)
/// let conservativePlanner = TypedRecordQueryPlanner(
///     metaData: metaData,
///     recordTypeName: "User",
///     statisticsManager: statsManager,
///     config: .conservative
/// )
/// ```
public struct PlanGenerationConfig: Sendable {
    /// Maximum number of candidate plans to generate
    ///
    /// Limits the search space to prevent excessive planning time.
    /// Once this limit is reached, no more candidate plans are generated.
    public let maxCandidatePlans: Int

    /// Maximum DNF expansion size (number of OR branches)
    ///
    /// When converting filters to Disjunctive Normal Form (DNF),
    /// limit the number of branches to prevent exponential explosion.
    /// If exceeded, falls back to heuristic planning.
    public let maxDNFBranches: Int

    /// Whether to use heuristic pruning
    ///
    /// When enabled, uses heuristics to skip obviously suboptimal plans:
    /// - Unique index on equality → short-circuit to index scan
    /// - High selectivity (>50%) → skip expensive multi-index plans
    /// - Full scan threshold checks
    public let enableHeuristicPruning: Bool

    /// Initialize with custom configuration
    ///
    /// - Parameters:
    ///   - maxCandidatePlans: Maximum candidate plans (1-100)
    ///   - maxDNFBranches: Maximum DNF branches (1-50)
    ///   - enableHeuristicPruning: Enable heuristic pruning
    public init(
        maxCandidatePlans: Int,
        maxDNFBranches: Int,
        enableHeuristicPruning: Bool
    ) {
        self.maxCandidatePlans = max(1, min(100, maxCandidatePlans))
        self.maxDNFBranches = max(1, min(50, maxDNFBranches))
        self.enableHeuristicPruning = enableHeuristicPruning
    }

    // MARK: - Presets

    /// Default configuration (balanced)
    ///
    /// Good balance between planning time and plan quality.
    /// Suitable for most production workloads.
    ///
    /// - Max candidates: 20
    /// - Max DNF branches: 10
    /// - Heuristic pruning: enabled
    public static let `default` = PlanGenerationConfig(
        maxCandidatePlans: 20,
        maxDNFBranches: 10,
        enableHeuristicPruning: true
    )

    /// Aggressive configuration
    ///
    /// More thorough plan exploration at the cost of planning time.
    /// Use when query performance is critical and planning overhead is acceptable.
    ///
    /// - Max candidates: 50
    /// - Max DNF branches: 20
    /// - Heuristic pruning: enabled
    public static let aggressive = PlanGenerationConfig(
        maxCandidatePlans: 50,
        maxDNFBranches: 20,
        enableHeuristicPruning: true
    )

    /// Conservative configuration
    ///
    /// Faster planning with fewer candidate plans.
    /// Use when planning time is critical and "good enough" plans are acceptable.
    ///
    /// - Max candidates: 10
    /// - Max DNF branches: 5
    /// - Heuristic pruning: enabled
    public static let conservative = PlanGenerationConfig(
        maxCandidatePlans: 10,
        maxDNFBranches: 5,
        enableHeuristicPruning: true
    )

    /// Minimal configuration (fastest planning)
    ///
    /// Minimal plan exploration for very fast planning.
    /// Only considers full scan and first matching index.
    ///
    /// - Max candidates: 5
    /// - Max DNF branches: 3
    /// - Heuristic pruning: enabled
    public static let minimal = PlanGenerationConfig(
        maxCandidatePlans: 5,
        maxDNFBranches: 3,
        enableHeuristicPruning: true
    )

    /// Exhaustive configuration (slowest planning, best plans)
    ///
    /// Maximum plan exploration. Use only for critical queries
    /// where planning time is not a concern.
    ///
    /// - Max candidates: 100
    /// - Max DNF branches: 50
    /// - Heuristic pruning: disabled (explore all)
    public static let exhaustive = PlanGenerationConfig(
        maxCandidatePlans: 100,
        maxDNFBranches: 50,
        enableHeuristicPruning: false
    )
}
