# FDB Record Layer - Examples

このディレクトリには、FDB Record Layer（マクロAPI）の実践的な使用例が含まれています。

## 前提条件

### 1. FoundationDBのインストールと起動

```bash
# インストール
brew install foundationdb

# 起動
brew services start foundationdb

# 動作確認
fdbcli --exec "status"
```

### 2. プロジェクトのビルド

```bash
cd /path/to/fdb-record-layer
swift build
```

---

## 環境変数による設定（推奨）

Examples は環境変数でクラスタ設定や動作をカスタマイズできます：

| 環境変数 | 説明 | デフォルト | 例 |
|---------|------|----------|-----|
| **FDB_CLUSTER_FILE** | クラスタファイルのパス | なし（デフォルトクラスタ） | `/etc/foundationdb/fdb.cluster` |
| **FDB_API_VERSION** | FoundationDB APIバージョン | `710` | `730` |
| **EXAMPLE_CLEANUP** | 実行後にデータをクリーンアップ | `true` | `false`（デバッグ用） |
| **EXAMPLE_RUN_ID** | データ分離用の一意ID | UUID（自動生成） | `test-run-1` |

### 使用例

```bash
# 本番クラスタに接続
FDB_CLUSTER_FILE=/etc/foundationdb/prod.cluster swift run SimpleExample

# データを残す（デバッグ用）
EXAMPLE_CLEANUP=false swift run 07-VectorSearch

# 複数の設定を組み合わせ
FDB_CLUSTER_FILE=~/my-cluster.conf \
FDB_API_VERSION=730 \
EXAMPLE_CLEANUP=false \
swift run 11-PerformanceOptimization
```

### CI/CD環境での使用

```yaml
# GitHub Actions例
env:
  FDB_CLUSTER_FILE: ${{ secrets.FDB_CLUSTER_FILE }}
  FDB_API_VERSION: "710"
  EXAMPLE_CLEANUP: "true"

steps:
  - name: Run examples
    run: swift run SimpleExample
```

---

## データの分離と再実行性

すべての Examples は **自動的にデータを分離** します：

1. **一意なRun ID**: 各実行ごとに UUID が生成され、データの衝突を防ぎます
2. **自動クリーンアップ**: 実行後に自動的にデータを削除します（`EXAMPLE_CLEANUP=false`で無効化可能）
3. **Subspaceプレフィックス**: `examples/<example-name>/<run-id>` 形式で分離

### 手動クリーンアップ（デバッグ時）

```bash
# 特定のサンプルのデータを削除
fdbcli --exec "clearrange \x00examples/SimpleExample \xff"

# すべてのExamplesデータを削除
fdbcli --exec "clearrange \x00examples \xff"

# Vector Search例のHNSWインデックスをリセット
# → 07-VectorSearch.swift内のresetHNSWIndex()を使用（自動）
```

---

## サンプル一覧

### 1. SimpleExample.swift - 基本的な使い方

**内容**:
- `@Recordable`マクロでレコードタイプを定義
- `#Directory`でデータ保存場所を指定
- `#Index`でインデックスを定義
- 基本的なCRUD操作
- KeyPathベースのクエリ

**実行方法**:
```bash
swift run SimpleExample
```

**コード例**:
```swift
@Recordable
struct User {
    #Directory<User>("app", "users", layer: .recordStore)
    #Index<User>([\email])
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
    var email: String
    var age: Int32

    @Default(value: Date())
    var createdAt: Date
}

// RecordStoreを開く（自動生成されたメソッド）
let store = try await User.store(database: database, schema: schema)

// 保存
try await store.save(user)

// クエリ
let results = try await store.query(User.self)
    .where(\.email, .equals, "alice@example.com")
    .execute()
```

**学べること**:
- ✅ マクロAPIの基本
- ✅ レコードの保存・読み取り・更新・削除
- ✅ インデックスを使った検索
- ✅ デフォルト値の使用

---

### 2. MultiTypeExample.swift - 複数のレコードタイプ

**内容**:
- 複数の`@Recordable`型（User、Order）
- `#Directory`でのパーティション（マルチテナント）
- レコード間の関係（外部キー）
- クロスタイプクエリ
- ユニーク制約

**実行方法**:
```bash
swift run MultiTypeExample
```

