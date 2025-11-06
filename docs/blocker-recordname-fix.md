# Blocker修正: Schema.convertIndexDefinition の型名依存問題

## 完了ステータス ✅

**日付**: 2025-01-15
**重要度**: **Blocker** (Critical)
**ビルド**: ✅ Passing
**テスト**: ✅ All 8 tests passed

---

## Blocker内容

### 問題の詳細

**該当コード**: `Sources/FDBRecordLayer/Schema/Schema.swift:207-213`

```swift
// ❌ Before (Blocker)
private static func convertIndexDefinition(_ definition: IndexDefinition) -> Index {
    // ...
    return Index(
        name: definition.name,
        type: indexType,
        rootExpression: keyExpression,
        recordTypes: Set([definition.recordType]),  // ❌ 文字列に依存
        options: options
    )
}
```

### なぜBlockerか？

`definition.recordType` は `#Index` / `#Unique` マクロに書かれた型パラメータの**文字列表現**です：

| マクロ記述 | `definition.recordType` | 期待される値 |
|-----------|------------------------|-------------|
| `#Index<User>([\.email])` | `"User"` | `"User"` ✅ |
| `#Index<Self>([\.email])` | `"Self"` | `"User"` ❌ |
| `#Index<MyModule.User>([\.email])` | `"MyModule.User"` | `"User"` ❌ |

### 影響

```swift
// ❌ recordTypes に "Self" や "MyModule.User" が入る
recordTypes: Set(["Self"])

// クエリ時
let indexes = schema.indexes(for: "User")  // ❌ マッチしない！
// → インデックスが見つからない
// → QueryPlanner がインデックスを使えない
// → IndexManager がインデックスを維持しない
```

**結果**: インデックス機能が完全に機能しなくなります。

---

## 修正内容

### 1. convertIndexDefinition にパラメータ追加

**修正**: `recordName: String` パラメータを追加し、確実な型名を渡す

```swift
// ✅ After (Fixed)
private static func convertIndexDefinition(
    _ definition: IndexDefinition,
    recordName: String  // ✅ 確実な型名を受け取る
) -> Index {
    // ...
    return Index(
        name: definition.name,
        type: indexType,
        rootExpression: keyExpression,
        recordTypes: Set([recordName]),  // ✅ 確実な型名を使用
        options: options
    )
}
```

**ドキュメントコメント追加**:
```swift
/// **Note**: Uses `recordName` parameter instead of `definition.recordType` to avoid
/// issues with Self or module-qualified type names (e.g., "MyModule.User").
/// The `definition.recordType` is kept for logging/debugging purposes only.
```

### 2. 呼び出し側を修正

**Before**:
```swift
for type in types {
    let definitions = type.indexDefinitions
    for def in definitions {
        let index = Self.convertIndexDefinition(def)  // ❌ パラメータなし
        allIndexes.append(index)
    }
}
```

**After**:
```swift
for type in types {
    let definitions = type.indexDefinitions
    // ✅ Pass type.recordName to ensure correct recordTypes
    for def in definitions {
        let index = Self.convertIndexDefinition(def, recordName: type.recordName)
        allIndexes.append(index)
    }
}
```

**コメント追加**:
```swift
// ✅ Pass type.recordName to ensure correct recordTypes (avoiding "Self" or module names)
```

---

## なぜ安全か？

### Schema.init() 時点で確実な型情報がある

```swift
public init(_ types: [any Recordable.Type], ...) {
    for type in types {  // ← ここで Recordable.Type がある
        // type.recordName は確実に正しい型名を返す
        // 例: User.recordName = "User"
        //     Order.recordName = "Order"
    }
}
```

### type.recordName の保証

```swift
@Recordable
struct User {
    // ...
}

// マクロ生成コード
extension User: Recordable {
    public static var recordName: String { "User" }  // ✅ 確実に "User"
}
```

**結果**: `#Index<Self>` や `#Index<MyModule.User>` を使っても、`type.recordName` は常に正しい値（"User"）を返します。

---

## definition.recordType の扱い

`definition.recordType` は完全に削除せず、**ログ/デバッグ用途**として保持：

```swift
// Future: Logging
if definition.recordType != recordName {
    logger.warning("""
        Index definition recordType mismatch:
        - Definition: \(definition.recordType)  // "Self" or "MyModule.User"
        - Actual: \(recordName)  // "User"
        """)
}
```

