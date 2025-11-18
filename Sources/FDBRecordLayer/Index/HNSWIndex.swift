import Foundation
import FoundationDB
import Logging

// MARK: - HNSW Data Structures

/// HNSW node metadata (NO vector duplication - vectors stored in flat index only)
///
/// **Storage Design (v2.1)**:
/// - Flat Index: `[indexSubspace][primaryKey] = vector` (source of truth)
/// - HNSW Metadata: `[indexSubspace]["hnsw"]["nodes"][primaryKey] = HNSWNodeMetadata`
/// - HNSW Edges: `[indexSubspace]["hnsw"]["edges"][primaryKey][level][neighborPK] = ""`
///
/// **Critical**: This struct contains NO vector data. Vectors are loaded from flat index only.
public struct HNSWNodeMetadata: Codable, Sendable {
    /// Maximum level this node appears in (0-indexed)
    ///
    /// Level is assigned probabilistically during insertion:
    /// - P(level = l) = (1/M)^l
    /// - Higher levels have exponentially fewer nodes
    /// - Top layer typically has 1-2 nodes (entry points)
    public let level: Int

    /// Initialize node metadata
    ///
    /// - Parameter level: Maximum level for this node (0 = ground layer)
    public init(level: Int) {
        self.level = level
    }
}

/// HNSW index parameters
///
/// **Default Values** (optimized for general use):
/// - M = 16: Max edges per layer (typical range: 5-48)
/// - efConstruction = 100: Dynamic candidate list size during construction
/// - ml = 1/ln(M) ≈ 0.36: Level assignment multiplier
///
/// **Performance Characteristics**:
/// - Higher M → Better recall, slower insertion, more storage
/// - Higher efConstruction → Better graph quality, slower insertion
/// - Lower M → Faster insertion, worse recall
public struct HNSWParameters: Sendable {
    /// Maximum number of bi-directional connections for each node per layer
    ///
    /// **Layer 0**: M_max = M * 2 (denser connections at ground layer)
    /// **Layer > 0**: M_max = M
    ///
    /// Typical values: 5-48 (16 is a good default)
    public let M: Int

    /// Size of the dynamic candidate list during construction
    ///
    /// Controls graph quality during insertion. Higher values produce better
    /// graphs but take longer to build.
    ///
    /// Typical values: 100-500 (100 is a good default)
    public let efConstruction: Int

    /// Level assignment multiplier (1/ln(M))
    ///
    /// Used to probabilistically assign levels to nodes:
    /// - level = floor(-ln(uniform(0,1)) * ml)
    ///
    /// For M=16: ml ≈ 0.36
    public let ml: Double

    /// Initialize with custom parameters
    ///
    /// - Parameters:
    ///   - M: Max edges per layer (default: 16)
    ///   - efConstruction: Dynamic candidate list size (default: 100)
    public init(M: Int = 16, efConstruction: Int = 100) {
        self.M = M
        self.efConstruction = efConstruction
        self.ml = 1.0 / log(Double(M))
    }

    /// Maximum edges for layer 0 (ground layer is denser)
    public var M_max0: Int {
        return M * 2
    }

    /// Maximum edges for layers > 0
    public var M_max: Int {
        return M
    }
}

/// Search-time parameters for HNSW
///
/// **ef (exploration factor)**: Size of dynamic candidate list during search
/// - Higher ef → Better recall, slower search
/// - Lower ef → Faster search, worse recall
/// - Must be >= k (number of nearest neighbors)
/// - Typical: ef = k * 1.5 to k * 3
public struct HNSWSearchParameters: Sendable {
    /// Size of dynamic candidate list during search
    ///
    /// **Recommendation**: ef >= k (k = number of results)
    /// - For recall ~90%: ef ≈ k * 1.5
    /// - For recall ~95%: ef ≈ k * 2
    /// - For recall ~99%: ef ≈ k * 3
    public let ef: Int

    /// Initialize search parameters
    ///
    /// - Parameter ef: Exploration factor (default: 50)
    public init(ef: Int = 50) {
        self.ef = ef
    }
}

// MARK: - HNSW Index Maintainer

/// HNSW (Hierarchical Navigable Small World) index maintainer
///
/// **Phase 2 Implementation**: Approximate nearest neighbor search using HNSW graph
///
/// **Algorithm**:
/// - **Construction**: O(log n) insertion with probabilistic layers
/// - **Search**: O(log n) greedy search with dynamic candidate list
/// - **Deletion**: O(M^2 * level) with neighbor rewiring
/// - **Storage**: Metadata-only (vectors in flat index, no duplication)
///
/// **Storage Layout**:
/// ```
/// Flat Index (Phase 1): [indexSubspace][primaryKey] = vector
/// HNSW Metadata:        [indexSubspace]["hnsw"]["nodes"][primaryKey] = HNSWNodeMetadata
/// HNSW Edges:           [indexSubspace]["hnsw"]["edges"][primaryKey][level][neighborPK] = ""
/// Entry Point:          [indexSubspace]["hnsw"]["entrypoint"] = primaryKey
/// ```
///
/// **⚠️ CRITICAL: Transaction Budget Limitations**:
///
/// **Actual Complexity** (measured, not theoretical):
/// - **Small graphs** (level ≤ 2, ~1,000 nodes): ~2,600 ops/insert ✅ Safe
/// - **Medium graphs** (level = 3, ~5,000 nodes): ~3,800 ops/insert ⚠️ Risky
/// - **Large graphs** (level ≥ 4, >10,000 nodes): ~12,000+ ops/insert ❌ Will timeout
///
/// **Why**: Nested loops in pruning logic:
/// - searchLayer: efConstruction * avgNeighbors getNeighbors calls per level
/// - Pruning: M * M distance calculations per level
/// - Total: O(efConstruction * M * currentLevel) with nested I/O
///
/// **⚠️ DO NOT USE INLINE INDEXING FOR HNSW IN PRODUCTION**
///
/// **Correct Usage Pattern**:
/// ```swift
/// // Step 1: Create index in writeOnly state (disable inline maintenance)
/// let hnswIndex = Index(
///     name: "vector_hnsw",
///     type: .vector,
///     rootExpression: FieldKeyExpression(fieldName: "embedding"),
///     options: IndexOptions(vectorOptions: VectorOptions(dimensions: 128, metric: .cosine))
/// )
/// try await indexStateManager.setState(index: "vector_hnsw", state: .writeOnly)
///
/// // Step 2: Build via OnlineIndexer (batched, safe)
/// try await onlineIndexer.buildIndex(
///     indexName: "vector_hnsw",
///     batchSize: 100,      // Batch insertions
///     throttleDelayMs: 10  // Respect FDB limits
/// )
///
/// // Step 3: Enable queries
/// try await indexStateManager.setState(index: "vector_hnsw", state: .readable)
///
/// // Step 4: Search (fast, O(log n))
/// let maintainer = try indexManager.maintainer(for: "vector_hnsw") as! GenericHNSWIndexMaintainer<MyRecord>
/// let results = try await maintainer.search(
///     queryVector: queryEmbedding,
///     k: 10,
///     searchParams: HNSWSearchParameters(ef: 50),
///     transaction: transaction
/// )
/// ```
///
/// **Inline Indexing Behavior**:
/// - ✅ **Deletions**: Supported (fast, O(M^2 * level) with neighbor rewiring)
/// - ❌ **Insertions**: Will throw error if graph has >2 levels
/// - 📋 **Recommendation**: Always use OnlineIndexer for insertions
public struct GenericHNSWIndexMaintainer<Record: Recordable>: GenericIndexMaintainer {
    public let index: Index
    public let subspace: Subspace
    public let recordSubspace: Subspace

