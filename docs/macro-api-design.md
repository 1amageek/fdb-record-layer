# マクロベースAPI設計

**作成日**: 2025-01-06
**ステータス**: 設計フェーズ
**対象**: FDB Record Layer マクロAPI

---

## 📋 設計目標

### 1. SwiftData互換のマクロAPI

SwiftDataのマクロと同じ感覚で使える設計：
- `@Recordable` ← SwiftDataの`@Model`
- `@PrimaryKey` ← SwiftDataの`@Attribute(.primaryKey)`
- `#Index`, `#Unique` ← SwiftDataの`#Index`, `#Unique`
- `#Subspace` ← **独自**: 動的パス構築

### 2. Protobuf実装の隠蔽

ユーザーはSwiftコードのみを記述し、マクロが自動的に：
- Recordableプロトコル実装を生成
- Protobufファイル（.proto）を生成
- シリアライズ/デシリアライズコードを生成

### 3. 段階的実装

**Phase 0**: 基盤API（✅ 完了）
- Recordableプロトコル
- RecordContainer
- Schema
- RecordStore

**Phase 1**: コア マクロ（次のステップ）
- @Recordable
- @PrimaryKey
- @Attribute

**Phase 2**: インデックス マクロ
- #Index
- #Unique

**Phase 3**: Subspace マクロ
- #Subspace（動的パス構築）

**Phase 4**: 高度な機能
- @Relationship
- @Transient
- Protobuf自動生成

---

## 🎯 Phase 1: コアマクロ設計

### @Recordable マクロ

**目的**: SwiftDataの`@Model`相当の機能を提供

#### 使用例

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var email: String
    var name: String
    var age: Int
    var createdAt: Date

    @Transient var isLoggedIn: Bool = false
}
```

#### マクロが生成するコード

```swift
extension User: Recordable {
    // MARK: - Static Properties

    static var recordTypeName: String { "User" }

    static var primaryKeyFields: [String] { ["userID"] }

    static var allFields: [String] {
        ["userID", "email", "name", "age", "createdAt"]
    }

    // MARK: - Serialization

    func toProtobuf() throws -> Data {
        var proto = User_Proto()
        proto.userID = self.userID
        proto.email = self.email
        proto.name = self.name
        proto.age = Int32(self.age)
        proto.createdAt = self.createdAt.timeIntervalSince1970
        return try proto.serializedData()
    }

    static func fromProtobuf(_ data: Data) throws -> User {
        let proto = try User_Proto(serializedData: data)
        return User(
            userID: proto.userID,
            email: proto.email,
            name: proto.name,
            age: Int(proto.age),
            createdAt: Date(timeIntervalSince1970: proto.createdAt),
            isLoggedIn: false  // @Transientフィールドはデフォルト値
        )
    }

    func toDictionary() -> [String: Any] {
        return [
            "userID": userID,
            "email": email,
            "name": name,
            "age": age,
            "createdAt": createdAt
        ]
    }

    func extractPrimaryKey() -> Tuple {
        return Tuple([userID])
    }

    // MARK: - KeyPath Support

    static func fieldName<Value>(for keyPath: KeyPath<User, Value>) -> String {
        switch keyPath {
        case \User.userID: return "userID"
        case \User.email: return "email"
        case \User.name: return "name"
        case \User.age: return "age"
        case \User.createdAt: return "createdAt"
        default: return ""
        }
    }
}
```

#### マクロが生成する.protoファイル

```protobuf
syntax = "proto3";

message User_Proto {
    int64 userID = 1;
    string email = 2;
    string name = 3;
    int32 age = 4;
    double createdAt = 5;  // timestamp as Unix epoch
}
```

---

### @PrimaryKey マクロ

**目的**: プライマリキーフィールドを指定

#### 単一主キー

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var email: String
}

// 生成されるコード
static var primaryKeyFields: [String] { ["userID"] }
```

#### 複合主キー

