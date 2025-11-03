# FoundationDB バインディングのアーキテクチャ設計

## fdb-swift-bindings に含めるもの・含めないもの

---

## 🎯 設計原則

### fdb-swift-bindings (基本バインディング) の役割

**「FoundationDB の基本的な機能を、そのまま Swift で使えるようにする」**

- FoundationDB の C API を Swift でラップ
- 言語間で共通の基本的なデータ構造を提供
- すべての FoundationDB アプリケーションで使われる基盤

---

## ✅ fdb-swift-bindings に含めるべきもの

### 1. **Tuple Layer** (Tuple.swift)

#### なぜ含める？
- ✅ FoundationDB の**公式な標準機能**
- ✅ すべての言語バインディングに含まれる
- ✅ キーのエンコーディングの基礎

#### 含まれる機能
```swift
Tuple("user", 12345, true).encode()
Tuple.decode(from: bytes)
```

#### クロスランゲージ比較
| 言語 | モジュール | 含まれる場所 |
|------|-----------|-------------|
| Python | `fdb.tuple` | **fdb パッケージ** |
| Go | `tuple.Tuple` | **fdb パッケージ** |
| Java | `com.apple.foundationdb.tuple.Tuple` | **fdb-java** |
| Swift | `Tuple` | **fdb-swift-bindings** ✅ |

---

### 2. **Subspace** (Subspace.swift)

#### なぜ含める？
- ✅ FoundationDB の**公式な標準機能**
- ✅ すべての言語バインディングに含まれる
- ✅ キー空間の分割・管理の基礎

#### 含まれる機能
```swift
let users = Subspace(rootPrefix: "users")
let key = users.pack(Tuple(12345, "alice"))
let (begin, end) = users.range()
```

#### クロスランゲージ比較
| 言語 | モジュール | 含まれる場所 |
|------|-----------|-------------|
| Python | `fdb.Subspace` | **fdb パッケージ** ✅ |
| Go | `subspace.Subspace` | **fdb パッケージ** ✅ |
| Java | `com.apple.foundationdb.subspace.Subspace` | **fdb-java** ✅ |
| C++ | `fdb::Subspace` | **fdb-c++** ✅ |
| Swift | `Subspace` | **fdb-swift-bindings** ✅ |

**重要:** Subspace は**基本レイヤー**であり、Record Layer とは独立して使われる。

---

### 3. **Versionstamp** (Versionstamp.swift, Tuple+Versionstamp.swift)

#### なぜ含める？
- ✅ FoundationDB の**公式機能** (SET_VERSIONSTAMPED_KEY)
- ✅ すべての言語バインディングに含まれる
- ✅ Tuple Layer の一部として標準化されている

#### 含まれる機能
```swift
let vs = Versionstamp.incomplete(userVersion: 0)
let key = try Tuple("event", vs).packWithVersionstamp()
transaction.atomicOp(key: key, param: [], mutationType: .setVersionstampedKey)
```

#### クロスランゲージ比較
| 言語 | モジュール | 含まれる場所 |
|------|-----------|-------------|
| Python | `fdb.tuple.Versionstamp` | **fdb パッケージ** ✅ |
|        | `tuple.pack_with_versionstamp()` | **fdb パッケージ** ✅ |
| Go | `tuple.Versionstamp` | **fdb パッケージ** ✅ |
|    | `tuple.PackWithVersionstamp()` | **fdb パッケージ** ✅ |
| Java | `com.apple.foundationdb.tuple.Versionstamp` | **fdb-java** ✅ |
|      | `Tuple.packWithVersionstamp()` | **fdb-java** ✅ |
| Swift | `Versionstamp` | **fdb-swift-bindings** ✅ |
|       | `Tuple.packWithVersionstamp()` | **fdb-swift-bindings** ✅ |

---

### 4. **String Increment (strinc)** (FDB.Bytes.strinc())

#### なぜ含める？
- ✅ FoundationDB の**公式アルゴリズム**
- ✅ すべての言語バインディングに含まれる
- ✅ Subspace の範囲クエリで使用

#### 含まれる機能
```swift
try [0x01, 0xFF].strinc() // → [0x02]
let (begin, end) = try subspace.prefixRange()
```

#### クロスランゲージ比較
| 言語 | 関数 | 含まれる場所 |
|------|------|-------------|
| Python | `fdb.strinc()` | **fdb パッケージ** ✅ |
| Go | `fdb.Strinc()` | **fdb パッケージ** ✅ |
| Java | `ByteArrayUtil.strinc()` | **fdb-java** ✅ |
| C++ | `fdb::Strinc()` | **fdb-c++** ✅ |
| Swift | `FDB.Bytes.strinc()` | **fdb-swift-bindings** ✅ |

