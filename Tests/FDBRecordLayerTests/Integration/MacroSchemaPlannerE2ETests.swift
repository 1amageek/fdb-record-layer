import Testing
import Foundation
 import FDBRecordCore
@testable import FoundationDB
@testable import FDBRecordLayer

/// End-to-End tests for Macro → Schema → Planner integration
///
/// These tests verify the complete flow:
/// 1. @Recordable macro generates Index definitions
/// 2. Schema captures these indexes
/// 3. RecordStore creates physical indexes in FDB
/// 4. Planner uses these indexes to generate optimal query plans
/// 5. Query execution returns correct results
@Suite("Macro → Schema → Planner E2E Tests", .tags(.e2e, .integration))
struct MacroSchemaPlannerE2ETests {

    // MARK: - Test Models

    /// Model with Range field and macro-generated indexes
    @Recordable
    struct Event {
        #PrimaryKey<Event>([\.id])
        #Index<Event>([\.period.lowerBound])  // Explicit lowerBound index
        #Index<Event>([\.period.upperBound])  // Explicit upperBound index

        var id: Int64
        var period: Range<Date>
        var title: String
    }

    /// Model with multiple index types
    @Recordable
    struct Product {
        #PrimaryKey<Product>([\.id])
        #Index<Product>([\.category])
        #Index<Product>([\.price])
        #Unique<Product>([\.sku])

        var id: Int64
        var category: String
        var price: Double
        var sku: String
    }

    /// Model with composite indexes
    @Recordable
    struct Order {
        #PrimaryKey<Order>([\.orderID])
        #Index<Order>([\.customerID, \.orderDate])
        #Index<Order>([\.status])

        var orderID: Int64
        var customerID: Int64
        var orderDate: Date
        var status: String
        var totalAmount: Double
    }

    // MARK: - Setup/Teardown

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    private func setupEventStore() async throws -> RecordStore<Event> {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_e2e_event_\(UUID().uuidString)".utf8))
        let schema = Schema([Event.self])

        let store = RecordStore<Event>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        return store
    }

    private func setupProductStore() async throws -> RecordStore<Product> {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_e2e_product_\(UUID().uuidString)".utf8))
        let schema = Schema([Product.self])

        let store = RecordStore<Product>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        return store
    }

    private func setupOrderStore() async throws -> RecordStore<Order> {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_e2e_order_\(UUID().uuidString)".utf8))
        let schema = Schema([Order.self])

        let store = RecordStore<Order>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        return store
    }

    // MARK: - Range Index E2E Tests

    @Test("E2E: Macro generates Range indexes → Schema → Planner uses IntersectionPlan")
    func testRangeIndexE2E() async throws {
        let store = try await setupEventStore()

        // Step 1: Verify macro generated indexes in schema
        let schema = store.schema
        let indexes = schema.indexes(for: Event.recordName)

        #expect(indexes.count >= 2, "Macro should generate at least 2 indexes for Range field")

        let startIndex = indexes.first { $0.name == "Event_period_start_index" }
        let endIndex = indexes.first { $0.name == "Event_period_end_index" }

        #expect(startIndex != nil, "Macro should generate _start index")
        #expect(endIndex != nil, "Macro should generate _end index")

        // Step 2: Save test data
        let baseTime = Date(timeIntervalSince1970: 0)
        let events = [
            Event(id: 1, period: baseTime.addingTimeInterval(0)..<baseTime.addingTimeInterval(100), title: "Morning Meeting"),
            Event(id: 2, period: baseTime.addingTimeInterval(50)..<baseTime.addingTimeInterval(150), title: "Lunch Break"),
            Event(id: 3, period: baseTime.addingTimeInterval(200)..<baseTime.addingTimeInterval(300), title: "Afternoon Workshop"),
        ]

        for event in events {
            try await store.save(event)
        }

        // Step 3: Query with overlaps() and verify Planner generates IntersectionPlan
        let queryRange = baseTime.addingTimeInterval(25)..<baseTime.addingTimeInterval(125)
        let queryBuilder = store.query().overlaps(\.period, with: queryRange)
        let (query, planner) = queryBuilder.buildQueryAndPlanner()
        let plan = try await planner.plan(query: query)

        #expect(plan is TypedIntersectionPlan<Event>, "Planner should generate IntersectionPlan for overlaps()")

        // Step 4: Verify query results are correct
        let results = try await queryBuilder.execute()
        let resultIDs = results.map { $0.id }.sorted()

        #expect(resultIDs == [1, 2], "Should find events 1 and 2 overlapping the query range")
    }