```swift
@Recordable
struct Order {
    @PrimaryKey var tenantID: String
    @PrimaryKey var orderID: Int64
    var amount: Decimal
}

// 生成されるコード
static var primaryKeyFields: [String] { ["tenantID", "orderID"] }

func extractPrimaryKey() -> Tuple {
    return Tuple([tenantID, orderID])
}
```

---

### @Attribute マクロ

**目的**: フィールド属性を指定（オプショナル、リネームなど）

#### 使用例

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64

    @Attribute(originalName: "username")
    var name: String  // Protobufでは"username"

    @Attribute(.optional)
    var bio: String?
}
```

#### 生成されるコード

```swift
static var allFields: [String] {
    ["userID", "username", "bio"]  // ← "name"ではなく"username"
}

func toProtobuf() throws -> Data {
    var proto = User_Proto()
    proto.userID = self.userID
    proto.username = self.name  // ← マッピング
    if let bio = self.bio {
        proto.bio = bio
    }
    return try proto.serializedData()
}
```

---

### @Transient マクロ

**目的**: 永続化しないフィールドを指定

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var email: String

    @Transient var isLoggedIn: Bool = false
    @Transient var cachedAvatar: UIImage?
}

// 生成されるコード
static var allFields: [String] {
    ["userID", "email"]  // ← isLoggedInとcachedAvatarは除外
}
```

---

## 🎯 Phase 2: インデックスマクロ設計

### #Index マクロ

**目的**: セカンダリインデックスを定義

#### 単一フィールドインデックス

```swift
@Recordable
struct User {
    #Index<User>([\.email])

    @PrimaryKey var userID: Int64
    var email: String
    var name: String
}
```

#### マクロ展開

```swift
// マクロがRecordMetaDataに登録するコード
extension User {
    static func registerIndexes(in metaData: RecordMetaData) {
        let emailIndex = Index(
            name: "User_email_idx",
            type: .value,
            rootExpression: FieldKeyExpression(fieldName: "email")
        )
        try? metaData.addIndex(emailIndex, forRecordType: "User")
    }
}
```

#### 複合インデックス

```swift
@Recordable
struct User {
    #Index<User>([\.city, \.age])

    @PrimaryKey var userID: Int64
    var city: String
    var age: Int
}

// 生成されるインデックス
let cityAgeIndex = Index(
    name: "User_city_age_idx",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "age")
    ])
)
```

---

### #Unique マクロ

**目的**: ユニーク制約を持つインデックスを定義

```swift
@Recordable
struct User {
    #Unique<User>([\.email])

    @PrimaryKey var userID: Int64
    var email: String
}

// 生成されるインデックス
let uniqueEmailIndex = Index(
    name: "User_email_unique",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email"),
    options: IndexOptions(unique: true)
)
```

---

## 🎯 Phase 3: Subspace マクロ設計

### #Subspace マクロ

**目的**: 動的なパス構築（Firestore/マルチテナント対応）

**設計原則**:
1. `#Subspace`はマーカーマクロ（freestanding declaration macro）
2. `@Recordable`が`#Subspace`マクロ呼び出しを直接読み取り、適切な`store()`メソッドを生成
3. `#Subspace`がない場合でも、基本的な`store(in:path:)`は常に利用可能

**重要な制約**:
- ⚠️ **プレースホルダー名はフィールド名と完全に一致する必要があります**
- 例: `"accounts/{accountID}/users"` → フィールド名は `accountID` でなければならない
- 不一致の場合はコンパイルエラーになります

#### マクロ連携の仕組み

```
#Subspace<User>("accounts/{accountID}/users")
    ↓ (@Recordableが直接読み取り)
@Recordable
    ↓ (解析してstore()メソッド生成)
extension User {
    // 基本メソッド（常に生成）
    static func store(in container: RecordContainer, path: String) -> RecordStore<User>

    // 型安全メソッド（#Subspaceがある場合のみ生成）
    static func store(in container: RecordContainer, accountID: String) -> RecordStore<User>
}
```

