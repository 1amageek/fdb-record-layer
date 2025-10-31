import XCTest
import FoundationDB
@testable import FDBRecordLayer

final class SubspaceTests: XCTestCase {
    func testSubspaceCreation() {
        let subspace = Subspace(rootPrefix: "test")
        XCTAssertFalse(subspace.prefix.isEmpty)
    }

    func testNestedSubspace() {
        let root = Subspace(rootPrefix: "test")
        let nested = root.subspace(Int64(1), "child")

        XCTAssertTrue(nested.prefix.starts(with: root.prefix))
        XCTAssertGreaterThan(nested.prefix.count, root.prefix.count)
    }

    func testPackUnpack() throws {
        let subspace = Subspace(rootPrefix: "test")
        let tuple = Tuple("key", Int64(123))

        let packed = subspace.pack(tuple)
        _ = try subspace.unpack(packed)

        // Verify the packed key has the subspace prefix
        XCTAssertTrue(packed.starts(with: subspace.prefix))
    }

    func testRange() {
        let subspace = Subspace(rootPrefix: "test")
        let (begin, end) = subspace.range()

        XCTAssertEqual(begin, subspace.prefix)
        // End should be greater than begin (lexicographically)
        XCTAssertNotEqual(end, begin)
        XCTAssertTrue(end.starts(with: subspace.prefix))
    }

    func testContains() {
        let subspace = Subspace(rootPrefix: "test")
        let tuple = Tuple("key")
        let key = subspace.pack(tuple)

        XCTAssertTrue(subspace.contains(key))

        let otherSubspace = Subspace(rootPrefix: "other")
        XCTAssertFalse(otherSubspace.contains(key))
    }
}
