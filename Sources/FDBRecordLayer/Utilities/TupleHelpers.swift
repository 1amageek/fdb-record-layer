import Foundation
import FoundationDB

/// Utility functions for working with Tuples
public enum TupleHelpers {
    /// Convert a TupleElement to its encoded representation for storage
    /// - Parameter element: The element to convert
    /// - Returns: A tuple containing just this element
    public static func toTuple(_ element: any TupleElement) -> Tuple {
        if let str = element as? String {
            return Tuple(str)
        } else if let int = element as? Int {
            return Tuple(Int64(int))
        } else if let int32 = element as? Int32 {
            return Tuple(Int64(int32))
        } else if let int64 = element as? Int64 {
            return Tuple(int64)
        } else if let uint64 = element as? UInt64 {
            return Tuple(uint64)
        } else if let bool = element as? Bool {
            return Tuple(bool)
        } else if let float = element as? Float {
            return Tuple(float)
        } else if let double = element as? Double {
            return Tuple(double)
        } else if let uuid = element as? UUID {
            return Tuple(uuid)
        } else if let bytes = element as? FDB.Bytes {
            return Tuple(bytes)
        } else {
            // Fallback for unknown types - use empty string
            return Tuple("")
        }
    }

    /// Create a tuple from an array of elements
    /// - Parameter elements: The elements to include
    /// - Returns: A tuple containing all elements
    public static func toTuple(_ elements: [any TupleElement]) -> Tuple {
        // Start with empty bytes and build tuple manually
        var combinedBytes: FDB.Bytes = []

        for element in elements {
            let singleTuple: Tuple
            if let str = element as? String {
                singleTuple = Tuple(str)
            } else if let int = element as? Int {
                singleTuple = Tuple(Int64(int))
            } else if let int32 = element as? Int32 {
                singleTuple = Tuple(Int64(int32))
            } else if let int64 = element as? Int64 {
                singleTuple = Tuple(int64)
            } else if let uint64 = element as? UInt64 {
                singleTuple = Tuple(uint64)
            } else if let bool = element as? Bool {
                singleTuple = Tuple(bool)
            } else if let float = element as? Float {
                singleTuple = Tuple(float)
            } else if let double = element as? Double {
                singleTuple = Tuple(double)
            } else if let uuid = element as? UUID {
                singleTuple = Tuple(uuid)
            } else if let bytes = element as? FDB.Bytes {
                singleTuple = Tuple(bytes)
            } else {
                // Unknown type - use empty string
                singleTuple = Tuple("")
            }

            // Combine encoded tuples (this is a simplified approach)
            // In practice, we'd need proper tuple concatenation
            combinedBytes.append(contentsOf: singleTuple.encode())
        }

        // Decode combined bytes back to create final tuple
        if combinedBytes.isEmpty {
            return Tuple()
        }

        do {
            let decoded = try Tuple.decode(from: combinedBytes)
            return Tuple(decoded)
        } catch {
            // Fallback to empty tuple
            return Tuple()
        }
    }

    /// Convert an Int64 to bytes in little-endian format
    /// - Parameter value: The value to convert
    /// - Returns: The byte representation
    public static func int64ToBytes(_ value: Int64) -> FDB.Bytes {
        return withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// Convert bytes to Int64 from little-endian format
    /// - Parameter bytes: The bytes to convert
    /// - Returns: The Int64 value
    public static func bytesToInt64(_ bytes: FDB.Bytes) -> Int64 {
        return bytes.withUnsafeBytes { $0.load(as: Int64.self).littleEndian }
    }

    /// Convert a UInt64 to bytes in little-endian format
    /// - Parameter value: The value to convert
    /// - Returns: The byte representation
    public static func uint64ToBytes(_ value: UInt64) -> FDB.Bytes {
        return withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// Convert bytes to UInt64 from little-endian format
    /// - Parameter bytes: The bytes to convert
    /// - Returns: The UInt64 value
    public static func bytesToUInt64(_ bytes: FDB.Bytes) -> UInt64 {
        return bytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }
}