---

### 5. **基本的なトランザクション API**

#### 含まれる機能
```swift
FDBClient.initialize()
FDBClient.openDatabase()
database.withTransaction { transaction in
    transaction.setValue(value, for: key)
    let value = try await transaction.getValue(for: key)
    transaction.getRange(...)
    transaction.atomicOp(...)
}
```

これらは C API の直接ラップで、すべての言語バインディングの基礎。

---

## ❌ fdb-swift-bindings に含めないもの

### 1. **Record Layer 機能**

以下は **fdb-record-layer** に含める:

#### RecordStore (レコード管理)
```swift
// ❌ fdb-swift-bindings には含めない
// ✅ fdb-record-layer に含める
let store = RecordStore<User>(...)
try await store.save(user)
```

**理由:**
- Record Layer は高レベルの抽象化
- すべてのアプリケーションで必要ではない
- fdb-swift-bindings に依存関係を追加したくない

---

#### Index (インデックス管理)
```swift
// ❌ fdb-swift-bindings には含めない
// ✅ fdb-record-layer に含める
let index = ValueIndex(...)
let maintainer = ValueIndexMaintainer(...)
```

**理由:**
- インデックスは Record Layer 固有の概念
- Subspace と Tuple を使って独自に実装できる
- 標準化されていない（アプリケーション依存）

---

#### Query Planner (クエリ最適化)
```swift
// ❌ fdb-swift-bindings には含めない
// ✅ fdb-record-layer に含める
let query = RecordQuery.where { $0.age > 18 }
let planner = RecordQueryPlanner(...)
```

**理由:**
- 高レベルの抽象化
- Record Layer 固有の機能

---

### 2. **Directory Layer**

**現状:** どちらにも含まれていない（将来的に追加可能）

#### なぜ現在は含めない？
- ⚠️ 実装が複雑
- ⚠️ ユースケースが限定的
- ⚠️ Subspace で代替可能

#### 将来的には fdb-swift-bindings に含める候補
- ✅ Python/Go/Java には含まれている
- ✅ FoundationDB の公式機能

```swift
// 将来的な実装例 (fdb-swift-bindings)
let directory = try await DirectoryLayer.default.createOrOpen(
    transaction,
    path: ["users", "active"]
)
let subspace = directory.subspace
```

---

### 3. **高レベルなデータモデリング**

```swift
// ❌ fdb-swift-bindings には含めない
// ✅ fdb-record-layer または独自実装
protocol Record: Codable { ... }
class TypedRecordStore<Record> { ... }
```

**理由:**
- アプリケーション固有
- Record Layer の責務

---

## 📊 レイヤー構造の比較

### Python FoundationDB バインディング

```
┌─────────────────────────────────────┐
│ アプリケーション                      │
├─────────────────────────────────────┤
│ Record Layer (存在しない)             │  ← Python には公式 Record Layer なし
├─────────────────────────────────────┤
│ fdb (基本バインディング)               │
│ - Tuple                             │
│ - Subspace                          │
│ - Versionstamp                      │
│ - pack_with_versionstamp()          │
│ - strinc()                          │
│ - Directory Layer                   │  ← Python には含まれる
├─────────────────────────────────────┤
│ FoundationDB C API                  │
└─────────────────────────────────────┘
```

---

### Java FoundationDB バインディング

```
┌─────────────────────────────────────┐
│ アプリケーション                      │
├─────────────────────────────────────┤
│ fdb-record-layer                    │  ← Apple が開発した Record Layer (Java 版)
│ - RecordStore                       │
│ - Index                             │
│ - Query Planner                     │
├─────────────────────────────────────┤
│ fdb-java (基本バインディング)          │
│ - Tuple                             │
│ - Subspace                          │
│ - Versionstamp                      │
│ - packWithVersionstamp()            │
│ - strinc()                          │
│ - Directory Layer                   │
├─────────────────────────────────────┤
│ FoundationDB C API                  │
└─────────────────────────────────────┘
```

---

### Swift FoundationDB バインディング (現在)

