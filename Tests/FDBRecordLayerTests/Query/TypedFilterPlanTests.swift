import XCTest
@testable import FDBRecordLayer
import FoundationDB

/// Tests for TypedFilterPlan and FilteredTypedCursor
///
/// These tests verify that:
/// 1. FilterPlan correctly applies filters to records
/// 2. FilteredTypedCursor skips non-matching records
/// 3. Complex filter combinations work (AND, OR, NOT)
final class TypedFilterPlanTests: XCTestCase {

    // MARK: - Test Data

    struct TestRecord: Sendable {
        let id: Int64
        let name: String
        let age: Int64
        let city: String
    }

    struct TestRecordAccess: RecordAccess {
        func recordName(for record: TestRecord) -> String {
            return "TestRecord"
        }

        func serialize(_ record: TestRecord) throws -> FDB.Bytes {
            // Simple JSON encoding for testing
            let dict: [String: Any] = [
                "id": record.id,
                "name": record.name,
                "age": record.age,
                "city": record.city
            ]
            let data = try JSONSerialization.data(withJSONObject: dict)
            return FDB.Bytes(data)
        }

        func deserialize(_ bytes: FDB.Bytes) throws -> TestRecord {
            let data = Data(bytes)
            let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return TestRecord(
                id: dict["id"] as! Int64,
                name: dict["name"] as! String,
                age: dict["age"] as! Int64,
                city: dict["city"] as! String
            )
        }

        func extractField(from record: TestRecord, fieldName: String) throws -> [any TupleElement] {
            switch fieldName {
            case "id":
                return [record.id]
            case "name":
                return [record.name]
            case "age":
                return [record.age]
            case "city":
                return [record.city]
            default:
                throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
            }
        }

        func extractPrimaryKey(from record: TestRecord) throws -> Tuple {
            return Tuple(record.id)
        }
    }

    // MARK: - Helper: Create Test Cursor

    /// Create a simple cursor that returns test records
    private func createTestCursor(records: [TestRecord]) -> AnyTypedRecordCursor<TestRecord> {
        let stream = AsyncStream<TestRecord> { continuation in
            for record in records {
                continuation.yield(record)
            }
            continuation.finish()
        }

        struct SimpleCursor: TypedRecordCursor {
            typealias Element = TestRecord

            let stream: AsyncStream<TestRecord>

            func makeAsyncIterator() -> AsyncStream<TestRecord>.AsyncIterator {
                return stream.makeAsyncIterator()
            }
        }

        return AnyTypedRecordCursor(SimpleCursor(stream: stream))
    }

    // MARK: - Tests

    func testFilterPlan_SimpleEquality() async throws {
        // Given: A set of test records
        let records = [
            TestRecord(id: 1, name: "Alice", age: 30, city: "Tokyo"),
            TestRecord(id: 2, name: "Bob", age: 25, city: "NYC"),
            TestRecord(id: 3, name: "Charlie", age: 30, city: "London")
        ]

        // When: Filter for age == 30
        let filter = TypedFieldQueryComponent<TestRecord>.equals("age", Int64(30))
        let sourceCursor = createTestCursor(records: records)

        let recordAccess = TestRecordAccess()
        let filteredCursor = FilteredTypedCursor(
            source: sourceCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        // Then: Should get only Alice and Charlie
        var results: [TestRecord] = []
        for try await record in filteredCursor {
            results.append(record)
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.name == "Alice" })
        XCTAssertTrue(results.contains { $0.name == "Charlie" })
        XCTAssertFalse(results.contains { $0.name == "Bob" })
    }

    func testFilterPlan_RangeQuery() async throws {
        // Given: A set of test records
        let records = [
            TestRecord(id: 1, name: "Alice", age: 18, city: "Tokyo"),
            TestRecord(id: 2, name: "Bob", age: 25, city: "NYC"),
            TestRecord(id: 3, name: "Charlie", age: 30, city: "London"),
            TestRecord(id: 4, name: "David", age: 65, city: "Paris")
        ]

        // When: Filter for age > 20 AND age < 60
        let filter = TypedAndQueryComponent<TestRecord>(children: [
            TypedFieldQueryComponent<TestRecord>.greaterThan("age", Int64(20)),
            TypedFieldQueryComponent<TestRecord>.lessThan("age", Int64(60))
        ])

        let sourceCursor = createTestCursor(records: records)
        let recordAccess = TestRecordAccess()
        let filteredCursor = FilteredTypedCursor(
            source: sourceCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        // Then: Should get only Bob and Charlie
        var results: [TestRecord] = []
        for try await record in filteredCursor {
            results.append(record)
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.name == "Bob" })
        XCTAssertTrue(results.contains { $0.name == "Charlie" })
    }

