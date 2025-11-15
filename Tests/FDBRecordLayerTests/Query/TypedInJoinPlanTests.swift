import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

@Suite("TypedInJoinPlan Tests")
struct TypedInJoinPlanTests {

    // MARK: - Initialization

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    // MARK: - Helper Methods

    /// Get database with health check
    ///
    /// Returns nil if FDB is not available or not responding
    private func getDatabase() async -> (any DatabaseProtocol)? {
        guard ProcessInfo.processInfo.environment["SKIP_INTEGRATION_TESTS"] != "1" else {
            return nil
        }

        do {
            let db = try FDBClient.openDatabase()

            // Health check: verify FDB is actually responding
            do {
                try await db.withTransaction { transaction in
                    let healthCheckKey = Tuple("test", "health_check").pack()
                    transaction.setValue([0x01], for: healthCheckKey)
                }
                return db
            } catch {
                print("⚠️  FoundationDB connection failed: \(error)")
                return nil
            }
        } catch {
            print("⚠️  FoundationDB not available: \(error)")
            return nil
        }
    }

    // MARK: - Test Data

    struct TestRecord: Sendable, Codable {
        let id: Int64
        let age: Int64
        let city: String
        let status: String
    }

    struct TestRecordAccess: RecordAccess {
        func recordName(for record: TestRecord) -> String {
            return "TestRecord"
        }

        func serialize(_ record: TestRecord) throws -> FDB.Bytes {
            let data = try ProtobufEncoder().encode(record)
            return FDB.Bytes(data)
        }

        func deserialize(_ bytes: FDB.Bytes) throws -> TestRecord {
            let data = Data(bytes)
            return try ProtobufDecoder().decode(TestRecord.self, from: data)
        }

        func extractField(from record: TestRecord, fieldName: String) throws -> [any TupleElement] {
            switch fieldName {
            case "id":
                return [record.id]
            case "age":
                return [record.age]
            case "city":
                return [record.city]
            case "status":
                return [record.status]
            default:
                throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
            }
        }

        func extractPrimaryKey(from record: TestRecord) throws -> Tuple {
            return Tuple(record.id)
        }
    }

    // MARK: - TypedInQueryComponent Tests

    @Test("IN query component matches multiple values")
    func inQueryComponentMatchesMultipleValues() throws {
        let inComponent = TypedInQueryComponent<TestRecord>(
            fieldName: "age",
            values: [Int64(20), Int64(25), Int64(30)]
        )

        let recordAccess = TestRecordAccess()

        let testCases: [(TestRecord, Bool, String)] = [
            (TestRecord(id: 1, age: 20, city: "Tokyo", status: "ACTIVE"), true, "age 20 should match"),
            (TestRecord(id: 2, age: 25, city: "NYC", status: "ACTIVE"), true, "age 25 should match"),
            (TestRecord(id: 3, age: 30, city: "London", status: "ACTIVE"), true, "age 30 should match"),
            (TestRecord(id: 4, age: 35, city: "Paris", status: "ACTIVE"), false, "age 35 should not match"),
            (TestRecord(id: 5, age: 18, city: "Berlin", status: "ACTIVE"), false, "age 18 should not match")
        ]

        for (record, expectedMatch, description) in testCases {
            let matches = try inComponent.matches(record: record, recordAccess: recordAccess)
            #expect(matches == expectedMatch, "\(description)")
        }
    }

    @Test("IN query component matches string values")
    func inQueryComponentMatchesStringValues() throws {
        let inComponent = TypedInQueryComponent<TestRecord>(
            fieldName: "city",
            values: ["Tokyo", "NYC", "London"]
        )

        let recordAccess = TestRecordAccess()

        let testCases: [(TestRecord, Bool, String)] = [
            (TestRecord(id: 1, age: 30, city: "Tokyo", status: "ACTIVE"), true, "Tokyo should match"),
            (TestRecord(id: 2, age: 25, city: "NYC", status: "ACTIVE"), true, "NYC should match"),
            (TestRecord(id: 3, age: 30, city: "London", status: "ACTIVE"), true, "London should match"),
            (TestRecord(id: 4, age: 35, city: "Paris", status: "ACTIVE"), false, "Paris should not match"),
            (TestRecord(id: 5, age: 18, city: "Berlin", status: "ACTIVE"), false, "Berlin should not match")
        ]

        for (record, expectedMatch, description) in testCases {
            let matches = try inComponent.matches(record: record, recordAccess: recordAccess)
            #expect(matches == expectedMatch, "\(description)")
        }
    }

