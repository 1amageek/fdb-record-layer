# MetaDataEvolutionValidator Design Document

## 概要

MetaDataEvolutionValidatorは、RecordMetaDataのスキーマ進化における安全性を保証するための検証システムです。異なるバージョンのスキーマ間で互換性のない変更を検出し、データの整合性を守ります。

## 設計目標

### 1. 安全なスキーマ進化

- レコードタイプの削除を防止
- フィールドの削除・型変更を検出
- プライマリキー構造の変更を検出
- インデックスの互換性検証

### 2. FormerIndexによる履歴管理

- 削除されたインデックスの記録
- インデックス名の再利用防止
- スキーマ進化の履歴保持

### 3. 柔軟な検証ポリシー

- `allowIndexRebuilds`フラグによる制御
- 段階的なマイグレーション対応
- 詳細なエラー報告

## アーキテクチャ

### コンポーネント構成

```
┌───────────────────────────────────────────────────┐
│ MetaDataEvolutionValidator                        │
│                                                    │
│  ┌─────────────────────────────────────────┐     │
│  │ Validation Engine                       │     │
│  │  - validateRecordTypes()                │     │
│  │  - validateIndexes()                    │     │
│  │  - validateFormerIndexes()              │     │
│  └─────────────────────────────────────────┘     │
│                                                    │
│  ┌─────────────────────────────────────────┐     │
│  │ Compatibility Checkers                   │     │
│  │  - areKeyExpressionsCompatible()        │     │
│  │  - areSubspaceKeysCompatible()          │     │
│  └─────────────────────────────────────────┘     │
│                                                    │
│  ┌─────────────────────────────────────────┐     │
│  │ Error Collection                         │     │
│  │  - ValidationError                       │     │
│  │  - ValidationResult                      │     │
│  └─────────────────────────────────────────┘     │
└───────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
┌──────────────────┐      ┌──────────────────┐
│  Old Metadata    │      │  New Metadata    │
│  (Version N)     │      │  (Version N+1)   │
└──────────────────┘      └──────────────────┘
```

## 主要コンポーネント

### 1. ValidationError

検出された互換性エラーを表現します。

```swift
public struct ValidationError: Error, Sendable {
    public enum Category: String, Sendable {
        case recordTypeRemoved
        case fieldRemoved
        case fieldTypeChanged
        case primaryKeyChanged
        case indexFormatChanged
        case indexRemovedWithoutFormer
        case formerIndexConflict
        case indexSubspaceConflict
    }

    public let category: Category
    public let recordTypeName: String?
    public let fieldName: String?
    public let indexName: String?
    public let message: String
}
```

**設計の意図**:
- カテゴリ別のエラー分類
- コンテキスト情報の保持（レコードタイプ名、フィールド名、インデックス名）
- 人間が読みやすいメッセージ

### 2. ValidationResult

検証結果の集約情報を提供します。

```swift
public struct ValidationResult: Sendable {
    public let isValid: Bool
    public let errors: [ValidationError]
    public var errorCount: Int { errors.count }
}
```

**設計の意図**:
- すべてのエラーを一度に報告
- 部分的な進化の検証を可能にする
- エラーの優先順位付けに使用可能

### 3. MetaDataEvolutionValidator

中核となるバリデータクラスです。

```swift
public final class MetaDataEvolutionValidator: Sendable {
    private let oldMetaData: RecordMetaData
    private let newMetaData: RecordMetaData
    private let allowIndexRebuilds: Bool

    public init(
        oldMetaData: RecordMetaData,
        newMetaData: RecordMetaData,
        allowIndexRebuilds: Bool = false
    ) throws

    public func validate() -> ValidationResult
    public func validateAndThrow() throws
}
```

**設計の意図**:
- 不変（immutable）な検証器
- スレッドセーフ（Sendable準拠）
- 明示的なポリシー設定（allowIndexRebuilds）

## 検証ルール

### 1. レコードタイプの検証

#### ルール1.1: レコードタイプの削除禁止

**理由**: 既存のデータが読み取り不能になる