**コード例**:
```swift
@Recordable
struct User {
    #Directory<User>("app", "users")
    #Unique<User>([\email])
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
    var email: String
}

@Recordable
struct Order {
    #Directory<Order>("tenants", Field(\Order.accountID), "orders", layer: .partition)
    #Index<Order>([\userID])
    #PrimaryKey<Order>([\.orderID])

    var orderID: Int64
    var accountID: String  // パーティションキー
    var userID: Int64      // 外部キー
    var total: Double
}

// 両方の型をスキーマに登録
let schema = Schema([User.self, Order.self])

let userStore = try await User.store(database: database, schema: schema)
let orderStore = try await Order.store(
    accountID: "account-123",
    database: database,
    schema: schema
)
```

**学べること**:
- ✅ 複数のレコードタイプ管理
- ✅ パーティションによるデータ分離
- ✅ 外部キー関係
- ✅ ユニーク制約
- ✅ クロスタイプクエリ

---

### 3. PartitionExample.swift - マルチテナントアーキテクチャ

**内容**:
- マルチレベルパーティション（tenant → channel → messages）
- テナント間のデータ完全分離
- 同じ主キーが異なるパーティションで使用可能
- パーティションごとの統計情報

**実行方法**:
```bash
swift run PartitionExample
```

**コード例**:
```swift
@Recordable
struct Message {
    #Directory<Message>(
        "tenants",
        Field(\Message.tenantID),
        "channels",
        Field(\Message.channelID),
        "messages",
        layer: .partition
    )

    #Index<Message>([\authorID])
    #PrimaryKey<Message>([\.messageID])

    var messageID: Int64
    var tenantID: String   // 第1パーティションキー
    var channelID: String  // 第2パーティションキー
    var content: String
}

// テナントA、チャンネル"general"
let tenantAGeneralStore = try await Message.store(
    tenantID: "tenant-A",
    channelID: "general",
    database: database,
    schema: schema
)

// テナントB、チャンネル"general"（完全に分離）
let tenantBGeneralStore = try await Message.store(
    tenantID: "tenant-B",
    channelID: "general",
    database: database,
    schema: schema
)
```

**学べること**:
- ✅ マルチレベルパーティション
- ✅ テナント別データ分離
- ✅ SaaSアプリケーションのアーキテクチャ
- ✅ パーティションごとの分析

---

## サンプル実行の期待される出力

### SimpleExample.swift

```
FDB Record Layer - Macro API Example
=====================================

1. Initializing FoundationDB...
   ✓ Connected to FoundationDB

2. Creating schema...
   ✓ Schema created with User type

3. Opening record store...
   ✓ Record store opened at: app/users

4. Creating sample records...
5. Saving records...
   ✓ Saved 3 records

6. Loading record by primary key (userID = 1)...
   ✓ Found user:
     - ID: 1
     - Name: Alice
     - Email: alice@example.com
     - Age: 30

7. Querying by email (bob@example.com)...
   ✓ Found user: Bob (ID: 2)

8. Querying users aged 30 or older...
   ✓ Found 2 user(s):
     - Alice (age: 30)
     - Charlie (age: 35)

9. Updating Bob's age...
   ✓ Updated Bob's age to 26

10. Verifying update...
   ✓ Bob's age is now: 26

11. Deleting Charlie...
   ✓ Deleted user ID 3

12. Verifying deletion...
   ✓ Charlie successfully deleted

13. Counting remaining users...
   ✓ Total users: 2

Example completed successfully!

Key Features of Macro API:
  • @Recordable - No manual Protobuf files needed
  • #Directory - Type-safe directory paths
  • #Index - Declarative index definitions
  • #PrimaryKey - Explicit primary key marking
  • @Default - Default value support
  • Type-safe queries with KeyPath-based filtering
  • Automatic store() method generation
```

---

## Advanced Examples（高度な例）

基本的な例をマスターしたら、以下の高度な例で実践的なユースケースを学びましょう：

### 4. 01-CRUDOperations.swift - CRUD操作の完全ガイド

**内容**: User モデルを使った完全なCRUD（Create、Read、Update、Delete）操作

**実行方法**:
```bash
swift run 01-CRUDOperations
```

**学べること**: プライマリキー検索、インデックス検索、更新、削除

---

### 5. 02-QueryFiltering.swift - クエリとフィルタリング

**内容**: Product モデルを使った複雑なクエリパターン（価格範囲、複数条件、ソート、リミット、IN句）

**実行方法**:
```bash
swift run 02-QueryFiltering
```

**学べること**: where句の組み合わせ、orderBy、limit、IN クエリ

