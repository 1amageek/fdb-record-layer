import Foundation
import FoundationDB
import Logging
import Synchronization

/// マルチテナント対応のパーティション管理クラス
///
/// PartitionManagerは、アカウントIDごとに分離されたRecordStoreを管理します。
/// 各アカウントは独立したSubspace内にデータを保持し、完全なデータ分離を実現します。
///
/// **設計原則**:
/// - final class + Mutex パターン（actorではなく高スループット）
/// - I/O操作はロック外で実行（並列性を最大化）
/// - RecordStore<Record>をキャッシュして再利用
/// - メトリクスとロギングを自動設定
///
/// **使用例**:
/// ```swift
/// let partitionManager = PartitionManager(
///     database: database,
///     rootSubspace: Subspace(rootPrefix: "app"),
///     metaData: metaData
/// )
///
/// // アカウント専用のRecordStoreを取得
/// let userStore: RecordStore<User> = try await partitionManager.recordStore(
///     for: "acct-001",
///     collection: "users"
/// )
///
/// // 型安全な操作
/// try await userStore.save(user)
/// let users = try await userStore.query()
///     .where(\.name, .equals, "Alice")
///     .execute()
/// ```
public final class PartitionManager: Sendable {
    // MARK: - Properties

    /// FoundationDBデータベース
    /// nonisolated(unsafe): DatabaseProtocolは内部でスレッドセーフ
    nonisolated(unsafe) private let database: any DatabaseProtocol

    /// ルートSubspace（例: "app"）
    private let rootSubspace: Subspace

    /// RecordMetaData（全パーティションで共有）
    private let metaData: RecordMetaData

    /// StatisticsManager（オプション）
    private let statisticsManager: (any StatisticsManagerProtocol)?

    /// RecordStoreキャッシュ（型消去されたAny、実際はRecordStore<Record>）
    /// Key: "accountID.collection.recordTypeName" (型安全性のため型名を含む)
    /// Value: RecordStore<Record>（型ごとに異なる）
    private let storeCacheLock: Mutex<[String: Any]>

    // MARK: - Initialization

    /// PartitionManagerを初期化
    ///
    /// - Parameters:
    ///   - database: FoundationDBデータベース
    ///   - rootSubspace: ルートSubspace（例: "app", "myproject"）
    ///   - metaData: RecordMetaData
    ///   - statisticsManager: StatisticsManager（オプション）
    public init(
        database: any DatabaseProtocol,
        rootSubspace: Subspace,
        metaData: RecordMetaData,
        statisticsManager: (any StatisticsManagerProtocol)? = nil
    ) {
        self.database = database
        self.rootSubspace = rootSubspace
        self.metaData = metaData
        self.statisticsManager = statisticsManager
        self.storeCacheLock = Mutex([:])
    }

    // MARK: - RecordStore Management

    /// アカウントとコレクション専用のRecordStoreを取得
    ///
    /// このメソッドは、指定されたアカウントIDとコレクション名に対応する
    /// RecordStore<Record>を返します。初回呼び出し時にRecordStoreを作成し、
    /// 2回目以降はキャッシュから返します。
    ///
    /// **Subspace構造**:
    /// ```
    /// /rootSubspace/accounts/<accountID>/<collection>/
    /// ```
    ///
    /// **例**:
    /// ```swift
    /// // rootSubspace = "app"
    /// // accountID = "acct-001"
    /// // collection = "users"
    /// // → /app/accounts/acct-001/users/
    ///
    /// let userStore: RecordStore<User> = try await partitionManager.recordStore(
    ///     for: "acct-001",
    ///     collection: "users"
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - accountID: アカウントID
    ///   - collection: コレクション名（例: "users", "orders"）
    /// - Returns: RecordStore<Record>
    /// - Throws: RecordLayerError
    public func recordStore<Record: Recordable>(
        for accountID: String,
        collection: String
    ) async throws -> RecordStore<Record> {
        // cacheKeyに型名を含めることで、同じコレクションで異なる型を要求した場合の上書きを防ぐ
        let cacheKey = "\(accountID).\(collection).\(Record.recordTypeName)"

        // 1. Cache check (inside lock - fast path)
        let cached: RecordStore<Record>? = storeCacheLock.withLock { cache in
            cache[cacheKey] as? RecordStore<Record>
        }

        if let cached = cached {
            return cached
        }

        // 2. I/O operations (outside lock - high throughput)
        // Subspace構造: /rootSubspace/accounts/<accountID>/<collection>/
        let accountSubspace = rootSubspace
            .subspace(Tuple(["accounts"]))
            .subspace(Tuple([accountID]))
            .subspace(Tuple([collection]))

        // RecordStoreの作成
        // メトリクスとロギングを自動設定
        // Note: metricsRecorderのcomponentは固定値にして高カーディナリティを回避
        // アカウント/コレクション情報はloggerのmetadataで記録
        let store = RecordStore<Record>(
            database: database,
            subspace: accountSubspace,
            metaData: metaData,
            statisticsManager: statisticsManager ?? NullStatisticsManager(),
            metricsRecorder: SwiftMetricsRecorder(component: "partition_manager"),
            logger: Logger(label: "com.fdb.recordlayer.partition", metadata: [
                "accountID": "\(accountID)",
                "collection": "\(collection)"
            ])
        )

        // 3. Cache update (inside lock - fast)
        storeCacheLock.withLock { cache in
            cache[cacheKey] = store
        }

        return store
    }