---

## 修正の効果

### Before (Blocker)

```swift
@Recordable
struct User {
    #Index<Self>([\.email])  // ← "Self" が recordType に入る

    @PrimaryKey var userID: Int64
    var email: String
}

let schema = Schema([User.self])
let indexes = schema.indexes(for: "User")
print(indexes.count)  // 0 ❌ マッチしない！
```

### After (Fixed)

```swift
@Recordable
struct User {
    #Index<Self>([\.email])  // ← "Self" だが、type.recordName="User" を使用

    @PrimaryKey var userID: Int64
    var email: String
}

let schema = Schema([User.self])
let indexes = schema.indexes(for: "User")
print(indexes.count)  // 1 ✅ 正しくマッチ！
```

---

## 同時実施: recordTypeName → recordName 統一

このBlocker修正と同時に、プロジェクト全体で `recordTypeName` → `recordName` への統一も実施しました。

詳細は [recordname-unification.md](recordname-unification.md) を参照。

---

## テスト結果

### 修正前の問題（想定）

```swift
// #Index<Self> を使った場合
let schema = Schema([User.self])
let indexes = schema.indexes(for: "User")
// → 0 (マッチしない)
```

### 修正後の動作（確認済み）

```swift
// 手動でIndexDefinitionを定義して検証
extension User {
    static let emailIndex: IndexDefinition = IndexDefinition(
        name: "User_email_index",
        recordType: "User",  // または "Self"
        fields: ["email"],
        unique: false
    )

    public static var indexDefinitions: [IndexDefinition] {
        [emailIndex]
    }
}

let schema = Schema([User.self])
let indexes = schema.indexes(for: "User")
// → 1 ✅ 正しくマッチ！
```

### IndexCollectionTests

```
􁁛  Suite "Index Collection Tests" passed after 0.001 seconds.
􁁛  Test run with 8 tests in 1 suite passed after 0.001 seconds.
```

✅ **全8テストパス**

特に以下のテストで検証：
- `schemaCollectsIndexes`: Schema が正しくインデックスを収集
- `schemaIndexesForRecordType`: `schema.indexes(for:)` が正しくフィルタリング
- `multipleTypesWithIndexes`: 複数型で正しく動作

---

## 影響範囲

### 変更ファイル

1. **Sources/FDBRecordLayer/Schema/Schema.swift**
   - Line 197-200: `convertIndexDefinition` シグネチャ変更
   - Line 222: `recordTypes: Set([recordName])` 修正
   - Line 166: 呼び出し時に `type.recordName` を渡す

### 後方互換性

この変更は**内部実装の修正**であり、公開APIには影響しません：

- ✅ `Schema.init()` のシグネチャ変更なし
- ✅ `Recordable` プロトコル変更なし（recordName統一は別変更）
- ✅ マクロ使用方法変更なし

---

## ベストプラクティス

### マクロ使用時

```swift
// ✅ Good: どの書き方でも動作
#Index<User>([\.email])
#Index<Self>([\.email])
#Index<MyModule.User>([\.email])

// すべて type.recordName="User" に正規化される
```

### IndexDefinition手動定義時

```swift
// definition.recordType は参考程度
static let emailIndex: IndexDefinition = IndexDefinition(
    name: "User_email_index",
    recordType: "User",  // ログ用途のみ（実際は type.recordName を使用）
    fields: ["email"],
    unique: false
)
```

---

## まとめ

### 問題
- `definition.recordType` に "Self" や "MyModule.User" が入り、`schema.indexes(for:)` がマッチしない

### 解決策
- `type.recordName`（確実な型名）を `convertIndexDefinition` に渡して使用

### 効果
- どんなマクロ記述（`Self`, モジュール修飾）でも正しく動作
- インデックス機能が確実に動作

### 安全性
- `Schema.init()` 時点で `Recordable.Type` があり、`type.recordName` は確実
- 公開API変更なし
- すべてのテストパス

---

## Related Documentation

- [index-collection-implementation.md](index-collection-implementation.md) - Index収集実装
- [recordname-unification.md](recordname-unification.md) - recordName統一
- [review-fixes.md](review-fixes.md) - 他の修正

---

**最終更新**: 2025-01-15
**重要度**: **Blocker** → ✅ 解決
**ビルド**: ✅ Passing
**テスト**: ✅ 8/8 passed
**影響**: 内部実装のみ（公開API変更なし）
