# FoundationDB Record Layer 開発ガイド

テストはSwiftTestingで実装してください。
実装を中途半端に終えた場合は、中途半端な実装部分の設計を行い確実に実装するまで実装してください。

## 目次

### Part 1: FoundationDB基礎
- FoundationDBとは
- コアアーキテクチャ
- 標準レイヤー（Tuple、Subspace、Directory）
- トランザクション制限
- fdbcli コマンドライン
- Subspace.pack() vs Subspace.subspace() の設計ガイドライン
- データモデリングパターン
- トランザクション分離レベルと競合制御
- アトミック操作（MutationType）
- Versionstamp
- Watch操作
- パフォーマンスチューニング
- エラーハンドリング
- Subspaceの正しい使い方

### Part 2: fdb-swift-bindings API
- DatabaseProtocol と TransactionProtocol
- Tuple
- Subspace
- DirectoryLayer

### Part 3: Swift並行性パターン
- final class + Mutex パターン

### Part 4: Record Layer設計
- インデックス状態管理
- インデックスタイプ（VALUE、COUNT、SUM、MIN/MAX）
- RangeSet（進行状況追跡）
- オンラインインデックス構築
- クエリプランナー
- Record Layerアーキテクチャ
- マクロAPI
- スキーママイグレーション

---

## Part 1: FoundationDB基礎

### FoundationDBとは

分散トランザクショナルKey-Valueストア：
- **ACID保証**、**順序付きKey-Value**、**楽観的並行性制御**
- キーは辞書順でソート、コミット時に競合検出
- トランザクション制限: キー≤10KB、値≤100KB、トランザクション≤10MB、実行時間≤5秒

### コアアーキテクチャ

**主要コンポーネント**:

| コンポーネント | 役割 |
|--------------|------|
| **Cluster Controller** | クラスタ監視とロール割り当て |
| **Master** | トランザクション調整、バージョン管理 |
| **Commit Proxy** | コミットリクエスト処理、競合検出 |
| **GRV Proxy** | 読み取りバージョン提供 |
| **Resolver** | トランザクション間の競合検出 |
| **Transaction Log (TLog)** | コミット済みトランザクションの永続化 |
| **Storage Server** | データ保存（MVCC、バージョン管理） |

**トランザクション処理フロー**:

1. 読み取り: GRV Proxy → 読み取りバージョン取得 → Storage Serverから直接読み取り
2. 書き込み: Commit Proxy → 競合検出 → TLogへ書き込み → Storage Serverへ非同期更新

**snapshotパラメータ**:

| パラメータ | 動作 | 用途 |
|-----------|------|------|
| `snapshot: true` | 競合検知なし | SnapshotCursor（トランザクション外） |
| `snapshot: false` | Serializable読み取り、競合検知あり | TransactionCursor（トランザクション内） |

```swift
// TransactionCursor: トランザクション内
try await database.withTransaction { transaction in
    let value = try await transaction.getValue(for: key, snapshot: false)
    // 同一トランザクション内の書き込みが見える、競合を検知
}

// SnapshotCursor: トランザクション外
let value = try await transaction.getValue(for: key, snapshot: true)
// 読み取り専用、競合検知不要、パフォーマンス最適
```

### 標準レイヤー

**Tuple Layer**: 型安全なエンコーディング、辞書順保持

```swift
// Tuple作成
let tuple = Tuple("California", "Los Angeles", 123)

// パック（エンコード）
let packed = tuple.pack()  // FDB.Bytes

// アンパック（デコード）
let elements = try Tuple.unpack(from: packed)  // [any TupleElement]

// Tuple構造体の使い方
let tuple = Tuple("A", "B", 123)
tuple.count  // 3

// 要素アクセス（subscript）
for i in 0..<tuple.count {
    if let element = tuple[i] {
        if let str = element as? String {
            print("String: \(str)")
        } else if let int = element as? Int64 {
            print("Int64: \(int)")
        }
    }
}

// Subspace.unpack()の使い方
let subspace = Subspace(prefix: [0x01])
let key = subspace.pack(Tuple("category", 123))
let unpacked: Tuple = try subspace.unpack(key)  // Tupleを返す
let category = unpacked[0] as? String  // subscriptでアクセス
let id = unpacked[1] as? Int64

// 注意: Tuple.elements は internal なので外部からアクセス不可
// 必ず subscript または count を使用
```

**Subspace Layer**: 名前空間の分離
```swift
let app = Subspace(prefix: Tuple("myapp").pack())
let users = app["users"]
```

**Directory Layer**: 階層管理、短いプレフィックスへのマッピング
```swift
let dir = try await directoryLayer.createOrOpen(path: ["app", "users"])
```

### トランザクション制限

**サイズ制限**:

| 項目 | デフォルト | 設定可能 |
|------|-----------|---------|
| キーサイズ | 最大10KB | ❌ |
| 値サイズ | 最大100KB | ❌ |
| トランザクションサイズ | 10MB | ✅ |
| 実行時間 | 5秒 | ✅（タイムアウト） |

**制限の設定**:
```swift
// トランザクションサイズ制限
try transaction.setOption(to: withUnsafeBytes(of: Int64(50_000_000).littleEndian) { Array($0) },
                          forOption: .sizeLimit)  // 50MB

// タイムアウト設定
try transaction.setOption(to: withUnsafeBytes(of: Int64(3000).littleEndian) { Array($0) },
                          forOption: .timeout)  // 3秒
```

### fdbcli コマンドライン

**fdbcli**はFoundationDBクラスタの管理・操作を行うコマンドラインツールです。

#### 起動とオプション

```bash
# 基本起動（デフォルトクラスタファイルを使用）
fdbcli

# クラスタファイルを指定
fdbcli -C /path/to/fdb.cluster

# コマンドを実行して終了
fdbcli --exec "status"

# 複数コマンドを実行
fdbcli --exec "status; get mykey"

# ステータスチェックをスキップ
fdbcli --no-status
```

#### トランザクションモード

| モード | 説明 | 使用方法 |
|--------|------|---------|
| **Autocommit** (デフォルト) | 各コマンドが自動的にコミット | `set key value` |
| **Transaction** | 複数操作を1つのトランザクションで実行 | `begin` → 操作 → `commit` |

#### 主要コマンド

**クラスタ管理**:

```bash
# ステータス確認
status                    # 基本情報
status details           # 詳細統計
status json              # JSON形式（スクリプト用）

# データベース設定変更
configure triple ssd     # triple redundancy + SSD storage
configure single memory  # 単一サーバー + メモリストレージ

# サーバー除外/復帰
exclude 10.0.0.1:4500   # サーバーを除外
include 10.0.0.1:4500   # サーバーを復帰

# コーディネーター変更
coordinators auto        # 自動選択

# データベースロック
lock                     # ロック
unlock <PASSPHRASE>     # アンロック
```

**データ操作**:

```bash
# 書き込みモードを有効化（デフォルトは無効）
writemode on

# キー・値の操作
set "key" "value"              # 設定
get "key"                      # 取得
clear "key"                    # 削除
clearrange "begin" "end"       # 範囲削除
getrange "begin" "end" 100     # 範囲取得（最大100件）

# トランザクション
begin                          # 開始
set "key1" "value1"
set "key2" "value2"
commit                         # コミット
rollback                       # ロールバック
reset                          # リセット
```

**キー・値のエスケープ**:

```bash
# スペースを含むキー
set "key with spaces" "value"
set key\ with\ spaces "value"
set key\x20with\x20spaces "value"

# バイナリデータ（16進数）
set "\x01\x02\x03" "\xFF\xFE"

# クォーテーション
set "key\"with\"quotes" "value"
```

**設定とノブ**:

```bash
# ノブ（内部パラメータ）の設定
setknob <KNOBNAME> <VALUE>
getknob <KNOBNAME>
clearknob <KNOBNAME>
```

**その他**:

```bash
# バージョン取得
getversion

# テナント使用
usetenant myTenant
defaulttenant

# ヘルプ
help                # コマンド一覧
help escaping       # エスケープ方法
help options        # トランザクションオプション

# 終了
exit / quit
```

#### 実用例

**クラスタ初期化**:

```bash
fdbcli --exec "configure new single memory"
```

**データの確認**:

```bash
fdbcli --exec "writemode on; set test_key test_value; get test_key"
```

**ステータス監視**:

```bash
watch -n 5 'fdbcli --exec "status json" | jq ".cluster.qos"'
```

**バッチ操作**:

```bash
fdbcli <<EOF
writemode on
begin
set user:1 {"name":"Alice"}
set user:2 {"name":"Bob"}
commit
EOF
```

### ⚠️ CRITICAL: Subspace.pack() vs Subspace.subspace() の設計ガイドライン

> **重要**: この違いは**型システムで防げません**。開発者が正しいパターンを理解し、コードレビューで検証する必要があります。

#### 問題の本質

FoundationDBのSubspace APIには**2つの似たメソッド**があり、どちらもコンパイルが通りますが、**異なるキーエンコーディング**を生成します：

| メソッド | エンコーディング | 用途 |
|---------|----------------|------|
| `subspace.pack(tuple)` | **フラット** | インデックスキー、効率的なRange読み取り |
| `subspace.subspace(tuple)` | **ネスト**（\x05マーカー付き） | 階層的な論理構造、Directory Layer代替 |

**誤用の影響**:
- インデックススキャンが0件を返す（最も頻発するバグ）
- 実行時にしか検出できない
- テストで気づきにくい（データが少ない場合）

---

#### エンコーディングの違い（詳細）

