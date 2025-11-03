# Tuple.packWithVersionstamp() 詳細解説

## 概要

`Tuple.packWithVersionstamp()` は、**Versionstamp を含む Tuple を自動的にエンコードし、FoundationDB が必要とするオフセット情報を追加する**メソッドです。

---

## 何をするもの？

### 基本的な役割

1. **Tuple を Versionstamp 付きでエンコード**
2. **Versionstamp の位置 (オフセット) を自動計算**
3. **4 バイトのオフセット情報を末尾に追加**

これにより、FoundationDB の `SET_VERSIONSTAMPED_KEY` アトミック操作で使用できるキーを生成します。

---

## なぜ必要なのか？

### FoundationDB の Versionstamp の仕組み

FoundationDB では、トランザクションコミット時に**グローバルに一意で単調増加する 10 バイトの値 (versionstamp)** を割り当てます。

この versionstamp をキーに含めるには、以下が必要です:
1. キーの一部に **10 バイトのプレースホルダー (0xFF を 10 個)** を入れる
2. キーの末尾に **プレースホルダーの位置 (オフセット) を 4 バイトで指定**
3. `SET_VERSIONSTAMPED_KEY` アトミック操作を使用

FoundationDB は、コミット時に以下を行います:
1. 末尾 4 バイトからオフセットを読み取る
2. その位置の 10 バイトを実際の versionstamp に置き換える
3. 末尾の 4 バイトオフセットを削除

---

## 手動実装 vs Tuple.packWithVersionstamp()

### 🔴 手動実装 (従来の方法 - VersionIndex.swift で使用中)

```swift
// Step 1: 基本キーを作成
var key = subspace.pack(primaryKey)
let versionPosition = UInt32(key.count)

// Step 2: 位置がオーバーフローしないか確認
guard versionPosition <= UInt32.max - 10 else {
    throw RecordLayerError.internalError("Version key too long")
}

// Step 3: 10 バイトのプレースホルダーを追加
key.append(contentsOf: [UInt8](repeating: 0xFF, count: 10))

// Step 4: 4 バイトのオフセットを little-endian で追加
let positionBytes = withUnsafeBytes(of: versionPosition.littleEndian) { Array($0) }
key.append(contentsOf: positionBytes)

// Step 5: SET_VERSIONSTAMPED_KEY を使用
transaction.atomicOp(key: key, param: [], mutationType: .setVersionstampedKey)
```

**問題点:**
- ❌ コードが長い (8 行)
- ❌ オフセット計算が手動
- ❌ エンディアン変換が必要
- ❌ エラーが発生しやすい

---

### ✅ Tuple.packWithVersionstamp() を使用 (新しい方法)

```swift
// Step 1: Versionstamp を作成
let vs = Versionstamp.incomplete(userVersion: 0)

// Step 2: Tuple に含める
let tuple = Tuple("user", 12345, vs)

// Step 3: 自動的にパック (オフセット計算も自動)
let key = try tuple.packWithVersionstamp()

// Step 4: SET_VERSIONSTAMPED_KEY を使用
transaction.atomicOp(key: key, param: [], mutationType: .setVersionstampedKey)
```

**メリット:**
- ✅ コードが短い (4 行)
- ✅ オフセット計算が自動
- ✅ エンディアン変換が自動
- ✅ 型安全 (Versionstamp 型を使用)
- ✅ エラーチェックが自動

---

## 具体的な動作例

### 入力

```swift
let vs = Versionstamp.incomplete(userVersion: 0)
let tuple = Tuple("user", 12345, vs)
let key = try tuple.packWithVersionstamp()
```

### 内部処理

#### 1. Tuple のエンコード

```
"user" → [0x02, 0x75, 0x73, 0x65, 0x72, 0x00]  (String タイプコード 0x02)
12345  → [0x15, 0x30, 0x39]                      (Int タイプコード 0x15)
vs     → [0x33, 0xFF, 0xFF, ..., 0xFF, 0x00, 0x00]  (Versionstamp タイプコード 0x33)
         ^^^^^ ^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^
         type  10-byte placeholder   2-byte userVersion
```

#### 2. オフセット計算

```
オフセット = "user" のサイズ + 12345 のサイズ + タイプコード 0x33
          = 6 + 3 + 1 = 10

10-byte placeholder は位置 10 から始まる
```

#### 3. オフセットを追加 (little-endian)

```
key = [エンコードされた Tuple] + [0x0A, 0x00, 0x00, 0x00]
                                   ^^^^^^^^^^^^^^^^^^^^^^^^
                                   offset = 10 (little-endian)
```

### 最終的なキー構造

**トランザクション中:**
```
[0x02, 0x75, 0x73, 0x65, 0x72, 0x00,  // "user"
 0x15, 0x30, 0x39,                     // 12345
 0x33,                                 // Versionstamp タイプコード
 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,         // 10-byte placeholder (前半)
 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,         // 10-byte placeholder (後半)
 0x00, 0x00,                           // userVersion = 0
 0x0A, 0x00, 0x00, 0x00]               // offset = 10 (little-endian)
```

**コミット後 (FDB が処理):**
```
[0x02, 0x75, 0x73, 0x65, 0x72, 0x00,  // "user"
 0x15, 0x30, 0x39,                     // 12345
 0x33,                                 // Versionstamp タイプコード
 0xAB, 0xCD, 0xEF, 0x12, 0x34,         // 実際の versionstamp (前半)
 0x56, 0x78, 0x9A, 0xBC, 0xDE,         // 実際の versionstamp (後半)
 0x00, 0x00]                           // userVersion = 0
                                       // offset は削除される
```

