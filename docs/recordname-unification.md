# recordTypeName → recordName 統一

## 完了ステータス ✅

**日付**: 2025-01-15
**ビルド**: ✅ Passing
**テスト**: ✅ All 8 tests passed

---

## 問題

プロジェクト内で2つの似た名前が混在していました：

1. **`recordName`**: `@Recordable(recordName: "CustomName")` マクロ引数
2. **`recordTypeName`**: `Recordable` プロトコルの静的プロパティ

これは紛らわしく、一貫性に欠けていました。

---

## 実施内容

### 全箇所を `recordName` に統一

**置換対象**: 153箇所

```bash
# Sources
find Sources/FDBRecordLayer -name "*.swift" -exec sed -i '' 's/recordTypeName/recordName/g' {} \;

# Macros
find Sources/FDBRecordLayerMacros -name "*.swift" -exec sed -i '' 's/recordTypeName/recordName/g' {} \;

# Tests
find Tests -name "*.swift" -exec sed -i '' 's/recordTypeName/recordName/g' {} \;
```

---

## 変更内容

### 1. Recordable プロトコル

**Before**:
```swift
public protocol Recordable: Sendable {
    static var recordTypeName: String { get }  // ❌ 紛らわしい
}
```

**After**:
```swift
public protocol Recordable: Sendable {
    static var recordName: String { get }  // ✅ 統一
}
```

### 2. RecordAccess プロトコル

**Before**:
```swift
public protocol RecordAccess<Record>: Sendable {
    func recordTypeName(for record: Record) -> String  // ❌
}
```

**After**:
```swift
public protocol RecordAccess<Record>: Sendable {
    func recordName(for record: Record) -> String  // ✅
}
```

### 3. @Recordable マクロ生成コード

**Before**:
```swift
extension User: Recordable {
    public static var recordTypeName: String { "User" }  // ❌
}
```

**After**:
```swift
extension User: Recordable {
    public static var recordName: String { "User" }  // ✅
}
```

### 4. Schema.convertIndexDefinition

**Before**:
```swift
private static func convertIndexDefinition(
    _ definition: IndexDefinition,
    recordTypeName: String  // ❌
) -> Index {
    return Index(
        name: definition.name,
        type: indexType,
        rootExpression: keyExpression,
        recordTypes: Set([recordTypeName]),
        options: options
    )
}
```

**After**:
```swift
private static func convertIndexDefinition(
    _ definition: IndexDefinition,
    recordName: String  // ✅
) -> Index {
    return Index(
        name: definition.name,
        type: indexType,
        rootExpression: keyExpression,
        recordTypes: Set([recordName]),
        options: options
    )
}
```

### 5. Schema.init() 呼び出し

**Before**:
```swift
for type in types {
    let definitions = type.indexDefinitions
    for def in definitions {
        let index = Self.convertIndexDefinition(def, recordTypeName: type.recordTypeName)
        allIndexes.append(index)
    }
}
```

**After**:
```swift
for type in types {
    let definitions = type.indexDefinitions
    for def in definitions {
        let index = Self.convertIndexDefinition(def, recordName: type.recordName)
        allIndexes.append(index)
    }
}
```

---

## 影響範囲

### 変更ファイル数

- **Sources/FDBRecordLayer**: 約100箇所
- **Sources/FDBRecordLayerMacros**: 約10箇所
- **Tests**: 約43箇所

### 主要な変更箇所

| ファイル | 主な変更 |
|---------|---------|
| `Serialization/Recordable.swift` | プロトコル定義 `recordTypeName` → `recordName` |
| `Serialization/RecordAccess.swift` | メソッド名 `recordTypeName(for:)` → `recordName(for:)` |
| `Serialization/GenericRecordAccess.swift` | 実装更新 |
| `Schema/Schema.swift` | パラメータ名 `recordTypeName` → `recordName` |
| `Schema/Schema+Entity.swift` | Entity 生成で `type.recordName` 使用 |
| `Schema/RecordContainer.swift` | キャッシュキー生成で `Record.recordName` 使用 |
| `RecordableMacro.swift` | 変数名・生成コード更新 |
| `Query/TypedRecordQueryPlanner.swift` | クエリプランナーで `recordName` 使用 |

