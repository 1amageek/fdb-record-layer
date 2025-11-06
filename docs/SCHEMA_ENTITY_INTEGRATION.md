# Schema & Entity統合設計 (SwiftData準拠)

## 概要

SwiftDataの公式APIに準拠し、現在の3層構造（Schema → RecordMetadata → RecordType/Entity）を2層構造（Schema → Entity）に統合します。

## SwiftData公式構造（参考）

### Schema

```swift
class Schema: Sendable {
    let entities: [Entity]
    let entitiesByName: [String: Entity]

    init(_ entities: Entity..., version: Version)
    init(_ types: [any PersistentModel.Type], version: Version)
}
```

### Entity

```swift
final class Entity: Sendable, Hashable {
    // Identity
    let name: String

    // Properties
    let attributes: Set<Attribute>
    let attributesByName: [String: Attribute]
    let relationships: Set<Relationship>
    let relationshipsByName: [String: Relationship]

    var properties: [any SchemaProperty]
    var inheritedProperties: [any SchemaProperty]
    var inheritedPropertiesByName: [String: any SchemaProperty]
    var storedProperties: [any SchemaProperty]
    var storedPropertiesByName: [String: any SchemaProperty]

    // Constraints
    let uniquenessConstraints: [[String]]
    let indices: [[String]]

    // Inheritance
    let superentity: Entity?
    let superentityName: String?
    let subentities: Set<Entity>
}
```

### Attribute

```swift
class Attribute: SchemaProperty, Sendable, Hashable {
    let name: String  // via propertyName
    let defaultValue: Any?
    let options: [Option]
    let isTransformable: Bool
    let hashModifier: String?

    struct Option {
        static let unique: Option
        static let allowsCloudEncryption: Option
        static let preserveValueOnDeletion: Option
        static let spotlight: Option
        static let externalStorage: Option
    }
}
```

### Relationship

```swift
final class Relationship: SchemaProperty, Sendable, Hashable {
    let name: String  // via propertyName
    let destination: String
    let inverseName: String?
    let inverseKeyPath: AnyKeyPath?
    let deleteRule: DeleteRule
    let isToOneRelationship: Bool
    let minimumModelCount: Int?
    let maximumModelCount: Int?
    let hashModifier: String?

    enum DeleteRule {
        case noAction
        case nullify
        case cascade
        case deny
    }
}
```

### SchemaProperty Protocol

```swift
protocol SchemaProperty: Sendable {
    var propertyName: String { get }
}
```

## 現在の問題点

### 冗長な3層構造

```
Schema
├─ entities: [Entity]
├─ recordMetadata: RecordMetadata (internal)  ← 不要
│
RecordMetadata
├─ recordTypes: [String: RecordType]  ← RecordType ≈ Entity
├─ indexes: [String: Index]
├─ formerIndexes: [String: FormerIndex]
├─ recordableRegistrations: [String: RecordableTypeRegistration]  ← 不要
│
Entity
├─ recordType: RecordType (internal)  ← 重複
├─ indexObjects: [Index]
```

### SwiftDataとの相違点

1. **RecordMetadataという余分な層**
   - SwiftDataにはない中間層
   - Schemaが直接Entityを管理すべき

2. **RecordTypeとEntityの重複**
   - RecordType = プライマリキー情報のみ
   - Entity = RecordTypeのラッパー
   - 統合すべき

3. **インデックス管理の分散**
   - RecordMetadata: `indexes: [String: Index]`
   - Entity: `indexObjects: [Index]`
   - 両方で管理している

## 新しい設計: SwiftData準拠2層構造 + IndexManager

### 責務の分離

**Schema/Entity**: スキーマ定義のみ（宣言的）
- 「**何を**」定義するか: フィールド名、インデックス定義、制約
- Index実装オブジェクトは持たない

**IndexManager**: Index実装管理（実装）
- 「**どうやって**」実装するか: IndexオブジェクトとKeyExpressionの構築・管理
- Schema/Entityから定義を読み取って実装を生成

### アーキテクチャ