**検出方法**:
```swift
for (oldTypeName, _) in oldRecordTypes {
    guard newRecordTypes[oldTypeName] != nil else {
        // Error: Record type removed
    }
}
```

**エラー例**:
```
[Record type removed] RecordType: Order
Record type 'Order' was removed. Record types cannot be removed.
```

#### ルール1.2: プライマリキーの変更禁止

**理由**: 既存レコードのキーが無効になる

**検出方法**:
```swift
if !areKeyExpressionsCompatible(oldType.primaryKey, newType.primaryKey) {
    // Error: Primary key changed
}
```

### 2. フィールドの検証

#### ルール2.1: プライマリキーフィールドの削除禁止

**理由**: レコードの識別ができなくなる

**検出方法**:
```swift
let oldPrimaryKeyFields = extractFieldNames(from: oldType.primaryKey)
let newPrimaryKeyFields = extractFieldNames(from: newType.primaryKey)

for oldField in oldPrimaryKeyFields {
    if !newPrimaryKeyFields.contains(oldField) {
        // Error: Primary key field removed
    }
}
```

**将来の拡張**:
- Protobuf descriptorの比較
- すべてのフィールドの型検証
- `optional`/`required`の変更検出

### 3. インデックスの検証

#### ルール3.1: インデックス削除時はFormerIndexが必須

**理由**: インデックス名の再利用を防止

**検出方法**:
```swift
for (oldIndexName, _) in oldIndexes {
    if newIndexes[oldIndexName] == nil {
        // Index was removed
        if !newFormerIndexes.keys.contains(oldIndexName) {
            // Error: Index removed without FormerIndex
        }
    }
}
```

**正しいマイグレーションパターン**:
```swift
// Version 1: Index exists
let emailIndex = Index(name: "user_by_email", ...)

// Version 2: Remove index, add FormerIndex
let formerIndex = FormerIndex(
    name: "user_by_email",
    addedVersion: 1,
    removedVersion: 2
)

let newMetaData = try RecordMetaData(
    version: 2,
    recordTypes: [userType],
    indexes: [],  // Index removed
    formerIndexes: [formerIndex]  // FormerIndex added
)
```

#### ルール3.2: インデックスタイプの変更（条件付き）

**理由**: ディスクフォーマットが変わる

**検出方法**:
```swift
if oldIndex.type != newIndex.type {
    if !allowIndexRebuilds {
        // Error: Index type changed
    }
}
```

**`allowIndexRebuilds = true`の場合**:
- インデックスの再構築を前提とした変更を許可
- OnlineIndexerによる段階的な再構築を想定

#### ルール3.3: インデックス式の変更（条件付き）

**理由**: インデックスキーの構造が変わる

**検出方法**:
```swift
if !areKeyExpressionsCompatible(oldIndex.rootExpression, newIndex.rootExpression) {
    if !allowIndexRebuilds {
        // Error: Index expression changed
    }
}
```

#### ルール3.4: サブスペースキーの変更（条件付き）

**理由**: ディスク上の物理的な位置が変わる

**検出方法**:
```swift
if !areSubspaceKeysCompatible(oldIndex.subspaceTupleKey, newIndex.subspaceTupleKey) {
    if !allowIndexRebuilds {
        // Error: Subspace key changed
    }
}
```

### 4. FormerIndexの検証

#### ルール4.1: FormerIndexとアクティブインデックスの重複禁止

**理由**: 名前の衝突を防止

**検出方法**:
```swift
for (formerIndexName, _) in newFormerIndexes {
    if newIndexes.keys.contains(formerIndexName) {
        // Error: FormerIndex conflicts with active index
    }
}
```

#### ルール4.2: 以前のFormerIndexとの衝突検出

**理由**: 削除されたインデックス名の再利用を防止

**検出方法**:
```swift
for (newIndexName, _) in newIndexes {
    if oldFormerIndexes.keys.contains(newIndexName) {
        // Error: New index conflicts with former index
    }
}
```

## 使用方法

### 基本的な使用例

