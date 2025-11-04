import Foundation

/// Record metadata defining schema and indexes
///
/// RecordMetaData is the central schema definition for a record store.
/// It contains all record types, indexes, and schema version information.
///
/// **不変性とスレッドセーフ**:
/// RecordMetaData は基本的に不変（immutable）であるべきです。
/// 一度構築されたら、レコード型やインデックスは変更されません。
/// これにより、複数のスレッドから安全にアクセスできます。
///
/// 動的な型登録が必要な場合は、RecordMetaDataBuilder を使用して
/// 新しいインスタンスを作成してください。
///
/// **推奨される使用方法**:
/// ```swift
/// // ビルダーで構築（不変）
/// let metaData = try RecordMetaDataBuilder()
///     .addRecordType(userType)
///     .addRecordType(orderType)
///     .addIndex(emailIndex)
///     .build()
///
/// // RecordStore で使用
/// let store = RecordStore(database: db, subspace: subspace, metaData: metaData)
/// ```
///
/// **マイグレーション時の型登録**:
/// 開発中やマイグレーション時に動的に型を追加する必要がある場合のみ、
/// registerRecordType() を使用してください。本番環境では事前定義を推奨します。
public final class RecordMetaData: Sendable {
    // MARK: - Properties

    /// Version number for schema evolution
    public let version: Int

    /// All record types in this metadata (keyed by name)
    /// 内部的には mutable だが、外部からは immutable として扱う
    private let _recordTypes: SendableBox<[String: RecordType]>

    /// All indexes (keyed by name)
    /// 内部的には mutable だが、外部からは immutable として扱う
    private let _indexes: SendableBox<[String: Index]>

    /// Recordable型の登録情報（内部使用）
    private let _recordableRegistrations: SendableBox<[String: any RecordableTypeRegistration]>

    /// Thread-safe access to recordTypes
    public var recordTypes: [String: RecordType] {
        return _recordTypes.withLock { $0 }
    }

    /// Thread-safe access to indexes
    public var indexes: [String: Index] {
        return _indexes.withLock { $0 }
    }

    // MARK: - Initialization

    internal init(
        version: Int,
        recordTypes: [String: RecordType],
        indexes: [String: Index]
    ) {
        self.version = version
        self._recordTypes = SendableBox(recordTypes)
        self._indexes = SendableBox(indexes)
        self._recordableRegistrations = SendableBox([:])
    }

    /// 空のRecordMetaDataを初期化
    ///
    /// マルチタイプサポートのために使用します。
    public init(version: Int = 1) {
        self.version = version
        self._recordTypes = SendableBox([:])
        self._indexes = SendableBox([:])
        self._recordableRegistrations = SendableBox([:])
    }

    /// Initialize RecordMetaData with arrays (Swift-style API)
    ///
    /// - Parameters:
    ///   - version: Schema version number
    ///   - recordTypes: Array of record types
    ///   - indexes: Array of indexes
    ///   - unionDescriptor: Protocol buffer union descriptor (optional, for compatibility)
    /// - Throws: RecordLayerError if there are duplicate names
    public init(
        version: Int,
        recordTypes: [RecordType],
        indexes: [Index],
        unionDescriptor: Any? = nil  // For API compatibility, not used
    ) throws {
        // Validate record types are unique
        let typeNames = recordTypes.map { $0.name }
        let uniqueTypeNames = Set(typeNames)
        guard typeNames.count == uniqueTypeNames.count else {
            throw RecordLayerError.internalError("Duplicate record type names")
        }

        // Validate index names are unique
        let indexNames = indexes.map { $0.name }
        let uniqueIndexNames = Set(indexNames)
        guard indexNames.count == uniqueIndexNames.count else {
            throw RecordLayerError.internalError("Duplicate index names")
        }

        self.version = version
        self._recordTypes = SendableBox(Dictionary(uniqueKeysWithValues: recordTypes.map { ($0.name, $0) }))
        self._indexes = SendableBox(Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) }))
        self._recordableRegistrations = SendableBox([:])
    }

    // MARK: - Public Methods

    /// Get a record type by name
    /// - Parameter name: The record type name
    /// - Returns: The record type
    /// - Throws: RecordLayerError.recordTypeNotFound if not found
    public func getRecordType(_ name: String) throws -> RecordType {
        let recordType = _recordTypes.withLock { $0[name] }
        guard let recordType = recordType else {
            throw RecordLayerError.recordTypeNotFound(name)
        }
        return recordType
    }

    /// Get an index by name
    /// - Parameter name: The index name
    /// - Returns: The index
    /// - Throws: RecordLayerError.indexNotFound if not found
    public func getIndex(_ name: String) throws -> Index {
        let index = _indexes.withLock { $0[name] }
        guard let index = index else {
            throw RecordLayerError.indexNotFound(name)
        }
        return index
    }

    /// Get all indexes that apply to a specific record type
    /// - Parameter recordTypeName: The record type name
    /// - Returns: Array of indexes
    public func getIndexesForRecordType(_ recordTypeName: String) -> [Index] {
        return _indexes.withLock { indexes in
            indexes.values.filter { index in
                // Universal indexes (recordTypes == nil) apply to all types
                guard let recordTypes = index.recordTypes else {
                    return true
                }
                // Otherwise check if this record type is in the index's set
                return recordTypes.contains(recordTypeName)
            }
        }
    }
}

