import Testing
import Foundation
@testable import FDBRecordLayer

@Suite("Serializer Tests")
struct SerializerTests {

    // MARK: - Test Models

    struct SimpleRecord: Codable, Equatable {
        let id: Int64
        let name: String
        let active: Bool
    }

    struct NestedRecord: Codable, Equatable {
        let id: Int64
        let metadata: Metadata

        struct Metadata: Codable, Equatable {
            let version: Int
            let tags: [String]
        }
    }

    struct OptionalFieldsRecord: Codable, Equatable {
        let id: Int64
        let name: String?
        let email: String?
    }

    // MARK: - CodableSerializer Tests

    @Test("CodableSerializer serializes and deserializes simple record")
    func codableSerializerSimpleRecord() throws {
        let serializer = CodableSerializer<SimpleRecord>()
        let original = SimpleRecord(id: 12345, name: "Alice", active: true)

        // Serialize
        let bytes = try serializer.serialize(original)
        #expect(!bytes.isEmpty)

        // Deserialize
        let deserialized = try serializer.deserialize(bytes)
        #expect(deserialized == original)
    }

    @Test("CodableSerializer handles nested structures")
    func codableSerializerNestedRecord() throws {
        let serializer = CodableSerializer<NestedRecord>()
        let original = NestedRecord(
            id: 999,
            metadata: NestedRecord.Metadata(
                version: 2,
                tags: ["important", "urgent"]
            )
        )

        // Serialize
        let bytes = try serializer.serialize(original)
        #expect(!bytes.isEmpty)

        // Deserialize
        let deserialized = try serializer.deserialize(bytes)
        #expect(deserialized == original)
        #expect(deserialized.metadata.tags == ["important", "urgent"])
    }

    @Test("CodableSerializer handles optional fields correctly")
    func codableSerializerOptionalFields() throws {
        let serializer = CodableSerializer<OptionalFieldsRecord>()

        // Test with some fields nil
        let record1 = OptionalFieldsRecord(id: 1, name: "Alice", email: nil)
        let bytes1 = try serializer.serialize(record1)
        let deserialized1 = try serializer.deserialize(bytes1)
        #expect(deserialized1 == record1)
        #expect(deserialized1.email == nil)

        // Test with all fields present
        let record2 = OptionalFieldsRecord(id: 2, name: "Bob", email: "bob@example.com")
        let bytes2 = try serializer.serialize(record2)
        let deserialized2 = try serializer.deserialize(bytes2)
        #expect(deserialized2 == record2)
        #expect(deserialized2.email == "bob@example.com")
    }

    @Test("CodableSerializer throws on invalid data")
    func codableSerializerInvalidData() {
        let serializer = CodableSerializer<SimpleRecord>()
        let invalidBytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0xFC]

        #expect(throws: (any Error).self) {
            _ = try serializer.deserialize(invalidBytes)
        }
    }

    @Test("CodableSerializer produces deterministic output")
    func codableSerializerDeterministic() throws {
        let serializer = CodableSerializer<SimpleRecord>()
        let record = SimpleRecord(id: 123, name: "Test", active: false)

        // Serialize multiple times
        let bytes1 = try serializer.serialize(record)
        let bytes2 = try serializer.serialize(record)
        let bytes3 = try serializer.serialize(record)

        // All should be identical
        #expect(bytes1 == bytes2)
        #expect(bytes2 == bytes3)
    }

    @Test("CodableSerializer handles empty strings")
    func codableSerializerEmptyString() throws {
        let serializer = CodableSerializer<SimpleRecord>()
        let record = SimpleRecord(id: 456, name: "", active: true)

        let bytes = try serializer.serialize(record)
        let deserialized = try serializer.deserialize(bytes)

        #expect(deserialized.name == "")
        #expect(deserialized == record)
    }

    @Test("CodableSerializer handles large records")
    func codableSerializerLargeRecord() throws {
        struct LargeRecord: Codable, Equatable {
            let id: Int64
            let data: [String]
        }

        let serializer = CodableSerializer<LargeRecord>()
        // Create record with 1000 strings
        let largeData = (0..<1000).map { "item_\($0)" }
        let record = LargeRecord(id: 789, data: largeData)

        let bytes = try serializer.serialize(record)
        let deserialized = try serializer.deserialize(bytes)

        #expect(deserialized == record)
        #expect(deserialized.data.count == 1000)
    }

    @Test("CodableSerializer handles special characters in strings")
    func codableSerializerSpecialCharacters() throws {
        let serializer = CodableSerializer<SimpleRecord>()
        let specialNames = [
            "Test with spaces",
            "Test\nwith\nnewlines",
            "Test\twith\ttabs",
            "Test with emoji 😀🎉",
            "Test with unicode: 日本語",
            "Test with quotes: \"quoted\"",
            "Test with backslash: \\path\\to\\file"
        ]

        for name in specialNames {
            let record = SimpleRecord(id: 1, name: name, active: true)
            let bytes = try serializer.serialize(record)
            let deserialized = try serializer.deserialize(bytes)
            #expect(deserialized.name == name)
        }
    }

    @Test("CodableSerializer handles numeric edge cases")
    func codableSerializerNumericEdgeCases() throws {
        let serializer = CodableSerializer<SimpleRecord>()

        let edgeCases: [Int64] = [
            0,
            1,
            -1,
            Int64.max,
            Int64.min,
            Int64.max - 1,
            Int64.min + 1
        ]

        for value in edgeCases {
            let record = SimpleRecord(id: value, name: "Test", active: true)
            let bytes = try serializer.serialize(record)
            let deserialized = try serializer.deserialize(bytes)
            #expect(deserialized.id == value)
        }
    }
}
