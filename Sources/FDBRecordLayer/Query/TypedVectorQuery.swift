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
        let context = TransactionContext(transaction: transaction)
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
        context: TransactionContext,
        recordSubspace: Subspace
    ) async throws -> [(record: Record, distance: Double)] {
        let transaction = context.getTransaction()

        // Build index subspace
        let indexNameSubspace = subspace.subspace(index.name)

        // ✅ Post-filter behavior: Ensure k results are returned
        // If post-filter exists, we may need multiple fetch attempts to get k results
        // because filtering can reduce the result count significantly.
        //
        // **Algorithm**:
        // 1. Initial fetch: k * 2 candidates
        // 2. Apply filter and collect results
        // 3. If results.count < k: fetch more candidates (k * 3, k * 4, ...)
        // 4. Skip already-processed primary keys to avoid duplicates
        // 5. Repeat until results.count >= k or no more candidates
        //
        // **Performance**:
        // - Best case (no filter or high selectivity): 1 search, O(log n) or O(n)
        // - Worst case (low selectivity): multiple searches, but ensures k results
        //
        // **Trade-off**:
        // - Guarantees k results (if enough candidates exist)
        // - May require multiple round-trips for low-selectivity filters

        var results: [(record: Record, distance: Double)] = []
        var fetchedPrimaryKeys: Set<String> = []
        let recordName = Record.recordName

        // ✅ Read strategy from Schema (runtime configuration)
        let strategy = schema.getVectorStrategy(for: index.name)

        // Maximum fetch attempts to prevent infinite loops
        let maxAttempts = 5
        var attempt = 0

        while results.count < k && attempt < maxAttempts {
            attempt += 1

            // Calculate fetchK for this attempt
            // - No filter: fetch exactly k
            // - With filter: fetch k * (1 + attempt) to progressively get more candidates
            let fetchK = postFilter != nil ? k * (1 + attempt) : k

            // Perform search based on strategy
            let searchResults: [(primaryKey: Tuple, distance: Double)]

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
                // Use HNSW for O(log n) search (large-scale datasets)

                // ✅ NEW: Check health tracker before attempting HNSW
                let (shouldUseHNSW, healthReason) = hnswHealthTracker.shouldUseHNSW(indexName: index.name)

                if !shouldUseHNSW {
                    // Circuit breaker: HNSW is unhealthy, use flat scan immediately
                    Logger(label: "com.fdb.recordlayer.query.vector").warning(
                        "⚠️ HNSW circuit breaker active for '\(index.name)': \(healthReason ?? "unhealthy")",
                        metadata: [
                            "index": "\(index.name)",
                            "action": "using flat scan fallback"
                        ]
                    )

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
                    // HNSW is healthy or retrying, attempt to use it
                    let hnswMaintainer = try GenericHNSWIndexMaintainer<Record>(
                        index: index,
                        subspace: indexNameSubspace,
                        recordSubspace: recordSubspace
                    )

                    if inlineIndexing {
                        // 🛡️ USER SPECIFICATION: Graceful fallback for inline indexing
                        do {
                            searchResults = try await hnswMaintainer.search(
                                queryVector: queryVector,
                                k: fetchK,
                                transaction: transaction
                            )

                            // ✅ NEW: Record success
                            hnswHealthTracker.recordSuccess(indexName: index.name)

                            if let reason = healthReason {
                                Logger(label: "com.fdb.recordlayer.query.vector").info(
                                    "✅ HNSW search successful for '\(index.name)': \(reason)"
                                )
                            }
                        } catch let error as RecordLayerError {
                            if case .hnswGraphNotBuilt = error {
                                // ✅ NEW: Record failure
                                hnswHealthTracker.recordFailure(indexName: index.name, error: error)

                                // Fall back to flat scan
                                Logger(label: "com.fdb.recordlayer.query.vector").warning(
                                    "⚠️ HNSW graph not found for '\(index.name)', falling back to flat scan (O(n))",
                                    metadata: [
                                        "index": "\(index.name)",
                                        "recommendation": "Build HNSW graph via OnlineIndexer for O(log n) performance"
                                    ]
                                )

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
                                throw error
                            }
                        }
                    } else {
                        // 🛡️ Strategy: .hnsw(inlineIndexing: false) - fail-fast
                        do {
                            searchResults = try await hnswMaintainer.search(
                                queryVector: queryVector,
                                k: fetchK,
                                transaction: transaction
                            )

                            // ✅ NEW: Record success
                            hnswHealthTracker.recordSuccess(indexName: index.name)

                            if let reason = healthReason {
                                Logger(label: "com.fdb.recordlayer.query.vector").info(
                                    "✅ HNSW search successful for '\(index.name)': \(reason)"
                                )
                            }
                        } catch let error as RecordLayerError {
                            // ✅ NEW: Record failure for fail-fast mode
                            if case .hnswGraphNotBuilt = error {
                                hnswHealthTracker.recordFailure(indexName: index.name, error: error)
                            }
                            throw error
                        }
                    }
                }
            }

            // Process search results
            var newResultsAdded = false

            for (primaryKey, distance) in searchResults {
                // Skip already-processed primary keys
                let pkKey = primaryKey.pack().map { String(format: "%02x", $0) }.joined()
                if fetchedPrimaryKeys.contains(pkKey) {
                    continue
                }
                fetchedPrimaryKeys.insert(pkKey)

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
                newResultsAdded = true

                // Stop if we have k results
                if results.count >= k {
                    break
                }
            }

            // If no new results were added, no point in retrying
            if !newResultsAdded {
                break
            }

            // If we have k results, we're done
            if results.count >= k {
                break
            }
        }

        return results
    }
}
