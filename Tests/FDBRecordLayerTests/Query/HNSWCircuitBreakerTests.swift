// HNSWCircuitBreakerTests.swift
// Integration tests for HNSW circuit breaker using real state manipulation

import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordCore
@testable import FDBRecordLayer

@Suite("HNSW Circuit Breaker Integration Tests", .tags(.integration))
struct HNSWCircuitBreakerTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Test Model

    @Recordable
    struct TestProduct {
        #PrimaryKey<TestProduct>([\.id])

        var id: Int64
        var name: String
        var embedding: [Float32]
    }

    // MARK: - Helper Methods

    private func createTestEnvironment() async throws -> (
        database: any DatabaseProtocol,
        subspace: Subspace,
        store: RecordStore<TestProduct>
    ) {
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_circuit_breaker_\(UUID().uuidString)".utf8))

        // Create vector index manually
        let vectorIndex = Index(
            name: "test_product_embedding",
            type: .vector,
            rootExpression: FieldKeyExpression(fieldName: "embedding"),
            recordTypes: Set(["TestProduct"]),
            options: IndexOptions(vectorOptions: VectorIndexOptions(dimensions: 128, metric: .cosine))
        )

        // Create schema with .hnswBatch strategy
        let schema = Schema(
            [TestProduct.self],
            indexes: [vectorIndex],
            indexConfigurations: [
                IndexConfiguration(
                    indexName: "test_product_embedding",
                    vectorStrategy: .hnswBatch
                )
            ]
        )

        let store = RecordStore<TestProduct>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        return (database, subspace, store)
    }

    private func cleanup(database: any DatabaseProtocol, subspace: Subspace) async throws {
        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    private func rebuildHNSWIndex(
        indexName: String,
        store: RecordStore<TestProduct>,
        database: any DatabaseProtocol,
        subspace: Subspace
    ) async throws {
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )

        // Disable index
        let currentState = try await indexStateManager.state(of: indexName)
        if currentState != .disabled {
            try await indexStateManager.disable(indexName)
        }

        // Clear index data
        let indexSubspace = subspace.subspace("I").subspace(indexName)
        try await database.withTransaction { transaction in
            let (begin, end) = indexSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }

        // Clear RangeSet
        let rangeSetSubspace = subspace.subspace("rangeSet").subspace(indexName)
        try await database.withTransaction { transaction in
            let (begin, end) = rangeSetSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }

        // Build index
        guard let index = store.schema.indexes(for: TestProduct.recordName).first(where: { $0.name == indexName }) else {
            throw RecordLayerError.indexNotFound("Index '\(indexName)' not found")
        }

        let recordAccess = GenericRecordAccess<TestProduct>()
        let onlineIndexer = OnlineIndexer<TestProduct>(
            database: database,
            subspace: subspace,
            schema: store.schema,
            entityName: TestProduct.recordName,
            index: index,
            recordAccess: recordAccess,
            indexStateManager: indexStateManager,
            batchSize: 100,
            throttleDelayMs: 10
        )

        try await onlineIndexer.buildIndex()

        // Reset health tracker
        hnswHealthTracker.reset(indexName: indexName)
    }

    private func randomEmbedding(dimensions: Int = 128) -> [Float32] {
        return (0..<dimensions).map { _ in Float32.random(in: -1...1) }
    }

    // MARK: - Tests

    @Test("Disabled index triggers circuit breaker")
    func testDisabledIndexTriggersCircuitBreaker() async throws {
        let (database, subspace, store) = try await createTestEnvironment()

        // 1. Insert test data
        let products = [
            TestProduct(id: 1, name: "Product 1", embedding: randomEmbedding()),
            TestProduct(id: 2, name: "Product 2", embedding: randomEmbedding()),
            TestProduct(id: 3, name: "Product 3", embedding: randomEmbedding())
        ]

        for product in products {
            try await store.save(product)
        }

        // 2. Build HNSW index
        try await rebuildHNSWIndex(
            indexName: "test_product_embedding",
            store: store,
            database: database,
            subspace: subspace
        )

        // 3. Verify HNSW search works
        let queryVector = randomEmbedding()
        let results1 = try await store.query()
            .nearestNeighbors(k: 2, to: queryVector, using: \.embedding)
            .execute()

        #expect(results1.count == 2)

        // 4. Disable index (simulate failure)
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )
        try await indexStateManager.disable("test_product_embedding")

        // 5. Query again → circuit breaker should activate
        let results2 = try await store.query()
            .nearestNeighbors(k: 2, to: queryVector, using: \.embedding)
            .execute()

        // Still returns results (flat scan fallback)
        #expect(results2.count == 2)

        // 6. Verify circuit breaker state
        let (shouldUse, reason) = hnswHealthTracker.shouldUseHNSW(indexName: "test_product_embedding")
        #expect(shouldUse == false)
        #expect(reason != nil)
        #expect(reason?.contains("failed") == true)

        // Cleanup
        try await cleanup(database: database, subspace: subspace)
    }

    @Test("Rebuild index resets circuit breaker")
    func testRebuildResetsCircuitBreaker() async throws {
        let (database, subspace, store) = try await createTestEnvironment()

        // 1. Insert test data
        let product = TestProduct(id: 1, name: "Product 1", embedding: randomEmbedding())
        try await store.save(product)

        // 2. Build HNSW index
        try await rebuildHNSWIndex(
            indexName: "test_product_embedding",
            store: store,
            database: database,
            subspace: subspace
        )

        // 3. Disable index → trigger circuit breaker
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )
        try await indexStateManager.disable("test_product_embedding")

        // 4. Trigger circuit breaker
        let queryVector = randomEmbedding()
        let _ = try await store.query()
            .nearestNeighbors(k: 1, to: queryVector, using: \.embedding)
            .execute()

        // 5. Verify circuit breaker is active
        var (shouldUse, _) = hnswHealthTracker.shouldUseHNSW(indexName: "test_product_embedding")
        #expect(shouldUse == false)

        // 6. Rebuild index → should reset circuit breaker
        try await rebuildHNSWIndex(
            indexName: "test_product_embedding",
            store: store,
            database: database,
            subspace: subspace
        )

        // 7. Verify circuit breaker is reset
        (shouldUse, _) = hnswHealthTracker.shouldUseHNSW(indexName: "test_product_embedding")
        #expect(shouldUse == true)

        // 8. Query should use HNSW again
        let results = try await store.query()
            .nearestNeighbors(k: 1, to: queryVector, using: \.embedding)
            .execute()

        #expect(results.count == 1)

        // Cleanup
        try await cleanup(database: database, subspace: subspace)
    }

    @Test("Circuit breaker prevents repeated HNSW attempts")
    func testCircuitBreakerPreventsRepeatedAttempts() async throws {
        let (database, subspace, store) = try await createTestEnvironment()

        // 1. Insert test data
        let product = TestProduct(id: 1, name: "Product 1", embedding: randomEmbedding())
        try await store.save(product)

        // 2. Disable index
        let indexStateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )
        try await indexStateManager.disable("test_product_embedding")

        // 3. Clear health tracker
        hnswHealthTracker.reset(indexName: "test_product_embedding")

        let queryVector = randomEmbedding()

        // 4. First query → triggers error, records failure
        let _ = try await store.query()
            .nearestNeighbors(k: 1, to: queryVector, using: \.embedding)
            .execute()

        // 5. Check circuit breaker activated
        let (shouldUse1, _) = hnswHealthTracker.shouldUseHNSW(indexName: "test_product_embedding")
        #expect(shouldUse1 == false)

        // 6. Second query → circuit breaker prevents HNSW attempt
        let _ = try await store.query()
            .nearestNeighbors(k: 1, to: queryVector, using: \.embedding)
            .execute()

        // 7. Third query → circuit breaker still prevents HNSW
        let _ = try await store.query()
            .nearestNeighbors(k: 1, to: queryVector, using: \.embedding)
            .execute()

        // 8. Verify only 1 failure recorded (circuit breaker prevented retries)
        let info = hnswHealthTracker.getHealthInfo(indexName: "test_product_embedding")
        #expect(info.contains("Total failures: 1"))

        // Cleanup
        try await cleanup(database: database, subspace: subspace)
    }
}
