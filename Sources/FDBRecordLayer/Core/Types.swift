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
    case serializationFailed(String)
    case deserializationFailed(String)
    case serializationValidationFailed(String)
    case missingUnionDescriptor
    case noValidPlan
    case internalError(String)
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
        }
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

/// State of an index
public enum IndexState: UInt8, Sendable {
    case readable = 0       // Ready for read and write
    case disabled = 1       // Disabled
    case writeOnly = 2      // Building, writes allowed
    case building = 3       // Building, writes not recommended
}

// MARK: - Index Type

/// Type of index
public enum IndexType: String, Sendable {
    case value      // Standard B-tree index
    case rank       // Rank/leaderboard index
    case count      // Count aggregation index
    case sum        // Sum aggregation index
    case version    // Version index
    case permuted   // Permuted index (multiple orderings)
}

// MARK: - Tuple Element Aliases

/// We use FoundationDB's TupleElement protocol directly
public typealias TupleElement = FoundationDB.TupleElement
