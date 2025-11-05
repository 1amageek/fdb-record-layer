# ネストフィールドインデックス - 完全ガイド

## 概要

FDB Record Layer は **KeyPath 連鎖による型安全なネストフィールドインデックス**をサポートします。

ネストした構造体のフィールドに対して、型安全にインデックスを作成し、効率的にクエリを実行できます。

## 基本的な使い方

### シンプルな例

```swift
import FDBRecordLayer

@Recordable
struct Address {
    @PrimaryKey var id: Int64
    var street: String
    var city: String
    var country: String
}

@Recordable
struct Person {
    // ✅ ネストフィールドインデックス（KeyPath連鎖）
    #Index<Person>([\\.address.city])
    #Index<Person>([\\.address.country, \\.age])

    @PrimaryKey var personID: Int64
    var name: String
    var age: Int32
    var address: Address  // ネストした型
}
```

### 生成されるインデックス

上記のコードから以下のインデックスが生成されます：

1. **Person_address_city_index**
   - フィールド: `["address.city"]`
   - 用途: 都市名で人物を検索

2. **Person_address_country_age_index**
   - フィールド: `["address.country", "age"]`
   - 用途: 国と年齢の複合条件で検索

## 技術的詳細

### 動作メカニズム

#### 1. KeyPath 連鎖の解析

```swift
\Person.address.city  →  ["address", "city"]  →  "address.city"
```

マクロ展開時に KeyPath のすべてのコンポーネントを抽出し、ドット区切りのパスに変換します。

#### 2. extractField の拡張

生成される `extractField` メソッドはネストパスをサポートします：

```swift
public func extractField(_ fieldName: String) -> [any TupleElement] {
    // ネストパスを検出: "address.city"
    if fieldName.contains(".") {
        let components = fieldName.split(separator: ".", maxSplits: 1)
        let firstField = String(components[0])      // "address"
        let remainingPath = String(components[1])   // "city"

        switch firstField {
        case "address":
            return self.address.extractField(remainingPath)  // 再帰的に委譲
        default:
            return []
        }
    }

    // 通常のフィールドアクセス
    switch fieldName {
    case "name": return [self.name]
    case "age": return [Int64(self.age)]
    default: return []
    }
}
```

#### 3. FoundationDB インデックスキー

インデックスは以下の形式で FoundationDB に格納されます：

```
Key:   ["Person", "address.city", "San Francisco", 100]
         ^^^^^^   ^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^  ^^^
         型名     インデックス名    フィールド値      主キー

Value: <empty>
```

## 使用例

### 例1: 都市名で検索

```swift
@Recordable
struct User {
    #Index<User>([\\.address.city])

    @PrimaryKey var userID: Int64
    var name: String
    var address: Address
}

// RecordStore でのクエリ（イメージ）
let tokyoUsers = try recordStore.query(
    recordType: User.self,
    indexName: "User_address_city_index",
    value: "Tokyo"
)
```

### 例2: 複合インデックス

```swift
@Recordable
struct Employee {
    #Index<Employee>([\\.office.country, \\.department])

    @PrimaryKey var employeeID: Int64
    var name: String
    var office: Address
    var department: String
}

// "日本のエンジニアリング部門"を検索
let jpEngineers = try recordStore.query(
    recordType: Employee.self,
    indexName: "Employee_office_country_department_index",
    values: ["Japan", "Engineering"]
)
```

### 例3: 多段ネスト

```swift
@Recordable
struct Company {
    @PrimaryKey var companyID: Int64
    var name: String
    var ceo: Person  // Person の中に Address がある
}

@Recordable
struct Department {
    // 3段ネスト: department.company.ceo.address.city
    #Index<Department>([\\.company.ceo.address.city])

    @PrimaryKey var deptID: Int64
    var name: String
    var company: Company
}
```

### 例4: Optional ネストフィールド

```swift
@Recordable
struct Contact {
    #Index<Contact>([\\.workAddress.city])  // Optional でもOK

    @PrimaryKey var contactID: Int64
    var name: String
    var workAddress: Address?  // Optional
}

// Optional の場合、値が nil なら空配列を返す
let city = contact.extractField("workAddress.city")  // [] or ["Tokyo"]
```

### 例5: ユニーク制約

```swift
@Recordable
struct Account {
    #Unique<Account>([\\.profile.email])  // ネストフィールドのユニーク制約

    @PrimaryKey var accountID: Int64
    var username: String
    var profile: UserProfile
}

@Recordable
struct UserProfile {
    @PrimaryKey var profileID: Int64
    var email: String
    var displayName: String
}
```

## サポートされる型

### ✅ インデックス可能な型

ネストフィールドインデックスは、**プリミティブ型**のフィールドのみサポートします：

- `Int32`, `Int64`, `UInt32`, `UInt64`
- `Bool`
- `String`
- `Data`
- `Double`, `Float`

### ❌ インデックス不可能な型

以下はインデックスに使用できません（FoundationDB Tuple の制限）：

- カスタム型（さらにネストした構造体）
- 配列型（`[String]`, `[Int]` など）
- Optional 内の Optional（`String??`）

### 例：制限のあるケース

