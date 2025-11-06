# Documentation Index

**最終更新**: 2025-01-06

このドキュメントは、FDB Record Layer Swiftのすべてのドキュメントの索引です。

---

## 📚 主要ドキュメント

### プロジェクト概要

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [README.md](../README.md) | プロジェクト概要、クイックスタート | すべて |
| [STATUS.md](STATUS.md) | 現在のプロジェクトステータス | すべて |
| [REMAINING_WORK.md](REMAINING_WORK.md) | 残りの作業リスト（詳細） | 開発者 |

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
| [swift-macro-design.md](swift-macro-design.md) | SwiftData風マクロAPI設計 | 開発者 |
| [SNAPSHOT_AND_TRANSACTION_DESIGN.md](SNAPSHOT_AND_TRANSACTION_DESIGN.md) | トランザクション設計 | 開発者 |

### 機能別設計

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [online-index-scrubber-design.md](online-index-scrubber-design.md) | OnlineIndexScrubber設計 | 開発者 |
| [metadata-evolution-validator-design.md](metadata-evolution-validator-design.md) | スキーマ進化バリデータ設計 | 開発者 |
| [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md) | メトリクスとロギング設計 | 開発者、運用者 |

### FoundationDB参考資料

| ドキュメント | 説明 | 対象読者 |
|------------|------|---------|
| [CLAUDE.md](../CLAUDE.md) | FoundationDB使い方ガイド（包括的） | すべて |

---

## 📖 ドキュメントの使い方

### 初めてのユーザー

1. [README.md](../README.md) - プロジェクト概要を理解
2. [STATUS.md](STATUS.md) - 現在の実装状況を確認
3. [CLAUDE.md](../CLAUDE.md) - FoundationDBの基礎を学習

### 開発者

1. [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) - コードベース構造を理解
2. [swift-macro-design.md](swift-macro-design.md) - マクロAPI設計を理解
3. [REMAINING_WORK.md](REMAINING_WORK.md) - 残りの作業を確認
4. 各機能別設計ドキュメント - 実装詳細を確認

### プロジェクトマネージャー

1. [STATUS.md](STATUS.md) - 現状確認
2. [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) - 実装計画
3. [REMAINING_WORK.md](REMAINING_WORK.md) - 優先順位と見積もり

### 運用者

1. [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md) - メトリクスとログ設計
2. [CLAUDE.md](../CLAUDE.md) - FoundationDB運用知識
3. [online-index-scrubber-design.md](online-index-scrubber-design.md) - インデックス一貫性管理

---

## 🗂 ドキュメント分類

### ステータス・計画（What）

- STATUS.md - 現在地
- REMAINING_WORK.md - 次に何をするか
- IMPLEMENTATION_ROADMAP.md - 長期計画

### 設計・アーキテクチャ（How）

- swift-macro-design.md - マクロAPI設計
- online-index-scrubber-design.md - インデックス検証設計
- metadata-evolution-validator-design.md - スキーマ進化設計
- SNAPSHOT_AND_TRANSACTION_DESIGN.md - トランザクション設計
- METRICS_AND_LOGGING.md - 監視設計

### 実装ガイド（How to Implement）

- PROJECT_STRUCTURE.md - コード構造
- MACRO_IMPLEMENTATION_STATUS.md - マクロ実装状況
- API-MIGRATION-GUIDE.md - API移行方法

### 参考資料（Reference）

- CLAUDE.md - FoundationDB包括ガイド

---

## 🔍 トピック別索引

### マクロAPI

- [swift-macro-design.md](swift-macro-design.md) - 設計
- [MACRO_IMPLEMENTATION_STATUS.md](MACRO_IMPLEMENTATION_STATUS.md) - 実装状況
- [REMAINING_WORK.md](REMAINING_WORK.md#1-swiftdata風マクロapi完成80100) - 残りの作業

### インデックス

- [online-index-scrubber-design.md](online-index-scrubber-design.md) - 一貫性検証
- [REMAINING_WORK.md](REMAINING_WORK.md#2-高度なインデックスタイプ) - Rank/Version Index計画

### スキーマ進化

- [metadata-evolution-validator-design.md](metadata-evolution-validator-design.md) - バリデータ設計
- [REMAINING_WORK.md](REMAINING_WORK.md#1-スキーマ進化バリデータ未実装) - 実装計画

### メトリクス・ロギング

- [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md) - 設計と使用法

### FoundationDB

- [CLAUDE.md](../CLAUDE.md) - 包括的ガイド
- [SNAPSHOT_AND_TRANSACTION_DESIGN.md](SNAPSHOT_AND_TRANSACTION_DESIGN.md) - トランザクション設計

---

## 📝 ドキュメント保守

### ドキュメント更新ルール

1. **STATUS.md**: 機能完成時に即更新
2. **REMAINING_WORK.md**: Phase完了時に更新
3. **IMPLEMENTATION_ROADMAP.md**: 四半期ごとに見直し
4. **設計ドキュメント**: 実装前に作成、実装後に最終版化

### 廃止ドキュメント（2025-01-06削除）

以下のドキュメントは古い設計や重複のため削除されました：

- ~~OnlineIndexScrubber-Architecture-Fix.md~~ → [online-index-scrubber-design.md](online-index-scrubber-design.md)に統合
- ~~OnlineIndexScrubber-Architecture.md~~ → 同上
- ~~OnlineIndexScrubber-Implementation-Checklist.md~~ → [REMAINING_WORK.md](REMAINING_WORK.md)に統合
- ~~OnlineIndexScrubber-ErrorHandling-Metrics-Design.md~~ → [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md)に統合
- ~~monitoring/METRICS_INTEGRATION_REVIEW.md~~ → [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md)に置き換え

---

## 🚀 クイックリンク

- **今すぐ始める**: [README.md](../README.md) → [Examples/](../Examples/)
- **何ができるか**: [STATUS.md](STATUS.md)
- **次に何をするか**: [REMAINING_WORK.md](REMAINING_WORK.md)
- **FoundationDB学習**: [CLAUDE.md](../CLAUDE.md)
- **マクロAPI使い方**: [MACRO_IMPLEMENTATION_STATUS.md](MACRO_IMPLEMENTATION_STATUS.md#使用例)
- **メトリクス設定**: [METRICS_AND_LOGGING.md](METRICS_AND_LOGGING.md#implementation)

---

**メンテナ**: Claude Code
**最終整理**: 2025-01-06
**次回見直し**: Phase 2a完了時
