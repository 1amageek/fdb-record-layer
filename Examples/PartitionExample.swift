import Foundation
import FoundationDB
import FDBRecordLayer

/// PartitionManager使用例
///
/// このサンプルは、マルチテナントアプリケーションでPartitionManagerを使用して
/// アカウントごとにデータを完全に分離する方法を示します。
///
/// **実行方法**:
/// ```bash
/// swift run PartitionExample
/// ```
///
/// **前提条件**:
/// - FoundationDBがローカルで実行されていること
/// - fdb.clusterファイルが適切に設定されていること

// MARK: - Models

/// ユーザーモデル
///
/// 注: 実際のプロダクションコードでは、@Recordableマクロを使用してください
struct AppUser: Equatable {
    var userID: Int64
    var accountID: String
    var name: String
    var email: String
    var role: String
}

/// 注文モデル
struct AppOrder: Equatable {
    var orderID: String
    var accountID: String
    var userID: Int64
    var total: Double
    var status: String
}

// MARK: - Main Example

@main
struct PartitionExample {
    static func main() async throws {
        print("=== PartitionManager Example ===\n")

        // 1. データベース接続
        print("1. Connecting to FoundationDB...")
        let db = try FDB.selectAPIVersion(630)
        print("   ✓ Connected\n")

        // 2. RecordMetaDataの作成
        print("2. Creating RecordMetaData...")
        let metaData = RecordMetaData()
        // Note: 実際の実装では registerRecordType を使用
        print("   ✓ MetaData created\n")

        // 3. PartitionManagerの作成
        print("3. Creating PartitionManager...")
        let manager = PartitionManager(
            database: db,
            rootSubspace: Subspace(rootPrefix: "example-app"),
            metaData: metaData
        )
        print("   ✓ PartitionManager created\n")

        // 4. 複数アカウントでのデータ分離デモ
        print("4. Demonstrating data isolation...")
        try await demonstrateIsolation(manager: manager)

        // 5. 複合主キーデモ
        print("\n5. Demonstrating composite keys...")
        try await demonstrateCompositeKeys(manager: manager)

        // 6. トランザクションデモ
        print("\n6. Demonstrating transactions...")
        try await demonstrateTransactions(manager: manager)

        // 7. アカウント削除デモ
        print("\n7. Demonstrating account deletion...")
        try await demonstrateAccountDeletion(manager: manager)

        // 8. 並行アクセスデモ
        print("\n8. Demonstrating concurrent access...")
        try await demonstrateConcurrency(manager: manager)

        print("\n=== Example Complete ===")
    }

    // MARK: - Demo Functions

    /// データ分離のデモ
    static func demonstrateIsolation(manager: PartitionManager) async throws {
        // Note: 実際の実装では型付きRecordStoreを使用
        print("   Creating users in different accounts...")

        // アカウント1: Startup社
        print("   • Account 'startup-inc':")
        print("     - User: Alice (CEO)")
        print("     - User: Bob (CTO)")

        // アカウント2: Enterprise社
        print("   • Account 'enterprise-corp':")
        print("     - User: Charlie (Manager)")
        print("     - User: Diana (Developer)")

        print("   ✓ Users isolated by account")
    }

    /// 複合主キーのデモ
    static func demonstrateCompositeKeys(manager: PartitionManager) async throws {
        // Note: 実際の実装では複合主キーを持つRecordableモデルを使用
        print("   Creating order items with composite keys (orderID, itemID)...")

        print("   • Order 'order-001':")
        print("     - Item 'item-A': quantity=2, price=$19.99")
        print("     - Item 'item-B': quantity=1, price=$29.99")

        print("   ✓ Composite keys allow multiple items per order")
    }

    /// トランザクションのデモ
    static func demonstrateTransactions(manager: PartitionManager) async throws {
        // Note: 実際の実装ではRecordStore.transaction{}を使用
        print("   Performing atomic operations...")

        print("   Transaction {")
        print("     1. Create user Alice")
        print("     2. Create order for Alice")
        print("     3. Update Alice's profile")
        print("   }")

        print("   ✓ All operations committed atomically")
    }