    func testFilterPlan_OrCondition() async throws {
        // Given: A set of test records
        let records = [
            TestRecord(id: 1, name: "Alice", age: 30, city: "Tokyo"),
            TestRecord(id: 2, name: "Bob", age: 25, city: "NYC"),
            TestRecord(id: 3, name: "Charlie", age: 30, city: "NYC")
        ]

        // When: Filter for city == "Tokyo" OR city == "NYC"
        let filter = TypedOrQueryComponent<TestRecord>(children: [
            TypedFieldQueryComponent<TestRecord>.equals("city", "Tokyo"),
            TypedFieldQueryComponent<TestRecord>.equals("city", "NYC")
        ])

        let sourceCursor = createTestCursor(records: records)
        let recordAccess = TestRecordAccess()
        let filteredCursor = FilteredTypedCursor(
            source: sourceCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        // Then: Should get all records (all are Tokyo or NYC)
        var results: [TestRecord] = []
        for try await record in filteredCursor {
            results.append(record)
        }

        XCTAssertEqual(results.count, 3)
    }

    func testFilterPlan_NotCondition() async throws {
        // Given: A set of test records
        let records = [
            TestRecord(id: 1, name: "Alice", age: 30, city: "Tokyo"),
            TestRecord(id: 2, name: "Bob", age: 25, city: "NYC"),
            TestRecord(id: 3, name: "Charlie", age: 30, city: "London")
        ]

        // When: Filter for NOT (city == "NYC")
        let filter = TypedNotQueryComponent<TestRecord>(
            child: TypedFieldQueryComponent<TestRecord>.equals("city", "NYC")
        )

        let sourceCursor = createTestCursor(records: records)
        let recordAccess = TestRecordAccess()
        let filteredCursor = FilteredTypedCursor(
            source: sourceCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        // Then: Should get Alice and Charlie (not NYC)
        var results: [TestRecord] = []
        for try await record in filteredCursor {
            results.append(record)
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.name == "Alice" })
        XCTAssertTrue(results.contains { $0.name == "Charlie" })
        XCTAssertFalse(results.contains { $0.name == "Bob" })
    }

    func testFilterPlan_ComplexCondition() async throws {
        // Given: A set of test records
        let records = [
            TestRecord(id: 1, name: "Alice", age: 30, city: "Tokyo"),
            TestRecord(id: 2, name: "Bob", age: 25, city: "NYC"),
            TestRecord(id: 3, name: "Charlie", age: 30, city: "NYC"),
            TestRecord(id: 4, name: "David", age: 35, city: "Tokyo")
        ]

        // When: Filter for (age == 30 AND city == "NYC") OR (age > 30 AND city == "Tokyo")
        let condition1 = TypedAndQueryComponent<TestRecord>(children: [
            TypedFieldQueryComponent<TestRecord>.equals("age", Int64(30)),
            TypedFieldQueryComponent<TestRecord>.equals("city", "NYC")
        ])

        let condition2 = TypedAndQueryComponent<TestRecord>(children: [
            TypedFieldQueryComponent<TestRecord>.greaterThan("age", Int64(30)),
            TypedFieldQueryComponent<TestRecord>.equals("city", "Tokyo")
        ])

        let filter = TypedOrQueryComponent<TestRecord>(children: [condition1, condition2])

        let sourceCursor = createTestCursor(records: records)
        let recordAccess = TestRecordAccess()
        let filteredCursor = FilteredTypedCursor(
            source: sourceCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        // Then: Should get Charlie (30, NYC) and David (35, Tokyo)
        var results: [TestRecord] = []
        for try await record in filteredCursor {
            results.append(record)
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.name == "Charlie" })
        XCTAssertTrue(results.contains { $0.name == "David" })
    }

    func testFilterPlan_EmptyResults() async throws {
        // Given: A set of test records
        let records = [
            TestRecord(id: 1, name: "Alice", age: 30, city: "Tokyo"),
            TestRecord(id: 2, name: "Bob", age: 25, city: "NYC")
        ]

        // When: Filter for city == "London" (no matches)
        let filter = TypedFieldQueryComponent<TestRecord>.equals("city", "London")

        let sourceCursor = createTestCursor(records: records)
        let recordAccess = TestRecordAccess()
        let filteredCursor = FilteredTypedCursor(
            source: sourceCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        // Then: Should get empty results
        var results: [TestRecord] = []
        for try await record in filteredCursor {
            results.append(record)
        }

        XCTAssertEqual(results.count, 0)
    }

    func testFilterPlan_StringOperations() async throws {
        // Given: A set of test records
        let records = [
            TestRecord(id: 1, name: "Alice", age: 30, city: "Tokyo"),
            TestRecord(id: 2, name: "Alicia", age: 25, city: "NYC"),
            TestRecord(id: 3, name: "Bob", age: 30, city: "London")
        ]

        // When: Filter for name starts with "Ali"
        let filter = TypedFieldQueryComponent<TestRecord>(
            fieldName: "name",
            comparison: .startsWith,
            value: "Ali"
        )

        let sourceCursor = createTestCursor(records: records)
        let recordAccess = TestRecordAccess()
        let filteredCursor = FilteredTypedCursor(
            source: sourceCursor,
            filter: filter,
            recordAccess: recordAccess
        )

        // Then: Should get Alice and Alicia
        var results: [TestRecord] = []
        for try await record in filteredCursor {
            results.append(record)
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.name == "Alice" })
        XCTAssertTrue(results.contains { $0.name == "Alicia" })
    }
}
