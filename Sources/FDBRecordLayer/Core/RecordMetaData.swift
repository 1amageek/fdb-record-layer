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
/// // RecordStore で使用（統計マネージャーと共に）
/// let statisticsManager = StatisticsManager(database: db, subspace: statsSubspace)
/// let store = RecordStore(
///     database: db,
///     subspace: subspace,
///     metaData: metaData,
///     statisticsManager: statisticsManager
/// )
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

    /// Former indexes (removed indexes, keyed by name)
    /// Used for schema evolution validation
    private let _formerIndexes: SendableBox<[String: FormerIndex]>

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

    /// Thread-safe access to former indexes
    public var formerIndexes: [String: FormerIndex] {
        return _formerIndexes.withLock { $0 }
    }

    // MARK: - Initialization

    internal init(
        version: Int,
        recordTypes: [String: RecordType],
        indexes: [String: Index],
        formerIndexes: [String: FormerIndex] = [:]
    ) {
        self.version = version
        self._recordTypes = SendableBox(recordTypes)
        self._indexes = SendableBox(indexes)
        self._formerIndexes = SendableBox(formerIndexes)
        self._recordableRegistrations = SendableBox([:])
    }

    /// 空のRecordMetaDataを初期化
    ///
    /// マルチタイプサポートのために使用します。
    public init(version: Int = 1) {
        self.version = version
        self._recordTypes = SendableBox([:])
        self._indexes = SendableBox([:])
        self._formerIndexes = SendableBox([:])
        self._recordableRegistrations = SendableBox([:])
    }

    /// Initialize RecordMetaData with arrays (Swift-style API)
    ///
    /// - Parameters:
    ///   - version: Schema version number
    ///   - recordTypes: Array of record types
    ///   - indexes: Array of indexes
    ///   - formerIndexes: Array of former indexes (optional)
    ///   - unionDescriptor: Protocol buffer union descriptor (optional, for compatibility)
    /// - Throws: RecordLayerError if there are duplicate names
    public init(
        version: Int,
        recordTypes: [RecordType],
        indexes: [Index],
        formerIndexes: [FormerIndex] = [],
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

        // Validate former index names are unique
        let formerIndexNames = formerIndexes.map { $0.name }
        let uniqueFormerIndexNames = Set(formerIndexNames)
        guard formerIndexNames.count == uniqueFormerIndexNames.count else {
            throw RecordLayerError.internalError("Duplicate former index names")
        }

        self.version = version
        self._recordTypes = SendableBox(Dictionary(uniqueKeysWithValues: recordTypes.map { ($0.name, $0) }))
        self._indexes = SendableBox(Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) }))
        self._formerIndexes = SendableBox(Dictionary(uniqueKeysWithValues: formerIndexes.map { ($0.name, $0) }))
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

    /// Get record types indexed by a specific index
    ///
    /// This is the inverse of `getIndexesForRecordType()`. Used by OnlineIndexScrubber
    /// to determine which record types need to be scanned for a given index.
    ///
    /// - Parameter indexName: Name of the index
    /// - Returns: Array of record type names that are indexed
    public func getRecordTypesForIndex(_ indexName: String) -> [String] {
        guard let index = _indexes.withLock({ $0[indexName] }) else {
            return []
        }

        // If index has explicit record types, return them
        if let recordTypes = index.recordTypes, !recordTypes.isEmpty {
            return Array(recordTypes)
        }

        // Universal index: return all record types
        return _recordTypes.withLock { Array($0.keys) }
    }

    /// Calculate primary key field count for a record type
    ///
    /// This is used by OnlineIndexScrubber to extract primary keys from index keys.
    /// The primary key length is determined by counting the KeyExpression components.
    ///
    /// - Parameter recordTypeName: Name of the record type
    /// - Returns: Number of primary key fields
    /// - Throws: RecordLayerError.recordTypeNotFound if record type doesn't exist
    public func getPrimaryKeyFieldCount(_ recordTypeName: String) throws -> Int {
        let recordType = try getRecordType(recordTypeName)
        return countKeyExpressionFields(recordType.primaryKey)
    }

    /// Count the number of fields in a KeyExpression
    private func countKeyExpressionFields(_ expression: KeyExpression) -> Int {
        switch expression {
        case is FieldKeyExpression:
            return 1
        case let concat as ConcatenateKeyExpression:
            return concat.children.reduce(0) { $0 + countKeyExpressionFields($1) }
        case is EmptyKeyExpression:
            return 0
        case let nest as NestExpression:
            return countKeyExpressionFields(nest.child)
        default:
            // For unknown types, assume 1 field
            return 1
        }
    }

    // MARK: - Former Index Management

    /// Get a former index by name
    /// - Parameter name: The former index name
    /// - Returns: The former index, or nil if not found
    public func getFormerIndex(_ name: String) -> FormerIndex? {
        return _formerIndexes.withLock { $0[name] }
    }

    /// Check if a name is used by a former index
    /// - Parameter name: The name to check
    /// - Returns: True if the name is a former index
    public func hasFormerIndex(_ name: String) -> Bool {
        return _formerIndexes.withLock { $0[name] != nil }
    }

    /// Add a former index
    ///
    /// This is typically used during schema evolution when removing an index.
    /// The former index serves as a marker to prevent name reuse.
    ///
    /// - Parameter formerIndex: The former index to add
    /// - Throws: RecordLayerError if a former index with the same name already exists
    public func addFormerIndex(_ formerIndex: FormerIndex) throws {
        try _formerIndexes.withLock { formerIndexes in
            guard formerIndexes[formerIndex.name] == nil else {
                throw RecordLayerError.internalError("Former index '\(formerIndex.name)' already exists")
            }
            formerIndexes[formerIndex.name] = formerIndex
        }
    }

    /// Remove an index and add it as a former index
    ///
    /// This is the typical pattern for removing an index during schema evolution:
    /// 1. Remove from active indexes
    /// 2. Add to former indexes
    ///
    /// **Thread Safety**: This method is thread-safe but performs two separate lock
    /// acquisitions. In production, prefer using RecordMetaDataBuilder to create
    /// a new immutable instance with the desired state.
    ///
    /// - Parameters:
    ///   - indexName: The name of the index to remove
    ///   - addedVersion: The schema version at which the index was originally added
    ///   - removedVersion: The schema version at which it's being removed
    /// - Throws: RecordLayerError if the index doesn't exist or FormerIndex already exists
    public func removeIndexAsFormer(
        indexName: String,
        addedVersion: Int,
        removedVersion: Int
    ) throws {
        // Get the index (validates existence)
        let index = try getIndex(indexName)

        // Create former index
        let formerIndex = FormerIndex.from(
            index: index,
            addedVersion: addedVersion,
            removedVersion: removedVersion
        )

        // Perform operations in order to minimize window of inconsistency
        // 1. First, add FormerIndex (this validates no conflict)
        try _formerIndexes.withLock { formerIndexes in
            guard formerIndexes[formerIndex.name] == nil else {
                throw RecordLayerError.internalError(
                    "FormerIndex '\(formerIndex.name)' already exists"
                )
            }
            formerIndexes[formerIndex.name] = formerIndex
        }

        // 2. Then remove from active indexes
        // If this fails, we have FormerIndex without removal, which is safe
        // (validation will catch it)
        _indexes.withLock { indexes in
            indexes.removeValue(forKey: indexName)
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
    private var formerIndexes: [FormerIndex] = []

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

    /// Add a former index
    /// - Parameter formerIndex: The former index to add
    /// - Returns: Self for chaining
    public func addFormerIndex(_ formerIndex: FormerIndex) -> Self {
        formerIndexes.append(formerIndex)
        return self
    }

    /// Build the RecordMetaData
    /// - Returns: The constructed metadata
    /// - Throws: RecordLayerError if validation fails
    public func build() throws -> RecordMetaData {
        return try RecordMetaData(
            version: version,
            recordTypes: recordTypes,
            indexes: indexes,
            formerIndexes: formerIndexes
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
    /// metaData.registerRecordType(User.self)
    /// metaData.registerRecordType(Order.self)
    /// ```
    ///
    /// - Parameter type: 登録するRecordable型
    /// - Note: Idempotent - if the type is already registered, this is a no-op
    public func registerRecordType<T: Recordable>(_ type: T.Type) {
        let typeName = T.recordTypeName

        // Idempotent registration
        _recordTypes.withLock { recordTypes in
            // Already registered → skip
            guard recordTypes[typeName] == nil else {
                return
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

/// カーディナリティ
public enum Cardinality: Sendable {
    case oneToOne
    case oneToMany
    case manyToMany
}