```swift
let subspace = Subspace(prefix: [0x01])
let tuple = Tuple("category", 123)

// パターン1: pack() - フラットエンコーディング
let flatKey = subspace.pack(tuple)
// 結果: [0x01, 0x02, 'c','a','t','e','g','o','r','y', 0x00, 0x15, 0x01]
//       ^prefix  ^String marker  ^String data      ^end  ^Int64  ^value

// パターン2: subspace() - ネストエンコーディング
let nestedSubspace = subspace.subspace(tuple)
let nestedKey = nestedSubspace.pack(Tuple())
// 結果: [0x01, 0x05, 0x02, 'c','a','t','e','g','o','r','y', 0x00, 0x15, 0x01, 0x00, 0x00]
//       ^prefix  ^Nested marker  ^Tuple data                         ^end   ^empty tuple
```

**FoundationDB Tuple型マーカー**:
- `\x00`: Null / 終端
- `\x02`: String
- `\x05`: **Nested Tuple（重要！）**
- `\x15`: Int64（0の場合はintZero + value）

---

#### なぜインデックスキーはフラットであるべきか

**FoundationDBフォーラムの知見**（[参考](https://forums.foundationdb.org/t/whats-the-purpose-of-the-directory-layer/677/10)）:

> A.J. Beamon氏: "キーはサブスペースのプレフィックスを共有するが、ディレクトリではサブディレクトリのデータは親から分離される"

**インデックスキーの要件**:

1. **効率的なRange読み取り**: インデックス値でソートされ、連続したキー範囲をスキャン
2. **分散**: 異なるインデックス値が物理的に分散（ホットスポット回避）
3. **プライマリキーの連結**: `<indexValue><primaryKey>` の自然な順序

**フラットエンコーディングの利点**:
```
インデックスキー構造: <indexSubspace><indexValue><primaryKey>

例: category="Electronics", productID=1001
  キー: ...index_category\x00 + \x02Electronics\x00 + \x15{1001}

Range読み取り: category="Electronics"のすべての製品
  開始: ...index_category\x00 + \x02Electronics\x00
  終了: ...index_category\x00 + \x02Electronics\x00\xFF
  → 自然にソートされた順序で効率的にスキャン
```

**ネストエンコーディングの問題**:
```swift
// ❌ 間違った実装
let indexSubspace = subspace.subspace("I").subspace("category")
let categorySubspace = indexSubspace.subspace(Tuple("Electronics"))
let key = categorySubspace.pack(Tuple(productID))

// 生成されるキー: ...I\x00category\x00\x05\x02Electronics\x00\x00 + \x15{1001}
//                                      ^^^^^ ← 余計な\x05マーカー
// → IndexManagerが保存したフラットキーとマッチしない
```

---

#### レコードキーは階層的であるべき

**RecordStoreの設計意図**:

レコードキーは**論理的なグループ化**を目的としており、ネストエンコーディングが適切です：

```swift
// RecordStore.saveInternal() の実装
let recordKey = recordSubspace
    .subspace(Record.recordName)    // レベル1: レコードタイプ
    .subspace(primaryKey)            // レベル2: プライマリキー
    .pack(Tuple())                   // 空のTupleで終端

// 例: User(id=123)
// キー: <R-prefix> + \x05User\x00 + \x05\x15{123}\x00 + \x00
//                    ^^^^^^^^^^^^   ^^^^^^^^^^^^^^^^   ^^^
//                    レコードタイプ  プライマリキー      終端
```

**階層的エンコーディングの利点**:
1. **レコードタイプごとの分離**: 同じタイプのレコードが論理的にグループ化
2. **プレフィックススキャン**: 特定タイプのすべてのレコードを効率的に取得
3. **Directory Layer代替**: 動的ディレクトリ不要の軽量な階層構造

---

#### Java版Record Layerとの比較

Java版も同じSubspace APIを持ちますが、**明確な使い分けパターン**が確立されています：

##### StandardIndexMaintainer（Java版）

```java
// インデックスキー構築
public void updateIndexKeys(...) {
    for (IndexEntry entry : indexEntries) {
        // ✅ 正しい: pack()を使用（フラット）
        byte[] key = state.indexSubspace.pack(entry.getKey());
        tr.set(key, entry.getValue().pack());
    }
}
```

##### RankIndexMaintainer（Java版）

```java
// グループ化されたランキングインデックス
Subspace rankSubspace = extraSubspace.subspace(prefix);  // グループ化
byte[] key = rankSubspace.pack(scoreTuple);              // 最終キー生成
```

**Java版のルール**:
- `subspace()`: **論理的な階層構造**の作成（グループ化、Directory代替）
- `pack()`: **最終的なキー生成**（FoundationDBへの書き込み）

**Swift版が誤用した理由**:
RankIndexの`subspace(prefix)`パターンを見て、ValueIndexにも適用してしまった。しかしStandardIndexMaintainerの基本は**常にpack()を使用**。

---

#### 型システムで防げない理由

```swift
// どちらもコンパイルが通る
let key1 = indexSubspace.pack(tuple)              // ✅ 正しい
let key2 = indexSubspace.subspace(tuple).pack(Tuple())  // ❌ 間違い、でもコンパイル成功

// 型シグネチャが同じ
func pack(_ tuple: Tuple) -> FDB.Bytes
func subspace(_ tuple: Tuple) -> Subspace
```

**なぜ型で防げないか**:
1. どちらも有効なAPI（用途が異なるだけ）
2. 戻り値の型が異なるが、最終的に`FDB.Bytes`になる
3. Swift型システムでは「どのAPIチェーンを使ったか」を追跡できない

**将来的な改善案**（Optional）:
```swift
// 専用のビルダーパターンで型安全性を向上
protocol IndexKeyBuilder {
    func buildFlatKey(values: [TupleElement]) -> FDB.Bytes
}

// subspace()の使用を禁止
struct FlatIndexKeyBuilder: IndexKeyBuilder {
    let indexSubspace: Subspace

    func buildFlatKey(values: [TupleElement]) -> FDB.Bytes {
        return indexSubspace.pack(TupleHelpers.toTuple(values))
    }
}
```

---

#### 設計原則とベストプラクティス

##### ✅ インデックスキー構築の正しいパターン

```swift
// ValueIndex, CountIndex, SumIndex など
class GenericValueIndexMaintainer<Record: Sendable>: IndexMaintainer {
    func buildIndexKey(record: Record, recordAccess: any RecordAccess<Record>) throws -> FDB.Bytes {
        let indexedValues = try recordAccess.extractIndexValues(...)
        let primaryKeyValues = recordAccess.extractPrimaryKey(...)
        let allValues = indexedValues + primaryKeyValues

        // ✅ MUST: pack()を使用（フラット）
        return subspace.pack(TupleHelpers.toTuple(allValues))

        // ❌ NEVER: subspace()を使用しない
        // return subspace.subspace(TupleHelpers.toTuple(allValues)).pack(Tuple())
    }
}
```

```swift
// TypedIndexScanPlan
func execute(...) async throws -> AnyTypedRecordCursor<Record> {
    let indexSubspace = subspace.subspace("I").subspace(indexName)

    // ✅ MUST: pack()を使用
    let beginKey = indexSubspace.pack(beginTuple)
    var endKey = indexSubspace.pack(endTuple)

    // 等価クエリの場合のみ0xFFを追加
    if beginKey == endKey {
        endKey.append(0xFF)
    }
}
```

##### ✅ レコードキー構築の正しいパターン

```swift
// RecordStore
func saveInternal(_ record: Record, context: RecordContext) async throws {
    let primaryKey = recordAccess.extractPrimaryKey(from: record)

    // ✅ MUST: ネストされたsubspace()を使用
    let effectiveSubspace = recordSubspace.subspace(Record.recordName)
    let key = effectiveSubspace.subspace(primaryKey).pack(Tuple())

    // ❌ NEVER: フラットpack()を使用しない
    // let key = recordSubspace.pack(Tuple(Record.recordName, primaryKey))
}
```

```swift
// IndexScanTypedCursor
func next() async throws -> Record? {
    // インデックスキーからプライマリキーを抽出
    let primaryKeyTuple = // ...

    // ✅ MUST: RecordStoreと同じパターン
    let effectiveSubspace = recordSubspace.subspace(recordName)
    let recordKey = effectiveSubspace.subspace(primaryKeyTuple).pack(Tuple())
}
```

---

#### コードレビューチェックリスト

**インデックス関連コード**:

- [ ] `IndexMaintainer`実装でインデックスキー構築に`subspace.pack(tuple)`を使用しているか？
- [ ] `TypedQueryPlan`実装でインデックススキャンに`indexSubspace.pack(tuple)`を使用しているか？
- [ ] `subspace.subspace(tuple)`を使っている場合、本当に階層構造が必要か確認したか？
- [ ] 等価クエリで0xFF追加、範囲クエリでは追加しないパターンを守っているか？
- [ ] オープンエンド範囲（empty beginValues/endValues）で`subspace.range()`を使用しているか？

**レコード関連コード**:

- [ ] `RecordStore.save*()`でレコードキー構築に`subspace().subspace().pack(Tuple())`を使用しているか？
- [ ] `IndexScanTypedCursor`でレコードキー生成がRecordStoreと一致しているか？
- [ ] レコードタイプ名（recordName）をキーに含めているか？

**デバッグ時**:

- [ ] インデックススキャンが0件を返す場合、まずキーエンコーディングを確認したか？
- [ ] 実際のキーを16進数で出力して\x05マーカーの有無を確認したか？
- [ ] `IndexManager`と`TypedQueryPlan`で同じエンコーディングパターンを使用しているか確認したか？

---

#### デバッグ時の確認方法

```swift
// 実際に保存されているキーを16進数で確認
print("Key hex: \(key.map { String(format: "%02x", $0) }.joined(separator: " "))")

// 期待: ...02 45 6c 65 63 74 72 6f 6e 69 63 73 00 15 03 e9
//       ^String "Electronics"                   ^Int64 1001

// もし\x05が含まれていたら、ネストエンコーディングが使われている（誤り）
// 例: ...05 02 45 ... ← この05は間違い

// Tupleをアンパックして内容確認
if let unpacked = try? indexSubspace.unpack(key) {
    print("Tuple count: \(unpacked.count)")
    for i in 0..<unpacked.count {
        if let element = unpacked[i] {
            if let str = element as? String {
                print("[\(i)]: String(\"\(str)\")")
            } else if let int = element as? Int64 {
                print("[\(i)]: Int64(\(int))")
            }
        }
    }
}
```

---

#### まとめ

| 用途 | パターン | エンコーディング | 理由 |
|------|---------|----------------|------|
| **インデックスキー** | `subspace.pack(tuple)` | フラット | Range効率、分散、自然なソート順 |
| **レコードキー** | `subspace().subspace().pack(Tuple())` | ネスト | 論理的グループ化、階層構造 |
| **Directory代替** | `subspace(tuple)` | ネスト | 階層的な名前空間管理 |

**重要**:
- この違いは型システムで強制できない
- コードレビューとドキュメントで品質を保証
- Java版StandardIndexMaintainerのパターンを常に参照
- インデックススキャンが0件を返したら、まずエンコーディングを疑う

### データモデリングパターン

**パターン1: シンプルインデックス**

プライマリデータに対して属性ベースのインデックスを作成：

```swift
// プライマリデータ: (main, userID) = (name, zipcode)
transaction.setValue(Tuple(name, zipcode).pack(), for: mainSubspace.pack(Tuple(userID)))

// インデックス: (index, zipcode, userID) = ''
transaction.setValue([], for: indexSubspace.pack(Tuple(zipcode, userID)))

// ZIPコードで検索
let (begin, end) = indexSubspace.range(from: Tuple(zipcode), to: Tuple(zipcode, "\xFF"))
for try await (key, _) in transaction.getRange(
    beginSelector: .firstGreaterOrEqual(begin),
    endSelector: .firstGreaterOrEqual(end),
    snapshot: false
) {
    let tuple = try indexSubspace.unpack(key)
    let userID = tuple[1]  // 2番目の要素
}
```

**パターン2: 複合インデックス**

複数の属性でソート・フィルタリング：

```swift
// インデックスキー: (index, city, age, userID) = ''
let indexKey = indexSubspace.pack(Tuple("Tokyo", 25, userID))
transaction.setValue([], for: indexKey)

// 都市と年齢範囲で検索
let (begin, end) = indexSubspace.range(
    from: Tuple("Tokyo", 18),
    to: Tuple("Tokyo", 65)
)
```

**パターン3: カバリングインデックス**

インデックスから直接データ取得（プライマリデータへのアクセス不要）：

```swift
// カバリングインデックス: (index, zipcode, userID) = (name, otherData)
transaction.setValue(Tuple(name, otherData).pack(),
                     for: indexSubspace.pack(Tuple(zipcode, userID)))

// 1回のRange読み取りで完結
for try await (key, value) in transaction.getRange(...) {
    let data = try Tuple.unpack(from: value)
    let name = data[0] as? String
}
```

### トランザクション分離レベルと競合制御

FoundationDBはOCC（Optimistic Concurrency Control）を使用したStrict Serializabilityを提供します。

**分離レベル**:

| レベル | 動作 | 競合検知 | 用途 |
|--------|------|---------|------|
| **Strictly Serializable** (デフォルト) | 読み取りが競合範囲に追加される | あり | 通常のトランザクション |
| **Snapshot Read** | 読み取りが競合範囲に追加されない | なし | 読み取り専用、分析クエリ |

**Read-Your-Writes（RYW）動作**:

デフォルトで、トランザクション内の読み取りは同じトランザクション内の書き込みを見ることができます：

```swift
try await database.withTransaction { transaction in
    // 書き込み
    transaction.setValue([0x01], for: key)

    // 同じトランザクション内で読み取り → 書き込んだ値が見える
    let value = try await transaction.getValue(for: key, snapshot: false)
    // value == [0x01]
}
```

**競合検出の仕組み**:

1. **Read Version**: トランザクションの最初の読み取り時に読み取りバージョンを取得
2. **Conflict Range**: 読み取り・書き込みしたキー範囲を記録
3. **Commit Version**: コミット時に新しいバージョンを取得
4. **Conflict Check**: Resolverが、読み取りバージョンとコミットバージョンの間に他のトランザクションが書き込んだかをチェック
5. **競合時**: `not_committed`エラーで自動リトライ

**競合回避のテクニック**:

```swift
// 方法1: Snapshot Readを使用（競合なし）
let value = try await transaction.getValue(for: key, snapshot: true)

// 方法2: Atomic Operationを使用（読み取り競合なし）
transaction.atomicOp(
    key: counterKey,
    param: withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) },
    mutationType: .add
)

// 方法3: Read-Your-Writesを無効化（小さなパフォーマンス向上）
// transaction.setOption(.readYourWritesDisable)
```

### アトミック操作（MutationType）

FoundationDBは読み取り-変更-書き込みサイクルを1つの操作にまとめた**アトミック操作**を提供します。これにより、頻繁に更新されるキー（カウンターなど）の競合を最小化できます。

**主要なアトミック操作**:

| 操作 | 説明 | 用途 |
|------|------|------|
| **ADD** | Little-endian整数の加算 | カウンター、残高の増減 |
| **BIT_AND** | ビット単位のAND | フラグのクリア |
| **BIT_OR** | ビット単位のOR | フラグのセット |
| **BIT_XOR** | ビット単位のXOR | フラグのトグル |
| **MAX** | 既存値とparamの大きい方を保存 | 最大値の追跡 |
| **MIN** | 既存値とparamの小さい方を保存 | 最小値の追跡 |
| **BYTE_MAX** | 辞書順で大きい方を保存 | 文字列の最大値 |
| **BYTE_MIN** | 辞書順で小さい方を保存 | 文字列の最小値 |
| **APPEND_IF_FITS** | 既存値にparamを追加（100KB以下の場合） | ログの追記 |
| **COMPARE_AND_CLEAR** | 既存値がparamと等しい場合にクリア | 条件付きクリア |
| **SET_VERSIONSTAMPED_KEY** | キーにversionstampを埋め込む | 一意で順序付けられたキー |
| **SET_VERSIONSTAMPED_VALUE** | 値にversionstampを埋め込む | タイムスタンプ付きデータ |

**使用例**:

```swift
// ADDでカウンターをインクリメント
let incrementBytes = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
transaction.atomicOp(key: counterKey, param: incrementBytes, mutationType: .add)

// MAXで最大値を更新
let newMax = withUnsafeBytes(of: Int64(1000).littleEndian) { Array($0) }
transaction.atomicOp(key: maxValueKey, param: newMax, mutationType: .max)

// APPEND_IF_FITSでログエントリを追加
let logEntry = "Event: User login at \(Date())".data(using: .utf8)!
transaction.atomicOp(key: logKey, param: Array(logEntry), mutationType: .appendIfFits)
```

**重要な特性**:
- **競合回避**: アトミック操作は読み取り競合範囲を追加しない → 高い並行性
- **非冪等性**: 一部の操作（ADD、APPEND_IF_FITSなど）は冪等ではないため、`commit_unknown_result`エラー時の対応に注意
- **パラメータエンコーディング**: paramは適切にエンコードされたバイト列である必要がある

### Versionstamp

**Versionstamp**は、FoundationDBがコミット時に割り当てる12バイトの一意で単調増加する値です。AUTO_INCREMENT PRIMARY KEYに相当する機能を提供します。

**構造**:

```
[8バイト: トランザクションバージョン][2バイト: バッチバージョン][2バイト: ユーザーバージョン]
 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^       ^^^^^^^^^^^^^^^^^^       ^^^^^^^^^^^^^^^^^^
 Big-endian                           Big-endian               ユーザー定義順序
 データベースのコミットバージョン      同一バッチ内の順序       トランザクション内の順序
```

**使用例**:

```swift
// 1. Incomplete Versionstampを含むキーを作成
var keyBytes = Tuple("log", Versionstamp.incomplete()).pack()

// 2. SET_VERSIONSTAMPED_KEYでコミット時にversionstampを埋め込む
transaction.atomicOp(
    key: keyBytes,
    param: logDataBytes,
    mutationType: .setVersionstampedKey
)

// 3. コミット後、実際のversionstampを取得
try await transaction.commit()
let versionstamp = try await transaction.getVersionstamp()
```

**主な用途**:

1. **ログスキャン**: 時系列順にデータを効率的に取得
2. **追記専用データ構造**: 読み取り競合なしでデータを追加
3. **グローバル順序**: すべてのトランザクションにわたる順序を保証
4. **トランザクション内の順序**: ユーザーバージョンで同一トランザクション内の順序を定義

**注意**:
- Versionstampは単一FoundationDBクラスタのライフタイム全体で一意性と単調性を保証
- 異なるクラスタ間でデータを移動する場合、単調性が崩れる可能性がある

### Watch操作

**Watch**は特定のキーの変更を監視する仕組みで、ポーリング不要のリアクティブプログラミングを可能にします。

**仕組み**:

```swift
try await database.withTransaction { transaction in
    // 現在の値を取得
    let currentValue = try await transaction.getValue(for: key, snapshot: false)

    // Watchを作成（トランザクションコミット後に変更を監視）
    let watch = transaction.watch(key: key)

    try await transaction.commit()

    // 値が変更されるまで待機
    try await watch.wait()
    print("Key '\(key)' changed!")
}
```

**制限事項**:

1. **トランザクション依存**: Watchを作成したトランザクションがコミットされるまで、他のトランザクションの変更を報告しない
2. **Read-Your-Writes無効時**: `readYourWritesDisable`が設定されている場合、Watchを作成できない
3. **エラー処理**: トランザクションがコミット失敗した場合、Watchもエラーになる
4. **Watch制限**: デフォルトで1接続あたり10,000個まで（`too_many_watches`エラー）
5. **値の保証なし**: Watchは変更があったことだけを保証し、その後の読み取り値を保証しない

**リアクティブな読み取りループの例**:

```swift
func watchingReadLoop(database: any DatabaseProtocol, keys: [FDB.Bytes]) async throws {
    var cache: [FDB.Bytes: FDB.Bytes?] = [:]

    while true {
        // 値を読み取り、Watchを作成
        var watches: [Task<Void, Error>] = []
        try await database.withTransaction { transaction in
            for key in keys {
                let value = try await transaction.getValue(for: key, snapshot: false)

                if cache[key] != value {
                    print("Key changed: \(key) -> \(value)")
                    cache[key] = value
                }

                let watch = transaction.watch(key: key)
                watches.append(Task {
                    try await watch.wait()
                })
            }
        }

        // いずれかのWatchが発火するまで待機
        _ = try await Task.race(watches)
    }
}
```

### パフォーマンスチューニング

#### キー設計パターン

**ベストプラクティス**:

1. **小さいキーサイズ**: 1KB以下、理想は32バイト以下
2. **適度な値サイズ**: 10KB以下推奨、100KB上限
3. **Range読み取り用の構造化**: 頻繁にアクセスするデータを効率的に取得できるキー設計
4. **順序保持エンコーディング**: Tuple Layerを使用して型安全かつ順序保持

**複合キーの例**:

```swift
// ユーザーの購入履歴: (purchases, userID, timestamp) = orderData
let key = purchasesSubspace.pack(Tuple(userID, timestamp))
transaction.setValue(orderData, for: key)

// 特定ユーザーの履歴を時系列で取得
let (begin, end) = purchasesSubspace.range(from: Tuple(userID), to: Tuple(userID, "\xFF"))
for try await (key, value) in transaction.getRange(
    beginSelector: .firstGreaterOrEqual(begin),
    endSelector: .firstGreaterOrEqual(end),
    snapshot: true
) {
    // 処理
}
```

#### ホットスポット回避

**問題**: 単一キーへの頻繁な更新（毎秒10-100回以上）は競合を引き起こす

**解決策**:

1. **キーの分割**: カウンターをN個に分割してランダムに更新

```swift
// カウンターを10個に分割
let shardID = Int.random(in: 0..<10)
let shardKey = counterSubspace.pack(Tuple("counter", shardID))
transaction.atomicOp(key: shardKey, param: incrementBytes, mutationType: .add)

// 合計を取得
var total: Int64 = 0
for shardID in 0..<10 {
    let key = counterSubspace.pack(Tuple("counter", shardID))
    if let bytes = try await transaction.getValue(for: key, snapshot: true) {
        total += bytes.withUnsafeBytes { $0.load(as: Int64.self) }
    }
}
```

2. **アトミック操作の使用**: ADDやMAXなどは読み取り競合を発生させない

3. **Snapshot Readの使用**: 読み取りのみの操作で競合を削減

#### トランザクションバッチング

FoundationDBは高い並行性で最大スループットを達成します：

1. **暗黙のバッチング**: Commit ProxyとGRV Proxyが自動的にリクエストをバッチ処理
2. **クライアント側の並行性**: 多数の並行スレッド/プロセスで十分なリクエストを発行
3. **並列読み取り**: 単一トランザクション内で複数の読み取りを並列実行

```swift
// ❌ 悪い例: 順次読み取り
let value1 = try await transaction.getValue(for: key1, snapshot: false)
let value2 = try await transaction.getValue(for: key2, snapshot: false)
let value3 = try await transaction.getValue(for: key3, snapshot: false)

// ✅ 良い例: 並列読み取り
async let value1 = transaction.getValue(for: key1, snapshot: false)
async let value2 = transaction.getValue(for: key2, snapshot: false)
async let value3 = transaction.getValue(for: key3, snapshot: false)
let results = try await (value1, value2, value3)
```

#### モニタリング戦略

**fdbcli status**:

```bash
$ fdbcli
fdb> status

# 主要メトリクス:
# - Read rate: 読み取りスループット
# - Write rate: 書き込みスループット
# - Transactions started/committed: トランザクション数
# - Conflict rate: 競合率（高い場合は最適化が必要）
```

**status json**（詳細メトリクス）:

```bash
fdb> status json

# チェック項目:
# - cluster.workload.operations.reads: 読み取り操作数
# - cluster.workload.operations.writes: 書き込み操作数
# - cluster.qos.worst_queue_bytes_storage_server: ストレージサーバーのキュー
# - cluster.processes[].memory.available_bytes: 利用可能メモリ（4GB以上推奨）
```

**Swift APIでのメトリクス取得**:

```swift
// \xff/metrics/ のSpecial Key Spaceを使用
let metricsSubspace = Subspace(prefix: [0xFF, 0xFF] + "/metrics/".data(using: .utf8)!)
let (begin, end) = metricsSubspace.range()

try await database.withTransaction { transaction in
    for try await (key, value) in transaction.getRange(
        beginSelector: .firstGreaterOrEqual(begin),
        endSelector: .firstGreaterOrEqual(end),
        snapshot: true
    ) {
        print("Metric: \(String(data: Data(key), encoding: .utf8)!) = \(value)")
    }
}
```

### エラーハンドリング

```swift
public struct FDBError: Error {
    public let code: Int32
    public var isRetryable: Bool
}

// 主要なエラー
// 1007: transaction_too_old（5秒超過）
// 1020: not_committed（競合、自動リトライ）
// 1021: commit_unknown_result（冪等な場合のみリトライ）
// 1031: transaction_timed_out（タイムアウト制限）
// 2101: transaction_too_large（サイズ制限超過）
```

**冪等性の確保**:
```swift
// 悪い例（非冪等）
func deposit(transaction: TransactionProtocol, accountID: String, amount: Int64) async throws {
    transaction.atomicOp(key: balanceKey, param: amountBytes, mutationType: .add)
    // 問題: リトライ時に重複入金の可能性
}

// 良い例（冪等）
func deposit(transaction: TransactionProtocol, accountID: String, depositID: String, amount: Int64) async throws {
    let depositKey = depositSubspace.pack(Tuple(accountID, "deposit", depositID))

    // 既に処理済みかチェック
    if let _ = try await transaction.getValue(for: depositKey, snapshot: false) {
        return  // 既に成功済み
    }

    // 処理を実行
    transaction.setValue(amountBytes, for: depositKey)
    transaction.atomicOp(key: balanceKey, param: amountBytes, mutationType: .add)
}
```

### Subspaceの正しい使い方

> **重要**: Subspaceの誤った使い方は、インデックスエントリが見つからないなどの深刻なバグを引き起こします。

#### Subspace.subspace()の仕様

`Subspace.subspace()`はvariadic引数を取り、各引数をTuple要素として扱います：

```swift
public func subspace(_ elements: any TupleElement...) -> Subspace {
    let tuple = Tuple(elements)
    return Subspace(prefix: prefix + tuple.pack())
}
```

#### ❌ 間違った使い方

**問題**: `Tuple`オブジェクトを渡すと、**ネストされたタプル**としてエンコードされます。

```swift
// ❌ 間違い: Tupleオブジェクトを渡す
let indexSubspace = subspace.subspace(Tuple("I"))
// エンコード結果: 05 02 49 00 ff 00 (ネストされたタプル)
//   05 = ネストされたタプル型コード
//   02 = 文字列型コード
//   49 00 = "I"

let indexNameSubspace = indexSubspace.subspace(Tuple(["product_by_category"]))
// エンコード結果: 05 02 70 72 6f... (さらにネストされる)

// ❌ 間違い: 配列を含むTupleを渡す
let keyPrefix = indexNameSubspace.subspace(Tuple(["Electronics"]))
// エンコード結果: 05 02 45 6c... (ネストされたタプル)

// 結果: インデックスキーの構造が不一致で、Range読み取りが失敗
// 書き込まれたキー: ...02 45 6c 65 63 74 72 6f 6e 69 63 73 00 15 01
// クエリのキー:     ...05 02 45 6c 65 63 74 72 6f 6e 69 63 73 00 ff 00 00
//                      ^^^^^ ネストされたタプル型コード（不一致！）
```

#### ✅ 正しい使い方

**解決策**: Tupleオブジェクトではなく、**直接値を渡す**。

```swift
// ✅ 正しい: 直接文字列を渡す
let indexSubspace = subspace.subspace("I")
// エンコード結果: 02 49 00 (文字列型)
//   02 = 文字列型コード
//   49 00 = "I"

let indexNameSubspace = indexSubspace.subspace("product_by_category")
// エンコード結果: 02 70 72 6f... (文字列型)

// ✅ 正しい: 直接値を渡す
let keyPrefix = indexNameSubspace.subspace("Electronics")
// エンコード結果: 02 45 6c... (文字列型)

// ✅ 正しい: 数値も直接渡す
let priceSubspace = indexNameSubspace.subspace(300)
// エンコード結果: 15 2c 01 (整数型)

// ✅ 正しい: 複数の値を渡す（Tupleは不要）
let compositeSubspace = subspace.subspace("users", "active", 12345)
// エンコード結果: 02 75 73... 02 61 63... 15 39 30...
```

#### 実際のバグ例

**症状**: インデックスエントリが見つからない（count = 0）

```swift
// ❌ バグのあるコード
func countIndexEntries(
    indexSubspace: Subspace,
    indexName: String,
    keyPrefix: Tuple  // ← Tupleオブジェクトを受け取る
) async throws -> Int {
    let indexNameSubspace = indexSubspace.subspace(Tuple([indexName]))  // ❌ 間違い
    let rangeSubspace = indexNameSubspace.subspace(keyPrefix)          // ❌ 間違い
    let (begin, end) = rangeSubspace.range()

    var count = 0
    for try await _ in transaction.getRange(begin: begin, end: end) {
        count += 1  // ← 常に0（キー構造が不一致）
    }
    return count
}

// ✅ 修正後のコード
func countIndexEntries(
    indexSubspace: Subspace,
    indexName: String,
    keyPrefix: Tuple  // Tupleは引数として受け取るが...
) async throws -> Int {
    let indexNameSubspace = indexSubspace.subspace(indexName)  // ✅ 直接文字列を渡す

    // TupleからTupleElementsを抽出して個別に渡す
    let elements = keyPrefix.elements
    let rangeSubspace: Subspace
    if elements.count == 1 {
        rangeSubspace = indexNameSubspace.subspace(elements[0])  // ✅ 個別の要素を渡す
    } else {
        // 複数要素の場合もvariadic引数として展開
        rangeSubspace = elements.reduce(indexNameSubspace) { subspace, element in
            subspace.subspace(element)
        }
    }

    let (begin, end) = rangeSubspace.range()

    var count = 0
    for try await _ in transaction.getRange(begin: begin, end: end) {
        count += 1  // ✅ 正しくカウントされる
    }
    return count
}
```

#### プロジェクト全体での修正パターン

このプロジェクトで見つかった誤用箇所と修正：

```bash
# ❌ 間違ったパターンを検索
grep -r "\.subspace(Tuple(\[" Sources/ Tests/

# ✅ 一括修正（例）
sed -i '' 's/\.subspace(Tuple("\([^"]*\)"))/\.subspace("\1")/g' file.swift
sed -i '' 's/\.subspace(Tuple(\[\([0-9]*\)\]))/\.subspace(\1)/g' file.swift
sed -i '' 's/\.subspace(Tuple(\["\([^"]*\)"\]))/\.subspace("\1")/g' file.swift
```

**修正が必要だった箇所**:
- `RecordStore.swift`: `recordSubspace.subspace(Tuple([Record.recordName]))` → `recordSubspace.subspace(Record.recordName)`
- `IndexManager.swift`: `subspace.subspace(Tuple([indexName]))` → `subspace.subspace(indexName)`
- `RecordStoreIndexIntegrationTests.swift`: すべての`Tuple([...])`パターン
- `DebugIndexKeysTests.swift`: すべての`Tuple([...])`パターン

#### まとめ

| 操作 | ❌ 間違い | ✅ 正しい |
|------|----------|----------|
| 文字列subspace | `.subspace(Tuple("I"))` | `.subspace("I")` |
| 配列からsubspace | `.subspace(Tuple(["name"]))` | `.subspace("name")` |
| 数値subspace | `.subspace(Tuple([300]))` | `.subspace(300)` |
| 変数からsubspace | `.subspace(Tuple([indexName]))` | `.subspace(indexName)` |
| 複数要素 | `.subspace(Tuple("a", "b"))` | `.subspace("a", "b")` |

**覚え方**:
- `Subspace.subspace()`は**variadic引数**を直接受け取る
- `Tuple`オブジェクトは**絶対に渡さない**
- 配列リテラル`[...]`も**絶対に使わない**

---

## Part 2: fdb-swift-bindings API

### DatabaseProtocol と TransactionProtocol

```swift
public protocol DatabaseProtocol {
    func createTransaction() throws -> Transaction
    func withTransaction<T: Sendable>(
        _ operation: (TransactionProtocol) async throws -> T
    ) async throws -> T
}

public protocol TransactionProtocol: Sendable {
    func getValue(for key: FDB.Bytes, snapshot: Bool) async throws -> FDB.Bytes?
    func setValue(_ value: FDB.Bytes, for key: FDB.Bytes)
    func clear(key: FDB.Bytes)
    func clearRange(beginKey: FDB.Bytes, endKey: FDB.Bytes)
    func getRange(beginSelector: FDB.KeySelector, endSelector: FDB.KeySelector, snapshot: Bool) -> FDB.AsyncKVSequence
    func atomicOp(key: FDB.Bytes, param: FDB.Bytes, mutationType: FDB.MutationType)
    func commit() async throws -> Bool
}
```

### Tuple

```swift
// サポート型: String, Int64, Bool, Float, Double, UUID, Bytes, Tuple, Versionstamp
let tuple = Tuple(userID, "alice@example.com")
let packed = tuple.pack()
let elements = try Tuple.unpack(from: packed)

// 注意: Tuple equality is based on encoded bytes
Tuple(0.0) != Tuple(-0.0)  // true
```

### Subspace

```swift
let root = Subspace(prefix: Tuple("app").pack())
let records = root["records"]
let indexes = root["indexes"]

// キー操作
let key = records.pack(Tuple(123))
let tuple = try records.unpack(key)

// Range読み取り
let (begin, end) = records.range()
for try await (k, v) in transaction.getRange(
    beginSelector: .firstGreaterOrEqual(begin),
    endSelector: .firstGreaterOrEqual(end),
    snapshot: false
) { }

// range() vs prefixRange()
// range(): (prefix + [0x00], prefix + [0xFF]) - Tuple-encodedデータ用
// prefixRange(): (prefix, strinc(prefix)) - Raw binaryプレフィックス用
```

### DirectoryLayer

```swift
public final class DirectoryLayer: Sendable {
    public func createOrOpen(path: [String], type: DirectoryType?) async throws -> DirectorySubspace
    public func create(path: [String], type: DirectoryType?, prefix: FDB.Bytes?) async throws -> DirectorySubspace
    public func open(path: [String]) async throws -> DirectorySubspace?
    public func move(oldPath: [String], newPath: [String]) async throws -> DirectorySubspace
    public func remove(path: [String]) async throws -> Bool
    public func exists(path: [String]) async throws -> Bool
}

// DirectoryType
public enum DirectoryType {
    case partition  // 独立した名前空間、マルチテナント向け
    case custom(String)
}
```

**使用例**:
```swift
let dir = try await directoryLayer.createOrOpen(
    path: ["tenants", accountID, "orders"],
    type: .partition
)
let recordStore = RecordStore(database: database, subspace: dir.subspace, metaData: metaData)
```

---

## Part 3: Swift並行性パターン

### final class + Mutex パターン

**重要**: このプロジェクトは `actor` を使用せず、`final class: Sendable` + `Mutex` パターンを採用。

**理由**: スループット最適化
- actorはシリアライズされた実行 → 低スループット
- Mutexは細粒度ロック → 高い並行性
- データベースI/O中も他のタスクを実行可能

**実装パターン**:
```swift
import Synchronization

public final class ClassName<Record: Sendable>: Sendable {
    // 1. DatabaseProtocolは内部的にスレッドセーフ
    nonisolated(unsafe) private let database: any DatabaseProtocol

    // 2. 可変状態はMutexで保護
    private let stateLock: Mutex<MutableState>

    private struct MutableState {
        var counter: Int = 0
        var isRunning: Bool = false
    }

    public init(database: any DatabaseProtocol) {
        self.database = database
        self.stateLock = Mutex(MutableState())
    }

    // 3. withLockで状態アクセス
    public func operation() async throws {
        let count = stateLock.withLock { state in
            state.counter += 1
            return state.counter
        }

        try await database.run { transaction in
            // I/O中、他のタスクは getProgress() などを呼べる
        }
    }
}
```

**ガイドライン**:
1. ✅ `final class: Sendable` を使用（actorは使用しない）
2. ✅ `DatabaseProtocol` には `nonisolated(unsafe)` を使用
3. ✅ 可変状態は `Mutex<State>` で保護
4. ✅ ロックスコープは最小限（I/Oを含めない）

---

## Part 4: Record Layer設計

### インデックス状態管理

**3状態遷移**: disabled → writeOnly → readable

```swift
public enum IndexState: String, Sendable {
    case disabled   // 維持されず、クエリ不可
    case writeOnly  // 維持されるがクエリ不可（構築中）
    case readable   // 完全に構築され、クエリ可能
}
```

### インデックスタイプ

#### VALUE インデックス（B-tree）

標準的なインデックス。フィールド値でのルックアップとRange検索が可能。

```swift
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email")
)
```

**インデックス構造**: `[indexSubspace][email][primaryKey] = []`

#### COUNT インデックス（集約）

グループごとのレコード数をカウント。

```swift
let cityCountIndex = Index(
    name: "user_count_by_city",
    type: .count,
    rootExpression: FieldKeyExpression(fieldName: "city")
)

// 使用例: 東京のユーザー数を取得
let count = try await store.evaluateAggregate(
    .count(indexName: "user_count_by_city"),
    groupBy: ["Tokyo"]
)
```

**インデックス構造**: `[indexSubspace][groupingValue] = Int64（カウント）`

#### SUM インデックス（集約）

グループごとの値の合計を計算。

```swift
let salaryByDeptIndex = Index(
    name: "salary_by_dept",
    type: .sum,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "department"),
        FieldKeyExpression(fieldName: "salary")
    ])
)

// 使用例: エンジニアリング部門の給与合計
let total = try await store.evaluateAggregate(
    .sum(indexName: "salary_by_dept"),
    groupBy: ["Engineering"]
)
```

**インデックス構造**: `[indexSubspace][groupingValue] = Int64（合計）`

#### MIN/MAX インデックス（集約）

グループごとの最小値・最大値を効率的に取得（O(log n)）。

**インデックス定義**:
```swift
// MIN インデックス: [region, amount] → 地域ごとの最小金額
let minIndex = Index(
    name: "amount_min_by_region",
    type: .min,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "region"),    // グルーピングフィールド
        FieldKeyExpression(fieldName: "amount")     // 値フィールド
    ])
)

// MAX インデックス: [region, amount] → 地域ごとの最大金額
let maxIndex = Index(
    name: "amount_max_by_region",
    type: .max,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "region"),    // グルーピングフィールド
        FieldKeyExpression(fieldName: "amount")     // 値フィールド
    ])
)
```

**インデックス構造**: `[indexSubspace][groupingValue][value][primaryKey] = []`

- キーは辞書順にソートされるため、MIN = 最初のキー、MAX = 最後のキー
- O(log n)で取得可能（Key Selectorを使用）

**使用例**:
```swift
// RecordStore経由（推奨）
let minAmount = try await store.evaluateAggregate(
    .min(indexName: "amount_min_by_region"),
    groupBy: ["North"]
)

let maxAmount = try await store.evaluateAggregate(
    .max(indexName: "amount_max_by_region"),
    groupBy: ["North"]
)

// 内部ヘルパー関数（低レベルAPI）
let min = try await findMinValue(
    index: index,
    subspace: indexSubspace,
    groupingValues: ["North"],
    transaction: transaction
)
```

**重要な制約**:
- グルーピング値の数は `index.rootExpression.columnCount - 1` と一致する必要がある
- 例: インデックスが `[country, region, amount]` の場合、`groupBy: ["USA", "East"]`（2値）が正しい
- 不一致の場合は詳細なエラーメッセージとともに `RecordLayerError.invalidArgument` を返す

**エラーメッセージの詳細化**:
```
// グルーピング値が少ない場合
Grouping values count (1) does not match expected count (2) for index 'amount_min_by_country_region'
Expected grouping fields: [country, region]
Value field: amount
Provided values: ["USA"]
Missing: [region]

// グルーピング値が多い場合
Grouping values count (3) does not match expected count (2) for index 'amount_min_by_country_region'
Expected grouping fields: [country, region]
Value field: amount
Provided values: ["USA", "East", "Extra"]
Extra values: ["Extra"]
```

**内部実装**:
```swift
// MIN: 最初のキーを取得
let selector = FDB.KeySelector.firstGreaterOrEqual(range.begin)
let firstKey = try await transaction.getKey(selector: selector, snapshot: true)
let value = extractNumericValue(dataElements[0])  // O(1)

// MAX: 最後のキーを取得
let selector = FDB.KeySelector.lastLessThan(range.end)
let lastKey = try await transaction.getKey(selector: selector, snapshot: true)
let value = extractNumericValue(dataElements[0])  // O(1)
```

**対応する数値型**: Int64, Int, Int32, Double, Float（すべてInt64に変換）

### RangeSet（進行状況追跡）

オンライン操作（インデックス構築、スクラビング）の進行状況を追跡する仕組み：

```swift
public final class RangeSet: Sendable {
    // 完了したRange（閉区間）を記録
    // キー: (rangeSet, begin) → end

    public func insertRange(begin: FDB.Bytes, end: FDB.Bytes, transaction: TransactionProtocol) async throws
    public func contains(key: FDB.Bytes, transaction: TransactionProtocol) async throws -> Bool
    public func missingRanges(begin: FDB.Bytes, end: FDB.Bytes, transaction: TransactionProtocol) async throws -> [(FDB.Bytes, FDB.Bytes)]
}
```

**使用例**:
```swift
// インデックス構築の進行状況を記録
let rangeSet = RangeSet(database: database, subspace: progressSubspace)

// バッチ処理
for batch in batches {
    // レコードをスキャンしてインデックスエントリを作成
    try await processBatch(batch, transaction: transaction)

    // 完了したRangeを記録
    try await rangeSet.insertRange(
        begin: batch.startKey,
        end: batch.endKey,
        transaction: transaction
    )
}

// 中断からの再開: 未完了のRangeを取得
let missingRanges = try await rangeSet.missingRanges(
    begin: totalBeginKey,
    end: totalEndKey,
    transaction: transaction
)
```

### オンラインインデックス構築

```swift
public final class OnlineIndexer<Record: Sendable>: Sendable {
    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let lock: Mutex<IndexBuildState>

    private struct IndexBuildState {
        var totalRecordsScanned: UInt64 = 0
        var isRunning: Bool = false
    }

    public func buildIndex() async throws {
        // 1. インデックスを writeOnly 状態に設定
        try await indexStateManager.setState(index: indexName, state: .writeOnly)

        // 2. RangeSetで進行状況を追跡しながらバッチ処理
        let rangeSet = RangeSet(database: database, subspace: progressSubspace)
        let missingRanges = try await rangeSet.missingRanges(...)

        for (begin, end) in missingRanges {
            try await database.withTransaction { transaction in
                // レコードをスキャン
                let sequence = transaction.getRange(
                    beginSelector: .firstGreaterOrEqual(begin),
                    endSelector: .firstGreaterOrEqual(end),
                    snapshot: false
                )

                var batch: [(key: FDB.Bytes, value: FDB.Bytes)] = []
                for try await (key, value) in sequence {
                    batch.append((key, value))
                    if batch.count >= batchSize { break }
                }

                // インデックスエントリを作成
                for (key, value) in batch {
                    let record = try serializer.deserialize(value)
                    let indexEntry = evaluateIndexExpression(record)
                    transaction.setValue([], for: indexSubspace.pack(indexEntry))
                }

                // 進行状況を記録
                try await rangeSet.insertRange(begin: begin, end: batch.last!.key, transaction: transaction)
            }
        }

        // 3. インデックスを readable 状態に設定
        try await indexStateManager.setState(index: indexName, state: .readable)
    }

    public func getProgress() async throws -> (scanned: UInt64, total: UInt64, percentage: Double) {
        return lock.withLock { state in
            let percentage = total > 0 ? Double(state.totalRecordsScanned) / Double(total) : 0.0
            return (state.totalRecordsScanned, total, percentage)
        }
    }
}
```

**重要な特性**:
- **再開可能**: RangeSetにより中断された場所から再開
- **バッチ処理**: トランザクション制限（5秒、10MB）を遵守
- **並行安全**: 同じインデックスに対する複数のビルダーは競合しない（RangeSetで調整）
- **進行状況追跡**: リアルタイムで進捗を確認可能

### クエリプランナー

**TypedRecordQueryPlanner**: コストベース最適化

```swift
public struct TypedRecordQueryPlanner<Record: Sendable> {
    private let statisticsManager: any StatisticsManagerProtocol

    public func plan(query: TypedRecordQuery<Record>) async throws -> any TypedQueryPlan<Record> {
        // 1. フィルタ正規化（DNF変換）
        let normalizedFilters = normalizeToDNF(query.filters)

        // 2. 各候補プランのコスト計算
        var candidates: [(plan: TypedQueryPlan<Record>, cost: Double)] = []

        // フルスキャンプラン
        let fullScanCost = estimateFullScanCost()
        candidates.append((TypedScanPlan(), fullScanCost))

        // インデックススキャンプラン
        for index in availableIndexes {
            if let indexPlan = tryIndexPlan(index: index, filters: normalizedFilters) {
                let selectivity = statisticsManager.estimateSelectivity(
                    index: index,
                    filters: normalizedFilters
                )
                let cost = estimateIndexCost(index: index, selectivity: selectivity)
                candidates.append((indexPlan, cost))
            }
        }

        // 3. 最小コストのプランを選択
        return candidates.min(by: { $0.cost < $1.cost })!.plan
    }
}
```

**StatisticsManager**: ヒストグラムベースの統計情報管理

```swift
public final class StatisticsManager: Sendable {
    // ヒストグラム: (stats, indexName, bucketID) → (min, max, count)

    public func collectStatistics(
        index: Index,
        sampleRate: Double = 0.01
    ) async throws {
        // サンプリングしてヒストグラム構築
        var buckets: [Bucket] = []

        try await database.withTransaction { transaction in
            let sequence = transaction.getRange(...)

            for try await (key, _) in sequence where shouldSample(sampleRate) {
                let value = extractIndexValue(key)
                addToBucket(&buckets, value: value)
            }

            // ヒストグラムを保存
            for bucket in buckets {
                let statsKey = statsSubspace.pack(Tuple(index.name, bucket.id))
                transaction.setValue(
                    Tuple(bucket.min, bucket.max, bucket.count).pack(),
                    for: statsKey
                )
            }
        }
    }

    public func estimateSelectivity(
        index: Index,
        filters: [Filter]
    ) -> Double {
        // ヒストグラムから選択性を推定
        // 例: city == "Tokyo" → ヒストグラムでTokyoのバケットを検索
        let bucket = findBucket(index: index, value: filterValue)
        return Double(bucket.count) / Double(totalRecords)
    }
}
```

**クエリ最適化の例**:

```swift
// クエリ: 東京在住の25-35歳のユーザー
let query = QueryBuilder<User>()
    .filter(\.city == "Tokyo")
    .filter(\.age >= 25)
    .filter(\.age <= 35)
    .build()

// プランナーの判断:
// - Option 1: フルスキャン → コスト = 100,000（全レコード数）
// - Option 2: city インデックス → 選択性 = 10%（東京: 10,000人）→ コスト = 10,000
// - Option 3: city_age 複合インデックス → 選択性 = 1%（東京25-35歳: 1,000人）→ コスト = 1,000
// → city_age インデックスを選択
```

### Record Layerアーキテクチャ

**Subspace構造**:
```
rootSubspace/
├── records/          # レコードデータ
├── indexes/          # インデックスデータ
│   ├── user_by_email/
│   └── user_by_city_age/
├── metadata/         # メタデータ
└── state/           # インデックス状態
```

**インデックスタイプ**:

| タイプ | キー構造 | 値 | 用途 |
|--------|---------|-----|------|
| **VALUE** | (index, field..., primaryKey) | '' | 基本的な検索、Range読み取り |
| **COUNT** | (index, groupKey) | count | グループごとの集約 |
| **SUM** | (index, groupKey) | sum | 数値フィールドの集約 |
| **MIN/MAX** | (index, groupKey) | min/max | 最小/最大値の追跡 |

**VALUE Index**:
```swift
// インデックスキー: (index, email, userID) = ''
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "email"),
        FieldKeyExpression(fieldName: "userID")
    ])
)

// 使用例
let query = QueryBuilder<User>()
    .filter(\.email == "alice@example.com")
    .build()
// → emailIndexを使用してRange読み取り
```

**COUNT Index**:
```swift
// インデックスキー: (index, city) → count（アトミック操作で更新）
let cityCount = Index(
    name: "user_count_by_city",
    type: .count,
    rootExpression: FieldKeyExpression(fieldName: "city")
)

// レコード追加時
transaction.atomicOp(
    key: countIndexSubspace.pack(Tuple("Tokyo")),
    param: withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) },
    mutationType: .add
)
```

**複合インデックス**:
```swift
// 都市と年齢で検索可能
let cityAgeIndex = Index(
    name: "user_by_city_age",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "age"),
        FieldKeyExpression(fieldName: "userID")
    ])
)

// 使用例: 東京在住の18-65歳
let (begin, end) = indexSubspace.range(
    from: Tuple("Tokyo", 18),
    to: Tuple("Tokyo", 65)
)
```

### マクロAPI（完全実装済み）

SwiftData風の宣言的APIで、型安全なレコード定義が可能です：

```swift
@Recordable
struct User {
    #Unique<User>([\.email])
    #Index<User>([\.city, \.age])
    #Directory<User>("tenants", Field(\.tenantID), "users", layer: .partition)
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var email: String
    var city: String
    var age: Int

    @Default(value: Date())
    var createdAt: Date

    @Transient var isLoggedIn: Bool = false
}

// 使用例: マクロが自動生成したstoreメソッドを使用
let schema = Schema([User.self])
let store = try await User.store(
    tenantID: "tenant-123",
    database: database,
    schema: schema
)

try await store.save(user)

let users = try await store.query(User.self)
    .where(\.email, .equals, "user@example.com")
    .execute()
```

**実装済み機能**:
- ✅ @Recordable, @Transient, @Default
- ✅ #PrimaryKey, #Index, #Unique, #Directory
- ✅ @Relationship, @Attribute
- ✅ 自動生成されるstore()メソッド
- ✅ マルチテナント対応（#Directoryマクロ）

**マクロの種類**:
- **@Recordable**: 構造体マクロ（attached macro）- Recordableプロトコル適合を自動生成
- **@Transient**: プロパティマクロ - 永続化から除外するフィールドをマーク
- **@Default(value:)**: プロパティマクロ - デフォルト値を指定
- **@Relationship**: プロパティマクロ - リレーションシップを定義
- **@Attribute**: プロパティマクロ - 属性メタデータを指定
- **#PrimaryKey<T>([...])**: フリースタンディングマクロ - プライマリキーフィールドを宣言（KeyPath配列）
- **#Index<T>([...])**: フリースタンディングマクロ - インデックスを宣言
- **#Unique<T>([...])**: フリースタンディングマクロ - 一意制約インデックスを宣言
- **#Directory<T>(...)**: フリースタンディングマクロ - Directory Layer設定を宣言

### スキーママイグレーション

**MigrationManager**は、スキーマの進化（バージョン間の変更）を安全かつ自動的に適用するシステムです。

#### 概要

**主要コンポーネント**:

| コンポーネント | 役割 |
|--------------|------|
| **MigrationManager** | マイグレーション全体を調整、バージョン管理 |
| **Migration** | 単一のマイグレーション操作を定義 |
| **MigrationContext** | マイグレーション実行時のコンテキスト、API提供 |
| **AnyRecordStore** | 型消去されたRecordStore、マルチレコードタイプ対応 |
| **FormerIndex** | 削除されたインデックスのメタデータ |

**マイグレーションフロー**:
```
1. getCurrentVersion() - 現在のスキーマバージョンを取得
2. migrate(to: targetVersion) - ターゲットバージョンへのパスを構築
3. マイグレーションチェーンの実行 - 各Migrationを順次実行
4. setCurrentVersion() - 新バージョンを記録
```

#### MigrationManager API

**初期化**:

```swift
// パターン1: 単一RecordStore用
let manager = MigrationManager(
    database: database,
    schema: schema,
    migrations: [migration1, migration2],
    store: recordStore
)

// パターン2: 複数RecordStore用（ストアレジストリ）
let storeRegistry: [String: any AnyRecordStore] = [
    "User": userStore,
    "Product": productStore,
    "Order": orderStore
]
let manager = MigrationManager(
    database: database,
    schema: schema,
    migrations: migrations,
    storeRegistry: storeRegistry
)
```

**主要メソッド**:

```swift
// 現在のバージョンを取得
let currentVersion = try await manager.getCurrentVersion()
// → SchemaVersion(major: 1, minor: 0, patch: 0) or nil

// 指定バージョンへマイグレーション
try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))

// マイグレーション一覧
let allMigrations = manager.listMigrations()

// 特定マイグレーションの適用状態確認
let isApplied = try await manager.isMigrationApplied(migration)
```

#### Migration定義

**基本構造**:

```swift
let migration = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
    description: "Add email index to User"
) { context in
    // マイグレーション処理
    let emailIndex = Index(
        name: "user_by_email",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "email")
    )
    try await context.addIndex(emailIndex)
}
```

**SchemaVersion vs Schema.Version**:

| 型 | 用途 | 例 |
|------|------|-----|
| **SchemaVersion** | マイグレーション管理用 | `SchemaVersion(major: 1, minor: 0, patch: 0)` |
| **Schema.Version** | スキーマ定義用 | `Schema.Version(1, 0, 0)` |

**変換**:
```swift
// Schema.Version → SchemaVersion
let migrationVersion = SchemaVersion(
    major: schemaVersion.major,
    minor: schemaVersion.minor,
    patch: schemaVersion.patch
)

// SchemaVersion → Schema.Version
let schemaVersion = Schema.Version(
    migrationVersion.major,
    migrationVersion.minor,
    migrationVersion.patch
)
```

#### MigrationContext操作

**インデックス操作**:

```swift
// 1. インデックス追加（オンライン構築）
let migration1 = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 1, minor: 1, patch: 0),
    description: "Add city index"
) { context in
    let cityIndex = Index(
        name: "user_by_city",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "city")
    )
    // OnlineIndexerを使用して構築（バッチ処理）
    try await context.addIndex(cityIndex)
}

// 2. インデックス再構築（既存データから再生成）
let migration2 = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 1, patch: 0),
    toVersion: SchemaVersion(major: 1, minor: 2, patch: 0),
    description: "Rebuild email index due to data corruption"
) { context in
    // 内部処理: disable → clear → buildIndex (enable → build → readable)
    try await context.rebuildIndex(indexName: "user_by_email")
}

// 3. インデックス削除（FormerIndexとして記録）
let migration3 = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 2, patch: 0),
    toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
    description: "Remove deprecated nickname index"
) { context in
    // FormerIndexを作成してスキーマに追加、既存データをクリア
    try await context.removeIndex(
        indexName: "user_by_nickname",
        addedVersion: SchemaVersion(major: 1, minor: 0, patch: 0)
    )
}
```

**データ操作**:

```swift
// レコード全件スキャンとデータ変換
let migration = Migration(
    fromVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 2, minor: 1, patch: 0),
    description: "Normalize phone numbers"
) { context in
    let store = try context.store(for: "User")

    // 全レコードをスキャン
    let records = try await store.scanRecords { data in
        // フィルタリングロジック（例: 旧フォーマットの電話番号のみ）
        return true  // すべてのレコードを処理
    }

    // 各レコードを変換
    for try await recordData in records {
        // データ変換処理
        let normalizedData = normalizePhoneNumber(recordData)
        // 更新（実装は RecordStore API に依存）
    }
}
```

#### インデックス状態遷移の詳細

**状態遷移フロー**:

```
addIndex:
  初期状態 → writeOnly → readable

rebuildIndex:
  初期状態 → disabled → writeOnly → readable
  ※ disable後に既存データをクリア

removeIndex:
  初期状態 → disabled → FormerIndex作成
```

**重要な実装パターン**:

```swift
// ✅ 正しい: addIndex - OnlineIndexerに完全委譲
public func addIndex(_ index: Index) async throws {
    // OnlineIndexerが以下を実行:
    // 1. enable() - disabled → writeOnly
    // 2. build() - バッチ処理でインデックスエントリ構築
    // 3. makeReadable() - writeOnly → readable
    try await store.buildIndex(indexName: index.name, batchSize: 1000, throttleDelayMs: 10)
}

// ✅ 正しい: rebuildIndex - disable/clearしてからOnlineIndexer委譲
public func rebuildIndex(indexName: String) async throws {
    // 1. disable - 既存インデックスを無効化
    try await indexStateManager.disable(indexName)

    // 2. clear - 既存データを削除
    let indexRange = store.indexSubspace.subspace(indexName).range()
    try await database.withTransaction { transaction in
        transaction.clearRange(beginKey: indexRange.begin, endKey: indexRange.end)
    }

    // 3. rebuild - OnlineIndexerが enable → build → readable を実行
    try await store.buildIndex(indexName: indexName, batchSize: 1000, throttleDelayMs: 10)
}

// ❌ 間違い: 手動で状態遷移を管理（重複した遷移が発生）
public func rebuildIndex(indexName: String) async throws {
    try await indexStateManager.enable(indexName)       // ❌ OnlineIndexerも enable() を呼ぶ
    try await store.buildIndex(...)                     // 内部で enable() → 重複
    try await indexStateManager.makeReadable(indexName) // ❌ OnlineIndexerも makeReadable() を呼ぶ
}
```

**OnlineIndexerの責務**:
- `enable()`: インデックスを writeOnly 状態にする
- `build()`: RangeSetを使用してバッチ処理でインデックス構築
- `makeReadable()`: インデックスを readable 状態にする

**MigrationContextの責務**:
- `addIndex()`: OnlineIndexerを呼ぶだけ（状態遷移は触らない）
- `rebuildIndex()`: disable/clear してからOnlineIndexerに委譲
- `removeIndex()`: disable してからFormerIndexを作成

#### Lightweight Migration

**軽量マイグレーション**は、単純なスキーマ変更を自動的に適用します。

**サポートされる変更**:
- ✅ 新しいレコードタイプの追加
- ✅ 新しいインデックスの追加
- ✅ オプショナルフィールドの追加（デフォルト値あり）

**サポートされない変更**（カスタムマイグレーション必須）:
- ❌ レコードタイプの削除
- ❌ フィールドの削除
- ❌ フィールドの型変更
- ❌ データ変換

**使用例**:

```swift
// スキーマV1
protocol SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
}

// スキーマV2（新しいインデックスを追加）
protocol SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
}

// 軽量マイグレーションの作成
let lightweightMigration = MigrationManager.lightweightMigration(
    from: SchemaV1.self,
    to: SchemaV2.self
)

// マイグレーション実行
let manager = MigrationManager(
    database: database,
    schema: schemaV2,
    migrations: [lightweightMigration],
    store: store
)
try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))
```

**内部処理**:
```swift
// 1. スキーマ変更を検出
let changes = detectSchemaChanges(from: schemaV1, to: schemaV2)

// 2. 自動適用可能か検証
guard changes.canBeAutomatic else {
    throw RecordLayerError.internalError("Cannot perform lightweight migration: ...")
}

// 3. 変更を自動適用
for indexToAdd in changes.indexesToAdd {
    try await context.addIndex(indexToAdd)
}
```

#### ヘルパーメソッド

**MigrationManager**には便利なヘルパーメソッドがあります：

```swift
// インデックス追加マイグレーションを簡単に作成
let addIndexMigration = MigrationManager.addIndexMigration(
    fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 1, minor: 1, patch: 0),
    index: emailIndex
)

// インデックス削除マイグレーションを簡単に作成
let removeIndexMigration = MigrationManager.removeIndexMigration(
    fromVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 2, minor: 1, patch: 0),
    indexName: "user_by_nickname",
    addedVersion: SchemaVersion(major: 1, minor: 0, patch: 0)
)
```

#### 実用例

**例1: 段階的なスキーマ進化**

```swift
// V1: 初期スキーマ
let schemaV1 = Schema(
    [User.self],
    version: Schema.Version(1, 0, 0),
    indexes: []
)

// V1.1: emailインデックス追加
let migration1_1 = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 1, minor: 1, patch: 0),
    description: "Add email index"
) { context in
    let emailIndex = Index(
        name: "user_by_email",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "email")
    )
    try await context.addIndex(emailIndex)
}

// V1.2: cityインデックス追加
let migration1_2 = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 1, patch: 0),
    toVersion: SchemaVersion(major: 1, minor: 2, patch: 0),
    description: "Add city index"
) { context in
    let cityIndex = Index(
        name: "user_by_city",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "city")
    )
    try await context.addIndex(cityIndex)
}

// V2.0: nicknameインデックス削除
let migration2_0 = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 2, patch: 0),
    toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
    description: "Remove nickname index"
) { context in
    try await context.removeIndex(
        indexName: "user_by_nickname",
        addedVersion: SchemaVersion(major: 1, minor: 0, patch: 0)
    )
}

// マイグレーションマネージャーの作成
let manager = MigrationManager(
    database: database,
    schema: schemaV2,
    migrations: [migration1_1, migration1_2, migration2_0],
    store: userStore
)

// V1.0 → V2.0への自動マイグレーション
// MigrationManagerが自動的にパスを構築: V1.0 → V1.1 → V1.2 → V2.0
try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))
```

**例2: マルチレコードタイプのマイグレーション**

```swift
// 複数のRecordStoreを管理
let storeRegistry: [String: any AnyRecordStore] = [
    "User": userStore,
    "Product": productStore,
    "Order": orderStore
]

// 複数レコードタイプに影響するマイグレーション
let migration = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
    description: "Add indexes to multiple record types"
) { context in
    // Userにインデックス追加
    let userStore = try context.store(for: "User")
    let emailIndex = Index(
        name: "user_by_email",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "email")
    )
    try await context.addIndex(emailIndex)

    // Productにインデックス追加
    let productStore = try context.store(for: "Product")
    let categoryIndex = Index(
        name: "product_by_category",
        type: .value,
        rootExpression: FieldKeyExpression(fieldName: "category")
    )
    try await context.addIndex(categoryIndex)
}

let manager = MigrationManager(
    database: database,
    schema: schema,
    migrations: [migration],
    storeRegistry: storeRegistry
)
try await manager.migrate(to: SchemaVersion(major: 2, minor: 0, patch: 0))
```

#### ベストプラクティス

**1. セマンティックバージョニング**:
```swift
// MAJOR: 後方互換性のない変更
SchemaVersion(major: 2, minor: 0, patch: 0)  // レコードタイプ削除、フィールド削除

// MINOR: 後方互換性のある機能追加
SchemaVersion(major: 1, minor: 1, patch: 0)  // インデックス追加、フィールド追加

// PATCH: バグ修正
SchemaVersion(major: 1, minor: 0, patch: 1)  // インデックス再構築
```

**2. マイグレーションチェーン**:
```swift
// ✅ 正しい: 連続したバージョンチェーン
migrations: [
    migration_1_0_to_1_1,  // 1.0 → 1.1
    migration_1_1_to_2_0,  // 1.1 → 2.0
    migration_2_0_to_2_1   // 2.0 → 2.1
]
// MigrationManagerが自動的にパスを構築

// ❌ 間違い: ギャップのあるチェーン
migrations: [
    migration_1_0_to_1_1,  // 1.0 → 1.1
    migration_2_0_to_2_1   // 2.0 → 2.1  ← 1.1 → 2.0 が欠落
]
// エラー: "No migration path found from 1.1 to 2.1"
```

**3. 冪等性の確保**:
```swift
// ✅ 正しい: isMigrationApplied()で既適用をチェック
let migration = Migration(...) { context in
    // MigrationManagerが自動的にチェック
    try await context.addIndex(index)
}

// 同じマイグレーションを複数回実行しても安全
try await manager.migrate(to: targetVersion)
try await manager.migrate(to: targetVersion)  // 2回目は何もしない
```

**4. ダウンタイム最小化**:
```swift
// OnlineIndexerを使用してバッチ処理
let migration = Migration(...) { context in
    // バッチサイズとスロットルを調整
    try await context.addIndex(index)  // 内部で buildIndex(batchSize: 1000, throttleDelayMs: 10)
}

// トランザクション制限を遵守
// - 各バッチは5秒以内
// - 各バッチは10MB以内
// - RangeSetで進行状況を記録 → 中断から再開可能
```

**5. ロールバック対応（将来実装）**:
```swift
// 現在は前方マイグレーションのみサポート
// 将来的には Migration.down クロージャを追加予定
let migration = Migration(
    fromVersion: SchemaVersion(major: 1, minor: 0, patch: 0),
    toVersion: SchemaVersion(major: 2, minor: 0, patch: 0),
    description: "Add email index",
    up: { context in
        try await context.addIndex(emailIndex)
    },
    down: { context in  // 将来実装
        try await context.removeIndex(indexName: "user_by_email", ...)
    }
)
```

#### エラーハンドリング

**主要なエラー**:

```swift
// マイグレーションパスが見つからない
RecordLayerError.internalError("No migration path found from 1.0.0 to 2.0.0")
→ 連続したマイグレーションチェーンを確認

// マイグレーションが既に実行中
RecordLayerError.internalError("Migration already in progress")
→ 並行実行を避ける

// 軽量マイグレーションが不可能
RecordLayerError.internalError("Cannot perform lightweight migration: Index 'foo' removed")
→ カスタムマイグレーションを作成

// インデックスが見つからない
RecordLayerError.indexNotFound("Index 'user_by_email' not found in schema")
→ スキーマにインデックスが定義されているか確認

// レコードストアが見つからない
RecordLayerError.internalError("RecordStore for record type 'User' not found in registry")
→ storeRegistry に必要なストアが登録されているか確認
```

#### デバッグとモニタリング

**現在のバージョン確認**:
```swift
let currentVersion = try await manager.getCurrentVersion()
print("Current schema version: \(currentVersion)")
// 出力: Current schema version: Optional(SchemaVersion(major: 1, minor: 2, patch: 0))
```

**マイグレーション履歴確認**:
```swift
let allMigrations = manager.listMigrations()
for migration in allMigrations {
    let isApplied = try await manager.isMigrationApplied(migration)
    print("\(migration.description): \(isApplied ? "✅ Applied" : "⏳ Pending")")
}
```

**OnlineIndexer進行状況**:
```swift
// OnlineIndexer内部でRangeSetを使用
// MigrationManager自体は進行状況APIを提供しない
// 将来的にはコールバックやProgress APIを追加予定
```

#### まとめ

**MigrationManager**の主要機能:
- ✅ **型安全**: スキーマバージョン管理とマイグレーションチェーン
- ✅ **冪等性**: 同じマイグレーションを複数回実行しても安全
- ✅ **オンライン操作**: バッチ処理で本番環境でも実行可能
- ✅ **再開可能**: RangeSetで中断からの再開をサポート
- ✅ **マルチレコードタイプ**: 複数RecordStoreを統合管理
- ✅ **軽量マイグレーション**: 単純な変更を自動適用

**実装状況**:
- ✅ MigrationManager本体
- ✅ MigrationContext (addIndex, rebuildIndex, removeIndex)
- ✅ Lightweight Migration
- ✅ AnyRecordStore protocol
- ✅ RecordStore+Migration extension
- ✅ FormerIndex
- ✅ **24テスト全合格** (基本11テスト + 高度な13テスト)

---

**Last Updated**: 2025-01-13
**FoundationDB**: 7.1.0+ | **fdb-swift-bindings**: 1.0.0+
**Record Layer (Swift)**: プロダクション対応 | **テスト**: 321合格 | **進捗**: 98%完了
**Phase 2 (スキーマ進化)**: ✅ 100%完了（Enum検証含む）
**Phase 3 (Migration Manager)**: ✅ 100%完了（**24テスト全合格**、包括的テストカバレッジ）
