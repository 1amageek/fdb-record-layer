import Foundation

/// Decoder that decodes Protobuf wire format to Codable values
///
/// This is a custom Decoder implementation that reads binary data in Protobuf
/// wire format and reconstructs Swift types conforming to Decodable.
///
/// **Wire Format**:
/// - Tag: `(fieldNumber << 3) | wireType`
/// - Wire types: 0=Varint, 1=64-bit, 2=Length-delimited, 5=32-bit
///
/// **Usage**:
/// ```swift
/// let decoder = ProtobufDecoder()
/// let user = try decoder.decode(User.self, from: data)
/// ```
///
/// **Note**: This decoder expects that types have CodingKeys with intValue
/// set to the field number (1-indexed). The @Recordable macro automatically
/// generates appropriate CodingKeys.
public final class ProtobufDecoder {
    public init() {}

    /// Decode Protobuf wire format data to a Decodable type
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = _ProtobufDecoder(data: data)

        // Check if T conforms to Recordable and set field number lookup
        if let recordableType = T.self as? any Recordable.Type {
            decoder.fieldNumberLookup = { fieldName in
                return recordableType.fieldNumber(for: fieldName)
            }
        }

        return try T(from: decoder)
    }
}

// MARK: - Internal Decoder Implementation

private final class _ProtobufDecoder: Decoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    let data: Data
    var offset: Int = 0
    var fieldNumberLookup: ((String) -> Int?)? = nil

    init(data: Data) {
        self.data = data
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        let container = _ProtobufKeyedDecodingContainer<Key>(decoder: self)
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        return _ProtobufUnkeyedDecodingContainer(decoder: self)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return _ProtobufSingleValueDecodingContainer(decoder: self)
    }
}

// MARK: - Keyed Decoding Container

