import Foundation
import FoundationDB
import Logging

/// Tracks which key ranges have been processed for an index build
///
/// RangeSet stores completed ranges in FoundationDB, allowing index builds
/// to resume after interruption without re-processing already completed ranges.
///
/// Implementation: Stores range boundaries in a subspace. A range is "completed"
/// if it has been successfully processed and committed.
public final class RangeSet: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let logger: Logger

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.rangeset")
    }

    // MARK: - Public Methods

    /// Mark a range as completed
    ///
    /// - Parameters:
    ///   - begin: Start of the range (inclusive)
    ///   - end: End of the range (exclusive)
    ///   - context: Transaction context
    public func insertRange(begin: FDB.Bytes, end: FDB.Bytes, context: RecordContext) async throws {
        let transaction = context.getTransaction()

        // Store a marker for this range
        // Key: subspace + begin
        // Value: end (the exclusive end of this range)
        let key = subspace.pack(Tuple(begin))
        transaction.setValue(end, for: key)

        logger.debug("Marked range as completed: \(begin.count) bytes -> \(end.count) bytes")
    }

    /// Get all ranges that have not yet been processed within a given key space
    ///
    /// - Parameters:
    ///   - fullBegin: Start of the entire key space
    ///   - fullEnd: End of the entire key space
    /// - Returns: Array of (begin, end) tuples representing missing ranges
    public func missingRanges(fullBegin: FDB.Bytes, fullEnd: FDB.Bytes) async throws -> [(begin: FDB.Bytes, end: FDB.Bytes)] {
        return try await database.withRecordContext { [subspace] context in
            let transaction = context.getTransaction()
            var completedRanges: [(begin: FDB.Bytes, end: FDB.Bytes)] = []

            // Read all completed ranges from the RangeSet subspace
            let (rangeBegin, rangeEnd) = subspace.range()
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(rangeBegin),
                endSelector: .firstGreaterThan(rangeEnd),
                snapshot: true
            )

            for try await (key, value) in sequence {
                // Unpack to get the range start
                let tuple = try subspace.unpack(key)
                guard let beginBytes = tuple[0] as? FDB.Bytes else { continue }
                let endBytes = value

                completedRanges.append((begin: beginBytes, end: endBytes))
            }

            // Sort by start position
            completedRanges.sort { $0.begin.lexicographicallyPrecedes($1.begin) }

            // Calculate missing ranges
            var missing: [(begin: FDB.Bytes, end: FDB.Bytes)] = []
            var currentPos = fullBegin

            for completed in completedRanges {
                // If there's a gap before this completed range
                if currentPos.lexicographicallyPrecedes(completed.begin) {
                    missing.append((begin: currentPos, end: completed.begin))
                }

                // Move past this completed range
                if completed.end.lexicographicallyPrecedes(currentPos) {
                    // Overlapping or out-of-order ranges - skip
                    continue
                }
                currentPos = completed.end
            }

            // If there's remaining space after all completed ranges
            if currentPos.lexicographicallyPrecedes(fullEnd) {
                missing.append((begin: currentPos, end: fullEnd))
            }

            return missing
        }
    }

    /// Check if a specific range has been completed
    ///
    /// - Parameters:
    ///   - begin: Start of the range
    ///   - end: End of the range
    /// - Returns: True if the entire range is marked as complete
    public func containsRange(begin: FDB.Bytes, end: FDB.Bytes) async throws -> Bool {
        let missing = try await missingRanges(fullBegin: begin, fullEnd: end)
        return missing.isEmpty
    }

    /// Clear all completed ranges (reset the RangeSet)
    ///
    /// Used when restarting an index build from scratch.
    public func clear() async throws {
        try await database.withRecordContext { [subspace] context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }

        logger.info("Cleared all completed ranges")
    }

    /// Get progress statistics
    ///
    /// - Parameters:
    ///   - fullBegin: Start of the entire key space
    ///   - fullEnd: End of the entire key space
    /// - Returns: (completed ranges count, estimated progress percentage)
    public func getProgress(fullBegin: FDB.Bytes, fullEnd: FDB.Bytes) async throws -> (completedRanges: Int, estimatedProgress: Double) {
        return try await database.withRecordContext { [subspace] context in
            let transaction = context.getTransaction()
            var completedCount = 0
            var completedBytes: UInt64 = 0

            let (rangeBegin, rangeEnd) = subspace.range()
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(rangeBegin),
                endSelector: .firstGreaterThan(rangeEnd),
                snapshot: true
            )

            for try await (key, value) in sequence {
                let tuple = try subspace.unpack(key)
                guard let beginBytes = tuple[0] as? FDB.Bytes else { continue }
                let endBytes = value

                completedCount += 1
                // Rough estimation based on key size difference
                if let beginLast = beginBytes.last, let endLast = endBytes.last {
                    completedBytes += UInt64(endLast) - UInt64(beginLast)
                }
            }

            // Rough progress estimation
            let totalBytes = (fullEnd.last ?? 0) - (fullBegin.first ?? 0)
            let progress = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0.0

            return (completedRanges: completedCount, estimatedProgress: min(1.0, progress))
        }
    }
}