    /// アカウントのすべてのデータを削除
    ///
    /// このメソッドは、指定されたアカウントIDに関連するすべてのデータを削除します。
    /// - キャッシュをクリア
    /// - Subspace全体をクリア（レコードとインデックスの両方）
    ///
    /// **警告**: この操作は元に戻せません。
    ///
    /// - Parameter accountID: 削除するアカウントID
    /// - Throws: RecordLayerError
    public func deleteAccount(_ accountID: String) async throws {
        // 1. Clear cache (inside lock)
        storeCacheLock.withLock { cache in
            // Remove all stores for this account (all collections and types)
            // Cache key format: "accountID.collection.recordTypeName"
            let keysToRemove = cache.keys.filter { $0.hasPrefix("\(accountID).") }
            for key in keysToRemove {
                cache.removeValue(forKey: key)
            }
        }

        // 2. Clear data (outside lock - I/O operation)
        let accountSubspace = rootSubspace
            .subspace(Tuple(["accounts"]))
            .subspace(Tuple([accountID]))

        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let tr = context.getTransaction()

        // Clear entire account subspace (records + indexes)
        let range = accountSubspace.range()
        tr.clearRange(beginKey: range.begin, endKey: range.end)

        try await context.commit()
    }

    /// キャッシュをクリア
    ///
    /// すべてのRecordStoreキャッシュをクリアします。
    /// メモリ使用量を削減したい場合や、テスト時に使用します。
    public func clearCache() {
        storeCacheLock.withLock { cache in
            cache.removeAll()
        }
    }

    /// キャッシュサイズを取得
    ///
    /// - Returns: キャッシュされているRecordStoreの数
    public func cacheSize() -> Int {
        return storeCacheLock.withLock { cache in
            cache.count
        }
    }
}

// MARK: - Performance Notes

/*
 ## パフォーマンス設計

 ### final class + Mutex vs Actor

 この実装では actor ではなく final class + Mutex を使用しています。
 理由は以下の通りです：

 1. **Actor の制約**:
    - すべてのメソッド呼び出しがシリアライズされる
    - I/O 操作中もロックが保持される
    - スループットが低下（~8.3 batch/sec）

 2. **Mutex の利点**:
    - ロックスコープを最小化できる
    - I/O 操作はロック外で実行
    - 並列性が高い（~22.2 batch/sec, ~3倍）

 3. **実装パターン**:
    ```swift
    // ✅ Good: I/O outside lock
    let cached = storeCacheLock.withLock { cache[key] }
    if cached != nil { return cached }

    let store = createStore()  // I/O outside lock

    storeCacheLock.withLock { cache[key] = store }

    // ❌ Bad: I/O inside lock
    await storeCacheLock.withLock {
        if cache[key] != nil { return cache[key] }
        cache[key] = await createStore()  // I/O blocks other threads
    }
    ```

 ### DirectoryLayer統合（将来の拡張）

 現在はSubspaceベースの実装ですが、将来的にDirectoryLayerを統合可能です：

 ```swift
 // DirectoryLayer使用例（将来）
 let directoryLayer = DirectoryLayer()
 let accountDir = try await directoryLayer.createOrOpen(
     db,
     path: ["app", "accounts", accountID]
 )
 let collectionSubspace = accountDir.subspace(Tuple([collection]))
 ```

 DirectoryLayerのメリット：
 - 短いプレフィックス（間接参照）
 - ディレクトリ移動が効率的
 - メタデータ管理が容易

 参考: CLAUDE.md - Directory Layer
 */