---

### 6. 03-RangeQueries.swift - Range型クエリ

**内容**: Event モデルでPartialRange（`...`、`..<`、`X...`）を使った時系列クエリ

**実行方法**:
```bash
swift run 03-RangeQueries
```

**学べること**: PartialRangeFrom、PartialRangeThrough、PartialRangeUpTo、overlaps()

---

### 7. 04-IndexManagement.swift - インデックス管理

**内容**: OnlineIndexerを使った既存データへのインデックス追加とバッチ構築

**実行方法**:
```bash
swift run 04-IndexManagement
```

**学べること**: OnlineIndexer、buildIndex()、進行状況監視、バッチサイズ調整

---

### 8. 05-SchemaMigration.swift - スキーママイグレーション

**内容**: Schema V1（インデックスなし）からV2（emailインデックス追加）への段階的マイグレーション

**実行方法**:
```bash
swift run 05-SchemaMigration
```

**学べること**: MigrationManager、Migration定義、バージョン管理、addIndex()

---

### 9. 06-SpatialIndex.swift - 空間インデックス

**内容**: Restaurant モデルで地理座標ベースの検索（半径検索、バウンディングボックス）

**実行方法**:
```bash
swift run 06-SpatialIndex
```

**学べること**: @Spatial マクロ、.geo、withinRadius()、withinBoundingBox()

---

### 10. 07-VectorSearch.swift - ベクトル検索

**内容**: Product モデルで埋め込みベクトルを使った類似商品検索（HNSW）

**実行方法**:
```bash
swift run 07-VectorSearch
```

**学べること**: ベクトルインデックス、buildHNSWIndex()、nearestNeighbors()、O(log n)検索

---

### 11. 08-ECommercePlatform.swift - E-commerceプラットフォーム

**内容**: 完全なE-commerceシステム（Product、Order、複合インデックス、ステータス管理）

**実行方法**:
```bash
swift run 08-ECommercePlatform
```

**学べること**: マルチレコードタイプ、外部キー、注文履歴、カテゴリ検索

---

### 12. 09-SocialMedia.swift - ソーシャルメディア

**内容**: SNSプラットフォーム（SocialUser、Post、Follow、タイムライン、ハッシュタグ検索）

**実行方法**:
```bash
swift run 09-SocialMedia
```

**学べること**: フォロー関係、タイムライン生成、ハッシュタグインデックス、IN Joinクエリ

---

### 13. 10-IoTSensorData.swift - IoTセンサーデータ

**内容**: IoTセンサー管理（時系列データ、温度異常検知、地理座標インデックス）

**実行方法**:
```bash
swift run 10-IoTSensorData
```

**学べること**: 複合主キー（sensorID + timestamp）、時系列クエリ、異常検知、空間検索

---

### 14. 11-PerformanceOptimization.swift - パフォーマンス最適化

**内容**: StatisticsManager、バッチ挿入、複合インデックス戦略、クエリ最適化

**実行方法**:
```bash
swift run 11-PerformanceOptimization
```

**学べること**: 統計情報収集、バッチ処理（chunked）、インデックス選択、スループット測定

---

### 15. 12-ErrorHandling.swift - エラーハンドリング

**内容**: リトライロジック、競合解決（OCC）、デッドロック回避、トランザクションスコープのベストプラクティス

**実行方法**:
```bash
swift run 12-ErrorHandling
```

**学べること**: 指数バックオフ、isRetryable判定、一貫した順序アクセス、トランザクション制限

---

## ファイル構造

```
Examples/
├── README.md                        # このファイル
├── SimpleExample.swift              # 基本的な使用例
├── MultiTypeExample.swift           # 複数レコードタイプの例
├── PartitionExample.swift           # マルチテナントの例
├── 01-CRUDOperations.swift          # CRUD操作完全ガイド
├── 02-QueryFiltering.swift          # クエリとフィルタリング
├── 03-RangeQueries.swift            # Range型クエリ
├── 04-IndexManagement.swift         # インデックス管理
├── 05-SchemaMigration.swift         # スキーママイグレーション
├── 06-SpatialIndex.swift            # 空間インデックス
├── 07-VectorSearch.swift            # ベクトル検索
├── 08-ECommercePlatform.swift       # E-commerceユースケース
├── 09-SocialMedia.swift             # ソーシャルメディア
├── 10-IoTSensorData.swift           # IoTセンサーデータ
├── 11-PerformanceOptimization.swift # パフォーマンス最適化
└── 12-ErrorHandling.swift           # エラーハンドリング
```

