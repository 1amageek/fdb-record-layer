import Foundation
import FoundationDB

/// 型安全なクエリビルダー
///
/// QueryBuilderは、Recordable型に対する型安全なクエリAPIを提供します。
/// KeyPathを使用してフィールドを指定し、型チェックされたフィルタ条件を構築できます。
///
/// **使用例**:
/// ```swift
/// // 単純な等価比較
/// let users = try await store.query(User.self)
///     .where(\.email, .equals, "alice@example.com")
///     .execute()
///
/// // 複数条件
/// let tokyoUsers = try await store.query(User.self)
///     .where(\.country, .equals, "Japan")
///     .where(\.city, .equals, "Tokyo")
///     .limit(10)
///     .execute()
/// ```
public final class QueryBuilder<T: Recordable> {
    private let store: RecordStore
    private let recordType: T.Type
    private let metaData: RecordMetaData
    private let database: any DatabaseProtocol
    private let subspace: Subspace
    private var filters: [any TypedQueryComponent<T>] = []
    private var limitValue: Int?

    internal init(
        store: RecordStore,
        recordType: T.Type,
        metaData: RecordMetaData,
        database: any DatabaseProtocol,
        subspace: Subspace
    ) {
        self.store = store
        self.recordType = recordType
        self.metaData = metaData
        self.database = database
        self.subspace = subspace
    }

    // MARK: - Query Construction

    /// フィルタを追加
    ///
    /// - Parameters:
    ///   - keyPath: フィールドへのKeyPath
    ///   - comparison: 比較演算子
    ///   - value: 比較値
    /// - Returns: Self（メソッドチェーン用）
    public func `where`<Value: TupleElement>(
        _ keyPath: KeyPath<T, Value>,
        _ comparison: TypedFieldQueryComponent<T>.Comparison,
        _ value: Value
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        let filter = TypedFieldQueryComponent<T>(
            fieldName: fieldName,
            comparison: comparison,
            value: value
        )
        filters.append(filter)
        return self
    }

    /// リミットを設定
    ///
    /// - Parameter limit: 最大取得件数
    /// - Returns: Self（メソッドチェーン用）
    public func limit(_ limit: Int) -> Self {
        self.limitValue = limit
        return self
    }

    // MARK: - Execution

    /// クエリを実行
    ///
    /// - Returns: レコードの配列
    /// - Throws: RecordLayerError if execution fails
    public func execute() async throws -> [T] {
        // TypedRecordQuery を構築
        let filter: (any TypedQueryComponent<T>)? = filters.isEmpty ? nil : (filters.count == 1 ? filters[0] : TypedAndQueryComponent<T>(children: filters))
        let query = TypedRecordQuery<T>(
            filter: filter,
            limit: limitValue
        )

        // QueryPlanner を使用して最適な実行プランを作成
        // Note: QueryBuilder uses heuristic-based planning without statistics
        let planner = TypedRecordQueryPlanner<T>(
            metaData: metaData,
            recordTypeName: T.recordTypeName
        )
        let plan = try await planner.plan(query: query)

        // プランを実行
        let transaction = try database.createTransaction()
        let context = RecordContext(transaction: transaction)
        defer { context.cancel() }

        let recordAccess = GenericRecordAccess<T>()
        let cursor = try await plan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: true
        )

        // 結果を収集
        var results: [T] = []
        for try await record in cursor {
            results.append(record)
            if let limit = limitValue, results.count >= limit {
                break
            }
        }

        return results
    }

    /// 最初のレコードを取得
    ///
    /// - Returns: 最初のレコード、または nil
    /// - Throws: RecordLayerError if execution fails
    public func first() async throws -> T? {
        let originalLimit = limitValue
        limitValue = 1
        let results = try await execute()
        limitValue = originalLimit
        return results.first
    }

    /// レコード数をカウント
    ///
    /// **注意**: 現在の実装ではすべてのレコードを取得してカウントします。
    /// 将来的にはCOUNTインデックスを使用した最適化を実装予定です。
    ///
    /// - Returns: レコード数
    /// - Throws: RecordLayerError if execution fails
    public func count() async throws -> Int {
        let results = try await execute()
        return results.count
    }
}

// MARK: - Operator Overloads

// TODO: Future macro-based implementation
// extension QueryBuilder {
//     /// WHERE field == value のショートカット
//     ///
//     /// **使用例**:
//     /// ```swift
//     /// let users = try await store.query(User.self)
//     ///     .where(\.email == "alice@example.com")
//     ///     .execute()
//     /// ```
//     public func `where`<Value: TupleElement & Equatable>(
//         _ condition: @autoclosure () -> Bool
//     ) -> Self {
//         // Note: この実装は演算子オーバーロードでは動作しません
//         // 将来的にマクロで実装予定
//         return self
//     }
// }
