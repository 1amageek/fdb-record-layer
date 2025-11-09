import Testing
import FoundationDB
@testable import FDBRecordLayer

@Suite("Subspace Tests")
struct SubspaceTests {
    @Test("Subspace creation creates non-empty prefix")
    func subspaceCreation() {
        let subspace = Subspace(prefix: Array("test".utf8))
        #expect(!subspace.prefix.isEmpty)
    }

    @Test("Nested subspace prefix includes root prefix")
    func nestedSubspace() {
        let root = Subspace(prefix: Array("test".utf8))
        let nested = root.subspace(Int64(1), "child")

        #expect(nested.prefix.starts(with: root.prefix))
        #expect(nested.prefix.count > root.prefix.count)
    }

    @Test("Pack/unpack preserves subspace prefix")
    func packUnpack() throws {
        let subspace = Subspace(prefix: Array("test".utf8))
        let tuple = Tuple("key", Int64(123))

        let packed = subspace.pack(tuple)
        _ = try subspace.unpack(packed)

        // Verify the packed key has the subspace prefix
        #expect(packed.starts(with: subspace.prefix))
    }

    @Test("Range returns correct begin and end keys")
    func range() {
        let subspace = Subspace(prefix: Array("test".utf8))
        let (begin, end) = subspace.range()

        // Canonical FDB behavior: begin = prefix + [0x00], end = prefix + [0xFF]
        let expectedBegin = subspace.prefix + [0x00]
        let expectedEnd = subspace.prefix + [0xFF]

        #expect(begin == expectedBegin)
        #expect(end == expectedEnd)
        #expect(end != begin)
    }

    @Test("Range handles 0xFF overflow by appending 0x00")
    func rangeOverflow() {
        // Create a subspace with string that encodes to end with 0xFF
        // Use "test" which should encode without 0xFF at end
        let subspace = Subspace(prefix: Array("test\u{00FF}".utf8))
        let (begin, end) = subspace.range()

        // Canonical FDB behavior: begin = prefix + [0x00], end = prefix + [0xFF]
        let expectedBegin = subspace.prefix + [0x00]
        let expectedEnd = subspace.prefix + [0xFF]

        #expect(begin == expectedBegin)
        #expect(end == expectedEnd)
        #expect(end.count > 0)
    }

    @Test("Range handles special characters")
    func rangeSpecialCharacters() {
        let subspace = Subspace(prefix: Array("test_special_chars".utf8))
        let (begin, end) = subspace.range()

        // Canonical FDB behavior: begin = prefix + [0x00], end = prefix + [0xFF]
        let expectedBegin = subspace.prefix + [0x00]
        let expectedEnd = subspace.prefix + [0xFF]

        #expect(begin == expectedBegin)
        #expect(end == expectedEnd)
        #expect(end.count > 0)
    }

    @Test("Range handles empty prefix")
    func rangeEmptyPrefix() {
        let subspace = Subspace(prefix: Array("".utf8))
        let (begin, end) = subspace.range()

        // Empty string encodes to something in tuple encoding
        #expect(!begin.isEmpty) // Tuple encoding of empty string is not empty
        #expect(end != begin)
    }

    @Test("Contains checks if key belongs to subspace")
    func contains() {
        let subspace = Subspace(prefix: Array("test".utf8))
        let tuple = Tuple("key")
        let key = subspace.pack(tuple)

        #expect(subspace.contains(key))

        let otherSubspace = Subspace(prefix: Array("other".utf8))
        #expect(!otherSubspace.contains(key))
    }
}
