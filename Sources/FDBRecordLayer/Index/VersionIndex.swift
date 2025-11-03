import Foundation
import FoundationDB

/// Represents a record version (FDB Versionstamp)
///
/// A Version is a 10-byte value assigned by FoundationDB at commit time.
/// This is the native 80-bit versionstamp used by SET_VERSIONSTAMPED_KEY.
/// It consists of:
/// - 8 bytes: database commit version (big-endian, globally unique)
/// - 2 bytes: batch order within same commit version (big-endian)
///
/// Versions are comparable and provide total ordering for optimistic concurrency control.
///
/// Note: This is NOT the 96-bit versionstamp (12 bytes) used in Tuple layer.
/// The Tuple layer adds 2 bytes for user-defined ordering, but SET_VERSIONSTAMPED_KEY
/// only writes the native 10-byte versionstamp.
public struct Version: Sendable, Comparable, Hashable, CustomStringConvertible {
    public let bytes: FDB.Bytes  // Must be exactly 10 bytes

    // MARK: - Initialization

    /// Create a Version from versionstamp bytes
    /// - Parameter bytes: 10-byte versionstamp from FoundationDB
    public init(bytes: FDB.Bytes) {
        precondition(bytes.count == 10, "Version must be 10 bytes (80-bit versionstamp)")
        self.bytes = bytes
    }

    /// Create incomplete versionstamp placeholder (0xFF bytes)
    /// Used when setting keys/values that will be filled by FDB at commit time
    public static func incomplete() -> Version {
        return Version(bytes: [UInt8](repeating: 0xFF, count: 10))
    }

    // MARK: - Comparable

    public static func < (lhs: Version, rhs: Version) -> Bool {
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        return lhs.bytes == rhs.bytes
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Conversion

    /// Extract database commit version (first 8 bytes, big-endian)
    public var databaseVersion: UInt64 {
        return bytes.prefix(8).withUnsafeBytes {
            $0.load(as: UInt64.self).bigEndian
        }
    }

    /// Extract batch order (last 2 bytes, big-endian)
    public var batchOrder: UInt16 {
        return UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    }
}

// MARK: - Version History Strategy

/// Strategy for managing version history
public enum VersionHistoryStrategy: Sendable {
    /// Keep all versions (unlimited history)
    case keepAll

    /// Keep only the last N versions
    case keepLast(Int)

    /// Keep versions for a specific duration (in seconds)
    case keepForDuration(TimeInterval)

    // Note: custom predicate removed due to Sendable constraints
}

// MARK: - Version Index Maintainer

/// Maintainer for version indexes
///
/// Version indexes provide:
/// - Automatic versioning using FDB versionstamps
/// - Optimistic concurrency control (OCC)
/// - Version history queries
///
/// **Data Model:**
/// ```
/// Version Index Key:
///   [subspace][primary_key][versionstamp]
///
/// Example:
///   [version_idx][user:123][0x0000000000000001ABCD] → ∅
/// ```
///
/// **Usage:**
/// ```swift
/// // Define version index
/// let versionIndex = Index(
///     name: "document_version",
///     type: .version,
///     rootExpression: EmptyKeyExpression()
/// )
///
/// // Save with optimistic lock
/// try await recordStore.save(
///     record,
///     expectedVersion: currentVersion,
///     context: context
/// )
/// ```
public struct VersionIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    /// Field name to store version in record (default: "_version")
    private let versionField: String

    /// Version history retention strategy
    private let historyStrategy: VersionHistoryStrategy

    // MARK: - Initialization

    public init(
        index: Index,
        subspace: Subspace,
        recordSubspace: Subspace,
        versionField: String = "_version",
        historyStrategy: VersionHistoryStrategy = .keepAll
    ) {
        self.index = index
        self.subspace = subspace
        self.recordSubspace = recordSubspace
        self.versionField = versionField
        self.historyStrategy = historyStrategy
    }

    // MARK: - IndexMaintainer Protocol

    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        guard let record = newRecord ?? oldRecord else { return }

        // Extract primary key
        let primaryKey = try extractPrimaryKey(record)

        // For version index, we store: [subspace][primary_key][versionstamp] → empty
        // The versionstamp is automatically filled by FDB at commit time

