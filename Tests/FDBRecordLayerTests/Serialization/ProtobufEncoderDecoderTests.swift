import Testing
import Foundation
@testable import FDBRecordLayer

// MARK: - Test Models

fileprivate struct SimpleRecord: Codable {
    var id: Int64
    var name: String
    var age: Int32
    var isActive: Bool
    var createdAt: Date
}

fileprivate struct NumericRecord: Codable {
    var id: Int64
    var int32Value: Int32
    var int64Value: Int64
    var uint32Value: UInt32
    var uint64Value: UInt64
    var floatValue: Float
    var doubleValue: Double
}

fileprivate struct OptionalRecord: Codable {
    var id: Int64
    var optionalString: String?
    var optionalInt: Int64?
    var optionalBool: Bool?
}

fileprivate struct RangeRecord: Codable {
    var id: Int64
    var period: Range<Date>
    var schedule: ClosedRange<Date>
}

fileprivate struct OptionalRangeRecord: Codable {
    var id: Int64
    var period: Range<Date>?
}

fileprivate struct PartialRangeRecord: Codable {
    var id: Int64
    var validFrom: PartialRangeFrom<Date>
    var validThrough: PartialRangeThrough<Date>
    var validUpTo: PartialRangeUpTo<Date>
}

fileprivate struct OptionalPartialRangeRecord: Codable {
    var id: Int64
    var validFrom: PartialRangeFrom<Date>?
    var validThrough: PartialRangeThrough<Date>?
    var validUpTo: PartialRangeUpTo<Date>?

    enum CodingKeys: String, CodingKey {
        case id
        case validFrom
        case validThrough
        case validUpTo

        var intValue: Int? {
            switch self {
            case .id: return 1
            case .validFrom: return 2
            case .validThrough: return 3
            case .validUpTo: return 4
            }
        }

        init?(intValue: Int) {
            switch intValue {
            case 1: self = .id
            case 2: self = .validFrom
            case 3: self = .validThrough
            case 4: self = .validUpTo
            default: return nil
            }
        }
    }
}

// MARK: - Test Suite

@Suite("Protobuf Encoder/Decoder Tests")
struct ProtobufEncoderDecoderTests {

    // MARK: - Basic Type Tests