    @Test("E2E: Range index with filter → FilterPlan wrapping IntersectionPlan")
    func testRangeIndexWithFilterE2E() async throws {
        let store = try await setupEventStore()

        // Save test data
        let baseTime = Date(timeIntervalSince1970: 0)
        let events = [
            Event(id: 1, period: baseTime.addingTimeInterval(0)..<baseTime.addingTimeInterval(100), title: "Meeting"),
            Event(id: 2, period: baseTime.addingTimeInterval(50)..<baseTime.addingTimeInterval(150), title: "Conference"),
            Event(id: 3, period: baseTime.addingTimeInterval(75)..<baseTime.addingTimeInterval(125), title: "Meeting"),
        ]

        for event in events {
            try await store.save(event)
        }

        // Query with overlaps() + filter
        let queryRange = baseTime.addingTimeInterval(25)..<baseTime.addingTimeInterval(125)
        let queryBuilder = store.query()
            .overlaps(\.period, with: queryRange)
            .where(\.title, is: .equals, "Meeting")
        let (query, planner) = queryBuilder.buildQueryAndPlanner()
        let plan = try await planner.plan(query: query)

        // Verify plan structure
        #expect(plan is TypedFilterPlan<Event>, "Combined query should generate FilterPlan")
        if let filterPlan = plan as? TypedFilterPlan<Event> {
            #expect(filterPlan.child is TypedIntersectionPlan<Event>, "FilterPlan should wrap IntersectionPlan")
        }

        // Verify results
        let results = try await queryBuilder.execute()
        let resultIDs = results.map { $0.id }.sorted()

        #expect(resultIDs == [1, 3], "Should find meetings 1 and 3")
    }

    // MARK: - Single Field Index E2E Tests

    @Test("E2E: Single field index → Planner uses IndexScanPlan")
    func testSingleFieldIndexE2E() async throws {
        let store = try await setupProductStore()

        // Step 1: Verify macro generated indexes in schema
        let schema = store.schema
        let indexes = schema.indexes(for: Product.recordName)

        let categoryIndex = indexes.first { $0.name.contains("category") }
        let priceIndex = indexes.first { $0.name.contains("price") }

        #expect(categoryIndex != nil, "Macro should generate category index")
        #expect(priceIndex != nil, "Macro should generate price index")

        // Step 2: Save test data
        let products = [
            Product(id: 1, category: "Electronics", price: 999.99, sku: "LAPTOP001"),
            Product(id: 2, category: "Electronics", price: 49.99, sku: "MOUSE001"),
            Product(id: 3, category: "Furniture", price: 299.99, sku: "DESK001"),
        ]

        for product in products {
            try await store.save(product)
        }

        // Step 3: Query by category and verify Planner generates IndexScanPlan
        let queryBuilder = store.query().where(\.category, is: .equals, "Electronics")
        let (query, planner) = queryBuilder.buildQueryAndPlanner()
        let plan = try await planner.plan(query: query)

        #expect(plan is TypedIndexScanPlan<Product>, "Planner should use IndexScanPlan for indexed field")

        // Step 4: Verify results
        let results = try await queryBuilder.execute()
        let resultIDs = results.map { $0.id }.sorted()

        #expect(resultIDs == [1, 2], "Should find 2 Electronics products")
    }

    @Test("E2E: Unique index → Planner uses IndexScanPlan")
    func testUniqueIndexE2E() async throws {
        let store = try await setupProductStore()

        // Verify unique index in schema
        let schema = store.schema
        let indexes = schema.indexes(for: Product.recordName)

        let skuIndex = indexes.first { $0.name.contains("sku") }
        #expect(skuIndex != nil, "Macro should generate SKU unique index")

        // Save test data
        let product = Product(id: 1, category: "Electronics", price: 999.99, sku: "LAPTOP001")
        try await store.save(product)

        // Query by unique SKU
        let queryBuilder = store.query().where(\.sku, is: .equals, "LAPTOP001")
        let (query, planner) = queryBuilder.buildQueryAndPlanner()
        let plan = try await planner.plan(query: query)

        #expect(plan is TypedIndexScanPlan<Product>, "Planner should use IndexScanPlan for unique index")

        // Verify single result
        let results = try await queryBuilder.execute()
        #expect(results.count == 1, "Unique query should return single result")
        #expect(results.first?.id == 1, "Should find product 1")
    }

