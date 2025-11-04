import Foundation
import FoundationDB

/// Protocol for maintaining an index (Generic version)
///
/// GenericIndexMaintainer is the new generic version that works with
/// RecordAccess instead of assuming dictionary-based records.
///
/// This replaces the old IndexMaintainer protocol for new code.
public protocol GenericIndexMaintainer<Record>: Sendable {
    associatedtype Record: Sendable

    /// Update index entries when a record changes
    /// - Parameters:
    ///   - oldRecord: The old record (nil if inserting)
    ///   - newRecord: The new record (nil if deleting)
    ///   - recordAccess: RecordAccess for extracting field values
    ///   - transaction: The transaction to use
    func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws

    /// Scan and build index entries for a record
    /// - Parameters:
    ///   - record: The record to scan
    ///   - primaryKey: The record's primary key
    ///   - recordAccess: RecordAccess for extracting field values
    ///   - transaction: The transaction to use
    func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws
}