---

## 主要な概念

### 1. @Recordableマクロ

レコードタイプを定義するメインマクロ。

```swift
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])

    var userID: Int64
    var name: String
}
```

**自動生成**:
- `Recordable`プロトコル準拠
- Protobufシリアライズメソッド
- `store()`メソッド（`#Directory`と組み合わせた場合）

### 2. #Directoryマクロ

データの保存場所を指定。

```swift
// 静的パス
#Directory<User>("app", "users", layer: .recordStore)

// パーティション（動的パス）
#Directory<Order>(
    "tenants",
    Field(\Order.accountID),
    "orders",
    layer: .partition
)
```

### 3. #Indexマクロ

検索インデックスを定義。

```swift
// 単一インデックス
#Index<User>([\email])

// 複合インデックス
#Index<User>([\city, \age])

// 複数のインデックス
#Index<User>([\email])
#Index<User>([\username])
```

### 4. #Uniqueマクロ

ユニーク制約を持つインデックス。

```swift
#Unique<User>([\email])  // emailは一意
```

### 5. #PrimaryKeyマクロ

主キーフィールドを指定（必須）。

```swift
#PrimaryKey<User>([\.userID])

// 複合主キー
#PrimaryKey<Hotel>([\.tenantID, \.userID])
```

### 6. @Defaultマクロ

デフォルト値を指定。

```swift
@Default(value: Date())
var createdAt: Date
```

### 7. @Transientマクロ

永続化しないフィールド。

```swift
@Transient var isLoggedIn: Bool = false
```

---

## よくある質問

### Q1: Protobufファイルは必要ですか？

**A**: いいえ、マクロAPIを使用する場合、`.proto`ファイルは不要です。

---

### Q2: どのサンプルから始めるべきですか？

**A**: `SimpleExample.swift`から始めることをお勧めします。基本的な概念がすべて含まれています。

---

### Q4: パーティションはいつ使うべきですか？

**A**: マルチテナントアプリケーション、地理的データ分離、またはセキュリティ要件で厳格なデータ分離が必要な場合に使用してください。

---

## トラブルシューティング

### 1. FoundationDB接続エラー

**エラー**:
```
Error: Could not connect to FoundationDB
Error Domain=FDB Code=1031 "operation_timed_out"
```

**原因**: FoundationDBが起動していない、またはクラスタファイルが見つからない

**解決法**:
```bash
# 1. FoundationDBが起動しているか確認
brew services list | grep foundationdb

# 2. 起動していない場合
brew services start foundationdb

# 3. ステータス確認
fdbcli --exec "status"

# 4. クラスタファイルの場所を確認
ls -la /usr/local/etc/foundationdb/fdb.cluster

# 5. カスタムクラスタファイルを使用
FDB_CLUSTER_FILE=/path/to/custom.cluster swift run SimpleExample
```

---

### 2. ビルドエラー

**エラー**:
```
error: no such module 'FDBRecordLayer'
```

**原因**: 依存関係が解決されていない、またはビルドキャッシュが古い

**解決法**:
```bash
# プロジェクトルートで完全なクリーンビルド
swift package clean
swift package reset
swift package resolve
swift build

# Xcodeを使用している場合
rm -rf .build
rm -rf .swiftpm
xcodebuild -scheme fdb-record-layer clean build
```

---

### 3. HNSWインデックスの再構築エラー

**エラー**:
```
Error: HNSW index already exists in writeOnly state
RecordLayerError.indexNotReadable
```

**原因**: 前回の実行でHNSWインデックス構築が中断された、または既にインデックスが存在する

**解決法**:

**Option 1: 自動リセット（推奨）**
```swift
// 07-VectorSearch.swiftでは自動的にresetHNSWIndex()が呼ばれます
// EXAMPLE_CLEANUP=false の場合のみ手動リセットが必要
```

**Option 2: 手動リセット（fdbcli）**
```bash
# インデックスデータを削除
fdbcli --exec "clearrange \x00examples/VectorSearch \xff"

# 再実行
swift run 07-VectorSearch
```

**Option 3: 環境変数でクリーンアップ強制**
```bash
EXAMPLE_CLEANUP=true swift run 07-VectorSearch
```

---

### 4. データの競合エラー

