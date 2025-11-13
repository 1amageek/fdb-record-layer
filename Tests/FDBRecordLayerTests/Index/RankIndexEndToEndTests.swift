import Testing
import Foundation
@testable import FDBRecordLayer
@testable import FoundationDB

/// End-to-end tests for RANK Index
///
/// Verifies:
/// 1. RankIndexMaintainer correctly maintains rank index
/// 2. RankIndexAPI provides correct rank queries
/// 3. O(log n) performance with Range Tree algorithm
/// 4. Leaderboard scenarios (top players, rank lookup, etc.)
@Suite("RANK Index End-to-End Tests")
struct RankIndexEndToEndTests {

    // MARK: - Test Record Types

    @Recordable
    struct Player {
        #Index<Player>([\.score])
        #PrimaryKey<Player>([\.playerID])

        var playerID: Int64
        var name: String
        var score: Int64
    }

    @Recordable
    struct GroupedPlayer {
        #Index<GroupedPlayer>([\.gameID, \.score])
        #PrimaryKey<GroupedPlayer>([\.playerID])

        var playerID: Int64
        var gameID: String
        var name: String
        var score: Int64
    }

    @Recordable
    struct MultiTenantPlayer {
        #Index<MultiTenantPlayer>([\.score])
        #PrimaryKey<MultiTenantPlayer>([\.tenantID, \.playerID])

        var tenantID: String
        var playerID: Int64
        var name: String
        var score: Int64
    }

    // MARK: - Helper Methods

    init() {
        do {
            try FDBNetwork.shared.initialize(version: 710)
        } catch {
            // Network already initialized - this is fine
        }
    }

    func createDatabase() throws -> any DatabaseProtocol {
        return try FDBClient.openDatabase()
    }

    func createSchema<T: Recordable>(for recordType: T.Type) -> Schema {
        // Create RANK index for score field
        let scoreRankIndex = Index(
            name: "score_rank",
            type: .rank,
            rootExpression: FieldKeyExpression(fieldName: "score")
        )
        return Schema([recordType], indexes: [scoreRankIndex])
    }

    func createRecordStore<T: Recordable>(
        database: any DatabaseProtocol,
        recordType: T.Type
    ) async throws -> RecordStore<T> {
        let schema = createSchema(for: recordType)
        let testSubspace = Subspace(prefix: Array("test_rank_\(UUID().uuidString)".utf8))

        return RecordStore<T>(
            database: database,
            subspace: testSubspace,
            schema: schema,
            statisticsManager: StatisticsManager(database: database, subspace: testSubspace.subspace("stats"))
        )
    }

    func clearTestData(database: any DatabaseProtocol) async throws {
        // Data is automatically cleared by using unique subspace per test
    }

    // MARK: - Basic Rank Operations

    @Test("Insert players and verify rank index entries")
    func testInsertPlayersAndVerifyIndex() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert 5 players
        let players = [
            Player(playerID: 1, name: "Alice", score: 1000),
            Player(playerID: 2, name: "Bob", score: 800),
            Player(playerID: 3, name: "Charlie", score: 1200),
            Player(playerID: 4, name: "Diana", score: 950),
            Player(playerID: 5, name: "Eve", score: 1100)
        ]

        for player in players {
            try await store.save(player)
        }

        // Verify index entries exist
        let rankQuery = try store.rankQuery(named: "score_rank")
        let totalCount = try await rankQuery.count()