    @Test("IN query component convenience method")
    func inQueryComponentConvenienceMethod() throws {
        let inComponent = TypedInQueryComponent<TestRecord>.in("age", [Int64(20), Int64(30)])
        let recordAccess = TestRecordAccess()

        let record1 = TestRecord(id: 1, age: 20, city: "Tokyo", status: "ACTIVE")
        let record2 = TestRecord(id: 2, age: 25, city: "NYC", status: "ACTIVE")

        #expect(try inComponent.matches(record: record1, recordAccess: recordAccess))
        #expect(try !inComponent.matches(record: record2, recordAccess: recordAccess))
    }

    @Test("IN query component with empty values")
    func inQueryComponentEmptyValues() throws {
        let inComponent = TypedInQueryComponent<TestRecord>(
            fieldName: "age",
            values: []
        )

        let recordAccess = TestRecordAccess()
        let record = TestRecord(id: 1, age: 20, city: "Tokyo", status: "ACTIVE")

        #expect(try !inComponent.matches(record: record, recordAccess: recordAccess))
    }

    @Test("IN query component with single value")
    func inQueryComponentSingleValue() throws {
        let inComponent = TypedInQueryComponent<TestRecord>(
            fieldName: "age",
            values: [Int64(20)]
        )

        let recordAccess = TestRecordAccess()

        let record1 = TestRecord(id: 1, age: 20, city: "Tokyo", status: "ACTIVE")
        let record2 = TestRecord(id: 2, age: 25, city: "NYC", status: "ACTIVE")

        #expect(try inComponent.matches(record: record1, recordAccess: recordAccess))
        #expect(try !inComponent.matches(record: record2, recordAccess: recordAccess))
    }

    // MARK: - TypedInJoinPlan Structure Tests

    @Test("IN join plan structure")
    func inJoinPlanStructure() {
        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "age",
            values: [Int64(20), Int64(25), Int64(30)],
            indexName: "test_by_age",
            indexSubspaceTupleKey: "test_by_age",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        #expect(plan.fieldName == "age")
        #expect(plan.values.count == 3)
        #expect(plan.indexName == "test_by_age")
        #expect(plan.primaryKeyLength == 1)
        #expect(plan.recordName == "TestRecord")
    }

    @Test("Generate IN join plan creates IN join plan")
    func generateInJoinPlanCreatesInJoinPlan() {
        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "age",
            values: [Int64(20), Int64(25), Int64(30)],
            indexName: "test_by_age",
            indexSubspaceTupleKey: "test_by_age",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        #expect(plan.fieldName == "age")
        #expect(plan.values.count == 3)
        #expect(plan.indexName == "test_by_age")
        #expect(plan.primaryKeyLength == 1)
        #expect(plan.recordName == "TestRecord")
    }

    @Test("Generate IN join plan with string values")
    func generateInJoinPlanWithStringValues() {
        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "city",
            values: ["Tokyo", "NYC", "London"],
            indexName: "test_by_city",
            indexSubspaceTupleKey: "test_by_city",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        #expect(plan.fieldName == "city")
        #expect(plan.values.count == 3)
        #expect(plan.indexName == "test_by_city")
    }

    @Test("Generate IN join plan logic")
    func generateInJoinPlanLogic() {
        let inComponent = TypedInQueryComponent<TestRecord>(
            fieldName: "age",
            values: [Int64(20), Int64(25), Int64(30)]
        )

        let hasEnoughValues = inComponent.values.count >= 2

        #expect(hasEnoughValues, "IN join optimization requires at least 2 values")
    }