```swift
@Recordable
struct BlogPost {
    #Index<BlogPost>([\\.author.name])         // ✅ OK: String
    #Index<BlogPost>([\\.author.address.city]) // ✅ OK: String (多段ネスト)

    // ❌ これらはコンパイルエラーまたは実行時に空配列
    // #Index<BlogPost>([\\.tags])                    // ❌ 配列型
    // #Index<BlogPost>([\\.author.friends])          // ❌ 配列型
    // #Index<BlogPost>([\\.author.company])          // ❌ カスタム型

    @PrimaryKey var postID: Int64
    var title: String
    var author: Author
    var tags: [String]  // インデックス不可
}

@Recordable
struct Author {
    @PrimaryKey var authorID: Int64
    var name: String             // ✅ インデックス可能
    var address: Address         // ネストの起点としてのみ使用
    var friends: [Author]        // ❌ インデックス不可
}
```

## パフォーマンス考慮事項

### ストレージ効率

**良いケース**:
```swift
// 少数の明確なフィールドにインデックス
#Index<User>([\\.address.city])
#Index<User>([\\.address.country])
```

**悪いケース**:
```swift
// 過剰なインデックス（カーディナリティが高すぎる）
#Index<User>([\\.address.street])  // 各ユーザーで一意になりやすい
#Index<User>([\\.lastLoginTimestamp])  // 常に変化する
```

### クエリ効率

**効率的**:
```swift
// 都市は限られた値（東京、大阪、福岡 etc.）
#Index<User>([\\.address.city])

// Query: "東京のユーザー" → インデックススキャン効率的
```

**非効率**:
```swift
// 郵便番号はほぼ一意（100-0001, 100-0002, ...）
#Index<User>([\\.address.zipCode])

// Query: 特定の郵便番号 → ほぼ主キー検索と同等
// → ユニーク制約として使う方が適切
#Unique<User>([\\.address.zipCode])
```

## ベストプラクティス

### 1. インデックス対象の選定

✅ **推奨**:
- 検索条件として頻繁に使われるフィールド
- カーディナリティが低〜中程度（都市、国、カテゴリー etc.）
- 変更頻度が低い

❌ **避けるべき**:
- ほぼ一意な値（住所全文、タイムスタンプ etc.）
- 頻繁に変更されるフィールド
- 使われないクエリパターン

### 2. 正規化 vs ネスト

**ネストを使う場合**:
```swift
// ✅ 住所情報はユーザーと密結合
@Recordable
struct User {
    #Index<User>([\\.homeAddress.city])

    @PrimaryKey var userID: Int64
    var name: String
    var homeAddress: Address  // ネストでOK
}
```

**正規化を使う場合**:
```swift
// ✅ 会社情報は独立したエンティティ
@Recordable
struct Employee {
    #Index<Employee>([\\.companyID])  // ID参照

    @PrimaryKey var employeeID: Int64
    var name: String
    var companyID: Int64  // 正規化（ID参照）
}

@Recordable
struct Company {
    #Index<Company>([\\.city])

    @PrimaryKey var companyID: Int64
    var name: String
    var city: String
}
```

### 3. インデックス命名

マクロが自動生成する名前をカスタマイズできます：

```swift
#Index<Person>(
    [\\.address.city],
    name: "people_by_city"  // カスタム名
)

#Index<Person>(
    [\\.address.country, \\.age],
    name: "people_country_age_idx"
)
```

## トラブルシューティング

### Q1: extractField が空配列を返す

```swift
let city = person.extractField("address.city")
// 結果: []
```

**原因**:
- フィールド名のタイプミス
- Optional フィールドが nil
- 配列型またはカスタム型を直接取得しようとしている

**解決策**:
```swift
// 正しいフィールド名を確認
let city = person.extractField("address.city")  // "city" not "City"

// Optional の確認
if let address = person.address {
    let city = address.extractField("city")
}

// デバッグ
print(Person.allFields)  // 利用可能なフィールド一覧
```

### Q2: コンパイルエラー: "Cannot find 'X' in scope"

```swift
#Index<Person>([\\.address.city])
// Error: Cannot find 'city' in scope
```

**原因**:
- Address 型の定義が見つからない
- フィールド名が間違っている

**解決策**:
- Address が @Recordable で定義されているか確認
- フィールド名のスペルミスを確認

### Q3: インデックスが使われない（RecordStore）

**原因**:
- インデックス定義が RecordMetaData に登録されていない

**解決策**:
```swift
// RecordMetaData にインデックスを登録
metaData.addIndex(Person.Person_address_city_index)
```

## まとめ

### ✅ ネストフィールドインデックスの利点

1. **型安全**: KeyPath 連鎖でコンパイル時チェック
2. **表現力**: ネストした構造を直感的にモデリング
3. **効率性**: FoundationDB インデックスで高速クエリ
4. **保守性**: リファクタリング時の安全性

### 🎯 使用ガイドライン

- ネストは1〜3段程度に抑える
- プリミティブ型のフィールドにのみインデックス
- カーディナリティを考慮してインデックス設計
- 頻繁なクエリパターンに基づいて選定

### 📚 関連ドキュメント

- [COMPLETE_IMPLEMENTATION_SUMMARY.md](./COMPLETE_IMPLEMENTATION_SUMMARY.md) - 完全実装の概要
- [Examples/NestedFieldIndexExample.swift](./Examples/NestedFieldIndexExample.swift) - 詳細なサンプルコード
- [IMPLEMENTATION_STATUS.md](./IMPLEMENTATION_STATUS.md) - 実装ステータス
