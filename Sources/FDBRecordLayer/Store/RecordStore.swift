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
    ///   - metaData: Record metadata with registered types
    ///   - statisticsManager: Statistics manager for cost-based optimization
    ///   - logger: Optional logger
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        metaData: RecordMetaData,
        statisticsManager: any StatisticsManagerProtocol,
        metricsRecorder: any MetricsRecorder = NullMetricsRecorder(),
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.metaData = metaData
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
        let start = DispatchTime.now()

        do {
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

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordSave(duration: duration)

            // Structured logging with record-type details
            logger.trace("Record saved", metadata: [
                "recordType": "\(T.recordTypeName)",
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
                "recordType": "\(T.recordTypeName)",
                "operation": "save",
                "error": "\(error)"
            ])

            throw error
        }
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
        let start = DispatchTime.now()

        do {
            let recordAccess = GenericRecordAccess<T>()

            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
            let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())

            let tr = context.getTransaction()
            guard let bytes = try await tr.getValue(for: key, snapshot: true) else {
                // Record success metrics even for nil result
                let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                metricsRecorder.recordFetch(duration: duration)

                // Structured logging
                logger.trace("Record fetch (not found)", metadata: [
                    "recordType": "\(T.recordTypeName)",
                    "duration_ns": "\(duration)",
                    "operation": "fetch",
                    "found": "false"
                ])
                return nil
            }

            let result = try recordAccess.deserialize(bytes)

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordFetch(duration: duration)

            // Structured logging
            logger.trace("Record fetched", metadata: [
                "recordType": "\(T.recordTypeName)",
                "duration_ns": "\(duration)",
                "operation": "fetch",
                "found": "true"
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
                "recordType": "\(T.recordTypeName)",
                "operation": "fetch",
                "error": "\(error)"
            ])

            throw error
        }
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
        let start = DispatchTime.now()

        do {
            let recordAccess = GenericRecordAccess<T>()

            let transaction = try database.createTransaction()
            let context = RecordContext(transaction: transaction)
            defer { context.cancel() }

            let typeSubspace = recordSubspace.subspace(Tuple([T.recordTypeName]))
            let key = typeSubspace.subspace(Tuple([primaryKey])).pack(Tuple())

            let tr = context.getTransaction()

            // Load the record before deletion (needed for index updates)
            guard let existingBytes = try await tr.getValue(for: key, snapshot: false) else {
                // Record doesn't exist, nothing to delete
                // Record success metrics even for no-op
                let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                metricsRecorder.recordDelete(duration: duration)

                // Structured logging
                logger.trace("Record delete (not found)", metadata: [
                    "recordType": "\(T.recordTypeName)",
                    "duration_ns": "\(duration)",
                    "operation": "delete",
                    "found": "false"
                ])
                return
            }

            // Deserialize the record
            let record = try recordAccess.deserialize(existingBytes)

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

            // Record success metrics
            let duration = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            metricsRecorder.recordDelete(duration: duration)

            // Structured logging
            logger.trace("Record deleted", metadata: [
                "recordType": "\(T.recordTypeName)",
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
                "recordType": "\(T.recordTypeName)",
                "operation": "delete",
                "error": "\(error)"
            ])

            throw error
        }
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

            results[groupKeyString] = aggregateValue as? F.Result
        }

        return results
    }
}