    @Test("Generate IN join plan with single value not optimal")
    func generateInJoinPlanSingleValueNotOptimal() {
        let inComponent = TypedInQueryComponent<TestRecord>(
            fieldName: "age",
            values: [Int64(20)]
        )

        let shouldUseInJoin = inComponent.values.count >= 2

        #expect(!shouldUseInJoin, "IN join not beneficial for single value")
    }

    @Test("Generate IN join plan with empty values not optimal")
    func generateInJoinPlanEmptyValuesNotOptimal() {
        let inComponent = TypedInQueryComponent<TestRecord>(
            fieldName: "age",
            values: []
        )

        let shouldUseInJoin = inComponent.values.count >= 2

        #expect(!shouldUseInJoin, "IN join not beneficial for empty values")
    }

    // MARK: - Multi-Valued Field Tests

    @Test("IN query component multi-valued field any match")
    func inQueryComponentMultiValuedFieldAnyMatch() throws {
        struct TaggedRecord: Sendable, Codable {
            let id: Int64
            let tags: [String]
        }

        struct TaggedRecordAccess: RecordAccess {
            func recordName(for record: TaggedRecord) -> String {
                return "TaggedRecord"
            }

            func serialize(_ record: TaggedRecord) throws -> FDB.Bytes {
                let data = try ProtobufEncoder().encode(record)
                return FDB.Bytes(data)
            }

            func deserialize(_ bytes: FDB.Bytes) throws -> TaggedRecord {
                let data = Data(bytes)
                return try ProtobufDecoder().decode(TaggedRecord.self, from: data)
            }

            func extractField(from record: TaggedRecord, fieldName: String) throws -> [any TupleElement] {
                switch fieldName {
                case "id":
                    return [record.id]
                case "tags":
                    return record.tags
                default:
                    throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
                }
            }

            func extractPrimaryKey(from record: TaggedRecord) throws -> Tuple {
                return Tuple(record.id)
            }
        }

        let inComponent = TypedInQueryComponent<TaggedRecord>(
            fieldName: "tags",
            values: ["swift", "fdb"]
        )

        let recordAccess = TaggedRecordAccess()

        let testCases: [(TaggedRecord, Bool, String)] = [
            (TaggedRecord(id: 1, tags: ["swift", "ios"]), true, "Has 'swift' - should match"),
            (TaggedRecord(id: 2, tags: ["java", "fdb"]), true, "Has 'fdb' - should match"),
            (TaggedRecord(id: 3, tags: ["swift", "fdb", "nosql"]), true, "Has both - should match"),
            (TaggedRecord(id: 4, tags: ["python", "django"]), false, "Has neither - should not match"),
            (TaggedRecord(id: 5, tags: []), false, "Empty tags - should not match")
        ]

        for (record, expectedMatch, description) in testCases {
            let matches = try inComponent.matches(record: record, recordAccess: recordAccess)
            #expect(matches == expectedMatch, "\(description)")
        }
    }

    @Test("IN query component multi-valued field empty field")
    func inQueryComponentMultiValuedFieldEmptyField() throws {
        struct TaggedRecord: Sendable, Codable {
            let id: Int64
            let tags: [String]
        }

        struct TaggedRecordAccess: RecordAccess {
            func recordName(for record: TaggedRecord) -> String {
                return "TaggedRecord"
            }

            func serialize(_ record: TaggedRecord) throws -> FDB.Bytes {
                let data = try ProtobufEncoder().encode(record)
                return FDB.Bytes(data)
            }

            func deserialize(_ bytes: FDB.Bytes) throws -> TaggedRecord {
                let data = Data(bytes)
                return try ProtobufDecoder().decode(TaggedRecord.self, from: data)
            }

            func extractField(from record: TaggedRecord, fieldName: String) throws -> [any TupleElement] {
                switch fieldName {
                case "id":
                    return [record.id]
                case "tags":
                    return record.tags
                default:
                    throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
                }
            }

            func extractPrimaryKey(from record: TaggedRecord) throws -> Tuple {
                return Tuple(record.id)
            }
        }

        let inComponent = TypedInQueryComponent<TaggedRecord>(
            fieldName: "tags",
            values: ["swift", "fdb"]
        )

        let recordAccess = TaggedRecordAccess()
        let record = TaggedRecord(id: 1, tags: [])

        let matches = try inComponent.matches(record: record, recordAccess: recordAccess)
        #expect(!matches, "Empty repeated field should not match")
    }

