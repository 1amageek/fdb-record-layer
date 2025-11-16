import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Tests for AggregateDSL functions (Sum, Avg, Max, Min, Count)
///
/// Tests the Reflection-based implementation of aggregate functions
@Suite("AggregateDSL Tests")
struct AggregateDSLTests {

    // MARK: - Test Model

    @Recordable
    struct Product {
        #PrimaryKey<Product>([\.id])

        var id: Int64
        var name: String
        var price: Double
        var stock: Int64
        var category: String
    }

    // MARK: - Setup/Teardown

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    private func setupTestStore() async throws -> RecordStore<Product> {
        let db = try FDBClient.openDatabase()
        let testSubspace = Subspace(prefix: Array("test_aggregate_\(UUID().uuidString)".utf8))
        let schema = Schema([Product.self])

        let store = RecordStore<Product>(
            database: db,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: db, subspace: testSubspace.subspace("stats"))
        )

        // Save test products
        let products = [
            Product(id: 1, name: "Laptop", price: 1200.0, stock: 10, category: "Electronics"),
            Product(id: 2, name: "Mouse", price: 25.0, stock: 50, category: "Electronics"),
            Product(id: 3, name: "Keyboard", price: 75.0, stock: 30, category: "Electronics"),
            Product(id: 4, name: "Desk", price: 300.0, stock: 5, category: "Furniture"),
            Product(id: 5, name: "Chair", price: 150.0, stock: 15, category: "Furniture"),
        ]

        for product in products {
            try await store.save(product)
        }

        return store
    }

    // MARK: - Count Tests

    @Test("Count() - count all records")
    func testCountAll() async throws {
        let store = try await setupTestStore()

        let count = try await store.aggregate(Count())

        #expect(count == 5, "Should count all 5 products")
    }

    @Test("Count() - count with filter")
    func testCountWithFilter() async throws {
        let store = try await setupTestStore()

        let count = try await store.aggregate(where: \.category == "Electronics", Count())

        #expect(count == 3, "Should count 3 Electronics products")
    }

    // MARK: - Sum Tests

    @Test("Sum() - sum of price field")
    func testSumPrice() async throws {
        let store = try await setupTestStore()

        let totalPrice = try await store.aggregate(Sum(\.price))

        // 1200 + 25 + 75 + 300 + 150 = 1750
        #expect(totalPrice == 1750.0, "Total price should be 1750.0")
    }

    @Test("Sum() - sum with filter")
    func testSumWithFilter() async throws {
        let store = try await setupTestStore()

        let electronicsPrice = try await store.aggregate(where: \.category == "Electronics", Sum(\.price))

        // 1200 + 25 + 75 = 1300
        #expect(electronicsPrice == 1300.0, "Electronics total should be 1300.0")
    }

    @Test("Sum() - sum of integer field")
    func testSumStock() async throws {
        let store = try await setupTestStore()

        let totalStock = try await store.aggregate(Sum(\.stock))

        // 10 + 50 + 30 + 5 + 15 = 110
        #expect(totalStock == 110, "Total stock should be 110")
    }

    // MARK: - Average Tests

    @Test("Average() - average price")
    func testAveragePrice() async throws {
        let store = try await setupTestStore()

        let avgPrice = try await store.aggregate(Average(\.price))

        // (1200 + 25 + 75 + 300 + 150) / 5 = 350.0
        #expect(avgPrice == 350.0, "Average price should be 350.0")
    }

    @Test("Average() - average with filter")
    func testAverageWithFilter() async throws {
        let store = try await setupTestStore()

        let furnitureAvg = try await store.aggregate(where: \.category == "Furniture", Average(\.price))

        // (300 + 150) / 2 = 225.0
        #expect(furnitureAvg == 225.0, "Furniture average should be 225.0")
    }

    // MARK: - Max Tests

    @Test("Max() - maximum price")
    func testMaxPrice() async throws {
        let store = try await setupTestStore()

        let maxPrice = try await store.aggregate(Max(\.price))

        #expect(maxPrice == 1200.0, "Max price should be 1200.0")
    }

    @Test("Max() - maximum with filter")
    func testMaxWithFilter() async throws {
        let store = try await setupTestStore()

        let furnitureMax = try await store.aggregate(where: \.category == "Furniture", Max(\.price))

        #expect(furnitureMax == 300.0, "Furniture max should be 300.0")
    }

    @Test("Max() - maximum stock")
    func testMaxStock() async throws {
        let store = try await setupTestStore()

        let maxStock = try await store.aggregate(Max(\.stock))

        #expect(maxStock == 50, "Max stock should be 50")
    }

    // MARK: - Min Tests

    @Test("Min() - minimum price")
    func testMinPrice() async throws {
        let store = try await setupTestStore()

        let minPrice = try await store.aggregate(Min(\.price))

        #expect(minPrice == 25.0, "Min price should be 25.0")
    }

    @Test("Min() - minimum with filter")
    func testMinWithFilter() async throws {
        let store = try await setupTestStore()

        let furnitureMin = try await store.aggregate(where: \.category == "Furniture", Min(\.price))

        #expect(furnitureMin == 150.0, "Furniture min should be 150.0")
    }

    @Test("Min() - minimum stock")
    func testMinStock() async throws {
        let store = try await setupTestStore()

        let minStock = try await store.aggregate(Min(\.stock))

        #expect(minStock == 5, "Min stock should be 5")
    }

    // MARK: - Edge Cases

    @Test("Count() - empty result set")
    func testCountEmpty() async throws {
        let store = try await setupTestStore()

        let count = try await store.aggregate(where: \.category == "Nonexistent", Count())

        #expect(count == 0, "Count should be 0 for empty result")
    }

    @Test("Sum() - empty result set")
    func testSumEmpty() async throws {
        let store = try await setupTestStore()

        let sum: Double = try await store.aggregate(where: \.category == "Nonexistent", Sum(\.price))

        #expect(sum == 0.0, "Sum should be 0.0 for empty result")
    }

    @Test("Average() - empty result set")
    func testAverageEmpty() async throws {
        let store = try await setupTestStore()

        let avg: Double = try await store.aggregate(where: \.category == "Nonexistent", Average(\.price))

        #expect(avg == 0.0, "Average should be 0.0 for empty result")
    }

    @Test("Max() - empty result set")
    func testMaxEmpty() async throws {
        let store = try await setupTestStore()

        let max: Double? = try await store.aggregate(where: \.category == "Nonexistent", Max(\.price))

        #expect(max == nil, "Max should be nil for empty result")
    }

    @Test("Min() - empty result set")
    func testMinEmpty() async throws {
        let store = try await setupTestStore()

        let min: Double? = try await store.aggregate(where: \.category == "Nonexistent", Min(\.price))

        #expect(min == nil, "Min should be nil for empty result")
    }
}