---

## 実際の使用例

### 例 1: バージョン管理されたレコードキー

```swift
// ユーザーレコードのバージョン履歴を保存
let userId = 12345
let vs = Versionstamp.incomplete(userVersion: 0)

let key = try Tuple("users", userId, "versions", vs).packWithVersionstamp()

transaction.atomicOp(
    key: key,
    param: recordData,
    mutationType: .setVersionstampedKey
)

// コミット後のキー:
// ["users", 12345, "versions", <actual versionstamp>]
// このキーは時系列順にソートされる
```

### 例 2: イベントログ

```swift
// グローバルに一意で時系列順のイベント ID を生成
let eventType = "user_login"
let vs = Versionstamp.incomplete(userVersion: 0)

let key = try Tuple("events", vs, eventType).packWithVersionstamp()

transaction.atomicOp(
    key: key,
    param: eventDetails,
    mutationType: .setVersionstampedKey
)

// コミット後のキー:
// ["events", <actual versionstamp>, "user_login"]
// versionstamp でソートされるため、時系列順に取得可能
```

### 例 3: 楽観的並行性制御 (Optimistic Locking)

```swift
// レコード更新時にバージョン番号を自動生成
let recordId = "item-123"
let vs = Versionstamp.incomplete(userVersion: 0)

// バージョンインデックス: [recordId][versionstamp] → ∅
let versionKey = try Tuple(recordId, vs).packWithVersionstamp(
    prefix: versionIndexSubspace.prefix
)

transaction.atomicOp(
    key: versionKey,
    param: [],
    mutationType: .setVersionstampedKey
)

// 読み取り時は最新バージョンを取得
let lastVersion = try await getLastVersion(recordId)
// 更新時にバージョンチェック
if currentVersion != lastVersion {
    throw RecordLayerError.versionMismatch
}
```

---

## 制約と注意点

### 1. 不完全な Versionstamp が正確に 1 つ必要

```swift
// ✅ OK: 1 つの incomplete versionstamp
let vs = Versionstamp.incomplete()
let key = try Tuple("key", vs).packWithVersionstamp()

// ❌ Error: incomplete versionstamp が 0 個
let key = try Tuple("key", 123).packWithVersionstamp()
// → TupleError.invalidEncoding

// ❌ Error: incomplete versionstamp が 2 個
let vs1 = Versionstamp.incomplete()
let vs2 = Versionstamp.incomplete()
let key = try Tuple("key", vs1, vs2).packWithVersionstamp()
// → TupleError.invalidEncoding

// ✅ OK: complete versionstamp は無制限
let vs1 = Versionstamp(transactionVersion: bytes1, userVersion: 0)
let vs2 = Versionstamp.incomplete()
let key = try Tuple("key", vs1, vs2).packWithVersionstamp()
```

### 2. オフセットは UInt32 範囲内

```swift
// オフセット位置が 4,294,967,295 バイトを超えるとエラー
guard position <= UInt32.max else {
    throw TupleError.invalidEncoding
}
```

実際には、FoundationDB のキーサイズ制限 (10KB) により、この制約に達することはありません。

### 3. prefix パラメータ

```swift
// プレフィックスを追加できる
let key = try tuple.packWithVersionstamp(prefix: subspace.prefix)

// これは以下と同等:
// subspace.pack(tuple) + オフセット計算
```

---

## 現在の fdb-record-layer での使用可能性

### ⚠️ データ互換性の問題

**現在の VersionIndex 実装:**
```
キー構造: [subspace.prefix] + primaryKey.encode() + [10-byte versionstamp]
```

**Tuple.packWithVersionstamp() を使った場合:**
```
キー構造: [subspace.prefix] + Tuple(primaryKey, versionstamp).encode()
                                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                Versionstamp は Tuple 要素として扱われる
```

**違い:**
- 現在: versionstamp は生バイトとして追加
- 新 API: versionstamp は Tuple 要素 (タイプコード 0x33 付き)

**結論:**
- ❌ **既存データとの互換性なし**
- 現在の実装から移行するには、全データのマイグレーションが必要
- 新規プロジェクトでは使用推奨

---

## まとめ

### Tuple.packWithVersionstamp() は:

1. ✅ **Versionstamp を含む Tuple を自動エンコード**
2. ✅ **オフセット計算を自動化** (エラー防止)
3. ✅ **型安全** (Versionstamp 型を使用)
4. ✅ **コードを簡潔化** (手動実装の 80% 削減)
5. ✅ **Python/Go/Java と同等の機能**

### 使用シーン:

- 🎯 グローバルに一意な ID 生成
- 🎯 時系列順のキー生成
- 🎯 楽観的並行性制御 (Optimistic Locking)
- 🎯 イベントログ、監査ログ
- 🎯 バージョン管理

### 現在の fdb-record-layer での推奨:

- ✅ **新規プロジェクト**: Tuple.packWithVersionstamp() を使用
- ⚠️ **既存プロジェクト**: 現在の手動実装を維持 (データ互換性のため)
- 💡 **移行**: データマイグレーション戦略を策定してから実施

---

**参考:**
- VersionIndex.swift:178-200 (現在の手動実装)
- Tuple+Versionstamp.swift:56-95 (packWithVersionstamp 実装)
- VersionstampTests.swift:156-202 (使用例)
