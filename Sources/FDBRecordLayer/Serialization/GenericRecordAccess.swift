import Foundation
import FoundationDB

/// Recordableプロトコルを利用した汎用RecordAccess実装
///
/// `Recordable` プロトコルに準拠している型であれば、このクラスを使用して
/// 自動的にシリアライズ/デシリアライズが可能になります。
///
/// **使用例**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///     var email: String
///     var name: String
/// }
///
/// // Recordableに準拠していれば自動的に使用可能
/// let recordAccess = GenericRecordAccess<User>()
///
/// // シリアライズ
/// let data = try recordAccess.serialize(user)
///
/// // デシリアライズ
/// let user = try recordAccess.deserialize(data)
/// ```
///
/// **設計の意図**:
/// - `Recordable` プロトコルの実装を再利用
/// - マクロが `Recordable` を実装すれば、自動的に `RecordAccess` として使用可能
/// - ボイラープレートコードの削減
public struct GenericRecordAccess<Record: Recordable>: RecordAccess {
    /// デフォルトイニシャライザ
    ///
    /// `Recordable` プロトコルに準拠している型であれば、
    /// 特別な設定なしで使用できます。
    public init() {}

    // MARK: - RecordAccess Implementation

    /// Get the record type name
    public func recordName(for record: Record) -> String {
        return Record.recordName
    }

    /// Extract a single field value
    public func extractField(
        from record: Record,
        fieldName: String
    ) throws -> [any TupleElement] {
        return record.extractField(fieldName)
    }

    /// Serialize a record to bytes
    public func serialize(_ record: Record) throws -> FDB.Bytes {
        let data = try record.toProtobuf()
        return FDB.Bytes(data)
    }

    /// Deserialize bytes to a record
    public func deserialize(_ bytes: FDB.Bytes) throws -> Record {
        let data = Data(bytes)
        return try Record.fromProtobuf(data)
    }

    // MARK: - Additional Helpers (not in RecordAccess protocol)

    /// プライマリキーを抽出
    ///
    /// RecordAccessプロトコルには含まれませんが、RecordStoreで使用されます。
    ///
    /// - Parameter record: レコード
    /// - Returns: プライマリキーのTuple
    public func extractPrimaryKey(from record: Record) -> Tuple {
        return record.extractPrimaryKey()
    }
}

// MARK: - Convenience Methods

extension GenericRecordAccess {
    /// レコードタイプ名を取得（静的メソッド）
    ///
    /// インスタンスを作成せずにレコードタイプ名を取得できます。
    ///
    /// - Returns: レコードタイプ名
    public static var recordName: String {
        return Record.recordName
    }

    /// プライマリキーフィールドのリストを取得
    ///
    /// - Returns: プライマリキーフィールド名のリスト
    public static var primaryKeyFields: [String] {
        return Record.primaryKeyFields
    }

    /// すべてのフィールド名のリストを取得
    ///
    /// - Returns: フィールド名のリスト
    public static var allFields: [String] {
        return Record.allFields
    }
}
