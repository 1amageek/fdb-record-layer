import Foundation
import FoundationDB

/// Type-erased wrapper for GenericIndexMaintainer
///
/// AnyGenericIndexMaintainer provides a type-erased interface to store
/// different GenericIndexMaintainer implementations in a collection.
///
/// This is necessary because GenericIndexMaintainer is a generic protocol
/// with an associated type, which prevents direct use in collections.
///
/// **Usage:**
/// ```swift
/// let versionMaintainer = VersionIndexMaintainer<User>(...)
/// let valueMaintainer = ValueIndexMaintainer<User>(...)
///
/// let maintainers: [AnyGenericIndexMaintainer<User>] = [
///     AnyGenericIndexMaintainer(versionMaintainer),
///     AnyGenericIndexMaintainer(valueMaintainer)
/// ]
///
/// for maintainer in maintainers {
///     try await maintainer.updateIndex(
///         oldRecord: oldUser,
///         newRecord: newUser,
///         recordAccess: userAccess,
///         transaction: transaction
///     )
/// }
/// ```
public struct AnyGenericIndexMaintainer<Record: Sendable>: Sendable {
    private let _updateIndex: @Sendable (Record?, Record?, any RecordAccess<Record>, any TransactionProtocol) async throws -> Void
    private let _scanRecord: @Sendable (Record, Tuple, any RecordAccess<Record>, any TransactionProtocol) async throws -> Void

    /// Create a type-erased wrapper for a GenericIndexMaintainer
    ///
    /// - Parameter maintainer: The concrete GenericIndexMaintainer to wrap
    public init<M: GenericIndexMaintainer>(_ maintainer: M) where M.Record == Record {
        // Capture the maintainer's methods
        self._updateIndex = { oldRecord, newRecord, recordAccess, transaction in
            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: newRecord,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }

        self._scanRecord = { record, primaryKey, recordAccess, transaction in
            try await maintainer.scanRecord(
                record,
                primaryKey: primaryKey,
                recordAccess: recordAccess,
                transaction: transaction
            )
        }
    }

    /// Update index entries when a record changes
    ///
    /// - Parameters:
    ///   - oldRecord: The old record (nil if inserting)
    ///   - newRecord: The new record (nil if deleting)
    ///   - recordAccess: RecordAccess for extracting field values
    ///   - transaction: The transaction to use
    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        try await _updateIndex(oldRecord, newRecord, recordAccess, transaction)
    }

    /// Scan and build index entries for a record
    ///
    /// - Parameters:
    ///   - record: The record to scan
    ///   - primaryKey: The record's primary key
    ///   - recordAccess: RecordAccess for extracting field values
    ///   - transaction: The transaction to use
    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        try await _scanRecord(record, primaryKey, recordAccess, transaction)
    }
}
