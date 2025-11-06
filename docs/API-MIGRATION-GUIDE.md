# API Migration Guide

## Overview

このプロジェクトは開発中のため、古いAPI・重複実装を削除しました。
新しい型安全APIのみを使用してください。

## ✅ 推奨API（使用してください）

### 1. GenericRecordAccess - 型安全なレコードアクセス

**用途**: Recordableプロトコルに準拠した型でレコードを保存・読み取り

```swift
import FDBRecordLayer

// Recordableに準拠した型を定義（将来的にはマクロで自動生成）
struct User: Recordable {
    static let recordTypeName = "User"
    static let primaryKeyFields = ["userID"]
    static let allFields = ["userID", "email", "name"]

    let userID: Int64
    let email: String
    let name: String

    func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "userID": return [userID]
        case "email": return [email]
        case "name": return [name]
        default: return []
        }
    }

    func extractPrimaryKey() -> Tuple {
        return Tuple(userID)
    }

    func toProtobuf() throws -> Data {
        // Protobufシリアライゼーション実装
    }

    static func fromProtobuf(_ data: Data) throws -> User {
        // Protobufデシリアライゼーション実装
    }
}

// RecordStoreで使用
let recordAccess = GenericRecordAccess<User>()
let store = RecordStore(
    database: database,
    subspace: subspace,
    metaData: metaData
)

// 保存
try await store.save(user)

// 読み取り
let users: [User] = try await store.fetch(User.self).collect()
```

### 2. RecordAccess プロトコル - 汎用レコードアクセス

**用途**: カスタムシリアライゼーションが必要な場合

```swift
public protocol RecordAccess<Record>: Sendable {
    associatedtype Record: Sendable

    /// レコード型名を取得
    func recordTypeName(for record: Record) -> String

    /// フィールド値を抽出
    func extractField(from record: Record, fieldName: String) throws -> [any TupleElement]

    /// レコードをバイト列にシリアライズ
    func serialize(_ record: Record) throws -> FDB.Bytes

    /// バイト列からレコードをデシリアライズ
    func deserialize(_ bytes: FDB.Bytes) throws -> Record
}
```

### 3. Recordable プロトコル - レコード型の要件

**用途**: GenericRecordAccessで使用する型の定義

```swift
public protocol Recordable: Sendable {
    static var recordTypeName: String { get }
    static var primaryKeyFields: [String] { get }
    static var allFields: [String] { get }

    func extractField(_ fieldName: String) -> [any TupleElement]
    func extractPrimaryKey() -> Tuple
    func toProtobuf() throws -> Data
    static func fromProtobuf(_ data: Data) throws -> Self
}
```

## ❌ 削除されたAPI（使用しないでください）

### 1. DictionaryRecordAccess ❌

**理由**: Legacy dictionary-based API、型安全性なし

**移行先**: `GenericRecordAccess<T: Recordable>`

```swift
// ❌ 古いコード
let dictionaryAccess = DictionaryRecordAccess()
let record: [String: Any] = ["_type": "User", "id": 1, "name": "Alice"]

// ✅ 新しいコード
struct User: Recordable { ... }
let recordAccess = GenericRecordAccess<User>()
let record = User(userID: 1, name: "Alice", email: "alice@example.com")
```

### 2. ProtobufRecordAccess ❌

**理由**: 手動でフィールドエクストラクタを定義する必要がある

**移行先**: `GenericRecordAccess<T: Recordable>`

```swift
// ❌ 古いコード
extension ProtobufFieldExtractor where M == User {
    public static func forUser() -> ProtobufFieldExtractor<User> {
        return ProtobufFieldExtractor(extractors: [
            "userID": { user in [user.userID] },
            "name": { user in [user.name] }
        ])
    }
}
let userAccess = ProtobufRecordAccess(typeName: "User", fieldExtractor: .forUser())

// ✅ 新しいコード
struct User: Recordable {
    func extractField(_ fieldName: String) -> [any TupleElement] {
        // 自動実装（または手動）
    }
}
let recordAccess = GenericRecordAccess<User>()
```

### 3. RecordSerializer プロトコル ❌

**理由**: RecordAccessプロトコルと完全に重複

**移行先**: `RecordAccess` プロトコルを使用

