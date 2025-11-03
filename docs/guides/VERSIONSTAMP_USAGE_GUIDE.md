# Versionstamp Usage Guide for Swift Bindings

このドキュメントは、fdb-swift-bindings に Versionstamp サポートが追加された後の使用方法を説明します。

---

## 📚 目次

1. [基本概念](#基本概念)
2. [Before/After 比較](#beforeafter-比較)
3. [基本的な使い方](#基本的な使い方)
4. [高度な使用例](#高度な使用例)
5. [マイグレーションガイド](#マイグレーションガイド)
6. [エラーハンドリング](#エラーハンドリング)
7. [パフォーマンス考慮事項](#パフォーマンス考慮事項)

---

## 基本概念

### Versionstamp とは

Versionstamp は FoundationDB が提供する **12バイト（96ビット）の一意な値** です：

```
[10 bytes: Transaction Version] + [2 bytes: User Version]
```

- **Transaction Version (10 bytes)**: FDB がコミット時に自動的に割り当てる
  - 8 bytes: データベースコミットバージョン（big-endian）
  - 2 bytes: 同一コミット内のバッチ順序（big-endian）
- **User Version (2 bytes)**: アプリケーションが指定する順序付け用の値（0-65535）

### 用途

1. **楽観的同時実行制御 (OCC)**
   - レコードのバージョン管理
   - コンフリクト検出

2. **一意キーの生成**
   - グローバルに一意
   - 単調増加

3. **時系列順序の保証**
   - イベントログ
   - 監査ログ

---

## Before/After 比較

### 現在（手動実装）❌

```swift
// エラーが起きやすく、冗長
var key = subspace.pack(primaryKey)
let versionPosition = UInt32(key.count)

// 10バイトのプレースホルダーを手動追加
key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))

// 4バイトのオフセットを手動追加（リトルエンディアン）
let positionBytes = withUnsafeBytes(of: versionPosition.littleEndian) { Array($0) }
key.append(contentsOf: positionBytes)

// atomicOp で設定
transaction.atomicOp(key: key, param: [], mutationType: .setVersionstampedKey)
```

**問題点:**
- オフセット計算を手動で行う必要がある
- API バージョンの違い（2バイト vs 4バイト）を考慮する必要がある
- 型安全性がない
- バリデーションがない

### 提案実装（Versionstamp 型使用）✅

```swift
// クリーンで型安全
let vs = Versionstamp.incomplete(userVersion: 0)
let tuple = Tuple("prefix", userId, vs)
let key = try tuple.packWithVersionstamp()

transaction.atomicOp(key: key, param: [], mutationType: .setVersionstampedKey)
```

**改善点:**
- オフセット計算が自動
- API バージョン互換性が自動
- 型安全性
- バリデーション付き

---

## 基本的な使い方

### 1. Incomplete Versionstamp の作成

```swift
// User version なし
let vs1 = Versionstamp.incomplete()

// User version 指定
let vs2 = Versionstamp.incomplete(userVersion: 42)

// プロパティ確認
print(vs1.isComplete)  // false
print(vs1.userVersion) // 0
```

### 2. Tuple への追加

```swift
let vs = Versionstamp.incomplete(userVersion: 0)
let tuple = Tuple("user", 12345, vs)
```

### 3. packWithVersionstamp() でパック

```swift
let key = try tuple.packWithVersionstamp()

// オプション: prefix 指定
let keyWithPrefix = try tuple.packWithVersionstamp(prefix: namespaceBytes)
```

### 4. トランザクションで使用

```swift
try await database.withTransaction { transaction in
    let vs = Versionstamp.incomplete(userVersion: 0)
    let tuple = Tuple("document", documentId, vs)
    let key = try tuple.packWithVersionstamp()

    // Versionstamped key を設定
    transaction.atomicOp(
        key: key,
        param: [],
        mutationType: .setVersionstampedKey
    )

    // コミット後の versionstamp を取得
    let committedVersion = try await transaction.getVersionstamp()
    return committedVersion
}
```

### 5. Complete Versionstamp の作成

```swift
// コミット後の versionstamp を取得
let trVersion = try await transaction.getVersionstamp()

// Complete versionstamp を作成
let completeVs = Versionstamp(
    transactionVersion: trVersion!,
    userVersion: 0
)

print(completeVs.isComplete)  // true
```

---

## 高度な使用例

### 例1: バージョン管理付きドキュメントストア

```swift
actor DocumentStore {
    private let database: any DatabaseProtocol
    private let subspace: Subspace

    // ドキュメントの保存（バージョン付き）
    func saveDocument(_ doc: Document) async throws -> FDB.Bytes {
        return try await database.withTransaction { transaction in
            // Incomplete versionstamp でキーを作成
            let vs = Versionstamp.incomplete(userVersion: 0)
            let key = try Tuple(
                "doc",
                doc.id,
                vs
            ).packWithVersionstamp(prefix: subspace.prefix)

            // ドキュメントデータを JSON エンコード
            let value = try JSONEncoder().encode(doc)

            // Versionstamped key で保存
            transaction.atomicOp(
                key: key,
                param: value,
                mutationType: .setVersionstampedKey
            )

            // コミットされた versionstamp を返す
            return try await transaction.getVersionstamp()!
        }
    }

    // 特定バージョンのドキュメントを取得
    func getDocument(
        id: String,
        version: Versionstamp
    ) async throws -> Document? {
        return try await database.withTransaction { transaction in
            let key = Tuple("doc", id, version).encode(prefix: subspace.prefix)

            guard let value = try await transaction.getValue(for: key) else {
                return nil
            }

            return try JSONDecoder().decode(Document.self, from: Data(value))
        }
    }

    // ドキュメントの全バージョン履歴を取得
    func getVersionHistory(
        id: String
    ) async throws -> [Versionstamp] {
        return try await database.withTransaction { transaction in
            let beginKey = Tuple("doc", id).encode(prefix: subspace.prefix)
            let endKey = beginKey + [0xFF]

            var versions: [Versionstamp] = []

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterThan(endKey),
                snapshot: true
            )

            for try await (key, _) in sequence {
                // Key から Tuple をデコード
                let keyWithoutPrefix = key.dropFirst(subspace.prefix.count)
                let elements = try Tuple.decodeWithVersionstamp(from: Array(keyWithoutPrefix))

                // 最後の要素が Versionstamp
                if let vs = elements.last as? Versionstamp {
                    versions.append(vs)
                }
            }

            return versions
        }
    }
}
```

### 例2: バッチ挿入（トランザクション内順序付け）

```swift
actor EventLog {
    private let database: any DatabaseProtocol
    private let subspace: Subspace

    // イベントのバッチ挿入（user version で順序付け）
    func logEvents(_ events: [Event]) async throws {
        try await database.withTransaction { transaction in
            for (index, event) in events.enumerated() {
                // User version でトランザクション内の順序を保証
                let vs = Versionstamp.incomplete(userVersion: UInt16(index))

                let key = try Tuple(
                    "event",
                    event.category,
                    vs
                ).packWithVersionstamp(prefix: subspace.prefix)

                let value = try JSONEncoder().encode(event)

                transaction.atomicOp(
                    key: key,
                    param: value,
                    mutationType: .setVersionstampedKey
                )
            }
        }
    }
}
```

### 例3: 楽観的同時実行制御 (OCC)

```swift
actor UserProfileStore {
    private let database: any DatabaseProtocol
    private let subspace: Subspace

    // プロファイルの読み取り（バージョン付き）
    func getProfile(userId: String) async throws -> (UserProfile, Versionstamp)? {
        return try await database.withTransaction { transaction in
            // 最新バージョンのキーを取得
            let beginKey = Tuple("profile", userId).encode(prefix: subspace.prefix)
            let endKey = beginKey + [0xFF]

            let lastSelector = FDB.KeySelector.lastLessThan(endKey)
            guard let lastKey = try await transaction.getKey(selector: lastSelector) else {
                return nil
            }

            // Key から Versionstamp を抽出
            let keyWithoutPrefix = lastKey.dropFirst(subspace.prefix.count)
            let elements = try Tuple.decodeWithVersionstamp(from: Array(keyWithoutPrefix))

            guard let vs = elements.last as? Versionstamp,
                  let value = try await transaction.getValue(for: lastKey) else {
                return nil
            }

            let profile = try JSONDecoder().decode(UserProfile.self, from: Data(value))
            return (profile, vs)
        }
    }

    // プロファイルの更新（バージョンチェック付き）
    func updateProfile(
        userId: String,
        expectedVersion: Versionstamp,
        updatedProfile: UserProfile
    ) async throws {
        try await database.withTransaction { transaction in
            // 現在のバージョンを確認
            guard let (_, currentVersion) = try await getProfile(userId: userId) else {
                throw ProfileError.notFound
            }

            // バージョンチェック
            guard currentVersion == expectedVersion else {
                throw ProfileError.versionMismatch(
                    expected: expectedVersion,
                    actual: currentVersion
                )
            }

            // 新しいバージョンで保存
            let vs = Versionstamp.incomplete(userVersion: 0)
            let key = try Tuple(
                "profile",
                userId,
                vs
            ).packWithVersionstamp(prefix: subspace.prefix)

            let value = try JSONEncoder().encode(updatedProfile)

            transaction.atomicOp(
                key: key,
                param: value,
                mutationType: .setVersionstampedKey
            )
        }
    }
}
```

---

## マイグレーションガイド

### 既存コードの移行

#### Step 1: Versionstamp 型の導入

**Before:**
```swift
// 手動でバイト配列を構築
var key = prefix
key.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
key.append(contentsOf: [0x00, 0x00])  // user version
```

**After:**
```swift
// Versionstamp 型を使用
let vs = Versionstamp.incomplete(userVersion: 0)
```

#### Step 2: Tuple.packWithVersionstamp() の使用

**Before:**
```swift
var key = subspace.pack(primaryKey)
let versionPosition = UInt32(key.count)
key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))
let positionBytes = withUnsafeBytes(of: versionPosition.littleEndian) { Array($0) }
key.append(contentsOf: positionBytes)
```

**After:**
```swift
let vs = Versionstamp.incomplete(userVersion: 0)
let tuple = Tuple(/* ... */, vs)
let key = try tuple.packWithVersionstamp(prefix: subspace.prefix)
```

#### Step 3: エラーハンドリングの追加

```swift
do {
    let key = try tuple.packWithVersionstamp()
    transaction.atomicOp(key: key, param: [], mutationType: .setVersionstampedKey)
} catch {
    // Versionstamp エラーを処理
    print("Versionstamp error: \(error)")
}
```

### 互換性

- **下位互換性**: 既存の `atomicOp` を使用したコードはそのまま動作
- **API バージョン**: 自動的に適切なオフセットサイズ（2バイト or 4バイト）を使用
- **段階的移行**: 新しいコードから順次移行可能

---

## エラーハンドリング

### よくあるエラー

#### 1. Incomplete Versionstamp が見つからない

```swift
let tuple = Tuple("no versionstamp")
do {
    _ = try tuple.packWithVersionstamp()
} catch {
    // Error: requires exactly one incomplete versionstamp, found 0
}
```

**修正:**
```swift
let vs = Versionstamp.incomplete()
let tuple = Tuple("with versionstamp", vs)
let key = try tuple.packWithVersionstamp()  // OK
```

#### 2. 複数の Incomplete Versionstamp

```swift
let vs1 = Versionstamp.incomplete(userVersion: 0)
let vs2 = Versionstamp.incomplete(userVersion: 1)
let tuple = Tuple(vs1, vs2)
do {
    _ = try tuple.packWithVersionstamp()
} catch {
    // Error: requires exactly one incomplete versionstamp, found 2
}
```

**修正:**
```swift
// トランザクション内の順序付けには user version を使用
let vs = Versionstamp.incomplete(userVersion: 0)
let tuple = Tuple(vs)
let key = try tuple.packWithVersionstamp()  // OK
```

#### 3. オフセットオーバーフロー

```swift
// API < 520 で 65535 を超えるオフセット
let largePrefix = [UInt8](repeating: 0x00, count: 70000)
let vs = Versionstamp.incomplete()
let tuple = Tuple(vs)
do {
    _ = try tuple.packWithVersionstamp(prefix: largePrefix)
} catch {
    // Error: Versionstamp offset exceeds maximum for API version
}
```

**修正:**
- API 710 を使用（4バイトオフセット対応）
- または prefix サイズを小さくする

### エラーハンドリングのベストプラクティス

```swift
func saveWithVersionstamp(_ data: Data, key: Tuple) async throws {
    // 1. Versionstamp のバリデーション
    try key.validateForVersionstamp()

    // 2. Pack with error handling
    let packedKey: FDB.Bytes
    do {
        packedKey = try key.packWithVersionstamp()
    } catch let error as FDBError {
        throw StorageError.invalidVersionstamp(error.message)
    }

    // 3. トランザクション実行
    try await database.withTransaction { transaction in
        transaction.atomicOp(
            key: packedKey,
            param: Array(data),
            mutationType: .setVersionstampedKey
        )
    }
}
```

---

## パフォーマンス考慮事項

### 1. Versionstamp のキャッシング

```swift
// ❌ 非効率: 毎回新しい incomplete versionstamp を作成
for i in 0..<1000 {
    let vs = Versionstamp.incomplete(userVersion: UInt16(i))
    // ...
}

// ✅ 効率的: user version のみ変更
for i in 0..<1000 {
    let vs = Versionstamp.incomplete(userVersion: UInt16(i))
    // Versionstamp 構造体は軽量なので問題なし
}
```

### 2. packWithVersionstamp() のパフォーマンス

```swift
// packWithVersionstamp() は O(n) where n = tuple size
// 大きな tuple では一度だけパックする
let vs = Versionstamp.incomplete()
let tuple = Tuple(/* 多数の要素 */, vs)

// ✅ 一度だけパック
let packedKey = try tuple.packWithVersionstamp()

// トランザクション内で再利用
try await database.withTransaction { transaction in
    transaction.atomicOp(key: packedKey, param: [], mutationType: .setVersionstampedKey)
}
```

### 3. バッチ処理の最適化

```swift
// ✅ トランザクション内で複数の versionstamped key を設定
try await database.withTransaction { transaction in
    for (index, item) in items.enumerated() {
        let vs = Versionstamp.incomplete(userVersion: UInt16(index))
        let key = try Tuple("item", item.id, vs).packWithVersionstamp()
        transaction.atomicOp(key: key, param: item.data, mutationType: .setVersionstampedKey)
    }
}
// FDB が各キーに異なる versionstamp を割り当てる
// user version により順序が保証される
```

---

## まとめ

### 推奨される使い方

1. **Versionstamp.incomplete() を使用** - 手動バイト構築を避ける
2. **Tuple.packWithVersionstamp() を使用** - オフセット計算を自動化
3. **validateForVersionstamp() でバリデーション** - エラーを早期検出
4. **User version で順序付け** - トランザクション内の複数キー

### 避けるべきパターン

1. ❌ 手動でのバイト配列構築
2. ❌ オフセット計算の手動実装
3. ❌ API バージョンの手動チェック
4. ❌ Complete versionstamp の直接エンコード（read-only）

### 次のステップ

- [GitHub Issue](./GITHUB_ISSUE_VERSIONSTAMP.md) を確認
- 実装ファイルを確認:
  - `Versionstamp.swift`
  - `Tuple+Versionstamp.swift`
  - `VersionstampTests.swift`
- fdb-swift-bindings への PR を作成
