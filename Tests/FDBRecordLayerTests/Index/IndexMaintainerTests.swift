import Testing
import Foundation
import FoundationDB
@testable import FDBRecordLayer

@Suite("IndexMaintainer Tests", .disabled("Requires running FoundationDB instance"))
struct IndexMaintainerTests {

    // MARK: - Test Helpers

    func createDatabase() throws -> any DatabaseProtocol {
        return try FDBClient.openDatabase()
    }

    func cleanup(database: any DatabaseProtocol, subspace: Subspace) async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - ValueIndex Tests

    @Test("ValueIndex creates correct index entries on insert")
    func valueIndexInsert() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_value_index_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("email_index")
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        let emailIndex = Index(
            name: "email_index",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let maintainer = ValueIndexMaintainer(
            index: emailIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            let record: [String: Any] = [
                "id": Int64(1),
                "email": "alice@example.com"
            ]

            // Insert index entry
            let noOldRecord: [String: Any]? = nil
            try await maintainer.updateIndex(
                oldRecord: noOldRecord,
                newRecord: record,
                transaction: transaction
            )

            // Verify index entry exists
            let indexKey = indexSubspace.pack(Tuple("alice@example.com", Int64(1)))
            let value = try await transaction.getValue(for: indexKey)
            #expect(value != nil)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("ValueIndex updates index entries on record update")
    func valueIndexUpdate() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_value_update_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("email_index")
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        let emailIndex = Index(
            name: "email_index",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let maintainer = ValueIndexMaintainer(
            index: emailIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            let oldRecord: [String: Any] = [
                "id": Int64(1),
                "email": "old@example.com"
            ]

            let newRecord: [String: Any] = [
                "id": Int64(1),
                "email": "new@example.com"
            ]

            // Update index (delete old, insert new)
            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: newRecord,
                transaction: transaction
            )

            // Verify old entry is removed
            let oldKey = indexSubspace.pack(Tuple("old@example.com", Int64(1)))
            let oldValue = try await transaction.getValue(for: oldKey)
            #expect(oldValue == nil)

            // Verify new entry exists
            let newKey = indexSubspace.pack(Tuple("new@example.com", Int64(1)))
            let newValue = try await transaction.getValue(for: newKey)
            #expect(newValue != nil)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("ValueIndex removes index entries on delete")
    func valueIndexDelete() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_value_delete_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("email_index")
        let recordSubspace = subspace.subspace(RecordStoreKeyspace.record.rawValue)

        let emailIndex = Index(
            name: "email_index",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let maintainer = ValueIndexMaintainer(
            index: emailIndex,
            subspace: indexSubspace,
            recordSubspace: recordSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            let record: [String: Any] = [
                "id": Int64(1),
                "email": "delete@example.com"
            ]

            // First insert
            let noOldRecord: [String: Any]? = nil
            try await maintainer.updateIndex(
                oldRecord: noOldRecord,
                newRecord: record,
                transaction: transaction
            )

            // Verify entry exists
            let indexKey = indexSubspace.pack(Tuple("delete@example.com", Int64(1)))
            let value1 = try await transaction.getValue(for: indexKey)
            #expect(value1 != nil)

            // Delete
            let noNewRecord: [String: Any]? = nil
            try await maintainer.updateIndex(
                oldRecord: record,
                newRecord: noNewRecord,
                transaction: transaction
            )

            // Verify entry is removed
            let value2 = try await transaction.getValue(for: indexKey)
            #expect(value2 == nil)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    // MARK: - CountIndex Tests

    @Test("CountIndex increments count on insert")
    func countIndexIncrement() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_count_insert_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("city_count")

        let cityCountIndex = Index(
            name: "city_count",
            type: .count,
            rootExpression: FieldKeyExpression(fieldName: "city")
        )

        let maintainer = CountIndexMaintainer(
            index: cityCountIndex,
            subspace: indexSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            // Insert multiple records for same city
            let noOldRecord: [String: Any]? = nil
            for i in 1...3 {
                let record: [String: Any] = [
                    "id": Int64(i),
                    "city": "NYC"
                ]
                try await maintainer.updateIndex(
                    oldRecord: noOldRecord,
                    newRecord: record,
                    transaction: transaction
                )
            }

            // Read count
            let countKey = indexSubspace.pack(Tuple("NYC"))
            let countBytes = try await transaction.getValue(for: countKey)
            #expect(countBytes != nil)

            let count = TupleHelpers.bytesToInt64(countBytes!)
            #expect(count == 3)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("CountIndex decrements count on delete")
    func countIndexDecrement() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_count_delete_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("city_count")

        let cityCountIndex = Index(
            name: "city_count",
            type: .count,
            rootExpression: FieldKeyExpression(fieldName: "city")
        )

        let maintainer = CountIndexMaintainer(
            index: cityCountIndex,
            subspace: indexSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            // Insert 5 records
            let noOldRecord: [String: Any]? = nil
            let noNewRecord: [String: Any]? = nil
            for i in 1...5 {
                let record: [String: Any] = [
                    "id": Int64(i),
                    "city": "SF"
                ]
                try await maintainer.updateIndex(
                    oldRecord: noOldRecord,
                    newRecord: record,
                    transaction: transaction
                )
            }

            // Delete 2 records
            for i in 1...2 {
                let record: [String: Any] = [
                    "id": Int64(i),
                    "city": "SF"
                ]
                try await maintainer.updateIndex(
                    oldRecord: record,
                    newRecord: noNewRecord,
                    transaction: transaction
                )
            }

            // Read count (should be 3)
            let countKey = indexSubspace.pack(Tuple("SF"))
            let countBytes = try await transaction.getValue(for: countKey)
            let count = TupleHelpers.bytesToInt64(countBytes!)
            #expect(count == 3)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("CountIndex handles updates correctly")
    func countIndexUpdate() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_count_update_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("city_count")

        let cityCountIndex = Index(
            name: "city_count",
            type: .count,
            rootExpression: FieldKeyExpression(fieldName: "city")
        )

        let maintainer = CountIndexMaintainer(
            index: cityCountIndex,
            subspace: indexSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            // Insert record
            let noOldRecord: [String: Any]? = nil
            let oldRecord: [String: Any] = ["id": Int64(1), "city": "NYC"]
            try await maintainer.updateIndex(
                oldRecord: noOldRecord,
                newRecord: oldRecord,
                transaction: transaction
            )

            // Update to different city (should decrement NYC, increment LA)
            let newRecord: [String: Any] = ["id": Int64(1), "city": "LA"]
            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: newRecord,
                transaction: transaction
            )

            // Verify NYC count is 0
            let nycKey = indexSubspace.pack(Tuple("NYC"))
            let nycBytes = try await transaction.getValue(for: nycKey)
            let nycCount = nycBytes != nil ? TupleHelpers.bytesToInt64(nycBytes!) : 0
            #expect(nycCount == 0)

            // Verify LA count is 1
            let laKey = indexSubspace.pack(Tuple("LA"))
            let laBytes = try await transaction.getValue(for: laKey)
            let laCount = TupleHelpers.bytesToInt64(laBytes!)
            #expect(laCount == 1)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    // MARK: - SumIndex Tests

    @Test("SumIndex accumulates values correctly")
    func sumIndexAccumulate() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_sum_accumulate_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("city_sales_sum")

        let citySalesIndex = Index(
            name: "city_sales_sum",
            type: .sum,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "city"),
                FieldKeyExpression(fieldName: "sales")
            ])
        )

        let maintainer = SumIndexMaintainer(
            index: citySalesIndex,
            subspace: indexSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            // Insert records with sales amounts
            let noOldRecord: [String: Any]? = nil
            let sales = [100, 200, 150]
            for (i, amount) in sales.enumerated() {
                let record: [String: Any] = [
                    "id": Int64(i + 1),
                    "city": "NYC",
                    "sales": Int64(amount)
                ]
                try await maintainer.updateIndex(
                    oldRecord: noOldRecord,
                    newRecord: record,
                    transaction: transaction
                )
            }

            // Read sum (should be 450)
            let sumKey = indexSubspace.pack(Tuple("NYC"))
            let sumBytes = try await transaction.getValue(for: sumKey)
            let sum = TupleHelpers.bytesToInt64(sumBytes!)
            #expect(sum == 450)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("SumIndex handles updates correctly")
    func sumIndexUpdate() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_sum_update_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("city_sales_sum")

        let citySalesIndex = Index(
            name: "city_sales_sum",
            type: .sum,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "city"),
                FieldKeyExpression(fieldName: "sales")
            ])
        )

        let maintainer = SumIndexMaintainer(
            index: citySalesIndex,
            subspace: indexSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            // Insert record
            let noOldRecord: [String: Any]? = nil
            let oldRecord: [String: Any] = [
                "id": Int64(1),
                "city": "SF",
                "sales": Int64(100)
            ]
            try await maintainer.updateIndex(
                oldRecord: noOldRecord,
                newRecord: oldRecord,
                transaction: transaction
            )

            // Update sales amount
            let newRecord: [String: Any] = [
                "id": Int64(1),
                "city": "SF",
                "sales": Int64(250)
            ]
            try await maintainer.updateIndex(
                oldRecord: oldRecord,
                newRecord: newRecord,
                transaction: transaction
            )

            // Read sum (should be 250: -100 + 250)
            let sumKey = indexSubspace.pack(Tuple("SF"))
            let sumBytes = try await transaction.getValue(for: sumKey)
            let sum = TupleHelpers.bytesToInt64(sumBytes!)
            #expect(sum == 250)
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("SumIndex handles deletes correctly")
    func sumIndexDelete() async throws {
        let db = try createDatabase()
        let subspace = Subspace(rootPrefix: "test_sum_delete_\(UUID().uuidString)")
        let indexSubspace = subspace.subspace(RecordStoreKeyspace.index.rawValue)
            .subspace("city_sales_sum")

        let citySalesIndex = Index(
            name: "city_sales_sum",
            type: .sum,
            rootExpression: ConcatenateKeyExpression(children: [
                FieldKeyExpression(fieldName: "city"),
                FieldKeyExpression(fieldName: "sales")
            ])
        )

        let maintainer = SumIndexMaintainer(
            index: citySalesIndex,
            subspace: indexSubspace
        )

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()

            // Insert two records
            let noOldRecord: [String: Any]? = nil
            let noNewRecord: [String: Any]? = nil
            let records = [
                ["id": Int64(1), "city": "LA", "sales": Int64(300)],
                ["id": Int64(2), "city": "LA", "sales": Int64(200)]
            ]

            for record in records {
                try await maintainer.updateIndex(
                    oldRecord: noOldRecord,
                    newRecord: record,
                    transaction: transaction
                )
            }

            // Delete first record
            try await maintainer.updateIndex(
                oldRecord: records[0],
                newRecord: noNewRecord,
                transaction: transaction
            )

            // Read sum (should be 200)
            let sumKey = indexSubspace.pack(Tuple("LA"))
            let sumBytes = try await transaction.getValue(for: sumKey)
            let sum = TupleHelpers.bytesToInt64(sumBytes!)
            #expect(sum == 200)
        }

        try await cleanup(database: db, subspace: subspace)
    }
}
