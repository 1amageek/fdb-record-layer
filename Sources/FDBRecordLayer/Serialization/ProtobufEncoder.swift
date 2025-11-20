import Foundation

/// Encoder that encodes Codable values to Protobuf wire format
///
/// This is a custom Encoder implementation that outputs binary data compatible
/// with the Protobuf wire format used by the original Record Layer implementation.
///
/// **Wire Format**:
/// - Tag: `(fieldNumber << 3) | wireType`
/// - Wire types: 0=Varint, 1=64-bit, 2=Length-delimited, 5=32-bit
///
/// **Usage**:
/// ```swift
/// let encoder = ProtobufEncoder()
/// let data = try encoder.encode(user)
/// ```
///
/// **Note**: This encoder expects that types have CodingKeys with intValue
/// set to the field number (1-indexed). The @Recordable macro automatically
/// generates appropriate CodingKeys.
public final class ProtobufEncoder {
    public init() {}

    /// Encode a Codable value to Protobuf wire format
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = _ProtobufEncoder()

        // Check if T conforms to Recordable and set field number lookup
        if let recordableType = T.self as? any Recordable.Type {
            encoder.fieldNumberLookup = { fieldName in
                return recordableType.fieldNumber(for: fieldName)
            }
        }

        try value.encode(to: encoder)
        return encoder.data
    }
}

// MARK: - Internal Encoder Implementation

private final class _ProtobufEncoder: Encoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var data = Data()
    var fieldNumberLookup: ((String) -> Int?)? = nil

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        let container = _ProtobufKeyedEncodingContainer<Key>(encoder: self)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return _ProtobufUnkeyedEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _ProtobufSingleValueEncodingContainer(encoder: self)
    }
}

// MARK: - Keyed Encoding Container