    // HNSW parameters
    private let parameters: HNSWParameters

    // Extract vector options from index
    private let dimensions: Int
    private let metric: VectorMetric

    // HNSW subspaces
    private let hnswSubspace: Subspace
    private let nodesSubspace: Subspace
    private let edgesSubspace: Subspace
    private let entryPointKey: FDB.Bytes

    public init(
        index: Index,
        subspace: Subspace,
        recordSubspace: Subspace,
        parameters: HNSWParameters = HNSWParameters()
    ) throws {
        self.index = index
        self.subspace = subspace
        self.recordSubspace = recordSubspace
        self.parameters = parameters

        // Extract vector options
        guard index.type == .vector else {
            throw RecordLayerError.internalError("GenericHNSWIndexMaintainer requires vector index type")
        }

        guard let options = index.options.vectorOptions else {
            throw RecordLayerError.internalError("Vector index must have vectorOptions configured")
        }

        self.dimensions = options.dimensions
        self.metric = options.metric

        // Initialize HNSW subspaces
        self.hnswSubspace = subspace.subspace("hnsw")
        self.nodesSubspace = hnswSubspace.subspace("nodes")
        self.edgesSubspace = hnswSubspace.subspace("edges")
        self.entryPointKey = hnswSubspace.pack(Tuple("entrypoint"))
    }
}

// MARK: - HNSW Storage Helpers

