import Foundation
import FoundationDB
import Logging

/// Record store for managing a specific record type
///
/// RecordStore は単一のレコード型を管理します。
/// 型パラメータによって、コンパイル時に型安全性を保証します。
///
/// **基本的な使用例**:
/// ```swift
/// // Schemaを作成（型とインデックスを定義）
/// let schema = Schema([User.self])
///
/// // 型付きRecordStoreを初期化
/// let userStore = RecordStore<User>(
///     database: database,
///     subspace: subspace,
///     schema: schema,
///     statisticsManager: statisticsManager
/// )
///
/// // 型安全な保存（型パラメータ不要）
/// try await userStore.save(user)
///
/// // 型安全な取得（User.self不要）
/// if let user = try await userStore.fetch(by: 1) {
///     print(user.name)
/// }
///
/// // 型安全なクエリ（User.self不要）
/// let users = try await userStore.query()
///     .where(\.name == "Alice")
///     .execute()
/// ```
///
/// **複合主キーの使用例**:
///
/// 複合主キーは複数のフィールドの組み合わせで一意性を保証します。
/// 2つの方法でサポートされています：
///
/// 1. **Tuple型を使用する方法**:
/// ```swift
/// struct OrderItem: Recordable {
///     // 複合主キー: (orderID, itemID)
///     static var primaryKey: KeyPath<OrderItem, Tuple> = \.compositeKey
///
///     let orderID: String
///     let itemID: String
///     var quantity: Int
///
///     var compositeKey: Tuple {
///         Tuple(orderID, itemID)
///     }
/// }
///
/// // 保存
/// let item = OrderItem(orderID: "order-001", itemID: "item-456", quantity: 2)
/// try await store.save(item)
///
/// // 取得: Tupleを使用
/// let key = Tuple("order-001", "item-456")
/// if let item = try await store.fetch(by: key) {
///     print("Found: \(item.quantity)")
/// }
///
/// // 削除: Tupleを使用
/// try await store.delete(by: Tuple("order-001", "item-456"))
/// ```
///
/// 2. **可変長引数を使用する方法（推奨）**:
/// ```swift
/// // 取得: 可変長引数（より簡潔）
/// if let item = try await store.fetch(by: "order-001", "item-456") {
///     print("Found: \(item.quantity)")
/// }
///
/// // 削除: 可変長引数
/// try await store.delete(by: "order-001", "item-456")
///
/// // トランザクション内でも使用可能
/// try await store.transaction { transaction in
///     if let item = try await transaction.fetch(by: "order-001", "item-456") {
///         var updated = item
///         updated.quantity += 1
///         try await transaction.save(updated)
///     }
/// }
/// ```
///
/// **重要な注意事項**:
/// - 単一主キーと複合主キーで内部キー形式が統一されています
/// - `fetchInternal`/`deleteInternal`は自動的にキーを正規化します
/// - 可変長引数版は、単一キー・複合キーの両方に対応しています
public final class RecordStore<Record: Recordable>: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    public let subspace: Subspace
    public let schema: Schema
    private let logger: Logger

    /// Statistics manager for cost-based query optimization
    private let statisticsManager: any StatisticsManagerProtocol

    /// Metrics recorder for observability
    private let metricsRecorder: any MetricsRecorder

    // Subspaces
    internal let recordSubspace: Subspace
    internal let indexSubspace: Subspace

    // MARK: - Initialization

    /// Initialize RecordStore with injected StatisticsManager
    ///
    /// - Parameters:
    ///   - database: The FDB database
    ///   - subspace: The subspace for this record store
    ///   - schema: Schema with registered types and indexes
    ///   - statisticsManager: Statistics manager for cost-based optimization
    ///   - logger: Optional logger
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,
        statisticsManager: any StatisticsManagerProtocol,
        metricsRecorder: any MetricsRecorder = NullMetricsRecorder(),
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.schema = schema
        self.logger = logger ?? Logger(label: "com.fdb.recordlayer.store")
        self.statisticsManager = statisticsManager
        self.metricsRecorder = metricsRecorder

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
    ///     schema: schema,
    ///     statisticsManager: statsManager
    /// )
    /// ```
    ///
    /// - Note: For testing or environments where statistics are not needed,
    ///         you can pass `NullStatisticsManager()` instead.

    // MARK: - Internal Methods (shared by RecordStore and RecordTransaction)

    /// 内部保存ロジック（RecordStoreとRecordTransactionで共有）
    ///
    /// - Parameters:
    ///   - record: 保存するレコード
    ///   - context: トランザクションコンテキスト
    /// - Throws: RecordLayerError if save fails
    internal func saveInternal(_ record: Record, context: RecordContext) async throws {
        let recordAccess = GenericRecordAccess<Record>()
        let bytes = try recordAccess.serialize(record)
        let primaryKey = recordAccess.extractPrimaryKey(from: record)

        // Subspace制御: 常にレコードタイプ名を自動追加（Phase 2a-1）
        // TODO: Phase 2a-3で#Subspace対応を追加
        let effectiveSubspace = recordSubspace.subspace(Tuple([Record.recordName]))
        let key = effectiveSubspace.subspace(primaryKey).pack(Tuple())

        let tr = context.getTransaction()

        // Load old record if it exists (for index updates)
        let oldRecord: Record?
        if let existingBytes = try await tr.getValue(for: key, snapshot: false) {
            oldRecord = try recordAccess.deserialize(existingBytes)
        } else {
            oldRecord = nil
        }

        // Save the record
        tr.setValue(bytes, for: key)

        // Update indexes
        let indexManager = IndexManager(schema: schema, subspace: indexSubspace)
        try await indexManager.updateIndexes(
            for: record,
            primaryKey: primaryKey,
            oldRecord: oldRecord,
            context: context,
            recordSubspace: recordSubspace
        )
    }

    /// 内部取得ロジック（RecordStoreとRecordTransactionで共有）
    ///
    /// - Parameters:
    ///   - primaryKey: プライマリキー値
    ///   - context: トランザクションコンテキスト
    /// - Returns: レコード（存在しない場合は nil）
    /// - Throws: RecordLayerError if fetch fails
    internal func fetchInternal(by primaryKey: any TupleElement, context: RecordContext) async throws -> Record? {
        let recordAccess = GenericRecordAccess<Record>()

        // Subspace制御: 常にレコードタイプ名を自動追加（Phase 2a-1）
        let effectiveSubspace = recordSubspace.subspace(Tuple([Record.recordName]))

        // 複合主キー対応: primaryKeyがTupleの場合はそのまま、単一値の場合はTupleに変換
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.subspace(keyTuple).pack(Tuple())

        let tr = context.getTransaction()
        guard let bytes = try await tr.getValue(for: key, snapshot: false) else {
            return nil
        }

        return try recordAccess.deserialize(bytes)
    }

    /// 内部削除ロジック（RecordStoreとRecordTransactionで共有）
    ///
    /// - Parameters:
    ///   - primaryKey: プライマリキー値
    ///   - context: トランザクションコンテキスト
    /// - Throws: RecordLayerError if delete fails
    internal func deleteInternal(by primaryKey: any TupleElement, context: RecordContext) async throws {
        let recordAccess = GenericRecordAccess<Record>()

        // Subspace制御: 常にレコードタイプ名を自動追加（Phase 2a-1）
        let effectiveSubspace = recordSubspace.subspace(Tuple([Record.recordName]))

        // 複合主キー対応: primaryKeyがTupleの場合はそのまま、単一値の場合はTupleに変換
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.subspace(keyTuple).pack(Tuple())

        let tr = context.getTransaction()

        // Load the record before deletion (needed for index updates)
        guard let existingBytes = try await tr.getValue(for: key, snapshot: false) else {
            // Record doesn't exist, nothing to delete
            return
        }

        // Deserialize the record
        let record = try recordAccess.deserialize(existingBytes)

        // Delete the record
        tr.clear(key: key)

        // Delete index entries
        let indexManager = IndexManager(schema: schema, subspace: indexSubspace)
        try await indexManager.deleteIndexes(
            oldRecord: record,
            primaryKey: keyTuple,
            context: context,
            recordSubspace: recordSubspace
        )
    }

    // MARK: - Save

    /// レコードを保存（型安全）
    ///
    /// - Parameter record: 保存するレコード
    /// - Throws: RecordLayerError if save fails
    public func save(_ record: Record) async throws {
        let start = DispatchTime.now()

        do {
            // トランザクション作成
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            // 共通ロジックを使用
            try await saveInternal(record, context: context)

            try await context.commit()

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordSave(duration: duration)

            // Structured logging with record-type details
            logger.trace("Record saved", metadata: [
                "recordType": "\(Record.recordName)",
                "duration_ns": "\(duration)",
                "operation": "save"
            ])
        } catch {
            // Record error metrics
            metricsRecorder.recordError(
                operation: "save",
                errorType: String(reflecting: Swift.type(of: error))
            )

            // Structured logging for error details
            logger.error("Failed to save record", metadata: [
                "recordType": "\(Record.recordName)",
                "operation": "save",
                "error": "\(error)"
            ])

            throw error
        }
    }

    // MARK: - Fetch

    /// プライマリキーでレコードを取得
    ///
    /// - Parameter primaryKey: プライマリキー値
    /// - Returns: レコード（存在しない場合は nil）
    /// - Throws: RecordLayerError if fetch fails
    public func record(
        for primaryKey: any TupleElement
    ) async throws -> Record? {
        let start = DispatchTime.now()

        do {
            // トランザクション作成
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            // 共通ロジックを使用
            let result = try await fetchInternal(by: primaryKey, context: context)

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordFetch(duration: duration)

            // Structured logging
            logger.trace("Record fetch completed", metadata: [
                "recordType": "\(Record.recordName)",
                "duration_ns": "\(duration)",
                "operation": "fetch",
                "found": "\(result != nil)"
            ])

            return result
        } catch {
            // Record error metrics
            metricsRecorder.recordError(
                operation: "fetch",
                errorType: String(reflecting: Swift.type(of: error))
            )

            // Structured logging for error details
            logger.error("Failed to fetch record", metadata: [
                "recordType": "\(Record.recordName)",
                "operation": "fetch",
                "error": "\(error)"
            ])

            throw error
        }
    }

    /// 複合主キーでレコードを取得（可変長引数版）
    ///
    /// **使用例**:
    /// ```swift
    /// // 単一キー
    /// let user = try await store.fetch(by: 123)
    ///
    /// // 複合キー（可変長引数）
    /// let orderItem = try await store.record(forCompositeKey: "order-001", "item-456")
    /// ```
    ///
    /// - Parameter keys: プライマリキーの要素（可変長）
    /// - Returns: レコード（存在しない場合は nil）
    /// - Throws: RecordLayerError if fetch fails
    public func record(
        forCompositeKey keys: any TupleElement...
    ) async throws -> Record? {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "record(forCompositeKey:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        return try await record(for: primaryKey)
    }

    // MARK: - Query

    /// クエリビルダーを作成（型パラメータ不要）
    ///
    /// - Returns: クエリビルダー
    public func query() -> QueryBuilder<Record> {
        return QueryBuilder(
            store: self,
            recordType: Record.self,
            schema: schema,
            database: database,
            subspace: subspace,
            statisticsManager: statisticsManager
        )
    }

    // MARK: - Delete

    /// レコードを削除
    ///
    /// - Parameter primaryKey: プライマリキー値
    /// - Throws: RecordLayerError if delete fails
    public func delete(
        by primaryKey: any TupleElement
    ) async throws {
        let start = DispatchTime.now()

        do {
            // トランザクション作成
            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            // 共通ロジックを使用
            try await deleteInternal(by: primaryKey, context: context)

            try await context.commit()

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordDelete(duration: duration)

            // Structured logging
            logger.trace("Record delete completed", metadata: [
                "recordType": "\(Record.recordName)",
                "duration_ns": "\(duration)",
                "operation": "delete"
            ])
        } catch {
            // Record error metrics
            metricsRecorder.recordError(
                operation: "delete",
                errorType: String(reflecting: Swift.type(of: error))
            )

            // Structured logging for error details
            logger.error("Failed to delete record", metadata: [
                "recordType": "\(Record.recordName)",
                "operation": "delete",
                "error": "\(error)"
            ])

            throw error
        }
    }

    /// 複合主キーでレコードを削除（可変長引数版）
    ///
    /// **使用例**:
    /// ```swift
    /// // 単一キー
    /// try await store.delete(by: 123)
    ///
    /// // 複合キー（可変長引数）
    /// try await store.delete(by: "order-001", "item-456")
    /// ```
    ///
    /// - Parameter keys: プライマリキーの要素（可変長）
    /// - Throws: RecordLayerError if delete fails
    public func delete(
        by keys: any TupleElement...
    ) async throws {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "delete(by:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        try await delete(by: primaryKey)
    }

    // MARK: - Transaction

    /// トランザクション内で操作を実行
    ///
    /// - Parameter block: トランザクション内で実行するブロック
    /// - Returns: ブロックの戻り値
    /// - Throws: ブロックがスローしたエラー
    public func transaction<T>(
        _ block: (RecordTransaction<Record>) async throws -> T
    ) async throws -> T {
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let recordTransaction = RecordTransaction<Record>(
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
public struct RecordTransaction<Record: Recordable> {
    private let store: RecordStore<Record>
    internal let context: RecordContext

    internal init(store: RecordStore<Record>, context: RecordContext) {
        self.store = store
        self.context = context
    }

    /// レコードを保存
    public func save(_ record: Record) async throws {
        // 共通ロジックを使用
        try await store.saveInternal(record, context: context)
    }

    /// レコードを取得
    public func record(
        for primaryKey: any TupleElement
    ) async throws -> Record? {
        // 共通ロジックを使用
        return try await store.fetchInternal(by: primaryKey, context: context)
    }

    /// 複合主キーでレコードを取得（可変長引数版）
    ///
    /// **使用例**:
    /// ```swift
    /// try await store.transaction { transaction in
    ///     // 単一キー
    ///     let user = try await transaction.record(for: 123)
    ///
    ///     // 複合キー（可変長引数）
    ///     let orderItem = try await transaction.record(forCompositeKey: "order-001", "item-456")
    /// }
    /// ```
    ///
    /// - Parameter keys: プライマリキーの要素（可変長）
    /// - Returns: レコード（存在しない場合は nil）
    /// - Throws: RecordLayerError if fetch fails
    public func record(
        forCompositeKey keys: any TupleElement...
    ) async throws -> Record? {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "record(forCompositeKey:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        return try await record(for: primaryKey)
    }

    /// レコードを削除
    public func delete(
        by primaryKey: any TupleElement
    ) async throws {
        // 共通ロジックを使用
        try await store.deleteInternal(by: primaryKey, context: context)
    }

    /// 複合主キーでレコードを削除（可変長引数版）
    ///
    /// **使用例**:
    /// ```swift
    /// try await store.transaction { transaction in
    ///     // 単一キー
    ///     try await transaction.delete(by: 123)
    ///
    ///     // 複合キー（可変長引数）
    ///     try await transaction.delete(by: "order-001", "item-456")
    /// }
    /// ```
    ///
    /// - Parameter keys: プライマリキーの要素（可変長）
    /// - Throws: RecordLayerError if delete fails
    public func delete(
        by keys: any TupleElement...
    ) async throws {
        // Validate arguments
        guard !keys.isEmpty else {
            throw RecordLayerError.invalidArgument(
                "delete(by:) requires at least one key element"
            )
        }

        // Convert variadic arguments to Tuple
        let primaryKey: any TupleElement = keys.count == 1 ? keys[0] : Tuple(keys)
        try await delete(by: primaryKey)
    }
}

// MARK: - Aggregate Functions

extension RecordStore {
    /// Evaluate an aggregate function on an index
    ///
    /// This method queries an aggregate index (COUNT, SUM, MIN, MAX) and returns
    /// the aggregated value for a specific grouping.
    ///
    /// **Example:**
    /// ```swift
    /// // Count users by city
    /// let count = try await store.evaluateAggregate(
    ///     .count(indexName: "user_count_by_city"),
    ///     groupBy: ["Tokyo"]
    /// )
    ///
    /// // Sum salaries by department
    /// let total = try await store.evaluateAggregate(
    ///     .sum(indexName: "salary_by_dept"),
    ///     groupBy: ["Engineering"]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - function: The aggregate function to evaluate
    ///   - groupBy: The grouping values (e.g., city name, department ID)
    /// - Returns: The aggregated result
    /// - Throws: RecordLayerError if index not found or evaluation fails
    public func evaluateAggregate<F: AggregateFunction>(
        _ function: F,
        groupBy: [any TupleElement]
    ) async throws -> F.Result {
        // Create context for this operation (will auto-close on deinit)
        let context = try RecordContext(database: database)

        // Get index subspace
        let indexSubspace = self.indexSubspace.subspace(Tuple([function.indexName]))

        // Get transaction
        let transaction = context.getTransaction()

        // Evaluate the function
        return try await function.evaluate(
            subspace: indexSubspace,
            groupBy: groupBy,
            transaction: transaction
        )
    }

    /// Evaluate an aggregate function with no grouping (全体の集約)
    ///
    /// For cases where you want the aggregate over all records without grouping.
    ///
    /// **Example:**
    /// ```swift
    /// // Total user count (all cities)
    /// let totalUsers = try await store.evaluateAggregate(
    ///     .count(indexName: "user_count")
    /// )
    /// ```
    ///
    /// - Parameter function: The aggregate function to evaluate
    /// - Returns: The aggregated result
    /// - Throws: RecordLayerError if index not found or evaluation fails
    public func evaluateAggregate<F: AggregateFunction>(
        _ function: F
    ) async throws -> F.Result {
        return try await evaluateAggregate(function, groupBy: [])
    }

    /// Evaluate an aggregate function with grouped results
    ///
    /// Returns a dictionary mapping each group to its aggregated value.
    ///
    /// **Example:**
    /// ```swift
    /// // Get count for all cities
    /// let cityCounts = try await store.evaluateAggregateGrouped(
    ///     .count(indexName: "user_count_by_city")
    /// )
    /// // Result: ["Tokyo": 1000, "NYC": 500, ...]
    /// ```
    ///
    /// - Parameter function: The aggregate function to evaluate
    /// - Returns: Dictionary mapping group keys to aggregated values
    /// - Throws: RecordLayerError if index not found or evaluation fails
    public func evaluateAggregateGrouped<F: AggregateFunction>(
        _ function: F
    ) async throws -> [String: F.Result] where F.Result == Int64 {
        // Create context for this operation (will auto-close on deinit)
        let context = try RecordContext(database: database)

        // Get index subspace
        let indexSubspace = self.indexSubspace.subspace(Tuple([function.indexName]))

        // Get transaction
        let transaction = context.getTransaction()

        // Scan all entries in the index
        let range = indexSubspace.range()
        let sequence = transaction.getRange(
            begin: range.begin,
            end: range.end,
            snapshot: true
        )

        var results: [String: F.Result] = [:]

        for try await (key, value) in sequence {
            // Extract group key from the index key
            let unpacked = try indexSubspace.unpack(key)

            // Build group key string (simplified: use string representation of tuple)
            // TODO: Improve this to properly handle multi-element tuples
            let groupKeyString = "\(unpacked)"

            // Decode aggregate value
            let aggregateValue = TupleHelpers.bytesToInt64(value)

            results[groupKeyString] = aggregateValue as F.Result
        }

        return results
    }
}
