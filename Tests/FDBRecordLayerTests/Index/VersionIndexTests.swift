import Foundation
import Testing
import FoundationDB
@testable import FDBRecordLayer

/// Tests for Version Index functionality
@Suite("Version Index Tests")
struct VersionIndexTests {

    // MARK: - Version Struct Tests

    @Test("Version initialization with valid bytes")
    func testVersionInitialization() throws {
        let bytes: FDB.Bytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C]
        let version = Version(bytes: bytes)

        #expect(version.bytes == bytes)
        #expect(version.bytes.count == 12)
    }

    @Test("Version incomplete placeholder")
    func testIncompleteVersion() {
        let version = Version.incomplete()

        #expect(version.bytes.count == 12)
        #expect(version.bytes.prefix(10).allSatisfy { $0 == 0xFF })
        #expect(version.bytes[10] == 0x00)
        #expect(version.bytes[11] == 0x00)
    }

    @Test("Version transaction version extraction")
    func testTransactionVersion() {
        let bytes: FDB.Bytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C]
        let version = Version(bytes: bytes)

        let txnVersion = version.transactionVersion
        #expect(txnVersion.count == 10)
        #expect(txnVersion == [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A])
    }

    @Test("Version batch order extraction")
    func testBatchOrder() {
        let bytes: FDB.Bytes = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x23]
        let version = Version(bytes: bytes)

        let batchOrder = version.batchOrder
        // 0x01 << 8 | 0x23 = 0x0123 = 291
        #expect(batchOrder == 291)
    }

    @Test("Version comparison")
    func testVersionComparison() {
        let version1 = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let version2 = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
        let version3 = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])

        #expect(version1 < version2)
        #expect(version1 == version3)
        #expect(version2 > version1)
    }

    @Test("Version hashable")
    func testVersionHashable() {
        let version1 = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let version2 = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])

        var set: Set<Version> = []
        set.insert(version1)
        set.insert(version2)

        #expect(set.count == 1)
    }

    @Test("Version description")
    func testVersionDescription() {
        let bytes: FDB.Bytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C]
        let version = Version(bytes: bytes)

        #expect(version.description == "0102030405060708090a0b0c")
    }

    // MARK: - VersionHistoryStrategy Tests

    @Test("VersionHistoryStrategy keepAll")
    func testKeepAllStrategy() {
        let strategy = VersionHistoryStrategy.keepAll

        switch strategy {
        case .keepAll:
            #expect(true)
        default:
            Issue.record("Expected keepAll strategy")
        }
    }

    @Test("VersionHistoryStrategy keepLast")
    func testKeepLastStrategy() {
        let strategy = VersionHistoryStrategy.keepLast(10)

        switch strategy {
        case .keepLast(let count):
            #expect(count == 10)
        default:
            Issue.record("Expected keepLast strategy")
        }
    }

    @Test("VersionHistoryStrategy keepForDuration")
    func testKeepForDurationStrategy() {
        let strategy = VersionHistoryStrategy.keepForDuration(3600.0)

        switch strategy {
        case .keepForDuration(let duration):
            #expect(duration == 3600.0)
        default:
            Issue.record("Expected keepForDuration strategy")
        }
    }

    // MARK: - VersionIndexMaintainer Tests

    @Test("VersionIndexMaintainer initialization")
    func testVersionIndexMaintainerInit() throws {
        let index = Index(
            name: "test_version",
            type: IndexType.version,
            rootExpression: EmptyKeyExpression()
        )

        let subspace = Subspace(prefix: Tuple("test").encode())
        let recordSubspace = Subspace(prefix: Tuple("records").encode())

        let maintainer = VersionIndexMaintainer(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace
        )

        #expect(maintainer.index.name == "test_version")
        #expect(maintainer.index.type == IndexType.version)
    }

    @Test("VersionIndexMaintainer with custom version field")
    func testVersionIndexMaintainerCustomField() {
        let index = Index(
            name: "test_version",
            type: IndexType.version,
            rootExpression: EmptyKeyExpression()
        )

        let subspace = Subspace(prefix: Tuple("test").encode())
        let recordSubspace = Subspace(prefix: Tuple("records").encode())

        let maintainer = VersionIndexMaintainer(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace,
            versionField: "custom_version"
        )

        #expect(maintainer.index.name == "test_version")
    }

    @Test("VersionIndexMaintainer with history strategy")
    func testVersionIndexMaintainerWithStrategy() {
        let index = Index(
            name: "test_version",
            type: IndexType.version,
            rootExpression: EmptyKeyExpression()
        )

        let subspace = Subspace(prefix: Tuple("test").encode())
        let recordSubspace = Subspace(prefix: Tuple("records").encode())

        let maintainer = VersionIndexMaintainer(
            index: index,
            subspace: subspace,
            recordSubspace: recordSubspace,
            historyStrategy: .keepLast(5)
        )

        #expect(maintainer.index.name == "test_version")
    }

    // MARK: - Error Tests

    @Test("RecordLayerError versionMismatch")
    func testVersionMismatchError() {
        let version1 = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let version2 = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])

        let error = RecordLayerError.versionMismatch(expected: version1, actual: version2)

        switch error {
        case .versionMismatch(let expected, let actual):
            #expect(expected.contains("01"))
            #expect(actual.contains("02"))
        default:
            Issue.record("Expected versionMismatch error")
        }
    }

    @Test("RecordLayerError versionNotFound")
    func testVersionNotFoundError() {
        let version = Version(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])

        let error = RecordLayerError.versionNotFound(version: version)

        switch error {
        case .versionNotFound(let versionStr):
            #expect(versionStr.contains("01"))
        default:
            Issue.record("Expected versionNotFound error")
        }
    }
}
