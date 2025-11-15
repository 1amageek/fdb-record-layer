import Foundation
import FoundationDB

// MARK: - Errors

/// Errors that can occur in Record Layer operations
public enum RecordLayerError: Error, Sendable {
    case contextAlreadyClosed
    case indexNotFound(String)
    case indexNotReady(String)
    case recordTypeNotFound(String)
    case invalidKey(String)
    case invalidSerializedData(String)
    case invalidIndexState(UInt8)
    case invalidArgument(String)
    case serializationFailed(String)
    case deserializationFailed(String)
    case serializationValidationFailed(String)
    case missingUnionDescriptor
    case noValidPlan
    case internalError(String)

    // Version Index errors
    case versionMismatch(expected: String, actual: String)
    case versionNotFound(version: String)
    case invalidVersion(String)

    // Permuted Index errors
    case invalidPermutation(String)

    // Rank Index errors
    case invalidRank(String)
    case rankOutOfBounds(rank: Int, total: Int)

    // Resource limits
    case resourceExhausted(String)

    // Covering Index errors
    case reconstructionNotImplemented(recordType: String, suggestion: String)
    case reconstructionFailed(recordType: String, reason: String)

    // Range Index errors
    case fieldNotFound(String)
    case fieldNotRangeType(fieldName: String, actualType: String)
    case invalidRangeComponent(fieldName: String, requestedComponent: String, availableComponent: String)
}

extension RecordLayerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .contextAlreadyClosed:
            return "Record context has already been closed"
        case .indexNotFound(let name):
            return "Index not found: \(name)"
        case .indexNotReady(let name):
            return "Index not ready: \(name)"
        case .recordTypeNotFound(let name):
            return "Record type not found: \(name)"
        case .invalidKey(let message):
            return "Invalid key: \(message)"
        case .invalidSerializedData(let message):
            return "Invalid serialized data: \(message)"
        case .invalidIndexState(let value):
            return "Invalid index state value: \(value)"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .serializationFailed(let message):
            return "Serialization failed: \(message)"
        case .deserializationFailed(let message):
            return "Deserialization failed: \(message)"
        case .serializationValidationFailed(let message):
            return "Serialization validation failed: \(message)"
        case .missingUnionDescriptor:
            return "Union descriptor is required but missing"
        case .noValidPlan:
            return "No valid query plan could be generated"
        case .internalError(let message):
            return "Internal error: \(message)"

        // Version Index errors
        case .versionMismatch(let expected, let actual):
            return "Version mismatch: expected \(expected), got \(actual)"
        case .versionNotFound(let version):
            return "Version not found: \(version)"
        case .invalidVersion(let message):
            return "Invalid version: \(message)"

        // Permuted Index errors
        case .invalidPermutation(let message):
            return "Invalid permutation: \(message)"

        // Rank Index errors
        case .invalidRank(let message):
            return "Invalid rank: \(message)"
        case .rankOutOfBounds(let rank, let total):
            return "Rank \(rank) is out of bounds (total: \(total))"

        // Resource limits
        case .resourceExhausted(let message):
            return "Resource exhausted: \(message)"

        // Covering Index errors
        case .reconstructionNotImplemented(let recordType, let suggestion):
            return """
                Record reconstruction not implemented for type: \(recordType)

                \(suggestion)
                """
        case .reconstructionFailed(let recordType, let reason):
            return "Record reconstruction failed for type \(recordType): \(reason)"

        // Range Index errors
        case .fieldNotFound(let fieldName):
            return "Field not found: \(fieldName)"
        case .fieldNotRangeType(let fieldName, let actualType):
            return "Field '\(fieldName)' is not a Range type (actual type: \(actualType))"
        case .invalidRangeComponent(let fieldName, let requested, let available):
            return "Invalid range component '\(requested)' requested for field '\(fieldName)' (available: \(available))"
        }
    }
}

// MARK: - Convenience Errors

extension RecordLayerError {
    /// Invalid state transition error
    public static func invalidStateTransition(
        from: IndexState,
        to: IndexState,
        index: String,
        reason: String = ""
    ) -> RecordLayerError {
        let message = "Invalid state transition for index '\(index)': \(from) → \(to)"
        let fullMessage = reason.isEmpty ? message : "\(message). \(reason)"
        return .internalError(fullMessage)
    }