// MARK: - RecordMetaData Builder

/// Builder for constructing RecordMetaData
///
/// Provides a fluent API for building metadata with validation.
public class RecordMetaDataBuilder {
    private var version: Int = 1
    private var recordTypes: [RecordType] = []
    private var indexes: [Index] = []

    public init() {}

    /// Set the schema version
    /// - Parameter version: The version number
    /// - Returns: Self for chaining
    public func setVersion(_ version: Int) -> Self {
        self.version = version
        return self
    }

    /// Add a record type
    /// - Parameter recordType: The record type to add
    /// - Returns: Self for chaining
    public func addRecordType(_ recordType: RecordType) -> Self {
        recordTypes.append(recordType)
        return self
    }

    /// Add an index
    /// - Parameter index: The index to add
    /// - Returns: Self for chaining
    public func addIndex(_ index: Index) -> Self {
        indexes.append(index)
        return self
    }

    /// Build the RecordMetaData
    /// - Returns: The constructed metadata
    /// - Throws: RecordLayerError if validation fails
    public func build() throws -> RecordMetaData {
        return try RecordMetaData(
            version: version,
            recordTypes: recordTypes,
            indexes: indexes
        )
    }
}

// MARK: - Recordable Type Registration

/// Recordable型の登録情報を保持するプロトコル（内部使用）
internal protocol RecordableTypeRegistration: Sendable {
    var recordType: RecordType { get }
}

/// Recordable型の登録情報の実装
internal struct RecordableTypeRegistrationImpl<T: Recordable>: RecordableTypeRegistration {
    let type: T.Type

    var recordType: RecordType {
        RecordType(
            name: T.recordTypeName,
            primaryKey: ConcatenateKeyExpression(
                children: T.primaryKeyFields.map { FieldKeyExpression(fieldName: $0) }
            )
        )
    }
}

// MARK: - RecordMetaData Multi-Type Support

extension RecordMetaData {
    /// Recordable型を登録
    ///
    /// マクロで`@Recordable`を付けた型を、RecordMetaDataに登録します。
    /// 登録することで、RecordStoreでその型を扱えるようになります。
    ///
    /// **使用例**:
    /// ```swift
    /// let metaData = RecordMetaData()
    /// try metaData.registerRecordType(User.self)
    /// try metaData.registerRecordType(Order.self)
    /// ```
    ///
    /// - Parameter type: 登録するRecordable型
    /// - Throws: RecordLayerError if the type is already registered
    public func registerRecordType<T: Recordable>(_ type: T.Type) throws {
        let typeName = T.recordTypeName

        // Already registered check
        try _recordTypes.withLock { recordTypes in
            guard recordTypes[typeName] == nil else {
                throw RecordLayerError.internalError("Record type '\(typeName)' is already registered")
            }

            // Create registration
            let registration = RecordableTypeRegistrationImpl(type: type)

            // Add to recordableRegistrations
            _recordableRegistrations.withLock { registrations in
                registrations[typeName] = registration
            }

            // Add to recordTypes
            recordTypes[typeName] = registration.recordType
        }

        // マクロが生成したインデックス登録メソッドを呼び出す（将来の拡張）
        // T.registerIndexes?(in: self)
    }

    /// インデックスを追加
    ///
    /// マクロによって生成されたインデックスを登録します。
    ///
    /// - Parameter index: 追加するインデックス
    /// - Throws: RecordLayerError if the index is already registered
    public func addIndex(_ index: Index) throws {
        try _indexes.withLock { indexes in
            guard indexes[index.name] == nil else {
                throw RecordLayerError.internalError("Index '\(index.name)' is already registered")
            }
            indexes[index.name] = index
        }
    }

    /// リレーションシップを追加（将来の拡張）
    ///
    /// - Parameter relationship: 追加するリレーションシップ
    public func addRelationship(_ relationship: Relationship) {
        // Future implementation
    }
}

/// リレーションシップ定義（将来の拡張）
public struct Relationship: Sendable {
    public let name: String
    public let sourceType: String
    public let sourceField: String
    public let targetType: String
    public let targetField: String
    public let deleteRule: DeleteRule
    public let cardinality: Cardinality

    public init(
        name: String,
        sourceType: String,
        sourceField: String,
        targetType: String,
        targetField: String,
        deleteRule: DeleteRule,
        cardinality: Cardinality
    ) {
        self.name = name
        self.sourceType = sourceType
        self.sourceField = sourceField
        self.targetType = targetType
        self.targetField = targetField
        self.deleteRule = deleteRule
        self.cardinality = cardinality
    }
}

/// 削除ルール
public enum DeleteRule: Sendable {
    case cascade      // 関連レコードも削除
    case nullify      // 外部キーを nil に設定
    case deny         // 関連レコードが存在する場合削除を拒否
    case noAction     // 何もしない（整合性チェックなし）
}

/// カーディナリティ
public enum Cardinality: Sendable {
    case oneToOne
    case oneToMany
    case manyToMany
}
