import Foundation
 import FDBRecordCore
import Testing
@testable import FoundationDB
@testable import FDBRecordLayer

// MARK: - Test Record

@Recordable
struct PredicateTestUser {
    #Directory<PredicateTestUser>("test", "predicate_users", layer: .recordStore)
    #PrimaryKey<PredicateTestUser>([\.userID])

    

    var userID: Int64
    var name: String
    var email: String
    var age: Int32
    var city: String
    var active: Bool
}

// MARK: - Predicate Tests

@Suite("Predicate Tests", .serialized)
struct PredicateTests {

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

    // MARK: - Helper Functions

    func createTestDatabase() throws -> any DatabaseProtocol {
        return try FDBClient.openDatabase()
    }

    func createTestSubspace() -> Subspace {
        let prefix = Array("test_predicate_\(UUID().uuidString)".utf8)
        return Subspace(prefix: prefix)
    }

    func createTestSchema() throws -> Schema {
        let schema = Schema([PredicateTestUser.self])
        return schema
    }

    func cleanup(database: any DatabaseProtocol, store: RecordStore<PredicateTestUser>) async throws {
        try await database.withTransaction { transaction in
            // Clear all keys in the store's subspace
            let (beginKey, endKey) = store.subspace.range()
            transaction.clearRange(beginKey: beginKey, endKey: endKey)
        }
    }

    func withTestEnvironment<T>(
        _ body: (any DatabaseProtocol, Schema) async throws -> T
    ) async throws -> T {
        let db = try createTestDatabase()
        let schema = try createTestSchema()

        // Create store to get the actual subspace being used
        let store = try await PredicateTestUser.store(database: db, schema: schema)

        do {
            let result = try await body(db, schema)
            try await cleanup(database: db, store: store)
            return result
        } catch {
            try? await cleanup(database: db, store: store)
            throw error
        }
    }

    // MARK: - Tests

    @Test("Equality operator")
    func testEqualityOperator() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            // テストデータを作成
            let alice = PredicateTestUser(
                userID: 1,
                name: "Alice",
                email: "alice@example.com",
                age: 30,
                city: "Tokyo",
                active: true
            )
            let bob = PredicateTestUser(
                userID: 2,
                name: "Bob",
                email: "bob@example.com",
                age: 25,
                city: "Osaka",
                active: true
            )

            // Save records
            try await store.save(alice)
            try await store.save(bob)

            // Predicate演算子を使用したクエリ
            let results = try await store.query()
                .where(\.email == "alice@example.com")
                .execute()

