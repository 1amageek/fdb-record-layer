import Foundation
import FoundationDB

/// Protocol for maintaining an index
///
/// IndexMaintainer implementations handle the logic for updating index entries
/// when records are inserted, updated, or deleted.
public protocol IndexMaintainer: Sendable {
    /// Update index entries when a record changes
    /// - Parameters:
    ///   - oldRecord: The old record (nil if inserting)
    ///   - newRecord: The new record (nil if deleting)
    ///   - transaction: The transaction to use
    func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws

    /// Scan and build index entries for a record
    /// - Parameters:
    ///   - record: The record to scan
    ///   - primaryKey: The record's primary key
    ///   - transaction: The transaction to use
    func scanRecord(
        _ record: [String: Any],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws
}
