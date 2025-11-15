# モジュール分離設計書：クライアント・サーバー間のモデル共有（SSOT版）

**作成日**: 2025-01-16
**バージョン**: 2.0
**ステータス**: 設計確定

---

## 目次

1. [概要](#概要)
2. [設計原則：SSOT](#設計原則ssot)
3. [現状分析](#現状分析)
4. [目標アーキテクチャ](#目標アーキテクチャ)
5. [モジュール設計](#モジュール設計)
6. [プロトコル設計](#プロトコル設計)
7. [マクロ設計](#マクロ設計)
8. [RecordAccess設計](#recordaccess設計)
9. [使用例](#使用例)
10. [マイグレーション戦略](#マイグレーション戦略)
11. [実装計画](#実装計画)
12. [成功基準](#成功基準)

---

## 概要

### 目的

現在のfdb-record-layerは全てのコンポーネントがFoundationDBに依存しており、iOS/macOSクライアントアプリでモデル定義を共有できません。本設計では、**モデル定義をSSOT（Single Source of Truth）として維持しながら**、モジュールを分離します：

- **FDBRecordCore**: モデル定義レイヤー（@Recordableマクロ含む、FDB非依存）
- **FDBRecordLayer**: 永続化・インデックス・クエリレイヤー（FDB依存）

### 期待される効果

1. **SSOT**: サーバーとクライアントで**完全に同一**のモデル定義
2. **型安全性**: コンパイル時の型チェック（サーバー・クライアント両方）
3. **軽量化**: クライアントアプリにFoundationDBライブラリをリンクしない
4. **Codable統合**: JSON API連携が容易
5. **後方互換性**: 既存のサーバーコードは変更不要
6. **学習コスト**: 新しいマクロやAPIを学ぶ必要なし

---

## 設計原則：SSOT

### Single Source of Truth（唯一の真実の情報源）

**モデル定義は1箇所のみ**:

```swift
// Shared/Models/User.swift
import FDBRecordCore

@Recordable  // 既存マクロ
struct User {
    #PrimaryKey<User>([\.userID])  // 既存マクロ
    #Index<User>([\.email])

    var userID: Int64
    var email: String
    var name: String
}

// ✅ クライアントで使用: Codable
let jsonData = try JSONEncoder().encode(user)

// ✅ サーバーで使用: FDB永続化
try await store.save(user)
```

**重要な設計決定**:
- ❌ 新しいマクロは追加しない（@Record, @ID等）
- ✅ 既存の@Recordableマクロを**FDB非依存に改良**
- ✅ クライアント・サーバーで**完全に同じコード**を使用

---

## 現状分析

### 問題点

#### 1. FoundationDB依存の全域化

**Sources/FDBRecordLayer/Serialization/Recordable.swift**:
```swift
import Foundation
import FoundationDB  // ← 全てのモデルがFDB依存
```

**影響**:
- iOS/macOSアプリで`@Recordable`を使用できない
- FoundationDBバイナリ（約20MB）をクライアントにリンクする必要
- モデル定義を重複実装する必要

#### 2. Recordableプロトコル自体がFDB依存

**現在のRecordableプロトコル**:
```swift
public protocol Recordable: Sendable, Codable {
    // FoundationDBのTuple型に直接依存
    func extractField(_ fieldName: String) -> [any TupleElement]  // ← FDB型
    func extractPrimaryKey() -> Tuple                              // ← FDB型
}
```

**影響**:
- プロトコル定義自体がFoundationDBに密結合
- クライアントアプリでは使用不可能

#### 3. マクロ生成コードがFDB依存

**現在の@Recordableマクロ**が生成するコード:
```swift
extension User: Recordable {
    // FoundationDBのTupleElement型を返す
    public func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "email": return [email]
        // ...
        }
    }
}
```

**影響**:
- マクロが生成するコード自体がFDB依存
- クライアント側でコンパイルエラー

---

## 目標アーキテクチャ

### モジュール依存グラフ

```
┌─────────────────────────────────────────────────────────┐
│                    Swift標準ライブラリ                    │
│                  (Foundation, Codable)                   │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│              FDBRecordLayerMacros (コンパイラプラグイン)   │
│  - @Recordable, #PrimaryKey<T>, #Index<T>              │
│  - @Transient, @Default, @Attribute                    │
│  ※すべて既存マクロ（FDB非依存のコードを生成）              │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                     FDBRecordCore                        │
│           ┌─────────────────────────────────────┐        │
│           │  依存: Swift標準ライブラリのみ        │        │
│           │  プラットフォーム: iOS, macOS, Linux  │        │
│           └─────────────────────────────────────┘        │
│                                                          │
│  ✅ Recordable プロトコル（FDB非依存版）                  │
│  ✅ IndexDefinition（メタデータ）                        │
│  ✅ RecordMetadataDescriptor                            │
│  ✅ マクロ定義のエクスポート                              │
│                                                          │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                    FDBRecordLayer                        │
│           ┌─────────────────────────────────────┐        │
│           │  依存: FDBRecordCore + FoundationDB │        │
│           │  プラットフォーム: macOS, Linux       │        │
│           └─────────────────────────────────────┘        │
│                                                          │
│  ✅ RecordAccess (Recordable → FDB変換)                 │
│  ✅ RecordStore<Record: Recordable>                     │
│  ✅ IndexManager                                        │
│  ✅ QueryBuilder                                        │
│  ✅ OnlineIndexer                                       │
│  ✅ MigrationManager                                    │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### クライアント・サーバー使用例

#### 共通モデル定義（SSOT）

```swift
// Shared/Models/User.swift
import FDBRecordCore

@Recordable  // 既存マクロ（FDB非依存のコード生成）
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email])

    var userID: Int64
    var email: String
    var name: String
}
```

#### iOS/macOSクライアント

```swift
import FDBRecordCore  // FoundationDB非依存

// 同じUser型を使用
let user = User(userID: 1, email: "user@example.com", name: "Alice")
let jsonData = try JSONEncoder().encode(user)  // Codable

// SwiftUI表示
List(users) { user in
    Text(user.name)
}
```

#### サーバー

```swift
import FDBRecordCore   // モデル定義
import FDBRecordLayer  // RecordStore等

// 同じUser型でFDB永続化
let store = try await User.store(database: database, schema: schema)
try await store.save(user)

// インデックスクエリ
let users = try await store.query()
    .where(\.email, .equals, "user@example.com")
    .execute()
```

---

## モジュール設計

### FDBRecordCore

#### 目的
FoundationDB非依存のモデル定義レイヤー。**@Recordableマクロ含む**。

#### 依存関係
- ✅ Swift標準ライブラリ（Foundation, Codable）
- ✅ FDBRecordLayerMacros（コンパイル時のみ）
- ❌ FoundationDB（依存しない）

#### 提供する機能

##### 1. Recordableプロトコル（FDB非依存版）

```swift
// Sources/FDBRecordCore/Recordable.swift

import Foundation

/// 永続化可能なレコード型のプロトコル
///
/// FDB非依存。クライアント・サーバー共通で使用。
public protocol Recordable: Sendable, Codable {
    /// レコードタイプ名
    static var recordName: String { get }

    /// プライマリキーフィールド名のリスト
    static var primaryKeyFields: [String] { get }

    /// 全フィールド名のリスト（@Transient除く）
    static var allFields: [String] { get }

    /// インデックス定義のリスト
    static var indexDefinitions: [IndexDefinition] { get }

    /// Protobufフィールド番号取得
    static func fieldNumber(for fieldName: String) -> Int?
}

// デフォルト実装
extension Recordable {
    public static var indexDefinitions: [IndexDefinition] {
        return []
    }
}
```

**重要**: `extractField()` や `extractPrimaryKey()` などのFDB固有メソッドは**含めない**

##### 2. IndexDefinition（メタデータ）

```swift
// Sources/FDBRecordCore/IndexDefinition.swift

import Foundation

/// インデックス定義（FDB非依存）
public struct IndexDefinition: Sendable {
    public let name: String
    public let keyPaths: [PartialKeyPath<Any>]
    public let type: IndexType
    public let scope: IndexScope

    public enum IndexType: String, Sendable {
        case value
        case rank
        case count
        case sum
        case min
        case max
    }

    public enum IndexScope: String, Sendable {
        case partition
        case global
    }
}
```

##### 3. マクロ定義のエクスポート

```swift
// Sources/FDBRecordCore/Macros.swift

import Foundation

/// Recordableプロトコルへの準拠を自動生成
@attached(member, names: /* ... */)
@attached(extension, conformances: Recordable)
public macro Recordable() = #externalMacro(module: "FDBRecordLayerMacros", type: "RecordableMacro")

/// プライマリキー定義
@freestanding(declaration)
public macro PrimaryKey<T>(_ keyPaths: [PartialKeyPath<T>]) = #externalMacro(module: "FDBRecordLayerMacros", type: "PrimaryKeyMacro")

/// インデックス定義
@freestanding(declaration)
public macro Index<T>(_ keyPaths: [PartialKeyPath<T>], type: IndexDefinition.IndexType? = nil, scope: IndexDefinition.IndexScope? = nil, name: String? = nil) = #externalMacro(module: "FDBRecordLayerMacros", type: "IndexMacro")

// その他既存マクロ
@attached(peer)
public macro Transient() = #externalMacro(module: "FDBRecordLayerMacros", type: "TransientMacro")

@attached(peer)
public macro Default(value: Any) = #externalMacro(module: "FDBRecordLayerMacros", type: "DefaultMacro")

@attached(peer)
public macro Attribute(_ options: AttributeOption..., originalName: String? = nil, hashModifier: String? = nil) = #externalMacro(module: "FDBRecordLayerMacros", type: "AttributeMacro")
```

#### ファイル構成

```
Sources/FDBRecordCore/
├── Recordable.swift              # Recordableプロトコル（FDB非依存）
├── IndexDefinition.swift         # インデックスメタデータ
├── Macros.swift                  # マクロ定義のエクスポート
└── Errors.swift                  # コアエラー型
```

---

### FDBRecordLayer

#### 目的
FoundationDB依存の永続化・インデックス・クエリ機能を提供。

#### 依存関係
- ✅ FDBRecordCore
- ✅ FoundationDB (fdb-swift-bindings)
- ✅ 既存の依存関係（Logging, Metrics, SwiftProtobuf, etc）

#### 提供する機能

##### 1. RecordAccess（Recordable → FDB変換）

**重要な設計変更**: RecordableプロトコルにFDBメソッドを含めず、RecordAccessが**リフレクション**を使ってFDB型に変換します。

```swift
// Sources/FDBRecordLayer/Serialization/RecordAccess.swift

import Foundation
import FoundationDB
import FDBRecordCore

/// RecordableプロトコルからFDB型への変換を担当
///
/// RecordableにはFDB依存メソッドを含めず、RecordAccessがリフレクションで変換
public struct GenericRecordAccess<Record: Recordable> {

    public init() {}

    /// プライマリキーをFDB Tupleに変換
    public func extractPrimaryKey(from record: Record) -> Tuple {
        let mirror = Mirror(reflecting: record)
        var elements: [any TupleElement] = []

        for fieldName in Record.primaryKeyFields {
            if let value = findFieldValue(in: mirror, fieldName: fieldName) {
                elements.append(convertToTupleElement(value))
            }
        }

        return Tuple(elements)
    }

    /// フィールド値をFDB TupleElementに変換
    public func extractField(from record: Record, fieldName: String) -> [any TupleElement] {
        let mirror = Mirror(reflecting: record)

        guard let value = findFieldValue(in: mirror, fieldName: fieldName) else {
            return []
        }

        return [convertToTupleElement(value)]
    }

    // MARK: - Private Helpers

    private func findFieldValue(in mirror: Mirror, fieldName: String) -> Any? {
        for child in mirror.children {
            if child.label == fieldName {
                return child.value
            }
        }
        return nil
    }

    private func convertToTupleElement(_ value: Any) -> any TupleElement {
        switch value {
        case let v as String: return v
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Double: return v
        case let v as Float: return v
        case let v as Bool: return v
        case let v as UUID: return v.uuidString
        case let v as Date: return v.timeIntervalSince1970
        case let v as Data: return FDB.Bytes(v)
        default:
            fatalError("Unsupported type for TupleElement: \(type(of: value))")
        }
    }
}
```

##### 2. RecordStore（既存APIを維持）

```swift
// Sources/FDBRecordLayer/Store/RecordStore.swift

import FDBRecordCore
import FoundationDB

/// Record store for managing a specific record type
public final class RecordStore<Record: Recordable>: Sendable {
    // 既存の実装を維持
    // RecordAccessを使ってRecordable → FDB変換

    public func save(_ record: Record) async throws {
        let recordAccess = GenericRecordAccess<Record>()
        let primaryKey = recordAccess.extractPrimaryKey(from: record)
        let bytes = try recordAccess.serialize(record)

        // ... 既存のロジック
    }
}
```

---

## プロトコル設計

### Recordableプロトコル（FDB非依存版）

#### 設計原則

1. **FDB型を使わない**: `Tuple`, `TupleElement` への参照を削除
2. **メタデータのみ**: フィールド名、型情報、インデックス定義
3. **Codable準拠**: JSON/Protobufシリアライゼーション
4. **リフレクション対応**: RecordAccessがMirror APIで値を取得

#### プロトコル定義

```swift
// FDBRecordCore/Recordable.swift

public protocol Recordable: Sendable, Codable {
    // メタデータ（FDB非依存）
    static var recordName: String { get }
    static var primaryKeyFields: [String] { get }
    static var allFields: [String] { get }
    static var indexDefinitions: [IndexDefinition] { get }
    static func fieldNumber(for fieldName: String) -> Int?

    // ❌ 削除: extractField() - FDB依存
    // ❌ 削除: extractPrimaryKey() - FDB依存
}
```

#### 既存コードとの互換性

**現在の@Recordableマクロが生成するコード**:
```swift
extension User: Recordable {
    // ❌ FDB依存（削除）
    public func extractField(_ fieldName: String) -> [any TupleElement] { ... }
    public func extractPrimaryKey() -> Tuple { ... }
}
```

**新しい@Recordableマクロが生成するコード**:
```swift
extension User: Recordable {
    // ✅ FDB非依存（メタデータのみ）
    public static var recordName: String { "User" }
    public static var primaryKeyFields: [String] { ["userID"] }
    public static var allFields: [String] { ["userID", "email", "name"] }
    public static var indexDefinitions: [IndexDefinition] { [/* ... */] }

    public static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "userID": return 1
        case "email": return 2
        case "name": return 3
        default: return nil
        }
    }
}
```

---

## マクロ設計

### @Recordableマクロの更新

#### 現在の生成コード（FDB依存）

```swift
extension User: Recordable {
    // FDB型を返す
    public func extractField(_ fieldName: String) -> [any TupleElement] {
        switch fieldName {
        case "userID": return [userID]
        case "email": return [email]
        default: return []
        }
    }

    public func extractPrimaryKey() -> Tuple {
        return Tuple(userID)
    }
}
```

#### 新しい生成コード（FDB非依存）

```swift
extension User: Recordable {
    // メタデータのみ
    public static var recordName: String { "User" }

    public static var primaryKeyFields: [String] { ["userID"] }

    public static var allFields: [String] { ["userID", "email", "name"] }

    public static var indexDefinitions: [IndexDefinition] {
        [
            IndexDefinition(
                name: "user_by_email",
                keyPaths: [\.email],
                type: .value,
                scope: .partition
            )
        ]
    }

    public static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "userID": return 1
        case "email": return 2
        case "name": return 3
        default: return nil
        }
    }
}
```

**重要**: `import FoundationDB` は不要、`Tuple` や `TupleElement` への参照なし

---

## RecordAccess設計

### リフレクションベースのフィールド抽出

#### 設計原則

1. **RecordableはFDB非依存**: メタデータのみ提供
2. **RecordAccessがFDB変換**: Swift MirrorでフィールドにアクセスしてTuple化
3. **パフォーマンス**: リフレクションは初回のみ、結果をキャッシュ（将来最適化）

#### 実装例

```swift
// FDBRecordLayer/Serialization/RecordAccess.swift

import Foundation
import FoundationDB
import FDBRecordCore

public struct GenericRecordAccess<Record: Recordable> {

    // MARK: - Primary Key Extraction

    public func extractPrimaryKey(from record: Record) -> Tuple {
        let mirror = Mirror(reflecting: record)
        var elements: [any TupleElement] = []

        // primaryKeyFieldsの順序でフィールド値を取得
        for fieldName in Record.primaryKeyFields {
            guard let value = findFieldValue(in: mirror, fieldName: fieldName) else {
                fatalError("Primary key field '\(fieldName)' not found in \(Record.recordName)")
            }
            elements.append(convertToTupleElement(value))
        }

        return Tuple(elements)
    }

    // MARK: - Field Extraction

    public func extractField(from record: Record, fieldName: String) -> [any TupleElement] {
        let mirror = Mirror(reflecting: record)

        guard let value = findFieldValue(in: mirror, fieldName: fieldName) else {
            return []
        }

        // 配列フィールドの場合は展開
        if let array = value as? [Any] {
            return array.map { convertToTupleElement($0) }
        }

        return [convertToTupleElement(value)]
    }

    // MARK: - Serialization

    public func serialize(_ record: Record) throws -> FDB.Bytes {
        // Codable経由でProtobufエンコード
        let encoder = ProtobufEncoder()
        return try encoder.encode(record)
    }

    public func deserialize(_ bytes: FDB.Bytes) throws -> Record {
        // Codable経由でProtobufデコード
        let decoder = ProtobufDecoder()
        return try decoder.decode(Record.self, from: bytes)
    }

    // MARK: - Private Helpers

    private func findFieldValue(in mirror: Mirror, fieldName: String) -> Any? {
        for child in mirror.children {
            if child.label == fieldName {
                return child.value
            }
        }
        return nil
    }

    private func convertToTupleElement(_ value: Any) -> any TupleElement {
        // Swift型 → FDB TupleElement変換
        switch value {
        case let v as String: return v
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Int32: return Int64(v)
        case let v as Double: return v
        case let v as Float: return v
        case let v as Bool: return v
        case let v as UUID: return v.uuidString
        case let v as Date: return v.timeIntervalSince1970
        case let v as Data: return FDB.Bytes(v)
        default:
            fatalError("Unsupported type for TupleElement: \(type(of: value))")
        }
    }
}
```

### パフォーマンス最適化（将来）

```swift
// キャッシュ戦略（Phase 2で実装）
private static var fieldCache: [String: Int] = [:]

private func findFieldValueOptimized(in mirror: Mirror, fieldName: String) -> Any? {
    // フィールド位置をキャッシュして高速化
}
```

---

## 使用例

### 共通モデル定義（SSOT）

```swift
// Shared/Models/User.swift
import FDBRecordCore

/// クライアント・サーバー共通のモデル定義
///
/// @Recordableマクロにより以下が自動生成される：
/// - Recordable プロトコル準拠（FDB非依存）
/// - Codable 準拠（JSON/Protobuf）
/// - Sendable 準拠（並行処理安全）
/// - メタデータ（recordName, primaryKeyFields, allFields等）
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email], name: "user_by_email")
    #Index<User>([\.name], name: "user_by_name")

    var userID: Int64
    var email: String
    var name: String

    @Transient var isLoggedIn: Bool = false

    @Default(value: Date())
    var createdAt: Date
}
```

### クライアント側（iOS/macOS）

#### API連携

```swift
// iOS App
import FDBRecordCore  // FoundationDB非依存

class UserService {
    func fetchUsers() async throws -> [User] {
        let url = URL(string: "https://api.example.com/users")!
        let (data, _) = try await URLSession.shared.data(from: url)

        // Codable でデコード
        return try JSONDecoder().decode([User].self, from: data)
    }

    func createUser(_ user: User) async throws {
        let url = URL(string: "https://api.example.com/users")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Codable でエンコード
        request.httpBody = try JSONEncoder().encode(user)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            throw URLError(.badServerResponse)
        }
    }
}
```

#### SwiftUI表示

```swift
// iOS App
import SwiftUI
import FDBRecordCore

struct UserListView: View {
    @State private var users: [User] = []
    private let service = UserService()

    var body: some View {
        NavigationView {
            List(users, id: \.userID) { user in
                VStack(alignment: .leading) {
                    Text(user.name)
                        .font(.headline)
                    Text(user.email)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Users")
            .task {
                users = (try? await service.fetchUsers()) ?? []
            }
        }
    }
}
```

### サーバー側

#### RecordStore使用

```swift
// Server
import FDBRecordCore   // モデル定義
import FDBRecordLayer  // RecordStore等

class UserRepository {
    private let store: RecordStore<User>

    init(database: any DatabaseProtocol, schema: Schema) async throws {
        // 同じUser型でRecordStore作成
        self.store = try await User.store(database: database, schema: schema)
    }

    func save(_ user: User) async throws {
        try await store.save(user)
    }

    func findByEmail(_ email: String) async throws -> User? {
        let users = try await store.query()
            .where(\.email, .equals, email)
            .execute()
        return users.first
    }

    func findAll() async throws -> [User] {
        var result: [User] = []
        for try await user in store.scan() {
            result.append(user)
        }
        return result
    }
}
```

#### Vapor統合

```swift
// Server/Routes/UserRoutes.swift
import Vapor
import FDBRecordCore
import FDBRecordLayer

func routes(_ app: Application) throws {
    let repo = try await UserRepository(database: app.fdb, schema: schema)

    // GET /users
    app.get("users") { req async throws -> [User] in
        return try await repo.findAll()
    }

    // POST /users
    app.post("users") { req async throws -> User in
        // 同じUser型でデコード
        let user = try req.content.decode(User.self)
        try await repo.save(user)
        return user
    }

    // GET /users/:email
    app.get("users", ":email") { req async throws -> User in
        guard let email = req.parameters.get("email"),
              let user = try await repo.findByEmail(email) else {
            throw Abort(.notFound)
        }
        return user
    }
}
```

---

## マイグレーション戦略

### 段階的移行アプローチ

#### Phase 1: FDBRecordCoreモジュール作成（破壊的変更なし）

**タスク**:
1. Package.swiftにFDBRecordCoreターゲット追加
2. Recordableプロトコル（FDB非依存版）を作成
3. IndexDefinition等のメタデータ型を作成
4. マクロ定義のエクスポートファイル作成

**影響**: なし（既存コードは動作し続ける）

#### Phase 2: @Recordableマクロ更新（既存コードに影響）

**タスク**:
1. RecordableMacroを更新してFDB非依存コードを生成
2. RecordAccessにリフレクションベースの抽出ロジック追加
3. RecordStoreでRecordAccessを使用するよう更新

**影響**: 中程度
- 既存の`@Recordable`コードは再コンパイル必要
- 生成コードの構造が変わる
- ただし、使用側のコードは変更不要

#### Phase 3: テスト・検証

**タスク**:
1. 既存テストスイート（321テスト）実行
2. クライアント専用サンプルアプリ作成
3. パフォーマンステスト（リフレクションのオーバーヘッド測定）

**成功基準**:
- [ ] 既存テスト321件全て合格
- [ ] クライアントサンプルがFDB依存なしでビルド
- [ ] パフォーマンス劣化 < 5%

### 後方互換性

#### APIシグネチャ（変更なし）

```swift
// ✅ 既存のAPIは全て維持
@Recordable
struct User { ... }

#PrimaryKey<User>([\.userID])
#Index<User>([\.email])

let store = RecordStore<User>(...)
try await store.save(user)
```

#### データフォーマット（変更なし）

- ✅ FoundationDB内のキーフォーマット変更なし
- ✅ 値フォーマット変更なし（Protobuf）
- ✅ インデックス構造変更なし

---

## 実装計画

### タイムライン

| フェーズ | タスク | 見積もり時間 |
|---------|--------|-------------|
| **Phase 1** | FDBRecordCoreモジュール作成 | 2-3h |
| | - Package.swift更新 | 30分 |
| | - Recordableプロトコル（FDB非依存版） | 1h |
| | - IndexDefinition等メタデータ型 | 30分 |
| | - マクロ定義エクスポート | 30分 |
| **Phase 2** | @Recordableマクロ更新 | 3-4h |
| | - RecordableMacro更新（FDB非依存コード生成） | 2h |
| | - RecordAccess実装（リフレクション） | 1.5h |
| | - RecordStore統合 | 30分 |
| **Phase 3** | テスト・検証 | 2-3h |
| | - 既存テストスイート実行 | 1h |
| | - クライアントサンプル作成 | 1h |
| | - パフォーマンステスト | 1h |
| **Phase 4** | ドキュメント更新 | 1-2h |
| | - README更新 | 30分 |
| | - api-reference.md更新 | 30分 |
| | - サンプルコード追加 | 30分 |
| **合計** | | **8-12時間** |

### マイルストーン

#### M1: FDBRecordCore動作確認（Phase 1完了）
- [ ] FDBRecordCoreモジュールがビルド成功
- [ ] Recordableプロトコル（FDB非依存版）が定義済み
- [ ] マクロ定義がエクスポート済み

#### M2: マクロ更新完了（Phase 2完了）
- [ ] @RecordableマクロがFDB非依存コードを生成
- [ ] RecordAccessがリフレクションで動作
- [ ] RecordStoreが正常動作

#### M3: 検証完了（Phase 3完了）
- [ ] 既存テスト321件全て合格
- [ ] クライアントサンプルがビルド成功（FDB依存なし）
- [ ] パフォーマンス劣化 < 5%

---

## 成功基準

### 機能要件

- [ ] **SSOT**: クライアント・サーバーで完全に同一のモデル定義
- [ ] **FDBRecordCore**: FoundationDB非依存のビルド成功
- [ ] **@Recordableマクロ**: FDB非依存コードを生成
- [ ] **RecordAccess**: リフレクションでRecordable → FDB変換
- [ ] **既存API**: 全てのパブリックAPIが動作

### 非機能要件

- [ ] **後方互換性**: 既存コードが変更なしで動作
- [ ] **パフォーマンス**: リフレクションオーバーヘッド < 5%
- [ ] **テストカバレッジ**: 既存321テスト全て合格
- [ ] **モジュールサイズ**: FDBRecordCore < 100KB
- [ ] **学習コスト**: 新しいマクロやAPIなし

### ドキュメント要件

- [ ] **README.md**: 2モジュール構成の説明
- [ ] **api-reference.md**: 更新
- [ ] **サンプルコード**: クライアント・サーバー両方
- [ ] **CHANGELOG.md**: 更新

---

## 付録

### リスクと対策

| リスク | 影響度 | 対策 |
|-------|-------|------|
| **リフレクションのパフォーマンス** | 中 | ベンチマーク、将来的にキャッシュ |
| **マクロ生成コードの不整合** | 高 | 包括的なテストケース |
| **既存コードの破壊** | 高 | 段階的移行、既存テスト全件実行 |

### 参考リンク

- [FoundationDB公式ドキュメント](https://apple.github.io/foundationdb/)
- [Java Record Layer](https://github.com/FoundationDB/fdb-record-layer)
- [Swift Macros](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/macros/)

### 用語集

| 用語 | 定義 |
|------|------|
| **SSOT** | Single Source of Truth（唯一の真実の情報源） |
| **Recordable** | FDB非依存のレコードプロトコル |
| **RecordAccess** | Recordable → FDB変換を担当するヘルパー |
| **FDBRecordCore** | モデル定義モジュール（FDB非依存） |
| **FDBRecordLayer** | FDB永続化モジュール（FDB依存） |

---

**このドキュメントに関する質問・フィードバック**: [GitHub Issues](https://github.com/1amageek/fdb-record-layer/issues)
