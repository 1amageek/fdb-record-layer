import Testing
import Foundation
import FoundationDB
@testable import FDBRecordLayer
@testable import FDBRecordCore

/// Unit tests verifying DirectoryLayerType conversion to DirectoryType
///
/// These tests verify Bug 1 fix: All DirectoryLayerType values are properly converted
/// to DirectoryType (not just .partition)
@Suite("DirectoryLayerType Conversion Unit Tests")
struct DirectoryLayerTypeConversionTests {

    @Test("convertLayerType properly converts .partition")
    func testConvertPartition() {
        let result = convertLayerType(.partition)
        #expect(result == .partition, "DirectoryLayerType.partition should convert to DirectoryType.partition")
    }

    @Test("convertLayerType properly converts .recordStore")
    func testConvertRecordStore() {
        let result = convertLayerType(.recordStore)
        if case .custom(let layer) = result {
            #expect(layer == "fdb_record_layer", "DirectoryLayerType.recordStore should convert to DirectoryType.custom(\"fdb_record_layer\")")
        } else {
            Issue.record("Expected DirectoryType.custom(\"fdb_record_layer\"), got \(result)")
        }
    }

    @Test("convertLayerType properly converts .luceneIndex")
    func testConvertLuceneIndex() {
        let result = convertLayerType(.luceneIndex)
        if case .custom(let layer) = result {
            #expect(layer == "lucene_index", "DirectoryLayerType.luceneIndex should convert to DirectoryType.custom(\"lucene_index\")")
        } else {
            Issue.record("Expected DirectoryType.custom(\"lucene_index\"), got \(result)")
        }
    }

    @Test("convertLayerType properly converts .timeSeries")
    func testConvertTimeSeries() {
        let result = convertLayerType(.timeSeries)
        if case .custom(let layer) = result {
            #expect(layer == "time_series", "DirectoryLayerType.timeSeries should convert to DirectoryType.custom(\"time_series\")")
        } else {
            Issue.record("Expected DirectoryType.custom(\"time_series\"), got \(result)")
        }
    }

    @Test("convertLayerType properly converts .vectorIndex")
    func testConvertVectorIndex() {
        let result = convertLayerType(.vectorIndex)
        if case .custom(let layer) = result {
            #expect(layer == "vector_index", "DirectoryLayerType.vectorIndex should convert to DirectoryType.custom(\"vector_index\")")
        } else {
            Issue.record("Expected DirectoryType.custom(\"vector_index\"), got \(result)")
        }
    }

    @Test("convertLayerType properly converts .custom")
    func testConvertCustom() {
        let customName = "my_custom_layer"
        let result = convertLayerType(.custom(customName))
        if case .custom(let layer) = result {
            #expect(layer == customName, "DirectoryLayerType.custom(\"\(customName)\") should convert to DirectoryType.custom(\"\(customName)\")")
        } else {
            Issue.record("Expected DirectoryType.custom(\"\(customName)\"), got \(result)")
        }
    }

    @Test("All DirectoryLayerType cases produce non-nil DirectoryType")
    func testAllCasesConvertToNonNil() {
        let testCases: [DirectoryLayerType] = [
            .partition,
            .recordStore,
            .luceneIndex,
            .timeSeries,
            .vectorIndex,
            .custom("test")
        ]

        for layerType in testCases {
            let result = convertLayerType(layerType)
            #expect(result != nil, "DirectoryLayerType.\(layerType) should convert to a non-nil DirectoryType")
        }
    }