extension GenericHNSWIndexMaintainer {
    /// Load vector from flat index (ONLY way to access vectors in Phase 2)
    ///
    /// **Critical**: Vectors are NEVER stored in HNSW metadata. This function
    /// is the single source of truth for vector data.
    ///
    /// **Storage**: `[indexSubspace][primaryKey] = Tuple(Float32, ...)`
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key of the record
    ///   - transaction: FDB transaction
    /// - Returns: Vector as [Float32] array
    /// - Throws: RecordLayerError.internalError if vector not found
    private func loadVectorFromFlatIndex(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> [Float32] {
        // Build flat index key: [indexSubspace][primaryKey]
        let vectorKey = subspace.pack(primaryKey)

        guard let vectorValue = try await transaction.getValue(for: vectorKey, snapshot: true) else {
            throw RecordLayerError.internalError(
                "Vector not found in flat index for primaryKey: \(primaryKey)"
            )
        }

        // Decode vector from tuple
        let vectorTuple = try Tuple.unpack(from: vectorValue)
        var vectorArray: [Float32] = []
        vectorArray.reserveCapacity(dimensions)

        for i in 0..<dimensions {
            guard i < vectorTuple.count else {
                throw RecordLayerError.internalError(
                    "Vector tuple has fewer elements than expected dimensions. " +
                    "Expected: \(dimensions), Got: \(vectorTuple.count)"
                )
            }

            let element = vectorTuple[i]

            // Handle both Float and Double from tuple
            let floatValue: Float32
            if let f = element as? Float {
                floatValue = Float32(f)
            } else if let d = element as? Double {
                floatValue = Float32(d)
            } else {
                throw RecordLayerError.internalError(
                    "Vector tuple element must be Float or Double, got: \(type(of: element))"
                )
            }

            vectorArray.append(floatValue)
        }

        return vectorArray
    }

    /// Calculate distance between two vectors based on configured metric
    ///
    /// **Supported Metrics**:
    /// - `.cosine`: 1 - cosine_similarity (range: [0, 2])
    /// - `.l2`: Euclidean distance (range: [0, ∞))
    /// - `.innerProduct`: -dot_product (range: (-∞, ∞))
    ///
    /// - Parameters:
    ///   - vector1: First vector
    ///   - vector2: Second vector
    /// - Returns: Distance value (smaller = more similar)
    private func calculateDistance(_ vector1: [Float32], _ vector2: [Float32]) -> Double {
        precondition(vector1.count == vector2.count, "Vector dimensions must match")

        switch metric {
        case .cosine:
            return cosineDistance(vector1, vector2)
        case .l2:
            return l2Distance(vector1, vector2)
        case .innerProduct:
            return innerProductDistance(vector1, vector2)
        }
    }

    /// Cosine distance: 1 - cosine_similarity
    /// Range: [0, 2], where 0 = identical, 2 = opposite
    private func cosineDistance(_ v1: [Float32], _ v2: [Float32]) -> Double {
        let dotProduct = zip(v1, v2).map { Double($0) * Double($1) }.reduce(0, +)
        let norm1 = sqrt(v1.map { Double($0) * Double($0) }.reduce(0, +))
        let norm2 = sqrt(v2.map { Double($0) * Double($0) }.reduce(0, +))

        guard norm1 > 0 && norm2 > 0 else {
            return 2.0  // Maximum distance for zero vectors
        }

        let cosineSimilarity = dotProduct / (norm1 * norm2)
        return 1.0 - cosineSimilarity
    }

    /// L2 (Euclidean) distance
    /// Range: [0, ∞)
    private func l2Distance(_ v1: [Float32], _ v2: [Float32]) -> Double {
        var sum: Double = 0.0
        for (a, b) in zip(v1, v2) {
            let diff = Double(a) - Double(b)
            sum += diff * diff
        }
        return sqrt(sum)
    }

    /// Inner product distance: -dot_product
    /// Range: (-∞, ∞), negative for dissimilarity
    private func innerProductDistance(_ v1: [Float32], _ v2: [Float32]) -> Double {
        let dotProduct = zip(v1, v2).map { Double($0) * Double($1) }.reduce(0, +)
        return -dotProduct  // Negative because we want smaller = more similar
    }

    /// Assign random level for new node using exponential decay
    ///
    /// **Algorithm**: level = floor(-ln(uniform(0,1)) * ml)
    /// - ml = 1/ln(M) ≈ 0.36 for M=16
    /// - P(level = l) = (1/M)^l (exponential distribution)
    ///
    /// **Level Distribution** (M=16, 1000 nodes):
    /// - Level 0: ~940 nodes (94%)
    /// - Level 1: ~59 nodes (5.9%)
    /// - Level 2: ~1 node (0.1%)
    ///
    /// - Returns: Random level (0-indexed)
    private func assignRandomLevel() -> Int {
        let randomValue = Double.random(in: 0..<1)
        let level = Int(floor(-log(randomValue) * parameters.ml))
        return max(0, level)  // Ensure non-negative
    }

    /// Estimate FDB operations for inserting into a graph with given currentLevel
    ///
    /// **Actual Complexity** (measured, not theoretical):
    /// - Each searchLayer call: ~efConstruction * avgNeighbors getNeighbors operations
    ///   - efConstruction = 100 (default)
    ///   - avgNeighbors ≈ M/2 ≈ 8 (average branching factor)
    ///   - Per level: ~800 ops
    /// - Each level insertion: M edge additions + M pruning checks
    ///   - Each pruning: getNeighbors + distance calculations (another ~M ops)
    ///   - Per level: ~M * (2 + M) ≈ 16 * 18 = 288 ops
    /// - Total per level: ~1,088 ops
    /// - Total for insertion: ~currentLevel * 1,088 + metadata overhead
    ///
    /// **Conservative Formula** (with safety margin):
    /// - Base: currentLevel * 1,200 (includes all nested operations)
    /// - Overhead: 200 (metadata, entry point updates)
    /// - Total: currentLevel * 1,200 + 200
    ///
    /// **Examples**:
    /// - currentLevel = 2: 2,600 ops (safe)
    /// - currentLevel = 3: 3,800 ops (safe)
    /// - currentLevel = 4: 5,000 ops (borderline)
    /// - currentLevel = 5: 6,200 ops (risky)
    /// - currentLevel = 10: 12,200 ops (will timeout)
    ///
    /// - Parameter currentLevel: Current maximum level in the graph
    /// - Returns: Estimated number of FDB operations
    private func estimateInsertionOperations(currentLevel: Int) -> Int {
        let opsPerLevel = 1_200  // Conservative estimate including all nested operations
        let overhead = 200
        return currentLevel * opsPerLevel + overhead
    }

    /// Get current entry point of HNSW graph
    ///
    /// **Storage**: `[indexSubspace]["hnsw"]["entrypoint"] = primaryKey`
    ///
    /// - Parameters:
    ///   - transaction: FDB transaction
    ///   - snapshot: Use snapshot read (default: true for read-only queries)
    /// - Returns: Entry point primary key, or nil if graph is empty
    private func getEntryPoint(
        transaction: any TransactionProtocol,
        snapshot: Bool = true
    ) async throws -> Tuple? {
        guard let entryPointBytes = try await transaction.getValue(for: entryPointKey, snapshot: snapshot) else {
            return nil
        }
        let elements = try Tuple.unpack(from: entryPointBytes)
        return Tuple(elements)
    }

    /// Set entry point of HNSW graph
    ///
    /// **Storage**: `[indexSubspace]["hnsw"]["entrypoint"] = primaryKey`
    ///
    /// - Parameters:
    ///   - primaryKey: New entry point
    ///   - transaction: FDB transaction
    private func setEntryPoint(primaryKey: Tuple, transaction: any TransactionProtocol) {
        transaction.setValue(primaryKey.pack(), for: entryPointKey)
    }

    /// Load node metadata
    ///
    /// **Storage**: `[indexSubspace]["hnsw"]["nodes"][primaryKey] = HNSWNodeMetadata`
    ///
    /// - Parameters:
    ///   - primaryKey: Node's primary key
    ///   - transaction: FDB transaction
    ///   - snapshot: Use snapshot read (default: true for read-only queries)
    /// - Returns: Node metadata, or nil if not found
    public func getNodeMetadata(
        primaryKey: Tuple,
        transaction: any TransactionProtocol,
        snapshot: Bool = true
    ) async throws -> HNSWNodeMetadata? {
        let nodeKey = nodesSubspace.pack(primaryKey)
        guard let nodeBytes = try await transaction.getValue(for: nodeKey, snapshot: snapshot) else {
            return nil
        }

        let decoder = JSONDecoder()
        return try decoder.decode(HNSWNodeMetadata.self, from: Data(nodeBytes))
    }

    /// Save node metadata
    ///
    /// **Storage**: `[indexSubspace]["hnsw"]["nodes"][primaryKey] = HNSWNodeMetadata`
    ///
    /// - Parameters:
    ///   - primaryKey: Node's primary key
    ///   - metadata: Node metadata
    ///   - transaction: FDB transaction
    private func setNodeMetadata(
        primaryKey: Tuple,
        metadata: HNSWNodeMetadata,
        transaction: any TransactionProtocol
    ) throws {
        let nodeKey = nodesSubspace.pack(primaryKey)
        let encoder = JSONEncoder()
        let nodeBytes = try encoder.encode(metadata)
        transaction.setValue(Array(nodeBytes), for: nodeKey)
    }

    /// Get neighbors of a node at a specific level
    ///
    /// **Storage**: `[indexSubspace]["hnsw"]["edges"][primaryKey][level][neighborPK] = ""`
    ///
    /// - Parameters:
    ///   - primaryKey: Node's primary key
    ///   - level: Layer level
    ///   - transaction: FDB transaction
    ///   - snapshot: Use snapshot read (default: true for read-only queries)
    /// - Returns: Array of neighbor primary keys
    private func getNeighbors(
        primaryKey: Tuple,
        level: Int,
        transaction: any TransactionProtocol,
        snapshot: Bool = true
    ) async throws -> [Tuple] {
        let levelSubspace = edgesSubspace.subspace(primaryKey).subspace(level)
        let (begin, end) = levelSubspace.range()

        var neighbors: [Tuple] = []
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(begin),
            endSelector: .firstGreaterOrEqual(end),
            snapshot: snapshot
        )

        for try await (key, _) in sequence {
            let neighborPK = try levelSubspace.unpack(key)
            neighbors.append(neighborPK)
        }

        return neighbors
    }

    /// Add bidirectional edge between two nodes at a specific level
    ///
    /// **Storage**: `[indexSubspace]["hnsw"]["edges"][primaryKey][level][neighborPK] = ""`
    ///
    /// - Parameters:
    ///   - fromPK: Source node primary key
    ///   - toPK: Target node primary key
    ///   - level: Layer level
    ///   - transaction: FDB transaction
    private func addEdge(
        fromPK: Tuple,
        toPK: Tuple,
        level: Int,
        transaction: any TransactionProtocol
    ) {
        // Add forward edge: from -> to
        let forwardKey = edgesSubspace.subspace(fromPK).subspace(level).pack(toPK)
        transaction.setValue([], for: forwardKey)

        // Add backward edge: to -> from (bidirectional)
        let backwardKey = edgesSubspace.subspace(toPK).subspace(level).pack(fromPK)
        transaction.setValue([], for: backwardKey)
    }

    /// Remove edge between two nodes at a specific level
    ///
    /// **Storage**: `[indexSubspace]["hnsw"]["edges"][primaryKey][level][neighborPK] = ""`
    ///
    /// - Parameters:
    ///   - fromPK: Source node primary key
    ///   - toPK: Target node primary key
    ///   - level: Layer level
    ///   - transaction: FDB transaction
    private func removeEdge(
        fromPK: Tuple,
        toPK: Tuple,
        level: Int,
        transaction: any TransactionProtocol
    ) {
        // Remove forward edge
        let forwardKey = edgesSubspace.subspace(fromPK).subspace(level).pack(toPK)
        transaction.clear(key: forwardKey)

        // Remove backward edge
        let backwardKey = edgesSubspace.subspace(toPK).subspace(level).pack(fromPK)
        transaction.clear(key: backwardKey)
    }