**注意**: `#Subspace`マクロ自体は何も宣言を生成しません。`@Recordable`がASTから直接読み取ります。

#### 静的パス

```swift
@Recordable
struct GlobalConfig {
    #Subspace<GlobalConfig>("config")

    @PrimaryKey var key: String
    var value: String
}

// #Subspace が生成（メタデータ）
static let __subspacePath = "config"
static let __subspacePlaceholders: [String] = []

// @Recordable が生成（store()メソッド）
extension GlobalConfig {
    /// 基本メソッド - 任意のパスで使用可能
    static func store(
        in container: RecordContainer,
        path: String
    ) -> RecordStore<GlobalConfig> {
        return container.store(for: GlobalConfig.self, path: path)
    }

    /// 型安全メソッド - #Subspace のパスを使用
    static func store(
        in container: RecordContainer
    ) -> RecordStore<GlobalConfig> {
        return container.store(for: GlobalConfig.self, path: "config")
    }
}

// 使用例
let configStore = GlobalConfig.store(in: container)  // 型安全
// または
let configStore = GlobalConfig.store(in: container, path: "custom/path")  // 柔軟性
```

#### 動的パス（プレースホルダー使用）

```swift
@Recordable
struct User {
    #Subspace<User>("accounts/{accountID}/users")

    @PrimaryKey var userID: Int64
    var accountID: String  // ⚠️ プレースホルダー名と一致必須
    var email: String
}

// @Recordable が生成（store()メソッド）
extension User {
    /// 基本メソッド - 任意のパスで使用可能
    static func store(
        in container: RecordContainer,
        path: String
    ) -> RecordStore<User> {
        return container.store(for: User.self, path: path)
    }

    /// 型安全メソッド - #Subspace のパスを使用
    /// プレースホルダーがフィールド型に基づいてパラメータ化される
    static func store(
        in container: RecordContainer,
        accountID: String  // ← フィールド型(String)を使用
    ) -> RecordStore<User> {
        let path = "accounts/\(accountID)/users"
        return container.store(for: User.self, path: path)
    }
}

// 使用例
let userStore = User.store(in: container, accountID: "acct-001")
// パス: "accounts/acct-001/users"
```

#### 複雑な階層構造

```swift
@Recordable
struct Comment {
    #Subspace<Comment>("accounts/{accountID}/posts/{postID}/comments")

    @PrimaryKey var commentID: Int64
    var accountID: String  // ⚠️ プレースホルダー名と一致必須
    var postID: Int64      // ⚠️ プレースホルダー名と一致必須
    var text: String
}

// @Recordable が生成（store()メソッド）
extension Comment {
    /// 基本メソッド
    static func store(
        in container: RecordContainer,
        path: String
    ) -> RecordStore<Comment> {
        return container.store(for: Comment.self, path: path)
    }

    /// 型安全メソッド
    /// 各プレースホルダーはフィールド型に基づいてパラメータ化される
    static func store(
        in container: RecordContainer,
        accountID: String,  // ← String型
        postID: Int64       // ← Int64型
    ) -> RecordStore<Comment> {
        let path = "accounts/\(accountID)/posts/\(postID)/comments"
        return container.store(for: Comment.self, path: path)
    }
}

// 使用例
let commentStore = Comment.store(
    in: container,
    accountID: "acct-001",
    postID: 123
)
// パス: "accounts/acct-001/posts/123/comments"
```

#### #Subspaceなしの場合

```swift
@Recordable
struct SimpleUser {
    @PrimaryKey var userID: Int64
    var name: String
}

// @Recordable が生成（基本メソッドのみ）
extension SimpleUser {
    static func store(
        in container: RecordContainer,
        path: String
    ) -> RecordStore<SimpleUser> {
        return container.store(for: SimpleUser.self, path: path)
    }
}

// 使用例
let userStore = SimpleUser.store(in: container, path: "users")
```

