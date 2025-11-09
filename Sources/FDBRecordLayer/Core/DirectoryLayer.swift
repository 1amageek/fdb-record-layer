import Foundation

/// FoundationDB Directory Layer の layer パラメータを表す型
///
/// Directory Layer は、各ディレクトリにオプションで "layer" メタデータを付与できます。
/// これは、ディレクトリの用途やフォーマットバージョンを識別するために使用されます。
///
/// **標準 Layer**:
/// ```swift
/// let layer: DirectoryLayer = .partition
/// let layer2: DirectoryLayer = .recordStore
/// let layer3: DirectoryLayer = .luceneIndex
/// ```
///
/// **バージョン付き Layer**:
/// ```swift
/// let layer = DirectoryLayer.recordStoreVersion(2)  // "fdb_record_layer_v2"
/// let layer2 = DirectoryLayer.versioned("my_format", version: 3)  // "my_format_v3"
/// ```
///
/// **カスタム Layer**:
/// ```swift
/// let customLayer: DirectoryLayer = "my_custom_format_v2"
/// ```
public struct DirectoryLayer: Sendable, Hashable, ExpressibleByStringLiteral {

    /// layer の生バイト値
    public let rawValue: Data

    // MARK: - Initialization

    /// 文字列から DirectoryLayer を作成
    ///
    /// - Parameter string: Layer 名（UTF-8 文字列）
    public init(_ string: String) {
        self.rawValue = Data(string.utf8)
    }

    /// バイトデータから DirectoryLayer を作成
    ///
    /// - Parameter rawValue: Layer の生バイト値
    public init(rawValue: Data) {
        self.rawValue = rawValue
    }

    /// String literal から初期化（ExpressibleByStringLiteral）
    ///
    /// - Parameter value: Layer 名
    public init(stringLiteral value: String) {
        self.init(value)
    }

    // MARK: - Standard Layers

    /// FDB 標準の Partition layer
    ///
    /// Partition は、すべてのサブディレクトリが共通プレフィックスを共有する特殊なディレクトリです。
    /// マルチテナントアーキテクチャに最適で、テナント全体を単一の Range 削除で高速削除できます。
    public static let partition = DirectoryLayer("partition")

    /// Record Layer v1 のデフォルト layer
    ///
    /// RecordStore で使用される標準の layer です。
    public static let recordStore = DirectoryLayer("fdb_record_layer")

    /// Lucene インデックス用 layer
    ///
    /// 全文検索インデックスの格納に使用されます。
    public static let luceneIndex = DirectoryLayer("lucene_index")

    /// 時系列データ用 layer
    ///
    /// タイムスタンプベースのデータストレージに使用されます。
    public static let timeSeries = DirectoryLayer("time_series")

    /// Vector インデックス用 layer
    ///
    /// ベクトル検索インデックスの格納に使用されます。
    public static let vectorIndex = DirectoryLayer("vector_index")

    // MARK: - Versioned Layers

    /// バージョン付き Record Store layer
    ///
    /// - Parameter version: フォーマットバージョン
    /// - Returns: "fdb_record_layer_v{version}" という layer
    ///
    /// **使用例**:
    /// ```swift
    /// let layer = DirectoryLayer.recordStoreVersion(2)  // "fdb_record_layer_v2"
    /// ```
    public static func recordStoreVersion(_ version: Int) -> DirectoryLayer {
        return DirectoryLayer("fdb_record_layer_v\(version)")
    }

    /// カスタムバージョン付き layer
    ///
    /// - Parameters:
    ///   - name: Layer 名
    ///   - version: バージョン番号
    /// - Returns: "{name}_v{version}" という layer
    ///
    /// **使用例**:
    /// ```swift
    /// let layer = DirectoryLayer.versioned("my_format", version: 3)  // "my_format_v3"
    /// ```
    public static func versioned(_ name: String, version: Int) -> DirectoryLayer {
        return DirectoryLayer("\(name)_v\(version)")
    }

    // MARK: - Conversion

    /// layer を文字列として取得
    ///
    /// - Returns: UTF-8 文字列（変換に失敗した場合は nil）
    public var stringValue: String? {
        return String(data: rawValue, encoding: .utf8)
    }

    /// layer をバイト配列として取得
    ///
    /// - Returns: バイト配列
    public var bytes: [UInt8] {
        return Array(rawValue)
    }
}

// MARK: - CustomStringConvertible

extension DirectoryLayer: CustomStringConvertible {
    public var description: String {
        return stringValue ?? "<binary data: \(rawValue.count) bytes>"
    }
}

// MARK: - CustomDebugStringConvertible

extension DirectoryLayer: CustomDebugStringConvertible {
    public var debugDescription: String {
        if let str = stringValue {
            return "DirectoryLayer(\"\(str)\")"
        } else {
            return "DirectoryLayer(rawValue: \(rawValue.map { String(format: "%02x", $0) }.joined(separator: " ")))"
        }
    }
}