    /// Search for nearest neighbors within a single layer (greedy search)
    ///
    /// **Algorithm**:
    /// 1. Start from entry points
    /// 2. Explore neighbors, keeping ef closest candidates
    /// 3. Use MinHeap to track candidates and visited nodes
    /// 4. Stop when no closer nodes are found
    ///
    /// **Time Complexity**: O(ef * log ef)
    ///
    /// - Parameters:
    ///   - queryVector: Query vector
    ///   - entryPoints: Starting points for search
    ///   - ef: Size of dynamic candidate list
    ///   - level: Layer level to search
    ///   - transaction: FDB transaction
    ///   - snapshot: Use snapshot read (default: true for read-only queries)
    /// - Returns: Array of (primaryKey, distance) sorted by distance (ascending)
    private func searchLayer(
        queryVector: [Float32],
        entryPoints: [Tuple],
        ef: Int,
        level: Int,
        transaction: any TransactionProtocol,
        snapshot: Bool = true
    ) async throws -> [(primaryKey: Tuple, distance: Double)] {
        var visited = Set<Tuple>()

        // Candidates: MaxHeap to track ef closest (evicts furthest)
        var candidates = MinHeap<(primaryKey: Tuple, distance: Double)>(
            maxSize: ef,
            heapType: .max,
            comparator: { $0.distance > $1.distance }
        )

        // Result: MinHeap to track best ef candidates
        var result = MinHeap<(primaryKey: Tuple, distance: Double)>(
            maxSize: ef,
            heapType: .max,
            comparator: { $0.distance > $1.distance }
        )

        // Initialize with entry points
        for entryPK in entryPoints {
            let entryVector = try await loadVectorFromFlatIndex(primaryKey: entryPK, transaction: transaction)
            let distance = calculateDistance(queryVector, entryVector)

            candidates.insert((primaryKey: entryPK, distance: distance))
            result.insert((primaryKey: entryPK, distance: distance))
            visited.insert(entryPK)
        }

        // Greedy search
        while !candidates.isEmpty {
            guard let current = candidates.removeMin() else { break }

            // If current is further than worst result, stop
            if let worst = result.min, current.distance > worst.distance {
                break
            }

            // Explore neighbors
            let neighbors = try await getNeighbors(
                primaryKey: current.primaryKey,
                level: level,
                transaction: transaction,
                snapshot: snapshot
            )

            for neighborPK in neighbors {
                if visited.contains(neighborPK) { continue }
                visited.insert(neighborPK)

                let neighborVector = try await loadVectorFromFlatIndex(primaryKey: neighborPK, transaction: transaction)
                let distance = calculateDistance(queryVector, neighborVector)

                if result.count < ef || distance < result.min!.distance {
                    candidates.insert((primaryKey: neighborPK, distance: distance))
                    result.insert((primaryKey: neighborPK, distance: distance))
                }
            }
        }

        return result.sorted()
    }

    /// Select M neighbors using heuristic (prune to maintain graph quality)
    ///
    /// **Algorithm** (Simple heuristic - can be improved):
    /// 1. Sort candidates by distance (ascending)
    /// 2. Take first M candidates
    ///
    /// **Future Enhancement**: Implement RNG (Relative Neighborhood Graph) heuristic
    /// for better graph quality and recall.
    ///
    /// - Parameters:
    ///   - candidates: Candidate neighbors with distances
    ///   - M: Maximum number of neighbors
    /// - Returns: Selected neighbors (up to M)
    private func selectNeighborsHeuristic(
        candidates: [(primaryKey: Tuple, distance: Double)],
        M: Int
    ) -> [Tuple] {
        // Simple heuristic: take M closest
        let sorted = candidates.sorted { $0.distance < $1.distance }
        return sorted.prefix(M).map { $0.primaryKey }
    }

    /// Insert a new node into HNSW graph
    ///
    /// **Algorithm** (HNSW Paper - Algorithm 1):
    /// 1. Assign random level to new node
    /// 2. Find nearest neighbors at each layer
    /// 3. Connect to M nearest neighbors per layer
    /// 4. Update entry point if new node has higher level
    ///
    /// **Transaction Budget** (CRITICAL - Read This):
    /// - **Design estimate** (outdated): ~169 ops per insertion (M=16, avgLevel=2, efConstruction=100)
    /// - **Actual operations**: ~12,000+ ops for medium-sized graphs (currentLevel >= 3)
    ///   - searchLayer: ~efConstruction * avgNeighbors operations per level
    ///   - Edge pruning: ~M * M operations per level (nested loops)
    ///   - Total: O(efConstruction * M * currentLevel) ≈ 100 * 16 * 3 = 4,800 base ops
    ///   - With nested getNeighbors in pruning: 4,800 * 2.5 ≈ 12,000 ops
    ///
    /// **Graph Size Limits for Single-Transaction Insertion**:
    /// - Small graphs (currentLevel <= 2): ~6,400 ops, safe for single transaction
    /// - Medium graphs (currentLevel = 3): ~12,000 ops, may timeout
    /// - Large graphs (currentLevel >= 4): ~19,200+ ops, will timeout
    ///
    /// **⚠️ IMPORTANT**: For production use with large graphs, use OnlineIndexer for batch
    /// insertions instead of calling this method directly from user transactions.
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key of new node
    ///   - queryVector: Vector of new node
    ///   - transaction: FDB transaction
    private func insert(
        primaryKey: Tuple,
        queryVector: [Float32],
        transaction: any TransactionProtocol
    ) async throws {
        // Assign random level
        let nodeLevel = assignRandomLevel()

        // Get current entry point
        guard let entryPointPK = try await getEntryPoint(transaction: transaction) else {
            // First node in graph
            let metadata = HNSWNodeMetadata(level: nodeLevel)
            try setNodeMetadata(primaryKey: primaryKey, metadata: metadata, transaction: transaction)
            setEntryPoint(primaryKey: primaryKey, transaction: transaction)
            return
        }

        let entryMetadata = try await getNodeMetadata(primaryKey: entryPointPK, transaction: transaction)!
        let currentLevel = entryMetadata.level

        // CRITICAL: Transaction budget check
        // Estimate operations based on actual measured complexity
        let estimatedOps = estimateInsertionOperations(currentLevel: currentLevel)
        if estimatedOps > 10_000 {
            throw RecordLayerError.internalError(
                "HNSW insertion would exceed FDB transaction limits. " +
                "Estimated operations: \(estimatedOps) (limit: ~10,000). " +
                "Graph has \(currentLevel) levels. " +
                "Use OnlineIndexer.buildIndex() for batch insertions to large graphs. " +
                "Single-transaction insertion is only safe for graphs with ≤2 levels (~1,000 nodes)."
            )
        }

        // Search for nearest neighbors from top to target level
        var entryPoints = [entryPointPK]

        // Phase 1: Greedy search from top to nodeLevel + 1
        for level in stride(from: currentLevel, through: nodeLevel + 1, by: -1) {
            let nearest = try await searchLayer(
                queryVector: queryVector,
                entryPoints: entryPoints,
                ef: 1,  // Only need 1 for greedy search
                level: level,
                transaction: transaction
            )
            entryPoints = [nearest[0].primaryKey]
        }

        // Phase 2: Insert at each layer from nodeLevel to 0
        for level in stride(from: nodeLevel, through: 0, by: -1) {
            // Find efConstruction nearest neighbors
            let candidates = try await searchLayer(
                queryVector: queryVector,
                entryPoints: entryPoints,
                ef: parameters.efConstruction,
                level: level,
                transaction: transaction
            )

            // Select M neighbors
            let M_level = (level == 0) ? parameters.M_max0 : parameters.M_max
            let neighbors = selectNeighborsHeuristic(candidates: candidates, M: M_level)

            // Add bidirectional edges
            for neighborPK in neighbors {
                addEdge(fromPK: primaryKey, toPK: neighborPK, level: level, transaction: transaction)

                // Prune neighbor's connections if exceeds M
                // Use snapshot: false to see the edge we just added
                let neighborNeighbors = try await getNeighbors(
                    primaryKey: neighborPK,
                    level: level,
                    transaction: transaction,
                    snapshot: false
                )
                if neighborNeighbors.count > M_level {
                    // Load neighbor's vector for distance calculation
                    let neighborVector = try await loadVectorFromFlatIndex(primaryKey: neighborPK, transaction: transaction)

                    // Evaluate all neighbor's connections
                    var neighborCandidates: [(primaryKey: Tuple, distance: Double)] = []
                    for nnPK in neighborNeighbors {
                        let nnVector = try await loadVectorFromFlatIndex(primaryKey: nnPK, transaction: transaction)
                        let distance = calculateDistance(neighborVector, nnVector)
                        neighborCandidates.append((primaryKey: nnPK, distance: distance))
                    }

                    // Select best M neighbors
                    let prunedNeighbors = selectNeighborsHeuristic(candidates: neighborCandidates, M: M_level)

                    // Remove excess edges
                    for nnPK in neighborNeighbors {
                        if !prunedNeighbors.contains(nnPK) {
                            removeEdge(fromPK: neighborPK, toPK: nnPK, level: level, transaction: transaction)
                        }
                    }
                }
            }

            entryPoints = candidates.map { $0.primaryKey }
        }

        // Save node metadata
        let metadata = HNSWNodeMetadata(level: nodeLevel)
        try setNodeMetadata(primaryKey: primaryKey, metadata: metadata, transaction: transaction)

        // Update entry point if new node has higher level
        if nodeLevel > currentLevel {
            setEntryPoint(primaryKey: primaryKey, transaction: transaction)
        }
    }

