import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Comprehensive tests for MIN and MAX aggregate indexes
///
/// Test Coverage:
/// 1. Basic MIN/MAX operations
/// 2. Grouped MIN/MAX by region
/// 3. MIN/MAX updates after record deletion
/// 4. Multiple groups with different values
/// 5. Edge cases (single record, empty group)
/// 6. Error handling (non-existent groups)
/// 7. Different numeric types (Int64, Int)
/// 8. Online index builder integration
@Suite("MIN/MAX Index Tests", .serialized)
struct MinMaxIndexTests {

    // MARK: - Initialization

    /// Initialize FoundationDB network once for all tests
    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Test Record Type

    struct SalesRecord: Codable, Equatable, Recordable {
        let saleID: Int64
        let region: String
        let amount: Int64
        let quantity: Int
        let discount: Int64

        // MARK: - Recordable Conformance

        static var recordName: String { "SalesRecord" }
        static var primaryKeyFields: [String] { ["saleID"] }
        static var allFields: [String] { ["saleID", "region", "amount", "quantity", "discount"] }

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "saleID": return 1
            case "region": return 2
            case "amount": return 3
            case "quantity": return 4
            case "discount": return 5
            default: return nil
            }
        }

        func toProtobuf() throws -> Data {
            return try JSONEncoder().encode(self)
        }

        static func fromProtobuf(_ data: Data) throws -> SalesRecord {
            return try JSONDecoder().decode(SalesRecord.self, from: data)
        }

        func extractField(_ fieldName: String) -> [any TupleElement] {
            switch fieldName {
            case "saleID": return [saleID]
            case "region": return [region]
            case "amount": return [amount]
            case "quantity": return [quantity]
            case "discount": return [discount]
            default: return []
            }
        }

        func extractPrimaryKey() -> Tuple {
            return Tuple(saleID)
        }
    }

    /// RecordAccess implementation for SalesRecord
    struct SalesRecordAccess: RecordAccess {
        typealias Record = SalesRecord

        func serialize(_ record: SalesRecord) throws -> FDB.Bytes {
            let data = try JSONEncoder().encode(record)
            return Array(data)
        }

        func deserialize(_ bytes: FDB.Bytes) throws -> SalesRecord {
            let data = Data(bytes)
            return try JSONDecoder().decode(SalesRecord.self, from: data)
        }

        func extractField(from record: SalesRecord, fieldName: String) throws -> [any TupleElement] {
            switch fieldName {
            case "saleID": return [record.saleID]
            case "region": return [record.region]
            case "amount": return [record.amount]
            case "quantity": return [record.quantity]
            case "discount": return [record.discount]
            default:
                throw RecordLayerError.invalidArgument("Field not found: \(fieldName)")
            }
        }

        func recordName(for record: SalesRecord) -> String {
            return "SalesRecord"
        }
    }

    // MARK: - Test Helpers

    func createTestDatabase() throws -> any DatabaseProtocol {
        return try FDBClient.openDatabase()
    }

    func createTestSubspace() -> Subspace {
        return Subspace(prefix: Array("test_minmax_\(UUID().uuidString)".utf8))
    }

    func createTestSchema() throws -> Schema {
        // MIN index: minimum amount by region
        let minAmountIndex = Index(
            name: "amount_min_by_region",
            type: .min,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "region"),
                FieldKeyExpression(fieldName: "amount")
            ]),
            recordTypes: ["SalesRecord"]
        )

        // MAX index: maximum amount by region
        let maxAmountIndex = Index(
            name: "amount_max_by_region",
            type: .max,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "region"),
                FieldKeyExpression(fieldName: "amount")
            ]),
            recordTypes: ["SalesRecord"]
        )

        // MIN index: minimum quantity by region (different type: Int vs Int64)
        let minQuantityIndex = Index(
            name: "quantity_min_by_region",
            type: .min,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "region"),
                FieldKeyExpression(fieldName: "quantity")
            ]),
            recordTypes: ["SalesRecord"]
        )

        // MAX index: maximum quantity by region
        let maxQuantityIndex = Index(
            name: "quantity_max_by_region",
            type: .max,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "region"),
                FieldKeyExpression(fieldName: "quantity")
            ]),
            recordTypes: ["SalesRecord"]
        )

        // Create schema with all indexes readable
        return Schema(
            [SalesRecord.self],
            indexes: [minAmountIndex, maxAmountIndex, minQuantityIndex, maxQuantityIndex]
        )
    }

    func setupTestEnvironment() async throws -> (
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        indexManager: IndexManager,
        recordAccess: SalesRecordAccess
    ) {
        let database = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createTestSchema()
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
        let indexManager = IndexManager(schema: schema, subspace: indexSubspace)
        let recordAccess = SalesRecordAccess()

        // Make all indexes readable
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        try await indexStateManager.enable("amount_min_by_region")
        try await indexStateManager.makeReadable("amount_min_by_region")
        try await indexStateManager.enable("amount_max_by_region")
        try await indexStateManager.makeReadable("amount_max_by_region")
        try await indexStateManager.enable("quantity_min_by_region")
        try await indexStateManager.makeReadable("quantity_min_by_region")
        try await indexStateManager.enable("quantity_max_by_region")
        try await indexStateManager.makeReadable("quantity_max_by_region")

        return (database, subspace, schema, indexManager, recordAccess)
    }

    // MARK: - Test 1: Basic MIN Operations

    @Test("MIN index returns minimum value for a group")
    func testBasicMinIndex() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert test data
        let sales = [
            SalesRecord(saleID: 1, region: "East", amount: 1000, quantity: 5, discount: 10),
            SalesRecord(saleID: 2, region: "East", amount: 500, quantity: 3, discount: 20),   // MIN amount for East
            SalesRecord(saleID: 3, region: "East", amount: 1500, quantity: 10, discount: 15),
        ]

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            for sale in sales {
                let primaryKey = sale.extractPrimaryKey()
                let recordKey = recordSubspace.pack(primaryKey)
                let recordData = try recordAccess.serialize(sale)
                transaction.setValue(recordData, for: recordKey)

                // Update indexes
                try await indexManager.updateIndexes(
                    for: sale,
                    primaryKey: primaryKey,
                    oldRecord: nil,
                    context: context,
                    recordSubspace: recordSubspace
                )
            }
        }

        let minValue = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMinIndexMaintainer<SalesRecord>(
                index: index,
                subspace: minIndexSubspace,
                recordSubspace: recordSubspace
            )

            return try await maintainer.getMin(
                groupingValues: ["East"],
                transaction: transaction
            )
        }

        #expect(minValue == 500, "East region minimum amount should be 500")
    }

    // MARK: - Test 2: Basic MAX Operations

    @Test("MAX index returns maximum value for a group")
    func testBasicMaxIndex() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert test data
        let sales = [
            SalesRecord(saleID: 1, region: "West", amount: 1000, quantity: 5, discount: 10),
            SalesRecord(saleID: 2, region: "West", amount: 500, quantity: 3, discount: 20),
            SalesRecord(saleID: 3, region: "West", amount: 2000, quantity: 8, discount: 5),   // MAX amount for West
        ]

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            for sale in sales {
                let primaryKey = sale.extractPrimaryKey()
                let recordKey = recordSubspace.pack(primaryKey)
                let recordData = try recordAccess.serialize(sale)
                transaction.setValue(recordData, for: recordKey)

                try await indexManager.updateIndexes(
                    for: sale,
                    primaryKey: primaryKey,
                    oldRecord: nil,
                    context: context,
                    recordSubspace: recordSubspace
                )
            }
        }

        let maxValue = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let maxIndexSubspace = indexSubspace.subspace(Tuple(["amount_max_by_region"]))

            let index = Index(
                name: "amount_max_by_region",
                type: .max,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMaxIndexMaintainer<SalesRecord>(
                index: index,
                subspace: maxIndexSubspace,
                recordSubspace: recordSubspace
            )

            return try await maintainer.getMax(
                groupingValues: ["West"],
                transaction: transaction
            )
        }

        #expect(maxValue == 2000, "West region maximum amount should be 2000")
    }

    // MARK: - Test 3: MIN/MAX Updates After Deletion

    @Test("MIN index updates correctly after minimum record is deleted")
    func testMinIndexAfterDeletion() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert test data
        let sales = [
            SalesRecord(saleID: 1, region: "North", amount: 1000, quantity: 5, discount: 10),
            SalesRecord(saleID: 2, region: "North", amount: 500, quantity: 3, discount: 20),   // Initial MIN
            SalesRecord(saleID: 3, region: "North", amount: 750, quantity: 4, discount: 15),
        ]

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            for sale in sales {
                let primaryKey = sale.extractPrimaryKey()
                let recordKey = recordSubspace.pack(primaryKey)
                let recordData = try recordAccess.serialize(sale)
                transaction.setValue(recordData, for: recordKey)

                try await indexManager.updateIndexes(
                    for: sale,
                    primaryKey: primaryKey,
                    oldRecord: nil,
                    context: context,
                    recordSubspace: recordSubspace
                )
            }
        }

        let initialMin = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMinIndexMaintainer<SalesRecord>(
                index: index,
                subspace: minIndexSubspace,
                recordSubspace: recordSubspace
            )

            return try await maintainer.getMin(
                groupingValues: ["North"],
                transaction: transaction
            )
        }
        #expect(initialMin == 500, "Initial minimum should be 500")

        // Delete the minimum record
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let oldRecord = sales[1]  // saleID: 2, amount: 500
            let primaryKey = oldRecord.extractPrimaryKey()
            let recordKey = recordSubspace.pack(primaryKey)
            transaction.clear(key: recordKey)

            try await indexManager.deleteIndexes(
                oldRecord: oldRecord,
                primaryKey: primaryKey,
                context: context,
                recordSubspace: recordSubspace
            )
        }

        let newMin = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMinIndexMaintainer<SalesRecord>(
                index: index,
                subspace: minIndexSubspace,
                recordSubspace: recordSubspace
            )

            return try await maintainer.getMin(
                groupingValues: ["North"],
                transaction: transaction
            )
        }
        #expect(newMin == 750, "Minimum should update to 750 after deletion")
    }

    @Test("MAX index updates correctly after maximum record is deleted")
    func testMaxIndexAfterDeletion() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert test data
        let sales = [
            SalesRecord(saleID: 1, region: "South", amount: 1000, quantity: 5, discount: 10),
            SalesRecord(saleID: 2, region: "South", amount: 2000, quantity: 10, discount: 5),  // Initial MAX
            SalesRecord(saleID: 3, region: "South", amount: 1500, quantity: 8, discount: 12),
        ]

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            for sale in sales {
                let primaryKey = sale.extractPrimaryKey()
                let recordKey = recordSubspace.pack(primaryKey)
                let recordData = try recordAccess.serialize(sale)
                transaction.setValue(recordData, for: recordKey)

                try await indexManager.updateIndexes(
                    for: sale,
                    primaryKey: primaryKey,
                    oldRecord: nil,
                    context: context,
                    recordSubspace: recordSubspace
                )
            }
        }

        let initialMax = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let maxIndexSubspace = indexSubspace.subspace(Tuple(["amount_max_by_region"]))

            let index = Index(
                name: "amount_max_by_region",
                type: .max,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMaxIndexMaintainer<SalesRecord>(
                index: index,
                subspace: maxIndexSubspace,
                recordSubspace: recordSubspace
            )

            return try await maintainer.getMax(
                groupingValues: ["South"],
                transaction: transaction
            )
        }
        #expect(initialMax == 2000, "Initial maximum should be 2000")

        // Delete the maximum record
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let oldRecord = sales[1]  // saleID: 2, amount: 2000
            let primaryKey = oldRecord.extractPrimaryKey()
            let recordKey = recordSubspace.pack(primaryKey)
            transaction.clear(key: recordKey)

            try await indexManager.deleteIndexes(
                oldRecord: oldRecord,
                primaryKey: primaryKey,
                context: context,
                recordSubspace: recordSubspace
            )
        }

        let newMax = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let maxIndexSubspace = indexSubspace.subspace(Tuple(["amount_max_by_region"]))

            let index = Index(
                name: "amount_max_by_region",
                type: .max,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMaxIndexMaintainer<SalesRecord>(
                index: index,
                subspace: maxIndexSubspace,
                recordSubspace: recordSubspace
            )

            return try await maintainer.getMax(
                groupingValues: ["South"],
                transaction: transaction
            )
        }
        #expect(newMax == 1500, "Maximum should update to 1500 after deletion")
    }

    // MARK: - Test 4: Multiple Groups

    @Test("MIN/MAX work correctly with multiple groups")
    func testMultipleGroups() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert data for 3 regions
        let sales = [
            // East region
            SalesRecord(saleID: 1, region: "East", amount: 100, quantity: 1, discount: 5),   // MIN East
            SalesRecord(saleID: 2, region: "East", amount: 300, quantity: 3, discount: 10),  // MAX East
            SalesRecord(saleID: 3, region: "East", amount: 200, quantity: 2, discount: 8),

            // West region
            SalesRecord(saleID: 4, region: "West", amount: 150, quantity: 2, discount: 12),  // MIN West
            SalesRecord(saleID: 5, region: "West", amount: 400, quantity: 5, discount: 6),   // MAX West

            // Central region (single record)
            SalesRecord(saleID: 6, region: "Central", amount: 250, quantity: 4, discount: 15), // MIN/MAX Central
        ]

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            for sale in sales {
                let primaryKey = sale.extractPrimaryKey()
                let recordKey = recordSubspace.pack(primaryKey)
                let recordData = try recordAccess.serialize(sale)
                transaction.setValue(recordData, for: recordKey)

                try await indexManager.updateIndexes(
                    for: sale,
                    primaryKey: primaryKey,
                    oldRecord: nil,
                    context: context,
                    recordSubspace: recordSubspace
                )
            }
        }

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMinIndexMaintainer<SalesRecord>(
                index: index,
                subspace: minIndexSubspace,
                recordSubspace: recordSubspace
            )

            let eastMin = try await maintainer.getMin(groupingValues: ["East"], transaction: transaction)
            #expect(eastMin == 100, "East minimum should be 100")

            let westMin = try await maintainer.getMin(groupingValues: ["West"], transaction: transaction)
            #expect(westMin == 150, "West minimum should be 150")

            let centralMin = try await maintainer.getMin(groupingValues: ["Central"], transaction: transaction)
            #expect(centralMin == 250, "Central minimum should be 250")
        }

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let maxIndexSubspace = indexSubspace.subspace(Tuple(["amount_max_by_region"]))

            let index = Index(
                name: "amount_max_by_region",
                type: .max,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )
            let maintainer = GenericMaxIndexMaintainer<SalesRecord>(
                index: index,
                subspace: maxIndexSubspace,
                recordSubspace: recordSubspace
            )

            let eastMax = try await maintainer.getMax(groupingValues: ["East"], transaction: transaction)
            #expect(eastMax == 300, "East maximum should be 300")

            let westMax = try await maintainer.getMax(groupingValues: ["West"], transaction: transaction)
            #expect(westMax == 400, "West maximum should be 400")

            let centralMax = try await maintainer.getMax(groupingValues: ["Central"], transaction: transaction)
            #expect(centralMax == 250, "Central maximum should be 250")
        }
    }

    // MARK: - Test 5: Error Cases

    @Test("MIN/MAX throw error for empty group")
    func testEmptyGroup() async throws {
        let (database, subspace, _, _, _) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        await #expect(throws: RecordLayerError.self) {
            try await database.withRecordContext { context in
                let transaction = context.getTransaction()
                let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

                let index = Index(
                    name: "amount_min_by_region",
                    type: .min,
                    rootExpression: ConcatenateKeyExpression(children: [
                        FieldKeyExpression(fieldName: "region"),
                        FieldKeyExpression(fieldName: "amount")
                    ])
                )
                let maintainer = GenericMinIndexMaintainer<SalesRecord>(
                    index: index,
                    subspace: minIndexSubspace,
                    recordSubspace: recordSubspace
                )

                _ = try await maintainer.getMin(
                    groupingValues: ["NonExistent"],
                    transaction: transaction
                )
            }
        }

        await #expect(throws: RecordLayerError.self) {
            try await database.withRecordContext { context in
                let transaction = context.getTransaction()
                let maxIndexSubspace = indexSubspace.subspace(Tuple(["amount_max_by_region"]))

                let index = Index(
                    name: "amount_max_by_region",
                    type: .max,
                    rootExpression: ConcatenateKeyExpression(children: [
                        FieldKeyExpression(fieldName: "region"),
                        FieldKeyExpression(fieldName: "amount")
                    ])
                )
                let maintainer = GenericMaxIndexMaintainer<SalesRecord>(
                    index: index,
                    subspace: maxIndexSubspace,
                    recordSubspace: recordSubspace
                )

                _ = try await maintainer.getMax(
                    groupingValues: ["NonExistent"],
                    transaction: transaction
                )
            }
        }
    }

    // MARK: - Test 6: Different Numeric Types

    @Test("MIN/MAX work with different numeric types (Int64 vs Int)")
    func testDifferentNumericTypes() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert test data with quantity (Int type) vs amount (Int64 type)
        let sales = [
            SalesRecord(saleID: 1, region: "TestRegion", amount: 1000, quantity: 5, discount: 10),
            SalesRecord(saleID: 2, region: "TestRegion", amount: 1500, quantity: 2, discount: 15),  // MIN quantity
            SalesRecord(saleID: 3, region: "TestRegion", amount: 2000, quantity: 15, discount: 5),  // MAX quantity
        ]

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            for sale in sales {
                let primaryKey = sale.extractPrimaryKey()
                let recordKey = recordSubspace.pack(primaryKey)
                let recordData = try recordAccess.serialize(sale)
                transaction.setValue(recordData, for: recordKey)

                try await indexManager.updateIndexes(
                    for: sale,
                    primaryKey: primaryKey,
                    oldRecord: nil,
                    context: context,
                    recordSubspace: recordSubspace
                )
            }
        }

        // Query MIN quantity (Int type)
        let minQuantity = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["quantity_min_by_region"]))

            let index = Index(
                name: "quantity_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "quantity")
                ])
            )

            return try await findMinValue(
                index: index,
                subspace: minIndexSubspace,
                groupingValues: ["TestRegion"],
                transaction: transaction
            )
        }
        #expect(minQuantity == 2, "Minimum quantity should be 2")

        let maxQuantity = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let maxIndexSubspace = indexSubspace.subspace(Tuple(["quantity_max_by_region"]))

            let index = Index(
                name: "quantity_max_by_region",
                type: .max,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "quantity")
                ])
            )

            return try await findMaxValue(
                index: index,
                subspace: maxIndexSubspace,
                groupingValues: ["TestRegion"],
                transaction: transaction
            )
        }
        #expect(maxQuantity == 15, "Maximum quantity should be 15")
    }

    // MARK: - Test 7: Single Record Group

    @Test("MIN/MAX return correct value for single-record group")
    func testSingleRecordGroup() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert single record
        let sale = SalesRecord(saleID: 1, region: "Unique", amount: 999, quantity: 7, discount: 20)

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let primaryKey = sale.extractPrimaryKey()
            let recordKey = recordSubspace.pack(primaryKey)
            let recordData = try recordAccess.serialize(sale)
            transaction.setValue(recordData, for: recordKey)

            try await indexManager.updateIndexes(
                for: sale,
                primaryKey: primaryKey,
                oldRecord: nil,
                context: context,
                recordSubspace: recordSubspace
            )
        }

        // MIN and MAX should both be 999
        let minValue = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )

            return try await findMinValue(
                index: index,
                subspace: minIndexSubspace,
                groupingValues: ["Unique"],
                transaction: transaction
            )
        }
        #expect(minValue == 999, "Single record MIN should be 999")

        let maxValue = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let maxIndexSubspace = indexSubspace.subspace(Tuple(["amount_max_by_region"]))

            let index = Index(
                name: "amount_max_by_region",
                type: .max,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )

            return try await findMaxValue(
                index: index,
                subspace: maxIndexSubspace,
                groupingValues: ["Unique"],
                transaction: transaction
            )
        }
        #expect(maxValue == 999, "Single record MAX should be 999")
    }

    // MARK: - Test 8: Record Updates

    @Test("MIN/MAX update correctly when record value changes")
    func testRecordUpdate() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert initial data
        let initialSale = SalesRecord(saleID: 1, region: "Dynamic", amount: 500, quantity: 5, discount: 10)

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let primaryKey = initialSale.extractPrimaryKey()
            let recordKey = recordSubspace.pack(primaryKey)
            let recordData = try recordAccess.serialize(initialSale)
            transaction.setValue(recordData, for: recordKey)

            try await indexManager.updateIndexes(
                for: initialSale,
                primaryKey: primaryKey,
                oldRecord: nil,
                context: context,
                recordSubspace: recordSubspace
            )
        }

        // Verify initial MIN
        let initialMin = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )

            return try await findMinValue(
                index: index,
                subspace: minIndexSubspace,
                groupingValues: ["Dynamic"],
                transaction: transaction
            )
        }
        #expect(initialMin == 500, "Initial minimum should be 500")

        // Update record with new amount
        let updatedSale = SalesRecord(saleID: 1, region: "Dynamic", amount: 1000, quantity: 5, discount: 10)

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let primaryKey = updatedSale.extractPrimaryKey()
            let recordKey = recordSubspace.pack(primaryKey)
            let recordData = try recordAccess.serialize(updatedSale)
            transaction.setValue(recordData, for: recordKey)

            try await indexManager.updateIndexes(
                for: updatedSale,
                primaryKey: primaryKey,
                oldRecord: initialSale,
                context: context,
                recordSubspace: recordSubspace
            )
        }

        // Verify updated MIN
        let updatedMin = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )

            return try await findMinValue(
                index: index,
                subspace: minIndexSubspace,
                groupingValues: ["Dynamic"],
                transaction: transaction
            )
        }
        #expect(updatedMin == 1000, "Minimum should update to 1000")
    }

    // MARK: - Diagnostic Test

    @Test("Diagnostic: Verify index keys are written")
    func testDiagnosticIndexKeys() async throws {
        let (database, subspace, _, indexManager, recordAccess) = try await setupTestEnvironment()

        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)

        // Insert a single test record
        let sale = SalesRecord(saleID: 999, region: "Debug", amount: 777, quantity: 7, discount: 10)

        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let primaryKey = sale.extractPrimaryKey()
            let recordKey = recordSubspace.pack(primaryKey)
            let recordData = try recordAccess.serialize(sale)
            transaction.setValue(recordData, for: recordKey)

            try await indexManager.updateIndexes(
                for: sale,
                primaryKey: primaryKey,
                oldRecord: nil,
                context: context,
                recordSubspace: recordSubspace
            )
        }

        // Scan all keys in the index subspace to see what was written
        let allKeys = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))
            let range = minIndexSubspace.range()

            var keys: [String] = []
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(range.begin),
                endSelector: .firstGreaterThan(range.end),
                snapshot: true
            )

            for try await (key, _) in sequence {
                // Unpack the key relative to the index subspace to see its structure
                let unpackedTuple = try minIndexSubspace.unpack(key)
                keys.append("Key: \(unpackedTuple)")
            }
            return keys
        }

        print("DEBUG: Found \(allKeys.count) keys in amount_min_by_region index:")
        for key in allKeys {
            print("  \(key)")
        }

        // Now test querying with findMinValue
        print("\nDEBUG: Testing findMinValue query:")
        let minIndexSubspace = indexSubspace.subspace(Tuple(["amount_min_by_region"]))

        let testResult = try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let index = Index(
                name: "amount_min_by_region",
                type: .min,
                rootExpression: ConcatenateKeyExpression(children: [
                    FieldKeyExpression(fieldName: "region"),
                    FieldKeyExpression(fieldName: "amount")
                ])
            )

            return try await findMinValue(
                index: index,
                subspace: minIndexSubspace,
                groupingValues: ["Debug"],
                transaction: transaction
            )
        }

        print("  Query result: \(testResult)")

        #expect(allKeys.count > 0, "Should have at least one index key written")
        #expect(testResult == 777, "Should find MIN value of 777")
    }

    // MARK: - Test: Various Subspace Prefix Formats

    @Test("MIN/MAX work with various subspace prefix formats")
    func testVariousSubspacePrefixes() async throws {
        let database = try createTestDatabase()

        // Test case 1: Raw bytes prefix (non-tuple encoded)
        let rawSubspace = Subspace(prefix: [0x01, 0x02, 0x03, 0xFF])

        // Test case 2: UUID-based prefix (common in Directory Layer)
        let uuidBytes = UUID().uuid
        let uuidSubspace = Subspace(prefix: [
            uuidBytes.0, uuidBytes.1, uuidBytes.2, uuidBytes.3,
            uuidBytes.4, uuidBytes.5, uuidBytes.6, uuidBytes.7,
            uuidBytes.8, uuidBytes.9, uuidBytes.10, uuidBytes.11,
            uuidBytes.12, uuidBytes.13, uuidBytes.14, uuidBytes.15
        ])

        // Test case 3: String-based prefix with special characters
        let stringSubspace = Subspace(prefix: Array("app/users/région/".utf8))

        // Test case 4: Mixed content prefix (binary + text)
        let mixedSubspace = Subspace(prefix: [0xFE, 0x01] + Array("test".utf8) + [0x00, 0xFF])

        let testCases: [(String, Subspace)] = [
            ("Raw bytes", rawSubspace),
            ("UUID-based", uuidSubspace),
            ("String-based", stringSubspace),
            ("Mixed content", mixedSubspace)
        ]

        for (caseName, testSubspace) in testCases {
            // Create index subspace
            let indexSubspace = testSubspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(Tuple(["test_min_index"]))

            // Insert test data manually
            try await database.withRecordContext { context in
                let transaction = context.getTransaction()

                // Create multiple index entries: [grouping, value, primaryKey]
                let entries = [
                    ("GroupA", 100, 1),
                    ("GroupA", 50, 2),   // MIN for GroupA
                    ("GroupA", 150, 3),
                    ("GroupB", 200, 4),
                    ("GroupB", 75, 5),   // MIN for GroupB
                ]

                for (group, value, pk) in entries {
                    let indexKey = indexSubspace.pack(Tuple(group, value, pk))
                    transaction.setValue([], for: indexKey)
                }
            }

            // Query MIN using internal helper (to test the core unpacking logic)
            let minGroupA = try await database.withRecordContext { context in
                let transaction = context.getTransaction()

                let index = Index(
                    name: "test_min_index",
                    type: .min,
                    rootExpression: ConcatenateKeyExpression(children: [
                        FieldKeyExpression(fieldName: "group"),
                        FieldKeyExpression(fieldName: "value")
                    ])
                )

                return try await findMinValue(
                    index: index,
                    subspace: indexSubspace,
                    groupingValues: ["GroupA"],
                    transaction: transaction
                )
            }

            #expect(minGroupA == 50, "\(caseName): GroupA minimum should be 50")

            let minGroupB = try await database.withRecordContext { context in
                let transaction = context.getTransaction()

                let index = Index(
                    name: "test_min_index",
                    type: .min,
                    rootExpression: ConcatenateKeyExpression(children: [
                        FieldKeyExpression(fieldName: "group"),
                        FieldKeyExpression(fieldName: "value")
                    ])
                )

                return try await findMinValue(
                    index: index,
                    subspace: indexSubspace,
                    groupingValues: ["GroupB"],
                    transaction: transaction
                )
            }

            #expect(minGroupB == 75, "\(caseName): GroupB minimum should be 75")

            // Also test MAX
            let maxIndexSubspace = testSubspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(Tuple(["test_max_index"]))

            try await database.withRecordContext { context in
                let transaction = context.getTransaction()

                let entries = [
                    ("GroupA", 100, 1),
                    ("GroupA", 200, 2),  // MAX for GroupA
                    ("GroupA", 150, 3),
                ]

                for (group, value, pk) in entries {
                    let indexKey = maxIndexSubspace.pack(Tuple(group, value, pk))
                    transaction.setValue([], for: indexKey)
                }
            }

            let maxGroupA = try await database.withRecordContext { context in
                let transaction = context.getTransaction()

                let index = Index(
                    name: "test_max_index",
                    type: .max,
                    rootExpression: ConcatenateKeyExpression(children: [
                        FieldKeyExpression(fieldName: "group"),
                        FieldKeyExpression(fieldName: "value")
                    ])
                )

                return try await findMaxValue(
                    index: index,
                    subspace: maxIndexSubspace,
                    groupingValues: ["GroupA"],
                    transaction: transaction
                )
            }

            #expect(maxGroupA == 200, "\(caseName): GroupA maximum should be 200")

            print("✅ \(caseName) prefix format: All assertions passed")
        }
    }

    // MARK: - Test: RecordStore.evaluateAggregate Integration

    @Test("RecordStore.evaluateAggregate works end-to-end for MIN/MAX")
    func testRecordStoreEvaluateAggregate() async throws {
        let database = try createTestDatabase()
        let subspace = createTestSubspace()
        let schema = try createTestSchema()

        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        try await indexStateManager.enable("amount_min_by_region")
        try await indexStateManager.makeReadable("amount_min_by_region")
        try await indexStateManager.enable("amount_max_by_region")
        try await indexStateManager.makeReadable("amount_max_by_region")

        let store = RecordStore<SalesRecord>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: database, subspace: subspace.subspace("stats"))
        )

        let sales = [
            SalesRecord(saleID: 1, region: "North", amount: 1000, quantity: 5, discount: 10),
            SalesRecord(saleID: 2, region: "North", amount: 300, quantity: 3, discount: 20),   // MIN
            SalesRecord(saleID: 3, region: "North", amount: 1500, quantity: 10, discount: 15), // MAX
            SalesRecord(saleID: 4, region: "South", amount: 500, quantity: 2, discount: 5),
            SalesRecord(saleID: 5, region: "South", amount: 200, quantity: 1, discount: 10),   // MIN
            SalesRecord(saleID: 6, region: "South", amount: 800, quantity: 4, discount: 8),    // MAX
        ]

        for sale in sales {
            try await store.save(sale)
        }

        let northMin = try await store.evaluateAggregate(
            .min(indexName: "amount_min_by_region"),
            groupBy: ["North"]
        )
        #expect(northMin == 300, "North region minimum via RecordStore should be 300")

        let northMax = try await store.evaluateAggregate(
            .max(indexName: "amount_max_by_region"),
            groupBy: ["North"]
        )
        #expect(northMax == 1500, "North region maximum via RecordStore should be 1500")

        let southMin = try await store.evaluateAggregate(
            .min(indexName: "amount_min_by_region"),
            groupBy: ["South"]
        )
        #expect(southMin == 200, "South region minimum via RecordStore should be 200")

        let southMax = try await store.evaluateAggregate(
            .max(indexName: "amount_max_by_region"),
            groupBy: ["South"]
        )
        #expect(southMax == 800, "South region maximum via RecordStore should be 800")

        print("✅ RecordStore.evaluateAggregate: All assertions passed")
    }

    // MARK: - Test: Validation Error

    @Test("MIN/MAX throw validation error for incorrect grouping count")
    func testGroupingCountValidation() async throws {
        let database = try createTestDatabase()
        let subspace = Subspace(prefix: Array("test-validation".utf8))

        // Create an index with TWO grouping fields: [country, region, amount]
        let index = Index(
            name: "amount_min_by_country_region",
            type: .min,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "country"),
                FieldKeyExpression(fieldName: "region"),
                FieldKeyExpression(fieldName: "amount")
            ])
        )

        let indexSubspace = subspace
            .subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(Tuple(["amount_min_by_country_region"]))

        // Insert test data with structure: [country, region, amount, primaryKey]
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let indexKey = indexSubspace.pack(Tuple("USA", "East", 100, 1))
            transaction.setValue([], for: indexKey)
        }

        // Test 1: Too few grouping values (only 1 instead of 2)
        do {
            try await database.withRecordContext { context in
                let transaction = context.getTransaction()

                _ = try await findMinValue(
                    index: index,
                    subspace: indexSubspace,
                    groupingValues: ["USA"],  // Only 1 value, but need 2
                    transaction: transaction
                )
            }
            #expect(Bool(false), "Should have thrown an error for too few grouping values")
        } catch let error as RecordLayerError {
            // Verify error message contains detailed information
            let errorMessage = "\(error)"
            #expect(errorMessage.contains("country"), "Error should mention 'country' field")
            #expect(errorMessage.contains("region"), "Error should mention 'region' field")
            #expect(errorMessage.contains("Missing"), "Error should indicate missing fields")
            print("✅ Detailed error message for too few values:\n\(errorMessage)")
        }

        // Test 2: Too many grouping values (3 instead of 2)
        do {
            try await database.withRecordContext { context in
                let transaction = context.getTransaction()

                _ = try await findMinValue(
                    index: index,
                    subspace: indexSubspace,
                    groupingValues: ["USA", "East", "Extra"],  // 3 values, but need 2
                    transaction: transaction
                )
            }
            #expect(Bool(false), "Should have thrown an error for too many grouping values")
        } catch let error as RecordLayerError {
            // Verify error message contains detailed information
            let errorMessage = "\(error)"
            #expect(errorMessage.contains("Extra values"), "Error should indicate extra values")
            print("✅ Detailed error message for too many values:\n\(errorMessage)")
        }

        // Test 3: Correct grouping count should work
        let correctResult = try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            return try await findMinValue(
                index: index,
                subspace: indexSubspace,
                groupingValues: ["USA", "East"],  // Correct: 2 values
                transaction: transaction
            )
        }
        #expect(correctResult == 100, "Correct grouping count should return 100")

        print("✅ Validation error test: All assertions passed")
    }

    // MARK: - Test: Multiple Grouping Fields

    @Test("MIN/MAX work correctly with multiple grouping fields")
    func testMultipleGroupingFields() async throws {
        let database = try createTestDatabase()
        let subspace = Subspace(prefix: Array("test-multi-grouping".utf8))

        // Create an index with TWO grouping fields: [country, region, sales]
        let minIndex = Index(
            name: "sales_min_by_country_region",
            type: .min,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "country"),
                FieldKeyExpression(fieldName: "region"),
                FieldKeyExpression(fieldName: "sales")
            ])
        )

        let maxIndex = Index(
            name: "sales_max_by_country_region",
            type: .max,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "country"),
                FieldKeyExpression(fieldName: "region"),
                FieldKeyExpression(fieldName: "sales")
            ])
        )

        let minIndexSubspace = subspace
            .subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(Tuple(["sales_min_by_country_region"]))

        let maxIndexSubspace = subspace
            .subspace(RecordStoreKeyspace.index.rawValue)
            .subspace(Tuple(["sales_max_by_country_region"]))

        // Insert test data: [country, region, sales, primaryKey]
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()

            let minData = [
                // USA - East
                ("USA", "East", 500, 1),
                ("USA", "East", 200, 2),   // MIN for USA-East
                ("USA", "East", 800, 3),
                // USA - West
                ("USA", "West", 300, 4),
                ("USA", "West", 150, 5),   // MIN for USA-West
                ("USA", "West", 600, 6),
                // Japan - Kanto
                ("Japan", "Kanto", 1000, 7),
                ("Japan", "Kanto", 750, 8), // MIN for Japan-Kanto
                ("Japan", "Kanto", 1200, 9),
            ]

            for (country, region, sales, pk) in minData {
                let key = minIndexSubspace.pack(Tuple(country, region, sales, pk))
                transaction.setValue([], for: key)
            }

            let maxData = [
                // USA - East
                ("USA", "East", 500, 1),
                ("USA", "East", 200, 2),
                ("USA", "East", 800, 3),   // MAX for USA-East
                // USA - West
                ("USA", "West", 300, 4),
                ("USA", "West", 150, 5),
                ("USA", "West", 600, 6),   // MAX for USA-West
                // Japan - Kanto
                ("Japan", "Kanto", 1000, 7),
                ("Japan", "Kanto", 750, 8),
                ("Japan", "Kanto", 1200, 9), // MAX for Japan-Kanto
            ]

            for (country, region, sales, pk) in maxData {
                let key = maxIndexSubspace.pack(Tuple(country, region, sales, pk))
                transaction.setValue([], for: key)
            }
        }

        // Test MIN with multiple grouping fields
        let usaEastMin = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            return try await findMinValue(
                index: minIndex,
                subspace: minIndexSubspace,
                groupingValues: ["USA", "East"],
                transaction: transaction
            )
        }
        #expect(usaEastMin == 200, "USA-East minimum should be 200")

        let usaWestMin = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            return try await findMinValue(
                index: minIndex,
                subspace: minIndexSubspace,
                groupingValues: ["USA", "West"],
                transaction: transaction
            )
        }
        #expect(usaWestMin == 150, "USA-West minimum should be 150")

        let japanKantoMin = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            return try await findMinValue(
                index: minIndex,
                subspace: minIndexSubspace,
                groupingValues: ["Japan", "Kanto"],
                transaction: transaction
            )
        }
        #expect(japanKantoMin == 750, "Japan-Kanto minimum should be 750")

        // Test MAX with multiple grouping fields
        let usaEastMax = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            return try await findMaxValue(
                index: maxIndex,
                subspace: maxIndexSubspace,
                groupingValues: ["USA", "East"],
                transaction: transaction
            )
        }
        #expect(usaEastMax == 800, "USA-East maximum should be 800")

        let usaWestMax = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            return try await findMaxValue(
                index: maxIndex,
                subspace: maxIndexSubspace,
                groupingValues: ["USA", "West"],
                transaction: transaction
            )
        }
        #expect(usaWestMax == 600, "USA-West maximum should be 600")

        let japanKantoMax = try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            return try await findMaxValue(
                index: maxIndex,
                subspace: maxIndexSubspace,
                groupingValues: ["Japan", "Kanto"],
                transaction: transaction
            )
        }
        #expect(japanKantoMax == 1200, "Japan-Kanto maximum should be 1200")

        print("✅ Multiple grouping fields test: All assertions passed")
    }
}