#### プレースホルダー構文

**文字列テンプレート形式**: `{placeholder}`

- `{accountID}` → フィールド名と一致させる（推奨）
- `{tenantID}` → 複数のプレースホルダー可能
- 文字列解析のみ（KeyPathは使用しない）

**注意**: プレースホルダー名はあくまで引数名として使用されるだけで、実際のフィールドとの対応チェックは行われません。開発者が正しく対応させる責任があります。

---

## 🎯 Phase 4: 高度な機能

### @Relationship マクロ

**目的**: リレーションシップを定義（将来実装）

```swift
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var name: String

    @Relationship(deleteRule: .cascade)
    var orders: [Order]
}

@Recordable
struct Order {
    @PrimaryKey var orderID: Int64
    var amount: Decimal

    @Relationship(inverse: \.orders)
    var user: User?
}
```

---

## 🛠 実装戦略

### 1. マクロの実装順序

**Phase 1** (✅ 完了):
1. @Recordable - 基本的なコード生成
2. @PrimaryKey - プライマリキー指定
3. @Transient - 除外フィールド
4. @Attribute - フィールド属性

**Phase 2** (✅ 完了):
1. #Index - セカンダリインデックス
2. #Unique - ユニーク制約

**Phase 3** (🚧 実装中):
1. **#Subspace マクロ実装**:
   - Freestanding declaration macro
   - メタデータ生成: `__subspacePath`, `__subspacePlaceholders`
   - プレースホルダー解析ロジック

2. **@Recordable マクロ拡張**:
   - #Subspace メタデータの検出
   - 基本 `store(in:path:)` メソッドの生成（常に）
   - 型安全 `store(in:...placeholders...)` メソッドの生成（#Subspace存在時）
   - プレースホルダーから引数への変換ロジック

3. **連携テスト**:
   - #Subspace単体テスト
   - @Recordableとの統合テスト
   - 静的パス・動的パスの両方をテスト

**Phase 4**:
1. @Relationship - リレーションシップ
2. Protobuf自動生成プラグイン

### 2. テスト戦略

各Phaseで以下をテスト：
1. マクロ展開の正確性（SwiftSyntaxテスト）
2. 生成されたコードのコンパイル
3. Recordableプロトコル準拠の確認
4. 実際のCRUD操作
5. インデックスクエリ（Phase 2以降）

### 3. ドキュメント化

- マクロごとの使用例
- SwiftDataとの対応表
- マイグレーションガイド

---

## 📊 既存コードとの互換性

### 手動実装との共存

マクロを使わない手動実装も引き続きサポート：

```swift
// マクロ使用
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var email: String
}

// 手動実装（既存コード）
struct LegacyUser: Recordable {
    let userID: Int64
    let email: String

    static var recordTypeName: String { "LegacyUser" }
    static var primaryKeyFields: [String] { ["userID"] }
    // ... 他のメソッド手動実装
}
```

両方とも同じ`RecordContainer`で使用可能。

---

## ✅ Phase 0完了項目（既存実装）

以下は既に実装済み：

1. ✅ **Recordableプロトコル**
   - `recordTypeName`
   - `primaryKeyFields`
   - `allFields`
   - `toProtobuf()`/`fromProtobuf()`
   - `extractPrimaryKey()`

2. ✅ **RecordContainer**
   - `store(for:path:)` - パス文字列
   - `store(for:subspace:)` - Subspace直接
   - キャッシュ機能
   - メトリクス/ログサポート

3. ✅ **Schema**
   - SwiftData互換API
   - Entity管理
   - バージョン管理

4. ✅ **Subspace.fromPath()**
   - Firestore風パス解析
   - キャッシュ機能

5. ✅ **RecordStore<Record>**
   - CRUD操作
   - クエリ機能
   - インデックス管理

---

## 🚀 次のアクション