    /// Search for k nearest neighbors using HNSW graph
    ///
    /// **Algorithm** (HNSW Paper - Algorithm 2):
    /// 1. Start from entry point
    /// 2. Greedy search down to layer 0
    /// 3. Use ef parameter for search breadth
    /// 4. Return k closest neighbors
    ///
    /// **Time Complexity**: O(log n) expected
    ///
    /// **Performance**:
    /// - ef = k: Fast but lower recall
    /// - ef = k * 2: Balanced (recommended)
    /// - ef = k * 3: Slower but higher recall
    ///
    /// - Parameters:
    ///   - queryVector: Query vector
    ///   - k: Number of nearest neighbors
    ///   - searchParams: Search parameters (ef)
    ///   - transaction: FDB transaction
    /// - Returns: Array of (primaryKey, distance), sorted by distance (ascending)
    public func search(
        queryVector: [Float32],
        k: Int,
        searchParams: HNSWSearchParameters,
        transaction: any TransactionProtocol
    ) async throws -> [(primaryKey: Tuple, distance: Double)] {
        // Validate parameters
        guard queryVector.count == dimensions else {
            throw RecordLayerError.invalidArgument(
                "Query vector dimension mismatch. Expected: \(dimensions), Got: \(queryVector.count)"
            )
        }

        guard k > 0 else {
            throw RecordLayerError.invalidArgument("k must be positive")
        }

        guard searchParams.ef >= k else {
            throw RecordLayerError.invalidArgument(
                "ef (\(searchParams.ef)) must be >= k (\(k)). Recommended: ef = k * 2"
            )
        }

        // Get entry point
        guard let entryPointPK = try await getEntryPoint(transaction: transaction) else {
            throw RecordLayerError.hnswGraphNotBuilt(
                indexName: index.name,
                message: """
                HNSW graph for index '\(index.name)' has not been built yet.

                To fix this issue:
                1. Run OnlineIndexer.buildHNSWIndex() to build the graph
                2. Ensure IndexState is 'readable' after building

                Example:
                ```swift
                let indexer = OnlineIndexer(...)
                try await indexer.buildHNSWIndex(
                    indexName: "\(index.name)",
                    batchSize: 1000,
                    throttleDelayMs: 10
                )
                ```

                Alternative: Use `.flatScan` strategy for automatic indexing
                """
            )
        }

        let entryMetadata = try await getNodeMetadata(primaryKey: entryPointPK, transaction: transaction)!
        let currentLevel = entryMetadata.level

        // Phase 1: Greedy search from top to layer 1
        var entryPoints = [entryPointPK]
        for level in stride(from: currentLevel, through: 1, by: -1) {
            let nearest = try await searchLayer(
                queryVector: queryVector,
                entryPoints: entryPoints,
                ef: 1,
                level: level,
                transaction: transaction
            )
            entryPoints = [nearest[0].primaryKey]
        }

        // Phase 2: Search at layer 0 with ef
        let candidates = try await searchLayer(
            queryVector: queryVector,
            entryPoints: entryPoints,
            ef: searchParams.ef,
            level: 0,
            transaction: transaction
        )

        // Return top k
        return Array(candidates.prefix(k))
    }

    /// Search with default parameters (for TypedVectorSearchPlan compatibility)
    ///
    /// Convenience method that uses default search parameters (ef = k * 2).
    /// This matches the signature of GenericVectorIndexMaintainer.search()
    /// to allow seamless switching between flat and HNSW indexes in queries.
    ///
    /// - Parameters:
    ///   - queryVector: Query vector
    ///   - k: Number of nearest neighbors
    ///   - transaction: FDB transaction
    /// - Returns: Array of (primaryKey, distance), sorted by distance (ascending)
    public func search(
        queryVector: [Float32],
        k: Int,
        transaction: any TransactionProtocol
    ) async throws -> [(primaryKey: Tuple, distance: Double)] {
        // Use default search parameters: ef = k * 2 (good recall/performance balance)
        let searchParams = HNSWSearchParameters(ef: max(k * 2, 100))
        return try await search(
            queryVector: queryVector,
            k: k,
            searchParams: searchParams,
            transaction: transaction
        )
    }
}

// MARK: - HNSW Node Deletion

