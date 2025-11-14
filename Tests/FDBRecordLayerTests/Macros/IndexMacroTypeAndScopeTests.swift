import Testing
import Foundation
@testable import FDBRecordLayer

// MARK: - Test Types with Various Index Type/Scope Parameters

/// Test type with rank index
@Recordable
struct TestUserWithRankIndex {
    #PrimaryKey<TestUserWithRankIndex>([\.userID])
    #Index<TestUserWithRankIndex>([\.score], type: .rank, name: "score_rank")

    var userID: Int64
    var score: Int64
}

/// Test type with count index
@Recordable
struct TestUserWithCountIndex {
    #PrimaryKey<TestUserWithCountIndex>([\.userID])
    #Index<TestUserWithCountIndex>([\.city], type: .count, name: "city_count")

    var userID: Int64
    var city: String
}

/// Test type with sum index
@Recordable
struct TestUserWithSumIndex {
    #PrimaryKey<TestUserWithSumIndex>([\.userID])
    #Index<TestUserWithSumIndex>([\.amount], type: .sum, name: "amount_sum")

    var userID: Int64
    var amount: Int64
}

/// Test type with min index
@Recordable
struct TestUserWithMinIndex {
    #PrimaryKey<TestUserWithMinIndex>([\.userID])
    #Index<TestUserWithMinIndex>([\.price], type: .min, name: "price_min")

    var userID: Int64
    var price: Int64
}

/// Test type with max index
@Recordable
struct TestUserWithMaxIndex {
    #PrimaryKey<TestUserWithMaxIndex>([\.userID])
    #Index<TestUserWithMaxIndex>([\.price], type: .max, name: "price_max")

    var userID: Int64
    var price: Int64
}

/// Test type with global scope index
@Recordable
struct TestUserWithGlobalIndex {
    #PrimaryKey<TestUserWithGlobalIndex>([\.userID])
    #Index<TestUserWithGlobalIndex>([\.email], scope: .global, name: "email_global")

    var userID: Int64
    var email: String
}

/// Test type with partition scope index (explicit)
@Recordable
struct TestUserWithPartitionIndex {
    #PrimaryKey<TestUserWithPartitionIndex>([\.userID])
    #Index<TestUserWithPartitionIndex>([\.email], scope: .partition, name: "email_partition")

    var userID: Int64
    var email: String
}

/// Test type with rank + global combination
@Recordable
struct TestLeaderboardWithGlobalRank {
    #PrimaryKey<TestLeaderboardWithGlobalRank>([\.playerID])
    #Index<TestLeaderboardWithGlobalRank>([\.rating], type: .rank, scope: .global, name: "global_leaderboard")

    var playerID: Int64
    var rating: Double
}

/// Test type with count + partition combination
@Recordable
struct TestAnalyticsWithLocalCount {
    #PrimaryKey<TestAnalyticsWithLocalCount>([\.eventID])
    #Index<TestAnalyticsWithLocalCount>([\.category], type: .count, scope: .partition, name: "category_count_local")

    var eventID: Int64
    var category: String
}

/// Test type with default scope (no explicit scope parameter)
@Recordable
struct TestUserWithDefaultScope {
    #PrimaryKey<TestUserWithDefaultScope>([\.userID])
    #Index<TestUserWithDefaultScope>([\.email], name: "email_default")

    var userID: Int64
    var email: String
}

// MARK: - Tests

@Suite("Index Macro Type/Scope Parameter Tests")
struct IndexMacroTypeAndScopeTests {

    // MARK: - Index Type Tests

    @Test("Index type: .rank generates correct IndexDefinitionType")
    func testRankIndexType() throws {
        let indexDef = TestUserWithRankIndex.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "score_rank")

