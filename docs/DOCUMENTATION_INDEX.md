# Documentation Index

**最終更新**: 2025-01-15

このドキュメントは、FDB Record Layer Swiftのすべてのドキュメントの索引です。

---

## 📚 主要ドキュメント

### プロジェクト概要

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [README.md](../README.md) | プロジェクト概要、クイックスタート | すべて |
| [STATUS.md](STATUS.md) | 現在のプロジェクトステータス | すべて |
| [REMAINING_WORK.md](REMAINING_WORK.md) | 残りの作業リスト（詳細） | 開発者 |
| [IMPLEMENTATION_HISTORY.md](IMPLEMENTATION_HISTORY.md) | 実装履歴と修正記録 | 開発者 |

### 実装ガイド

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) | 実装ロードマップ（Phase別） | 開発者、PM |
| [MACRO_IMPLEMENTATION_STATUS.md](MACRO_IMPLEMENTATION_STATUS.md) | マクロAPI実装状況 | 開発者 |
| [API-MIGRATION-GUIDE.md](API-MIGRATION-GUIDE.md) | API移行ガイド | ユーザー |

### アーキテクチャ設計

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) | プロジェクト構造 | 開発者 |
| [architecture/ARCHITECTURE_REFERENCE.md](architecture/ARCHITECTURE_REFERENCE.md) | システムアーキテクチャ参考 | 開発者 |
| [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) | アーキテクチャ概要 | 開発者 |
| [architecture/QUERY_PLANNER_OPTIMIZATION_V2.md](architecture/QUERY_PLANNER_OPTIMIZATION_V2.md) | クエリプランナー最適化 | 開発者 |
| [swift-macro-design.md](swift-macro-design.md) | SwiftData風マクロAPI設計 | 開発者 |
| [SNAPSHOT_AND_TRANSACTION_DESIGN.md](SNAPSHOT_AND_TRANSACTION_DESIGN.md) | トランザクション設計 | 開発者 |
| [PARTITION_DESIGN.md](PARTITION_DESIGN.md) | マルチテナント分離設計 | 開発者 |
| [SCHEMA_ENTITY_INTEGRATION.md](SCHEMA_ENTITY_INTEGRATION.md) | Schemaとエンティティの統合 | 開発者 |
| [SWIFTDATA_DESIGN.md](SWIFTDATA_DESIGN.md) | SwiftData互換API設計 | 開発者 |

### 機能別設計

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [online-index-scrubber-design.md](online-index-scrubber-design.md) | OnlineIndexScrubber設計 | 開発者 |
| [metadata-evolution-validator-design.md](metadata-evolution-validator-design.md) | スキーマ進化バリデータ設計 | 開発者 |
| [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md) | メトリクスとロギング設計 | 開発者、運用者 |

### 使用ガイド

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [guides/QUERY_OPTIMIZER.md](guides/QUERY_OPTIMIZER.md) | クエリ最適化ガイド | ユーザー、開発者 |
| [guides/ADVANCED_INDEX_DESIGN.md](guides/ADVANCED_INDEX_DESIGN.md) | 高度なインデックス設計 | ユーザー、開発者 |
| [guides/VERSIONSTAMP_USAGE_GUIDE.md](guides/VERSIONSTAMP_USAGE_GUIDE.md) | Versionstamp使用ガイド | ユーザー、開発者 |
| [guides/TUPLE_PACK_WITH_VERSIONSTAMP_EXPLANATION.md](guides/TUPLE_PACK_WITH_VERSIONSTAMP_EXPLANATION.md) | Tuple + Versionstamp詳細 | 開発者 |
| [guides/MIGRATION.md](guides/MIGRATION.md) | マイグレーションガイド | ユーザー |
| [PARTITION_USAGE_GUIDE.md](PARTITION_USAGE_GUIDE.md) | マルチテナント分離使用ガイド | ユーザー、開発者 |

### FoundationDB参考資料

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [CLAUDE.md](../CLAUDE.md) | FoundationDB使い方ガイド（包括的） | すべて |
| [architecture/FDB_BINDINGS_ARCHITECTURE.md](architecture/FDB_BINDINGS_ARCHITECTURE.md) | FDBバインディングアーキテクチャ | 開発者 |

---

## 📖 ドキュメントの使い方

### 初めてのユーザー

1. [README.md](../README.md) - プロジェクト概要を理解
2. [STATUS.md](STATUS.md) - 現在の実装状況を確認
3. [CLAUDE.md](../CLAUDE.md) - FoundationDBの基礎を学習
4. [Examples/](../Examples/) - サンプルコードで実践

### 開発者

1. [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) - コードベース構造を理解
2. [swift-macro-design.md](swift-macro-design.md) - マクロAPI設計を理解
3. [IMPLEMENTATION_HISTORY.md](IMPLEMENTATION_HISTORY.md) - 最近の実装と修正を確認
4. [REMAINING_WORK.md](REMAINING_WORK.md) - 残りの作業を確認
5. 各機能別設計ドキュメント - 実装詳細を確認

### プロジェクトマネージャー

1. [STATUS.md](STATUS.md) - 現状確認
2. [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) - 実装計画
3. [REMAINING_WORK.md](REMAINING_WORK.md) - 優先順位と見積もり
4. [IMPLEMENTATION_HISTORY.md](IMPLEMENTATION_HISTORY.md) - 完了した作業の確認

### 運用者

1. [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md) - メトリクスとログ設計
2. [CLAUDE.md](../CLAUDE.md) - FoundationDB運用知識
3. [online-index-scrubber-design.md](online-index-scrubber-design.md) - インデックス一貫性管理
4. [PARTITION_USAGE_GUIDE.md](PARTITION_USAGE_GUIDE.md) - マルチテナント運用

