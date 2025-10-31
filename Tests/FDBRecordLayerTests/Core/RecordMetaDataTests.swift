import Testing
@testable import FDBRecordLayer

@Suite("RecordMetaData Tests")
struct RecordMetaDataTests {
    @Test("MetaData builder creates metadata with version, record types and indexes")
    func metaDataBuilder() throws {
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

        #expect(metaData.version == 1)
        #expect(metaData.recordTypes.count == 1)
        #expect(metaData.indexes.count == 1)

        let retrievedType = try metaData.getRecordType("User")
        #expect(retrievedType.name == "User")

        let retrievedIndex = try metaData.getIndex("user_by_email")
        #expect(retrievedIndex.name == "user_by_email")
    }

    @Test("Get indexes for record type returns record-specific and universal indexes")
    func getIndexesForRecordType() throws {
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

        #expect(indexes.count == 2)
        #expect(indexes.contains { $0.name == "user_by_email" })
        #expect(indexes.contains { $0.name == "universal" })
    }

    @Test("Duplicate record type throws error")
    func duplicateRecordTypeError() {
        let type1 = RecordType(name: "User", primaryKey: FieldKeyExpression(fieldName: "id"))
        let type2 = RecordType(name: "User", primaryKey: FieldKeyExpression(fieldName: "id"))

        #expect(throws: (any Error).self) {
            try RecordMetaDataBuilder()
                .addRecordType(type1)
                .addRecordType(type2)
                .build()
        }
    }
}