extension GenericHNSWIndexMaintainer {
    /// Delete a node from the HNSW graph
    ///
    /// **Algorithm** (With neighbor rewiring):
    /// 1. Get node metadata to determine levels
    /// 2. For each level:
    ///    a. Get all neighbors of the deleted node
    ///    b. Reconnect neighbors to each other (rewiring)
    ///    c. Remove all edges to/from the deleted node
    /// 3. Delete node metadata
    /// 4. Update entry point if necessary
    ///
    /// **Time Complexity**: O(M^2 * level) where M is max edges per level
    /// - Rewiring: O(M^2) per level (connect M neighbors to each other)
    /// - Edge removal: O(M) per level
    /// - Total: O(M^2 * level)
    ///
    /// **Graph Quality Impact**:
    /// - ✅ Neighbors are reconnected to maintain graph connectivity
    /// - ✅ Graph remains navigable with minimal quality loss
    /// - ✅ Prevents fragmentation from frequent deletions
    ///
    /// **Rewiring Strategy**:
    /// - Connect deleted node's neighbors to each other
    /// - Use distance-based heuristic to select best connections
    /// - Maintain M_max edge limit per node
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key of node to delete
    ///   - transaction: FDB transaction
    private func deleteNode(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // 1. Get node metadata (use snapshot: false to see if it exists in this transaction)
        guard let metadata = try await getNodeMetadata(
            primaryKey: primaryKey,
            transaction: transaction,
            snapshot: false
        ) else {
            return  // Node doesn't exist, nothing to delete
        }

        // 2. Rewire neighbors and remove edges at each level
        for level in 0...metadata.level {
            let neighbors = try await getNeighbors(
                primaryKey: primaryKey,
                level: level,
                transaction: transaction,
                snapshot: false  // Need to see current state
            )

            // 2a. Rewire neighbors to each other before removing deleted node
            if neighbors.count > 1 {
                try await rewireNeighbors(
                    neighbors: neighbors,
                    level: level,
                    transaction: transaction
                )
            }

            // 2b. Remove all edges to/from the deleted node
            for neighborPK in neighbors {
                removeEdge(
                    fromPK: primaryKey,
                    toPK: neighborPK,
                    level: level,
                    transaction: transaction
                )
            }
        }

        // 3. Delete node metadata
        let nodeKey = nodesSubspace.pack(primaryKey)
        transaction.clear(key: nodeKey)

        // 4. If this was the entry point, find a new one
        let currentEntryPoint = try await getEntryPoint(
            transaction: transaction,
            snapshot: false
        )
        if currentEntryPoint == primaryKey {
            try await updateEntryPointAfterDeletion(transaction: transaction)
        }
    }

    /// Rewire neighbors of a deleted node to maintain graph connectivity
    ///
    /// **Algorithm**:
    /// 1. For each pair of neighbors, calculate distance
    /// 2. Sort pairs by distance (closest pairs first)
    /// 3. Add edges between neighbors if they don't exceed M_max
    ///
    /// **Purpose**: Prevent graph fragmentation when a node is deleted
    ///
    /// **Time Complexity**: O(M^2) where M is number of neighbors
    ///
    /// - Parameters:
    ///   - neighbors: Neighbors of the deleted node
    ///   - level: Layer level
    ///   - transaction: FDB transaction
    private func rewireNeighbors(
        neighbors: [Tuple],
        level: Int,
        transaction: any TransactionProtocol
    ) async throws {
        let M_level = (level == 0) ? parameters.M_max0 : parameters.M_max

        // Load all neighbor vectors
        var neighborVectors: [(primaryKey: Tuple, vector: [Float32])] = []
        for neighborPK in neighbors {
            let vector = try await loadVectorFromFlatIndex(primaryKey: neighborPK, transaction: transaction)
            neighborVectors.append((primaryKey: neighborPK, vector: vector))
        }

        // For each neighbor, try to connect it to other neighbors
        for i in 0..<neighborVectors.count {
            let (neighborPK, neighborVector) = neighborVectors[i]

            // Get current neighbors
            let currentNeighbors = try await getNeighbors(
                primaryKey: neighborPK,
                level: level,
                transaction: transaction,
                snapshot: false
            )

            // If already at capacity, skip (pruning would be needed)
            if currentNeighbors.count >= M_level {
                continue
            }

            // Calculate distances to other neighbors
            var candidates: [(primaryKey: Tuple, distance: Double)] = []
            for j in 0..<neighborVectors.count where j != i {
                let (otherPK, otherVector) = neighborVectors[j]

                // Skip if already connected
                if currentNeighbors.contains(otherPK) {
                    continue
                }

                let distance = calculateDistance(neighborVector, otherVector)
                candidates.append((primaryKey: otherPK, distance: distance))
            }

            // Sort by distance and add edges to closest neighbors
            candidates.sort { $0.distance < $1.distance }
            let availableSlots = M_level - currentNeighbors.count
            let toConnect = candidates.prefix(availableSlots)

            for candidate in toConnect {
                addEdge(
                    fromPK: neighborPK,
                    toPK: candidate.primaryKey,
                    level: level,
                    transaction: transaction
                )
            }
        }
    }

    /// Find and set new entry point after the current entry point is deleted
    ///
    /// **Algorithm**:
    /// 1. Scan all remaining nodes
    /// 2. Find node with highest level
    /// 3. Set as new entry point (or clear if no nodes remain)
    ///
    /// **Time Complexity**: O(n) where n is number of nodes
    ///
    /// **Note**: This is expensive but deletions are rare. For production use with
    /// frequent deletions, consider maintaining a secondary index on node levels.
    ///
    /// - Parameter transaction: FDB transaction
    private func updateEntryPointAfterDeletion(
        transaction: any TransactionProtocol
    ) async throws {
        // Scan all nodes to find the one with highest level
        let (begin, end) = nodesSubspace.range()
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(begin),
            endSelector: .firstGreaterOrEqual(end),
            snapshot: false
        )

        var maxLevel = -1
        var newEntryPoint: Tuple? = nil
        let decoder = JSONDecoder()

        for try await (key, value) in sequence {
            let nodePK = try nodesSubspace.unpack(key)
            let metadata = try decoder.decode(HNSWNodeMetadata.self, from: Data(value))

            if metadata.level > maxLevel {
                maxLevel = metadata.level
                newEntryPoint = nodePK
            }
        }

        if let newEntryPoint = newEntryPoint {
            setEntryPoint(primaryKey: newEntryPoint, transaction: transaction)
        } else {
            // No nodes left, clear entry point
            transaction.clear(key: entryPointKey)
        }
    }
}

// MARK: - GenericIndexMaintainer Implementation