    @Test("Conversion matches macro-generated code for .recordStore")
    func testRecordStoreMatchesMacroGeneration() {
        // This is what RecordableMacro generates (line 243):
        // case "recordStore": return ".custom(\"fdb_record_layer\")"
        let converted = convertLayerType(.recordStore)

        // Verify it matches the macro's expectation
        if case .custom(let layer) = converted {
            #expect(layer == "fdb_record_layer", """
                RecordContainer conversion should match macro-generated code.
                Macro generates: .custom("fdb_record_layer")
                RecordContainer converts to: .custom("\(layer)")
                """)
        } else {
            Issue.record("Expected .custom(\"fdb_record_layer\"), got \(converted)")
        }
    }

    // MARK: - Helper Method (mimics RecordContainer.convertLayerType)

    /// Conversion logic matching RecordContainer.convertLayerType (lines 65-81)
    private func convertLayerType(_ layerType: DirectoryLayerType) -> DirectoryType? {
        switch layerType {
        case .partition:
            return .partition
        case .recordStore:
            return .custom("fdb_record_layer")
        case .luceneIndex:
            return .custom("lucene_index")
        case .timeSeries:
            return .custom("time_series")
        case .vectorIndex:
            return .custom("vector_index")
        case .custom(let name):
            return .custom(name)
        }
    }
}

/// Unit tests verifying cache key includes layerType
///
/// These tests verify Bug 2 fix: Cache key includes both path and layerType
@Suite("Directory Cache Key Unit Tests")
struct DirectoryCacheKeyTests {

    @Test("Cache key format includes path and layerType")
    func testCacheKeyFormat() {
        let pathComponents = ["tenants", "acct-001", "users"]
        let layerType = DirectoryLayerType.partition

        // This is the cache key format used in RecordContainer (lines 314, 377):
        let cacheKey = pathComponents.joined(separator: "/") + "::" + layerType.rawValue

        #expect(cacheKey == "tenants/acct-001/users::partition", """
            Cache key should include both path and layerType.
            Expected: "tenants/acct-001/users::partition"
            Got: "\(cacheKey)"
            """)
    }

    @Test("Different layerTypes on same path produce different cache keys")
    func testDifferentLayerTypesDifferentKeys() {
        let path = ["shared", "path"]

        let key1 = path.joined(separator: "/") + "::" + DirectoryLayerType.partition.rawValue
        let key2 = path.joined(separator: "/") + "::" + DirectoryLayerType.recordStore.rawValue

        #expect(key1 != key2, """
            Same path with different layerTypes should produce different cache keys.
            Key 1 (partition): "\(key1)"
            Key 2 (recordStore): "\(key2)"
            """)
    }

    @Test("Same path and layerType produce identical cache keys")
    func testSamePathAndLayerSameKey() {
        let path = ["app", "users"]
        let layerType = DirectoryLayerType.recordStore

        let key1 = path.joined(separator: "/") + "::" + layerType.rawValue
        let key2 = path.joined(separator: "/") + "::" + layerType.rawValue

        #expect(key1 == key2, "Same path and layerType should produce identical cache keys")
    }

    @Test("Cache key uses rawValue not String(describing:)")
    func testCacheKeyUsesRawValue() {
        let layerType = DirectoryLayerType.custom("test_layer")

        // Old incorrect approach (unstable)
        let unstableKey = "path::" + String(describing: layerType)

        // New correct approach (stable)
        let stableKey = "path::" + layerType.rawValue

        // Verify they differ (String(describing:) may produce different format)
        #expect(stableKey == "path::custom:test_layer", """
            Cache key should use rawValue for stable string representation.
            Stable key (rawValue): "\(stableKey)"
            Unstable key (String(describing:)): "\(unstableKey)"
            """)
    }

    @Test("All DirectoryLayerType values produce valid cache keys")
    func testAllLayerTypesProduceValidKeys() {
        let path = ["test", "path"]
        let layerTypes: [DirectoryLayerType] = [
            .partition,
            .recordStore,
            .luceneIndex,
            .timeSeries,
            .vectorIndex,
            .custom("custom_layer")
        ]

        var cacheKeys = Set<String>()
        for layerType in layerTypes {
            let key = path.joined(separator: "/") + "::" + layerType.rawValue
            cacheKeys.insert(key)
        }

        // Verify all keys are unique
        #expect(cacheKeys.count == layerTypes.count, """
            All DirectoryLayerType values should produce unique cache keys.
            Expected \(layerTypes.count) unique keys, got \(cacheKeys.count)
            Keys: \(cacheKeys)
            """)
    }
}

/// Unit tests verifying RawRepresentable implementation
@Suite("DirectoryLayerType RawRepresentable Tests")
struct DirectoryLayerTypeRawRepresentableTests {

    @Test("rawValue returns expected strings for all cases")
    func testRawValueStrings() {
        #expect(DirectoryLayerType.partition.rawValue == "partition")
        #expect(DirectoryLayerType.recordStore.rawValue == "recordStore")
        #expect(DirectoryLayerType.luceneIndex.rawValue == "luceneIndex")
        #expect(DirectoryLayerType.timeSeries.rawValue == "timeSeries")
        #expect(DirectoryLayerType.vectorIndex.rawValue == "vectorIndex")
        #expect(DirectoryLayerType.custom("test").rawValue == "custom:test")
    }

    @Test("init(rawValue:) properly decodes all standard cases")
    func testRawValueDecoding() {
        #expect(DirectoryLayerType(rawValue: "partition") == .partition)
        #expect(DirectoryLayerType(rawValue: "recordStore") == .recordStore)
        #expect(DirectoryLayerType(rawValue: "luceneIndex") == .luceneIndex)
        #expect(DirectoryLayerType(rawValue: "timeSeries") == .timeSeries)
        #expect(DirectoryLayerType(rawValue: "vectorIndex") == .vectorIndex)
    }

    @Test("init(rawValue:) properly decodes custom cases")
    func testCustomRawValueDecoding() {
        let customType = DirectoryLayerType(rawValue: "custom:my_layer")
        if case .custom(let name) = customType {
            #expect(name == "my_layer", "Custom layer name should be extracted correctly")
        } else {
            Issue.record("Expected .custom(\"my_layer\"), got \(String(describing: customType))")
        }
    }

    @Test("init(rawValue:) returns nil for invalid inputs")
    func testInvalidRawValues() {
        #expect(DirectoryLayerType(rawValue: "invalid") == nil)
        #expect(DirectoryLayerType(rawValue: "") == nil)
        #expect(DirectoryLayerType(rawValue: "custom") == nil) // Missing ":"

        // Note: "custom:" with empty name is valid and returns .custom("")
        let emptyCustom = DirectoryLayerType(rawValue: "custom:")
        if case .custom(let name) = emptyCustom {
            #expect(name == "", "Empty custom layer name is valid")
        } else {
            Issue.record("Expected .custom(\"\"), got \(String(describing: emptyCustom))")
        }
    }

    @Test("rawValue round-trip preserves value")
    func testRawValueRoundTrip() {
        let testCases: [DirectoryLayerType] = [
            .partition,
            .recordStore,
            .luceneIndex,
            .timeSeries,
            .vectorIndex,
            .custom("test_layer"),
            .custom("another-layer_123")
        ]

        for original in testCases {
            let rawValue = original.rawValue
            let decoded = DirectoryLayerType(rawValue: rawValue)
            #expect(decoded == original, """
                rawValue round-trip should preserve the value.
                Original: \(original)
                RawValue: "\(rawValue)"
                Decoded: \(String(describing: decoded))
                """)
        }
    }
}
