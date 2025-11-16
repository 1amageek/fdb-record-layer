# Vector Index Strategy Separation Design

## 設計原則: データ構造と実行時最適化の分離

**日付**: 2025-01-17
**ステータス**: 設計承認済み

---

## 問題提起

### 現在の設計の問題点

```swift
// ❌ 問題: モデル定義にハードウェア依存の戦略が含まれている
@Recordable
struct Product {
    #Index<Product>(
        [\.embedding],
        type: .vector(VectorIndexOptions(
            dimensions: 384,
            metric: .cosine,
            strategy: .hnswBatch  // ← モデルの責任範囲を超えている
        ))
    )
    var embedding: [Float32]
}
```

**問題点**:

1. **環境依存**: テスト環境（小規模）と本番環境（大規模）で異なる戦略を使いたい
2. **ハードウェア制約**: メモリが少ない環境では `.flatScan`、大規模環境では `.hnsw`
3. **データ規模の変化**: 初期は100件（flatScan）、将来100万件（HNSW）にスケール
4. **モデルの責任範囲**: データ構造を定義すべきで、実行時最適化を含むべきではない

**類似問題**: Spatial Index の `level` パラメータも同様の問題がある

---

## 設計原則

### Principle 1: Separation of Concerns

> **モデル定義はデータ構造を定義し、実行時設定は最適化戦略を定義する**

| 責任 | 定義場所 | 例 |
|------|---------|-----|
| **データ構造** | モデル定義（@Recordable） | ベクトル次元数、距離メトリック |
| **実行時最適化** | Schema/RecordStore初期化 | flatScan vs HNSW、inlineIndexing |
| **ハードウェア制約** | 環境設定（環境変数） | メモリ、CPU、データ規模 |

### Principle 2: Configuration at Deployment Time

> **最適化戦略はデプロイ時に決定され、コードの再コンパイルは不要**

```swift
// 環境変数から戦略を読み込み
let strategy = ProcessInfo.processInfo.environment["VECTOR_STRATEGY"] == "hnsw"
    ? VectorIndexStrategy.hnswBatch
    : VectorIndexStrategy.flatScan
```

### Principle 3: Safe Defaults

> **デフォルト戦略は安全側（flatScan）を選択**

- flatScan: O(n) だがメモリ効率が良く、トランザクションタイムアウトリスクなし
- HNSW: O(log n) だが高メモリ、明示的に選択した場合のみ使用

---

## 新しい設計

### 1. モデル定義: データ構造のみ

```swift
// ✅ 正しい: strategyは含めない
@Recordable
struct Product {
    #Index<Product>(
        [\.embedding],
        type: .vector(dimensions: 384, metric: .cosine)
        // strategyはモデル定義に含めない！
    )
    var embedding: [Float32]
}
```

**VectorIndexOptions（簡略化）**:

```swift
public struct VectorIndexOptions: Sendable {
    public let dimensions: Int
    public let metric: VectorMetric
    // strategyフィールドは削除

    public init(dimensions: Int, metric: VectorMetric = .cosine) {
        self.dimensions = dimensions
        self.metric = metric
    }
}
```

### 2. 実行時設定: IndexConfiguration

```swift
/// インデックスの実行時設定（ハードウェアやデータ規模に依存）
public struct IndexConfiguration: Sendable {
    public let indexName: String
    public let vectorStrategy: VectorIndexStrategy?
    public let spatialLevel: Int?  // 将来: Spatial Indexにも対応

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
```

### 3. Schema初期化時に戦略を指定

```swift
// パターン1: IndexConfiguration配列で指定
let schema = Schema(
    [Product.self],
    indexConfigurations: [
        IndexConfiguration(
            indexName: "product_embedding",
            vectorStrategy: .hnswBatch
        )
    ]
)

// パターン2: Dictionary形式（簡潔）
let schema = Schema(
    [Product.self],
    vectorStrategies: [
        "product_embedding": .hnswBatch
    ]
)
```

### 4. RecordStore初期化時に戦略を指定

```swift
// RecordStore拡張: 初期化時に戦略を指定
let store = try await RecordStore(
    database: database,
    schema: schema,
    subspace: subspace,
    vectorStrategies: [
        "product_embedding": getVectorStrategy()  // 環境変数から読み込み
    ]
)

func getVectorStrategy() -> VectorIndexStrategy {
    let envStrategy = ProcessInfo.processInfo.environment["VECTOR_STRATEGY"]
    switch envStrategy {
    case "hnsw":
        return .hnswBatch
    case "hnsw-inline":
        return .hnswInline
    default:
        return .flatScan  // デフォルト: 安全側
    }
}
```

---

## 実装計画

### Phase 1: IndexConfiguration導入

