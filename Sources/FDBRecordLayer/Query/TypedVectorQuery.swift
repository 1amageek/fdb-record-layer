import Foundation
import FoundationDB
import Logging

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
public struct TypedVectorQuery<Record: Recordable>: Sendable {
    let k: Int
    let queryVector: [Float32]
    let index: Index
    let recordAccess: any RecordAccess<Record>
    let recordSubspace: Subspace
    let indexSubspace: Subspace
    let rootSubspace: Subspace
    nonisolated(unsafe) let database: any DatabaseProtocol
    let schema: Schema

    // Post-filter using TypedQueryComponent (consistent with existing DSL)
    private let postFilter: (any TypedQueryComponent<Record>)?

    internal init(
        k: Int,
        queryVector: [Float32],
        index: Index,
        recordAccess: any RecordAccess<Record>,
        recordSubspace: Subspace,
        indexSubspace: Subspace,
        rootSubspace: Subspace,
        database: any DatabaseProtocol,
        schema: Schema,
        postFilter: (any TypedQueryComponent<Record>)? = nil
    ) {
        self.k = k
        self.queryVector = queryVector
        self.index = index
        self.recordAccess = recordAccess
        self.recordSubspace = recordSubspace
        self.indexSubspace = indexSubspace
        self.rootSubspace = rootSubspace
        self.database = database
        self.schema = schema
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
            rootSubspace: rootSubspace,
            database: database,
            schema: schema,
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

        // ✅ Check IndexState before executing query
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: rootSubspace
        )

        let state = try await indexStateManager.state(of: index.name, context: context)
        guard state == .readable else {
            throw RecordLayerError.indexNotReadable(
                indexName: index.name,
                currentState: state,
                message: """
                Index '\(index.name)' is not readable (current state: \(state)).

                - If state is 'disabled': Enable the index first
                - If state is 'writeOnly': Wait for index build to complete
                - Only 'readable' indexes can be queried

                Current state: \(state)
                Expected state: readable
                """
            )
        }

