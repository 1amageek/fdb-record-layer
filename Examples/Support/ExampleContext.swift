// ExampleContext.swift
// Common setup and teardown logic for all examples

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

/// Provides common infrastructure for examples with automatic cleanup
public final class ExampleContext<Record: Recordable> {
    public let config: ExampleConfig
    public let database: any DatabaseProtocol
    public let subspace: Subspace
    public let schema: Schema
    public let store: RecordStore<Record>

    /// Initialize example with automatic setup
    /// - Parameters:
    ///   - name: Example name (used for subspace prefix)
    ///   - recordType: Record type
    ///   - config: Configuration (uses default if not provided)
    ///   - additionalIndexes: Additional indexes beyond those defined in @Recordable
    public init(
        name: String,
        recordType: Record.Type,
        config: ExampleConfig = .default,
        additionalIndexes: [Index] = []
    ) async throws {
        self.config = config

        // Print configuration
        config.printConfig()

        // 1. Initialize FDB Network
        print("🔧 Initializing FoundationDB...")
        try FDBNetwork.shared.initialize(version: config.apiVersion)

        // 2. Open database with cluster file
        print("🔌 Connecting to database...")
        self.database = try FDBClient.openDatabase(clusterFilePath: config.clusterFilePath)
        print("✅ Connected to FoundationDB cluster")

        // 3. Create isolated subspace using run ID
        let prefix = Tuple("examples", name, config.runID).pack()
        self.subspace = Subspace(prefix: prefix)
        print("📁 Subspace: examples/\(name)/\(config.runID)")

        // 4. Create schema
        var allIndexes = Record.indexDefinitions
        allIndexes.append(contentsOf: additionalIndexes)
        self.schema = Schema([Record.self], indexes: allIndexes)

        // 5. Create RecordStore
        self.store = RecordStore<Record>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )
        print("✅ RecordStore initialized")
        print()
    }

    /// Clean up data (called automatically if config.cleanup = true)
    public func cleanup() async throws {
        guard config.cleanup else {
            print("⏭️  Cleanup skipped (EXAMPLE_CLEANUP=false)")
            return
        }

        print("\n🧹 Cleaning up example data...")

        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }

        print("✅ Cleanup complete")
    }

    /// Run example with automatic cleanup
    public func run(_ block: (RecordStore<Record>) async throws -> Void) async throws {
        do {
            try await block(store)
        } catch {
            print("\n❌ Example failed: \(error)")
            throw error
        }

        // Cleanup
        try await cleanup()
    }
}

/// Extension for HNSW-specific cleanup and rebuild
public extension ExampleContext {
    /// Completely rebuild an HNSW index from scratch with health tracker reset
    ///
    /// This method ensures the HNSW index can be built repeatedly by following
    /// the proper state machine and resetting the circuit breaker.
    ///
    /// **State Machine Flow**:
    /// 1. Check current state
    /// 2. Disable index (Any state → DISABLED)
    /// 3. Clear index data
    /// 4. Clear RangeSet (progress tracking)
    /// 5. Build index (DISABLED → WRITE_ONLY → READABLE)
    /// 6. Reset health tracker (circuit breaker)
    ///
    /// **Why This is Necessary**:
    /// - `buildHNSWIndex()` fails if index already exists
    /// - Manual `fdbcli` cleanup is error-prone and not reproducible
    /// - Examples need to run multiple times without manual intervention
    /// - Health tracker prevents repeated errors from same issue
    ///
    /// **Usage**:
    /// ```swift
    /// let context = try await ExampleContext(name: "VectorSearch", recordType: Product.self)
    ///
    /// try await context.run { store in
    ///     // Insert records
    ///     try await store.save(products)
    ///
    ///     // Rebuild HNSW index (safe for multiple runs)
    ///     try await context.rebuildHNSWIndex(indexName: "product_embedding_hnsw")
    ///
    ///     // Query using HNSW
    ///     let results = try await store.query(Product.self)
    ///         .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
    ///         .execute()
    /// }
    /// ```
    ///
    /// - Parameter indexName: Name of the HNSW vector index
    /// - Throws: RecordLayerError if index is not a vector index
    func rebuildHNSWIndex(indexName: String) async throws {
        print("🔄 Rebuilding HNSW index '\(indexName)' from scratch...")

        let indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace.subspace("state")
        )

        // Step 1: Check current state (for logging)
        let currentState = try await indexStateManager.state(of: indexName)
        print("   Current state: \(currentState)")

        // Step 2: Disable index (Any state → DISABLED)
        if currentState != .disabled {
            try await indexStateManager.disable(indexName)
            print("   ✅ Disabled index")
        }

        // Step 3: Clear index data
        let indexSubspace = subspace.subspace("indexes").subspace(indexName)
        try await database.withTransaction { transaction in
            let (begin, end) = indexSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
        print("   ✅ Cleared index data")

        // Step 4: Clear RangeSet (progress tracking)
        let rangeSetSubspace = subspace.subspace("rangeSet").subspace(indexName)
        try await database.withTransaction { transaction in
            let (begin, end) = rangeSetSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
        print("   ✅ Cleared progress tracking")

        // Step 5: Build index using OnlineIndexer
        // OnlineIndexer.buildIndex() handles the state machine:
        //   - enable() → DISABLED → WRITE_ONLY
        //   - buildHNSWIndex() → constructs graph
        //   - makeReadable() → WRITE_ONLY → READABLE
        print("   🔨 Building HNSW graph (this may take a few seconds)...")

        let onlineIndexer = OnlineIndexer(
            store: store,
            indexName: indexName,
            batchSize: 100,
            throttleDelayMs: 10
        )

        try await onlineIndexer.buildIndex()

        // Step 6: Reset health tracker
        hnswHealthTracker.reset(indexName: indexName)

        // Verify final state
        let finalState = try await indexStateManager.state(of: indexName)
        print("   ✅ Index state: \(finalState)")
        print("   ✅ Health tracker reset")
        print("✅ HNSW index rebuild complete")
    }

    /// Quick cleanup for HNSW index (disable + clear data only, no rebuild)
    ///
    /// Use this if you want to manually control the rebuild process.
    /// Most users should use `rebuildHNSWIndex()` instead.
    ///
    /// - Parameter indexName: Name of the HNSW vector index
    func cleanupHNSWIndex(indexName: String) async throws {
        print("🧹 Cleaning up HNSW index '\(indexName)'...")

        let indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace.subspace("state")
        )

        // 1. Disable index
        try await indexStateManager.disable(indexName)

        // 2. Clear index data
        let indexSubspace = subspace.subspace("indexes").subspace(indexName)
        try await database.withTransaction { transaction in
            let (begin, end) = indexSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }

        // 3. Clear RangeSet (progress tracking)
        let rangeSetSubspace = subspace.subspace("rangeSet").subspace(indexName)
        try await database.withTransaction { transaction in
            let (begin, end) = rangeSetSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }

        print("✅ HNSW index cleanup complete (index is now DISABLED)")
        print("💡 Call OnlineIndexer.buildIndex() to rebuild the index")
    }

    /// Check HNSW health status and print diagnostics
    ///
    /// - Parameter indexName: Name of the HNSW vector index
    func checkHNSWHealth(indexName: String) {
        let info = hnswHealthTracker.getHealthInfo(indexName: indexName)
        print("📊 HNSW Health Status for '\(indexName)':")
        print(info)
    }
}
