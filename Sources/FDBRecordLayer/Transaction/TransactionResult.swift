import Foundation
import FoundationDB

/// Protocol for types that can be returned from transaction blocks
///
/// TransactionResult provides a type-safe way to prevent TransactionCursor
/// from being returned from transaction blocks, which would cause runtime errors
/// since the transaction is already committed outside the block.
///
/// **Design:**
/// - Basic types and collections conform to TransactionResult
/// - TransactionCursor does NOT conform
/// - Attempting to return a TransactionCursor causes a compile-time error
///
/// **Usage:**
/// ```swift
/// // OK: OK: Array conforms to TransactionResult
/// let users = try await context.transaction { transaction in
///     let cursor = try await transaction.fetch(query)
///     return try await cursor.collect(limit: 100)
/// }
///
/// // ERROR: Compile error: TransactionCursor does not conform to TransactionResult
/// let cursor = try await context.transaction { transaction in
///     return try await transaction.fetch(query)
/// }
/// ```
public protocol TransactionResult: Sendable {}

// MARK: - Basic Types

extension Int: TransactionResult {}
extension Int8: TransactionResult {}
extension Int16: TransactionResult {}
extension Int32: TransactionResult {}
extension Int64: TransactionResult {}
extension UInt: TransactionResult {}
extension UInt8: TransactionResult {}
extension UInt16: TransactionResult {}
extension UInt32: TransactionResult {}
extension UInt64: TransactionResult {}
extension Float: TransactionResult {}
extension Double: TransactionResult {}
extension String: TransactionResult {}
extension Bool: TransactionResult {}
extension Data: TransactionResult {}

// MARK: - Collections

// Note: TransactionResult inherits from Sendable, so we don't need additional constraints
extension Array: TransactionResult {}
extension Dictionary: TransactionResult {}
extension Set: TransactionResult {}

// MARK: - Optional

extension Optional: TransactionResult where Wrapped: TransactionResult {}

// MARK: - Void (Empty Tuple)

// Note: In Swift 6, we cannot extend Void directly
// But Void is an empty tuple (), so returning nothing from transaction works fine

// MARK: - FDB Tuple

extension FoundationDB.Tuple: TransactionResult {}
