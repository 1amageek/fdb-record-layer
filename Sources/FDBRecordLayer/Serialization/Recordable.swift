import Foundation
import FoundationDB

/// レコードとして永続化可能な型を表すプロトコル
///
/// すべてのレコード型は、このプロトコルに準拠する必要があります。
/// 通常、`@Recordable` マクロがこのプロトコルへの準拠を自動生成します。
///
/// **使用例**:
/// ```swift
/// @Recordable
/// struct User {
///     @PrimaryKey var userID: Int64
///     var email: String
///     var name: String
/// }
/// ```
///
/// **マクロ展開後**:
/// ```swift
/// extension User: Recordable {
///     static var recordTypeName: String { "User" }
///     static var primaryKeyFields: [String] { ["userID"] }
///     static var allFields: [String] { ["userID", "email", "name"] }
///     // ... 他のメソッド実装
/// }
/// ```
public protocol Recordable: Sendable {
    /// レコードタイプ名（メタデータでの識別子）
    ///
    /// 各レコード型を一意に識別するための名前です。
    /// 通常は型名と同じですが、必要に応じて変更できます。
    ///
    /// **例**: `"User"`, `"Order"`, `"Product"`
    static var recordTypeName: String { get }

    /// プライマリキーフィールドのリスト
    ///
    /// レコードのプライマリキーを構成するフィールド名のリストです。
    /// 単一フィールドまたは複数フィールド（複合主キー）を指定できます。
    ///
    /// **例**:
    /// - 単一主キー: `["userID"]`
    /// - 複合主キー: `["tenantID", "userID"]`
    static var primaryKeyFields: [String] { get }

    /// すべてのフィールド名のリスト（@Transient を除く）
    ///
    /// 永続化されるすべてのフィールドの名前です。
    /// `@Transient` でマークされたフィールドは含まれません。
    ///
    /// **例**: `["userID", "email", "name", "createdAt"]`
    static var allFields: [String] { get }

    /// フィールド名からProtobufフィールド番号へのマッピング
    ///
    /// Protobufシリアライズ時に使用されるフィールド番号を返します。
    /// `#FieldOrder` マクロで明示的に指定されている場合はその順序、
    /// そうでない場合は宣言順に自動採番されます。
    ///
    /// - Parameter fieldName: フィールド名
    /// - Returns: フィールド番号（1から開始）、存在しない場合は nil
    static func fieldNumber(for fieldName: String) -> Int?

    /// Protobuf形式にシリアライズ
    ///
    /// レコードをProtobuf形式のバイト列に変換します。
    /// この実装は通常マクロによって自動生成されます。
    ///
    /// - Returns: Protobuf形式のバイト列
    /// - Throws: シリアライズエラー
    func toProtobuf() throws -> Data

    /// Protobuf形式からデシリアライズ
    ///
    /// Protobuf形式のバイト列からレコードを復元します。
    /// この実装は通常マクロによって自動生成されます。
    ///
    /// - Parameter data: Protobuf形式のバイト列
    /// - Returns: 復元されたレコード
    /// - Throws: デシリアライズエラー
    static func fromProtobuf(_ data: Data) throws -> Self

    /// 指定されたフィールドの値を抽出（インデックス用）
    ///
    /// インデックス構築時に使用されます。
    /// フィールド名に対応する値を `TupleElement` の配列として返します。
    ///
    /// **例**:
    /// ```swift
    /// user.extractField("email")  // -> ["alice@example.com"]
    /// user.extractField("tags")   // -> ["swift", "ios", "development"]
    /// ```
    ///
    /// - Parameter fieldName: フィールド名
    /// - Returns: フィールド値の配列（配列型のフィールドの場合は複数要素）
    func extractField(_ fieldName: String) -> [any TupleElement]

    /// プライマリキーをTupleとして抽出
    ///
    /// レコードのプライマリキーを FoundationDB の Tuple 形式で返します。
    /// 単一主キーの場合は1要素、複合主キーの場合は複数要素のTupleになります。
    ///
    /// **例**:
    /// ```swift
    /// user.extractPrimaryKey()  // -> Tuple(123)
    /// order.extractPrimaryKey() // -> Tuple("tenant_a", 456)  // 複合主キー
    /// ```
    ///
    /// - Returns: プライマリキーのTuple
    func extractPrimaryKey() -> Tuple
}

// MARK: - Helper Extensions

extension Recordable {
    /// KeyPathからフィールド名を取得
    ///
    /// **注**: この実装はマクロによって型ごとにオーバーライドされます。
    /// デフォルト実装はコンパイルエラーを防ぐためのプレースホルダーです。
    ///
    /// - Parameter keyPath: フィールドへのKeyPath
    /// - Returns: フィールド名
    public static func fieldName<Value>(for keyPath: KeyPath<Self, Value>) -> String {
        // この実装はマクロによって置き換えられる
        // デフォルトではKeyPathの文字列表現から推測（制限あり）
        let description = "\(keyPath)"

        // KeyPathの文字列表現から最後の要素を取得
        // 例: "\MyApp.User.email" -> "email"
        if let lastComponent = description.split(separator: ".").last {
            return String(lastComponent)
        }

        return description
    }
}