```
Schema (SwiftData互換 + FoundationDB拡張)
├─ version: Version
├─ entities: [Entity]
├─ entitiesByName: [String: Entity]
│
├─ [FoundationDB拡張 - スキーマ進化用]
├─ formerIndexes: [String: FormerIndex]  ← 削除されたインデックスの記録
│
Entity (SwiftData互換 + FoundationDB拡張)
├─ [SwiftData標準]
├─ name: String
├─ attributes: Set<Attribute>
├─ attributesByName: [String: Attribute]
├─ relationships: Set<Relationship>
├─ relationshipsByName: [String: Relationship]
├─ properties: [any SchemaProperty]
├─ storedProperties: [any SchemaProperty]
├─ storedPropertiesByName: [String: any SchemaProperty]
├─ uniquenessConstraints: [[String]]     ← インデックス定義
├─ indices: [[String]]                   ← インデックス定義
├─ superentity: Entity?
├─ subentities: Set<Entity>
│
├─ [FoundationDB拡張 - スキーマ定義のみ]
├─ primaryKeyFields: [String]            ← プライマリキー定義
│
IndexManager (Index実装管理 - 別コンポーネント)
├─ indexes: [String: Index]              ← Index実装オブジェクト
├─ buildIndexes(from: Entity) -> [Index] ← Entityからインデックス構築
├─ buildKeyExpression(fields: [String])  ← KeyExpression構築
```

### 削除するファイル

1. `Sources/FDBRecordLayer/Core/RecordMetadata.swift`
2. `Sources/FDBRecordLayer/Core/RecordType.swift`

### 削除する概念

- `RecordableTypeRegistration` プロトコル
- `RecordMetadata` 構造体
- `RecordType` 構造体

## 新しいAPI設計

### Schema

```swift
// Sources/FDBRecordLayer/Schema/Schema.swift

public final class Schema: Sendable {
    // MARK: - Version (SwiftData互換)

    public struct Version: Sendable, Hashable, Codable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var description: String {
            return "\(major).\(minor).\(patch)"
        }
    }

    // MARK: - Properties

    /// Schema version
    public let version: Version

    /// Encoding version (compatibility)
    public let encodingVersion: Version

    /// All entities (SwiftData互換)
    public let entities: [Entity]

    /// Access entities by name (SwiftData互換)
    public let entitiesByName: [String: Entity]

    /// [FoundationDB拡張] Former indexes (schema evolution)
    /// 削除されたインデックスの記録のみ（Index実装オブジェクトは持たない）
    public let formerIndexes: [String: FormerIndex]

    // MARK: - Initialization

    /// SwiftData-style initializer
    public init(
        _ types: [any Recordable.Type],
        version: Version = Version(1, 0, 0)
    ) {
        self.version = version
        self.encodingVersion = version

        // Build entities directly from Recordable types
        var entities: [Entity] = []
        var entitiesByName: [String: Entity] = [:]
        var globalIndexes: [String: Index] = [:]

        for type in types {
            // EntityをRecordableから直接構築（RecordTypeを経由しない）
            let entity = Entity(from: type)

            entities.append(entity)
            entitiesByName[entity.name] = entity

            // Entityのインデックスをグローバルレジストリに登録
            for index in entity.secondaryIndexes {
                globalIndexes[index.name] = index
            }
        }

        self.entities = entities
        self.entitiesByName = entitiesByName
        self.indexes = globalIndexes
        self.formerIndexes = [:]
    }

    /// SwiftData互換: VersionedSchemaから作成
    public convenience init(versionedSchema: any VersionedSchema.Type) {
        self.init(
            versionedSchema.models,
            version: versionedSchema.versionIdentifier
        )
    }

    // MARK: - Entity Access (SwiftData互換)

    /// Get entity for type
    public func entity<T: Recordable>(for type: T.Type) -> Entity? {
        return entitiesByName[T.recordTypeName]
    }

    /// Get entity by name
    public func entity(named name: String) -> Entity? {
        return entitiesByName[name]
    }

    // MARK: - Index Access (FoundationDB拡張)

    /// Get index by name
    public func getIndex(_ name: String) throws -> Index {
        guard let index = indexes[name] else {
            throw RecordLayerError.internalError("Index '\(name)' not found")
        }
        return index
    }

    /// Get all indexes for a specific entity
    public func getIndexes(for entityName: String) -> [Index] {
        guard let entity = entitiesByName[entityName] else {
            return []
        }
        return entity.secondaryIndexes
    }

    /// Get primary key field count for an entity
    public func getPrimaryKeyFieldCount(_ entityName: String) throws -> Int {
        guard let entity = entitiesByName[entityName] else {
            throw RecordLayerError.internalError("Entity '\(entityName)' not found")
        }
        return entity.primaryKeyFields.count
    }

    // MARK: - Schema Evolution (FoundationDB拡張)

    /// Get former index by name
    public func getFormerIndex(_ name: String) -> FormerIndex? {
        return formerIndexes[name]
    }

    /// Check if a former index exists
    public func hasFormerIndex(_ name: String) -> Bool {
        return formerIndexes[name] != nil
    }
}

// MARK: - SwiftData互換プロトコル準拠

extension Schema: Equatable {
    public static func == (lhs: Schema, rhs: Schema) -> Bool {
        return lhs.version == rhs.version &&
               lhs.entities == rhs.entities
    }
}

extension Schema: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        for name in entitiesByName.keys.sorted() {
            hasher.combine(name)
        }
    }
}

extension Schema: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "Schema(version: \(version), entities: \(entities.count))"
    }
}
```