    /// Invalid indexing policy error
    public static func invalidIndexingPolicy(_ message: String) -> RecordLayerError {
        return .internalError("Invalid indexing policy: \(message)")
    }

    /// Scrubber retry exhausted
    ///
    /// - Parameters:
    ///   - phase: Failed phase ("Phase 1", "Phase 2")
    ///   - operation: Failed operation ("scrubIndexEntriesBatch", "scrubRecordsBatch")
    ///   - keyRange: Key range being processed
    ///   - attempts: Number of attempts
    ///   - lastError: Last error encountered
    ///   - recommendation: Recommended action
    public static func scrubberRetryExhausted(
        phase: String,
        operation: String,
        keyRange: String,
        attempts: Int,
        lastError: Error,
        recommendation: String
    ) -> RecordLayerError {
        let message = """
            ERROR: Scrubber retry exhausted during \(phase)

            Operation: \(operation)
            Key Range: \(keyRange)
            Attempts: \(attempts)
            Last Error: \(lastError)

            Recommendation:
            \(recommendation)
            """
        return .internalError(message)
    }

    /// Key skip operation failed
    ///
    /// - Parameters:
    ///   - key: Key that was attempted to skip
    ///   - reason: Reason for failure
    ///   - attempts: Number of attempts
    public static func scrubberSkipFailed(
        key: String,
        reason: Error,
        attempts: Int
    ) -> RecordLayerError {
        let message = """
            ERROR: Failed to skip problematic key after \(attempts) attempts

            Key: \(key)
            Reason: \(reason)

            Recommendation:
            This key is blocking progress. Consider:
            1. Increase 'maxRetries' in ScrubberConfiguration
            2. Manually inspect and remove this key
            3. Check FoundationDB cluster health

            WARNING: The scrubber cannot proceed past this key until it is resolved.
            """
        return .internalError(message)
    }
}

// MARK: - Keyspace Identifiers

/// Record Store keyspace identifiers
public enum RecordStoreKeyspace: Int64, Sendable {
    case storeInfo = 0
    case record = 1
    case index = 2
    case indexSecondary = 3
    case indexState = 5
    case indexRange = 6
    case indexUniquenessViolations = 7
    case indexBuild = 9
}

// MARK: - Index State

/// Index lifecycle states
///
/// State transition diagram:
/// ```
///     ┌──────────┐
///     │ DISABLED │ ◄─────────────┐
///     └─────┬────┘               │
///           │ enableIndex()      │
///           ▼                    │ disableIndex()
///     ┌──────────┐               │
///     │WRITE_ONLY│               │
///     └─────┬────┘               │
///           │ markReadable()     │
///           ▼                    │
///     ┌──────────┐               │
///     │ READABLE │ ──────────────┘
///     └──────────┘
/// ```
public enum IndexState: UInt8, Sendable, CustomStringConvertible {
    /// Index is fully operational and can be used by queries
    case readable = 0

    /// Index is disabled
    /// - Not maintained on writes
    /// - Not used by queries
    case disabled = 1

    /// Index is being built or rebuilt
    /// - Maintained on writes
    /// - Not yet usable for queries
    case writeOnly = 2

    // MARK: - Helper Properties

    /// Returns true if this index can be used by queries
    public var isReadable: Bool {
        return self == .readable
    }

    /// Returns true if this index should be maintained on writes
    public var shouldMaintain: Bool {
        switch self {
        case .readable, .writeOnly:
            return true
        case .disabled:
            return false
        }
    }

    // MARK: - CustomStringConvertible

    /// String representation for debugging and logging
    public var description: String {
        switch self {
        case .readable:
            return "readable"
        case .disabled:
            return "disabled"
        case .writeOnly:
            return "writeOnly"
        }
    }
}

// MARK: - Index Type

/// Type of index
public enum IndexType: String, Sendable {
    case value      // Standard B-tree index
    case rank       // Rank/leaderboard index
    case count      // Count aggregation index
    case sum        // Sum aggregation index
    case min        // MIN aggregation index
    case max        // MAX aggregation index
    case version    // Version index
    case permuted   // Permuted index (multiple orderings)
    case vector     // HNSW-based vector similarity search
    case spatial    // Z-order curve spatial indexing
}

// MARK: - Tuple Element Aliases

/// We use FoundationDB's TupleElement protocol directly
public typealias TupleElement = FoundationDB.TupleElement

/// We use FoundationDB's Tuple struct directly
public typealias Tuple = FoundationDB.Tuple