private struct _ProtobufKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: _ProtobufDecoder
    var codingPath: [CodingKey] { decoder.codingPath }
    var allKeys: [Key] = []

    // Parse all fields into a dictionary: fieldNumber -> (wireType, data)
    private var fields: [Int: (wireType: Int, data: Data)] = [:]

    // Mutable state for field number tracking
    private class FieldNumberTracker {
        var nextFieldNumber: Int = 1
        var fieldNumbers: [String: Int] = [:]
    }
    private let tracker = FieldNumberTracker()

    init(decoder: _ProtobufDecoder) {
        self.decoder = decoder
        self.fields = Self.parseFields(from: decoder.data, offset: &decoder.offset)
    }

    /// Parse Protobuf wire format into field map
    private static func parseFields(from data: Data, offset: inout Int) -> [Int: (wireType: Int, data: Data)] {
        var fields: [Int: (wireType: Int, data: Data)] = [:]

        while offset < data.count {
            guard let tag = try? decodeVarint(from: data, offset: &offset) else { break }

            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)

            switch wireType {
            case 0:  // Varint
                guard let value = try? decodeVarint(from: data, offset: &offset) else { break }
                var valueData = Data()
                var n = value
                while n >= 0x80 {
                    valueData.append(UInt8(n & 0x7F) | 0x80)
                    n >>= 7
                }
                valueData.append(UInt8(n))
                fields[fieldNumber] = (wireType, valueData)

            case 1:  // 64-bit
                let endOffset = offset + 8
                guard endOffset <= data.count else { break }
                fields[fieldNumber] = (wireType, Data(data[offset..<endOffset]))
                offset = endOffset

            case 2:  // Length-delimited
                guard let length = try? decodeVarint(from: data, offset: &offset) else { break }
                let endOffset = offset + Int(length)
                guard endOffset <= data.count else { break }
                fields[fieldNumber] = (wireType, Data(data[offset..<endOffset]))
                offset = endOffset

            case 5:  // 32-bit
                let endOffset = offset + 4
                guard endOffset <= data.count else { break }
                fields[fieldNumber] = (wireType, Data(data[offset..<endOffset]))
                offset = endOffset

            default:
                // Unknown wire type - skip
                break
            }
        }

        return fields
    }

    func contains(_ key: Key) -> Bool {
        let fieldNumber = getFieldNumber(for: key)
        return fields[fieldNumber] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        return !contains(key)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let (_, data) = try getField(for: key)
        var offset = 0
        let value = try decodeVarint(from: data, offset: &offset)
        return value != 0
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        return Int(try decode(Int64.self, forKey: key))
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        return Int8(try decode(Int64.self, forKey: key))
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        return Int16(try decode(Int64.self, forKey: key))
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        let (_, data) = try getField(for: key)
        var offset = 0
        let value = try decodeVarint(from: data, offset: &offset)
        return Int32(bitPattern: UInt32(truncatingIfNeeded: value))
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        let (_, data) = try getField(for: key)
        var offset = 0
        let value = try decodeVarint(from: data, offset: &offset)
        return Int64(bitPattern: value)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        return UInt(try decode(UInt64.self, forKey: key))
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        return UInt8(try decode(UInt64.self, forKey: key))
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        return UInt16(try decode(UInt64.self, forKey: key))
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        let (_, data) = try getField(for: key)
        var offset = 0
        let value = try decodeVarint(from: data, offset: &offset)
        return UInt32(truncatingIfNeeded: value)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        let (_, data) = try getField(for: key)
        var offset = 0
        return try decodeVarint(from: data, offset: &offset)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let (_, data) = try getField(for: key)
        guard data.count == 4 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Float requires exactly 4 bytes, got \(data.count)"
                )
            )
        }
        let bits = UInt32(data[0]) |
                   (UInt32(data[1]) << 8) |
                   (UInt32(data[2]) << 16) |
                   (UInt32(data[3]) << 24)
        return Float(bitPattern: bits)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let (_, data) = try getField(for: key)
        guard data.count == 8 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Double requires exactly 8 bytes, got \(data.count)"
                )
            )
        }
        let bits = UInt64(data[0]) |
                   (UInt64(data[1]) << 8) |
                   (UInt64(data[2]) << 16) |
                   (UInt64(data[3]) << 24) |
                   (UInt64(data[4]) << 32) |
                   (UInt64(data[5]) << 40) |
                   (UInt64(data[6]) << 48) |
                   (UInt64(data[7]) << 56)
        return Double(bitPattern: bits)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let (_, data) = try getField(for: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Invalid UTF-8 data"
                )
            )
        }
        return string
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        // Special handling for Date - decode from Double timestamp
        if type == Date.self {
            let timestamp = try decode(Double.self, forKey: key)
            return Date(timeIntervalSince1970: timestamp) as! T
        }

        // Special handling for Data - decode from bytes (length-delimited)
        if type == Data.self {
            let (_, data) = try getField(for: key)
            return data as! T
        }

        // Special handling for Range<Date>
        if type == Range<Date>.self {
            // Check if field exists (important for Optional<Range<Date>>)
            guard contains(key) else {
                // Field doesn't exist - let Swift's standard Optional handling deal with it
                // This will throw keyNotFound, which Optional decoding will catch and return nil
                throw DecodingError.keyNotFound(
                    key,
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Range field '\(key.stringValue)' not found"
                    )
                )
            }

            let (wireType, data) = try getField(for: key)

            // Debug: check if data is empty
            if data.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Range field '\(key.stringValue)' has empty data (wireType=\(wireType))"
                    )
                )
            }

            // Parse the nested message containing lowerBound and upperBound
            var offset = 0
            let fields = Self.parseFields(from: data, offset: &offset)

            // Field 1: lowerBound (Double as 64-bit)
            guard let lowerField = fields[1], lowerField.wireType == 1 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Range lowerBound (field 1) not found or invalid"
                    )
                )
            }
            guard lowerField.data.count == 8 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Range lowerBound must be 8 bytes"
                    )
                )
            }
            let lowerBits = UInt64(lowerField.data[0]) |
                           (UInt64(lowerField.data[1]) << 8) |
                           (UInt64(lowerField.data[2]) << 16) |
                           (UInt64(lowerField.data[3]) << 24) |
                           (UInt64(lowerField.data[4]) << 32) |
                           (UInt64(lowerField.data[5]) << 40) |
                           (UInt64(lowerField.data[6]) << 48) |
                           (UInt64(lowerField.data[7]) << 56)
            let lowerBound = Date(timeIntervalSince1970: Double(bitPattern: lowerBits))

            // Field 2: upperBound (Double as 64-bit)
            guard let upperField = fields[2], upperField.wireType == 1 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Range upperBound (field 2) not found or invalid"
                    )
                )
            }
            guard upperField.data.count == 8 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Range upperBound must be 8 bytes"
                    )
                )
            }
            let upperBits = UInt64(upperField.data[0]) |
                           (UInt64(upperField.data[1]) << 8) |
                           (UInt64(upperField.data[2]) << 16) |
                           (UInt64(upperField.data[3]) << 24) |
                           (UInt64(upperField.data[4]) << 32) |
                           (UInt64(upperField.data[5]) << 40) |
                           (UInt64(upperField.data[6]) << 48) |
                           (UInt64(upperField.data[7]) << 56)
            let upperBound = Date(timeIntervalSince1970: Double(bitPattern: upperBits))

            return (lowerBound..<upperBound) as! T
        }

        // Special handling for ClosedRange<Date>
        if type == ClosedRange<Date>.self {
            // Check if field exists (important for Optional<ClosedRange<Date>>)
            guard contains(key) else {
                throw DecodingError.keyNotFound(
                    key,
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "ClosedRange field not found"
                    )
                )
            }

            let (_, data) = try getField(for: key)

            var offset = 0
            let fields = Self.parseFields(from: data, offset: &offset)

            // Field 1: lowerBound
            guard let lowerField = fields[1], lowerField.wireType == 1, lowerField.data.count == 8 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "ClosedRange lowerBound (field 1) not found or invalid"
                    )
                )
            }
            let lowerBits = UInt64(lowerField.data[0]) |
                           (UInt64(lowerField.data[1]) << 8) |
                           (UInt64(lowerField.data[2]) << 16) |
                           (UInt64(lowerField.data[3]) << 24) |
                           (UInt64(lowerField.data[4]) << 32) |
                           (UInt64(lowerField.data[5]) << 40) |
                           (UInt64(lowerField.data[6]) << 48) |
                           (UInt64(lowerField.data[7]) << 56)
            let lowerBound = Date(timeIntervalSince1970: Double(bitPattern: lowerBits))

            // Field 2: upperBound
            guard let upperField = fields[2], upperField.wireType == 1, upperField.data.count == 8 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "ClosedRange upperBound (field 2) not found or invalid"
                    )
                )
            }
            let upperBits = UInt64(upperField.data[0]) |
                           (UInt64(upperField.data[1]) << 8) |
                           (UInt64(upperField.data[2]) << 16) |
                           (UInt64(upperField.data[3]) << 24) |
                           (UInt64(upperField.data[4]) << 32) |
                           (UInt64(upperField.data[5]) << 40) |
                           (UInt64(upperField.data[6]) << 48) |
                           (UInt64(upperField.data[7]) << 56)
            let upperBound = Date(timeIntervalSince1970: Double(bitPattern: upperBits))

            return (lowerBound...upperBound) as! T
        }

        // Special handling for PartialRange types
        // Check if type is one of the PartialRange types
        let isPartialRangeFrom = type == PartialRangeFrom<Date>.self
        let isPartialRangeThrough = type == PartialRangeThrough<Date>.self
        let isPartialRangeUpTo = type == PartialRangeUpTo<Date>.self

        if isPartialRangeFrom || isPartialRangeThrough || isPartialRangeUpTo {
            guard contains(key) else {
                throw DecodingError.keyNotFound(
                    key,
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "PartialRange field not found"
                    )
                )
            }

            let (_, data) = try getField(for: key)

            var offset = 0
            let fields = Self.parseFields(from: data, offset: &offset)

            // Determine which PartialRange type based on present fields
            let hasField1 = fields[1] != nil
            let hasField2 = fields[2] != nil

            // PartialRangeFrom: field 1 only
            if hasField1 && !hasField2 {
                guard isPartialRangeFrom else {
                    throw DecodingError.typeMismatch(
                        type,
                        DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "Expected PartialRangeFrom but got different type with field 1 present"
                        )
                    )
                }
                guard let lowerField = fields[1], lowerField.wireType == 1, lowerField.data.count == 8 else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "PartialRangeFrom lowerBound (field 1) invalid"
                        )
                    )
                }
                let lowerBits = UInt64(lowerField.data[0]) |
                               (UInt64(lowerField.data[1]) << 8) |
                               (UInt64(lowerField.data[2]) << 16) |
                               (UInt64(lowerField.data[3]) << 24) |
                               (UInt64(lowerField.data[4]) << 32) |
                               (UInt64(lowerField.data[5]) << 40) |
                               (UInt64(lowerField.data[6]) << 48) |
                               (UInt64(lowerField.data[7]) << 56)
                let lowerBound = Date(timeIntervalSince1970: Double(bitPattern: lowerBits))

                return (lowerBound...) as! T
            }
            // PartialRangeThrough or PartialRangeUpTo: field 2 only
            else if !hasField1 && hasField2 {
                guard isPartialRangeThrough || isPartialRangeUpTo else {
                    throw DecodingError.typeMismatch(
                        type,
                        DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "Expected PartialRangeThrough or PartialRangeUpTo but got different type with field 2 present"
                        )
                    )
                }
                guard let upperField = fields[2], upperField.wireType == 1, upperField.data.count == 8 else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "PartialRange upperBound (field 2) invalid"
                        )
                    )
                }
                let upperBits = UInt64(upperField.data[0]) |
                               (UInt64(upperField.data[1]) << 8) |
                               (UInt64(upperField.data[2]) << 16) |
                               (UInt64(upperField.data[3]) << 24) |
                               (UInt64(upperField.data[4]) << 32) |
                               (UInt64(upperField.data[5]) << 40) |
                               (UInt64(upperField.data[6]) << 48) |
                               (UInt64(upperField.data[7]) << 56)
                let upperBound = Date(timeIntervalSince1970: Double(bitPattern: upperBits))

                if isPartialRangeThrough {
                    return (...upperBound) as! T
                } else if isPartialRangeUpTo {
                    return (..<upperBound) as! T
                } else {
                    fatalError("Unreachable: checked isPartialRangeThrough || isPartialRangeUpTo above")
                }
            }
            else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Invalid PartialRange structure: both or neither fields present"
                    )
                )
            }
        }

        // Special handling for arrays (packed repeated fields)
        if type == [Int32].self {
            return try decodePackedInt32Array(forKey: key) as! T
        }
        if type == [Int64].self {
            return try decodePackedInt64Array(forKey: key) as! T
        }
        if type == [UInt32].self {
            return try decodePackedUInt32Array(forKey: key) as! T
        }
        if type == [UInt64].self {
            return try decodePackedUInt64Array(forKey: key) as! T
        }
        if type == [Bool].self {
            return try decodePackedBoolArray(forKey: key) as! T
        }
        if type == [Float].self {
            return try decodePackedFloatArray(forKey: key) as! T
        }
        if type == [Double].self {
            return try decodePackedDoubleArray(forKey: key) as! T
        }
        if type == [String].self {
            return try decodeStringArray(forKey: key) as! T
        }
        if type == [Data].self {
            return try decodeDataArray(forKey: key) as! T
        }

        let (_, data) = try getField(for: key)

        // Decode nested message
        let nestedDecoder = ProtobufDecoder()
        return try nestedDecoder.decode(type, from: data)
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Nested containers not supported - decode nested types directly"
            )
        )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Nested unkeyed containers not supported"
            )
        )
    }

    func superDecoder() throws -> Decoder {
        return decoder
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        return decoder
    }

    // MARK: - Array Decoding Helpers

    private func decodePackedInt32Array(forKey key: Key) throws -> [Int32] {
        // Check if field exists - if not, return empty array
        guard contains(key) else {
            return []
        }

        let (wireType, data) = try getField(for: key)
        guard wireType == 2 else {  // Length-delimited
            throw DecodingError.typeMismatch(
                [Int32].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected length-delimited wire type for packed array"
                )
            )
        }

        var result: [Int32] = []
        var offset = 0
        while offset < data.count {
            let value = try decodeVarint(from: data, offset: &offset)
            result.append(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
        }
        return result
    }

    private func decodePackedInt64Array(forKey key: Key) throws -> [Int64] {
        guard contains(key) else {
            return []
        }

        let (wireType, data) = try getField(for: key)
        guard wireType == 2 else {
            throw DecodingError.typeMismatch(
                [Int64].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected length-delimited wire type for packed array"
                )
            )
        }

        var result: [Int64] = []
        var offset = 0
        while offset < data.count {
            let value = try decodeVarint(from: data, offset: &offset)
            result.append(Int64(bitPattern: value))
        }
        return result
    }

    private func decodePackedUInt32Array(forKey key: Key) throws -> [UInt32] {
        guard contains(key) else {
            return []
        }

        let (wireType, data) = try getField(for: key)
        guard wireType == 2 else {
            throw DecodingError.typeMismatch(
                [UInt32].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected length-delimited wire type for packed array"
                )
            )
        }

        var result: [UInt32] = []
        var offset = 0
        while offset < data.count {
            let value = try decodeVarint(from: data, offset: &offset)
            result.append(UInt32(truncatingIfNeeded: value))
        }
        return result
    }

    private func decodePackedUInt64Array(forKey key: Key) throws -> [UInt64] {
        guard contains(key) else {
            return []
        }

        let (wireType, data) = try getField(for: key)
        guard wireType == 2 else {
            throw DecodingError.typeMismatch(
                [UInt64].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected length-delimited wire type for packed array"
                )
            )
        }

        var result: [UInt64] = []
        var offset = 0
        while offset < data.count {
            let value = try decodeVarint(from: data, offset: &offset)
            result.append(value)
        }
        return result
    }

    private func decodePackedBoolArray(forKey key: Key) throws -> [Bool] {
        guard contains(key) else {
            return []
        }

        let (wireType, data) = try getField(for: key)
        guard wireType == 2 else {
            throw DecodingError.typeMismatch(
                [Bool].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected length-delimited wire type for packed array"
                )
            )
        }

        var result: [Bool] = []
        var offset = 0
        while offset < data.count {
            let value = try decodeVarint(from: data, offset: &offset)
            result.append(value != 0)
        }
        return result
    }

    private func decodePackedFloatArray(forKey key: Key) throws -> [Float] {
        guard contains(key) else {
            return []
        }

        let (wireType, data) = try getField(for: key)
        guard wireType == 2 else {
            throw DecodingError.typeMismatch(
                [Float].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected length-delimited wire type for packed array"
                )
            )
        }

        var result: [Float] = []
        var offset = 0
        while offset + 4 <= data.count {
            let bits = UInt32(data[offset]) |
                       (UInt32(data[offset + 1]) << 8) |
                       (UInt32(data[offset + 2]) << 16) |
                       (UInt32(data[offset + 3]) << 24)
            result.append(Float(bitPattern: bits))
            offset += 4
        }
        return result
    }

    private func decodePackedDoubleArray(forKey key: Key) throws -> [Double] {
        guard contains(key) else {
            return []
        }

        let (wireType, data) = try getField(for: key)
        guard wireType == 2 else {
            throw DecodingError.typeMismatch(
                [Double].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected length-delimited wire type for packed array"
                )
            )
        }

        var result: [Double] = []
        var offset = 0
        while offset + 8 <= data.count {
            let bits = UInt64(data[offset]) |
                       (UInt64(data[offset + 1]) << 8) |
                       (UInt64(data[offset + 2]) << 16) |
                       (UInt64(data[offset + 3]) << 24) |
                       (UInt64(data[offset + 4]) << 32) |
                       (UInt64(data[offset + 5]) << 40) |
                       (UInt64(data[offset + 6]) << 48) |
                       (UInt64(data[offset + 7]) << 56)
            result.append(Double(bitPattern: bits))
            offset += 8
        }
        return result
    }

    private func decodeStringArray(forKey key: Key) throws -> [String] {
        guard contains(key) else {
            return []
        }

        // String arrays use non-packed repeated encoding
        // Each string appears as a separate field with the same field number
        // We need to collect all occurrences of this field number
        let fieldNumber = getFieldNumber(for: key)

        var result: [String] = []

        // Scan through the raw data to find all occurrences of this field
        var offset = 0
        while offset < decoder.data.count {
            guard let tag = try? decodeVarint(from: decoder.data, offset: &offset) else {
                break
            }

            let currentFieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            if currentFieldNumber == fieldNumber {
                // Found our field - decode the string
                guard wireType == 2 else {  // Must be length-delimited
                    throw DecodingError.typeMismatch(
                        [String].self,
                        DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "Expected length-delimited wire type for string array element"
                        )
                    )
                }

                guard let length = try? decodeVarint(from: decoder.data, offset: &offset) else {
                    break
                }

                let endOffset = offset + Int(length)
                guard endOffset <= decoder.data.count else {
                    break
                }

                let stringData = Data(decoder.data[offset..<endOffset])
                guard let string = String(data: stringData, encoding: .utf8) else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "Invalid UTF-8 data in string array element"
                        )
                    )
                }
                result.append(string)
                offset = endOffset
            } else {
                // Skip other fields
                switch wireType {
                case 0:  // Varint
                    _ = try? decodeVarint(from: decoder.data, offset: &offset)
                case 1:  // 64-bit
                    offset += 8
                case 2:  // Length-delimited
                    if let length = try? decodeVarint(from: decoder.data, offset: &offset) {
                        offset += Int(length)
                    }
                case 5:  // 32-bit
                    offset += 4
                default:
                    break
                }
            }
        }

        return result
    }

    private func decodeDataArray(forKey key: Key) throws -> [Data] {
        guard contains(key) else {
            return []
        }

        // Data arrays use non-packed repeated encoding (like strings)
        // Each Data appears as a separate field with the same field number
        let fieldNumber = getFieldNumber(for: key)

        var result: [Data] = []

        // Scan through the raw data to find all occurrences of this field
        var offset = 0
        while offset < decoder.data.count {
            guard let tag = try? decodeVarint(from: decoder.data, offset: &offset) else {
                break
            }

            let currentFieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            if currentFieldNumber == fieldNumber {
                // Found our field - decode the data
                guard wireType == 2 else {  // Must be length-delimited
                    throw DecodingError.typeMismatch(
                        [Data].self,
                        DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "Expected length-delimited wire type for data array element"
                        )
                    )
                }

                guard let length = try? decodeVarint(from: decoder.data, offset: &offset) else {
                    break
                }

                let endOffset = offset + Int(length)
                guard endOffset <= decoder.data.count else {
                    break
                }

                let data = Data(decoder.data[offset..<endOffset])
                result.append(data)
                offset = endOffset
            } else {
                // Skip other fields
                switch wireType {
                case 0:  // Varint
                    _ = try? decodeVarint(from: decoder.data, offset: &offset)
                case 1:  // 64-bit
                    offset += 8
                case 2:  // Length-delimited
                    if let length = try? decodeVarint(from: decoder.data, offset: &offset) {
                        offset += Int(length)
                    }
                case 5:  // 32-bit
                    offset += 4
                default:
                    break
                }
            }
        }

        return result
    }

    // MARK: - Helpers

    private func getFieldNumber(for key: Key) -> Int {
        let fieldName = key.stringValue

        // If we've already assigned a number to this field, return it
        if let existing = tracker.fieldNumbers[fieldName] {
            return existing
        }

        // Use field number from Recordable.fieldNumber() if available
        // Otherwise use explicit intValue from CodingKey
        // Otherwise assign sequentially
        let fieldNumber: Int
        if let lookup = decoder.fieldNumberLookup, let recordableFieldNumber = lookup(fieldName) {
            fieldNumber = recordableFieldNumber
        } else if let explicitNumber = key.intValue {
            fieldNumber = explicitNumber
        } else {
            fieldNumber = tracker.nextFieldNumber
            tracker.nextFieldNumber += 1
        }

        tracker.fieldNumbers[fieldName] = fieldNumber
        return fieldNumber
    }

    private func getField(for key: Key) throws -> (wireType: Int, data: Data) {
        let fieldNumber = getFieldNumber(for: key)

        guard let field = fields[fieldNumber] else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Field \(fieldNumber) '\(key.stringValue)' not found in Protobuf data"
                )
            )
        }

        return field
    }
}