        let plan = TypedVectorSearchPlan(
            k: k,
            queryVector: queryVector,
            index: index,
            postFilter: postFilter,
            schema: schema
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
/// **HNSW Support**: Automatically selects the appropriate index maintainer:
/// - `.vector` indexes → GenericHNSWIndexMaintainer for O(log n) search
/// - Other types → GenericVectorIndexMaintainer for O(n) flat scan
///
/// **Design Note**: Search methods are marked as read-only operations (snapshot: true).
/// While maintainers are primarily designed for write operations, the search() method
/// is explicitly intended for read-only queries and does not modify index state.
///
/// **Implementation**: Type selection occurs at execute() time based on index.type,
/// ensuring transparent HNSW usage without user code changes.
struct TypedVectorSearchPlan<Record: Recordable>: Sendable {
    private let k: Int
    private let queryVector: [Float32]
    private let index: Index
    private let postFilter: (any TypedQueryComponent<Record>)?
    private let schema: Schema

    init(
        k: Int,
        queryVector: [Float32],
        index: Index,
        postFilter: (any TypedQueryComponent<Record>)? = nil,
        schema: Schema
    ) {
        self.k = k
        self.queryVector = queryVector
        self.index = index
        self.postFilter = postFilter
        self.schema = schema
    }

    /// Execute vector search plan
    ///
    /// **HNSW Support**: Automatically selects HNSW maintainer for .vector indexes,
    /// providing O(log n) search instead of O(n) flat scan.
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

        // Perform search (snapshot read)
        // If post-filter exists, fetch more results to account for filtering
        let fetchK = postFilter != nil ? k * 2 : k

        // Select maintainer based on vector index strategy
        let searchResults: [(primaryKey: Tuple, distance: Double)]

        // ✅ Read strategy from Schema (runtime configuration)
        // Separates data structure (VectorIndexOptions) from runtime optimization (IndexConfiguration)
        let strategy = schema.getVectorStrategy(for: index.name)

        switch strategy {
        case .flatScan:
            // Use flat scan for O(n) search (small-scale datasets, lower memory)
            let flatMaintainer = try GenericVectorIndexMaintainer<Record>(
                index: index,
                subspace: indexNameSubspace,
                recordSubspace: recordSubspace
            )
            searchResults = try await flatMaintainer.search(
                queryVector: queryVector,
                k: fetchK,
                transaction: transaction
            )

        case .hnsw(let inlineIndexing):
            // ✅ Extract inlineIndexing flag for better error context
            // Use HNSW for O(log n) search (large-scale datasets)
            let hnswMaintainer = try GenericHNSWIndexMaintainer<Record>(
                index: index,
                subspace: indexNameSubspace,
                recordSubspace: recordSubspace
            )

            // 🛡️ CRITICAL: Provide context-aware error messages based on indexing strategy
            //
            // **Strategy: .hnsw(inlineIndexing: true)**
            // - Graph should be built via RecordStore.save() for small datasets (<100 nodes)
            // - If entry point is missing: Possible data corruption or graph exceeds size limit
            //
            // **Strategy: .hnsw(inlineIndexing: false)** (aka .hnswBatch)
            // - Graph MUST be built via OnlineIndexer.buildHNSWIndex()
            // - If entry point is missing: Expected behavior, user needs to run OnlineIndexer
            //
            // Both cases will throw RecordLayerError.hnswGraphNotBuilt with appropriate message.
            // The HNSW maintainer's search() method will detect missing entry point and throw.

            do {
                searchResults = try await hnswMaintainer.search(
                    queryVector: queryVector,
                    k: fetchK,
                    transaction: transaction
                )
            } catch let error as RecordLayerError {
                // Handle missing graph gracefully: log warning and fallback to flat scan
                if case .hnswGraphNotBuilt(let indexName, _) = error {
                    // ⚠️ Log warning and fallback to flat scan
                    if inlineIndexing {
                        Logger(label: "com.fdb.recordlayer.query.vector").warning("HNSW graph not built, falling back to flat scan", metadata: [
                            "index": "\(indexName)",
                            "strategy": ".hnsw(inlineIndexing: true)",
                            "behavior": "Falling back to O(n) flat scan instead of O(log n) HNSW",
                            "causes": "No records saved yet, or graph exceeded size limit (maxLevel >= 2)",
                            "recommendation": "Switch to .hnswBatch and rebuild via OnlineIndexer for datasets > 100 nodes",
                            "documentation": "docs/hnsw_inline_indexing_protection.md"
                        ])
                    } else {
                        Logger(label: "com.fdb.recordlayer.query.vector").warning("HNSW graph not built, falling back to flat scan", metadata: [
                            "index": "\(indexName)",
                            "strategy": ".hnsw(inlineIndexing: false) (aka .hnswBatch)",
                            "behavior": "Falling back to O(n) flat scan instead of O(log n) HNSW",
                            "expected": "Graph NOT built automatically - must run OnlineIndexer.buildHNSWIndex()",
                            "required_steps": "1) enable index, 2) build via OnlineIndexer, 3) make readable",
                            "recommendation": "This is EXPECTED if OnlineIndexer hasn't been run yet",
                            "documentation": "docs/hnsw_inline_indexing_protection.md"
                        ])
                    }

                    // ✅ Fallback to flat scan (O(n) brute-force search)
                    let flatMaintainer = try GenericVectorIndexMaintainer<Record>(
                        index: index,
                        subspace: indexNameSubspace,
                        recordSubspace: recordSubspace
                    )
                    searchResults = try await flatMaintainer.search(
                        queryVector: queryVector,
                        k: fetchK,
                        transaction: transaction
                    )
                } else {
                    // Other errors: re-throw as-is
                    throw error
                }
            }
        }

        // Fetch records and apply post-filter
        var results: [(record: Record, distance: Double)] = []
        // ✅ FIX: Use Record.recordName instead of String(describing:) to support custom record names
        let recordName = Record.recordName

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
