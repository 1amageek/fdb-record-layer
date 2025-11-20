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

            if inlineIndexing {
                // 🛡️ USER SPECIFICATION: Graceful fallback for inline indexing
                // Try HNSW first (O(log n)), fall back to flat scan only if HNSW fails
                //
                // **Behavior**:
                // 1. Try HNSW search (may fail if graph not built)
                // 2. If HNSW succeeds → use HNSW results only (O(log n) performance)
                // 3. If HNSW fails → fall back to flat scan (O(n) performance)
                //
                // **Performance**:
                // - HNSW success: O(log n) - no flat scan overhead
                // - HNSW failure: O(n) - graceful degradation
                //
                // **User Requirement**:
                // "仕様上ここではエラーを投げるべきではありません。適切にフォールバックを行うのは仕様となります。
                //  警告となるログは残すものの正確フォールバックしてユーザーの意図に沿って結果を返すことを第一に考えるべきです"
                // "According to the specification, errors should not be thrown. Proper fallback is the specification.
                //  While warning logs should remain, the priority should be to accurately fallback and return results
                //  in line with user intent."

                // 1. Try HNSW search first
                do {
                    searchResults = try await hnswMaintainer.search(
                        queryVector: queryVector,
                        k: fetchK,
                        transaction: transaction
                    )
                    // ✅ HNSW succeeded - use O(log n) results, skip flat scan
                } catch let error as RecordLayerError {
                    if case .hnswGraphNotBuilt = error {
                        // 2. HNSW graph not built - fall back to flat scan (O(n))
                        Logger(label: "com.fdb.recordlayer.query.vector").warning(
                            "HNSW graph not found, falling back to flat scan (O(n))",
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
                        // Other errors - re-throw
                        throw error
                    }
                }
            } else {
                // 🛡️ Strategy: .hnsw(inlineIndexing: false) (aka .hnswBatch)
                // - Graph MUST be built via OnlineIndexer.buildHNSWIndex()
                // - If entry point is missing: Expected behavior, user needs to run OnlineIndexer
                // - Fail-fast: throw error to force user to build HNSW graph via OnlineIndexer

                searchResults = try await hnswMaintainer.search(
                    queryVector: queryVector,
                    k: fetchK,
                    transaction: transaction
                )
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

    /// Merge HNSW and flat search results, removing duplicates and sorting by distance
    ///
    /// **Deduplication**: Primary keys are used to identify duplicates
    /// **Distance**: In case of duplicate, use the smaller distance
    ///
    /// - Parameters:
    ///   - hnswResults: Results from HNSW graph search
    ///   - flatResults: Results from flat index search
    ///   - k: Maximum number of results to return
    /// - Returns: Merged, deduplicated, and sorted results (limited to k)
    private func mergeVectorSearchResults(
        hnswResults: [(primaryKey: Tuple, distance: Double)],
        flatResults: [(primaryKey: Tuple, distance: Double)],
        k: Int
    ) -> [(primaryKey: Tuple, distance: Double)] {
        var resultMap: [String: (primaryKey: Tuple, distance: Double)] = [:]

        // Add HNSW results
        for (primaryKey, distance) in hnswResults {
            let key = primaryKey.pack().map { String(format: "%02x", $0) }.joined()
            resultMap[key] = (primaryKey, distance)
        }

        // Add flat results, keeping better distance if duplicate
        for (primaryKey, distance) in flatResults {
            let key = primaryKey.pack().map { String(format: "%02x", $0) }.joined()
            if let existing = resultMap[key] {
                // Keep smaller distance
                if distance < existing.distance {
                    resultMap[key] = (primaryKey, distance)
                }
            } else {
                resultMap[key] = (primaryKey, distance)
            }
        }

        // Sort by distance and limit to k
        let sorted = resultMap.values.sorted { $0.distance < $1.distance }
        return Array(sorted.prefix(k))
    }
}