---

## 🗂 ドキュメント分類

### ステータス・計画（What）

- **STATUS.md** - 現在地（Phase 2a完了、Phase 2b計画中）
- **REMAINING_WORK.md** - 次に何をするか
- **IMPLEMENTATION_ROADMAP.md** - 長期計画
- **IMPLEMENTATION_HISTORY.md** - これまでの実装と修正

### 設計・アーキテクチャ（How）

#### コアアーキテクチャ
- **architecture/ARCHITECTURE_REFERENCE.md** - システムアーキテクチャ全体
- **architecture/QUERY_PLANNER_OPTIMIZATION_V2.md** - クエリプランナー設計
- **SNAPSHOT_AND_TRANSACTION_DESIGN.md** - トランザクション設計

#### API設計
- **swift-macro-design.md** - SwiftData風マクロAPI設計
- **SWIFTDATA_DESIGN.md** - SwiftData互換API設計
- **SCHEMA_ENTITY_INTEGRATION.md** - Schemaとエンティティ統合

#### 機能別設計
- **PARTITION_DESIGN.md** - マルチテナント分離
- **online-index-scrubber-design.md** - インデックス検証
- **metadata-evolution-validator-design.md** - スキーマ進化
- **METRICS_AND_LOGGING.md** - 監視設計

### 実装ガイド（How to Implement）

- **PROJECT_STRUCTURE.md** - コード構造
- **MACRO_IMPLEMENTATION_STATUS.md** - マクロ実装状況
- **API-MIGRATION-GUIDE.md** - API移行方法

### 使用ガイド（How to Use）

- **guides/QUERY_OPTIMIZER.md** - クエリ最適化
- **guides/ADVANCED_INDEX_DESIGN.md** - インデックス設計パターン
- **guides/VERSIONSTAMP_USAGE_GUIDE.md** - Versionstamp使用方法
- **guides/MIGRATION.md** - マイグレーション手順
- **PARTITION_USAGE_GUIDE.md** - マルチテナント使用方法

### 参考資料（Reference）

- **CLAUDE.md** - FoundationDB包括的ガイド
- **architecture/FDB_BINDINGS_ARCHITECTURE.md** - FDBバインディング

---

## 📅 最新の更新（2025-01-15）

### 新規追加
- ✅ **IMPLEMENTATION_HISTORY.md** - 実装履歴と修正記録の統合ドキュメント

### 主要更新
- ✅ **STATUS.md** - Phase 2a完了、最新の実装状況を反映
- ✅ **REMAINING_WORK.md** - Phase 2b計画に更新
- ✅ **Examples/** - Schema-based APIへ更新

### 削除（統合・古い情報）
- ❌ FINAL-REVIEW-FIXES.md → IMPLEMENTATION_HISTORY.mdに統合
- ❌ blocker-recordname-fix.md → IMPLEMENTATION_HISTORY.mdに統合
- ❌ recordname-unification.md → IMPLEMENTATION_HISTORY.mdに統合
- ❌ index-collection-implementation.md → IMPLEMENTATION_HISTORY.mdに統合
- ❌ index-collection-summary.md → IMPLEMENTATION_HISTORY.mdに統合
- ❌ review-fixes.md → 一時的な記録、削除
- ❌ test-fixes-applied.md → 一時的な記録、削除
- ❌ primary-key-issues-found.md → 修正済み、削除
- ❌ design-primarykey-solution.md → 古い設計、削除
- ❌ future-primarykey-design.md → 古い設計、削除
- ❌ primary-key-implementation-status.md → 古いステータス、削除
- ❌ primary-key-migration-guide.md → 古いガイド、削除
- ❌ macro-api-design.md → swift-macro-design.mdに統合済み、削除
- ❌ schema-entity-design.md → SCHEMA_ENTITY_INTEGRATION.mdに統合済み、削除

---

## 🔍 ドキュメント検索

### キーワード別

**マクロ関連**:
- swift-macro-design.md
- MACRO_IMPLEMENTATION_STATUS.md
- SWIFTDATA_DESIGN.md

**インデックス関連**:
- guides/ADVANCED_INDEX_DESIGN.md
- online-index-scrubber-design.md
- IMPLEMENTATION_HISTORY.md（Index Collection Pipeline）

**マルチテナント関連**:
- PARTITION_DESIGN.md
- PARTITION_USAGE_GUIDE.md

**クエリ最適化関連**:
- architecture/QUERY_PLANNER_OPTIMIZATION_V2.md
- guides/QUERY_OPTIMIZER.md

**トランザクション関連**:
- SNAPSHOT_AND_TRANSACTION_DESIGN.md
- CLAUDE.md（FoundationDBトランザクション基礎）

**スキーマ進化関連**:
- metadata-evolution-validator-design.md
- SCHEMA_ENTITY_INTEGRATION.md

---

## 📝 ドキュメント作成ガイドライン

### 新しいドキュメントを作成する際

1. **適切な場所に配置**:
   - 設計ドキュメント: `docs/`
   - アーキテクチャ詳細: `docs/architecture/`
   - 使用ガイド: `docs/guides/`

2. **メタデータを含める**:
   ```markdown
   # ドキュメントタイトル

   **最終更新**: YYYY-MM-DD
   **ステータス**: 完了 / 進行中 / 計画中
   ```

3. **このインデックスに追加**:
   - 適切なセクションに追加
   - 対象読者を明記
   - 簡潔な説明を記載

4. **関連ドキュメントへのリンク**:
   - 相互参照を明確にする
   - 読者のナビゲーションを容易にする

---

**ドキュメントの整理方針**: 常に最新の情報を保ち、古い/重複した情報は定期的に削除または統合します。