### Phase 3の実装（現在のタスク）

#### ステップ1: #Subspace マクロのメタデータ生成機能

1. **SubspaceMacro.swift の修正**
   - `generateStoreMethod()` を削除
   - `generateMetadata()` を実装
   - メタデータ生成:
     ```swift
     static let __subspacePath = "accounts/{accountID}/users"
     static let __subspacePlaceholders = ["accountID"]
     ```

2. **テスト**
   - メタデータが正しく生成されることを確認
   - プレースホルダー解析ロジックのテスト

#### ステップ2: @Recordable マクロの拡張

1. **RecordableMacro.swift の修正**
   - struct内の`#Subspace`メタデータを検出
   - 基本メソッド `store(in:path:)` を常に生成
   - メタデータ存在時、型安全メソッド `store(in:...placeholders...)` を生成

2. **実装ポイント**
   - `__subspacePath`と`__subspacePlaceholders`を探す
   - プレースホルダーから引数リストを生成
   - 文字列補間でパスを構築するコードを生成

3. **テスト**
   - #Subspaceなし: 基本メソッドのみ生成
   - #Subspaceあり（静的）: 両メソッド生成、引数なし
   - #Subspaceあり（動的）: 両メソッド生成、引数あり

#### ステップ3: 統合テスト

1. **実際の使用例でテスト**
   - マルチテナント構造
   - ネストした階層
   - 静的パスと動的パスの混在

2. **エッジケースのテスト**
   - プレースホルダーが0個
   - プレースホルダーが複数
   - 特殊文字を含むパス

---

## 📝 設計上の決定事項

### 1. なぜProtobufを隠蔽するのか？

**理由**:
- ユーザーはSwiftのコードのみを書きたい
- .protoファイルのメンテナンスは手間
- SwiftDataと同じユーザー体験

**実装**:
- マクロがSwiftコードから.protoを生成
- または、マクロが直接Protobuf互換のシリアライズコードを生成

### 2. なぜ#Subspaceマクロが必要か？

**理由**:
- Firestoreライクな階層構造をサポート
- マルチテナント対応を簡潔に記述
- 型安全な動的パス構築

**代替案との比較**:
- 手動でパス指定: `container.store(for: User.self, path: "accounts/\(id)/users")` ← 冗長、タイポしやすい
- マクロ使用: `User.store(in: container, accountID: id)` ← 簡潔、型安全

### 3. なぜ#SubspaceとRecordableを連携させるのか？

**理由**:
1. **`store()`メソッドは常に必要**
   - #Subspaceがなくても`store(in:path:)`は使いたい
   - すべての型で一貫したAPIを提供

2. **型安全性の確保**
   - #Subspaceのプレースホルダーから引数を自動生成
   - コンパイル時に引数の型チェック

3. **責務の分離**
   - #Subspace: メタデータ提供（パステンプレート、プレースホルダー）
   - @Recordable: メタデータを読み取り、適切なメソッド生成

**設計の流れ**:
```
#Subspace → メタデータ生成 → @Recordable が読み取り → store()メソッド生成
```

**実装上の利点**:
- SwiftDataの`#Index`/`#Unique`と同じパターン（freestanding → @Model が読み取り）
- 各マクロの責務が明確
- テストしやすい

### 4. Phase分割の理由

**理由**:
- 段階的に機能を追加し、各Phaseで安定性を確認
- Phase 0（基盤API）は既に完了
- Phase 1から順次実装

---

## 🔗 参考資料

- [SwiftData Documentation](https://developer.apple.com/documentation/swiftdata)
- [Swift Macros Documentation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/macros/)
- [SwiftSyntax](https://github.com/apple/swift-syntax)
- [FDB Record Layer (Java)](https://foundationdb.github.io/fdb-record-layer/)

---

**最終更新**: 2025-01-06
**次のステップ**: Phase 1 (@Recordableマクロ) の実装開始
