import Foundation
import FoundationDB

// MARK: - Permutation

/// Represents a permutation of index field ordering
///
/// A permutation defines an alternative ordering for a compound index.
/// For example, given a base index on (A, B, C):
/// - Permutation [0, 1, 2] maintains original order (A, B, C)
/// - Permutation [1, 0, 2] creates ordering (B, A, C)
/// - Permutation [2, 1, 0] creates ordering (C, B, A)
///
/// **Storage Optimization:**
/// Instead of storing duplicate data, permuted indexes reference the base index
/// and only store permuted keys pointing to the base index entry.
///
/// **Example:**
/// ```swift
/// // Base index: compound(["country", "city", "name"])
/// let baseIndex = Index(
///     name: "country_city_name",
///     type: .value,
///     rootExpression: CompoundKeyExpression(["country", "city", "name"])
/// )
///
/// // Permuted index: (city, country, name)
/// let permutedIndex = Index(
///     name: "city_country_name",
///     type: .permuted,
///     rootExpression: CompoundKeyExpression(["country", "city", "name"]),
///     options: IndexOptions(
///         baseIndexName: "country_city_name",
///         permutation: [1, 0, 2]
///     )
/// )
/// ```
public struct Permutation: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The permutation indices
    ///
    /// For a base index with N fields, this array must:
    /// - Contain exactly N elements
    /// - Contain all integers from 0 to N-1 exactly once
    public let indices: [Int]

    // MARK: - Initialization

    /// Create a permutation from indices
    /// - Parameter indices: The permutation indices (must be a valid permutation)
    /// - Throws: RecordLayerError.invalidPermutation if indices are invalid
    public init(indices: [Int]) throws {
        // Validate permutation
        guard !indices.isEmpty else {
            throw RecordLayerError.invalidPermutation("Permutation cannot be empty")
        }

        let sorted = indices.sorted()
        let expected = Array(0..<indices.count)

        guard sorted == expected else {
            throw RecordLayerError.invalidPermutation(
                "Permutation must contain all indices 0..<\(indices.count) exactly once. Got: \(indices)"
            )
        }

        self.indices = indices
    }

    /// Create identity permutation (no reordering)
    /// - Parameter size: Number of fields
    public static func identity(size: Int) -> Permutation {
        // identity permutation cannot fail validation
        return try! Permutation(indices: Array(0..<size))
    }

    // MARK: - Operations

    /// Apply this permutation to a list of elements
    /// - Parameter elements: The elements to permute
    /// - Returns: Permuted elements
    /// - Throws: RecordLayerError.invalidPermutation if element count doesn't match
    public func apply<T>(_ elements: [T]) throws -> [T] {
        guard elements.count == indices.count else {
            throw RecordLayerError.invalidPermutation(
                "Cannot apply permutation of size \(indices.count) to \(elements.count) elements"
            )
        }

        return indices.map { elements[$0] }
    }

    /// Inverse of this permutation
    ///
    /// If P is a permutation, then P.inverse().apply(P.apply(x)) == x
    public var inverse: Permutation {
        var inverseIndices = [Int](repeating: 0, count: indices.count)
        for (newPos, oldPos) in indices.enumerated() {
            inverseIndices[oldPos] = newPos
        }
        // inverse permutation is always valid
        return try! Permutation(indices: inverseIndices)
    }

    /// Check if this is the identity permutation
    public var isIdentity: Bool {
        return indices == Array(0..<indices.count)
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        return "[\(indices.map(String.init).joined(separator: ", "))]"
    }
}

// MARK: - Index Options Extension

extension IndexOptions {
    /// Get permutation from indices
    public var permutation: Permutation? {
        guard let indices = permutationIndices else {
            return nil
        }
        return try? Permutation(indices: indices)
    }

    /// Create IndexOptions for a permuted index
    /// - Parameters:
    ///   - baseIndexName: Name of the base index
    ///   - permutation: The permutation to apply
    /// - Returns: IndexOptions with permuted index configuration
    public static func permuted(
        baseIndexName: String,
        permutation: Permutation
    ) -> IndexOptions {
        return IndexOptions(
            baseIndexName: baseIndexName,
            permutationIndices: permutation.indices
        )
    }
}

// MARK: - Permuted Index Maintainer

