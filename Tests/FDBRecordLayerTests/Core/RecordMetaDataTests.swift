import XCTest
@testable import FDBRecordLayer

final class RecordMetaDataTests: XCTestCase {
    func testMetaDataBuilder() throws {
        let primaryKey = FieldKeyExpression(fieldName: "id")

        let userType = RecordType(
            name: "User",
            primaryKey: primaryKey
        )

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )

        let metaData = try RecordMetaDataBuilder()
            .setVersion(1)
            .addRecordType(userType)
            .addIndex(emailIndex)
            .build()

        XCTAssertEqual(metaData.version, 1)
        XCTAssertEqual(metaData.recordTypes.count, 1)
        XCTAssertEqual(metaData.indexes.count, 1)

        let retrievedType = try metaData.getRecordType("User")
        XCTAssertEqual(retrievedType.name, "User")

        let retrievedIndex = try metaData.getIndex("user_by_email")
        XCTAssertEqual(retrievedIndex.name, "user_by_email")
    }

    func testGetIndexesForRecordType() throws {
        let userType = RecordType(
            name: "User",
            primaryKey: FieldKeyExpression(fieldName: "id")
        )

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email"),
            recordTypes: ["User"]
        )

        let universalIndex = Index(
            name: "universal",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "created_at"),
            recordTypes: nil  // Universal
        )

        let metaData = try RecordMetaDataBuilder()
            .addRecordType(userType)
            .addIndex(emailIndex)
            .addIndex(universalIndex)
            .build()

        let indexes = metaData.getIndexesForRecordType("User")

        XCTAssertEqual(indexes.count, 2)
        XCTAssertTrue(indexes.contains { $0.name == "user_by_email" })
        XCTAssertTrue(indexes.contains { $0.name == "universal" })
    }

    func testDuplicateRecordTypeError() {
        let type1 = RecordType(name: "User", primaryKey: FieldKeyExpression(fieldName: "id"))
        let type2 = RecordType(name: "User", primaryKey: FieldKeyExpression(fieldName: "id"))

        XCTAssertThrowsError(
            try RecordMetaDataBuilder()
                .addRecordType(type1)
                .addRecordType(type2)
                .build()
        )
    }
}