---

## 統一後のAPI

### マクロ使用

```swift
// デフォルト（型名を使用）
@Recordable
struct User {
    @PrimaryKey var userID: Int64
    var email: String
}
// → recordName = "User"

// カスタム名指定
@Recordable(recordName: "CustomUserName")
struct User {
    @PrimaryKey var userID: Int64
    var email: String
}
// → recordName = "CustomUserName"
```

### プロトコル実装

```swift
extension User: Recordable {
    public static var recordName: String { "User" }  // ✅ 統一された名前
    // ...
}
```

### 使用例

```swift
// Schema
let schema = Schema([User.self])
let entity = schema.entity(named: User.recordName)  // ✅ recordName

// RecordAccess
let access = GenericRecordAccess<User>()
let name = access.recordName(for: user)  // ✅ recordName(for:)

// IndexManager
let indexes = schema.indexes(for: User.recordName)  // ✅ recordName
```

---

## メリット

### 1. 一貫性の向上

**Before**:
```swift
@Recordable(recordName: "User")  // マクロ引数
struct User {
    // ...
}

User.recordTypeName  // ❌ プロトコルプロパティは異なる名前
```

**After**:
```swift
@Recordable(recordName: "User")  // マクロ引数
struct User {
    // ...
}

User.recordName  // ✅ 同じ名前！
```

### 2. 短くシンプル

- `recordTypeName` (14文字) → `recordName` (10文字)
- より短く、覚えやすい

### 3. 混乱の解消

開発者が「どちらを使えばいいのか？」と迷うことがなくなりました。

---

## 破壊的変更

この変更は既存コードに影響する破壊的変更ですが、プロジェクトはまだ開発段階のため問題ありません。

### 移行ガイド（将来のユーザー向け）

```swift
// Before
User.recordTypeName  // ❌

// After
User.recordName  // ✅
```

---

## テスト結果

### IndexCollectionTests

```
􁁛  Test "IndexDefinitions generation from #Index macros" passed after 0.001 seconds.
􁁛  Test "Unique index definition from #Unique macro" passed after 0.001 seconds.
􁁛  Test "No index definitions for types without macros" passed after 0.001 seconds.
􁁛  Test "Schema collects indexes from indexDefinitions" passed after 0.001 seconds.
􁁛  Test "Schema index lookup by name" passed after 0.001 seconds.
􁁛  Test "Schema indexes filtered by record type" passed after 0.001 seconds.
􁁛  Test "Multiple types with indexes" passed after 0.001 seconds.
􁁛  Test "Manual indexes merged with macro-declared indexes" passed after 0.001 seconds.
􁁛  Suite "Index Collection Tests" passed after 0.001 seconds.
􁁛  Test run with 8 tests in 1 suite passed after 0.001 seconds.
```

✅ **全8テストパス**

---

## Blocker修正との関係

この統一は、以下のBlocker修正と同時に実施されました：

**Blocker**: Schema.convertIndexDefinition が型名文字列に依存

**修正内容**:
1. `convertIndexDefinition` に `recordName: type.recordName` を渡す
2. `definition.recordType` (Self や MyModule.User) ではなく、確実な `type.recordName` を使用
3. これにより `schema.indexes(for:)` が正しく機能

```swift
// Before (Blocker)
let index = Self.convertIndexDefinition(def)
// → recordTypes: Set([definition.recordType])  // "Self" になる可能性

// After (Fixed)
let index = Self.convertIndexDefinition(def, recordName: type.recordName)
// → recordTypes: Set([recordName])  // 確実に "User" などの正しい名前
```

---

## Related Documentation

- [index-collection-implementation.md](index-collection-implementation.md) - Index収集実装
- [index-collection-summary.md](index-collection-summary.md) - Index収集サマリー
- [review-fixes.md](review-fixes.md) - 他の重大な修正

---

**最終更新**: 2025-01-15
**ステータス**: ✅ 完了
**ビルド**: ✅ Passing
**テスト**: ✅ 8/8 passed
**変更箇所**: 153箇所
**影響**: すべてのAPI（破壊的変更だが開発段階なので問題なし）