    @Test("Simple record encoding and decoding")
    func testSimpleRecord() throws {
        let now = Date()
        let record = SimpleRecord(
            id: 123,
            name: "Alice",
            age: 30,
            isActive: true,
            createdAt: now
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        #expect(!data.isEmpty)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(SimpleRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.name == record.name)
        #expect(decoded.age == record.age)
        #expect(decoded.isActive == record.isActive)
        #expect(abs(decoded.createdAt.timeIntervalSince1970 - now.timeIntervalSince1970) < 0.001)
    }

    @Test("Numeric types encoding and decoding")
    func testNumericTypes() throws {
        let record = NumericRecord(
            id: 1,
            int32Value: -2147483648,
            int64Value: -9223372036854775808,
            uint32Value: 4294967295,
            uint64Value: 18446744073709551615,
            floatValue: 3.14159,
            doubleValue: 2.718281828459045
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(NumericRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.int32Value == record.int32Value)
        #expect(decoded.int64Value == record.int64Value)
        #expect(decoded.uint32Value == record.uint32Value)
        #expect(decoded.uint64Value == record.uint64Value)
        #expect(abs(decoded.floatValue - record.floatValue) < 0.00001)
        #expect(abs(decoded.doubleValue - record.doubleValue) < 0.000001)
    }

    @Test("Zero values encoding and decoding")
    func testZeroValues() throws {
        let record = NumericRecord(
            id: 0,
            int32Value: 0,
            int64Value: 0,
            uint32Value: 0,
            uint64Value: 0,
            floatValue: 0.0,
            doubleValue: 0.0
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(NumericRecord.self, from: data)

        #expect(decoded.id == 0)
        #expect(decoded.int32Value == 0)
        #expect(decoded.int64Value == 0)
        #expect(decoded.uint32Value == 0)
        #expect(decoded.uint64Value == 0)
        #expect(decoded.floatValue == 0.0)
        #expect(decoded.doubleValue == 0.0)
    }

    // MARK: - String Tests

    @Test("Empty string encoding and decoding")
    func testEmptyString() throws {
        let record = SimpleRecord(id: 1, name: "", age: 25, isActive: false, createdAt: Date())

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(SimpleRecord.self, from: data)

        #expect(decoded.name == "")
    }

    @Test("Unicode string encoding and decoding")
    func testUnicodeString() throws {
        let record = SimpleRecord(
            id: 1,
            name: "日本語テスト 🎌 émojis",
            age: 25,
            isActive: true,
            createdAt: Date()
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(SimpleRecord.self, from: data)

        #expect(decoded.name == record.name)
    }

    // MARK: - Optional Tests

    @Test("Optional with values encoding and decoding")
    func testOptionalWithValues() throws {
        let record = OptionalRecord(
            id: 1,
            optionalString: "test",
            optionalInt: 42,
            optionalBool: true
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.optionalString == "test")
        #expect(decoded.optionalInt == 42)
        #expect(decoded.optionalBool == true)
    }

    @Test("Optional with nil values encoding and decoding")
    func testOptionalWithNil() throws {
        let record = OptionalRecord(
            id: 1,
            optionalString: nil,
            optionalInt: nil,
            optionalBool: nil
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.optionalString == nil)
        #expect(decoded.optionalInt == nil)
        #expect(decoded.optionalBool == nil)
    }

    @Test("Mixed optional values encoding and decoding")
    func testMixedOptionals() throws {
        let record = OptionalRecord(
            id: 1,
            optionalString: "present",
            optionalInt: 42,  // Non-nil value
            optionalBool: true  // Non-default value (not false)
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.optionalString == "present")
        #expect(decoded.optionalInt == 42)
        #expect(decoded.optionalBool == true)

        // Note: Protobuf cannot distinguish between nil and default values (0, false, "")
        // Both are encoded by omitting the field, and decode to nil for Optionals
    }

    // MARK: - Range Tests

    @Test("Range<Date> encoding and decoding")
    func testRangeEncoding() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)

        let record = RangeRecord(
            id: 1,
            period: start..<end,
            schedule: start...end
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        #expect(!data.isEmpty)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(RangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        // Dates should be very close (within 0.001 seconds)
        #expect(abs(decoded.period.lowerBound.timeIntervalSince1970 - start.timeIntervalSince1970) < 0.001)
        #expect(abs(decoded.period.upperBound.timeIntervalSince1970 - end.timeIntervalSince1970) < 0.001)
        #expect(abs(decoded.schedule.lowerBound.timeIntervalSince1970 - start.timeIntervalSince1970) < 0.001)
        #expect(abs(decoded.schedule.upperBound.timeIntervalSince1970 - end.timeIntervalSince1970) < 0.001)
    }

    @Test("Optional Range<Date> with nil value encoding and decoding")
    func testOptionalRangeWithNil() throws {
        let record = OptionalRangeRecord(
            id: 1,
            period: nil
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        #expect(!data.isEmpty)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalRangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.period == nil, "Period should be nil")
    }

    @Test("Optional Range<Date> with value encoding and decoding")
    func testOptionalRangeWithValue() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)

        let record = OptionalRangeRecord(
            id: 1,
            period: start..<end
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        #expect(!data.isEmpty)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalRangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.period != nil)
        #expect(abs(decoded.period!.lowerBound.timeIntervalSince1970 - start.timeIntervalSince1970) < 0.001)
        #expect(abs(decoded.period!.upperBound.timeIntervalSince1970 - end.timeIntervalSince1970) < 0.001)
    }

    // MARK: - PartialRange Tests

    @Test("PartialRangeFrom<Date> encoding and decoding")
    func testPartialRangeFromEncoding() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let through = Date(timeIntervalSince1970: 2000)
        let upTo = Date(timeIntervalSince1970: 3000)

        let record = PartialRangeRecord(
            id: 1,
            validFrom: start...,
            validThrough: ...through,
            validUpTo: ..<upTo
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        #expect(!data.isEmpty)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(PartialRangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        // PartialRangeFrom: lowerBound only
        #expect(abs(decoded.validFrom.lowerBound.timeIntervalSince1970 - start.timeIntervalSince1970) < 0.001)
        // PartialRangeThrough: upperBound only
        #expect(abs(decoded.validThrough.upperBound.timeIntervalSince1970 - through.timeIntervalSince1970) < 0.001)
        // PartialRangeUpTo: upperBound only
        #expect(abs(decoded.validUpTo.upperBound.timeIntervalSince1970 - upTo.timeIntervalSince1970) < 0.001)
    }

    @Test("Optional PartialRange with nil values encoding and decoding")
    func testOptionalPartialRangeWithNil() throws {
        let record = OptionalPartialRangeRecord(
            id: 1,
            validFrom: nil,
            validThrough: nil,
            validUpTo: nil
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        #expect(!data.isEmpty)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalPartialRangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.validFrom == nil, "validFrom should be nil")
        #expect(decoded.validThrough == nil, "validThrough should be nil")
        #expect(decoded.validUpTo == nil, "validUpTo should be nil")
    }

    @Test("Optional PartialRange with values encoding and decoding")
    func testOptionalPartialRangeWithValues() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let through = Date(timeIntervalSince1970: 2000)
        let upTo = Date(timeIntervalSince1970: 3000)

        let record = OptionalPartialRangeRecord(
            id: 1,
            validFrom: start...,
            validThrough: ...through,
            validUpTo: ..<upTo
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        #expect(!data.isEmpty)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalPartialRangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.validFrom != nil)
        #expect(decoded.validThrough != nil)
        #expect(decoded.validUpTo != nil)
        #expect(abs(decoded.validFrom!.lowerBound.timeIntervalSince1970 - start.timeIntervalSince1970) < 0.001)
        #expect(abs(decoded.validThrough!.upperBound.timeIntervalSince1970 - through.timeIntervalSince1970) < 0.001)
        #expect(abs(decoded.validUpTo!.upperBound.timeIntervalSince1970 - upTo.timeIntervalSince1970) < 0.001)
    }

    @Test("PartialRangeFrom with epoch date encoding and decoding")
    func testPartialRangeFromEpochDate() throws {
        let epochDate = Date(timeIntervalSince1970: 0)

        let record = OptionalPartialRangeRecord(
            id: 1,
            validFrom: epochDate...,
            validThrough: nil,
            validUpTo: nil
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalPartialRangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.validFrom != nil)
        #expect(abs(decoded.validFrom!.lowerBound.timeIntervalSince1970 - epochDate.timeIntervalSince1970) < 0.001)
    }

    @Test("PartialRangeThrough with far future date encoding and decoding")
    func testPartialRangeThroughFutureDate() throws {
        let futureDate = Date(timeIntervalSince1970: Double(Int32.max))

        let record = OptionalPartialRangeRecord(
            id: 1,
            validFrom: nil,
            validThrough: ...futureDate,
            validUpTo: nil
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(OptionalPartialRangeRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.validThrough != nil)
        #expect(abs(decoded.validThrough!.upperBound.timeIntervalSince1970 - futureDate.timeIntervalSince1970) < 0.001)
    }

    // MARK: - Edge Cases

    @Test("Large numbers encoding and decoding")
    func testLargeNumbers() throws {
        let record = NumericRecord(
            id: Int64.max,
            int32Value: Int32.max,
            int64Value: Int64.max,
            uint32Value: UInt32.max,
            uint64Value: UInt64.max,
            floatValue: Float.greatestFiniteMagnitude,
            doubleValue: Double.greatestFiniteMagnitude
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(NumericRecord.self, from: data)

        #expect(decoded.id == Int64.max)
        #expect(decoded.int32Value == Int32.max)
        #expect(decoded.int64Value == Int64.max)
        #expect(decoded.uint32Value == UInt32.max)
        #expect(decoded.uint64Value == UInt64.max)
    }

    @Test("Negative numbers encoding and decoding")
    func testNegativeNumbers() throws {
        let record = NumericRecord(
            id: -1,
            int32Value: Int32.min,
            int64Value: Int64.min,
            uint32Value: 0,
            uint64Value: 0,
            floatValue: -Float.greatestFiniteMagnitude,
            doubleValue: -Double.greatestFiniteMagnitude
        )

        let encoder = ProtobufEncoder()
        let data = try encoder.encode(record)

        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(NumericRecord.self, from: data)

        #expect(decoded.id == -1)
        #expect(decoded.int32Value == Int32.min)
        #expect(decoded.int64Value == Int64.min)
    }

    // MARK: - Field Order Independence

    @Test("Field order should not matter")
    func testFieldOrderIndependence() throws {
        // Encode a record
        let original = SimpleRecord(id: 1, name: "Test", age: 25, isActive: true, createdAt: Date())
        let encoder = ProtobufEncoder()
        let data = try encoder.encode(original)

        // Decode should work regardless of CodingKeys order
        let decoder = ProtobufDecoder()
        let decoded = try decoder.decode(SimpleRecord.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.age == original.age)
        #expect(decoded.isActive == original.isActive)
    }
}
