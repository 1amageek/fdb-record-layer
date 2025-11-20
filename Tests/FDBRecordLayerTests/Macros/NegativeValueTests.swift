import Testing
import Foundation
 import FDBRecordCore
@testable import FDBRecordLayer

// MARK: - Test Types with Negative Values

@Recordable
struct TestIntegerTypes {#PrimaryKey<TestIntegerTypes>([\.id])

    
    var id: Int64
    var int32Value: Int32
    var int64Value: Int64
    var uint32Value: UInt32
    var uint64Value: UInt64
}

@Recordable
struct TestFloatingPointTypes {#PrimaryKey<TestFloatingPointTypes>([\.id])

    
    var id: Int64
    var doubleValue: Double
    var floatValue: Float
}

// MARK: - Test Suite

@Suite("Negative Value Tests")
struct NegativeValueTests {

    /// Test serialization and deserialization of negative Int32
    @Test("Int32 negative values")
    func testInt32NegativeValues() throws {
        let record = TestIntegerTypes(
            id: 1,
            int32Value: -1,
            int64Value: 0,
            uint32Value: 0,
            uint64Value: 0
        )

        // Serialize
        let data = try ProtobufEncoder().encode(record)
        #expect(!data.isEmpty)

        // Deserialize
        let decoded = try ProtobufDecoder().decode(TestIntegerTypes.self, from: data)
        #expect(decoded.int32Value == -1, "Int32(-1) should be preserved")
    }

    /// Test serialization and deserialization of negative Int64
    @Test("Int64 negative values")
    func testInt64NegativeValues() throws {
        let record = TestIntegerTypes(
            id: -12345678901234,
            int32Value: 0,
            int64Value: -9876543210,
            uint32Value: 0,
            uint64Value: 0
        )

        // Serialize
        let data = try ProtobufEncoder().encode(record)
        #expect(!data.isEmpty)

        // Deserialize
        let decoded = try ProtobufDecoder().decode(TestIntegerTypes.self, from: data)
        #expect(decoded.id == -12345678901234, "Int64 primary key should be preserved")
        #expect(decoded.int64Value == -9876543210, "Int64(-9876543210) should be preserved")
    }

    /// Test serialization and deserialization of Int32 MIN and MAX
    @Test("Int32 edge values")
    func testInt32EdgeValues() throws {
        let record = TestIntegerTypes(
            id: 1,
            int32Value: Int32.min,
            int64Value: Int64(Int32.max),
            uint32Value: 0,
            uint64Value: 0
        )

        let data = try ProtobufEncoder().encode(record)
        let decoded = try ProtobufDecoder().decode(TestIntegerTypes.self, from: data)

        #expect(decoded.int32Value == Int32.min, "Int32.min should be preserved")
        #expect(decoded.int64Value == Int64(Int32.max), "Int32.max should be preserved")
    }

    /// Test serialization and deserialization of Int64 MIN and MAX
    @Test("Int64 edge values")
    func testInt64EdgeValues() throws {
        let record = TestIntegerTypes(
            id: Int64.min,
            int32Value: 0,
            int64Value: Int64.max,
            uint32Value: 0,
            uint64Value: 0
        )

        let data = try ProtobufEncoder().encode(record)
        let decoded = try ProtobufDecoder().decode(TestIntegerTypes.self, from: data)

        #expect(decoded.id == Int64.min, "Int64.min should be preserved")
        #expect(decoded.int64Value == Int64.max, "Int64.max should be preserved")
    }

    /// Test serialization and deserialization of negative floating point values
    @Test("Negative floating point values")
    func testNegativeFloatingPoint() throws {
        let record = TestFloatingPointTypes(
            id: 1,
            doubleValue: -123.456,
            floatValue: -78.9
        )

        let data = try ProtobufEncoder().encode(record)
        let decoded = try ProtobufDecoder().decode(TestFloatingPointTypes.self, from: data)

        // Use approximate equality for floating point
        #expect(abs(decoded.doubleValue - (-123.456)) < 0.0001, "Negative Double should be preserved")
        #expect(abs(decoded.floatValue - (-78.9)) < 0.01, "Negative Float should be preserved")
    }

    /// Test special floating point values (infinity, zero)
    @Test("Special floating point values")
    func testSpecialFloatingPointValues() throws {
        let record = TestFloatingPointTypes(
            id: 1,
            doubleValue: -Double.infinity,
            floatValue: -0.0
        )

        let data = try ProtobufEncoder().encode(record)
        let decoded = try ProtobufDecoder().decode(TestFloatingPointTypes.self, from: data)

        #expect(decoded.doubleValue == -Double.infinity, "-Infinity should be preserved")
        #expect(decoded.floatValue.sign == .minus && decoded.floatValue == 0.0, "-0.0 should be preserved")
    }

    /// Test round-trip with mixed positive and negative values
    @Test("Mixed positive and negative values")
    func testMixedValues() throws {
        let record = TestIntegerTypes(
            id: -999,
            int32Value: -42,
            int64Value: 9223372036854775807, // Int64.max
            uint32Value: 4294967295, // UInt32.max
            uint64Value: 18446744073709551615 // UInt64.max
        )

        let data = try ProtobufEncoder().encode(record)
        let decoded = try ProtobufDecoder().decode(TestIntegerTypes.self, from: data)

        #expect(decoded.id == -999)
        #expect(decoded.int32Value == -42)
        #expect(decoded.int64Value == 9223372036854775807)
        #expect(decoded.uint32Value == 4294967295)
        #expect(decoded.uint64Value == 18446744073709551615)
    }
}
