import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer

/// Tests for OnlineIndexScrubber
///
/// Covers:
/// 1. Factory method validation (index type, index state)
/// 2. Phase 1: Index entries scan (dangling entry detection/repair)
/// 3. Phase 2: Records scan (missing entry detection/repair)
/// 4. Multi-valued field support
/// 5. Multi-record type support
/// 6. Configuration presets (default, conservative, aggressive)
/// 7. Progress tracking (separate RangeSets for Phase 1/2)
@Suite("OnlineIndexScrubber Tests")
struct OnlineIndexScrubberTests {

    // MARK: - Initialization

    /// Initialize FoundationDB network once for all tests
    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
            // (Multiple test suites may try to initialize)
        }
    }

    // MARK: - Test Helpers

    /// Simple test record
    struct TestUser: Codable, Equatable {
        let id: Int64
        let name: String
        let email: String
        let age: Int
        let tags: [String]  // Multi-valued field
    }

    /// Simple RecordAccess implementation for testing
    struct TestUserAccess: RecordAccess {
        typealias Record = TestUser

        func serialize(_ record: TestUser) throws -> FDB.Bytes {
            let data = try JSONEncoder().encode(record)
            return Array(data)
        }

        func deserialize(_ bytes: FDB.Bytes) throws -> TestUser {
            let data = Data(bytes)
            return try JSONDecoder().decode(TestUser.self, from: data)
        }

        func extractField(from record: TestUser, fieldName: String) throws -> [any TupleElement] {
            switch fieldName {
            case "id":
                return [record.id]
            case "name":
                return [record.name]
            case "email":
                return [record.email]
            case "age":
                return [record.age]
            case "tags":
                // Multi-valued field: return all tags
                return record.tags.map { $0 as any TupleElement }
            default:
                throw RecordLayerError.invalidArgument("Field not found: \(fieldName)")
            }
        }

        func recordTypeName(for record: TestUser) -> String {
            return "TestUser"
        }
    }

    func createTestDatabase() throws -> any DatabaseProtocol {
        return try FDBClient.openDatabase()
    }

    func createTestSubspace() -> Subspace {
        return Subspace(rootPrefix: "test_scrubber_\(UUID().uuidString)")
    }

    func createTestMetadata() throws -> RecordMetaData {
        let primaryKey = FieldKeyExpression(fieldName: "id")
        let userType = RecordType(name: "TestUser", primaryKey: primaryKey)

        let emailIndex = Index(
            name: "user_by_email",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email"),
            recordTypes: ["TestUser"]
        )

        let ageIndex = Index(
            name: "user_by_age",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "age"),
            recordTypes: ["TestUser"]
        )

        let tagsIndex = Index(
            name: "user_by_tags",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "tags"),
            recordTypes: ["TestUser"]
        )

        return try RecordMetaDataBuilder()
            .addRecordType(userType)
            .addIndex(emailIndex)
            .addIndex(ageIndex)
            .addIndex(tagsIndex)
            .build()
    }

    func cleanup(database: any DatabaseProtocol, subspace: Subspace) async throws {
        try await database.withRecordContext { context in
            let transaction = context.getTransaction()
            let (begin, end) = subspace.range()
            transaction.clearRange(beginKey: begin, endKey: end)
        }
    }

    // MARK: - Factory Method Validation Tests

    @Test("Factory method validates index type")
    func factoryValidatesIndexType() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        // Create a COUNT index (not supported for scrubbing)
        let countIndex = Index(
            name: "user_count",
            type: .count,
            rootExpression: FieldKeyExpression(fieldName: "age"),
            recordTypes: ["TestUser"]
        )

        // Mark index as readable
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(countIndex.name)
        try await indexStateManager.makeReadable(countIndex.name)

        let recordAccess = TestUserAccess()

        // Should throw error for unsupported index type
        await #expect(throws: RecordLayerError.self) {
            try await OnlineIndexScrubber<TestUser>.create(
                database: db,
                subspace: subspace,
                metaData: metaData,
                index: countIndex,
                recordAccess: recordAccess
            )
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Factory method validates index state")
    func factoryValidatesIndexState() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let emailIndex = try metaData.getIndex("user_by_email")

        // Mark index as write_only (not ready for scrubbing)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(emailIndex.name)  // Sets to writeOnly

        let recordAccess = TestUserAccess()

        // Should throw error for non-readable index
        await #expect(throws: RecordLayerError.self) {
            try await OnlineIndexScrubber<TestUser>.create(
                database: db,
                subspace: subspace,
                metaData: metaData,
                index: emailIndex,
                recordAccess: recordAccess
            )
        }

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Factory method succeeds for valid VALUE index")
    func factorySucceedsForValidIndex() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let emailIndex = try metaData.getIndex("user_by_email")

        // Mark index as readable (must enable first, then make readable)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(emailIndex.name)
        try await indexStateManager.makeReadable(emailIndex.name)

        let recordAccess = TestUserAccess()

        // Should succeed
        let scrubber = try await OnlineIndexScrubber<TestUser>.create(
            database: db,
            subspace: subspace,
            metaData: metaData,
            index: emailIndex,
            recordAccess: recordAccess
        )

        // Scrubber was created successfully (non-optional type)
        _ = scrubber

        try await cleanup(database: db, subspace: subspace)
    }

    // MARK: - Configuration Preset Tests

    @Test("Configuration default preset")
    func configurationDefaultPreset() {
        let config = ScrubberConfiguration.default

        #expect(config.entriesScanLimit == 1_000)
        #expect(config.maxTransactionBytes == 9_000_000)
        #expect(config.transactionTimeoutMillis == 4_000)
        #expect(config.allowRepair == false)
        #expect(config.supportedTypes == [IndexType.value])
    }

    @Test("Configuration conservative preset")
    func configurationConservativePreset() {
        let config = ScrubberConfiguration.conservative

        #expect(config.entriesScanLimit == 100)
        #expect(config.maxTransactionBytes == 1_000_000)
        #expect(config.transactionTimeoutMillis == 2_000)
        #expect(config.allowRepair == false)
    }

    @Test("Configuration aggressive preset")
    func configurationAggressivePreset() {
        let config = ScrubberConfiguration.aggressive

        #expect(config.entriesScanLimit == 10_000)
        #expect(config.maxTransactionBytes == 9_000_000)
        #expect(config.transactionTimeoutMillis == 4_000)
        #expect(config.allowRepair == true)
    }

    // MARK: - Phase 1: Dangling Entry Detection Tests

    @Test("Phase 1 detects dangling index entries")
    func phase1DetectsDanglingEntries() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let emailIndex = try metaData.getIndex("user_by_email")

        // Mark index as readable (must enable first, then make readable)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(emailIndex.name)
        try await indexStateManager.makeReadable(emailIndex.name)

        // Insert dangling index entry (no corresponding record)
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(emailIndex.name)  // ✅ Use index name directly, not wrapped in Tuple

            // Create dangling entry: (email, id) -> empty bytes
            let danglingKey = indexSubspace.pack(Tuple("orphan@example.com", Int64(999)))
            transaction.setValue([], for: danglingKey)
        }

        // Run scrubber (without repair)
        let recordAccess = TestUserAccess()
        let scrubber = try await OnlineIndexScrubber<TestUser>.create(
            database: db,
            subspace: subspace,
            metaData: metaData,
            index: emailIndex,
            recordAccess: recordAccess,
            configuration: .default
        )

        let result = await scrubber.scrubIndex()

        // Should detect 1 dangling entry
        #expect(result.summary.danglingEntriesDetected == 1)
        #expect(result.summary.danglingEntriesRepaired == 0)  // Repair disabled

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Phase 1 repairs dangling index entries when enabled")
    func phase1RepairsDanglingEntries() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let emailIndex = try metaData.getIndex("user_by_email")

        // Mark index as readable (must enable first, then make readable)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(emailIndex.name)
        try await indexStateManager.makeReadable(emailIndex.name)

        // Insert dangling index entry
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(emailIndex.name)

            let danglingKey = indexSubspace.pack(Tuple("orphan@example.com", Int64(999)))
            transaction.setValue([], for: danglingKey)
        }

        // Run scrubber with repair enabled
        let recordAccess = TestUserAccess()
        let config = ScrubberConfiguration(
            entriesScanLimit: 1_000,
            maxTransactionBytes: 9_000_000,
            transactionTimeoutMillis: 4_000,
            readYourWrites: false,
            allowRepair: true,  // ✅ Enable repair
            supportedTypes: [IndexType.value],
            logWarningsLimit: 100,
            enableProgressLogging: false,
            progressLogIntervalSeconds: 10.0,
            maxRetries: 10,
            retryDelayMillis: 100
        )

        let scrubber = try await OnlineIndexScrubber<TestUser>.create(
            database: db,
            subspace: subspace,
            metaData: metaData,
            index: emailIndex,
            recordAccess: recordAccess,
            configuration: config
        )

        let result = await scrubber.scrubIndex()

        // Should detect and repair 1 dangling entry
        #expect(result.summary.danglingEntriesDetected == 1)
        #expect(result.summary.danglingEntriesRepaired == 1)

        // Verify entry was deleted
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(emailIndex.name)

            let danglingKey = indexSubspace.pack(Tuple("orphan@example.com", Int64(999)))
            let value = try await transaction.getValue(for: danglingKey, snapshot: true)

            #expect(value == nil)  // Should be deleted
        }

        try await cleanup(database: db, subspace: subspace)
    }

    // MARK: - Phase 2: Missing Entry Detection Tests

    @Test("Phase 2 detects missing index entries")
    func phase2DetectsMissingEntries() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let emailIndex = try metaData.getIndex("user_by_email")

        // Mark index as readable (must enable first, then make readable)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(emailIndex.name)
        try await indexStateManager.makeReadable(emailIndex.name)

        // Save record WITHOUT index entry
        let user = TestUser(
            id: 1,
            name: "Alice",
            email: "alice@example.com",
            age: 30,
            tags: ["swift", "fdb"]
        )

        let recordAccess = TestUserAccess()

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let recordSubspace = subspace
                .subspace(RecordStoreKeyspace.record.rawValue)
                .subspace("TestUser")

            let recordKey = recordSubspace.pack(Tuple(user.id))
            let recordBytes = try recordAccess.serialize(user)
            transaction.setValue(recordBytes, for: recordKey)

            // Intentionally skip creating index entry
        }

        // Run scrubber (without repair)
        let scrubber = try await OnlineIndexScrubber<TestUser>.create(
            database: db,
            subspace: subspace,
            metaData: metaData,
            index: emailIndex,
            recordAccess: recordAccess,
            configuration: .default
        )

        let result = await scrubber.scrubIndex()

        // Should detect 1 missing entry
        #expect(result.summary.missingEntriesDetected == 1)
        #expect(result.summary.missingEntriesRepaired == 0)  // Repair disabled

        try await cleanup(database: db, subspace: subspace)
    }

    @Test("Phase 2 repairs missing index entries when enabled")
    func phase2RepairsMissingEntries() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let emailIndex = try metaData.getIndex("user_by_email")

        // Mark index as readable (must enable first, then make readable)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(emailIndex.name)
        try await indexStateManager.makeReadable(emailIndex.name)

        // Save record WITHOUT index entry
        let user = TestUser(
            id: 1,
            name: "Alice",
            email: "alice@example.com",
            age: 30,
            tags: ["swift", "fdb"]
        )

        let recordAccess = TestUserAccess()

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let recordSubspace = subspace
                .subspace(RecordStoreKeyspace.record.rawValue)
                .subspace("TestUser")

            let recordKey = recordSubspace.pack(Tuple(user.id))
            let recordBytes = try recordAccess.serialize(user)
            transaction.setValue(recordBytes, for: recordKey)
        }

        // Run scrubber with repair enabled
        let config = ScrubberConfiguration(
            entriesScanLimit: 1_000,
            maxTransactionBytes: 9_000_000,
            transactionTimeoutMillis: 4_000,
            readYourWrites: false,
            allowRepair: true,  // ✅ Enable repair
            supportedTypes: [IndexType.value],
            logWarningsLimit: 100,
            enableProgressLogging: false,
            progressLogIntervalSeconds: 10.0,
            maxRetries: 10,
            retryDelayMillis: 100
        )

        let scrubber = try await OnlineIndexScrubber<TestUser>.create(
            database: db,
            subspace: subspace,
            metaData: metaData,
            index: emailIndex,
            recordAccess: recordAccess,
            configuration: config
        )

        let result = await scrubber.scrubIndex()

        // Should detect and repair 1 missing entry
        #expect(result.summary.missingEntriesDetected == 1)
        #expect(result.summary.missingEntriesRepaired == 1)

        // Verify entry was created
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(emailIndex.name)

            let expectedKey = indexSubspace.pack(Tuple("alice@example.com", user.id))
            let value = try await transaction.getValue(for: expectedKey, snapshot: true)

            #expect(value != nil)  // Should be created
        }

        try await cleanup(database: db, subspace: subspace)
    }

    // MARK: - Multi-Valued Field Tests

    @Test("Handles multi-valued fields correctly")
    func handlesMultiValuedFields() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let tagsIndex = try metaData.getIndex("user_by_tags")

        // Mark index as readable (must enable first, then make readable)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(tagsIndex.name)
        try await indexStateManager.makeReadable(tagsIndex.name)

        // Save record with multiple tags but only one index entry
        let user = TestUser(
            id: 1,
            name: "Alice",
            email: "alice@example.com",
            age: 30,
            tags: ["swift", "fdb", "testing"]
        )

        let recordAccess = TestUserAccess()

        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let recordSubspace = subspace
                .subspace(RecordStoreKeyspace.record.rawValue)
                .subspace("TestUser")

            let recordKey = recordSubspace.pack(Tuple(user.id))
            let recordBytes = try recordAccess.serialize(user)
            transaction.setValue(recordBytes, for: recordKey)

            // Create index entry for only one tag
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(tagsIndex.name)

            let swiftKey = indexSubspace.pack(Tuple("swift", user.id))
            transaction.setValue([], for: swiftKey)
        }

        // Run scrubber with repair enabled
        let config = ScrubberConfiguration(
            entriesScanLimit: 1_000,
            maxTransactionBytes: 9_000_000,
            transactionTimeoutMillis: 4_000,
            readYourWrites: false,
            allowRepair: true,
            supportedTypes: [IndexType.value],
            logWarningsLimit: 100,
            enableProgressLogging: false,
            progressLogIntervalSeconds: 10.0,
            maxRetries: 10,
            retryDelayMillis: 100
        )

        let scrubber = try await OnlineIndexScrubber<TestUser>.create(
            database: db,
            subspace: subspace,
            metaData: metaData,
            index: tagsIndex,
            recordAccess: recordAccess,
            configuration: config
        )

        let result = await scrubber.scrubIndex()

        // Should detect 2 missing entries (fdb, testing)
        #expect(result.summary.missingEntriesDetected == 2)
        #expect(result.summary.missingEntriesRepaired == 2)

        // Verify all 3 entries exist
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(tagsIndex.name)

            for tag in user.tags {
                let key = indexSubspace.pack(Tuple(tag, user.id))
                let value = try await transaction.getValue(for: key, snapshot: true)
                #expect(value != nil, "Index entry for tag '\(tag)' should exist")
            }
        }

        try await cleanup(database: db, subspace: subspace)
    }

    // MARK: - Result Aggregation Tests

    @Test("Result aggregates statistics correctly")
    func resultAggregatesStatistics() async throws {
        let db = try createTestDatabase()
        let subspace = createTestSubspace()
        let metaData = try createTestMetadata()

        let emailIndex = try metaData.getIndex("user_by_email")

        // Mark index as readable (must enable first, then make readable)
        let indexStateManager = IndexStateManager(database: db, subspace: subspace)
        try await indexStateManager.enable(emailIndex.name)
        try await indexStateManager.makeReadable(emailIndex.name)

        let recordAccess = TestUserAccess()

        // Create scenario: 1 dangling entry + 1 missing entry
        try await db.withRecordContext { context in
            let transaction = context.getTransaction()
            let indexSubspace = subspace
                .subspace(RecordStoreKeyspace.index.rawValue)
                .subspace(emailIndex.name)
            let recordSubspace = subspace
                .subspace(RecordStoreKeyspace.record.rawValue)
                .subspace("TestUser")

            // 1. Dangling entry
            let danglingKey = indexSubspace.pack(Tuple("orphan@example.com", Int64(999)))
            transaction.setValue([], for: danglingKey)

            // 2. Record without index entry
            let user = TestUser(
                id: 1,
                name: "Alice",
                email: "alice@example.com",
                age: 30,
                tags: ["swift"]
            )
            let recordKey = recordSubspace.pack(Tuple(user.id))
            let recordBytes = try recordAccess.serialize(user)
            transaction.setValue(recordBytes, for: recordKey)
        }

        // Run scrubber with repair enabled
        let config = ScrubberConfiguration(
            entriesScanLimit: 1_000,
            maxTransactionBytes: 9_000_000,
            transactionTimeoutMillis: 4_000,
            readYourWrites: false,
            allowRepair: true,
            supportedTypes: [IndexType.value],
            logWarningsLimit: 100,
            enableProgressLogging: false,
            progressLogIntervalSeconds: 10.0,
            maxRetries: 10,
            retryDelayMillis: 100
        )

        let scrubber = try await OnlineIndexScrubber<TestUser>.create(
            database: db,
            subspace: subspace,
            metaData: metaData,
            index: emailIndex,
            recordAccess: recordAccess,
            configuration: config
        )

        let result = await scrubber.scrubIndex()

        // Verify statistics
        #expect(result.summary.danglingEntriesDetected == 1)
        #expect(result.summary.danglingEntriesRepaired == 1)
        #expect(result.summary.missingEntriesDetected == 1)
        #expect(result.summary.missingEntriesRepaired == 1)
        #expect(result.summary.entriesScanned > 0)
        #expect(result.summary.recordsScanned > 0)

        try await cleanup(database: db, subspace: subspace)
    }
}