```swift
import FDBRecordLayer

// 旧バージョンのメタデータ
let oldMetaData = try RecordMetaData(
    version: 1,
    recordTypes: [userType, orderType],
    indexes: [emailIndex, ageIndex]
)

// 新バージョンのメタデータ
let newMetaData = try RecordMetaData(
    version: 2,
    recordTypes: [userType, orderType],  // 変更なし
    indexes: [emailIndex],  // ageIndexを削除
    formerIndexes: [
        FormerIndex(name: "age_index", addedVersion: 1, removedVersion: 2)
    ]
)

// 検証
let validator = try MetaDataEvolutionValidator(
    oldMetaData: oldMetaData,
    newMetaData: newMetaData
)

let result = validator.validate()

if result.isValid {
    print("✅ Schema evolution is valid")
} else {
    print("❌ Schema evolution has errors:")
    for error in result.errors {
        print("  - \(error)")
    }
}
```

### インデックス再構築を許可する例

```swift
// インデックスタイプを変更（valueからcount）
let oldAgeIndex = Index(
    name: "user_by_age",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "age")
)

let newAgeIndex = Index(
    name: "user_by_age",
    type: .count,  // タイプ変更
    rootExpression: FieldKeyExpression(fieldName: "age")
)

// allowIndexRebuilds = trueで検証
let validator = try MetaDataEvolutionValidator(
    oldMetaData: oldMetaData,
    newMetaData: newMetaData,
    allowIndexRebuilds: true  // インデックス再構築を許可
)

let result = validator.validate()

if result.isValid {
    print("✅ Valid with index rebuild required")
    // OnlineIndexerでインデックスを再構築
}
```

### 静的メソッドを使った簡潔な検証

```swift
let result = try MetaDataEvolutionValidator.validateEvolution(
    from: oldMetaData,
    to: newMetaData,
    allowIndexRebuilds: false
)

if !result.isValid {
    for error in result.errors {
        print("Error: \(error)")
    }
    throw RecordLayerError.schemaEvolutionFailed
}
```

### 例外を投げる検証

```swift
do {
    try validator.validateAndThrow()
    // 検証成功
    print("Schema evolution is valid")
} catch let error as MetaDataEvolutionValidator.ValidationError {
    // 最初のエラーが投げられる
    print("Validation failed: \(error)")
}
```

## スキーマ進化のベストプラクティス

### 1. 安全な変更パターン

#### ✅ レコードタイプの追加

```swift
// Version 1
let v1 = try RecordMetaData(
    version: 1,
    recordTypes: [userType],
    indexes: []
)

// Version 2: 新しいレコードタイプを追加
let v2 = try RecordMetaData(
    version: 2,
    recordTypes: [userType, orderType],  // ✅ 追加はOK
    indexes: []
)
```

#### ✅ インデックスの追加

```swift
// Version 2: 新しいインデックスを追加
let v2 = try RecordMetaData(
    version: 2,
    recordTypes: [userType],
    indexes: [emailIndex, ageIndex]  // ✅ 追加はOK
)
```

#### ✅ フィールドの追加（Protobufレベル）

```protobuf
// Version 1
message User {
    int64 userID = 1;
    string name = 2;
}

// Version 2: フィールド追加
message User {
    int64 userID = 1;
    string name = 2;
    string email = 3;  // ✅ 追加はOK
}
```

#### ✅ インデックスの削除（FormerIndex付き）

```swift
// Version 1
let v1 = try RecordMetaData(
    version: 1,
    recordTypes: [userType],
    indexes: [oldEmailIndex]
)

// Version 2: FormerIndexを使って削除
let v2 = try RecordMetaData(
    version: 2,
    recordTypes: [userType],
    indexes: [],  // インデックスを削除
    formerIndexes: [
        FormerIndex(name: "old_email_index", addedVersion: 1, removedVersion: 2)
    ]  // ✅ FormerIndexを追加
)
```

### 2. 危険な変更パターン

#### ❌ レコードタイプの削除