**ファイル**: `Sources/FDBRecordLayer/Core/IndexConfiguration.swift`

```swift
/// インデックスの実行時設定
///
/// モデル定義（データ構造）と分離して、実行時の最適化戦略を指定します。
/// これにより、環境（テスト vs 本番）やデータ規模に応じて戦略を変更できます。
public struct IndexConfiguration: Sendable, Codable {
    /// インデックス名（モデルで定義された名前と一致）
    public let indexName: String

    /// ベクトルインデックス戦略（オプション）
    public let vectorStrategy: VectorIndexStrategy?

    /// 空間インデックスレベル（オプション、将来実装）
    public let spatialLevel: Int?

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
```

### Phase 2: Schema拡張

**ファイル**: `Sources/FDBRecordLayer/Core/Schema.swift`

```swift
public final class Schema: Sendable {
    private let indexConfigurations: [String: IndexConfiguration]

    /// 初期化: IndexConfiguration配列を受け取る
    public init(
        _ recordTypes: [any Recordable.Type],
        version: Version = Version(1, 0, 0),
        indexes: [Index] = [],
        indexConfigurations: [IndexConfiguration] = []
    ) {
        // ...
        self.indexConfigurations = Dictionary(
            uniqueKeysWithValues: indexConfigurations.map { ($0.indexName, $0) }
        )
    }

    /// 便利イニシャライザ: Dictionary形式
    public convenience init(
        _ recordTypes: [any Recordable.Type],
        version: Version = Version(1, 0, 0),
        indexes: [Index] = [],
        vectorStrategies: [String: VectorIndexStrategy] = [:]
    ) {
        let configs = vectorStrategies.map { (name, strategy) in
            IndexConfiguration(indexName: name, vectorStrategy: strategy)
        }
        self.init(recordTypes, version: version, indexes: indexes, indexConfigurations: configs)
    }

    /// インデックスのベクトル戦略を取得
    public func getVectorStrategy(for indexName: String) -> VectorIndexStrategy {
        return indexConfigurations[indexName]?.vectorStrategy ?? .flatScan  // デフォルト
    }
}
```

### Phase 3: IndexManager修正

**ファイル**: `Sources/FDBRecordLayer/Index/IndexManager.swift`

```swift
public final class IndexManager: Sendable {
    public let schema: Schema

    private func createMaintainer<T: Recordable>(
        for index: Index,
        indexSubspace: Subspace,
        recordSubspace: Subspace
    ) throws -> AnyGenericIndexMaintainer<T> {
        switch index.type {
        case .vector:
            guard let vectorOptions = index.options.vectorOptions else {
                throw RecordLayerError.invalidArgument("Vector index requires vectorOptions")
            }

            // ✅ Schemaから実行時戦略を取得（モデル定義ではない）
            let strategy = schema.getVectorStrategy(for: index.name)

            switch strategy {
            case .flatScan:
                let maintainer = try GenericVectorIndexMaintainer<T>(
                    index: index,
                    subspace: indexSubspace,
                    recordSubspace: recordSubspace
                )
                return AnyGenericIndexMaintainer(maintainer)

            case .hnsw:
                let maintainer = try GenericHNSWIndexMaintainer<T>(
                    index: index,
                    subspace: indexSubspace,
                    recordSubspace: recordSubspace
                )
                return AnyGenericIndexMaintainer(maintainer)
            }
        // ...
        }
    }
}
```

### Phase 4: VectorIndexOptions簡略化

**ファイル**: `Sources/FDBRecordCore/IndexDefinition.swift`

```swift
/// ベクトルインデックスのデータ構造定義
///
/// **重要**: このstructはデータ構造（次元数、距離メトリック）のみを定義します。
/// 実行時の最適化戦略（flatScan vs HNSW）はIndexConfigurationで指定してください。
public struct VectorIndexOptions: Sendable, Codable {
    /// ベクトルの次元数
    public let dimensions: Int

    /// 距離メトリック
    public let metric: VectorMetric

    public init(dimensions: Int, metric: VectorMetric = .cosine) {
        self.dimensions = dimensions
        self.metric = metric
    }
}
```

### Phase 5: マクロ修正

**ファイル**: `Sources/FDBRecordLayerMacros/RecordableMacro.swift`

```swift
// マクロ生成コード修正
case .vector(let dimensions, let metric):
    indexTypeParam = """
indexType: .vector(VectorIndexOptions(
                        dimensions: \(dimensions),
                        metric: .\(metric)
                    ))
"""
// strategyパラメータは生成しない
```

---

## 移行パス

### Step 1: IndexConfiguration導入（後方互換性維持）

- `IndexConfiguration`と`Schema.init(indexConfigurations:)`を追加
- 既存の`VectorIndexOptions.strategy`は残す（deprecated警告付き）

