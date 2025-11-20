import Testing
import Foundation
@testable import FoundationDB
@testable import FDBRecordLayer
@testable import FDBRecordCore

@Suite("Simple Save Test")
struct SimpleSaveTest {

    @Recordable
    struct TestPlayer {
        #PrimaryKey<TestPlayer>([\.playerID])
        var playerID: Int64
        var name: String
    }

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    @Test("Save single record")
    func testSaveSingleRecord() async throws {
        print("=== Test Start ===")

        // 1. Database connection
        print("Step 1: Creating database connection...")
        let database = try FDBClient.openDatabase(clusterFilePath: nil)
        print("Step 1: ✅ Database connected")

        // 2. Schema setup
        print("Step 2: Creating schema...")
        let schema = Schema([TestPlayer.self])
        print("Step 2: ✅ Schema created")

        // 3. RecordStore setup
        print("Step 3: Creating RecordStore...")
        let subspace = Subspace(prefix: Tuple("test", "simple_save").pack())
        let store = RecordStore<TestPlayer>(
            database: database,
            subspace: subspace,
            schema: schema,
            statisticsManager: NullStatisticsManager()
        )
        print("Step 3: ✅ RecordStore created")

        // 4. Create record
        print("Step 4: Creating test record...")
        let player = TestPlayer(playerID: 1, name: "Test Player")
        print("Step 4: ✅ Record created: \(player)")

        // 5. Save record
        print("Step 5: Saving record...")
        try await store.save(player)
        print("Step 5: ✅ Record saved")

        // 6. Verify save
        print("Step 6: Verifying save...")
        let retrieved = try await store.record(for: 1)
        print("Step 6: ✅ Retrieved: \(String(describing: retrieved))")

        #expect(retrieved != nil)
        #expect(retrieved?.playerID == 1)
        #expect(retrieved?.name == "Test Player")

        print("=== Test Complete ===")
    }
}
