import XCTest
@testable import FDBRecordLayer

/// Basic smoke tests to verify module imports and basic functionality
final class FDBRecordLayerTests: XCTestCase {
    func testModuleImport() {
        // Verify that basic types are accessible
        let _ = Subspace(rootPrefix: "test")
        let _ = FieldKeyExpression(fieldName: "test")
        let _ = RecordLayerError.contextAlreadyClosed
        let _ = IndexType.value
        let _ = IndexState.readable
    }

    func testTupleHelpers() {
        let int64Value = Int64(12345)
        let bytes = TupleHelpers.int64ToBytes(int64Value)
        let decoded = TupleHelpers.bytesToInt64(bytes)

        XCTAssertEqual(int64Value, decoded)
    }

    func testTupleElementConversion() {
        let elements: [any TupleElement] = ["test", Int64(123), true]
        let tuple = TupleHelpers.toTuple(elements)

        // Verify tuple was created successfully
        XCTAssertFalse(tuple.encode().isEmpty)
    }
}