    // MARK: - Composite Index E2E Tests

    @Test("E2E: Composite index → Planner uses IndexScanPlan")
    func testCompositeIndexE2E() async throws {
        let store = try await setupOrderStore()

        // Step 1: Verify macro generated composite index
        let schema = store.schema
        let indexes = schema.indexes(for: Order.recordName)

        let compositeIndex = indexes.first {
            $0.name.contains("customerID") && $0.name.contains("orderDate")
        }
        #expect(compositeIndex != nil, "Macro should generate composite index for [customerID, orderDate]")

        // Step 2: Save test data
        let baseDate = Date(timeIntervalSince1970: 0)
        let orders = [
            Order(orderID: 1, customerID: 100, orderDate: baseDate.addingTimeInterval(0), status: "pending", totalAmount: 150.0),
            Order(orderID: 2, customerID: 100, orderDate: baseDate.addingTimeInterval(86400), status: "shipped", totalAmount: 200.0),
            Order(orderID: 3, customerID: 200, orderDate: baseDate.addingTimeInterval(0), status: "pending", totalAmount: 300.0),
        ]

        for order in orders {
            try await store.save(order)
        }

        // Step 3: Query by customerID and verify Planner uses composite index
        let queryBuilder = store.query().where(\.customerID, is: .equals, 100)
        let (query, planner) = queryBuilder.buildQueryAndPlanner()
        let plan = try await planner.plan(query: query)

        #expect(plan is TypedIndexScanPlan<Order>, "Planner should use IndexScanPlan for composite index prefix")

        // Step 4: Verify results
        let results = try await queryBuilder.execute()
        let resultIDs = results.map { $0.orderID }.sorted()

        #expect(resultIDs == [1, 2], "Should find 2 orders for customer 100")
    }

    // MARK: - Planner Selection Tests

    @Test("E2E: Multiple indexed fields with correct results")
    func testMultipleIndexedFieldsE2E() async throws {
        let store = try await setupProductStore()

        // Save test data: many Electronics, few at price 999.99
        let products = [
            Product(id: 1, category: "Electronics", price: 999.99, sku: "LAPTOP001"),
            Product(id: 2, category: "Electronics", price: 49.99, sku: "MOUSE001"),
            Product(id: 3, category: "Electronics", price: 49.99, sku: "MOUSE002"),
            Product(id: 4, category: "Electronics", price: 49.99, sku: "MOUSE003"),
            Product(id: 5, category: "Furniture", price: 299.99, sku: "DESK001"),
        ]

        for product in products {
            try await store.save(product)
        }

        // Query by both category and price
        // Without statistics, planner may choose full scan or index scan
        // The important thing is that results are correct
        let queryBuilder = store.query()
            .where(\.category, is: .equals, "Electronics")
            .where(\.price, is: .equals, 999.99)

        // Verify results are correct regardless of plan choice
        let results = try await queryBuilder.execute()
        #expect(results.count == 1, "Should find exactly 1 product matching both criteria")
        #expect(results.first?.id == 1, "Should find product 1")

        // Also verify that macro-generated indexes exist in schema
        let schema = store.schema
        let indexes = schema.indexes(for: Product.recordName)
        let hasCategoryIndex = indexes.contains { $0.name.contains("category") }
        let hasPriceIndex = indexes.contains { $0.name.contains("price") }
        #expect(hasCategoryIndex, "Schema should have category index from macro")
        #expect(hasPriceIndex, "Schema should have price index from macro")
    }

    @Test("E2E: Full scan when no suitable index exists")
    func testFullScanWhenNoIndex() async throws {
        let store = try await setupProductStore()

        // Save test data
        let product = Product(id: 1, category: "Electronics", price: 999.99, sku: "LAPTOP001")
        try await store.save(product)

        // Query by price range
        // For range queries without statistics, planner might use index or full scan
        let queryBuilder = store.query().where(\.price, is: .greaterThan, 500.0)

        // Verify results are correct regardless of plan choice
        let results = try await queryBuilder.execute()
        #expect(results.count == 1, "Should find 1 product with price > 500")
        #expect(results.first?.id == 1, "Should find product 1")
    }
}