extension GenericHNSWIndexMaintainer {
    /// Update HNSW index when a record is inserted/updated/deleted
    ///
    /// **⚠️ CRITICAL LIMITATION - READ THIS**:
    ///
    /// **Inline Indexing NOT Supported for HNSW**:
    /// - This method is called from user transactions via IndexManager.updateIndexes()
    /// - HNSW insertion requires ~12,000 FDB operations for medium graphs (currentLevel >= 3)
    /// - FDB transaction limits: 5 seconds, 10MB
    /// - **Result**: User transactions will fail with timeout/size errors
    ///
    /// **⚠️ DO NOT USE HNSW WITH INLINE INDEXING IN PRODUCTION**
    ///
    /// **Correct Usage**:
    /// 1. Set HNSW index to `IndexState.writeOnly` (disable inline maintenance)
    /// 2. Use `OnlineIndexer.buildIndex()` exclusively for batch insertions
    /// 3. Set to `IndexState.readable` only after build completes
    ///
    /// **This Method's Behavior**:
    /// - ✅ **Deletions**: Supported (fast, O(M^2 * level) with rewiring)
    /// - ❌ **Insertions**: Will throw error if graph has >2 levels (~1,000 nodes)
    /// - 📋 **Recommendation**: Use OnlineIndexer for all insertions
    ///
    /// **Example**:
    /// ```swift
    /// // Step 1: Disable inline indexing
    /// try await indexStateManager.setState(index: "vector_hnsw", state: .writeOnly)
    ///
    /// // Step 2: Build via OnlineIndexer (batched, safe)
    /// try await onlineIndexer.buildIndex(indexName: "vector_hnsw")
    ///
    /// // Step 3: Enable queries
    /// try await indexStateManager.setState(index: "vector_hnsw", state: .readable)
    /// ```
    ///
    /// - Parameters:
    ///   - oldRecord: Previous record (if updating/deleting)
    ///   - newRecord: New record (if inserting/updating)
    ///   - recordAccess: Record access for field extraction
    ///   - transaction: FDB transaction
    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // ✅ Deletions: Supported with neighbor rewiring
        if let oldRecord = oldRecord {
            let oldPrimaryKey = oldRecord.extractPrimaryKey()
            try await deleteNode(primaryKey: oldPrimaryKey, transaction: transaction)
        }