```swift
// Version 1
let v1 = try RecordMetaData(
    version: 1,
    recordTypes: [userType, orderType],
    indexes: []
)

// Version 2: レコードタイプを削除
let v2 = try RecordMetaData(
    version: 2,
    recordTypes: [userType],  // ❌ orderTypeを削除（エラー）
    indexes: []
)

// ValidationError: recordTypeRemoved
```

#### ❌ プライマリキーの変更

```swift
// Version 1: 単一フィールドのプライマリキー
let v1UserType = RecordType(
    name: "User",
    primaryKey: FieldKeyExpression(fieldName: "userID")
)

// Version 2: 複合プライマリキーに変更
let v2UserType = RecordType(
    name: "User",
    primaryKey: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "tenantID"),
        FieldKeyExpression(fieldName: "userID")
    ])  // ❌ プライマリキー構造を変更（エラー）
)

// ValidationError: primaryKeyChanged
```

#### ❌ インデックスの削除（FormerIndexなし）

```swift
// Version 1
let v1 = try RecordMetaData(
    version: 1,
    recordTypes: [userType],
    indexes: [emailIndex]
)

// Version 2: FormerIndexなしで削除
let v2 = try RecordMetaData(
    version: 2,
    recordTypes: [userType],
    indexes: []  // ❌ FormerIndexなしで削除（エラー）
)

// ValidationError: indexRemovedWithoutFormer
```

#### ❌ インデックスタイプの変更（allowIndexRebuilds=false）

```swift
// Version 1
let oldIndex = Index(name: "age_idx", type: .value, ...)

// Version 2: タイプを変更
let newIndex = Index(name: "age_idx", type: .count, ...)  // ❌ タイプ変更（エラー）

let validator = try MetaDataEvolutionValidator(
    oldMetaData: v1,
    newMetaData: v2,
    allowIndexRebuilds: false  // 再構築を許可しない
)

// ValidationError: indexFormatChanged
```

### 3. 段階的なマイグレーション戦略

#### パターン1: インデックスの置き換え

```swift
// Step 1 (Version 2): 新しいインデックスを追加
let v2 = try RecordMetaData(
    version: 2,
    recordTypes: [userType],
    indexes: [oldEmailIndex, newEmailIndex]  // 両方存在
)

// OnlineIndexerでnewEmailIndexを構築
let indexer = try await OnlineIndexer(...)
try await indexer.buildIndex()

// Step 2 (Version 3): 古いインデックスを削除
let v3 = try RecordMetaData(
    version: 3,
    recordTypes: [userType],
    indexes: [newEmailIndex],  // 新しいインデックスのみ
    formerIndexes: [
        FormerIndex(name: "old_email_index", addedVersion: 1, removedVersion: 3)
    ]
)
```

#### パターン2: レコードタイプの非推奨化（将来の拡張）

```swift
// 注: 現在の実装では未サポート

// Step 1: レコードタイプをdeprecated扱いにする
// （新規書き込みを停止、読み取りのみ許可）

// Step 2: 既存データをマイグレーション

// Step 3: レコードタイプを削除
// （すべてのデータが移行済みの場合のみ）
```

## 互換性チェックの詳細

### KeyExpression互換性

```swift
private func areKeyExpressionsCompatible(
    _ old: KeyExpression,
    _ new: KeyExpression
) -> Bool {
    // 1. 型の一致チェック
    if type(of: old) != type(of: new) {
        return false
    }

    // 2. FieldKeyExpression
    if let oldField = old as? FieldKeyExpression,
       let newField = new as? FieldKeyExpression {
        return oldField.fieldName == newField.fieldName
    }

    // 3. ConcatenateKeyExpression
    if let oldConcat = old as? ConcatenateKeyExpression,
       let newConcat = new as? ConcatenateKeyExpression {
        guard oldConcat.children.count == newConcat.children.count else {
            return false
        }
        return zip(oldConcat.children, newConcat.children).allSatisfy { pair in
            areKeyExpressionsCompatible(pair.0, pair.1)
        }
    }

    // 4. NestExpression
    if let oldNest = old as? NestExpression,
       let newNest = new as? NestExpression {
        return oldNest.parentField == newNest.parentField &&
               areKeyExpressionsCompatible(oldNest.child, newNest.child)
    }

    // 5. EmptyKeyExpression
    if old is EmptyKeyExpression && new is EmptyKeyExpression {
        return true
    }

    // Unknown types: assume compatible
    return true
}
```