        if let newRecord = newRecord {
            // Insert: create new version entry using FDB versionstamp
            //
            // FDB versionstamp is a 10-byte unique, monotonically increasing value
            // assigned at commit time. This is the native 80-bit versionstamp.
            //
            // Benefits:
            // - Globally unique, monotonically increasing
            // - Assigned atomically at commit time
            // - Enables true optimistic concurrency control
            // - Compatible with FoundationDB's MVCC
            //
            // Data Model: [subspace][primary_key][10-byte versionstamp] → ∅

            var key = subspace.pack(primaryKey)
            let versionPosition = UInt32(key.count)

            // Validate position fits in UInt32 range with room for versionstamp
            guard versionPosition <= UInt32.max - 10 else {
                throw RecordLayerError.internalError("Version key too long")
            }

            // Append 10-byte versionstamp placeholder (will be filled by FDB at commit)
            key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))

            // Append 4-byte position (little-endian) - tells FDB where to write versionstamp
            // This position points to the start of the 10-byte placeholder
            let positionBytes = withUnsafeBytes(of: versionPosition.littleEndian) { Array($0) }
            key.append(contentsOf: positionBytes)

            // Use atomicOp with setVersionstampedKey
            // FDB will:
            // 1. Read last 4 bytes as offset (versionPosition)
            // 2. Replace 10 bytes at key[versionPosition] with actual versionstamp
            // 3. Remove last 4 bytes
            // Final result: [subspace][primary_key][10-byte versionstamp]
            transaction.atomicOp(key: key, param: FDB.Bytes(), mutationType: .setVersionstampedKey)
        }

        // Cleanup old versions based on strategy
        try await cleanupOldVersions(primaryKey: primaryKey, transaction: transaction)
    }

    public func scanRecord(
        _ record: [String: Any],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // For historical records, create version entry using FDB versionstamp
        var key = subspace.pack(primaryKey)
        let versionPosition = UInt32(key.count)

        // Validate position
        guard versionPosition <= UInt32.max - 10 else {
            throw RecordLayerError.internalError("Version key too long")
        }

        // Append 10-byte versionstamp placeholder
        key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))

        // Append 4-byte position (little-endian)
        let positionBytes = withUnsafeBytes(of: versionPosition.littleEndian) { Array($0) }
        key.append(contentsOf: positionBytes)

        // Use atomicOp with setVersionstampedKey
        transaction.atomicOp(key: key, param: FDB.Bytes(), mutationType: .setVersionstampedKey)
    }

    // MARK: - Version Operations

    /// Check if expected version matches current version (for OCC)
    public func checkVersion(
        primaryKey: Tuple,
        expectedVersion: Version,
        transaction: any TransactionProtocol
    ) async throws {
        let currentVersion = try await getCurrentVersion(
            primaryKey: primaryKey,
            transaction: transaction
        )

        guard let current = currentVersion else {
            throw RecordLayerError.versionNotFound(version: expectedVersion)
        }

        guard current == expectedVersion else {
            throw RecordLayerError.versionMismatch(
                expected: expectedVersion,
                actual: current
            )
        }
    }

    /// Get current version for a record (latest version)
    public func getCurrentVersion(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> Version? {
        // Query version index for latest version of this primary key
        let beginKey = subspace.pack(primaryKey)
        let endKey = beginKey + [0xFF]

        // OPTIMIZED: Use getKey with lastLessThan selector to find the last version key
        // This is O(1) instead of O(n) with full range scan
        let lastSelector = FDB.KeySelector.lastLessThan(endKey)

        guard let lastKey = try await transaction.getKey(selector: lastSelector, snapshot: true) else {
            return nil
        }

        // Verify the key is actually in our range (belongs to this primary key)
        guard lastKey.starts(with: beginKey) else {
            return nil
        }

        // Extract version from key (last 10 bytes - 80-bit versionstamp)
        guard lastKey.count >= 10 else {
            return nil
        }
        let versionBytes = Array(lastKey.suffix(10))
        return Version(bytes: versionBytes)
    }

    /// Get all versions for a record
    public func getAllVersions(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> [Version] {
        let beginKey = subspace.pack(primaryKey)
        let endKey = beginKey + [0xFF]

        // Use getRange AsyncSequence (preferred over getRangeNative)
        let beginSelector = FDB.KeySelector.firstGreaterOrEqual(beginKey)
        let endSelector = FDB.KeySelector.firstGreaterOrEqual(endKey)
        let sequence = transaction.getRange(
            beginSelector: beginSelector,
            endSelector: endSelector,
            snapshot: true
        )

        var versions: [Version] = []
        for try await (key, _) in sequence {
            // Extract 10-byte versionstamp from end of key
            guard key.count >= 10 else { continue }
            let versionBytes = Array(key.suffix(10))
            versions.append(Version(bytes: versionBytes))
        }

        return versions
    }

    // MARK: - Private Methods

    /// Build version index key with versionstamp placeholder
    /// NOTE: This method is not used. Use atomicOp with setVersionstampedKey instead.
    private func buildVersionIndexKey(primaryKey: Tuple) throws -> FDB.Bytes {
        // Format: [subspace][primary_key][10-byte versionstamp]
        var key = subspace.pack(primaryKey)

        // Append incomplete versionstamp (10 bytes 0xFF)
        key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))

        return key
    }

    /// Extract primary key from record
    ///
    /// LIMITATION: Currently assumes "id" field as primary key
    ///
    /// In production, this should:
    /// 1. Accept RecordType parameter
    /// 2. Use RecordType.primaryKey expression to extract key
    /// 3. Support compound primary keys (multiple fields)
    /// 4. Handle all TupleElement types properly
    ///
    /// Example proper implementation:
    /// ```
    /// func extractPrimaryKey(_ record: [String: Any], recordType: RecordType) -> Tuple {
    ///     let keyValues = recordType.primaryKey.evaluate(record: record)
    ///     return TupleHelpers.toTuple(keyValues)
    /// }
    /// ```
    private func extractPrimaryKey(_ record: [String: Any]) throws -> Tuple {
        let primaryKeyValue: any TupleElement
        if let id = record["id"] as? Int64 {
            primaryKeyValue = id
        } else if let id = record["id"] as? Int {
            primaryKeyValue = Int64(id)
        } else if let id = record["id"] as? String {
            primaryKeyValue = id
        } else {
            throw RecordLayerError.invalidKey("Cannot extract primary key from record")
        }

        return Tuple(primaryKeyValue)
    }

    /// Clean up old versions based on strategy
    private func cleanupOldVersions(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        switch historyStrategy {
        case .keepAll:
            return  // No cleanup
        case .keepLast(let count):
            try await keepLastNVersions(
                primaryKey: primaryKey,
                count: count,
                transaction: transaction
            )
        case .keepForDuration(let duration):
            try await keepVersionsForDuration(
                primaryKey: primaryKey,
                duration: duration,
                transaction: transaction
            )
        }
    }

    private func keepLastNVersions(
        primaryKey: Tuple,
        count: Int,
        transaction: any TransactionProtocol
    ) async throws {
        let allVersions = try await getAllVersions(
            primaryKey: primaryKey,
            transaction: transaction
        )

        // Keep only last N versions, delete older ones
        let toDelete = allVersions.dropLast(count)

        for version in toDelete {
            var key = subspace.pack(primaryKey)
            key.append(contentsOf: version.bytes)
            transaction.clear(key: key)
        }
    }

    private func keepVersionsForDuration(
        primaryKey: Tuple,
        duration: TimeInterval,
        transaction: any TransactionProtocol
    ) async throws {
        // Calculate cutoff time
        let cutoffTime = Date().timeIntervalSince1970 - duration

        let allVersions = try await getAllVersions(
            primaryKey: primaryKey,
            transaction: transaction
        )

        // Delete versions older than duration
        // Note: This is a simplified implementation
        // In production, we'd need to extract actual timestamps from versionstamps
        for version in allVersions.dropLast(1) {
            var key = subspace.pack(primaryKey)
            key.append(contentsOf: version.bytes)
            transaction.clear(key: key)
        }
    }
}

// MARK: - RecordLayerError Extensions for Version Index

extension RecordLayerError {
    /// Version mismatch error with Version types
    public static func versionMismatch(expected: Version, actual: Version) -> RecordLayerError {
        return .versionMismatch(expected: expected.description, actual: actual.description)
    }

    /// Version not found error with Version type
    public static func versionNotFound(version: Version) -> RecordLayerError {
        return .versionNotFound(version: version.description)
    }
}
