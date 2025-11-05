import Foundation
import FoundationDB
import Logging

/// Record store for managing multiple record types
///
/// RecordStore は複数のレコード型を管理できます。
/// Recordableプロトコルに準拠した型を登録し、型安全なAPIで操作できます。
///
/// **使用例**:
/// ```swift
/// // RecordMetaDataに型を登録
/// let metaData = RecordMetaData()
/// try metaData.registerRecordType(User.self)
/// try metaData.registerRecordType(Order.self)
///
/// // RecordStoreを初期化
/// let store = RecordStore(
///     database: database,
///     subspace: subspace,
///     metaData: metaData
/// )
///
/// // 型安全な保存
/// try await store.save(user)
/// try await store.save(order)
///
/// // 型安全な取得
/// if let user = try await store.fetch(User.self, by: 1) {
///     print(user.name)
/// }
/// ```
public final class RecordStore: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    public let subspace: Subspace
    public let metaData: RecordMetaData
    private let logger: Logger

    /// Statistics manager for cost-based query optimization
    private let statisticsManager: any StatisticsManagerProtocol

    // Subspaces
    internal let recordSubspace: Subspace
    internal let indexSubspace: Subspace

    // MARK: - Initialization

    /// Initialize RecordStore with injected StatisticsManager
    ///
    /// - Parameters:
    ///   - database: The FDB database
    ///   - subspace: The subspace for this record store
    ///   - metaData: Record metadata with registered types
    ///   - statisticsManager: Statistics manager for cost-based optimization
    ///   - logger: Optional logger
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        statisticsManager: any StatisticsManagerProtocol,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.store")
        self.statisticsManager = statisticsManager

        // Initialize subspaces
        self.recordSubspace = subspace.subspace(Tuple("R"))  // Records
        self.indexSubspace = subspace.subspace(Tuple("I"))    // Indexes
    }

    // MARK: - Statistics Support

    /// Create RecordStore with real StatisticsManager for cost-based optimization
    ///
    /// This is the recommended way to create a RecordStore for production use.
    /// It automatically initializes a StatisticsManager for cost-based query optimization.
    ///
    /// **Example**:
    /// ```swift
    /// // Create StatisticsManager first
    /// let statsManager = StatisticsManager(
    ///     database: database,
    ///     subspace: subspace.subspace(Tuple("stats"))
    /// )
    ///
    /// // Create RecordStore with statistics support
    /// let store = RecordStore(
    ///     database: database,
    ///     subspace: subspace,
    ///     metaData: metaData,
    ///     statisticsManager: statsManager
    /// )
    /// ```
    ///
    /// - Note: For testing or environments where statistics are not needed,
    ///         you can pass `NullStatisticsManager()` instead.

    // MARK: - Save

    /// レコードを保存（型安全）
    ///
    /// - Parameter record: 保存するレコード
    /// - Throws: RecordLayerError if save fails
    public func save<T: Recordable>(_ record: T) async throws {
        let recordAccess = GenericRecordAccess<T>()
        let bytes = try recordAccess.serialize(record)
        let primaryKey = recordAccess.extractPrimaryKey(from: record)

        // FDBに保存
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        // レコードタイプごとのサブスペース: /R/<TypeName>/<PrimaryKey>
        let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
        let key = typeSubspace.subspace(primaryKey).pack(Tuple())

        let tr = context.getTransaction()

        // Load old record if it exists (for index updates)
        let oldRecord: T?
        if let existingBytes = try await tr.getValue(for: key, snapshot: false) {
            oldRecord = try recordAccess.deserialize(existingBytes)
        } else {
            oldRecord = nil
        }

        // Save the record
        tr.setValue(bytes, for: key)

        // Update indexes
        let indexManager = IndexManager(metaData: metaData, subspace: indexSubspace)
        try await indexManager.updateIndexes(
            for: record,
            primaryKey: primaryKey,
            oldRecord: oldRecord,
            context: context,
            recordSubspace: recordSubspace
        )

        try await context.commit()
    }

    // MARK: - Fetch

    /// プライマリキーでレコードを取得
    ///
    /// - Parameters:
    ///   - type: レコード型
    ///   - primaryKey: プライマリキー値
    /// - Returns: レコード（存在しない場合は nil）
    /// - Throws: RecordLayerError if fetch fails
    public func fetch<T: Recordable>(
        _ type: T.Type,
        by primaryKey: any TupleElement
    ) async throws -> T? {
        let recordAccess = GenericRecordAccess<T>()

        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
        let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())

        let tr = context.getTransaction()
        guard let bytes = try await tr.getValue(for: key, snapshot: true) else {
            return nil
        }

        return try recordAccess.deserialize(bytes)
    }

    // MARK: - Query

    /// クエリビルダーを作成
    ///
    /// - Parameter type: レコード型
    /// - Returns: クエリビルダー
    public func query<T: Recordable>(_ type: T.Type) -> QueryBuilder<T> {
        return QueryBuilder(
            store: self,
            recordType: type,
            metaData: metaData,
            database: database,
            subspace: subspace,
            statisticsManager: statisticsManager
        )
    }

    // MARK: - Delete

    /// レコードを削除
    ///
    /// - Parameters:
    ///   - type: レコード型
    ///   - primaryKey: プライマリキー値
    /// - Throws: RecordLayerError if delete fails
    public func delete<T: Recordable>(
        _ type: T.Type,
        by primaryKey: any TupleElement
    ) async throws {
        let recordAccess = GenericRecordAccess<T>()

        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        // Load the record before deletion (needed for index updates)
        let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
        let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())

        let tr = context.getTransaction()
        let oldRecord: T?
        if let existingBytes = try await tr.getValue(for: key, snapshot: false) {
            oldRecord = try recordAccess.deserialize(existingBytes)
        } else {
            // Record doesn't exist, nothing to delete
            return
        }

        guard let record = oldRecord else {
            return
        }

        // Delete the record
        tr.clear(key: key)

        // Delete index entries
        let indexManager = IndexManager(metaData: metaData, subspace: indexSubspace)
        try await indexManager.deleteIndexes(
            oldRecord: record,
            primaryKey: Tuple([primaryKey]),
            context: context,
            recordSubspace: recordSubspace
        )

        try await context.commit()
    }

    // MARK: - Transaction

    /// トランザクション内で操作を実行
    ///
    /// - Parameter block: トランザクション内で実行するブロック
    /// - Returns: ブロックの戻り値
    /// - Throws: ブロックがスローしたエラー
    public func transaction<T>(
        _ block: (RecordTransaction) async throws -> T
    ) async throws -> T {
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let recordTransaction = RecordTransaction(
            store: self,
            context: context
        )

        let result = try await block(recordTransaction)
        try await context.commit()

        return result
    }
}