            #expect(results.count == 1)
            #expect(results.first?.name == "Alice")
        }
    }

    @Test("Inequality operator")
    func testInequalityOperator() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let alice = PredicateTestUser(
                userID: 1,
                name: "Alice",
                email: "alice@example.com",
                age: 30,
                city: "Tokyo",
                active: true
            )
            let bob = PredicateTestUser(
                userID: 2,
                name: "Bob",
                email: "bob@example.com",
                age: 25,
                city: "Tokyo",
                active: true
            )

            try await store.save(alice)
            try await store.save(bob)

            // != 演算子のテスト
            let results = try await store.query()
                .where(\.name != "Alice")
                .execute()

            #expect(results.count == 1)
            #expect(results.first?.name == "Bob")
        }
    }

    @Test("Comparison operators (>, <, >=, <=)")
    func testComparisonOperators() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "b@test.com", age: 25, city: "Tokyo", active: true),
                PredicateTestUser(userID: 3, name: "Charlie", email: "c@test.com", age: 35, city: "Tokyo", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // > 演算子
            let over30 = try await store.query()
                .where(\.age > 30)
                .execute()
            #expect(over30.count == 1)
            #expect(over30.first?.name == "Charlie")

            // >= 演算子
            let over30OrEqual = try await store.query()
                .where(\.age >= 30)
                .execute()
            #expect(over30OrEqual.count == 2)

            // < 演算子
            let under30 = try await store.query()
                .where(\.age < 30)
                .execute()
            #expect(under30.count == 1)
            #expect(under30.first?.name == "Bob")

            // <= 演算子
            let under30OrEqual = try await store.query()
                .where(\.age <= 30)
                .execute()
            #expect(under30OrEqual.count == 2)
        }
    }

    @Test("Logical AND operator")
    func testLogicalAnd() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "b@test.com", age: 25, city: "Tokyo", active: true),
                PredicateTestUser(userID: 3, name: "Charlie", email: "c@test.com", age: 35, city: "Osaka", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // AND 演算子
            let results = try await store.query()
                .where(\.city == "Tokyo" && \.age > 25)
                .execute()

            #expect(results.count == 1)
            #expect(results.first?.name == "Alice")
        }
    }

    @Test("Logical OR operator")
    func testLogicalOr() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "b@test.com", age: 25, city: "Osaka", active: true),
                PredicateTestUser(userID: 3, name: "Charlie", email: "c@test.com", age: 35, city: "Nagoya", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // OR 演算子
            let results = try await store.query()
                .where(\.city == "Tokyo" || \.city == "Osaka")
                .execute()

            #expect(results.count == 2)
        }
    }

    @Test("Logical NOT operator")
    func testLogicalNot() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "b@test.com", age: 25, city: "Tokyo", active: false),
            ]

            for user in users {
                try await store.save(user)
            }

            // NOT 演算子
            let results = try await store.query()
                .where(!(\.active == false))
                .execute()

            #expect(results.count == 1)
            #expect(results.first?.name == "Alice")
        }
    }

    @Test("Complex predicate with multiple operators")
    func testComplexPredicate() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "b@test.com", age: 25, city: "Tokyo", active: false),
                PredicateTestUser(userID: 3, name: "Charlie", email: "c@test.com", age: 35, city: "Osaka", active: true),
                PredicateTestUser(userID: 4, name: "Dave", email: "d@test.com", age: 40, city: "Tokyo", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // 複雑な条件：(city == "Tokyo" AND active == true) AND (age >= 30)
            let results = try await store.query()
                .where((\.city == "Tokyo" && \.active == true) && \.age >= 30)
                .execute()

            #expect(results.count == 2)
            let names = results.map { $0.name }.sorted()
            #expect(names == ["Alice", "Dave"])
        }
    }

    @Test("String hasPrefix operator")
    func testStringHasPrefix() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "alice@example.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "bob@example.com", age: 25, city: "Tokyo", active: true),
                PredicateTestUser(userID: 3, name: "Charlie", email: "charlie@test.com", age: 35, city: "Tokyo", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // hasPrefix のテスト
            let results = try await store.query()
                .where((\PredicateTestUser.email).hasPrefix("alice"))
                .execute()

            #expect(results.count == 1)
            #expect(results.first?.name == "Alice")
        }
    }

    @Test("String contains operator")
    func testStringContains() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "alice@example.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "bob@example.com", age: 25, city: "Tokyo", active: true),
                PredicateTestUser(userID: 3, name: "Charlie", email: "charlie@test.com", age: 35, city: "Tokyo", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // contains のテスト
            let results = try await store.query()
                .where((\PredicateTestUser.email).contains("@example"))
                .execute()

            #expect(results.count == 2)
        }
    }

    @Test("orderBy ascending")
    func testOrderByAscending() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Charlie", email: "c@test.com", age: 35, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 3, name: "Bob", email: "b@test.com", age: 25, city: "Tokyo", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // 年齢で昇順ソート
            let results = try await store.query()
                .orderBy(\.age, .ascending)
                .execute()

            #expect(results.count == 3)
            #expect(results[0].name == "Bob")
            #expect(results[1].name == "Alice")
            #expect(results[2].name == "Charlie")
        }
    }

    @Test("orderBy descending")
    func testOrderByDescending() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Bob", email: "b@test.com", age: 25, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 3, name: "Charlie", email: "c@test.com", age: 35, city: "Tokyo", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // 年齢で降順ソート
            let results = try await store.query()
                .orderBy(\.age, .descending)
                .execute()

            #expect(results.count == 3)
            #expect(results[0].name == "Charlie")
            #expect(results[1].name == "Alice")
            #expect(results[2].name == "Bob")
        }
    }

    @Test("Combined where and orderBy")
    func testCombinedWhereAndOrderBy() async throws {
        try await withTestEnvironment { db, schema in
            let store = try await PredicateTestUser.store(database: db, schema: schema)

            let users = [
                PredicateTestUser(userID: 1, name: "Alice", email: "a@test.com", age: 30, city: "Tokyo", active: true),
                PredicateTestUser(userID: 2, name: "Bob", email: "b@test.com", age: 25, city: "Osaka", active: true),
                PredicateTestUser(userID: 3, name: "Charlie", email: "c@test.com", age: 35, city: "Tokyo", active: true),
                PredicateTestUser(userID: 4, name: "Dave", email: "d@test.com", age: 28, city: "Tokyo", active: true),
            ]

            for user in users {
                try await store.save(user)
            }

            // 東京在住のユーザーを年齢降順でソート
            let results = try await store.query()
                .where(\.city == "Tokyo")
                .orderBy(\.age, .descending)
                .execute()

            #expect(results.count == 3)
            #expect(results[0].name == "Charlie")
            #expect(results[1].name == "Alice")
            #expect(results[2].name == "Dave")
        }
    }
}