private struct _ProtobufKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: _ProtobufEncoder
    var codingPath: [CodingKey] { encoder.codingPath }

    // Track next field number (starts at 1 for Protobuf)
    private var nextFieldNumber: Int = 1
    private var fieldNumbers: [String: Int] = [:]

    init(encoder: _ProtobufEncoder) {
        self.encoder = encoder
    }

    mutating func encodeNil(forKey key: Key) throws {
        // Protobuf omits nil/default values
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 0  // Varint
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(value ? 1 : 0))
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        try encode(Int64(value), forKey: key)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try encode(Int64(value), forKey: key)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try encode(Int64(value), forKey: key)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 0  // Varint
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 0  // Varint
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(bitPattern: value)))
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try encode(UInt64(value), forKey: key)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try encode(UInt64(value), forKey: key)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try encode(UInt64(value), forKey: key)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 0  // Varint
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(value)))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 0  // Varint
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(value))
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 5  // 32-bit
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))

        let bits = value.bitPattern
        encoder.data.append(UInt8(truncatingIfNeeded: bits))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 8))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 16))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 24))
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 1  // 64-bit
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))

        let bits = value.bitPattern
        encoder.data.append(UInt8(truncatingIfNeeded: bits))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 8))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 16))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 24))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 32))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 40))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 48))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 56))
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        let fieldNumber = getFieldNumber(for: key)
        let tag = (fieldNumber << 3) | 2  // Length-delimited
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))

        let stringData = value.data(using: .utf8) ?? Data()
        encoder.data.append(contentsOf: encodeVarint(UInt64(stringData.count)))
        encoder.data.append(stringData)
    }

    mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        // Special handling for Date - encode as Double timestamp
        if let date = value as? Date {
            try encode(date.timeIntervalSince1970, forKey: key)
            return
        }

        // Special handling for Data - encode as bytes (length-delimited)
        if let data = value as? Data {
            let fieldNumber = getFieldNumber(for: key)
            let tag = (fieldNumber << 3) | 2  // Length-delimited
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(data.count)))
            encoder.data.append(data)
            return
        }

        // Special handling for Range<Date> - encode bounds as doubles
        if let range = value as? Range<Date> {
            let fieldNumber = getFieldNumber(for: key)

            // Create a mini message with field 1=lowerBound, field 2=upperBound
            var rangeData = Data()

            // Field 1: lowerBound (Double timestamp)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = range.lowerBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (Double timestamp)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = range.upperBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            // Encode as length-delimited
            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Similar handling for ClosedRange<Date>
        if let range = value as? ClosedRange<Date> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound
            let lowerTag = (1 << 3) | 1
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = range.lowerBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound
            let upperTag = (2 << 3) | 1
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = range.upperBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for Range<Int> - generic integer range
        if let range = value as? Range<Int> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (as Int64)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = UInt64(bitPattern: Int64(range.lowerBound))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (as Int64)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = UInt64(bitPattern: Int64(range.upperBound))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for Range<Int64> - 64-bit integer range
        if let range = value as? Range<Int64> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (as Int64)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = UInt64(bitPattern: range.lowerBound)
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (as Int64)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = UInt64(bitPattern: range.upperBound)
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for Range<Double> - floating point range
        if let range = value as? Range<Double> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (Double as bitPattern)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = range.lowerBound.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (Double as bitPattern)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = range.upperBound.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for ClosedRange<Int> - closed integer range
        if let range = value as? ClosedRange<Int> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (as Int64)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = UInt64(bitPattern: Int64(range.lowerBound))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (as Int64)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = UInt64(bitPattern: Int64(range.upperBound))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for ClosedRange<Int64> - closed 64-bit integer range
        if let range = value as? ClosedRange<Int64> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (as Int64)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = UInt64(bitPattern: range.lowerBound)
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (as Int64)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = UInt64(bitPattern: range.upperBound)
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for ClosedRange<Double> - closed floating point range
        if let range = value as? ClosedRange<Double> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (Double as bitPattern)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = range.lowerBound.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (Double as bitPattern)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = range.upperBound.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for ClosedRange<Date> - closed date range
        if let range = value as? ClosedRange<Date> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (Double timestamp)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = range.lowerBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Field 2: upperBound (Double timestamp)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = range.upperBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for PartialRangeFrom<Date> - only lowerBound
        if let range = value as? PartialRangeFrom<Date> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 1: lowerBound (Double timestamp)
            let lowerTag = (1 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(lowerTag)))
            let lowerBits = range.lowerBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: lowerBits >> 56))

            // Encode as length-delimited
            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for PartialRangeThrough<Date> - only upperBound (inclusive)
        if let range = value as? PartialRangeThrough<Date> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 2: upperBound (Double timestamp)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = range.upperBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            // Encode as length-delimited
            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for PartialRangeUpTo<Date> - only upperBound (exclusive)
        if let range = value as? PartialRangeUpTo<Date> {
            let fieldNumber = getFieldNumber(for: key)

            var rangeData = Data()

            // Field 2: upperBound (Double timestamp)
            let upperTag = (2 << 3) | 1  // 64-bit
            rangeData.append(contentsOf: encodeVarint(UInt64(upperTag)))
            let upperBits = range.upperBound.timeIntervalSince1970.bitPattern
            rangeData.append(UInt8(truncatingIfNeeded: upperBits))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 8))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 16))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 24))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 32))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 40))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 48))
            rangeData.append(UInt8(truncatingIfNeeded: upperBits >> 56))

            // Encode as length-delimited
            let tag = (fieldNumber << 3) | 2
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(rangeData.count)))
            encoder.data.append(rangeData)
            return
        }

        // Special handling for arrays (packed repeated fields)
        // Check for common array types
        if let int32Array = value as? [Int32] {
            try encodePackedInt32Array(int32Array, forKey: key)
            return
        }
        if let int64Array = value as? [Int64] {
            try encodePackedInt64Array(int64Array, forKey: key)
            return
        }
        if let uint32Array = value as? [UInt32] {
            try encodePackedUInt32Array(uint32Array, forKey: key)
            return
        }
        if let uint64Array = value as? [UInt64] {
            try encodePackedUInt64Array(uint64Array, forKey: key)
            return
        }
        if let boolArray = value as? [Bool] {
            try encodePackedBoolArray(boolArray, forKey: key)
            return
        }
        if let floatArray = value as? [Float] {
            try encodePackedFloatArray(floatArray, forKey: key)
            return
        }
        if let doubleArray = value as? [Double] {
            try encodePackedDoubleArray(doubleArray, forKey: key)
            return
        }
        if let stringArray = value as? [String] {
            try encodeStringArray(stringArray, forKey: key)
            return
        }
        if let dataArray = value as? [Data] {
            try encodeDataArray(dataArray, forKey: key)
            return
        }

        let fieldNumber = getFieldNumber(for: key)

        // Encode nested message as length-delimited
        let nestedEncoder = ProtobufEncoder()
        let nestedData = try nestedEncoder.encode(value)

        let tag = (fieldNumber << 3) | 2  // Length-delimited
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(nestedData.count)))
        encoder.data.append(nestedData)
    }

    // MARK: - Packed Array Encoding Helpers

    private mutating func encodePackedInt32Array(_ array: [Int32], forKey key: Key) throws {
        guard !array.isEmpty else { return }  // Omit empty arrays
        let fieldNumber = getFieldNumber(for: key)
        var packedData = Data()
        for value in array {
            packedData.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
        }
        let tag = (fieldNumber << 3) | 2  // Length-delimited
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
        encoder.data.append(packedData)
    }

    private mutating func encodePackedInt64Array(_ array: [Int64], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        var packedData = Data()
        for value in array {
            packedData.append(contentsOf: encodeVarint(UInt64(bitPattern: value)))
        }
        let tag = (fieldNumber << 3) | 2
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
        encoder.data.append(packedData)
    }

    private mutating func encodePackedUInt32Array(_ array: [UInt32], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        var packedData = Data()
        for value in array {
            packedData.append(contentsOf: encodeVarint(UInt64(value)))
        }
        let tag = (fieldNumber << 3) | 2
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
        encoder.data.append(packedData)
    }

    private mutating func encodePackedUInt64Array(_ array: [UInt64], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        var packedData = Data()
        for value in array {
            packedData.append(contentsOf: encodeVarint(value))
        }
        let tag = (fieldNumber << 3) | 2
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
        encoder.data.append(packedData)
    }

    private mutating func encodePackedBoolArray(_ array: [Bool], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        var packedData = Data()
        for value in array {
            packedData.append(contentsOf: encodeVarint(value ? 1 : 0))
        }
        let tag = (fieldNumber << 3) | 2
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
        encoder.data.append(packedData)
    }

    private mutating func encodePackedFloatArray(_ array: [Float], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        var packedData = Data()
        for value in array {
            let bits = value.bitPattern
            packedData.append(UInt8(truncatingIfNeeded: bits))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 8))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 16))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        let tag = (fieldNumber << 3) | 2
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
        encoder.data.append(packedData)
    }

    private mutating func encodePackedDoubleArray(_ array: [Double], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        var packedData = Data()
        for value in array {
            let bits = value.bitPattern
            packedData.append(UInt8(truncatingIfNeeded: bits))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 8))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 16))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 24))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 32))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 40))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 48))
            packedData.append(UInt8(truncatingIfNeeded: bits >> 56))
        }
        let tag = (fieldNumber << 3) | 2
        encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
        encoder.data.append(contentsOf: encodeVarint(UInt64(packedData.count)))
        encoder.data.append(packedData)
    }

    private mutating func encodeStringArray(_ array: [String], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        // String arrays use repeated non-packed encoding
        for string in array {
            let tag = (fieldNumber << 3) | 2  // Length-delimited
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            let stringData = string.data(using: .utf8) ?? Data()
            encoder.data.append(contentsOf: encodeVarint(UInt64(stringData.count)))
            encoder.data.append(stringData)
        }
    }

    private mutating func encodeDataArray(_ array: [Data], forKey key: Key) throws {
        guard !array.isEmpty else { return }
        let fieldNumber = getFieldNumber(for: key)
        // Data arrays use repeated non-packed encoding (like strings)
        for data in array {
            let tag = (fieldNumber << 3) | 2  // Length-delimited
            encoder.data.append(contentsOf: encodeVarint(UInt64(tag)))
            encoder.data.append(contentsOf: encodeVarint(UInt64(data.count)))
            encoder.data.append(data)
        }
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        // For now, just use the same encoder - Protobuf doesn't strictly need nested containers
        // since our generic encode<T> method handles nested types
        encoder.codingPath.append(key)
        let container = _ProtobufKeyedEncodingContainer<NestedKey>(encoder: encoder)
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        // Arrays/repeated fields not fully supported yet, but don't crash
        return _ProtobufUnkeyedEncodingContainer(encoder: encoder)
    }

    mutating func superEncoder() -> Encoder {
        return encoder
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        return encoder
    }

    // MARK: - Helpers

    private mutating func getFieldNumber(for key: Key) -> Int {
        let fieldName = key.stringValue

        // If we've already assigned a number to this field, return it
        if let existing = fieldNumbers[fieldName] {
            return existing
        }

        // Use field number from Recordable.fieldNumber() if available
        // Otherwise use explicit intValue from CodingKey
        // Otherwise assign sequentially
        let fieldNumber: Int
        if let lookup = encoder.fieldNumberLookup, let recordableFieldNumber = lookup(fieldName) {
            fieldNumber = recordableFieldNumber
        } else if let explicitNumber = key.intValue {
            fieldNumber = explicitNumber
        } else {
            fieldNumber = nextFieldNumber
            nextFieldNumber += 1
        }

        fieldNumbers[fieldName] = fieldNumber
        return fieldNumber
    }
}

