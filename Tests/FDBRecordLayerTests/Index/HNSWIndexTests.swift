import Foundation
import Testing
@testable import FDBRecordCore
@testable import FDBRecordLayer

@Suite("HNSW Index Tests")
struct HNSWIndexTests {
    // MARK: - Basic HNSW Data Structures

    @Test("HNSWNodeMetadata encoding/decoding")
    func testHNSWNodeMetadata() throws {
        let metadata = HNSWNodeMetadata(level: 3)

        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HNSWNodeMetadata.self, from: data)

        #expect(decoded.level == 3)
    }

    @Test("HNSWParameters default values")
    func testHNSWParameters() {
        let params = HNSWParameters()

        #expect(params.M == 16)
        #expect(params.efConstruction == 100)
        #expect(params.ml > 0.35 && params.ml < 0.37)  // ml ≈ 1/ln(16) ≈ 0.36
        #expect(params.M_max0 == 32)  // M * 2
        #expect(params.M_max == 16)
    }

    @Test("HNSWParameters custom values")
    func testHNSWParametersCustom() {
        let params = HNSWParameters(M: 8, efConstruction: 50)

        #expect(params.M == 8)
        #expect(params.efConstruction == 50)
        #expect(params.M_max0 == 16)  // M * 2
        #expect(params.M_max == 8)
    }

    @Test("HNSWSearchParameters")
    func testHNSWSearchParameters() {
        let params = HNSWSearchParameters(ef: 100)
        #expect(params.ef == 100)

        let defaultParams = HNSWSearchParameters()
        #expect(defaultParams.ef == 50)
    }

    // Note: Integration tests with FDB cluster are in separate integration test suite
}
