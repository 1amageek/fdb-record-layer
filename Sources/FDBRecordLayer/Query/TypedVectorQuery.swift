import Foundation
import FoundationDB

/// Type-safe vector similarity search query
///
/// Performs k-nearest neighbors search and optionally filters results.
/// **Distance Metric**: Depends on index configuration
/// - Cosine: `1 - cosine_similarity` (range: [0, 2], 0 = identical)
/// - L2: Euclidean distance (range: [0, ∞))
/// - Inner Product: `-dot_product` (range: (-∞, ∞))
///
/// **Example**:
/// ```swift
/// let results = try await store.query(Product.self)
///     .nearestNeighbors(k: 10, to: queryEmbedding, using: "product_embedding_vector")
///     .filter(\.category == "Electronics")
///     .execute()
///
/// for (product, distance) in results {
///     print("\(product.name): distance = \(distance)")
/// }
/// ```
public struct TypedVectorQuery<Record: Sendable>: Sendable {
    let k: Int
    let queryVector: [Float32]
    let index: Index
    let recordAccess: any RecordAccess<Record>
    let recordSubspace: Subspace
    let indexSubspace: Subspace
    nonisolated(unsafe) let database: any DatabaseProtocol

    // Post-filter using TypedQueryComponent (consistent with existing DSL)
    private let postFilter: (any TypedQueryComponent<Record>)?

    internal init(
        k: Int,
        queryVector: [Float32],
        index: Index,
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace,
        indexSubspace: Subspace,
        database: any DatabaseProtocol,
        postFilter: (any TypedQueryComponent<Record>)? = nil
    ) {
        self.k = k
        self.queryVector = queryVector
        self.index = index
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
        self.indexSubspace = indexSubspace
        self.database = database
        self.postFilter = postFilter
    }

    /// Add a filter to post-process results
    ///
    /// **Note**: Filters are applied AFTER vector search, so the query may fetch more than k results
    /// to ensure k results remain after filtering.
    /// Multiple calls to filter() are combined with AND logic.
    ///
    /// - Parameter component: Filter predicate using existing DSL (e.g., `\.age > 30`)
    /// - Returns: Modified query with additional filter
    public func filter(_ component: any TypedQueryComponent<Record>) -> TypedVectorQuery<Record> {
        let newFilter: any TypedQueryComponent<Record>
        if let existing = postFilter {
            // Combine with AND
            newFilter = TypedAndQueryComponent(children: [existing, component])
        } else {
            newFilter = component
        }

        return TypedVectorQuery(
            k: k,
            queryVector: queryVector,
            index: index,
            recordAccess: recordAccess,
            recordSubspace: recordSubspace,
            indexSubspace: indexSubspace,
            database: database,
            postFilter: newFilter
        )
    }

    /// Execute vector search
    ///
    /// - Returns: Array of (record, distance) tuples sorted by distance (ascending)
    /// - Throws: RecordLayerError on execution failure
    public func execute() async throws -> [(record: Record, distance: Double)] {
        // Create transaction for this query execution
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let plan = TypedVectorSearchPlan(
            k: k,
            queryVector: queryVector,
            index: index,
            postFilter: postFilter
        )

        return try await plan.execute(
            subspace: indexSubspace,
            recordAccess: recordAccess,
            context: context,
            recordSubspace: recordSubspace
        )
    }
}

/// Execution plan for vector similarity search
///
/// **Design Note**: This plan directly calls GenericVectorIndexMaintainer.search(),
/// which is marked as a read-only operation (snapshot: true). While maintainers are
/// primarily designed for write operations, the search() method is explicitly intended
/// for read-only queries and does not modify index state.
///
/// **Future Enhancement**: Extract search() to a separate VectorIndexReader component
/// to better separate read/write concerns.
struct TypedVectorSearchPlan<Record: Sendable>: Sendable {
    private let k: Int
    private let queryVector: [Float32]
    private let index: Index
    private let postFilter: (any TypedQueryComponent<Record>)?

    init(
        k: Int,
        queryVector: [Float32],
        index: Index,
        postFilter: (any TypedQueryComponent<Record>)? = nil
    ) {
        self.k = k
        self.queryVector = queryVector
        self.index = index
        self.postFilter = postFilter
    }

    /// Execute vector search plan
    ///
    /// - Returns: Array of (record, distance) tuples
    func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        recordSubspace: Subspace
    ) async throws -> [(record: Record, distance: Double)] {
        let transaction = context.getTransaction()

        // Build index subspace
        let indexNameSubspace = subspace.subspace(index.name)

        // Create vector index maintainer (read-only usage)
        let maintainer = try GenericVectorIndexMaintainer<Record>(
            index: index,
            subspace: indexNameSubspace,
            recordSubspace: recordSubspace
        )

        // Perform search (snapshot read)
        // If post-filter exists, fetch more results to account for filtering
        let fetchK = postFilter != nil ? k * 2 : k
        let searchResults = try await maintainer.search(
            queryVector: queryVector,
            k: fetchK,
            transaction: transaction
        )

        // Fetch records and apply post-filter
        var results: [(record: Record, distance: Double)] = []
        let recordName = String(describing: Record.self)

        for (primaryKey, distance) in searchResults {
            // Fetch record
            let effectiveSubspace = recordSubspace.subspace(recordName)
            let recordKey = effectiveSubspace.subspace(primaryKey).pack(Tuple())

            guard let recordValue = try await transaction.getValue(for: recordKey, snapshot: true) else {
                continue  // Record deleted, skip
            }

            let record = try recordAccess.deserialize(recordValue)

            // Apply post-filter if present
            if let filter = postFilter {
                let matches = try filter.matches(record: record, recordAccess: recordAccess)
                if !matches {
                    continue
                }
            }

            results.append((record: record, distance: distance))

            // Stop after k results (post-filter may reduce result count)
            if results.count >= k {
                break
            }
        }

        return results
    }
}