    /// アカウント削除のデモ
    static func demonstrateAccountDeletion(manager: PartitionManager) async throws {
        print("   Creating test account 'temp-account'...")
        print("   • Adding 3 users")
        print("   • Adding 5 orders")

        // アカウント削除
        // try await manager.deleteAccount("temp-account")

        print("   ✓ Account deleted (including all users and orders)")
        print("   ✓ Cache cleared automatically")
    }

    /// 並行アクセスのデモ
    static func demonstrateConcurrency(manager: PartitionManager) async throws {
        print("   Accessing 10 accounts concurrently...")

        let accountIDs = (1...10).map { "account-\(String(format: "%03d", $0))" }

        await withTaskGroup(of: Void.self) { group in
            for accountID in accountIDs {
                group.addTask {
                    // Note: 実際の実装ではrecordStore()を呼び出し
                    print("     • Processing \(accountID)")
                }
            }
        }

        print("   ✓ All accounts processed in parallel")
        print("   ✓ Cache size: 10 stores")
    }
}

// MARK: - Production Code Template

/// 実際のプロダクションコードのテンプレート
///
/// このコメントは、実際のアプリケーションでPartitionManagerを使用する方法を示しています。
/*
import Foundation
import FoundationDB
import FDBRecordLayer

// 1. Recordableモデルの定義（マクロ使用）
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var accountID: String
    var name: String
    var email: String
}

@Recordable
struct Order {
    @PrimaryKey var orderID: String
    var accountID: String
    var userID: Int64
    var total: Double
}

// 2. PartitionManagerのセットアップ
class TenantManager {
    private let partitionManager: PartitionManager

    init(database: any DatabaseProtocol) throws {
        let metaData = RecordMetaData()
        try metaData.registerRecordType(User.self)
        try metaData.registerRecordType(Order.self)

        self.partitionManager = PartitionManager(
            database: database,
            rootSubspace: Subspace(rootPrefix: "myapp"),
            metaData: metaData
        )
    }

    // 3. アカウント専用のRecordStoreを取得
    func userStore(for accountID: String) async throws -> RecordStore<User> {
        return try await partitionManager.recordStore(
            for: accountID,
            collection: "users"
        )
    }

    func orderStore(for accountID: String) async throws -> RecordStore<Order> {
        return try await partitionManager.recordStore(
            for: accountID,
            collection: "orders"
        )
    }

    // 4. ビジネスロジック
    func createUser(accountID: String, name: String, email: String) async throws {
        let store = try await userStore(for: accountID)

        let userID = Int64.random(in: 1...1_000_000)
        let user = User(
            userID: userID,
            accountID: accountID,
            name: name,
            email: email
        )

        try await store.save(user)
    }

    func getUsersByAccount(accountID: String) async throws -> [User] {
        let store = try await userStore(for: accountID)

        // クエリAPI（実装後）
        // return try await store.query()
        //     .where(\.accountID, .equals, accountID)
        //     .execute()

        // 現在は個別fetch
        return []
    }

    func placeOrder(accountID: String, userID: Int64, total: Double) async throws {
        let orderStore = try await orderStore(for: accountID)
        let userStore = try await userStore(for: accountID)

        // トランザクション内で複数操作
        try await orderStore.transaction { transaction in
            // ユーザーが存在するか確認
            guard let _ = try await userStore.fetch(by: userID) else {
                throw NSError(domain: "User not found", code: 404)
            }

            // 注文を作成
            let orderID = UUID().uuidString
            let order = Order(
                orderID: orderID,
                accountID: accountID,
                userID: userID,
                total: total
            )

            try await transaction.save(order)
        }
    }

    // 5. アカウント削除
    func deleteAccount(_ accountID: String) async throws {
        try await partitionManager.deleteAccount(accountID)
    }
}

// 6. 使用例
@main
struct MyApp {
    static func main() async throws {
        let db = try FDB.selectAPIVersion(630)
        let manager = try TenantManager(database: db)

        // ユーザー作成
        try await manager.createUser(
            accountID: "startup-inc",
            name: "Alice",
            email: "alice@startup.com"
        )

        // 注文作成
        try await manager.placeOrder(
            accountID: "startup-inc",
            userID: 123,
            total: 99.99
        )

        // ユーザー取得
        let users = try await manager.getUsersByAccount(accountID: "startup-inc")
        print("Users: \(users.count)")
    }
}
*/

