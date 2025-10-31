import Testing
@testable import FDBRecordLayer

/// Basic smoke tests to verify module imports and basic functionality
@Suite("FDBRecordLayer Smoke Tests")
struct FDBRecordLayerTests {
    @Test("Module imports and basic types are accessible")
    func moduleImport() {
        // Verify that basic types are accessible
        let _ = Subspace(rootPrefix: "test")
        let _ = FieldKeyExpression(fieldName: "test")
        let _ = RecordLayerError.contextAlreadyClosed
        let _ = IndexType.value
        let _ = IndexState.readable
    }

    @Test("TupleHelpers int64 conversion works correctly")
    func tupleHelpers() {
        let int64Value = Int64(12345)
        let bytes = TupleHelpers.int64ToBytes(int64Value)
        let decoded = TupleHelpers.bytesToInt64(bytes)

        #expect(int64Value == decoded)
    }

    @Test("TupleHelpers converts tuple elements to Tuple")
    func tupleElementConversion() {
        let elements: [any TupleElement] = ["test", Int64(123), true]
        let tuple = TupleHelpers.toTuple(elements)

        // Verify tuple was created successfully
        #expect(!tuple.encode().isEmpty)
    }
}