// MARK: - Unkeyed Encoding Container (for arrays)

private struct _ProtobufUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: _ProtobufEncoder
    var codingPath: [CodingKey] { encoder.codingPath }
    var count: Int = 0

    // Arrays are not supported at top level - they should be encoded as repeated fields
    mutating func encodeNil() throws {
        throw EncodingError.invalidValue(
            Optional<Any>.none as Any,
            EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed containers (arrays) must be encoded as repeated fields within a message"
            )
        )
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        throw EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed containers (arrays) must be encoded as repeated fields within a message"
            )
        )
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        // Create a new encoder for nested content
        let nestedEncoder = _ProtobufEncoder()
        nestedEncoder.codingPath = encoder.codingPath
        let container = _ProtobufKeyedEncodingContainer<NestedKey>(encoder: nestedEncoder)
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        // Return a new unkeyed container
        return _ProtobufUnkeyedEncodingContainer(encoder: encoder)
    }

    mutating func superEncoder() -> Encoder {
        return encoder
    }
}

// MARK: - Single Value Encoding Container

private struct _ProtobufSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: _ProtobufEncoder
    var codingPath: [CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws {
        // Single values can't be nil in Protobuf
    }

    mutating func encode(_ value: Bool) throws {
        encoder.data.append(contentsOf: encodeVarint(value ? 1 : 0))
    }

    mutating func encode(_ value: String) throws {
        let stringData = value.data(using: .utf8) ?? Data()
        encoder.data.append(stringData)
    }

    mutating func encode(_ value: Double) throws {
        let bits = value.bitPattern
        encoder.data.append(UInt8(truncatingIfNeeded: bits))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 8))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 16))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 24))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 32))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 40))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 48))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 56))
    }

    mutating func encode(_ value: Float) throws {
        let bits = value.bitPattern
        encoder.data.append(UInt8(truncatingIfNeeded: bits))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 8))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 16))
        encoder.data.append(UInt8(truncatingIfNeeded: bits >> 24))
    }

    mutating func encode(_ value: Int) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
    }

    mutating func encode(_ value: Int8) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
    }

    mutating func encode(_ value: Int16) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
    }

    mutating func encode(_ value: Int32) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(bitPattern: Int64(value))))
    }

    mutating func encode(_ value: Int64) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(bitPattern: value)))
    }

    mutating func encode(_ value: UInt) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(value)))
    }

    mutating func encode(_ value: UInt8) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(value)))
    }

    mutating func encode(_ value: UInt16) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(value)))
    }

    mutating func encode(_ value: UInt32) throws {
        encoder.data.append(contentsOf: encodeVarint(UInt64(value)))
    }

    mutating func encode(_ value: UInt64) throws {
        encoder.data.append(contentsOf: encodeVarint(value))
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        try value.encode(to: encoder)
    }
}

// MARK: - Varint Encoding Helper

private func encodeVarint(_ value: UInt64) -> [UInt8] {
    var result: [UInt8] = []
    var n = value
    while n >= 0x80 {
        result.append(UInt8(n & 0x7F) | 0x80)
        n >>= 7
    }
    result.append(UInt8(n))
    return result
}
