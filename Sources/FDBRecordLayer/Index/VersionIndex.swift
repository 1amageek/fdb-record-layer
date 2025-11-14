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
/// This is the new generic version that works with any record type
/// through RecordAccess instead of assuming dictionary-based records.
///
/// **Usage:**
/// ```swift
/// let maintainer = VersionIndexMaintainer(
///     index: versionIndex,
///     recordType: userType,
///     subspace: versionSubspace,
///     recordSubspace: recordSubspace
/// )
/// ```
public struct VersionIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
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

    // MARK: - GenericIndexMaintainer Protocol

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        guard let record = newRecord ?? oldRecord else { return }

        // Extract primary key using Recordable protocol
        let primaryKey: Tuple
        if let recordableRecord = record as? any Recordable {
            primaryKey = recordableRecord.extractPrimaryKey()
        } else {
            // Fallback: this shouldn't happen if Record conforms to Sendable properly
            throw RecordLayerError.internalError("Record does not conform to Recordable")
        }

        if let _ = newRecord {
            // INSERT/UPDATE: create new version entry using FDB versionstamp
            var key = subspace.pack(primaryKey)
            let versionPosition = key.count

            // Validate position fits in UInt32 range (FDB requires 4-byte offset)
            // SET_VERSIONSTAMPED_KEY expects a 4-byte little-endian offset
            guard versionPosition <= Int(UInt32.max) - 10 else {
                throw RecordLayerError.internalError("Version key too long (max \(UInt32.max - 10) bytes)")
            }

            // Append 10-byte versionstamp placeholder
            key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))

            // Append 4-byte position (little-endian) as required by FDB
            let position32 = UInt32(versionPosition)
            let positionBytes = withUnsafeBytes(of: position32.littleEndian) { Array($0) }
            key.append(contentsOf: positionBytes)

            // Store current timestamp in value for time-based retention
            let timestamp = Date().timeIntervalSince1970
            let timestampBytes = withUnsafeBytes(of: timestamp.bitPattern) { Array($0) }

            // Use atomicOp with setVersionstampedKey
            // FDB will read the last 4 bytes as the offset, replace 10 bytes at that offset
            // with the versionstamp, and remove the last 4 bytes
            transaction.atomicOp(key: key, param: timestampBytes, mutationType: .setVersionstampedKey)

            // Cleanup old versions based on strategy
            try await cleanupOldVersions(primaryKey: primaryKey, transaction: transaction)
        } else if oldRecord != nil {
            // DELETE: remove all version entries for this record
            let allVersions = try await getAllVersions(
                primaryKey: primaryKey,
                transaction: transaction
            )

            for (version, _) in allVersions {
                var key = subspace.pack(primaryKey)
                key.append(contentsOf: version.bytes)
                transaction.clear(key: key)
            }
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // For historical records, create version entry using FDB versionstamp
        var key = subspace.pack(primaryKey)
        let versionPosition = key.count

        // Validate position fits in UInt16 range (FDB requires 2-byte offset)
        guard versionPosition <= Int(UInt16.max) - 10 else {
            throw RecordLayerError.internalError("Version key too long (max \(UInt16.max - 10) bytes)")
        }

        // Append 10-byte versionstamp placeholder
        key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))

        // Append 2-byte position (little-endian) as required by FDB
        let position16 = UInt16(versionPosition)
        let positionBytes = withUnsafeBytes(of: position16.littleEndian) { Array($0) }
        key.append(contentsOf: positionBytes)

        // Store current timestamp in value for time-based retention
        let timestamp = Date().timeIntervalSince1970
        let timestampBytes = withUnsafeBytes(of: timestamp.bitPattern) { Array($0) }

        // Use atomicOp with setVersionstampedKey
        transaction.atomicOp(key: key, param: timestampBytes, mutationType: .setVersionstampedKey)
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

        // OPTIMIZED: Use getKey with lastLessThan selector
        let lastSelector = FDB.KeySelector.lastLessThan(endKey)

        guard let lastKey = try await transaction.getKey(selector: lastSelector, snapshot: true) else {
            return nil
        }

        // Verify the key is in our range
        guard lastKey.starts(with: beginKey) else {
            return nil
        }

        // Extract version from key (last 10 bytes)
        guard lastKey.count >= 10 else {
            return nil
        }
        let versionBytes = Array(lastKey.suffix(10))
        return Version(bytes: versionBytes)
    }

    /// Get all versions for a record with timestamps
    public func getAllVersions(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> [(version: Version, timestamp: TimeInterval)] {
        let beginKey = subspace.pack(primaryKey)
        let endKey = beginKey + [0xFF]

        let beginSelector = FDB.KeySelector.firstGreaterOrEqual(beginKey)
        let endSelector = FDB.KeySelector.firstGreaterOrEqual(endKey)
        let sequence = transaction.getRange(
            beginSelector: beginSelector,
            endSelector: endSelector,
            snapshot: true
        )

        var versions: [(Version, TimeInterval)] = []
        for try await (key, value) in sequence {
            // Extract 10-byte versionstamp from end of key
            guard key.count >= 10 else { continue }
            let versionBytes = Array(key.suffix(10))
            let version = Version(bytes: versionBytes)

            // Extract timestamp from value (8 bytes for Double.bitPattern)
            let timestamp: TimeInterval
            if value.count >= 8 {
                let bitPattern = value.withUnsafeBytes { $0.load(as: UInt64.self) }
                timestamp = TimeInterval(bitPattern: bitPattern)
            } else {
                // Legacy entries without timestamps: use 0 (will be deleted by time-based retention)
                timestamp = 0
            }

            versions.append((version, timestamp))
        }

        return versions
    }

    // MARK: - Private Methods

    /// Extract primary key from record
    private func extractPrimaryKey<T: Recordable>(_ record: T) -> Tuple {
        // Use Recordable's extractPrimaryKey() method
        return record.extractPrimaryKey()
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

        for (version, _) in toDelete {
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

        // Delete versions older than duration, but always keep at least one version
        let versionsToDelete = allVersions.filter { $0.timestamp < cutoffTime }

        // If all versions are old, keep the most recent one
        let shouldKeepLast = versionsToDelete.count == allVersions.count
        let toDelete = shouldKeepLast ? versionsToDelete.dropLast() : versionsToDelete

        for (version, _) in toDelete {
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