### Entity

```swift
// Sources/FDBRecordLayer/Schema/Schema+Entity.swift

extension Schema {
    /// Entity - Blueprint for model class (SwiftData互換 + FoundationDB拡張)
    public final class Entity: Sendable, CustomDebugStringConvertible {

        // MARK: - Identity (SwiftData互換)

        /// Entity name (type name)
        public let name: String

        // MARK: - Properties (SwiftData互換)

        /// Attributes
        public let attributes: Set<Attribute>

        /// Access attributes by name
        public let attributesByName: [String: Attribute]

        /// Relationships
        public let relationships: Set<Relationship>

        /// Access relationships by name
        public let relationshipsByName: [String: Relationship]

        /// All properties (attributes + relationships)
        public var properties: [any SchemaProperty] {
            return Array(attributes) + Array(relationships)
        }

        /// Inherited properties (future implementation)
        public var inheritedProperties: [any SchemaProperty] {
            // Future: implement inheritance
            return []
        }

        /// Inherited properties by name (future implementation)
        public var inheritedPropertiesByName: [String: any SchemaProperty] {
            return [:]
        }

        /// Stored properties (excluding transient)
        public var storedProperties: [any SchemaProperty] {
            // Future: filter transient attributes
            return properties
        }

        /// Access stored properties by name
        public var storedPropertiesByName: [String: any SchemaProperty] {
            var result: [String: any SchemaProperty] = [:]
            for property in storedProperties {
                result[property.propertyName] = property
            }
            return result
        }

        // MARK: - Constraints (SwiftData互換)

        /// Uniqueness constraints (array of field names)
        public let uniquenessConstraints: [[String]]

        /// Indices (array of field names)
        public let indices: [[String]]

        // MARK: - Inheritance (SwiftData互換)

        /// Parent entity (inheritance)
        public let superentity: Entity?

        /// Parent entity name
        public let superentityName: String?

        /// Child entities (inheritance)
        public let subentities: Set<Entity>

        // MARK: - FoundationDB拡張

        /// Primary key fields (FoundationDB extension)
        public let primaryKeyFields: [String]

        /// Primary key expression (for index building)
        internal let primaryKeyExpression: KeyExpression

        /// Secondary indexes (FoundationDB extension)
        internal let secondaryIndexes: [Index]

        // MARK: - Initialization

        /// Initialize from Recordable type
        internal init(from type: any Recordable.Type) {
            self.name = type.recordTypeName
            self.primaryKeyFields = type.primaryKeyFields

            // Build primary key expression
            if primaryKeyFields.count == 1 {
                self.primaryKeyExpression = FieldKeyExpression(fieldName: primaryKeyFields[0])
            } else {
                let fields = primaryKeyFields.map { FieldKeyExpression(fieldName: $0) }
                self.primaryKeyExpression = ConcatenateKeyExpression(children: fields)
            }

            // Build attributes from Recordable.allFields
            let allFields = type.allFields
            var attributes: Set<Attribute> = []
            var attributesByName: [String: Attribute] = [:]

            for fieldName in allFields {
                let isPrimaryKey = primaryKeyFields.contains(fieldName)
                let attribute = Attribute(
                    name: fieldName,
                    isOptional: false,  // Future: detect from type reflection
                    isPrimaryKey: isPrimaryKey
                )
                attributes.insert(attribute)
                attributesByName[fieldName] = attribute
            }

            self.attributes = attributes
            self.attributesByName = attributesByName

            // Relationships (future implementation)
            self.relationships = []
            self.relationshipsByName = [:]

            // Secondary indexes (future: extract from @Index macro)
            // For now, no secondary indexes by default
            self.secondaryIndexes = []

            // Build indices and constraints from secondaryIndexes
            var indices: [[String]] = []
            var uniquenessConstraints: [[String]] = []

            for index in secondaryIndexes {
                let fieldNames = index.rootExpression.fieldNames()
                indices.append(fieldNames)

                if index.options.unique {
                    uniquenessConstraints.append(fieldNames)
                }
            }

            self.indices = indices
            self.uniquenessConstraints = uniquenessConstraints

            // Inheritance (future implementation)
            self.superentity = nil
            self.superentityName = nil
            self.subentities = []
        }

        /// Initialize with explicit indexes (for testing)
        internal init(
            from type: any Recordable.Type,
            indexes: [Index]
        ) {
            self.name = type.recordTypeName
            self.primaryKeyFields = type.primaryKeyFields

            // Build primary key expression
            if primaryKeyFields.count == 1 {
                self.primaryKeyExpression = FieldKeyExpression(fieldName: primaryKeyFields[0])
            } else {
                let fields = primaryKeyFields.map { FieldKeyExpression(fieldName: $0) }
                self.primaryKeyExpression = ConcatenateKeyExpression(children: fields)
            }

            // Build attributes
            let allFields = type.allFields
            var attributes: Set<Attribute> = []
            var attributesByName: [String: Attribute] = [:]

            for fieldName in allFields {
                let isPrimaryKey = primaryKeyFields.contains(fieldName)
                let attribute = Attribute(
                    name: fieldName,
                    isOptional: false,
                    isPrimaryKey: isPrimaryKey
                )
                attributes.insert(attribute)
                attributesByName[fieldName] = attribute
            }

            self.attributes = attributes
            self.attributesByName = attributesByName

            // Relationships
            self.relationships = []
            self.relationshipsByName = [:]

            // Secondary indexes (provided)
            self.secondaryIndexes = indexes

            // Build indices and constraints
            var indices: [[String]] = []
            var uniquenessConstraints: [[String]] = []

            for index in indexes {
                let fieldNames = index.rootExpression.fieldNames()
                indices.append(fieldNames)

                if index.options.unique {
                    uniquenessConstraints.append(fieldNames)
                }
            }

            self.indices = indices
            self.uniquenessConstraints = uniquenessConstraints

            // Inheritance
            self.superentity = nil
            self.superentityName = nil
            self.subentities = []
        }

        // MARK: - CustomDebugStringConvertible (SwiftData互換)

        public var debugDescription: String {
            return "Entity(name: \(name), primaryKey: \(primaryKeyFields), indices: \(indices.count))"
        }
    }
}

// MARK: - SwiftData互換プロトコル準拠

extension Schema.Entity: Equatable {
    public static func == (lhs: Schema.Entity, rhs: Schema.Entity) -> Bool {
        return lhs.name == rhs.name
    }
}

extension Schema.Entity: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
```