```swift
// ❌ 古いコード
struct MySerializer: RecordSerializer {
    func serialize(_ record: MyRecord) throws -> FDB.Bytes { ... }
    func deserialize(_ bytes: FDB.Bytes) throws -> MyRecord { ... }
}

// ✅ 新しいコード
struct MyRecordAccess: RecordAccess {
    func recordTypeName(for record: MyRecord) -> String { ... }
    func extractField(from record: MyRecord, fieldName: String) throws -> [any TupleElement] { ... }
    func serialize(_ record: MyRecord) throws -> FDB.Bytes { ... }
    func deserialize(_ bytes: FDB.Bytes) throws -> MyRecord { ... }
}
```

### 4. CodableSerializer / ProtobufSerializer ❌

**理由**: RecordAccessで代替可能

**移行先**: `GenericRecordAccess<T: Recordable>` または カスタム `RecordAccess` 実装

```swift
// ❌ 古いコード
let serializer = CodableSerializer<MyRecord>()
let bytes = try serializer.serialize(record)

// ✅ 新しいコード
let recordAccess = GenericRecordAccess<MyRecord>()
let bytes = try recordAccess.serialize(record)
```

## 🔄 OnlineIndexer 移行例

### 変更前

```swift
let indexer = OnlineIndexer(
    database: database,
    subspace: subspace,
    metaData: metaData,
    recordType: recordType,
    index: index,
    recordAccess: recordAccess,
    serializer: CodableSerializer<User>(),  // ❌ 削除されたパラメータ
    indexStateManager: indexStateManager
)
```

### 変更後

```swift
let indexer = OnlineIndexer(
    database: database,
    subspace: subspace,
    metaData: metaData,
    recordType: recordType,
    index: index,
    recordAccess: GenericRecordAccess<User>(),  // ✅ recordAccessのみ
    indexStateManager: indexStateManager
)
```

**変更点**: `serializer` パラメータを削除し、`recordAccess.deserialize()` を内部で使用

## 📚 推奨開発パターン

### パターン1: SwiftData風マクロAPI（将来実装予定）

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var email: String
    var name: String
}

// 自動的にRecordableプロトコルが実装される
// GenericRecordAccessで使用可能
```

### パターン2: 手動Recordable実装

```swift
struct User: Recordable {
    static let recordTypeName = "User"
    static let primaryKeyFields = ["userID"]
    static let allFields = ["userID", "email", "name"]

    let userID: Int64
    let email: String
    let name: String

    func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "userID": return [userID]
        case "email": return [email]
        case "name": return [name]
        default: return []
        }
    }

    func extractPrimaryKey() -> Tuple {
        return Tuple(userID)
    }

    // Protobufシリアライゼーションを実装
    func toProtobuf() throws -> Data {
        // 実装
    }

    static func fromProtobuf(_ data: Data) throws -> User {
        // 実装
    }
}
```

### パターン3: カスタムRecordAccess実装

```swift
struct CustomRecordAccess: RecordAccess {
    typealias Record = MyCustomType

    func recordTypeName(for record: MyCustomType) -> String {
        return "MyCustomType"
    }

    func extractField(from record: MyCustomType, fieldName: String) throws -> [any TupleElement] {
        // カスタムフィールド抽出ロジック
    }

    func serialize(_ record: MyCustomType) throws -> FDB.Bytes {
        // カスタムシリアライゼーション
    }

    func deserialize(_ bytes: FDB.Bytes) throws -> MyCustomType {
        // カスタムデシリアライゼーション
    }
}
```

## 🎯 まとめ

| 機能 | 削除されたAPI | 新しいAPI |
|------|--------------|-----------|
| 型安全なレコードアクセス | `ProtobufRecordAccess` | `GenericRecordAccess<T: Recordable>` |
| Dictionary based | `DictionaryRecordAccess` | ❌ サポート終了 |
| シリアライゼーション | `RecordSerializer`, `CodableSerializer`, `ProtobufSerializer` | `RecordAccess` プロトコル |
| OnlineIndexer | `serializer` パラメータ | `recordAccess` のみ |

**開発方針**:
- ✅ 型安全性を最優先
- ✅ Recordableプロトコルベース
- ✅ 将来的にSwiftData風マクロで自動生成
- ✅ Protobufによる多言語互換性維持

---

**最終更新**: 2025-11-06
**対象バージョン**: 開発中（後方互換性なし）
