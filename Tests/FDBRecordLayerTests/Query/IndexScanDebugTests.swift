import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Debug tests to understand index key structure
@Suite("Index Scan Debug Tests", .serialized)
struct IndexScanDebugTests {

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Already initialized
        }
    }

    struct SimpleRecord: Codable, Equatable, Recordable {
        let id: Int64
        let category: String

        static var recordName: String { "SimpleRecord" }
        static var primaryKeyFields: [String] { ["id"] }
        static var allFields: [String] { ["id", "category"] }

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "id": return 1
            case "category": return 2
            default: return nil
            }
        }

        func extractField(_ fieldName: String) -> [any TupleElement] {
            switch fieldName {
            case "id": return [id]
            case "category": return [category]
            default: return []
            }
        }

        func extractPrimaryKey() -> Tuple {
            return Tuple(id)
        }
    }

    @Test("DEBUG: Examine actual index keys in database")
    func testExamineIndexKeys() async throws {
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(prefix: Array("test_debug_\(UUID().uuidString)".utf8))

        let categoryIndex = Index(
            name: "simple_category",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "category"),
            recordTypes: ["SimpleRecord"]
        )

        let schema = Schema([SimpleRecord.self], indexes: [categoryIndex])
        let statsManager = StatisticsManager(
            database: database,
            subspace: subspace.subspace("stats")
        )

        let store = RecordStore<SimpleRecord>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: statsManager
        )

        // Enable index
        let indexStateManager = IndexStateManager(database: database, subspace: subspace)
        try await indexStateManager.enable("simple_category")
        try await indexStateManager.makeReadable("simple_category")

        // Insert test records
        let records = [
            SimpleRecord(id: 1, category: "A"),
            SimpleRecord(id: 2, category: "A"),
            SimpleRecord(id: 3, category: "B"),
        ]

        for record in records {
            try await store.save(record)
        }

        // Check what keys are actually stored for records
        print("\n=== Actual Record Keys ===\"")
        try await database.withTransaction { transaction in
            let recordSubspace = subspace.subspace("R")
            let (begin, end) = recordSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterOrEqual(end),
                snapshot: true
            )

            var count = 0
            for try await (key, _) in sequence {
                count += 1
                print("Record #\(count): \(key.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
            print("Total records: \(count)")
        }

        // Examine actual keys in index
        try await database.withTransaction { transaction in

            let indexSubspace = subspace.subspace("I").subspace("simple_category")

            print("=== Index Subspace Prefix ===")
            print("Hex: \(indexSubspace.prefix.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("Length: \(indexSubspace.prefix.count) bytes")

            // Scan all keys in index
            let (begin, end) = indexSubspace.range()

            print("\n=== Range Bounds ===")
            print("Begin: \(begin.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("End:   \(end.map { String(format: "%02x", $0) }.joined(separator: " "))")

            print("\n=== Actual Index Keys ===")
            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterOrEqual(end),
                snapshot: true
            )

            var keyCount = 0
            for try await (key, value) in sequence {
                keyCount += 1
                print("\nKey #\(keyCount):")
                print("  Raw: \(key.map { String(format: "%02x", $0) }.joined(separator: " "))")
                print("  Length: \(key.count) bytes")

                // Try to unpack
                if let unpacked = try? indexSubspace.unpack(key) {
                    print("  Unpacked tuple count: \(unpacked.count)")
                    for i in 0..<unpacked.count {
                        if let element = unpacked[i] {
                            if let str = element as? String {
                                print("    [\(i)]: String(\"\(str)\")")
                            } else if let int = element as? Int64 {
                                print("    [\(i)]: Int64(\(int))")
                            } else {
                                print("    [\(i)]: \(type(of: element))")
                            }
                        }
                    }
                } else {
                    print("  Failed to unpack")
                }

                print("  Value length: \(value.count) bytes")
            }

            print("\n=== Total Keys Found: \(keyCount) ===")

            // Now test our query range construction
            print("\n=== Testing Query Range Construction ===")

            let queryValue = "A"
            let beginValues: [any TupleElement] = [queryValue]
            let endValues: [any TupleElement] = [queryValue]

            let beginTuple = TupleHelpers.toTuple(beginValues)
            let endTuple = TupleHelpers.toTuple(endValues)

            // Fixed implementation: pack directly without nesting
            let queryBeginKey = indexSubspace.pack(beginTuple)
            var queryEndKey = indexSubspace.pack(endTuple)
            queryEndKey.append(0xFF)

            print("\nQuery value: \"\(queryValue)\"")
            print("Begin tuple: \(beginTuple)")
            print("End tuple: \(endTuple)")
            print("\nQuery begin key: \(queryBeginKey.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("Query end key:   \(queryEndKey.map { String(format: "%02x", $0) }.joined(separator: " "))")

            // Test query
            print("\n=== Executing Query ===")
            let querySequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(queryBeginKey),
                endSelector: .firstGreaterOrEqual(queryEndKey),
                snapshot: true
            )

            var queryKeyCount = 0
            for try await (key, _) in querySequence {
                queryKeyCount += 1
                print("Query result #\(queryKeyCount): \(key.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }

            print("Total query results: \(queryKeyCount)")
        }

        // Test using QueryBuilder (high-level API)
        print("\n=== Testing QueryBuilder API ===")
        let queryResults = try await store.query()
            .where(\.category, is: .equals, "A")
            .execute()

        print("QueryBuilder results: \(queryResults.count) records")
        #expect(queryResults.count == 2, "Should find 2 records with category A")

        // Cleanup
        try await database.withTransaction { transaction in
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }
}