### Attribute & Relationship (既存コード維持)

`Schema+Entity.swift`に既に定義されている`Attribute`と`Relationship`はSwiftData互換なので、そのまま維持します。

## 影響を受けるコンポーネント

### 1. RecordConfiguration

```swift
// 変更なし - schemaを受け取るのみ
public struct RecordConfiguration: Sendable {
    public let schema: Schema
    // ...
}
```

### 2. RecordContainer

```swift
public final class RecordContainer: Sendable {
    public let schema: Schema  // 変更なし

    public func store<Record: Recordable>(
        for type: Record.Type,
        path: String
    ) -> RecordStore<Record> {
        let subspace = Subspace.fromPath(path)

        let store = RecordStore<Record>(
            database: database,
            subspace: subspace,
            schema: schema,  // metaData → schema (名前変更のみ)
            statisticsManager: statisticsManager ?? NullStatisticsManager(),
            metricsRecorder: metricsRecorder,
            logger: logger
        )

        return store
    }
}
```

### 3. RecordStore

```swift
public final class RecordStore<Record: Recordable>: Sendable {
    private let schema: Schema  // metaData → schema

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema,  // RecordMetadata → Schema
        statisticsManager: any StatisticsManagerProtocol,
        metricsRecorder: any MetricsRecorder,
        logger: Logger?
    ) {
        self.schema = schema
        // ...
    }

    // Entity取得
    private func getEntity() -> Schema.Entity? {
        return schema.entity(for: Record.self)
    }

    // プライマリキーフィールド数取得
    private func getPrimaryKeyFieldCount() throws -> Int {
        return try schema.getPrimaryKeyFieldCount(Record.recordTypeName)
    }
}
```