### Step 2: 既存コードを新APIに移行

```swift
// Before
let schema = Schema([Product.self])  // VectorIndexOptions内のstrategyを使用

// After
let schema = Schema(
    [Product.self],
    vectorStrategies: [
        "product_embedding": .hnswBatch
    ]
)
```

### Step 3: VectorIndexOptions.strategy削除

- `strategy`フィールドを削除
- マクロコードから`strategy`生成を削除

---

## 使用例

### 例1: 環境依存の戦略切り替え

```swift
// 環境変数から戦略を読み込み
func createSchema() -> Schema {
    let vectorStrategy: VectorIndexStrategy

    #if DEBUG
    vectorStrategy = .flatScan  // テスト環境: 高速起動
    #else
    let envStrategy = ProcessInfo.processInfo.environment["VECTOR_STRATEGY"]
    vectorStrategy = envStrategy == "hnsw" ? .hnswBatch : .flatScan
    #endif

    return Schema(
        [Product.self],
        vectorStrategies: [
            "product_embedding": vectorStrategy
        ]
    )
}
```

### 例2: データ規模に応じた戦略変更

```swift
// データ規模を確認して戦略を決定
func createSchema(database: any DatabaseProtocol) async throws -> Schema {
    let recordCount = try await estimateRecordCount(database)

    let strategy: VectorIndexStrategy = recordCount > 10_000
        ? .hnswBatch   // 大規模: HNSW
        : .flatScan    // 小規模: Flat Scan

    return Schema(
        [Product.self],
        vectorStrategies: [
            "product_embedding": strategy
        ]
    )
}
```

### 例3: 複数インデックスで異なる戦略

```swift
@Recordable
struct MultiVectorProduct {
    #Index<MultiVectorProduct>([\.titleEmbedding], type: .vector(384, .cosine))
    #Index<MultiVectorProduct>([\.imageEmbedding], type: .vector(512, .cosine))

    var titleEmbedding: [Float32]   // 小規模（1万件）
    var imageEmbedding: [Float32]   // 大規模（100万件）
}

let schema = Schema(
    [MultiVectorProduct.self],
    vectorStrategies: [
        "multivectorproduct_titleembedding": .flatScan,   // 小規模
        "multivectorproduct_imageembedding": .hnswBatch   // 大規模
    ]
)
```

---

## テスト戦略

### 1. 単体テスト

```swift
@Test("IndexConfiguration: Vector strategy override")
func testVectorStrategyOverride() async throws {
    let schema = Schema(
        [Product.self],
        vectorStrategies: [
            "product_embedding": .hnswBatch
        ]
    )

    let strategy = schema.getVectorStrategy(for: "product_embedding")
    #expect(strategy == .hnswBatch)
}

@Test("IndexConfiguration: Default to flatScan")
func testDefaultStrategy() async throws {
    let schema = Schema([Product.self])

    let strategy = schema.getVectorStrategy(for: "product_embedding")
    #expect(strategy == .flatScan)  // デフォルト
}
```

### 2. 統合テスト

```swift
@Test("RecordStore: Different strategies for same model")
func testDifferentStrategies() async throws {
    // 小規模環境: flatScan
    let testSchema = Schema(
        [Product.self],
        vectorStrategies: ["product_embedding": .flatScan]
    )
    let testStore = try await RecordStore(database: db, schema: testSchema, ...)
    // ... テスト ...

    // 本番環境: HNSW
    let prodSchema = Schema(
        [Product.self],
        vectorStrategies: ["product_embedding": .hnswBatch]
    )
    let prodStore = try await RecordStore(database: db, schema: prodSchema, ...)
    // ... テスト ...
}
```

---

## ドキュメント更新

### CLAUDE.md 更新箇所

1. **VectorIndexStrategy セクション**: モデル定義から分離する設計思想を明記
2. **使用例**: 環境依存の戦略切り替え例を追加
3. **ベストプラクティス**: IndexConfigurationの使用を推奨

---

## 利点のまとめ

| 項目 | Before（問題） | After（解決） |
|------|--------------|-------------|
| **環境切り替え** | コード変更が必要 | 環境変数で切り替え |
| **テスト** | 本番と同じ戦略で遅い | 常にflatScanで高速 |
| **スケール** | モデル再定義が必要 | 設定変更のみ |
| **責任範囲** | モデルが最適化を含む | データ構造のみ |
| **デプロイ** | 再コンパイル必要 | 設定変更のみ |

---

## 関連Issue

- Java版Record Layerでも同様の分離設計を採用
- Elasticsearchのindex settingsとmappingsの分離と同じ思想

---

**承認**: 2025-01-17
**実装予定**: Phase 1-5を順次実装
