import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Tests for Covering Index foundation (Phase 1)
///
/// Test Coverage:
/// 1. Index.covering() factory method
/// 2. Index.covers(fields:) method - field coverage detection
/// 3. RecordAccess.reconstruct() default implementation
/// 4. RecordAccess.supportsReconstruction default property
/// 5. Error handling for reconstruction not implemented
@Suite("Covering Index Foundation Tests")
struct CoveringIndexFoundationTests {

    // MARK: - Index.covering() Factory Method Tests

    @Test("Index.covering() creates index with covering fields")
    func coveringFactoryMethod() {
        // Create covering index
        let index = Index.covering(
            named: "user_by_city_covering",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "email")
            ],
            recordTypes: ["User"]
        )

        // Verify properties
        #expect(index.name == "user_by_city_covering")
        #expect(index.type == .value)
        #expect(index.coveringFields?.count == 2)
        #expect(index.recordTypes == ["User"])

        // Verify covering fields
        guard let coveringFields = index.coveringFields else {
            Issue.record("Expected coveringFields to be non-nil")
            return
        }

        let field1 = coveringFields[0] as? FieldKeyExpression
        let field2 = coveringFields[1] as? FieldKeyExpression

        #expect(field1?.fieldName == "name")
        #expect(field2?.fieldName == "email")
    }

    @Test("Index.covering() with empty covering fields")
    func coveringWithEmptyFields() {
        // Edge case: Empty covering fields array
        let index = Index.covering(
            named: "test_index",
            on: FieldKeyExpression(fieldName: "id"),
            covering: []
        )

        #expect(index.coveringFields?.isEmpty == true)
    }

    @Test("Regular index has nil covering fields (backward compatibility)")
    func regularIndexNoCoveringFields() {
        // Regular index created with Index.value()
        let regularIndex = Index.value(
            named: "user_by_email",
            on: FieldKeyExpression(fieldName: "email")
        )

        // Should have nil coveringFields (not empty array)
        #expect(regularIndex.coveringFields == nil)
    }

    // MARK: - Index.covers(fields:) Method Tests

    @Test("Index.covers() detects complete coverage")
    func coversAllRequiredFields() {
        // Index on city, covering name and email
        let index = Index.covering(
            named: "user_by_city_covering",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "email")
            ]
        )

        let primaryKey = FieldKeyExpression(fieldName: "userID")

        // Query needs: city (indexed), name (covered), email (covered)
        let requiredFields: Set<String> = ["city", "name", "email"]
        #expect(index.covers(fields: requiredFields, primaryKey: primaryKey) == true)

        // Query needs: city, name, email, userID (all covered including primary key)
        let requiredFields2: Set<String> = ["city", "name", "email", "userID"]
        #expect(index.covers(fields: requiredFields2, primaryKey: primaryKey) == true)
    }

    @Test("Index.covers() detects partial coverage")
    func coversPartialFields() {
        // Index on city, covering name and email
        let index = Index.covering(
            named: "user_by_city_covering",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [
                FieldKeyExpression(fieldName: "name"),
                FieldKeyExpression(fieldName: "email")
            ]
        )

        let primaryKey = FieldKeyExpression(fieldName: "userID")

        // Query needs: city, name, email, age (age NOT covered)
        let requiredFields: Set<String> = ["city", "name", "email", "age"]
        #expect(index.covers(fields: requiredFields, primaryKey: primaryKey) == false)
    }

    @Test("Index.covers() with composite index key")
    func coversCompositeIndexKey() {
        // Composite index: city + age
        let compositeExpr = ConcatenateKeyExpression(children: [
            FieldKeyExpression(fieldName: "city"),
            FieldKeyExpression(fieldName: "age")
        ])

        let index = Index.covering(
            named: "user_by_city_age_covering",
            on: compositeExpr,
            covering: [
                FieldKeyExpression(fieldName: "name")
            ]
        )

        let primaryKey = FieldKeyExpression(fieldName: "userID")

        // Query needs: city (indexed), age (indexed), name (covered)
        let requiredFields: Set<String> = ["city", "age", "name"]
        #expect(index.covers(fields: requiredFields, primaryKey: primaryKey) == true)

        // Query needs: city, age, name, userID (all covered including primary key)
        let requiredFields2: Set<String> = ["city", "age", "name", "userID"]
        #expect(index.covers(fields: requiredFields2, primaryKey: primaryKey) == true)

        // Query needs: city, age, name, email (email NOT covered)
        let requiredFields3: Set<String> = ["city", "age", "name", "email"]
        #expect(index.covers(fields: requiredFields3, primaryKey: primaryKey) == false)
    }

    @Test("Index.covers() with no covering fields (regular index)")
    func coversRegularIndexOnlyIndexedFields() {
        // Regular index with no covering fields
        let regularIndex = Index.value(
            named: "user_by_city",
            on: FieldKeyExpression(fieldName: "city")
        )

        let primaryKey = FieldKeyExpression(fieldName: "userID")

        // Indexed field + primary key should be covered
        #expect(regularIndex.covers(fields: ["city"], primaryKey: primaryKey) == true)
        #expect(regularIndex.covers(fields: ["city", "userID"], primaryKey: primaryKey) == true)

        // Additional fields should NOT be covered
        #expect(regularIndex.covers(fields: ["city", "name"], primaryKey: primaryKey) == false)
    }

    @Test("Index.covers() empty required fields")
    func coversEmptyRequiredFields() {
        let index = Index.covering(
            named: "test_index",
            on: FieldKeyExpression(fieldName: "id"),
            covering: [FieldKeyExpression(fieldName: "name")]
        )

        let primaryKey = FieldKeyExpression(fieldName: "pk")

        // Edge case: Empty required fields set
        // Empty set is a subset of any set, so should return true
        #expect(index.covers(fields: [], primaryKey: primaryKey) == true)
    }

    // MARK: - RecordAccess Default Implementation Tests

    @Test("RecordAccess.reconstruct() throws not implemented error by default")
    func reconstructThrowsNotImplemented() async throws {
        // Create a minimal RecordAccess implementation that uses default reconstruct()
        struct TestRecord: Sendable {
            let id: Int64
            let name: String
        }

        struct TestRecordAccess: RecordAccess {
            func recordName(for record: TestRecord) -> String {
                return "TestRecord"
            }

            func extractField(from record: TestRecord, fieldName: String) throws -> [any TupleElement] {
                switch fieldName {
                case "id": return [record.id]
                case "name": return [record.name]
                default: throw RecordLayerError.invalidArgument("Unknown field: \(fieldName)")
                }
            }

            func serialize(_ record: TestRecord) throws -> FDB.Bytes {
                return [] // Not used in this test
            }

            func deserialize(_ bytes: FDB.Bytes) throws -> TestRecord {
                return TestRecord(id: 0, name: "") // Not used in this test
            }
        }

        let recordAccess = TestRecordAccess()
        let index = Index.covering(
            named: "test_index",
            on: FieldKeyExpression(fieldName: "id"),
            covering: [FieldKeyExpression(fieldName: "name")]
        )
        let primaryKeyExpr = FieldKeyExpression(fieldName: "id")

        // Should throw reconstructionNotImplemented
        #expect(throws: RecordLayerError.self) {
            try recordAccess.reconstruct(
                indexKey: Tuple(1, "Alice"),
                indexValue: FDB.Bytes(),
                index: index,
                primaryKeyExpression: primaryKeyExpr
            )
        }

        // Verify error type and message
        do {
            _ = try recordAccess.reconstruct(
                indexKey: Tuple(1, "Alice"),
                indexValue: FDB.Bytes(),
                index: index,
                primaryKeyExpression: primaryKeyExpr
            )
            Issue.record("Expected reconstructionNotImplemented error")
        } catch let error as RecordLayerError {
            if case .reconstructionNotImplemented(let recordType, let suggestion) = error {
                #expect(recordType.contains("TestRecord"))
                #expect(suggestion.contains("@Recordable macro"))
                #expect(suggestion.contains("Manually implement"))
            } else {
                Issue.record("Expected reconstructionNotImplemented, got \(error)")
            }
        }
    }

    @Test("RecordAccess.supportsReconstruction returns false by default")
    func supportsReconstructionDefaultsFalse() {
        // Create a minimal RecordAccess implementation
        struct TestRecord: Sendable {}

        struct TestRecordAccess: RecordAccess {
            func recordName(for record: TestRecord) -> String { "TestRecord" }
            func extractField(from record: TestRecord, fieldName: String) throws -> [any TupleElement] { [] }
            func serialize(_ record: TestRecord) throws -> FDB.Bytes { [] }
            func deserialize(_ bytes: FDB.Bytes) throws -> TestRecord { TestRecord() }
        }

        let recordAccess = TestRecordAccess()

        // Default should be false (safe, conservative)
        #expect(recordAccess.supportsReconstruction == false)
    }

    @Test("Custom RecordAccess can override supportsReconstruction")
    func customRecordAccessCanEnableReconstruction() {
        struct TestRecord: Sendable {
            let id: Int64
        }

        // Custom implementation that supports reconstruction
        struct CustomRecordAccess: RecordAccess {
            func recordName(for record: TestRecord) -> String { "TestRecord" }
            func extractField(from record: TestRecord, fieldName: String) throws -> [any TupleElement] { [record.id] }
            func serialize(_ record: TestRecord) throws -> FDB.Bytes { [] }
            func deserialize(_ bytes: FDB.Bytes) throws -> TestRecord { TestRecord(id: 0) }

            // Override to enable reconstruction
            var supportsReconstruction: Bool {
                return true
            }

            // Custom reconstruct implementation
            func reconstruct(
                indexKey: Tuple,
                indexValue: FDB.Bytes,
                index: Index,
                primaryKeyExpression: KeyExpression
            ) throws -> TestRecord {
                // Simple reconstruction logic for testing
                guard let id = indexKey[0] as? Int64 else {
                    throw RecordLayerError.reconstructionFailed(
                        recordType: "TestRecord",
                        reason: "Invalid primary key"
                    )
                }
                return TestRecord(id: id)
            }
        }

        let recordAccess = CustomRecordAccess()

        // Should return true
        #expect(recordAccess.supportsReconstruction == true)

        // Should successfully reconstruct
        let index = Index.covering(
            named: "test_index",
            on: FieldKeyExpression(fieldName: "id"),
            covering: []
        )
        let primaryKeyExpr = FieldKeyExpression(fieldName: "id")

        #expect(throws: Never.self) {
            let record = try recordAccess.reconstruct(
                indexKey: Tuple(Int64(123)),
                indexValue: FDB.Bytes(),
                index: index,
                primaryKeyExpression: primaryKeyExpr
            )
            #expect(record.id == 123)
        }
    }

    // MARK: - Integration Tests

    @Test("Covering index properties are preserved through init")
    func coveringIndexPropertiesPreserved() {
        // Create index with all properties
        let coveringFields = [
            FieldKeyExpression(fieldName: "name"),
            FieldKeyExpression(fieldName: "email"),
            FieldKeyExpression(fieldName: "age")
        ]

        let index = Index(
            name: "comprehensive_index",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "city"),
            subspaceKey: "custom_subspace_key",
            recordTypes: ["User", "Admin"],
            options: IndexOptions(unique: true),
            coveringFields: coveringFields
        )

        // Verify all properties
        #expect(index.name == "comprehensive_index")
        #expect(index.type == .value)
        #expect(index.subspaceKey == "custom_subspace_key")
        #expect(index.recordTypes == ["User", "Admin"])
        #expect(index.options.unique == true)
        #expect(index.coveringFields?.count == 3)

        // Verify covering fields in detail
        let field1 = index.coveringFields?[0] as? FieldKeyExpression
        let field2 = index.coveringFields?[1] as? FieldKeyExpression
        let field3 = index.coveringFields?[2] as? FieldKeyExpression

        #expect(field1?.fieldName == "name")
        #expect(field2?.fieldName == "email")
        #expect(field3?.fieldName == "age")
    }

    @Test("Index equality based on name (covering fields not part of equality)")
    func indexEqualityBasedOnName() {
        // Two indexes with same name but different covering fields
        let index1 = Index.covering(
            named: "user_index",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [FieldKeyExpression(fieldName: "name")]
        )

        let index2 = Index.covering(
            named: "user_index",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [FieldKeyExpression(fieldName: "email")]
        )

        // Should be equal (name is the unique identifier)
        #expect(index1 == index2)
        #expect(index1.hashValue == index2.hashValue)

        // Different name should not be equal
        let index3 = Index.covering(
            named: "different_name",
            on: FieldKeyExpression(fieldName: "city"),
            covering: [FieldKeyExpression(fieldName: "name")]
        )

        #expect(index1 != index3)
    }
}