        if case .rank = indexDef?.indexType {
            // Success
        } else {
            Issue.record("Expected indexType to be .rank, got \(String(describing: indexDef?.indexType))")
        }
    }

    @Test("Index type: .count generates correct IndexDefinitionType")
    func testCountIndexType() throws {
        let indexDef = TestUserWithCountIndex.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "city_count")

        if case .count = indexDef?.indexType {
            // Success
        } else {
            Issue.record("Expected indexType to be .count, got \(String(describing: indexDef?.indexType))")
        }
    }

    @Test("Index type: .sum generates correct IndexDefinitionType")
    func testSumIndexType() throws {
        let indexDef = TestUserWithSumIndex.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "amount_sum")

        if case .sum = indexDef?.indexType {
            // Success
        } else {
            Issue.record("Expected indexType to be .sum, got \(String(describing: indexDef?.indexType))")
        }
    }

    @Test("Index type: .min generates correct IndexDefinitionType")
    func testMinIndexType() throws {
        let indexDef = TestUserWithMinIndex.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "price_min")

        if case .min = indexDef?.indexType {
            // Success
        } else {
            Issue.record("Expected indexType to be .min, got \(String(describing: indexDef?.indexType))")
        }
    }

    @Test("Index type: .max generates correct IndexDefinitionType")
    func testMaxIndexType() throws {
        let indexDef = TestUserWithMaxIndex.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "price_max")

        if case .max = indexDef?.indexType {
            // Success
        } else {
            Issue.record("Expected indexType to be .max, got \(String(describing: indexDef?.indexType))")
        }
    }

    // MARK: - Index Scope Tests

    @Test("Index scope: .global generates correct IndexDefinitionScope")
    func testGlobalIndexScope() throws {
        let indexDef = TestUserWithGlobalIndex.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "email_global")
        #expect(indexDef?.scope == .global)
    }

    @Test("Index scope: .partition generates correct IndexDefinitionScope")
    func testPartitionIndexScope() throws {
        let indexDef = TestUserWithPartitionIndex.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "email_partition")
        #expect(indexDef?.scope == .partition)
    }

    @Test("Index scope: defaults to .partition when not specified")
    func testDefaultIndexScope() throws {
        let indexDef = TestUserWithDefaultScope.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "email_default")
        #expect(indexDef?.scope == .partition)
    }

    // MARK: - Combined Type + Scope Tests

    @Test("Index type .rank + scope .global combination")
    func testRankGlobalCombination() throws {
        let indexDef = TestLeaderboardWithGlobalRank.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "global_leaderboard")
        #expect(indexDef?.scope == .global)

        if case .rank = indexDef?.indexType {
            // Success
        } else {
            Issue.record("Expected indexType to be .rank, got \(String(describing: indexDef?.indexType))")
        }
    }

    @Test("Index type .count + scope .partition combination")
    func testCountPartitionCombination() throws {
        let indexDef = TestAnalyticsWithLocalCount.indexDefinitions.first
        #expect(indexDef != nil)
        #expect(indexDef?.name == "category_count_local")
        #expect(indexDef?.scope == .partition)

        if case .count = indexDef?.indexType {
            // Success
        } else {
            Issue.record("Expected indexType to be .count, got \(String(describing: indexDef?.indexType))")
        }
    }

    // MARK: - Schema Conversion Tests

    @Test("Rank index converts to correct Index type in Schema")
    func testRankIndexSchemaConversion() throws {
        let schema = Schema([TestUserWithRankIndex.self])

        // Find the score_rank index
        guard let index = schema.indexes.first(where: { $0.name == "score_rank" }) else {
            Issue.record("Schema should contain score_rank index")
            return
        }

        #expect(index.name == "score_rank")
        #expect(index.type == .rank)
        #expect(index.scope == .partition)
    }

    @Test("Global scope converts correctly in Schema")
    func testGlobalScopeSchemaConversion() throws {
        let schema = Schema([TestUserWithGlobalIndex.self])

        // Find the email_global index
        guard let index = schema.indexes.first(where: { $0.name == "email_global" }) else {
            Issue.record("Schema should contain email_global index")
            return
        }

        #expect(index.name == "email_global")
        #expect(index.type == .value)
        #expect(index.scope == .global)
    }

    @Test("Rank + Global combination converts correctly in Schema")
    func testRankGlobalSchemaConversion() throws {
        let schema = Schema([TestLeaderboardWithGlobalRank.self])

        // Find the global_leaderboard index
        guard let index = schema.indexes.first(where: { $0.name == "global_leaderboard" }) else {
            Issue.record("Schema should contain global_leaderboard index")
            return
        }

        #expect(index.name == "global_leaderboard")
        #expect(index.type == .rank)
        #expect(index.scope == .global)
    }
}
