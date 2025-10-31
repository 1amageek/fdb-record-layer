import Foundation
import FoundationDB

/// Represents a record version (FDB Versionstamp)
///
/// A Version is a 12-byte value assigned by FoundationDB at commit time.
/// It consists of:
/// - 10 bytes: transaction version (globally unique, monotonically increasing)
/// - 2 bytes: batch order (for operations within same transaction)
///
/// Versions are comparable and provide total ordering for optimistic concurrency control.
public struct Version: Sendable, Comparable, Hashable, CustomStringConvertible {
    public let bytes: FDB.Bytes  // Must be exactly 12 bytes

    // MARK: - Initialization

    /// Create a Version from versionstamp bytes
    /// - Parameter bytes: 12-byte versionstamp from FoundationDB
    public init(bytes: FDB.Bytes) {
        precondition(bytes.count == 12, "Version must be 12 bytes (versionstamp)")
        self.bytes = bytes
    }

    /// Create incomplete versionstamp placeholder (0xFF bytes)
    /// Used when setting keys/values that will be filled by FDB at commit time
    public static func incomplete() -> Version {
        return Version(bytes: [UInt8](repeating: 0xFF, count: 10) + [0x00, 0x00])
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

    /// Extract transaction version (first 10 bytes)
    public var transactionVersion: FDB.Bytes {
        return Array(bytes.prefix(10))
    }

    /// Extract batch order (last 2 bytes)
    public var batchOrder: UInt16 {
        return UInt16(bytes[10]) << 8 | UInt16(bytes[11])
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
            // Insert: create new version entry

            // LIMITATION: This implementation uses timestamp instead of true FDB versionstamp
            //
            // For production use, this should use:
            //   transaction.setVersionstampedKey(versionKey, value: FDB.Bytes())
            //
            // Current timestamp approach limitations:
            // - No global monotonic ordering guarantee
            // - Possible timestamp collisions in distributed systems
            // - Not atomic with transaction commit
            // - Cannot support true optimistic concurrency control
            //
            // True versionstamp benefits:
            // - Globally unique, monotonically increasing
            // - Assigned atomically at commit time
            // - Enables conflict-free concurrent updates
            // - Compatible with FoundationDB's MVCC

            let timestamp = Date().timeIntervalSince1970
            let timestampBytes = withUnsafeBytes(of: timestamp) { Array($0) }
            var keyWithTimestamp = subspace.pack(primaryKey)
            keyWithTimestamp.append(contentsOf: timestampBytes)
            transaction.setValue(FDB.Bytes(), for: keyWithTimestamp)
        }

        // Cleanup old versions based on strategy
        try await cleanupOldVersions(primaryKey: primaryKey, transaction: transaction)
    }

    public func scanRecord(
        _ record: [String: Any],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // For historical records, create version entry
        // Use timestamp as version placeholder
        let timestamp = Date().timeIntervalSince1970
        let timestampBytes = withUnsafeBytes(of: timestamp) { Array($0) }
        var keyWithTimestamp = subspace.pack(primaryKey)
        keyWithTimestamp.append(contentsOf: timestampBytes)
        transaction.setValue(FDB.Bytes(), for: keyWithTimestamp)
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
        let pkBytes = primaryKey.encode()
        let beginKey = subspace.pack(primaryKey)

        // Get the last version (reverse scan with limit 1)
        let endKey = beginKey + [0xFF]

        let result = try await transaction.getRangeNative(
            beginKey: beginKey,
            endKey: endKey,
            limit: 1,
            snapshot: true
        )

        guard let (key, _) = result.records.last else {
            return nil
        }

        // Extract version from key
        let versionBytes = Array(key.suffix(12))
        return Version(bytes: versionBytes)
    }

    /// Get all versions for a record
    public func getAllVersions(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> [Version] {
        let beginKey = subspace.pack(primaryKey)
        let endKey = beginKey + [0xFF]

        let result = try await transaction.getRangeNative(
            beginKey: beginKey,
            endKey: endKey,
            limit: 0,
            snapshot: true
        )

        return result.records.compactMap { (key, _) in
            guard key.count >= 12 else { return nil }
            let versionBytes = Array(key.suffix(12))
            return Version(bytes: versionBytes)
        }
    }

    // MARK: - Private Methods

    /// Build version index key with versionstamp placeholder
    private func buildVersionIndexKey(primaryKey: Tuple) throws -> FDB.Bytes {
        // Format: [subspace][primary_key][versionstamp_placeholder]
        var key = subspace.pack(primaryKey)

        // Append incomplete versionstamp (10 bytes 0xFF + 2 bytes position)
        // In real implementation, this would be used with setVersionstampedKey
        key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))
        key.append(contentsOf: [0x00, 0x00])  // Batch order

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
