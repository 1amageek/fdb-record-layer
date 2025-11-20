import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Tests for Covering Index Scan (Phase 2B)
///
/// Test Coverage:
/// 1. CoveringIndexScanTypedCursor - record reconstruction from index key+value
/// 2. TypedCoveringIndexScanPlan - plan execution with covering cursor
/// 3. No getValue() calls verification (performance optimization)
/// 4. Filter application with reconstructed records
/// 5. Integration with index scan logic
@Suite("Covering Index Scan Tests", .serialized)
struct CoveringIndexScanTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Test Data Model

    struct Product: Sendable {
        let productID: Int64
        let category: String
        let name: String
        let price: Int64

        static let recordName = "Product"
    }

    struct ProductRecordAccess: RecordAccess {
        func recordName(for record: Product) -> String {
            return Product.recordName
        }

        func extractField(from record: Product, fieldName: String) throws -> [any TupleElement] {
            switch fieldName {
            case "productID": return [record.productID]
            case "category": return [record.category]
            case "name": return [record.name]
            case "price": return [record.price]
            default:
                throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
            }
        }

        func serialize(_ record: Product) throws -> FDB.Bytes {
            let tuple = Tuple(record.productID, record.category, record.name, record.price)
            return tuple.pack()
        }

        func deserialize(_ bytes: FDB.Bytes) throws -> Product {
            let tuple = try Tuple.unpack(from: bytes)
            guard let productID = tuple[0] as? Int64,
                  let category = tuple[1] as? String,
                  let name = tuple[2] as? String,
                  let price = tuple[3] as? Int64 else {
                throw RecordLayerError.deserializationFailed("Invalid Product tuple")
            }
            return Product(productID: productID, category: category, name: name, price: price)
        }

        // Covering index support
        public var supportsReconstruction: Bool {
            return true
        }

        public func reconstruct(
            indexKey: Tuple,
            indexValue: FDB.Bytes,
            index: Index,
            primaryKeyExpression: KeyExpression
        ) throws -> Product {
            // Field counts
            let rootCount = index.rootExpression.columnCount  // 1 (category)
            _ = primaryKeyExpression.columnCount              // 1 (productID)

            // Extract indexed field (category) from index key
            guard let category = indexKey[0] as? String else {
                throw RecordLayerError.reconstructionFailed(
                    recordType: "Product",
                    reason: "Invalid category field in index key"
                )
            }

            // Extract primary key (productID) from index key (last N elements)
            guard let productID = indexKey[rootCount] as? Int64 else {
                throw RecordLayerError.reconstructionFailed(
                    recordType: "Product",
                    reason: "Invalid productID field in index key"
                )
            }

            // Extract covering fields (name, price) from index value
            let coveringTuple = try Tuple.unpack(from: indexValue)
            guard let name = coveringTuple[0] as? String,
                  let price = coveringTuple[1] as? Int64 else {
                throw RecordLayerError.reconstructionFailed(
                    recordType: "Product",
                    reason: "Invalid covering fields in index value"
                )
            }

            // Reconstruct record
            return Product(productID: productID, category: category, name: name, price: price)
        }
    }

    // MARK: - CoveringIndexScanTypedCursor Tests

    @Test("CoveringIndexScanTypedCursor reconstructs records from index key+value")
    func coveringCursorReconstructsRecords() async throws {
        let database = try await setupDatabase()
        defer { cleanupDatabase(database) }

        let subspace = Subspace(prefix: [0x01])
        let indexSubspace = subspace.subspace("I").subspace("product_by_category_covering")
        let recordAccess = ProductRecordAccess()

        // Create covering index
        let index = Index.covering(
            named: "product_by_category_covering",
            on: FieldKeyExpression(fieldName: "category"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "price")
            ]
        )

        let primaryKeyExpr = FieldKeyExpression(fieldName: "productID")

        // Prepare test data: 3 products in "Electronics" category
        let products = [
            Product(productID: 1001, category: "Electronics", name: "Laptop", price: 1200),
            Product(productID: 1002, category: "Electronics", name: "Mouse", price: 25),
            Product(productID: 1003, category: "Electronics", name: "Keyboard", price: 75)
        ]

        // Write index entries
        try await database.withTransaction { transaction in
            for product in products {
                let indexKey = indexSubspace.pack(Tuple(product.category, product.productID))
                let indexValue = Tuple(product.name, product.price).pack()
                transaction.setValue(indexValue, for: indexKey)
            }
        }

        // Scan with CoveringIndexScanTypedCursor
        var scannedProducts: [Product] = []

        try await database.withTransaction { transaction in
            // Range: category == "Electronics"
            let beginKey = indexSubspace.pack(Tuple("Electronics"))
            let endKey = beginKey + [0xFF]

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: true
            )

            let cursor = CoveringIndexScanTypedCursor(
                indexSequence: sequence,
                indexSubspace: indexSubspace,
                recordAccess: recordAccess,
                transaction: transaction,
                filter: nil as (any TypedQueryComponent<Product>)?,
                index: index,
                primaryKeyExpression: primaryKeyExpr,
                snapshot: true
            )

            for try await product in cursor {
                scannedProducts.append(product)
            }
        }

        // Verify results
        #expect(scannedProducts.count == 3)

        let sortedProducts = scannedProducts.sorted { $0.productID < $1.productID }
        #expect(sortedProducts[0].productID == 1001)
        #expect(sortedProducts[0].name == "Laptop")
        #expect(sortedProducts[0].price == 1200)

        #expect(sortedProducts[1].productID == 1002)
        #expect(sortedProducts[1].name == "Mouse")
        #expect(sortedProducts[1].price == 25)

        #expect(sortedProducts[2].productID == 1003)
        #expect(sortedProducts[2].name == "Keyboard")
        #expect(sortedProducts[2].price == 75)
    }

    @Test("CoveringIndexScanTypedCursor applies filters correctly")
    func coveringCursorAppliesFilters() async throws {
        let database = try await setupDatabase()
        defer { cleanupDatabase(database) }

        let subspace = Subspace(prefix: [0x01])
        let indexSubspace = subspace.subspace("I").subspace("product_by_category_covering")
        let recordAccess = ProductRecordAccess()

        let index = Index.covering(
            named: "product_by_category_covering",
            on: FieldKeyExpression(fieldName: "category"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "price")
            ]
        )

        let primaryKeyExpr = FieldKeyExpression(fieldName: "productID")

        // Prepare test data
        let products = [
            Product(productID: 1001, category: "Electronics", name: "Laptop", price: 1200),
            Product(productID: 1002, category: "Electronics", name: "Mouse", price: 25),
            Product(productID: 1003, category: "Electronics", name: "Keyboard", price: 75)
        ]

        try await database.withTransaction { transaction in
            for product in products {
                let indexKey = indexSubspace.pack(Tuple(product.category, product.productID))
                let indexValue = Tuple(product.name, product.price).pack()
                transaction.setValue(indexValue, for: indexKey)
            }
        }

        // Scan with filter: price >= 50
        var filteredProducts: [Product] = []

        try await database.withTransaction { transaction in
            let beginKey = indexSubspace.pack(Tuple("Electronics"))
            let endKey = beginKey + [0xFF]

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterOrEqual(endKey),
                snapshot: true
            )

            // Filter: price >= 50
            let filter = TypedFieldQueryComponent<Product>(
                fieldName: "price",
                comparison: .greaterThanOrEquals,
                value: Int64(50)
            )

            let cursor = CoveringIndexScanTypedCursor(
                indexSequence: sequence,
                indexSubspace: indexSubspace,
                recordAccess: recordAccess,
                transaction: transaction,
                filter: filter,
                index: index,
                primaryKeyExpression: primaryKeyExpr,
                snapshot: true
            )

            for try await product in cursor {
                filteredProducts.append(product)
            }
        }

        // Verify: Only Laptop (1200) and Keyboard (75) match
        #expect(filteredProducts.count == 2)

        let sortedProducts = filteredProducts.sorted { $0.productID < $1.productID }
        #expect(sortedProducts[0].productID == 1001)  // Laptop
        #expect(sortedProducts[1].productID == 1003)  // Keyboard
    }

    // MARK: - TypedCoveringIndexScanPlan Tests

    @Test("TypedCoveringIndexScanPlan executes and returns covering cursor")
    func coveringPlanExecutesProperly() async throws {
        let database = try await setupDatabase()
        defer { cleanupDatabase(database) }

        let subspace = Subspace(prefix: [0x01])
        let indexSubspace = subspace.subspace("I")
        let recordAccess = ProductRecordAccess()

        let index = Index.covering(
            named: "product_by_category_covering",
            on: FieldKeyExpression(fieldName: "category"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "price")
            ]
        )

        let primaryKeyExpr = FieldKeyExpression(fieldName: "productID")

        // Prepare test data
        let products = [
            Product(productID: 1001, category: "Electronics", name: "Laptop", price: 1200),
            Product(productID: 1002, category: "Books", name: "Swift Guide", price: 45)
        ]

        try await database.withTransaction { transaction in
            let indexNameSubspace = indexSubspace.subspace("product_by_category_covering")
            for product in products {
                let indexKey = indexNameSubspace.pack(Tuple(product.category, product.productID))
                let indexValue = Tuple(product.name, product.price).pack()
                transaction.setValue(indexValue, for: indexKey)
            }
        }

        // Execute plan
        let plan = TypedCoveringIndexScanPlan<Product>(
            index: index,
            indexSubspaceTupleKey: "product_by_category_covering",
            beginValues: ["Electronics"],
            endValues: ["Electronics"],
            filter: nil as (any TypedQueryComponent<Product>)?,
            primaryKeyExpression: primaryKeyExpr
        )

        var results: [Product] = []

        try await database.withTransaction { transaction in
            let context = TransactionContext(transaction: transaction)


            let cursor = try await plan.execute(
                subspace: subspace,
                recordAccess: recordAccess,
                context: context,
                snapshot: true
            )

            for try await product in cursor {
                results.append(product)
            }
        }

        // Verify: Only Electronics product
        #expect(results.count == 1)
        #expect(results[0].productID == 1001)
        #expect(results[0].name == "Laptop")
        #expect(results[0].category == "Electronics")
    }

    @Test("TypedCoveringIndexScanPlan handles equality queries correctly")
    func coveringPlanEqualityQuery() async throws {
        let database = try await setupDatabase()
        defer { cleanupDatabase(database) }

        let subspace = Subspace(prefix: [0x01])
        let indexSubspace = subspace.subspace("I")
        let recordAccess = ProductRecordAccess()

        let index = Index.covering(
            named: "product_by_category_covering",
            on: FieldKeyExpression(fieldName: "category"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "price")
            ]
        )

        let primaryKeyExpr = FieldKeyExpression(fieldName: "productID")

        // Prepare test data: Multiple products with same category
        let products = [
            Product(productID: 1001, category: "Electronics", name: "Laptop", price: 1200),
            Product(productID: 1002, category: "Electronics", name: "Mouse", price: 25),
            Product(productID: 1003, category: "Electronics", name: "Keyboard", price: 75),
            Product(productID: 2001, category: "Books", name: "Swift Guide", price: 45)
        ]

        try await database.withTransaction { transaction in
            let indexNameSubspace = indexSubspace.subspace("product_by_category_covering")
            for product in products {
                let indexKey = indexNameSubspace.pack(Tuple(product.category, product.productID))
                let indexValue = Tuple(product.name, product.price).pack()
                transaction.setValue(indexValue, for: indexKey)
            }
        }

        // Execute equality query: category == "Electronics"
        let plan = TypedCoveringIndexScanPlan<Product>(
            index: index,
            indexSubspaceTupleKey: "product_by_category_covering",
            beginValues: ["Electronics"],  // Same as endValues → equality query
            endValues: ["Electronics"],
            filter: nil as (any TypedQueryComponent<Product>)?,
            primaryKeyExpression: primaryKeyExpr
        )

        var results: [Product] = []

        try await database.withTransaction { transaction in
            let context = TransactionContext(transaction: transaction)

            let cursor = try await plan.execute(
                subspace: subspace,
                recordAccess: recordAccess,
                context: context,
                snapshot: true
            )

            for try await product in cursor {
                results.append(product)
            }
        }

        // Verify: 3 Electronics products
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.category == "Electronics" })
    }

    @Test("TypedCoveringIndexScanPlan handles open-ended ranges")
    func coveringPlanOpenEndedRange() async throws {
        let database = try await setupDatabase()
        defer { cleanupDatabase(database) }

        let subspace = Subspace(prefix: [0x01])
        let indexSubspace = subspace.subspace("I")
        let recordAccess = ProductRecordAccess()

        let index = Index.covering(
            named: "product_by_category_covering",
            on: FieldKeyExpression(fieldName: "category"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "price")
            ]
        )

        let primaryKeyExpr = FieldKeyExpression(fieldName: "productID")

        // Prepare test data
        let products = [
            Product(productID: 1001, category: "Books", name: "Swift Guide", price: 45),
            Product(productID: 1002, category: "Electronics", name: "Laptop", price: 1200),
            Product(productID: 1003, category: "Furniture", name: "Desk", price: 300)
        ]

        try await database.withTransaction { transaction in
            let indexNameSubspace = indexSubspace.subspace("product_by_category_covering")
            for product in products {
                let indexKey = indexNameSubspace.pack(Tuple(product.category, product.productID))
                let indexValue = Tuple(product.name, product.price).pack()
                transaction.setValue(indexValue, for: indexKey)
            }
        }

        // Execute open-ended range query: category >= "Electronics"
        let plan = TypedCoveringIndexScanPlan<Product>(
            index: index,
            indexSubspaceTupleKey: "product_by_category_covering",
            beginValues: ["Electronics"],  // Lower bound
            endValues: [],                 // Open upper bound
            filter: nil as (any TypedQueryComponent<Product>)?,
            primaryKeyExpression: primaryKeyExpr
        )

        var results: [Product] = []

        try await database.withTransaction { transaction in
            let context = TransactionContext(transaction: transaction)

            let cursor = try await plan.execute(
                subspace: subspace,
                recordAccess: recordAccess,
                context: context,
                snapshot: true
            )

            for try await product in cursor {
                results.append(product)
            }
        }

        // Verify: Electronics and Furniture (Books < Electronics)
        #expect(results.count == 2)
        let categories = Set(results.map { $0.category })
        #expect(categories == ["Electronics", "Furniture"])
    }

    @Test("TypedCoveringIndexScanPlan with filter combines index scan and filtering")
    func coveringPlanWithFilter() async throws {
        let database = try await setupDatabase()
        defer { cleanupDatabase(database) }

        let subspace = Subspace(prefix: [0x01])
        let indexSubspace = subspace.subspace("I")
        let recordAccess = ProductRecordAccess()

        let index = Index.covering(
            named: "product_by_category_covering",
            on: FieldKeyExpression(fieldName: "category"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "price")
            ]
        )

        let primaryKeyExpr = FieldKeyExpression(fieldName: "productID")

        // Prepare test data
        let products = [
            Product(productID: 1001, category: "Electronics", name: "Laptop", price: 1200),
            Product(productID: 1002, category: "Electronics", name: "Mouse", price: 25),
            Product(productID: 1003, category: "Electronics", name: "Keyboard", price: 75)
        ]

        try await database.withTransaction { transaction in
            let indexNameSubspace = indexSubspace.subspace("product_by_category_covering")
            for product in products {
                let indexKey = indexNameSubspace.pack(Tuple(product.category, product.productID))
                let indexValue = Tuple(product.name, product.price).pack()
                transaction.setValue(indexValue, for: indexKey)
            }
        }

        // Plan: category == "Electronics" AND price < 100
        let filter = TypedFieldQueryComponent<Product>(
            fieldName: "price",
            comparison: .lessThan,
            value: Int64(100)
        )

        let plan = TypedCoveringIndexScanPlan<Product>(
            index: index,
            indexSubspaceTupleKey: "product_by_category_covering",
            beginValues: ["Electronics"],
            endValues: ["Electronics"],
            filter: filter,
            primaryKeyExpression: primaryKeyExpr
        )

        var results: [Product] = []

        try await database.withTransaction { transaction in
            let context = TransactionContext(transaction: transaction)

            let cursor = try await plan.execute(
                subspace: subspace,
                recordAccess: recordAccess,
                context: context,
                snapshot: true
            )

            for try await product in cursor {
                results.append(product)
            }
        }

        // Verify: Only Mouse (25) and Keyboard (75)
        #expect(results.count == 2)
        let sortedResults = results.sorted { $0.productID < $1.productID }
        #expect(sortedResults[0].productID == 1002)  // Mouse
        #expect(sortedResults[1].productID == 1003)  // Keyboard
    }

    // MARK: - Performance Verification Tests

    @Test("Covering index scan avoids getValue() calls")
    func coveringIndexScanPerformanceOptimization() async throws {
        let database = try await setupDatabase()
        defer { cleanupDatabase(database) }

        let subspace = Subspace(prefix: [0x01])
        _ = subspace.subspace("R")  // recordSubspace not used in this test
        let indexSubspace = subspace.subspace("I")
        let recordAccess = ProductRecordAccess()

        let index = Index.covering(
            named: "product_by_category_covering",
            on: FieldKeyExpression(fieldName: "category"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "price")
            ]
        )

        let primaryKeyExpr = FieldKeyExpression(fieldName: "productID")

        // Prepare test data: Index entries WITHOUT actual records
        // If covering scan works, it should reconstruct from index only
        let products = [
            Product(productID: 1001, category: "Electronics", name: "Laptop", price: 1200)
        ]

        try await database.withTransaction { transaction in
            // Write ONLY index entry, NOT the actual record
            let indexNameSubspace = indexSubspace.subspace("product_by_category_covering")
            for product in products {
                let indexKey = indexNameSubspace.pack(Tuple(product.category, product.productID))
                let indexValue = Tuple(product.name, product.price).pack()
                transaction.setValue(indexValue, for: indexKey)
            }

            // Intentionally NOT writing record data to verify no getValue() is called
            // If getValue() were called, it would return nil and fail
        }

        // Execute covering plan
        let plan = TypedCoveringIndexScanPlan<Product>(
            index: index,
            indexSubspaceTupleKey: "product_by_category_covering",
            beginValues: ["Electronics"],
            endValues: ["Electronics"],
            filter: nil as (any TypedQueryComponent<Product>)?,
            primaryKeyExpression: primaryKeyExpr
        )

        var results: [Product] = []

        try await database.withTransaction { transaction in
            let context = TransactionContext(transaction: transaction)

            let cursor = try await plan.execute(
                subspace: subspace,
                recordAccess: recordAccess,
                context: context,
                snapshot: true
            )

            for try await product in cursor {
                results.append(product)
            }
        }

        // Verify: Successfully reconstructed from index without record fetch
        #expect(results.count == 1)
        #expect(results[0].productID == 1001)
        #expect(results[0].name == "Laptop")
        #expect(results[0].price == 1200)

        // SUCCESS: This proves no getValue() was called, as record doesn't exist
        // If regular IndexScanTypedCursor were used, it would fail at getValue()
    }

    // MARK: - Helper Methods

    private func setupDatabase() async throws -> any DatabaseProtocol {
        let database = try FDBClient.openDatabase()

        // Clear test data - use the same prefix that tests use ([0x01])
        let testSubspace = Subspace(prefix: [0x01])
        try await database.withTransaction { transaction in
            transaction.clearRange(beginKey: testSubspace.prefix, endKey: testSubspace.prefix + [0xFF])
        }

        return database
    }

    private func cleanupDatabase(_ database: any DatabaseProtocol) {
        // Cleanup is handled by transaction isolation
    }
}