**エラー**:
```
RecordLayerError.recordAlreadyExists
Error Domain=FDB Code=1020 "not_committed"
```

**原因**: 同じRun IDで複数回実行、または前回のデータが残っている

**解決法**:
```bash
# 新しいRun IDで実行
EXAMPLE_RUN_ID="new-run-$(date +%s)" swift run SimpleExample

# または、データを手動削除
fdbcli --exec "clearrange \x00examples \xff"
```

---

### 5. トランザクションタイムアウト

**エラー**:
```
Error Domain=FDB Code=1031 "operation_timed_out"
Transaction exceeded 5 second limit
```

**原因**: 大量データ処理、HNSWインデックス構築が5秒を超えた

**解決法**:

**For Examples**: 自動的にバッチ処理されるため、通常は発生しません
```swift
// OnlineIndexerがバッチサイズを自動調整
// batchSize: 100（デフォルト） → トランザクション制限内
```

**For 本番環境**: バッチサイズを調整
```swift
let onlineIndexer = OnlineIndexer(
    store: store,
    indexName: "product_embedding_hnsw",
    batchSize: 50,          // ← 減らす
    throttleDelayMs: 20     // ← 増やす
)
```

---

### 6. メモリ不足エラー

**エラー**:
```
Process killed: out of memory
```

**原因**: ベクトル検索やSpatial Indexで大量データを一度に読み込んだ

**解決法**:
```bash
# limit()を使用してデータ量を制限
# 例: 11-PerformanceOptimization.swift
swift run 11-PerformanceOptimization  # 既にlimit付き

# メモリ制限を確認
ulimit -a

# メモリ制限を増やす（macOS）
ulimit -m unlimited
```

---

### 7. Directory Layer エラー

**エラー**:
```
RecordLayerError.directoryAlreadyExists
```

**原因**: `#Directory`で指定したパスが既に存在する

**解決法**:
```bash
# ディレクトリをリセット
fdbcli --exec "clearrange \x00<directory-prefix> \xff"

# 例: "app/users"をリセット
fdbcli <<EOF
writemode on
clearrange \x00app/users \xff
EOF

# または、EXAMPLE_CLEANUP=trueで自動削除
EXAMPLE_CLEANUP=true swift run SimpleExample
```

---

### 8. デバッグモードでの実行

詳細なログを出力するには：

```bash
# 環境変数でログレベルを設定
FDB_NETWORK_OPTION_TRACE_ENABLE=1 \
FDB_TRACE_LOG_GROUP=example \
swift run SimpleExample

# ログファイルを確認
tail -f /tmp/fdb-trace.*.xml
```

---

### よくあるエラーパターン早見表

| エラーコード | 説明 | 解決法 |
|------------|------|--------|
| **1007** | transaction_too_old | リトライ（自動処理済み） |
| **1020** | not_committed（競合） | リトライ、または順序アクセス修正 |
| **1021** | commit_unknown_result | 冪等性チェック追加 |
| **1031** | operation_timed_out | バッチサイズ削減、throttle追加 |
| **2101** | transaction_too_large | バッチサイズ削減（<10MB） |

---

### サポートが必要な場合

1. **ログを確認**: `fdbcli --exec "status details"`
2. **Issues**: https://github.com/anthropics/fdb-record-layer/issues
3. **ドキュメント**: `../CLAUDE.md`の「Part 1: エラーハンドリング」を参照

---

## 次のステップ

サンプルを実行したら、以下のドキュメントで詳細を学びましょう：

### ガイド

- **[getting-started.md](../docs/guides/getting-started.md)** - クイックスタートガイド
- **[macro-usage-guide.md](../docs/guides/macro-usage-guide.md)** - 包括的なマクロAPIリファレンス
- **[best-practices.md](../docs/guides/best-practices.md)** - ベストプラクティス

### 設計ドキュメント

- **[swift-macro-design.md](../docs/design/swift-macro-design.md)** - マクロAPIの設計
- **[query-planner-optimization.md](../docs/design/query-planner-optimization.md)** - クエリ最適化
- **[online-index-scrubber.md](../docs/design/online-index-scrubber.md)** - インデックス整合性

### リソース

- **[FoundationDB Documentation](https://apple.github.io/foundationdb/)** - 公式ドキュメント
- **[CLAUDE.md](../CLAUDE.md)** - FoundationDB使い方ガイド

---

**最終更新**: 2025-01-09
**マクロAPI**: ✅ 100%完了