### 4. IndexManager

```swift
public actor IndexManager {
    private let schema: Schema  // metaData → schema

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema  // RecordMetadata → Schema
    ) {
        self.schema = schema
        // ...
    }

    // インデックス取得
    public func getIndexes(for entityName: String) -> [Index] {
        return schema.getIndexes(for: entityName)
    }

    public func getIndex(named name: String) throws -> Index {
        return try schema.getIndex(name)
    }
}
```

### 5. QueryPlanner

```swift
public struct TypedRecordQueryPlanner: Sendable {
    private let schema: Schema  // metaData → schema

    public init(
        schema: Schema,  // RecordMetadata → Schema
        recordTypeName: String,
        statisticsManager: any StatisticsManagerProtocol
    ) {
        self.schema = schema
        // ...
    }

    // Entity取得
    private func getEntity() throws -> Schema.Entity {
        guard let entity = schema.entity(named: recordTypeName) else {
            throw RecordLayerError.internalError("Entity '\(recordTypeName)' not found")
        }
        return entity
    }

    // インデックス取得
    private func getIndexes() -> [Index] {
        return schema.getIndexes(for: recordTypeName)
    }
}
```

### 6. StatisticsManager

```swift
public actor StatisticsManager: StatisticsManagerProtocol {
    private let schema: Schema  // metaData → schema

    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        schema: Schema  // RecordMetadata → Schema
    ) {
        self.schema = schema
        // ...
    }

    // エンティティ情報取得
    private func getEntity(named name: String) -> Schema.Entity? {
        return schema.entity(named: name)
    }
}
```

## 移行手順

### Phase 1: Schema拡張（既存機能の移動）

1. ✅ `Schema.swift`を拡張
   - `indexes: [String: Index]` プロパティ追加
   - `formerIndexes: [String: FormerIndex]` プロパティ追加
   - `getIndex()`, `getIndexes()`, `getPrimaryKeyFieldCount()` メソッド追加

2. ✅ `Schema+Entity.swift`を拡張
   - `primaryKeyFields: [String]` プロパティ追加
   - `primaryKeyExpression: KeyExpression` プロパティ追加
   - `secondaryIndexes: [Index]` プロパティ追加
   - `init(from:)` イニシャライザ追加

### Phase 2: 初期化ロジック変更

1. ✅ `Schema.init()`を更新
   - Entityを`Recordable.Type`から直接構築
   - RecordableTypeRegistration抽象化を削除
   - インデックスをグローバルレジストリに登録

### Phase 3: 参照更新（`metaData` → `schema`）

1. ✅ `RecordContainer.swift` - `metaData` → `schema`
2. ✅ `RecordStore.swift` - `metaData` → `schema`
3. ✅ `IndexManager.swift` - `metaData` → `schema`
4. ✅ `QueryPlanner.swift` - `metaData` → `schema`
5. ✅ `StatisticsManager.swift` - `metaData` → `schema`
6. ✅ `OnlineIndexer.swift` - `metaData` → `schema`
7. ✅ その他すべての`recordMetadata`/`metaData`参照

### Phase 4: クリーンアップ

1. ✅ `RecordMetadata.swift` 削除
2. ✅ `RecordType.swift` 削除
3. ✅ RecordableTypeRegistration関連コード削除
4. ✅ テスト更新
5. ✅ ビルド確認

## メリット

### 1. SwiftData準拠

- 公式APIと同じ構造
- 学習コストが低い
- 他のSwiftDataコードとの互換性

### 2. シンプルな構造

- 3層 → 2層に削減
- 冗長な抽象化を排除
- 理解しやすいコード

### 3. 明確な責任分離

- **Schema**: メタデータ管理 (SwiftData互換 + FoundationDB拡張)
- **Entity**: レコード型定義 (SwiftData互換 + FoundationDB拡張)

### 4. 直接アクセス

- `schema.entity(for: User.self)` → Entity直接アクセス
- `entity.primaryKeyExpression` → 余計な間接参照なし
- `schema.getIndex("index_name")` → グローバルレジストリから直接取得

## 互換性

### 後方互換性

この変更は内部実装の変更であり、以下のパブリックAPIには影響しません：

- `RecordContainer.init()`
- `RecordContainer.store()`
- `Schema.init()`
- `Schema.entity()`

### マイグレーション不要

既存のデータベースデータには影響しません（メタデータ構造のみの変更）。

## まとめ

RecordMetadataとRecordTypeを削除し、SwiftDataの公式構造に準拠することで：