// MARK: - RecordTransaction

/// トランザクション内で使用するRecordStoreのラッパー
///
/// トランザクション内でレコード操作を行うために使用します。
public struct RecordTransaction {
    private let store: RecordStore
    internal let context: RecordContext

    internal init(store: RecordStore, context: RecordContext) {
        self.store = store
        self.context = context
    }

    /// レコードを保存
    public func save<T: Recordable>(_ record: T) async throws {
        let recordAccess = GenericRecordAccess<T>()
        let bytes = try recordAccess.serialize(record)
        let primaryKey = recordAccess.extractPrimaryKey(from: record)

        let typeSubspace = store.recordSubspace.subspace(Tuple([T.recordTypeName]))
        let key = typeSubspace.subspace(primaryKey).pack(Tuple())

        let tr = context.getTransaction()
        tr.setValue(bytes, for: key)

        // TODO: IndexManager integration
    }

    /// レコードを取得
    public func fetch<T: Recordable>(
        _ type: T.Type,
        by primaryKey: any TupleElement
    ) async throws -> T? {
        let recordAccess = GenericRecordAccess<T>()

        let typeSubspace = store.recordSubspace.subspace(Tuple([T.recordTypeName]))
        let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())

        let tr = context.getTransaction()
        guard let bytes = try await tr.getValue(for: key, snapshot: false) else {
            return nil
        }

        return try recordAccess.deserialize(bytes)
    }

    /// レコードを削除
    public func delete<T: Recordable>(
        _ type: T.Type,
        by primaryKey: any TupleElement
    ) async throws {
        let typeSubspace = store.recordSubspace.subspace(Tuple([T.recordTypeName]))
        let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())

        let tr = context.getTransaction()
        tr.clear(key: key)

        // TODO: IndexManager integration
    }
}
