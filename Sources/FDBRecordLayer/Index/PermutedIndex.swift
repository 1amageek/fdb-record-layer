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
public struct PermutedIndexMaintainer: IndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    /// Base index name that this permuted index references
    ///
    /// LIMITATION: Currently stored but not used for optimization
    ///
    /// In production, this should:
    /// 1. Verify base index exists during initialization
    /// 2. Use base index data to avoid duplicate storage
    /// 3. Share data between base and permuted indexes
    /// 4. Implement copy-on-write or reference counting
    ///
    /// Current implementation creates independent index entries,
    /// losing the storage optimization benefit (60-80% savings).
    private let baseIndexName: String

    /// Permutation to apply to fields
    private let permutation: Permutation

    // MARK: - Initialization

    /// Create a permuted index maintainer
    /// - Parameters:
    ///   - index: The permuted index definition
    ///   - subspace: Subspace for this permuted index
    ///   - recordSubspace: Subspace where records are stored
    /// - Throws: RecordLayerError.invalidPermutation if configuration is invalid
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

    // MARK: - IndexMaintainer Protocol

    public func updateIndex(
        oldRecord: [String: Any]?,
        newRecord: [String: Any]?,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old permuted entry if record existed
        if let oldRecord = oldRecord {
            let oldValues = index.rootExpression.evaluate(record: oldRecord)
            let oldPermuted = try permutation.apply(oldValues)
            let oldPrimaryKey = try extractPrimaryKey(oldRecord)

            let oldKey = buildPermutedKey(
                permutedValues: oldPermuted,
                primaryKey: oldPrimaryKey
            )
            transaction.clear(key: oldKey)
        }

        // Add new permuted entry if record exists
        if let newRecord = newRecord {
            let newValues = index.rootExpression.evaluate(record: newRecord)
            let newPermuted = try permutation.apply(newValues)
            let newPrimaryKey = try extractPrimaryKey(newRecord)

            let newKey = buildPermutedKey(
                permutedValues: newPermuted,
                primaryKey: newPrimaryKey
            )
            transaction.setValue(FDB.Bytes(), for: newKey)
        }
    }

    public func scanRecord(
        _ record: [String: Any],
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let values = index.rootExpression.evaluate(record: record)
        let permuted = try permutation.apply(values)

        let key = buildPermutedKey(
            permutedValues: permuted,
            primaryKey: primaryKey
        )
        transaction.setValue(FDB.Bytes(), for: key)
    }

    // MARK: - Private Methods

    /// Build permuted index key
    private func buildPermutedKey(
        permutedValues: [any TupleElement],
        primaryKey: Tuple
    ) -> FDB.Bytes {
        // Combine permuted values + primary key
        let primaryKeyElements = (try? Tuple.decode(from: primaryKey.encode())) ?? []
        let allElements = permutedValues + primaryKeyElements
        let tuple = TupleHelpers.toTuple(allElements)

        return subspace.pack(tuple)
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
}

// MARK: - Validation Helpers

extension PermutedIndexMaintainer {
    /// Validate that permutation size matches expected field count
    /// - Parameters:
    ///   - permutation: The permutation to validate
    ///   - fieldCount: Expected number of fields
    /// - Throws: RecordLayerError.invalidPermutation if size mismatch
    public static func validatePermutation(
        _ permutation: Permutation,
        fieldCount: Int
    ) throws {
        guard permutation.indices.count == fieldCount else {
            throw RecordLayerError.invalidPermutation(
                "Permutation size \(permutation.indices.count) does not match field count \(fieldCount)"
            )
        }
    }
}
