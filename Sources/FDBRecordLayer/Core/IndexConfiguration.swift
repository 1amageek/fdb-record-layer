import Foundation
import FDBRecordCore

/// インデックスの実行時設定
///
/// モデル定義（データ構造）と分離して、実行時の最適化戦略を指定します。
/// これにより、環境（テスト vs 本番）やデータ規模に応じて戦略を変更できます。
///
/// **設計原則**: データ構造と実行時最適化の分離
///
/// - データ構造（VectorIndexOptions）: ベクトル次元数、距離メトリック
/// - 実行時最適化（IndexConfiguration）: flatScan vs HNSW、inlineIndexing
///
/// **使用例**:
/// ```swift
/// // Schema初期化時に戦略を指定
/// let schema = Schema(
///     [Product.self],
///     indexConfigurations: [
///         IndexConfiguration(
///             indexName: "product_embedding",
///             vectorStrategy: .hnswBatch
///         )
///     ]
/// )
///
/// // 環境変数から戦略を読み込み
/// let strategy = ProcessInfo.processInfo.environment["VECTOR_STRATEGY"] == "hnsw"
///     ? VectorIndexStrategy.hnswBatch
///     : VectorIndexStrategy.flatScan
///
/// let config = IndexConfiguration(
///     indexName: "product_embedding",
///     vectorStrategy: strategy
/// )
/// ```
///
/// **参考**: [Vector Index Strategy Separation Design](../../docs/vector_index_strategy_separation_design.md)
public struct IndexConfiguration: Sendable, Codable {
    /// インデックス名（モデルで定義された名前と一致）
    public let indexName: String

    /// ベクトルインデックス戦略（オプション）
    ///
    /// **デフォルト**: `.flatScan`（安全側）
    ///
    /// **選択基準**:
    /// - `.flatScan`: データ規模 < 10,000 ベクトル、低メモリ環境
    /// - `.hnswBatch`: データ規模 > 10,000 ベクトル、高メモリ環境（推奨）
    public let vectorStrategy: VectorIndexStrategy?

    /// 空間インデックスレベル（オプション、将来実装）
    ///
    /// **用途**: Spatial Indexのタイル階層レベル
    public let spatialLevel: Int?

    /// イニシャライザ
    ///
    /// - Parameters:
    ///   - indexName: インデックス名（モデルで定義された名前と一致）
    ///   - vectorStrategy: ベクトルインデックス戦略（nil の場合は `.flatScan` がデフォルト）
    ///   - spatialLevel: 空間インデックスレベル（オプション）
    public init(
        indexName: String,
        vectorStrategy: VectorIndexStrategy? = nil,
        spatialLevel: Int? = nil
    ) {
        self.indexName = indexName
        self.vectorStrategy = vectorStrategy
        self.spatialLevel = spatialLevel
    }
}

/// ベクトルインデックス戦略（実行時最適化）
///
/// **重要**: この enum は実行時設定（IndexConfiguration）で使用します。
/// モデル定義（VectorIndexOptions）には含めません。
///
/// **戦略の選択**:
///
/// | 戦略 | 計算量 | メモリ使用量 | 用途 |
/// |------|--------|------------|------|
/// | `.flatScan` | O(n) | 低（~1.5 GB / 1M vectors） | < 10,000 ベクトル |
/// | `.hnswBatch` | O(log n) | 高（~15 GB / 1M vectors） | > 10,000 ベクトル（推奨） |
///
/// **HNSW インデックスの構築**:
///
/// - **Batch Indexing** (`.hnswBatch`): OnlineIndexer.buildHNSWIndex() で構築（推奨）
///   - メリット: 安全、再開可能、タイムアウトなし
///   - デメリット: 初期構築が必要
///
/// **注意**: HNSW インデックスはインライン更新（RecordStore.save() での自動更新）をサポートしていません。
/// 常に OnlineIndexer.buildHNSWIndex() を使用してください。
///
/// **使用例**:
/// ```swift
/// // 環境依存の戦略切り替え
/// #if DEBUG
/// let strategy = VectorIndexStrategy.flatScan  // テスト環境: 高速起動
/// #else
/// let strategy = VectorIndexStrategy.hnswBatch // 本番環境: 最適性能
/// #endif
///
/// let schema = Schema(
///     [Product.self],
///     indexConfigurations: [
///         IndexConfiguration(
///             indexName: "product_embedding",
///             vectorStrategy: strategy
///         )
///     ]
/// )
/// ```
public enum VectorIndexStrategy: Sendable, Equatable, Codable {
    /// フラットスキャン: O(n) 検索、低メモリ使用量
    ///
    /// **特性**:
    /// - 計算量: O(n)
    /// - メモリ: ~1.5 GB / 1M vectors (384 dims)
    /// - インライン更新: 常に有効（単一 setValue 操作）
    ///
    /// **用途**: 小規模データセット（< 10,000 ベクトル）
    case flatScan

    /// HNSW: O(log n) 検索、高メモリ使用量
    ///
    /// **特性**:
    /// - 計算量: O(log n) (近似)
    /// - メモリ: ~15 GB / 1M vectors (M=16, 384 dims)
    /// - インライン更新: `inlineIndexing` パラメータで制御
    ///
    /// **用途**: 大規模データセット（> 10,000 ベクトル）
    ///
    /// - Parameter inlineIndexing: RecordStore.save() 時の自動更新を許可するか
    ///   - `false`: OnlineIndexer.buildHNSWIndex() で構築（推奨）
    ///   - `true`: RecordStore.save() で自動更新（⚠️ タイムアウトリスク）
    case hnsw(inlineIndexing: Bool)

    /// HNSW with batch indexing（推奨）
    ///
    /// **使用方法**:
    /// 1. Schema作成時に `.hnswBatch` を指定
    /// 2. OnlineIndexer.buildHNSWIndex() で構築
    ///
    /// **メリット**:
    /// - 安全（タイムアウトなし）
    /// - 再開可能（RangeSetで進行状況記録）
    /// - 大規模データセット対応
    ///
    /// **例**:
    /// ```swift
    /// let schema = Schema(
    ///     [Product.self],
    ///     vectorStrategies: ["product_embedding": .hnswBatch]
    /// )
    ///
    /// let indexer = OnlineIndexer(...)
    /// try await indexer.buildHNSWIndex(
    ///     indexName: "product_embedding",
    ///     batchSize: 1000,
    ///     throttleDelayMs: 10
    /// )
    /// ```
    public static var hnswBatch: VectorIndexStrategy {
        .hnsw(inlineIndexing: false)
    }
}