### Subspaceキー互換性

```swift
private func areSubspaceKeysCompatible(
    _ old: (any TupleElement)?,
    _ new: (any TupleElement)?
) -> Bool {
    // Both nil → compatible
    if old == nil && new == nil {
        return true
    }

    // One is nil → incompatible
    guard let oldKey = old, let newKey = new else {
        return false
    }

    // Compare string representations
    // (simplified; full implementation would compare actual values)
    return String(describing: oldKey) == String(describing: newKey)
}
```

## Java版との比較

| 機能 | Java版 | Swift版（このプロジェクト） |
|------|--------|----------------------------|
| **Record Type削除検出** | ✅ | ✅ |
| **Field削除検出** | ✅（Protobuf Descriptor比較） | ⚠️ プライマリキーフィールドのみ |
| **Primary Key変更検出** | ✅ | ✅ |
| **Index削除検出** | ✅ | ✅ |
| **FormerIndex管理** | ✅ | ✅ |
| **Index Type変更検出** | ✅ | ✅ |
| **Index Expression変更検出** | ✅ | ✅ |
| **allowIndexRebuilds** | ✅ | ✅ |
| **Union Descriptor検証** | ✅ | ⏳ 将来実装 |
| **Deprecation警告** | ✅ | ⏳ 将来実装 |

## パフォーマンス特性

### 時間計算量

- **Record Type検証**: O(N) - Nはレコードタイプ数
- **Index検証**: O(M) - Mはインデックス数
- **FormerIndex検証**: O(F) - Fはフォーマーインデックス数
- **KeyExpression比較**: O(K) - Kは式の深さ

**合計**: O(N + M + F + K)

### メモリ使用量

- **ValidationError配列**: O(E) - Eはエラー数
- **一時的な文字列**: O(1)（固定サイズ）

**スケーラビリティ**: 数百のレコードタイプ・インデックスでも高速に動作

## エラーメッセージの例

```
[Record type removed] RecordType: Order
Record type 'Order' was removed. Record types cannot be removed.

[Primary key changed] RecordType: User
Primary key structure changed for 'User'

[Field removed] RecordType: User Field: userID
Primary key field 'userID' was removed from 'User'

[Index removed without FormerIndex] Index: user_by_email
Index 'user_by_email' was removed without adding a FormerIndex

[Index format changed] Index: user_by_age
Index type changed from value to count. Set allowIndexRebuilds=true to permit.

[FormerIndex conflicts with new index] Index: old_email_index
New index 'old_email_index' conflicts with a FormerIndex from previous version

[Index subspace conflict] Index: email_idx
Index subspace key changed. Set allowIndexRebuilds=true to permit.
```

## 将来の拡張

### 1. Protobuf Descriptorの完全検証

- すべてのフィールドの型変更検出
- `optional`/`required`の変更検出
- `oneof`の変更検出

### 2. 警告レベルのメッセージ

- 非推奨フィールド（deprecated）の使用
- パフォーマンスへの影響がある変更

### 3. カスタム検証ルール

- プロジェクト固有の制約
- プラグイン可能な検証器

### 4. 自動マイグレーション提案

- 検出された問題に対する修正案
- インデックス再構築の推奨順序

## まとめ

MetaDataEvolutionValidatorは、スキーマ進化の安全性を保証する重要なコンポーネントです：

1. **安全性**: 破壊的な変更を事前に検出
2. **柔軟性**: allowIndexRebuildsによる段階的マイグレーション
3. **明確性**: 詳細なエラーメッセージ
4. **Java版との互換性**: 設計パターンの継承

このバリデータにより、本番環境でのスキーマ変更を安全に実施できます。