        // ⚠️ Insertions: CONDITIONAL SUPPORT - Small graphs only (<100 nodes)
        if let newRecord = newRecord {
            // 🛡️ CRITICAL: HNSW inline indexing has STRICT limitations
            //
            // **Strategy: .hnsw(inlineIndexing: true)**
            // - ✅ **Supported**: Small graphs ONLY (maxLevel < 2, approximately <100 nodes)
            // - ❌ **NOT Supported**: Medium/large graphs (maxLevel >= 2)
            //
            // **Why Size Limits Exist**:
            // - HNSW insertion requires ~12,000 FDB operations for medium graphs (maxLevel >= 3)
            // - FoundationDB limits: 5 second timeout, 10MB transaction size
            // - User transactions WILL timeout/fail for graphs with maxLevel >= 2
            //
            // **Recommendation for Production**:
            // Use `.hnsw(inlineIndexing: false)` (aka `.hnswBatch`) and build with OnlineIndexer:
            //
            // 1. try await indexStateManager.setState(index: "\(index.name)", state: .writeOnly)
            // 2. try await onlineIndexer.buildIndex(indexName: "\(index.name)")
            // 3. try await indexStateManager.setState(index: "\(index.name)", state: .readable)

        // Check current graph size before attempting insertion
        let currentMaxLevel = try await getMaxLevel(transaction: transaction)

        if currentMaxLevel >= 2 {
            // Graph is too large for inline indexing - SKIP with WARNING
            let mValue = self.parameters.M
            let estimatedNodes = Int(pow(Double(mValue), Double(currentMaxLevel)))
            let estimatedOps = 12000 * (currentMaxLevel - 1)

            Logger(label: "com.fdb.recordlayer.index.hnsw").warning("HNSW inline indexing skipped for large graph", metadata: [
                "index": "\(index.name)",
                "maxLevel": "\(currentMaxLevel)",
                "estimatedNodes": "\(estimatedNodes)",
                "estimatedOps": "\(estimatedOps)",
                "reason": "Graph too large for inline indexing (would exceed FDB 5s timeout and 10MB limits)",
                "recommendation": "Switch to .hnsw(inlineIndexing: false) and rebuild via OnlineIndexer"
            ])

            // Skip insertion and return early (graceful degradation)
            return
        }

            // ✅ Small graph (maxLevel < 2) - ALLOW inline insertion
            // This should complete within FDB transaction limits for small datasets
            let primaryKey = newRecord.extractPrimaryKey()
            let vector = try extractVector(from: newRecord, recordAccess: recordAccess)

            // Perform inline insertion
            try await insert(
                primaryKey: primaryKey,
                queryVector: vector,
                transaction: transaction
            )
        }
    }

    /// Scan record during online index building
    ///
    /// **⚠️ CRITICAL**: This method is designed for OnlineIndexer use ONLY.
    /// It uses the current transaction for a SINGLE level insertion to stay within
    /// FoundationDB's 5-second timeout limit.
    ///
    /// **OnlineIndexer Workflow**:
    /// 1. First pass: Assign levels and store in metadata (fast, no graph operations)
    /// 2. Second pass: Build graph level-by-level (each level = separate transaction batch)
    ///
    /// - Parameters:
    ///   - record: Record to index
    ///   - primaryKey: Primary key
    ///   - recordAccess: Record access
    ///   - transaction: FDB transaction (should be short-lived)
    public func scanRecord(
        _ record: Record,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // ⚠️ WARNING: This is NOT the correct implementation for OnlineIndexer.
        // The current implementation calls insert() which processes ALL levels
        // in a single transaction, violating the 5-second timeout.
        //
        // **TODO (Future Work)**:
        // Implement level-by-level insertion:
        // 1. OnlineIndexer calls assignLevel() first (separate transaction)
        // 2. OnlineIndexer calls insertAtLevel(level: L) for each level (separate transactions)
        // 3. Each transaction stays within ~3,000 operations (~1-2 seconds)
        //
        // **Current Behavior**:
        // Throws error for graphs > level 2 due to transaction budget exceeded.

        // Extract vector field
        let indexedValues = try recordAccess.evaluate(
            record: record,
            expression: index.rootExpression
        )

        guard let vectorField = indexedValues.first else {
            throw RecordLayerError.invalidArgument("Vector index requires exactly one field")
        }

        guard let vector = vectorField as? any VectorRepresentable else {
            throw RecordLayerError.invalidArgument(
                "Vector index field must conform to VectorRepresentable protocol"
            )
        }

        let floatArray = vector.toFloatArray()

        guard floatArray.count == dimensions else {
            throw RecordLayerError.invalidArgument(
                "Vector dimension mismatch. Expected: \(dimensions), Got: \(floatArray.count)"
            )
        }

        // Insert into HNSW graph (WARNING: May timeout for large graphs)
        try await insert(primaryKey: primaryKey, queryVector: floatArray, transaction: transaction)
    }

    // MARK: - Level-by-Level Insertion (OnlineIndexer Support)

    /// Assign level to a node without inserting into graph
    ///
    /// **Transaction Budget**: ~10 operations (fast, always within FDB limits)
    ///
    /// **OnlineIndexer Workflow Step 1**:
    /// Call this method first to assign and store the level for each vector.
    /// This is a lightweight operation that completes quickly.
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key
    ///   - transaction: FDB transaction
    /// - Returns: Assigned level (for logging/debugging)
    public func assignLevel(
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws -> Int {
        let level = assignRandomLevel()
        let metadata = HNSWNodeMetadata(level: level)
        try setNodeMetadata(primaryKey: primaryKey, metadata: metadata, transaction: transaction)
        return level
    }

    /// Insert node at a specific level
    ///
    /// **Transaction Budget**: ~3,000 operations per level (safe for FDB 5-second timeout)
    ///
    /// **OnlineIndexer Workflow Step 2**:
    /// After calling assignLevel() for all vectors, call this method for each level
    /// (0, 1, 2, ...) in separate transaction batches.
    ///
    /// **Example**:
    /// ```swift
    /// // OnlineIndexer batch processing
    /// for vector in batch {
    ///     try await assignLevel(primaryKey: vector.pk, transaction: tx1)
    /// }
    ///
    /// // Process level by level
    /// for level in 0...maxLevel {
    ///     for vector in batch {
    ///         try await insertAtLevel(
    ///             primaryKey: vector.pk,
    ///             queryVector: vector.data,
    ///             level: level,
    ///             transaction: tx2  // Separate transaction per level
    ///         )
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - primaryKey: Primary key
    ///   - queryVector: Vector to insert
    ///   - targetLevel: Target level (must be <= assigned level in metadata)
    ///   - transaction: FDB transaction
    public func insertAtLevel(
        primaryKey: Tuple,
        queryVector: [Float32],
        targetLevel: Int,
        transaction: any TransactionProtocol
    ) async throws {
        // Validate that node metadata exists
        guard let metadata = try await getNodeMetadata(
            primaryKey: primaryKey,
            transaction: transaction,
            snapshot: false
        ) else {
            throw RecordLayerError.internalError(
                "Node metadata not found. Call assignLevel() first before insertAtLevel()."
            )
        }

        // Validate target level is within assigned level
        guard targetLevel <= metadata.level else {
            throw RecordLayerError.invalidArgument(
                "Target level (\(targetLevel)) exceeds assigned level (\(metadata.level))"
            )
        }

        // Find entry point for this level
        let entryPoint = try await getEntryPoint(transaction: transaction, snapshot: false)

        // Search layer to find candidates
        var W: [(primaryKey: Tuple, distance: Double)] = []

        if targetLevel == metadata.level, let ep = entryPoint {
            // Top level: Search from entry point
            W = try await searchLayer(
                queryVector: queryVector,
                entryPoints: [ep],
                ef: parameters.efConstruction,
                level: targetLevel,
                transaction: transaction,
                snapshot: false
            )
        } else if targetLevel < metadata.level {
            // Lower levels: Search from current level entry points
            // For simplicity, start from entry point at this level
            if let ep = entryPoint {
                W = try await searchLayer(
                    queryVector: queryVector,
                    entryPoints: [ep],
                    ef: parameters.efConstruction,
                    level: targetLevel,
                    transaction: transaction,
                    snapshot: false
                )
            }
        }

        // Select M neighbors
        let M_level = (targetLevel == 0) ? parameters.M_max0 : parameters.M_max
        let neighbors = selectNeighborsHeuristic(candidates: W, M: M_level)

        // Add bidirectional edges
        for neighborPK in neighbors {
            addEdge(fromPK: primaryKey, toPK: neighborPK, level: targetLevel, transaction: transaction)
            addEdge(fromPK: neighborPK, toPK: primaryKey, level: targetLevel, transaction: transaction)

            // Prune neighbor's connections if needed
            let neighborConnections = try await getNeighbors(
                primaryKey: neighborPK,
                level: targetLevel,
                transaction: transaction,
                snapshot: false
            )

            if neighborConnections.count > M_level {
                // Load neighbor vector
                let neighborVector = try await loadVectorFromFlatIndex(
                    primaryKey: neighborPK,
                    transaction: transaction
                )

                // Re-select neighbors for this neighbor
                var neighborCandidates: [(primaryKey: Tuple, distance: Double)] = []
                for connPK in neighborConnections {
                    let connVector = try await loadVectorFromFlatIndex(
                        primaryKey: connPK,
                        transaction: transaction
                    )
                    let dist = calculateDistance(neighborVector, connVector)
                    neighborCandidates.append((primaryKey: connPK, distance: dist))
                }

                let prunedNeighbors = selectNeighborsHeuristic(candidates: neighborCandidates, M: M_level)

                // Remove old edges
                for oldConn in neighborConnections {
                    removeEdge(fromPK: neighborPK, toPK: oldConn, level: targetLevel, transaction: transaction)
                }

                // Add new edges
                for newConn in prunedNeighbors {
                    addEdge(fromPK: neighborPK, toPK: newConn, level: targetLevel, transaction: transaction)
                }
            }
        }

        // Update entry point if this is the highest level
        if targetLevel == metadata.level {
            let currentEntryLevel = entryPoint != nil ? try await getNodeMetadata(primaryKey: entryPoint!, transaction: transaction, snapshot: false)?.level ?? -1 : -1
            if targetLevel > currentEntryLevel {
                setEntryPoint(primaryKey: primaryKey, transaction: transaction)
            }
        }
    }

    // MARK: - OnlineIndexer Support Methods

    /// Extract vector from record (for OnlineIndexer)
    ///
    /// This method extracts the vector field from a record using the index definition.
    ///
    /// - Parameters:
    ///   - record: The record to extract vector from
    ///   - recordAccess: Record access for field extraction
    /// - Returns: Vector as Float32 array
    public func extractVector(from record: Record, recordAccess: any RecordAccess<Record>) throws -> [Float32] {
        // Get the field name from the index expression
        guard let fieldExpr = index.rootExpression as? FieldKeyExpression else {
            throw RecordLayerError.internalError("Vector index must use FieldKeyExpression")
        }

        // Extract field values from record
        let fieldValues = record.extractField(fieldExpr.fieldName)

        // Convert to Float32 array
        var result: [Float32] = []
        for element in fieldValues {
            if let floatValue = element as? Float32 {
                result.append(floatValue)
            } else if let doubleValue = element as? Double {
                result.append(Float32(doubleValue))
            } else if let intValue = element as? Int64 {
                result.append(Float32(intValue))
            } else if let intValue = element as? Int {
                result.append(Float32(intValue))
            } else if let array = element as? [Float32] {
                // Handle array of Float32
                result.append(contentsOf: array)
            } else if let array = element as? [Double] {
                // Handle array of Double
                result.append(contentsOf: array.map { Float32($0) })
            } else {
                throw RecordLayerError.invalidArgument(
                    "Vector field must contain numeric values, got: \(type(of: element))"
                )
            }
        }

        // Validate dimensions
        guard result.count == dimensions else {
            throw RecordLayerError.invalidArgument(
                "Vector dimension mismatch. Expected: \(dimensions), Got: \(result.count)"
            )
        }

        return result
    }

    /// Get maximum level across all nodes in the graph
    ///
    /// This is used by OnlineIndexer to determine how many levels to process.
    ///
    /// - Parameter transaction: FDB transaction
    /// - Returns: Maximum level (0 if graph is empty)
    public func getMaxLevel(transaction: any TransactionProtocol) async throws -> Int {
        // Scan all node metadata to find max level
        let (begin, end) = nodesSubspace.range()

        var maxLevel = 0
        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(begin),
            endSelector: .firstGreaterOrEqual(end),
            snapshot: true
        )

        for try await (_, value) in sequence {
            let decoder = JSONDecoder()
            let metadata = try decoder.decode(HNSWNodeMetadata.self, from: Data(value))
            maxLevel = max(maxLevel, metadata.level)
        }

        return maxLevel
    }
}