// MARK: - Unkeyed Decoding Container

private struct _ProtobufUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let decoder: _ProtobufDecoder
    var codingPath: [CodingKey] { decoder.codingPath }
    var count: Int? = nil
    var isAtEnd: Bool { return decoder.offset >= decoder.data.count }
    var currentIndex: Int = 0

    func decodeNil() throws -> Bool {
        return false
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed containers (arrays) not supported at top level"
            )
        )
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Nested containers not supported"
            )
        )
    }

    func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Nested unkeyed containers not supported"
            )
        )
    }

    func superDecoder() throws -> Decoder {
        return decoder
    }
}

// MARK: - Single Value Decoding Container

private struct _ProtobufSingleValueDecodingContainer: SingleValueDecodingContainer {
    let decoder: _ProtobufDecoder
    var codingPath: [CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool {
        return decoder.data.isEmpty
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        var offset = decoder.offset
        let value = try decodeVarint(from: decoder.data, offset: &offset)
        decoder.offset = offset
        return value != 0
    }

    func decode(_ type: String.Type) throws -> String {
        let data = decoder.data[decoder.offset...]
        decoder.offset = decoder.data.count
        guard let string = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Invalid UTF-8 data"
                )
            )
        }
        return string
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard decoder.data.count - decoder.offset >= 8 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Insufficient data for Double"
                )
            )
        }
        let data = decoder.data
        let offset = decoder.offset
        let bits = UInt64(data[offset]) |
                   (UInt64(data[offset + 1]) << 8) |
                   (UInt64(data[offset + 2]) << 16) |
                   (UInt64(data[offset + 3]) << 24) |
                   (UInt64(data[offset + 4]) << 32) |
                   (UInt64(data[offset + 5]) << 40) |
                   (UInt64(data[offset + 6]) << 48) |
                   (UInt64(data[offset + 7]) << 56)
        decoder.offset += 8
        return Double(bitPattern: bits)
    }

    func decode(_ type: Float.Type) throws -> Float {
        guard decoder.data.count - decoder.offset >= 4 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Insufficient data for Float"
                )
            )
        }
        let data = decoder.data
        let offset = decoder.offset
        let bits = UInt32(data[offset]) |
                   (UInt32(data[offset + 1]) << 8) |
                   (UInt32(data[offset + 2]) << 16) |
                   (UInt32(data[offset + 3]) << 24)
        decoder.offset += 4
        return Float(bitPattern: bits)
    }

    func decode(_ type: Int.Type) throws -> Int {
        return Int(try decode(Int64.self))
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        return Int8(try decode(Int64.self))
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        return Int16(try decode(Int64.self))
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        var offset = decoder.offset
        let value = try decodeVarint(from: decoder.data, offset: &offset)
        decoder.offset = offset
        return Int32(bitPattern: UInt32(truncatingIfNeeded: value))
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        var offset = decoder.offset
        let value = try decodeVarint(from: decoder.data, offset: &offset)
        decoder.offset = offset
        return Int64(bitPattern: value)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        return UInt(try decode(UInt64.self))
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        return UInt8(try decode(UInt64.self))
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        return UInt16(try decode(UInt64.self))
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        return UInt32(try decode(UInt64.self))
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        var offset = decoder.offset
        let value = try decodeVarint(from: decoder.data, offset: &offset)
        decoder.offset = offset
        return value
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        return try T(from: decoder)
    }
}

// MARK: - Varint Decoding Helper

private func decodeVarint(from data: Data, offset: inout Int) throws -> UInt64 {
    var result: UInt64 = 0
    var shift: UInt64 = 0

    while offset < data.count {
        let byte = data[offset]
        offset += 1
        result |= UInt64(byte & 0x7F) << shift
        if byte & 0x80 == 0 {
            return result
        }
        shift += 7
        if shift >= 64 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Varint too long"
                )
            )
        }
    }

    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: [],
            debugDescription: "Unexpected end of data while decoding varint"
        )
    )
}