/// Maintainer for permuted indexes
///
/// Permuted indexes provide multiple orderings of the same compound index
/// without duplicating the actual data.
///
/// **Data Model:**
/// ```
/// Base Index Key:
///   [base_subspace][field_0][field_1]...[field_n][primary_key] → ∅
///
/// Permuted Index Key:
///   [permuted_subspace][permuted_field_0][permuted_field_1]...[permuted_field_n][primary_key] → ∅
/// ```
///
/// The permuted index entry contains no data—it simply provides an alternative
/// sort order that points to the same primary keys.
///
/// **Storage Savings:**
/// If you need to query on multiple orderings of (A, B, C):
/// - Without permutation: 3 full indexes = 300% storage
/// - With permutation: 1 base + 2 permuted = ~140% storage (60% savings)
///
/// **Usage:**
/// ```swift
/// // Define base index
/// let baseIndex = Index(
///     name: "country_city_name",
///     type: .value,
///     rootExpression: CompoundKeyExpression(["country", "city", "name"])
/// )
///
/// // Define permuted index
/// let permutedIndex = Index(
///     name: "city_country_name",
///     type: .permuted,
///     rootExpression: CompoundKeyExpression(["country", "city", "name"]),
///     options: IndexOptions.permuted(
///         baseIndexName: "country_city_name",
///         permutation: try! Permutation(indices: [1, 0, 2])
///     )
/// )
///
/// // Query using permuted order
/// let query = Query.and(
///     Query.field("city").equals("Tokyo"),
///     Query.field("country").equals("Japan")
/// )
/// // Query planner will automatically use city_country_name index
/// ```
// MARK: - Generic Permuted Index Maintainer

/// Generic maintainer for permuted indexes
///
/// This is the new generic version that works with any record type
/// through RecordAccess instead of assuming dictionary-based records.
///
/// Permuted indexes reorder fields from a base index to enable different query patterns
/// without duplicating data storage.
///
/// **Usage:**
/// ```swift
/// let maintainer = GenericPermutedIndexMaintainer(
///     index: permutedIndex,
///     recordType: userType,
///     subspace: permutedSubspace,
///     recordSubspace: recordSubspace
/// )
/// ```
public struct GenericPermutedIndexMaintainer<Record: Sendable>: GenericIndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    private let baseIndexName: String
    private let permutation: Permutation

    public init(
        index: Index,
                subspace: Subspace,
        recordSubspace: Subspace
    ) throws {
        let options = index.options

        guard let baseIndexName = options.baseIndexName else {
            throw RecordLayerError.invalidPermutation("Permuted index requires baseIndexName")
        }

        guard let permutation = options.permutation else {
            throw RecordLayerError.invalidPermutation("Permuted index requires permutation")
        }

        self.index = index
        self.subspace = subspace
        self.recordSubspace = recordSubspace
        self.baseIndexName = baseIndexName
        self.permutation = permutation
    }

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old permuted entry if record existed
        if let oldRecord = oldRecord {
            let oldValues = try recordAccess.evaluate(
                record: oldRecord,
                expression: index.rootExpression
            )
            let oldPermuted = try permutation.apply(oldValues)

            // Extract primary key using Recordable protocol
            let oldPrimaryKeyTuple: Tuple
            if let recordableRecord = oldRecord as? any Recordable {
                oldPrimaryKeyTuple = recordableRecord.extractPrimaryKey()
            } else {
                throw RecordLayerError.internalError("Record does not conform to Recordable")
            }
            let oldPrimaryKey = try Tuple.unpack(from: oldPrimaryKeyTuple.pack())

            let oldKey = buildPermutedKey(
                permutedValues: oldPermuted,
                primaryKeyValues: oldPrimaryKey
            )
            transaction.clear(key: oldKey)
        }

        // Add new permuted entry if record exists
        if let newRecord = newRecord {
            let newValues = try recordAccess.evaluate(
                record: newRecord,
                expression: index.rootExpression
            )
            let newPermuted = try permutation.apply(newValues)

            // Extract primary key using Recordable protocol
            let newPrimaryKeyTuple: Tuple
            if let recordableRecord = newRecord as? any Recordable {
                newPrimaryKeyTuple = recordableRecord.extractPrimaryKey()
            } else {
                throw RecordLayerError.internalError("Record does not conform to Recordable")
            }
            let newPrimaryKey = try Tuple.unpack(from: newPrimaryKeyTuple.pack())

            let newKey = buildPermutedKey(
                permutedValues: newPermuted,
                primaryKeyValues: newPrimaryKey
            )
            transaction.setValue(FDB.Bytes(), for: newKey)
        }
    }

    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        let values = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )
        let permuted = try permutation.apply(values)

        let key = buildPermutedKey(
            permutedValues: permuted,
            primaryKeyValues: try Tuple.unpack(from: primaryKey.pack())
        )
        transaction.setValue(FDB.Bytes(), for: key)
    }

    // MARK: - Private Methods

    private func buildPermutedKey(
        permutedValues: [any TupleElement],
        primaryKeyValues: [any TupleElement]
    ) -> FDB.Bytes {
        let allElements = permutedValues + primaryKeyValues
        let tuple = TupleHelpers.toTuple(allElements)
        return subspace.pack(tuple)
    }
}