```
┌─────────────────────────────────────┐
│ アプリケーション                      │
├─────────────────────────────────────┤
│ fdb-record-layer (Swift)            │
│ - RecordStore                       │
│ - Index                             │
│ - Query Planner                     │
│ - (Subspace を削除 → 下層に移動)      │  ← 今回の変更
├─────────────────────────────────────┤
│ fdb-swift-bindings                  │
│ - Tuple                             │  ← 既存
│ - Subspace                          │  ← 新規追加 ✅
│ - Versionstamp                      │  ← 新規追加 ✅
│ - packWithVersionstamp()            │  ← 新規追加 ✅
│ - strinc()                          │  ← 新規追加 ✅
│ - (Directory Layer: 未実装)          │  ← 将来的に追加候補
├─────────────────────────────────────┤
│ FoundationDB C API                  │
└─────────────────────────────────────┘
```

---

## 🎯 設計判断の基準

### fdb-swift-bindings に含める条件

以下の**すべて**を満たす場合に含める:

1. ✅ **FoundationDB の公式機能である**
   - ドキュメントに記載されている
   - C API で提供されている

2. ✅ **他の言語バインディングに含まれている**
   - Python: ✅
   - Go: ✅
   - Java: ✅
   - C++: ✅

3. ✅ **Record Layer とは独立して使われる**
   - Subspace: 多くのアプリケーションで使用
   - Tuple: キーのエンコーディングの基礎
   - Versionstamp: 楽観的ロックなど

4. ✅ **低レベルのプリミティブである**
   - 高レベルの抽象化ではない
   - 他の機能の基礎となる

---

### fdb-record-layer に含める条件

以下の**いずれか**を満たす場合に含める:

1. ✅ **Record Layer 固有の機能**
   - RecordStore
   - Index
   - Query Planner

2. ✅ **高レベルの抽象化**
   - データモデリング
   - クエリ最適化

3. ✅ **アプリケーション固有の機能**
   - 特定のユースケースに特化

---

## 📝 今回の変更の正当性

### Subspace を fdb-swift-bindings に移動した理由

#### Before (間違った設計)
```
fdb-record-layer に Subspace を含めていた
```

#### After (正しい設計)
```
fdb-swift-bindings に Subspace を含める ✅
```

#### 理由
1. ✅ Python/Go/Java/C++ すべてに含まれる**標準機能**
2. ✅ Record Layer とは**独立して使われる**
3. ✅ Tuple と並ぶ**基本プリミティブ**
4. ✅ 多くのアプリケーションで必要

#### 具体例: Subspace の独立使用

```swift
// fdb-swift-bindings だけで完結する使用例
import FoundationDB

let db = try FDBClient.openDatabase()

// Subspace でキー空間を分割
let users = Subspace(rootPrefix: "users")
let posts = Subspace(rootPrefix: "posts")

try await db.withTransaction { transaction in
    // ユーザーを保存
    let userKey = users.pack(Tuple(12345))
    transaction.setValue("Alice", for: userKey)

    // 投稿を保存
    let postKey = posts.pack(Tuple(1, 12345))
    transaction.setValue("Hello!", for: postKey)

    // 全ユーザーをスキャン
    let (begin, end) = users.range()
    for try await (key, value) in transaction.getRange(
        beginSelector: .firstGreaterOrEqual(begin),
        endSelector: .firstGreaterThan(end)
    ) {
        print(String(decoding: value, as: UTF8.self))
    }
}
```

**fdb-record-layer は一切使っていない！**

---

## 🔮 将来の拡張

### fdb-swift-bindings に追加候補

1. **Directory Layer**
   - Python/Go/Java には含まれている
   - 階層的な名前空間管理

2. **High Contention Allocator**
   - 高頻度アクセス時の ID 生成
   - Python には含まれている

---

## まとめ

### fdb-swift-bindings に含めるもの

| 機能 | 理由 | 他言語 |
|------|------|--------|
| Tuple | ✅ 基本プリミティブ | Python/Go/Java/C++ |
| Subspace | ✅ 基本プリミティブ | Python/Go/Java/C++ |
| Versionstamp | ✅ 基本プリミティブ | Python/Go/Java |
| packWithVersionstamp() | ✅ Tuple Layer の一部 | Python/Go/Java |
| strinc() | ✅ 基本アルゴリズム | Python/Go/Java/C++ |

### fdb-record-layer に含めるもの

| 機能 | 理由 |
|------|------|
| RecordStore | ✅ Record Layer 固有 |
| Index | ✅ Record Layer 固有 |
| Query Planner | ✅ 高レベル抽象化 |

---

**結論:** 今回の設計は**他の言語バインディングと完全に一致**しており、正しい判断です。
