import Foundation
import Testing
@testable import FoundationDB
@testable import FDBRecordCore
@testable import FDBRecordLayer

/// HNSW Validation Tests
///
/// Tests for the HNSW validation fixes that ensure fail-fast behavior:
/// - Problem 1: HNSW graph non-existence throws explicit error
/// - Problem 4: IndexState checking throws explicit error
///
/// **Design Document**: docs/hnsw_validation_fix_design.md
@Suite("HNSW Validation Tests")
struct HNSWValidationTests {

    // MARK: - Test Model

    @Recordable
    struct Product {
        #PrimaryKey<Product>([\.productID])

        var productID: Int64
        var name: String
        var category: String
        var embedding: [Float32]
    }

    // MARK: - Helper Methods

    /// Initialize FDB network and open database
    private func setupDatabase() throws -> any DatabaseProtocol {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized - this is fine
        }
        return try FDBClient.openDatabase()
    }

    // MARK: - Test 1: HNSW Graph Not Built Error

    @Test("HNSW search throws error when graph not built")
    func testHNSWSearchGraphNotBuilt() async throws {
        // Setup FDB database
        let db = try setupDatabase()

        // Create vector index manually
        let vectorIndex = Index(
            name: "Product_embedding_index",
            type: .vector,
            rootExpression: FieldKeyExpression(fieldName: "embedding"),
            recordTypes: Set(["Product"]),
            options: IndexOptions(vectorOptions: VectorIndexOptions(dimensions: 128, metric: .cosine))
        )

        // Create schema with .hnswBatch strategy using indexConfigurations
        let schema = Schema(
            [Product.self],
            indexes: [vectorIndex],
            indexConfigurations: [
                IndexConfiguration(
                    indexName: "Product_embedding_index",
                    vectorStrategy: .hnswBatch
                )
            ]
        )

        // Create RecordStore with unique subspace for this test
        let testSubspace = Subspace(prefix: Tuple("test", "hnsw_validation", UUID().uuidString).pack())
        let store = RecordStore<Product>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Manually set index to readable state (without building HNSW graph)
        let indexStateManager = IndexStateManager(
            database: db,
            subspace: testSubspace
        )
        try await indexStateManager.enable("Product_embedding_index")  // disabled → writeOnly
        try await indexStateManager.makeReadable("Product_embedding_index")  // writeOnly → readable

        // Save a product record (only flat index is updated, HNSW graph NOT built)
        let embedding = (0..<128).map { _ in Float32.random(in: -1...1) }
        let product = Product(
            productID: 1,
            name: "Test Product",
            category: "Electronics",
            embedding: embedding
        )
        try await store.save(product)

        // Query should throw hnswGraphNotBuilt error
        let queryVector = (0..<128).map { _ in Float32.random(in: -1...1) }

        await #expect(throws: RecordLayerError.self) {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
        }

        // Verify the specific error type
        do {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
            Issue.record("Expected hnswGraphNotBuilt error but query succeeded")
        } catch let error as RecordLayerError {
            switch error {
            case .hnswGraphNotBuilt(let indexName, let message):
                #expect(indexName == "Product_embedding_index")
                #expect(message.contains("HNSW graph"))
                #expect(message.contains("OnlineIndexer.buildHNSWIndex()"))
            default:
                Issue.record("Expected hnswGraphNotBuilt error but got: \(error)")
            }
        } catch {
            Issue.record("Expected RecordLayerError but got: \(error)")
        }

        // Cleanup
        try await db.withTransaction { transaction in
            let (begin, end) = testSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Test 2: IndexState Checking

    @Test("Query throws error when index is writeOnly")
    func testQueryIndexNotReadableWriteOnly() async throws {
        // Setup FDB database
        let db = try setupDatabase()

        // Create vector index manually
        let vectorIndex = Index(
            name: "Product_embedding_index",
            type: .vector,
            rootExpression: FieldKeyExpression(fieldName: "embedding"),
            recordTypes: Set(["Product"]),
            options: IndexOptions(vectorOptions: VectorIndexOptions(dimensions: 128, metric: .cosine))
        )

        // Create schema with .hnswBatch strategy using indexConfigurations
        let schema = Schema(
            [Product.self],
            indexes: [vectorIndex],
            indexConfigurations: [
                IndexConfiguration(
                    indexName: "Product_embedding_index",
                    vectorStrategy: .hnswBatch
                )
            ]
        )

        // Create RecordStore with unique subspace for this test
        let testSubspace = Subspace(prefix: Tuple("test", "hnsw_validation", UUID().uuidString).pack())
        let store = RecordStore<Product>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Manually set index to writeOnly state
        let indexStateManager = IndexStateManager(
            database: db,
            subspace: testSubspace
        )

        // Enable the index (disabled → writeOnly transition)
        try await indexStateManager.enable("Product_embedding_index")

        // Query should throw indexNotReadable error
        let queryVector = (0..<128).map { _ in Float32.random(in: -1...1) }

        await #expect(throws: RecordLayerError.self) {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
        }

        // Verify the specific error type
        do {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
            Issue.record("Expected indexNotReadable error but query succeeded")
        } catch let error as RecordLayerError {
            switch error {
            case .indexNotReadable(let indexName, let currentState, let message):
                #expect(indexName == "Product_embedding_index")
                #expect(currentState == .writeOnly)
                #expect(message.contains("not readable"))
                #expect(message.contains("writeOnly"))
            default:
                Issue.record("Expected indexNotReadable error but got: \(error)")
            }
        } catch {
            Issue.record("Expected RecordLayerError but got: \(error)")
        }

        // Cleanup
        try await db.withTransaction { transaction in
            let (begin, end) = testSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("Query throws error when index is disabled")
    func testQueryIndexNotReadableDisabled() async throws {
        // Setup FDB database
        let db = try setupDatabase()

        // Create vector index manually
        let vectorIndex = Index(
            name: "Product_embedding_index",
            type: .vector,
            rootExpression: FieldKeyExpression(fieldName: "embedding"),
            recordTypes: Set(["Product"]),
            options: IndexOptions(vectorOptions: VectorIndexOptions(dimensions: 128, metric: .cosine))
        )

        // Create schema with .hnswBatch strategy using indexConfigurations
        let schema = Schema(
            [Product.self],
            indexes: [vectorIndex],
            indexConfigurations: [
                IndexConfiguration(
                    indexName: "Product_embedding_index",
                    vectorStrategy: .hnswBatch
                )
            ]
        )

        // Create RecordStore with unique subspace for this test
        let testSubspace = Subspace(prefix: Tuple("test", "hnsw_validation", UUID().uuidString).pack())
        let store = RecordStore<Product>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Manually set index to disabled state
        let indexStateManager = IndexStateManager(
            database: db,
            subspace: testSubspace
        )

        // First enable, then disable
        try await indexStateManager.enable("Product_embedding_index")
        try await indexStateManager.disable("Product_embedding_index")

        // Query should throw indexNotReadable error
        let queryVector = (0..<128).map { _ in Float32.random(in: -1...1) }

        await #expect(throws: RecordLayerError.self) {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
        }

        // Verify the specific error type
        do {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
            Issue.record("Expected indexNotReadable error but query succeeded")
        } catch let error as RecordLayerError {
            switch error {
            case .indexNotReadable(let indexName, let currentState, let message):
                #expect(indexName == "Product_embedding_index")
                #expect(currentState == .disabled)
                #expect(message.contains("not readable"))
                #expect(message.contains("disabled"))
            default:
                Issue.record("Expected indexNotReadable error but got: \(error)")
            }
        } catch {
            Issue.record("Expected RecordLayerError but got: \(error)")
        }

        // Cleanup
        try await db.withTransaction { transaction in
            let (begin, end) = testSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Test 3: Successful HNSW Search After Build
    // NOTE: This test is commented out because it requires complex OnlineIndexer setup
    // that is not yet fully integrated with the test infrastructure.
    // The core validation tests above are sufficient to verify the fail-fast behavior.

    /*
    @Test("HNSW search succeeds after building graph")
    func testHNSWSearchAfterBuild() async throws {
        // This test would verify that HNSW search works correctly after building the graph
        // using OnlineIndexer, but requires additional infrastructure setup.
        // TODO: Add this test when OnlineIndexer integration is complete
    }
    */

    // MARK: - Test 4: Error Messages Quality

    @Test("HNSW graph not built error message is actionable")
    func testHNSWGraphNotBuiltErrorMessage() async throws {
        // Setup FDB database
        let db = try setupDatabase()

        // Create vector index manually
        let vectorIndex = Index(
            name: "Product_embedding_index",
            type: .vector,
            rootExpression: FieldKeyExpression(fieldName: "embedding"),
            recordTypes: Set(["Product"]),
            options: IndexOptions(vectorOptions: VectorIndexOptions(dimensions: 128, metric: .cosine))
        )

        // Create schema with .hnswBatch strategy using indexConfigurations
        let schema = Schema(
            [Product.self],
            indexes: [vectorIndex],
            indexConfigurations: [
                IndexConfiguration(
                    indexName: "Product_embedding_index",
                    vectorStrategy: .hnswBatch
                )
            ]
        )

        // Create RecordStore with unique subspace for this test
        let testSubspace = Subspace(prefix: Tuple("test", "hnsw_validation", UUID().uuidString).pack())
        let store = RecordStore<Product>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Manually set index to readable state (without building HNSW graph)
        let indexStateManager = IndexStateManager(
            database: db,
            subspace: testSubspace
        )
        try await indexStateManager.enable("Product_embedding_index")  // disabled → writeOnly
        try await indexStateManager.makeReadable("Product_embedding_index")  // writeOnly → readable

        // Save a product
        let embedding = (0..<128).map { _ in Float32.random(in: -1...1) }
        let product = Product(
            productID: 1,
            name: "Test Product",
            category: "Electronics",
            embedding: embedding
        )
        try await store.save(product)

        // Try to query - should get actionable error message
        let queryVector = (0..<128).map { _ in Float32.random(in: -1...1) }

        do {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
            Issue.record("Expected error but query succeeded")
        } catch let error as RecordLayerError {
            switch error {
            case .hnswGraphNotBuilt(let indexName, let message):
                // Verify error message follows design principles: What, Why, How

                // What: Clear description
                #expect(message.contains("HNSW graph"))
                #expect(message.contains("has not been built"))
                #expect(message.contains(indexName))

                // Why: Root cause
                // (Implicit - graph doesn't exist)

                // How: Actionable steps
                #expect(message.contains("OnlineIndexer.buildHNSWIndex()"))
                #expect(message.contains("Example:"))
                #expect(message.contains("swift"))
                #expect(message.contains("batchSize"))
                #expect(message.contains("throttleDelayMs"))

                // Alternative solutions
                #expect(message.contains("Alternative"))
                #expect(message.contains(".flatScan"))

            default:
                Issue.record("Expected hnswGraphNotBuilt error but got: \(error)")
            }
        } catch {
            Issue.record("Expected RecordLayerError but got: \(error)")
        }

        // Cleanup
        try await db.withTransaction { transaction in
            let (begin, end) = testSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("Index not readable error message is actionable")
    func testIndexNotReadableErrorMessage() async throws {
        // Setup FDB database
        let db = try setupDatabase()

        // Create vector index manually
        let vectorIndex = Index(
            name: "Product_embedding_index",
            type: .vector,
            rootExpression: FieldKeyExpression(fieldName: "embedding"),
            recordTypes: Set(["Product"]),
            options: IndexOptions(vectorOptions: VectorIndexOptions(dimensions: 128, metric: .cosine))
        )

        // Create schema with .hnswBatch strategy using indexConfigurations
        let schema = Schema(
            [Product.self],
            indexes: [vectorIndex],
            indexConfigurations: [
                IndexConfiguration(
                    indexName: "Product_embedding_index",
                    vectorStrategy: .hnswBatch
                )
            ]
        )

        // Create RecordStore with unique subspace for this test
        let testSubspace = Subspace(prefix: Tuple("test", "hnsw_validation", UUID().uuidString).pack())
        let store = RecordStore<Product>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )

        // Set index to writeOnly
        let indexStateManager = IndexStateManager(
            database: db,
            subspace: testSubspace
        )
        try await indexStateManager.enable("Product_embedding_index")

        // Try to query - should get actionable error message
        let queryVector = (0..<128).map { _ in Float32.random(in: -1...1) }

        do {
            let _ = try await store.query()
                .nearestNeighbors(k: 10, to: queryVector, using: \.embedding)
                .execute()
            Issue.record("Expected error but query succeeded")
        } catch let error as RecordLayerError {
            switch error {
            case .indexNotReadable(let indexName, let currentState, let message):
                // Verify error message follows design principles: What, Why, How

                // What: Clear description
                #expect(message.contains("not readable"))
                #expect(message.contains(indexName))

                // Why: Current state
                #expect(message.contains("current state"))
                #expect(message.contains(currentState.description))

                // How: Actionable steps based on state
                if currentState == .disabled {
                    #expect(message.contains("Enable the index"))
                } else if currentState == .writeOnly {
                    #expect(message.contains("Wait for index build"))
                }

                #expect(message.contains("Only 'readable' indexes can be queried"))
                #expect(message.contains("Expected state: readable"))

            default:
                Issue.record("Expected indexNotReadable error but got: \(error)")
            }
        } catch {
            Issue.record("Expected RecordLayerError but got: \(error)")
        }

        // Cleanup
        try await db.withTransaction { transaction in
            let (begin, end) = testSubspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }
}
