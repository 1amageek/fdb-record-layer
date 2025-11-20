import Testing
import Foundation
 import FDBRecordCore
import FoundationDB
@testable import FDBRecordLayer

// MARK: - Test Types

/// Static directory path
@Recordable
struct StaticDirRecord {
    #Directory<StaticDirRecord>("app", "static", layer: .recordStore)
    #PrimaryKey<StaticDirRecord>([\.id])

    var id: Int64
    var value: String
}

/// Test that @Recordable generates openDirectory() and store() methods when #Directory is present
@Suite("Directory Integration Tests", .tags(.integration))
struct DirectoryIntegrationTests {

    // MARK: - Compilation Tests

    /// Verify that @Recordable generates basic Recordable conformance
    @Test("Basic Recordable conformance without Directory")
    func basicRecordableConformance() {
        // These should compile if @Recordable works correctly
        #expect(StaticDirRecord.recordName == "StaticDirRecord")
        #expect(StaticDirRecord.primaryKeyFields == ["id"])
        #expect(StaticDirRecord.allFields == ["id", "value"])
    }

    /// Verify Protobuf serialization works
    @Test("Protobuf serialization without Directory")
    func protobufSerialization() throws {
        let record = StaticDirRecord(id: 123, value: "test")

        // Serialize
        let data = try ProtobufEncoder().encode(record)
        #expect(!data.isEmpty)

        // Deserialize
        let decoded = try ProtobufDecoder().decode(StaticDirRecord.self, from: data)
        #expect(decoded.id == 123)
        #expect(decoded.value == "test")
    }

    // MARK: - Directory Method Tests

    @Test("Static directory generates openDirectory()")
    func staticDirectoryOpenDirectory() async throws {
        // Compile-time verification: Check that the method signature exists
        let _: (any DatabaseProtocol) async throws -> DirectorySubspace =
            StaticDirRecord.openDirectory(database:)

        // This test verifies that @Recordable macro successfully:
        // 1. Detected #Directory<StaticDirRecord>(["app", "static"], layer: .recordStore)
        // 2. Generated openDirectory(database:) method
        // 3. Method returns DirectorySubspace type
    }

    @Test("Static directory generates store()")
    func staticDirectoryStore() async throws {
        // Compile-time verification: Check that the method signature exists
        let _: (any DatabaseProtocol, Schema) async throws -> RecordStore<StaticDirRecord> =
            StaticDirRecord.store(database:schema:)

        // This test verifies that @Recordable macro successfully:
        // 1. Generated store(database:schema:) method
        // 2. Method returns RecordStore<StaticDirRecord> type
    }

    // MARK: - Documentation

    /// This test suite verifies that @Recordable correctly processes #Directory macros
    /// and generates appropriate openDirectory() and store() methods.
    ///
    /// Current status:
    /// - ✅ DirectoryLayer type implemented and tested
    /// - ✅ DirectoryMacro validation implemented and tested
    /// - ✅ RecordableMacro reads #Directory and generates methods
    /// - ⏳ Runtime testing blocked on fdb-swift-bindings Directory Layer API
    ///
    /// Once fdb-swift-bindings implements:
    /// - DatabaseProtocol.directory property
    /// - DirectoryLayer.createOrOpen() method
    /// - DirectorySubspace type
    ///
    /// The commented tests can be enabled for full integration testing.
}
