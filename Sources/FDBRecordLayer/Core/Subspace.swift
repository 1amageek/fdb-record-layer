import Foundation
import FoundationDB

/// FoundationDB subspace for key management
///
/// A Subspace represents a well-defined region of keyspace in FoundationDB.
/// It provides methods for encoding keys with a prefix and decoding them back.
public struct Subspace: Sendable {
    /// The binary prefix for this subspace
    public let prefix: FDB.Bytes

    // MARK: - Initialization

    /// Create a subspace with a binary prefix
    /// - Parameter prefix: The binary prefix
    public init(prefix: FDB.Bytes) {
        self.prefix = prefix
    }

    /// Create a subspace with a string prefix
    /// - Parameter rootPrefix: The string prefix (will be encoded as a Tuple)
    public init(rootPrefix: String) {
        let tuple = Tuple(rootPrefix)
        self.prefix = tuple.encode()
    }

    // MARK: - Subspace Creation

    /// Create a nested subspace by appending tuple elements
    /// - Parameter elements: Tuple elements to append
    /// - Returns: A new subspace with the extended prefix
    public func subspace(_ elements: any TupleElement...) -> Subspace {
        let tuple = TupleHelpers.toTuple(elements)
        return Subspace(prefix: prefix + tuple.encode())
    }

    // MARK: - Key Encoding/Decoding

    /// Encode a tuple into a key with this subspace's prefix
    /// - Parameter tuple: The tuple to encode
    /// - Returns: The encoded key with prefix
    public func pack(_ tuple: Tuple) -> FDB.Bytes {
        return prefix + tuple.encode()
    }

    /// Decode a key into a tuple, removing this subspace's prefix
    /// - Parameter key: The key to decode
    /// - Returns: The decoded tuple
    /// - Throws: RecordLayerError.invalidKey if the key doesn't start with this prefix
    public func unpack(_ key: FDB.Bytes) throws -> Tuple {
        guard key.starts(with: prefix) else {
            throw RecordLayerError.invalidKey("Key does not match subspace prefix")
        }
        let tupleBytes = Array(key.dropFirst(prefix.count))
        let elements = try Tuple.decode(from: tupleBytes)
        return Tuple(elements)
    }

    /// Check if a key belongs to this subspace
    /// - Parameter key: The key to check
    /// - Returns: true if the key starts with this subspace's prefix
    public func contains(_ key: FDB.Bytes) -> Bool {
        return key.starts(with: prefix)
    }

    // MARK: - Range Operations

    /// Get the range for scanning all keys in this subspace
    /// - Returns: A tuple of (begin, end) keys for range operations
    public func range() -> (begin: FDB.Bytes, end: FDB.Bytes) {
        var end = prefix

        // Increment last byte for exclusive end key
        // If overflow, extend with 0x00
        if let lastIndex = end.indices.last {
            if end[lastIndex] == 0xFF {
                end.append(0x00)
            } else {
                end[lastIndex] = end[lastIndex] &+ 1
            }
        } else {
            // Empty prefix, use 0x00 as end
            end = [0x00]
        }

        return (prefix, end)
    }

    /// Get a range with specific start and end tuples
    /// - Parameters:
    ///   - start: Start tuple (inclusive)
    ///   - end: End tuple (exclusive)
    /// - Returns: A tuple of (begin, end) keys
    public func range(from start: Tuple, to end: Tuple) -> (begin: FDB.Bytes, end: FDB.Bytes) {
        return (pack(start), pack(end))
    }
}

// MARK: - Equatable

extension Subspace: Equatable {
    public static func == (lhs: Subspace, rhs: Subspace) -> Bool {
        return lhs.prefix == rhs.prefix
    }
}

// MARK: - Hashable

extension Subspace: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(prefix)
    }
}

// MARK: - CustomStringConvertible

extension Subspace: CustomStringConvertible {
    public var description: String {
        let hexString = prefix.map { String(format: "%02x", $0) }.joined()
        return "Subspace(prefix: \(hexString))"
    }
}