✅ SwiftDataと同じAPI設計
✅ コードがシンプルになる
✅ 冗長性が排除される
✅ 保守性が向上する
✅ 学習コストが低い
✅ パフォーマンスは変わらない（むしろ間接参照が減る）

## 責務分離後のAPI設計

### 責務マトリックス

| コンポーネント | スキーマ定義 | Index実装 | KeyExpression構築 |
|--------------|------------|-----------|------------------|
| **Schema/Entity** | ✅ 所有 | ❌ 持たない | ❌ 持たない |
| **IndexManager** | ❌ 参照のみ | ✅ 構築・管理 | ✅ 動的構築 |
| **RecordStore** | ❌ 参照のみ | ❌ IndexManagerに委譲 | ✅ プライマリキーのみ動的構築 |

### Schema API

```swift
public final class Schema: Sendable {
    // SwiftData互換
    public let version: Version
    public let entities: [Entity]
    public let entitiesByName: [String: Entity]
    
    // FoundationDB拡張（スキーマ進化用のみ）
    public let formerIndexes: [String: FormerIndex]
    
    public init(_ types: [any Recordable.Type], version: Version = Version(1, 0, 0)) {
        // ✅ スキーマ定義のみ構築
        for type in types {
            let entity = Entity(from: type)  // indicesは[[String]]のみ
            // ...
        }
    }
    
    // Entity Access
    public func entity<T: Recordable>(for type: T.Type) -> Entity?
    public func entity(named name: String) -> Entity?
}
```

**削除**: `indexes: [String: Index]`, `getIndex()`, `getIndexes()`

### Entity API

```swift
extension Schema {
    public final class Entity: Sendable {
        // SwiftData互換
        public let indices: [[String]]                 // ✅ フィールド名のみ
        public let uniquenessConstraints: [[String]]  // ✅ フィールド名のみ
        
        // FoundationDB拡張
        public let primaryKeyFields: [String]  // ✅ フィールド名のみ
        
        internal init(from type: any Recordable.Type) {
            self.primaryKeyFields = type.primaryKeyFields
            self.indices = []  // future: @Indexマクロから取得
            // ...
        }
    }
}
```

**削除**: `primaryKeyExpression: KeyExpression`, `secondaryIndexes: [Index]`

### IndexManager API (責務追加)

```swift
public actor IndexManager {
    private let schema: Schema
    private var indexCache: [String: Index] = [:]
    
    /// Entityのindices定義からIndex実装を構築
    public func buildIndexes(for entity: Schema.Entity) -> [Index] {
        return entity.indices.enumerated().map { (i, fieldNames) in
            let expression = buildKeyExpression(from: fieldNames)
            return Index(
                name: "\(entity.name)_index_\(i)",
                rootExpression: expression,
                type: .value
            )
        }
    }
    
    /// フィールド名配列からKeyExpression構築
    private func buildKeyExpression(from fieldNames: [String]) -> KeyExpression {
        if fieldNames.count == 1 {
            return FieldKeyExpression(fieldName: fieldNames[0])
        } else {
            return ConcatenateKeyExpression(
                children: fieldNames.map { FieldKeyExpression(fieldName: $0) }
            )
        }
    }
    
    /// Entity名からインデックス取得
    public func getIndexes(for entityName: String) -> [Index] {
        guard let entity = schema.entity(named: entityName) else { return [] }
        return buildIndexes(for: entity)
    }
}
```

### RecordStore API (動的構築)

```swift
public final class RecordStore<Record: Recordable>: Sendable {
    private let schema: Schema
    private let indexManager: IndexManager
    
    /// プライマリキーExpressionを動的構築
    private func getPrimaryKeyExpression() throws -> KeyExpression {
        guard let entity = schema.entity(for: Record.self) else {
            throw RecordLayerError.entityNotFound(Record.recordTypeName)
        }
        
        let fields = entity.primaryKeyFields
        return buildKeyExpression(from: fields)
    }
    
    /// Indexは IndexManagerから取得
    private func getIndexes() -> [Index] {
        return indexManager.getIndexes(for: Record.recordTypeName)
    }
    
    private func buildKeyExpression(from fields: [String]) -> KeyExpression {
        if fields.count == 1 {
            return FieldKeyExpression(fieldName: fields[0])
        } else {
            return ConcatenateKeyExpression(
                children: fields.map { FieldKeyExpression(fieldName: $0) }
            )
        }
    }
}
```

