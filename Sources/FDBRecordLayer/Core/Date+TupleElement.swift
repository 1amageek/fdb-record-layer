import Foundation
import FoundationDB

/// TupleElement conformance for Date
///
/// Encodes Date as Double (timeIntervalSince1970) in Tuple format.
/// This ensures Date values can be used in indexes and as query parameters.
extension Date: TupleElement {
    /// Encode Date as Double timestamp
    public func encodeTuple() -> FDB.Bytes {
        return timeIntervalSince1970.encodeTuple()
    }

    /// Decode Date from Double timestamp
    public static func decodeTuple(from bytes: FDB.Bytes, at offset: inout Int) throws -> Date {
        let timestamp = try Double.decodeTuple(from: bytes, at: &offset)
        return Date(timeIntervalSince1970: timestamp)
    }
}