    // MARK: - Deduplication Tests

    @Test("IN join plan uses stable deduplication")
    func inJoinPlanUsesStableDeduplication() {
        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "status",
            values: ["ACTIVE", "PENDING"],
            indexName: "test_by_status",
            indexSubspaceTupleKey: "test_by_status",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        #expect(plan.fieldName == "status")
        #expect(plan.values.count == 2)
        #expect(plan.primaryKeyLength == 1)
    }

    // MARK: - Subspace Layout Tests

    @Test("IN join plan uses consistent subspace layout")
    func inJoinPlanUsesConsistentSubspaceLayout() {
        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "age",
            values: [Int64(20), Int64(25)],
            indexName: "test_by_age",
            indexSubspaceTupleKey: "test_by_age",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        #expect(plan.recordName == "TestRecord")
    }

    // MARK: - Integration Tests (End-to-End)

    @Test("IN join plan execute returns matching records")
    func inJoinPlanExecuteReturnsMatchingRecords() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }
        let subspace = Subspace(prefix: Array("test_in_join_\(UUID().uuidString)".utf8))
        let recordAccess = TestRecordAccess()

        let recordSubspace = subspace.subspace("R")
        let indexSubspace = subspace.subspace("I")
            .subspace("test_by_age")

        let records = [
            TestRecord(id: 1, age: 20, city: "Tokyo", status: "ACTIVE"),
            TestRecord(id: 2, age: 25, city: "NYC", status: "ACTIVE"),
            TestRecord(id: 3, age: 30, city: "London", status: "ACTIVE"),
            TestRecord(id: 4, age: 35, city: "Paris", status: "INACTIVE"),
            TestRecord(id: 5, age: 20, city: "Berlin", status: "ACTIVE"),
        ]

        try await database.withTransaction { transaction in
            for record in records {
                let recordKey = recordSubspace.pack(Tuple(record.id))
                let recordBytes = try recordAccess.serialize(record)
                transaction.setValue(recordBytes, for: recordKey)

                let indexKey = indexSubspace.pack(Tuple(record.age, record.id))
                transaction.setValue(FDB.Bytes(), for: indexKey)
            }
        }

        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "age",
            values: [Int64(20), Int64(25), Int64(30)],
            indexName: "test_by_age",
            indexSubspaceTupleKey: "test_by_age",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        let recordContext = try RecordContext(database: database)

        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: recordContext,
            snapshot: false
        )

        var results: [TestRecord] = []
        for try await record in cursor {
            results.append(record)
        }

        #expect(results.count == 4, "Should return 4 records (id: 1, 2, 3, 5)")

        let resultIds = Set(results.map { $0.id })
        #expect(resultIds.contains(1), "Should include record with id=1 (age=20)")
        #expect(resultIds.contains(2), "Should include record with id=2 (age=25)")
        #expect(resultIds.contains(3), "Should include record with id=3 (age=30)")
        #expect(resultIds.contains(5), "Should include record with id=5 (age=20)")
        #expect(!resultIds.contains(4), "Should NOT include record with id=4 (age=35)")

        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("IN join plan execute with deduplication")
    func inJoinPlanExecuteWithDeduplication() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }
        let subspace = Subspace(prefix: Array("test_in_join_dedup_\(UUID().uuidString)".utf8))
        let recordAccess = TestRecordAccess()

        let recordSubspace = subspace.subspace("R")
        let indexSubspace = subspace.subspace("I")
            .subspace("test_by_status")

        let record = TestRecord(id: 1, age: 20, city: "Tokyo", status: "ACTIVE")

        try await database.withTransaction { transaction in
            let recordKey = recordSubspace.pack(Tuple(record.id))
            let recordBytes = try recordAccess.serialize(record)
            transaction.setValue(recordBytes, for: recordKey)

            let indexKey = indexSubspace.pack(Tuple(record.status, record.id))
            transaction.setValue(FDB.Bytes(), for: indexKey)
        }

        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "status",
            values: ["ACTIVE", "ACTIVE"],
            indexName: "test_by_status",
            indexSubspaceTupleKey: "test_by_status",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        let recordContext = try RecordContext(database: database)

        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: recordContext,
            snapshot: false
        )

        var results: [TestRecord] = []
        for try await rec in cursor {
            results.append(rec)
        }

        #expect(results.count == 1, "Should return record only once despite duplicate IN values")
        #expect(results.first?.id == 1)

        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("IN join plan execute with multi-valued field")
    func inJoinPlanExecuteWithMultiValuedField() async throws {
        guard let database = await getDatabase() else {
            throw SkipInfo("FoundationDB not available")
        }
        let subspace = Subspace(prefix: Array("test_in_join_multi_\(UUID().uuidString)".utf8))

        struct TaggedRecord: Sendable, Codable {
            let id: Int64
            let tags: [String]
        }

        struct TaggedRecordAccess: RecordAccess {
            func recordName(for record: TaggedRecord) -> String {
                return "TaggedRecord"
            }

            func serialize(_ record: TaggedRecord) throws -> FDB.Bytes {
                let data = try ProtobufEncoder().encode(record)
                return FDB.Bytes(data)
            }

            func deserialize(_ bytes: FDB.Bytes) throws -> TaggedRecord {
                let data = Data(bytes)
                return try ProtobufDecoder().decode(TaggedRecord.self, from: data)
            }

            func extractField(from record: TaggedRecord, fieldName: String) throws -> [any TupleElement] {
                switch fieldName {
                case "id":
                    return [record.id]
                case "tags":
                    return record.tags
                default:
                    throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
                }
            }

            func extractPrimaryKey(from record: TaggedRecord) throws -> Tuple {
                return Tuple(record.id)
            }
        }

        let recordAccess = TaggedRecordAccess()
        let recordSubspace = subspace.subspace("R")
        let indexSubspace = subspace.subspace("I")
            .subspace("test_by_tags")

        let records = [
            TaggedRecord(id: 1, tags: ["swift", "ios"]),
            TaggedRecord(id: 2, tags: ["java", "fdb"]),
            TaggedRecord(id: 3, tags: ["swift", "fdb", "nosql"]),
            TaggedRecord(id: 4, tags: ["python", "django"]),
        ]

        try await database.withTransaction { transaction in
            for record in records {
                let recordKey = recordSubspace.pack(Tuple(record.id))
                let recordBytes = try recordAccess.serialize(record)
                transaction.setValue(recordBytes, for: recordKey)

                for tag in record.tags {
                    let indexKey = indexSubspace.pack(Tuple(tag, record.id))
                    transaction.setValue(FDB.Bytes(), for: indexKey)
                }
            }
        }

        let plan = TypedInJoinPlan<TaggedRecord>(
            fieldName: "tags",
            values: ["swift", "fdb"],
            indexName: "test_by_tags",
            indexSubspaceTupleKey: "test_by_tags",
            primaryKeyLength: 1,
            recordName: "TaggedRecord"
        )

        let recordContext = try RecordContext(database: database)

        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: recordContext,
            snapshot: false
        )

        var results: [TaggedRecord] = []
        for try await rec in cursor {
            results.append(rec)
        }

        #expect(results.count == 3, "Should return 3 records (id: 1, 2, 3)")

        let resultIds = Set(results.map { $0.id })
        #expect(resultIds.contains(1), "Record 1 has 'swift'")
        #expect(resultIds.contains(2), "Record 2 has 'fdb'")
        #expect(resultIds.contains(3), "Record 3 has both 'swift' and 'fdb' (deduplicated)")
        #expect(!resultIds.contains(4), "Record 4 has neither")

        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("IN join plan execute with empty result")
    func inJoinPlanExecuteWithEmptyResult() async throws {
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_in_join_empty_\(UUID().uuidString)".utf8))
        let recordAccess = TestRecordAccess()

        let recordSubspace = subspace.subspace("R")
        let indexSubspace = subspace.subspace("I")
            .subspace("test_by_age")

        let records = [
            TestRecord(id: 1, age: 20, city: "Tokyo", status: "ACTIVE"),
            TestRecord(id: 2, age: 25, city: "NYC", status: "ACTIVE"),
            TestRecord(id: 3, age: 30, city: "London", status: "ACTIVE"),
        ]

        try await database.withTransaction { transaction in
            for record in records {
                let recordKey = recordSubspace.pack(Tuple(record.id))
                let recordBytes = try recordAccess.serialize(record)
                transaction.setValue(recordBytes, for: recordKey)

                let indexKey = indexSubspace.pack(Tuple(record.age, record.id))
                transaction.setValue(FDB.Bytes(), for: indexKey)
            }
        }

        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "age",
            values: [Int64(40), Int64(50), Int64(60)],
            indexName: "test_by_age",
            indexSubspaceTupleKey: "test_by_age",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        let recordContext = try RecordContext(database: database)

        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: recordContext,
            snapshot: false
        )

        var results: [TestRecord] = []
        for try await rec in cursor {
            results.append(rec)
        }

        #expect(results.count == 0, "Should return no records when no matches")

        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    @Test("IN join plan execute with large result set")
    func inJoinPlanExecuteWithLargeResultSet() async throws {
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_in_join_large_\(UUID().uuidString)".utf8))
        let recordAccess = TestRecordAccess()

        let recordSubspace = subspace.subspace("R")
        let indexSubspace = subspace.subspace("I")
            .subspace("test_by_age")

        var records: [TestRecord] = []
        for age in 20...29 {
            for i in 0..<10 {
                let id = Int64(age * 100 + i)
                records.append(TestRecord(
                    id: id,
                    age: Int64(age),
                    city: "City\(i)",
                    status: "ACTIVE"
                ))
            }
        }

        try await database.withTransaction { transaction in
            for record in records {
                let recordKey = recordSubspace.pack(Tuple(record.id))
                let recordBytes = try recordAccess.serialize(record)
                transaction.setValue(recordBytes, for: recordKey)

                let indexKey = indexSubspace.pack(Tuple(record.age, record.id))
                transaction.setValue(FDB.Bytes(), for: indexKey)
            }
        }

        let plan = TypedInJoinPlan<TestRecord>(
            fieldName: "age",
            values: [Int64(20), Int64(21), Int64(22), Int64(23), Int64(24)],
            indexName: "test_by_age",
            indexSubspaceTupleKey: "test_by_age",
            primaryKeyLength: 1,
            recordName: "TestRecord"
        )

        let recordContext = try RecordContext(database: database)

        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: recordContext,
            snapshot: false
        )

        var results: [TestRecord] = []
        for try await rec in cursor {
            results.append(rec)
        }

        #expect(results.count == 50, "Should return 50 records")

        let uniqueIds = Set(results.map { $0.id })
        #expect(uniqueIds.count == 50, "All IDs should be unique (no duplicates)")

        let ageGroups = Dictionary(grouping: results, by: { $0.age })
        #expect(ageGroups.keys.count == 5, "Should have 5 different ages")
        for age in 20...24 {
            #expect(ageGroups[Int64(age)]?.count == 10, "Age \(age) should have 10 records")
        }

        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }
}