        #expect(totalCount == 5, "Should have 5 rank index entries")
    }

    @Test("Get top N players")
    func testGetTopNPlayers() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert 10 players with random scores
        for i in 1...10 {
            let player = Player(
                playerID: Int64(i),
                name: "Player\(i)",
                score: Int64.random(in: 100...1000)
            )
            try await store.save(player)
        }

        // Get top 3 players
        let rankQuery = try store.rankQuery(named: "score_rank")
        let top3 = try await rankQuery.top(3)

        #expect(top3.count == 3, "Should return top 3 players")

        // Verify descending order
        if top3.count == 3 {
            #expect(
                top3[0].score >= top3[1].score,
                "1st place should have score >= 2nd place"
            )
            #expect(
                top3[1].score >= top3[2].score,
                "2nd place should have score >= 3rd place"
            )
        }
    }

    @Test("Get player by rank")
    func testGetPlayerByRank() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert players with known scores (descending: 1200, 1100, 1000, 950, 800)
        let players = [
            Player(playerID: 1, name: "Alice", score: 1000),
            Player(playerID: 2, name: "Bob", score: 800),
            Player(playerID: 3, name: "Charlie", score: 1200),
            Player(playerID: 4, name: "Diana", score: 950),
            Player(playerID: 5, name: "Eve", score: 1100)
        ]

        for player in players {
            try await store.save(player)
        }

        // Get 1st place (highest score = 1200 = Charlie)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let firstPlace = try await rankQuery.byRank(1)

        #expect(firstPlace != nil, "1st place should exist")
        #expect(firstPlace?.name == "Charlie", "1st place should be Charlie")
        #expect(firstPlace?.score == 1200, "1st place score should be 1200")

        // Get 3rd place (score = 1000 = Alice)
        let thirdPlace = try await rankQuery.byRank(3)

        #expect(thirdPlace != nil, "3rd place should exist")
        #expect(thirdPlace?.name == "Alice", "3rd place should be Alice")
        #expect(thirdPlace?.score == 1000, "3rd place score should be 1000")
    }

    @Test("Get rank by score")
    func testGetRankByScore() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert players with known scores
        let players = [
            Player(playerID: 1, name: "Alice", score: 1000),
            Player(playerID: 2, name: "Bob", score: 800),
            Player(playerID: 3, name: "Charlie", score: 1200),
            Player(playerID: 4, name: "Diana", score: 950),
            Player(playerID: 5, name: "Eve", score: 1100)
        ]

        for player in players {
            try await store.save(player)
        }

        // Get rank for score 1200 (should be 1st)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let rank1200 = try await rankQuery.getRank(score: 1200, primaryKey: 3)

        #expect(rank1200 == 1, "Score 1200 should be rank 1")

        // Get rank for score 1000 (should be 3rd)
        let rank1000 = try await rankQuery.getRank(score: 1000, primaryKey: 1)

        #expect(rank1000 == 3, "Score 1000 should be rank 3")
    }

    @Test("Get rank range")
    func testGetRankRange() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert 20 players
        for i in 1...20 {
            let player = Player(
                playerID: Int64(i),
                name: "Player\(i)",
                score: Int64(1000 - i * 10)
            )
            try await store.save(player)
        }

        // Get ranks 5-10 (inclusive)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let ranks5to10 = try await rankQuery.range(startRank: 5, endRank: 10)

        #expect(ranks5to10.count == 6, "Should return 6 players (ranks 5-10 inclusive)")

        // Verify descending order
        for i in 0..<(ranks5to10.count - 1) {
            #expect(
                ranks5to10[i].score >= ranks5to10[i + 1].score,
                "Scores should be in descending order"
            )
        }
    }

    @Test("Get score at rank")
    func testGetScoreAtRank() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert players with known scores
        let players = [
            Player(playerID: 1, name: "Alice", score: 1000),
            Player(playerID: 2, name: "Bob", score: 800),
            Player(playerID: 3, name: "Charlie", score: 1200),
            Player(playerID: 4, name: "Diana", score: 950),
            Player(playerID: 5, name: "Eve", score: 1100)
        ]

        for player in players {
            try await store.save(player)
        }

        // Get score at rank 1 (should be 1200)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let scoreAtRank1 = try await rankQuery.scoreAtRank(1)

        #expect(scoreAtRank1 == 1200, "Score at rank 1 should be 1200")

        // Get score at rank 5 (should be 800)
        let scoreAtRank5 = try await rankQuery.scoreAtRank(5)

        #expect(scoreAtRank5 == 800, "Score at rank 5 should be 800")
    }

    @Test("Get players by score range")
    func testGetPlayersByScoreRange() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert players with various scores
        let players = [
            Player(playerID: 1, name: "Alice", score: 1000),
            Player(playerID: 2, name: "Bob", score: 800),
            Player(playerID: 3, name: "Charlie", score: 1200),
            Player(playerID: 4, name: "Diana", score: 950),
            Player(playerID: 5, name: "Eve", score: 1100),
            Player(playerID: 6, name: "Frank", score: 750),
            Player(playerID: 7, name: "Grace", score: 1050)
        ]

        for player in players {
            try await store.save(player)
        }

        // Get players with score between 900 and 1100 (inclusive)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let playersInRange = try await rankQuery.byScoreRange(minScore: 900, maxScore: 1100)

        #expect(playersInRange.count == 4, "Should return 4 players in range")

        // Verify all scores are in range
        for player in playersInRange {
            #expect(
                player.score >= 900 && player.score <= 1100,
                "Player score should be in range [900, 1100]"
            )
        }
    }

    // MARK: - Update and Delete Operations

    @Test("Update player score and verify rank changes")
    func testUpdatePlayerScoreAndVerifyRank() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert players
        let players = [
            Player(playerID: 1, name: "Alice", score: 1000),
            Player(playerID: 2, name: "Bob", score: 800),
            Player(playerID: 3, name: "Charlie", score: 1200)
        ]

        for player in players {
            try await store.save(player)
        }

        // Alice is currently 2nd place (score 1000)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let aliceRankBefore = try await rankQuery.getRank(score: 1000, primaryKey: 1)
        #expect(aliceRankBefore == 2, "Alice should be 2nd place before update")

        // Update Alice's score to 1300 (should become 1st place)
        var alice = players[0]
        alice.score = 1300
        try await store.save(alice)

        // Verify Alice is now 1st place
        let aliceRankAfter = try await rankQuery.getRank(score: 1300, primaryKey: 1)
        #expect(aliceRankAfter == 1, "Alice should be 1st place after update")

        // Verify old rank no longer exists
        let oldRank = try await rankQuery.getRank(score: 1000, primaryKey: 1)
        #expect(oldRank != 2, "Old rank should no longer exist")
    }

    @Test("Delete player and verify rank index updated")
    func testDeletePlayerAndVerifyIndex() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert 3 players
        let players = [
            Player(playerID: 1, name: "Alice", score: 1000),
            Player(playerID: 2, name: "Bob", score: 800),
            Player(playerID: 3, name: "Charlie", score: 1200)
        ]

        for player in players {
            try await store.save(player)
        }

        // Delete Bob
        try await store.delete(by: 2)

        // Verify count decreased
        let rankQuery = try store.rankQuery(named: "score_rank")
        let totalCount = try await rankQuery.count()
        #expect(totalCount == 2, "Should have 2 players after deletion")

        // Verify top 2 does not include Bob
        let top2 = try await rankQuery.top(2)
        let hasBob = top2.contains { $0.playerID == 2 }
        #expect(!hasBob, "Top 2 should not include deleted player Bob")
    }

    // MARK: - Large Dataset Performance

    @Test("Large dataset: Insert 1000 players and verify O(log n) performance")
    func testLargeDatasetPerformance() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        // Insert 1000 players
        let startInsert = Date()
        for i in 1...1000 {
            let player = Player(
                playerID: Int64(i),
                name: "Player\(i)",
                score: Int64.random(in: 100...10000)
            )
            try await store.save(player)
        }
        let insertDuration = Date().timeIntervalSince(startInsert)
        print("Insert 1000 players: \(insertDuration)s")

        // Get rank (should be O(log n))
        let rankQuery = try store.rankQuery(named: "score_rank")
        let startRank = Date()
        let rank = try await rankQuery.getRank(score: 5000, primaryKey: 500)
        let rankDuration = Date().timeIntervalSince(startRank)
        print("Get rank in 1000 players: \(rankDuration)s")

        #expect(rank != nil, "Rank lookup should succeed")
        #expect(rankDuration < 0.1, "Rank lookup should be fast (< 100ms)")

        // Get top 10 (should be O(log n))
        let startTop = Date()
        let top10 = try await rankQuery.top(10)
        let topDuration = Date().timeIntervalSince(startTop)
        print("Get top 10 in 1000 players: \(topDuration)s")

        #expect(top10.count == 10, "Should return top 10 players")
        #expect(topDuration < 0.1, "Top 10 lookup should be fast (< 100ms)")
    }

    // MARK: - Error Handling

    @Test("Invalid rank throws error")
    func testInvalidRankThrowsError() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        let rankQuery = try store.rankQuery(named: "score_rank")

        // Rank 0 should throw error
        await #expect(throws: RecordLayerError.self) {
            _ = try await rankQuery.byRank(0)
        }

        // Negative rank should throw error
        await #expect(throws: RecordLayerError.self) {
            _ = try await rankQuery.byRank(-1)
        }
    }

    @Test("Invalid score range throws error")
    func testInvalidScoreRangeThrowsError() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: Player.self)

        let rankQuery = try store.rankQuery(named: "score_rank")

        // minScore > maxScore should throw error
        await #expect(throws: RecordLayerError.self) {
            _ = try await rankQuery.byScoreRange(minScore: 1000, maxScore: 500)
        }
    }

    // MARK: - Composite Primary Key Tests

    @Test("Composite primary key: Get player by rank")
    func testCompositePrimaryKeyGetByRank() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: MultiTenantPlayer.self)

        // Insert players with composite primary key (tenantID, playerID)
        let players = [
            MultiTenantPlayer(tenantID: "tenant1", playerID: 1, name: "Alice", score: 1000),
            MultiTenantPlayer(tenantID: "tenant1", playerID: 2, name: "Bob", score: 800),
            MultiTenantPlayer(tenantID: "tenant2", playerID: 1, name: "Charlie", score: 1200),
            MultiTenantPlayer(tenantID: "tenant2", playerID: 2, name: "Diana", score: 950),
        ]

        for player in players {
            try await store.save(player)
        }

        // Get 1st place (highest score = 1200 = Charlie from tenant2)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let firstPlace = try await rankQuery.byRank(1)

        #expect(firstPlace != nil, "1st place should exist")
        #expect(firstPlace?.tenantID == "tenant2", "1st place should be from tenant2")
        #expect(firstPlace?.playerID == 1, "1st place should be Charlie")
        #expect(firstPlace?.score == 1200, "1st place score should be 1200")
    }

    @Test("Composite primary key: Get rank by score")
    func testCompositePrimaryKeyGetRank() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: MultiTenantPlayer.self)

        // Insert players with composite primary key
        let players = [
            MultiTenantPlayer(tenantID: "tenant1", playerID: 1, name: "Alice", score: 1000),
            MultiTenantPlayer(tenantID: "tenant1", playerID: 2, name: "Bob", score: 800),
            MultiTenantPlayer(tenantID: "tenant2", playerID: 1, name: "Charlie", score: 1200),
        ]

        for player in players {
            try await store.save(player)
        }

        // Get rank for Charlie (tenant2, playerID=1, score=1200)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let charlieRank = try await rankQuery.getRank(score: 1200, primaryKey: Tuple("tenant2", 1))

        #expect(charlieRank == 1, "Charlie should be rank 1")

        // Get rank for Alice (tenant1, playerID=1, score=1000)
        let aliceRank = try await rankQuery.getRank(score: 1000, primaryKey: Tuple("tenant1", 1))

        #expect(aliceRank == 2, "Alice should be rank 2")
    }

    @Test("Composite primary key: Get score at rank")
    func testCompositePrimaryKeyScoreAtRank() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: MultiTenantPlayer.self)

        // Insert players with composite primary key
        let players = [
            MultiTenantPlayer(tenantID: "tenant1", playerID: 1, name: "Alice", score: 1000),
            MultiTenantPlayer(tenantID: "tenant1", playerID: 2, name: "Bob", score: 800),
            MultiTenantPlayer(tenantID: "tenant2", playerID: 1, name: "Charlie", score: 1200),
            MultiTenantPlayer(tenantID: "tenant2", playerID: 2, name: "Diana", score: 950),
        ]

        for player in players {
            try await store.save(player)
        }

        // Get score at rank 1 (should be 1200)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let scoreAtRank1 = try await rankQuery.scoreAtRank(1)

        #expect(scoreAtRank1 == 1200, "Score at rank 1 should be 1200")

        // Get score at rank 2 (should be 1000)
        let scoreAtRank2 = try await rankQuery.scoreAtRank(2)

        #expect(scoreAtRank2 == 1000, "Score at rank 2 should be 1000")
    }

    @Test("Composite primary key: Get players by score range")
    func testCompositePrimaryKeyByScoreRange() async throws {
        let database = try createDatabase()
        try await clearTestData(database: database)

        let store = try await createRecordStore(database: database, recordType: MultiTenantPlayer.self)

        // Insert players with composite primary key
        let players = [
            MultiTenantPlayer(tenantID: "tenant1", playerID: 1, name: "Alice", score: 1000),
            MultiTenantPlayer(tenantID: "tenant1", playerID: 2, name: "Bob", score: 800),
            MultiTenantPlayer(tenantID: "tenant2", playerID: 1, name: "Charlie", score: 1200),
            MultiTenantPlayer(tenantID: "tenant2", playerID: 2, name: "Diana", score: 950),
            MultiTenantPlayer(tenantID: "tenant3", playerID: 1, name: "Eve", score: 1100),
        ]

        for player in players {
            try await store.save(player)
        }

        // Get players with score between 900 and 1100 (inclusive)
        let rankQuery = try store.rankQuery(named: "score_rank")
        let playersInRange = try await rankQuery.byScoreRange(minScore: 900, maxScore: 1100)

        #expect(playersInRange.count == 3, "Should return 3 players in range")

        // Verify all scores are in range
        for player in playersInRange {
            #expect(
                player.score >= 900 && player.score <= 1100,
                "Player score should be in range [900, 1100]"
            )
        }

        // Verify correct players (Diana=950, Alice=1000, Eve=1100)
        let playerNames = Set(playersInRange.map { $0.name })
        #expect(playerNames.contains("Diana"), "Should include Diana")
        #expect(playerNames.contains("Alice"), "Should include Alice")
        #expect(playerNames.contains("Eve"), "Should include Eve")
    }
}
