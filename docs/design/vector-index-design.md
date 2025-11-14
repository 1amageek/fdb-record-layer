# VECTOR Index Design (ベクトル類似度検索)

## 概要

Swift版Record LayerにVECTORインデックスを実装し、ML/AI埋め込みベクトルの高速な類似度検索を提供します。**HNSW（Hierarchical Navigable Small World）**アルゴリズムを使用して、対数時間での近似最近傍探索を実現します。

## 背景

### ベクトル検索の用途

1. **意味検索（Semantic Search）**: テキスト埋め込みの類似度検索
2. **画像検索**: 画像埋め込みの類似度検索
3. **推薦システム**: ユーザー/アイテム埋め込みの類似アイテム検索
4. **異常検知**: 正常パターンからの距離による異常検出
5. **RAG（Retrieval-Augmented Generation）**: LLMへの関連コンテキスト提供

### なぜHNSWか

| 手法 | 時間計算量 | 精度 | 特徴 |
|------|----------|------|------|
| **線形探索** | O(n) | 100% | 小規模データセットのみ |
| **LSH** | O(log n) | 80-90% | ハッシュベース、精度低め |
| **IVFFlat** | O(√n) | 90-95% | クラスタリングベース |
| **HNSW** | O(log n) | 95-99% | グラフベース、高精度 |

**HNSW**は**高精度**と**高速**を両立し、ベクターデータベースの標準アルゴリズムです。

---

## HNSWアルゴリズムの原理

### 1. 階層的グラフ構造

HNSWは**多層のスキップリスト風グラフ**を構築します：

```
レイヤー2（最上層）: [A] --------→ [Z]
                       |            |
レイヤー1:            [A] --→ [M] --→ [Z]
                       |      |      |
レイヤー0（最下層）:   [A]-[B]-[M]-[X]-[Y]-[Z]
                     （すべてのベクトル）
```

**特性**:
- **上層**: 少数のノード、長距離リンク（粗い探索）
- **下層**: すべてのノード、短距離リンク（精密な探索）
- **探索**: 上から下へ、貪欲に最近傍を辿る

### 2. 挿入アルゴリズム

```
1. ランダムにレイヤーを決定（指数分布）
2. 最上層から貪欲探索で最近傍を見つける
3. 各レイヤーで M 個の近傍と接続
4. 近傍ノードの接続も更新（双方向リンク）
```

### 3. 検索アルゴリズム

```
1. エントリーポイント（最上層のノード）から開始
2. 各レイヤーで貪欲探索（候補をヒープで管理）
3. 最下層で ef 個の候補を保持
4. 上位 k 個を返す
```

### 4. 主要パラメータ

| パラメータ | 説明 | 推奨値 | トレードオフ |
|-----------|------|--------|------------|
| **M** | 各ノードの最大接続数 | 16-32 | 大きい → 精度↑、メモリ↑ |
| **efConstruction** | 構築時の候補数 | 100-200 | 大きい → 精度↑、構築時間↑ |
| **efSearch** | 検索時の候補数 | 50-100 | 大きい → 精度↑、検索時間↑ |
| **mL** | レイヤー確率の逆数 | 1/log(2) ≈ 1.44 | 階層の高さを制御 |

---

## FoundationDBへのマッピング

### 1. データモデル

**キー構造**:

```
# ベクトルデータ
[vectorIndexSubspace]["vector"][vectorID] = {
    "vector": [Float],        // ベクトル（正規化済み）
    "layer": Int,             // このノードの最大レイヤー
    "metadata": Data          // 任意のメタデータ
}

# グラフ構造（隣接リスト）
[vectorIndexSubspace]["edges"][layer][vectorID][neighborID] = distance

# エントリーポイント
[vectorIndexSubspace]["entry"] = vectorID

# 統計情報
[vectorIndexSubspace]["stats"]["count"] = Int
[vectorIndexSubspace]["stats"]["dimensions"] = Int
```

**設計上の選択**:

1. **ベクトルの正規化**: すべてのベクトルを単位ベクトルに正規化（コサイン類似度 = 内積）
2. **距離メトリック**: L2距離またはコサイン類似度（設定可能）
3. **エッジの双方向性**: 各エッジを2方向に保存（検索の効率化）

### 2. トランザクション戦略

**挿入**:
- 各レイヤーのエッジ更新を1トランザクションで実行
- M が小さい（16-32）ため、10MB制限に収まる

**検索**:
- スナップショット読み取りで非競合
- 階層的な探索で効率的（O(log n)読み取り）

**バッチ構築**:
- OnlineIndexerパターンで大量ベクトルをバッチ挿入
- RangeSetで進行状況を追跡

---

## Swift実装設計

### 1. Vector型とDistance

```swift
/// ベクトル型（型安全）
public struct Vector: Sendable, Equatable {
    public let elements: [Float]
    public let dimensions: Int

    public init(_ elements: [Float]) {
        self.elements = elements
        self.dimensions = elements.count
    }

    /// ベクトルを正規化（単位ベクトルに）
    public func normalized() -> Vector {
        let magnitude = sqrt(elements.reduce(0) { $0 + $1 * $1 })
        return Vector(elements.map { $0 / magnitude })
    }

    /// 内積
    public func dot(_ other: Vector) -> Float {
        precondition(dimensions == other.dimensions)
        return zip(elements, other.elements).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// L2距離（ユークリッド距離）
    public func l2Distance(to other: Vector) -> Float {
        precondition(dimensions == other.dimensions)
        let diff = zip(elements, other.elements).map { $0 - $1 }
        return sqrt(diff.reduce(0) { $0 + $1 * $1 })
    }

    /// コサイン類似度（正規化ベクトルなら内積と同じ）
    public func cosineSimilarity(to other: Vector) -> Float {
        normalized().dot(other.normalized())
    }
}

/// 距離メトリック
public enum DistanceMetric: Sendable {
    case l2           // L2距離（ユークリッド距離）
    case cosine       // コサイン類似度（内積ベース）
    case innerProduct // 内積（正規化済みベクトル用）

    func distance(_ a: Vector, _ b: Vector) -> Float {
        switch self {
        case .l2:
            return a.l2Distance(to: b)
        case .cosine:
            return 1.0 - a.cosineSimilarity(to: b)  // 距離に変換
        case .innerProduct:
            return -a.dot(b)  // 負の内積（小さいほど近い）
        }
    }
}
```

### 2. VectorIndexDefinition

```swift
/// VECTORインデックスの定義
public struct VectorIndexDefinition: Sendable {
    public let name: String
    public let fieldName: String         // ベクトルフィールド名
    public let dimensions: Int           // ベクトルの次元数
    public let metric: DistanceMetric    // 距離メトリック
    public let m: Int                    // 最大接続数
    public let efConstruction: Int       // 構築時の候補数
    public let efSearch: Int             // 検索時の候補数（デフォルト）
    public let mL: Float                 // レイヤー確率の逆数

    public init(
        name: String,
        fieldName: String,
        dimensions: Int,
        metric: DistanceMetric = .cosine,
        m: Int = 16,
        efConstruction: Int = 100,
        efSearch: Int = 50,
        mL: Float = 1.0 / log(2.0)
    ) {
        self.name = name
        self.fieldName = fieldName
        self.dimensions = dimensions
        self.metric = metric
        self.m = m
        self.efConstruction = efConstruction
        self.efSearch = efSearch
        self.mL = mL
    }
}

/// マクロAPI拡張
extension Index {
    public static func vector(
        _ name: String,
        on fieldExpression: FieldKeyExpression,
        dimensions: Int,
        metric: DistanceMetric = .cosine,
        m: Int = 16
    ) -> Index {
        Index(
            name: name,
            type: .vector,
            rootExpression: fieldExpression,
            options: IndexOptions(
                vectorDimensions: dimensions,
                vectorMetric: metric,
                vectorM: m
            )
        )
    }
}
```

### 3. VectorIndexMaintainer

```swift
/// VECTORインデックスのメンテナー
public final class VectorIndexMaintainer<Record: Sendable>: IndexMaintainer {
    private let definition: VectorIndexDefinition
    private let recordAccess: any RecordAccess<Record>
    private let subspace: Subspace
    private let rng: RandomNumberGenerator

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        transaction: TransactionProtocol
    ) async throws {
        // 1. 古いベクトルを削除
        if let oldRecord = oldRecord {
            let oldVectorID = recordAccess.extractPrimaryKey(from: oldRecord)
            try await deleteVector(oldVectorID, transaction: transaction)
        }

        // 2. 新しいベクトルを挿入
        if let newRecord = newRecord {
            let vectorID = recordAccess.extractPrimaryKey(from: newRecord)
            guard let vector = try recordAccess.extractFieldValue(
                from: newRecord,
                fieldName: definition.fieldName
            ) as? Vector else {
                throw RecordLayerError.invalidArgument("Field '\(definition.fieldName)' is not a Vector")
            }

            precondition(vector.dimensions == definition.dimensions,
                        "Vector dimensions mismatch: expected \(definition.dimensions), got \(vector.dimensions)")

            try await insertVector(vectorID, vector: vector.normalized(), transaction: transaction)
        }
    }

    /// ベクトルを挿入（HNSWアルゴリズム）
    private func insertVector(
        _ vectorID: PrimaryKey,
        vector: Vector,
        transaction: TransactionProtocol
    ) async throws {
        // 1. レイヤーをランダムに決定
        let layer = randomLayer()

        // 2. エントリーポイントを取得
        guard let entryPoint = try await getEntryPoint(transaction: transaction) else {
            // 最初のベクトル
            try await saveVector(vectorID, vector: vector, layer: layer, transaction: transaction)
            try await setEntryPoint(vectorID, transaction: transaction)
            return
        }

        // 3. 各レイヤーで最近傍を探索
        var currentNearest = entryPoint
        var currentLayer = try await getVectorLayer(entryPoint, transaction: transaction)

        // 上層から探索（貪欲探索）
        while currentLayer > layer {
            currentNearest = try await greedySearch(
                query: vector,
                entryPoint: currentNearest,
                layer: currentLayer,
                ef: 1,
                transaction: transaction
            ).first!

            currentLayer -= 1
        }

        // 4. 挿入レイヤーから最下層まで接続を確立
        for l in stride(from: layer, through: 0, by: -1) {
            let candidates = try await searchLayer(
                query: vector,
                entryPoint: currentNearest,
                layer: l,
                ef: definition.efConstruction,
                transaction: transaction
            )

            // M個の最近傍と接続
            let neighbors = Array(candidates.prefix(definition.m))
            try await connectNeighbors(
                vectorID,
                vector: vector,
                neighbors: neighbors,
                layer: l,
                transaction: transaction
            )

            currentNearest = neighbors.first!.vectorID
        }

        // 5. ベクトルメタデータを保存
        try await saveVector(vectorID, vector: vector, layer: layer, transaction: transaction)
    }

    /// レイヤーをランダムに決定（指数分布）
    private func randomLayer() -> Int {
        let uniform = Float.random(in: 0..<1)
        return Int(floor(-log(uniform) * definition.mL))
    }

    /// 貪欲探索（単一の最近傍）
    private func greedySearch(
        query: Vector,
        entryPoint: PrimaryKey,
        layer: Int,
        ef: Int,
        transaction: TransactionProtocol
    ) async throws -> [Neighbor] {
        var visited: Set<PrimaryKey> = []
        var candidates = MinHeap<Neighbor>()  // 距離が小さい順
        var results = MaxHeap<Neighbor>()     // 距離が大きい順（上位efを保持）

        let entryVector = try await getVector(entryPoint, transaction: transaction)
        let entryDistance = definition.metric.distance(query, entryVector)
        candidates.insert(Neighbor(vectorID: entryPoint, distance: entryDistance))
        results.insert(Neighbor(vectorID: entryPoint, distance: entryDistance))
        visited.insert(entryPoint)

        while !candidates.isEmpty {
            let current = candidates.extractMin()

            // 打ち切り条件: これ以上近いノードがない
            if current.distance > results.max()!.distance {
                break
            }

            // 隣接ノードを探索
            let neighbors = try await getNeighbors(current.vectorID, layer: layer, transaction: transaction)
            for neighborID in neighbors {
                if visited.contains(neighborID) { continue }
                visited.insert(neighborID)

                let neighborVector = try await getVector(neighborID, transaction: transaction)
                let neighborDistance = definition.metric.distance(query, neighborVector)

                if neighborDistance < results.max()!.distance || results.count < ef {
                    candidates.insert(Neighbor(vectorID: neighborID, distance: neighborDistance))
                    results.insert(Neighbor(vectorID: neighborID, distance: neighborDistance))

                    if results.count > ef {
                        results.extractMax()  // 最遠のノードを削除
                    }
                }
            }
        }

        return results.sorted { $0.distance < $1.distance }
    }

    /// レイヤー内の検索（ef個の候補を返す）
    private func searchLayer(
        query: Vector,
        entryPoint: PrimaryKey,
        layer: Int,
        ef: Int,
        transaction: TransactionProtocol
    ) async throws -> [Neighbor] {
        try await greedySearch(
            query: query,
            entryPoint: entryPoint,
            layer: layer,
            ef: ef,
            transaction: transaction
        )
    }

    /// 近傍と接続
    private func connectNeighbors(
        _ vectorID: PrimaryKey,
        vector: Vector,
        neighbors: [Neighbor],
        layer: Int,
        transaction: TransactionProtocol
    ) async throws {
        for neighbor in neighbors {
            // 双方向エッジを作成
            let edgeKey1 = buildEdgeKey(from: vectorID, to: neighbor.vectorID, layer: layer)
            let edgeKey2 = buildEdgeKey(from: neighbor.vectorID, to: vectorID, layer: layer)

            transaction.setValue(
                withUnsafeBytes(of: neighbor.distance) { Array($0) },
                for: edgeKey1
            )
            transaction.setValue(
                withUnsafeBytes(of: neighbor.distance) { Array($0) },
                for: edgeKey2
            )

            // 近傍ノードの接続数がMを超えたら剪定
            try await pruneNeighbors(neighbor.vectorID, layer: layer, transaction: transaction)
        }
    }

    /// 接続数がMを超えた場合の剪定
    private func pruneNeighbors(
        _ vectorID: PrimaryKey,
        layer: Int,
        transaction: TransactionProtocol
    ) async throws {
        let neighbors = try await getNeighbors(vectorID, layer: layer, transaction: transaction)

        if neighbors.count <= definition.m {
            return  // 剪定不要
        }

        // ヒューリスティック: 距離が近い順にM個を保持
        let vector = try await getVector(vectorID, transaction: transaction)
        var neighborsWithDistance: [(PrimaryKey, Float)] = []

        for neighborID in neighbors {
            let neighborVector = try await getVector(neighborID, transaction: transaction)
            let distance = definition.metric.distance(vector, neighborVector)
            neighborsWithDistance.append((neighborID, distance))
        }

        neighborsWithDistance.sort { $0.1 < $1.1 }
        let toKeep = Set(neighborsWithDistance.prefix(definition.m).map(\.0))

        // 遠いノードとのエッジを削除
        for neighborID in neighbors where !toKeep.contains(neighborID) {
            let edgeKey = buildEdgeKey(from: vectorID, to: neighborID, layer: layer)
            transaction.clear(key: edgeKey)
        }
    }

    private func buildEdgeKey(from: PrimaryKey, to: PrimaryKey, layer: Int) -> FDB.Bytes {
        subspace.subspace("edges", layer).pack(Tuple(from, to))
    }
}

private struct Neighbor: Comparable {
    let vectorID: PrimaryKey
    let distance: Float

    static func < (lhs: Neighbor, rhs: Neighbor) -> Bool {
        lhs.distance < rhs.distance
    }
}
```

### 4. VectorQuery（検索API）

```swift
/// ベクトル検索クエリ
public struct VectorQuery<Record: Sendable>: TypedQueryPlan {
    private let queryVector: Vector
    private let k: Int
    private let ef: Int?  // カスタムef（nilならインデックスのデフォルト）

    public func execute(
        transaction: TransactionProtocol,
        context: QueryContext
    ) async throws -> AnyTypedRecordCursor<Record> {
        let indexDef = context.index.vectorDefinition!
        let ef = self.ef ?? indexDef.efSearch

        // 1. エントリーポイントから探索開始
        guard let entryPoint = try await getEntryPoint(transaction: transaction) else {
            return EmptyCursor()
        }

        // 2. 最上層から貪欲探索
        var currentNearest = entryPoint
        var currentLayer = try await getVectorLayer(entryPoint, transaction: transaction)

        while currentLayer > 0 {
            currentNearest = try await greedySearch(
                query: queryVector,
                entryPoint: currentNearest,
                layer: currentLayer,
                ef: 1,
                transaction: transaction
            ).first!.vectorID

            currentLayer -= 1
        }

        // 3. 最下層でef個の候補を取得
        let candidates = try await searchLayer(
            query: queryVector,
            entryPoint: currentNearest,
            layer: 0,
            ef: ef,
            transaction: transaction
        )

        // 4. 上位k個を返す
        let topK = Array(candidates.prefix(k))

        return VectorSearchCursor(
            results: topK,
            recordStore: context.recordStore,
            transaction: transaction
        )
    }
}

/// QueryBuilder拡張
extension QueryBuilder {
    public func nearestNeighbors(
        _ keyPath: KeyPath<Record, Vector>,
        to queryVector: Vector,
        k: Int,
        ef: Int? = nil
    ) -> Self {
        // VectorQueryをプランに追加
        self
    }
}
```

---

## API使用例

### 基本的な検索

```swift
import FDBRecordLayer

// 1. レコード定義
@Recordable
struct Product {
    #Index<Product>([\.embedding], type: .vector(dimensions: 768))

    #PrimaryKey<Product>([\.productID])

    var productID: Int64
    var name: String
    var description: String
    var embedding: Vector  // 768次元のベクトル（例: OpenAI Embeddings）
}

// 2. ベクトルインデックス設定
let vectorIndex = VectorIndexDefinition(
    name: "product_embedding",
    fieldName: "embedding",
    dimensions: 768,
    metric: .cosine,
    m: 16,
    efConstruction: 100,
    efSearch: 50
)

// 3. レコード保存
let product = Product(
    productID: 1,
    name: "Wireless Headphones",
    description: "High-quality noise-canceling headphones",
    embedding: Vector(/* 768次元のベクトル */)
)
try await store.save(product)

// 4. 類似商品検索
let queryVector = Vector(/* ユーザーのクエリベクトル */)
let similarProducts = try await store.query(Product.self)
    .nearestNeighbors(\.embedding, to: queryVector, k: 10)
    .execute()

for (product, distance) in similarProducts {
    print("\(product.name) - Distance: \(distance)")
}
```

### カスタムefで精度調整

```swift
// 高精度検索（ef=200）
let highPrecision = try await store.query(Product.self)
    .nearestNeighbors(\.embedding, to: queryVector, k: 10, ef: 200)
    .execute()

// 高速検索（ef=20）
let fastSearch = try await store.query(Product.self)
    .nearestNeighbors(\.embedding, to: queryVector, k: 10, ef: 20)
    .execute()
```

### バッチ構築

```swift
// 大量のベクトルをバッチで挿入
let indexer = OnlineIndexer<Product>(
    database: database,
    indexName: "product_embedding",
    batchSize: 1000
)

try await indexer.buildIndex()

// 進行状況の確認
let (scanned, total, progress) = try await indexer.getProgress()
print("Progress: \(progress * 100)%")
```

---

## パフォーマンス最適化

### 1. メモリ効率

**Half-Precision Floats（Float16）**:
```swift
/// 16ビット浮動小数点数でメモリを半減
public struct VectorF16: Sendable {
    let elements: [Float16]

    func toFloat32() -> Vector {
        Vector(elements.map { Float($0) })
    }
}

// インデックスオプション
VectorIndexDefinition(
    name: "product_embedding_f16",
    fieldName: "embedding",
    dimensions: 768,
    precision: .float16  // メモリ50%削減
)
```

### 2. 並列検索

**複数クエリの並列実行**:
```swift
// 100個のクエリを並列実行
await withTaskGroup(of: [Product].self) { group in
    for queryVector in queryVectors {
        group.addTask {
            try await store.query(Product.self)
                .nearestNeighbors(\.embedding, to: queryVector, k: 10)
                .execute()
        }
    }

    for await results in group {
        // 結果を処理
    }
}
```

### 3. キャッシング

**頻繁なクエリのキャッシュ**:
```swift
private final class VectorQueryCache: Sendable {
    private let cache: Mutex<[Vector: [Neighbor]]>
    private let maxSize: Int = 1000

    func get(query: Vector) -> [Neighbor]? {
        cache.withLock { $0[query] }
    }

    func set(query: Vector, results: [Neighbor]) {
        cache.withLock { cache in
            if cache.count >= maxSize {
                cache.removeFirst()
            }
            cache[query] = results
        }
    }
}
```

---

## パフォーマンス特性

### 理論的計算量

| 操作 | 時間計算量 | 空間計算量 |
|------|----------|----------|
| **挿入** | O(log n · M · efConstruction) | O(n · M) |
| **検索** | O(log n · M · efSearch) | O(efSearch) |
| **削除** | O(log n · M) | O(1) |

### 実測値（予想）

**データセット**: 100万ベクトル、768次元、M=16

| 操作 | レイテンシ | スループット |
|------|----------|------------|
| **挿入** | 10-50ms | 1,000-5,000 vec/sec |
| **検索（k=10, ef=50）** | 5-20ms | 5,000-20,000 queries/sec |
| **検索（k=10, ef=200）** | 20-80ms | 1,000-5,000 queries/sec |

### パラメータチューニング

| パラメータ | 小さい値 | 大きい値 | 推奨値 |
|-----------|---------|---------|--------|
| **M** | 速い挿入、低精度 | 遅い挿入、高精度 | 16-32 |
| **efConstruction** | 速い構築、低精度 | 遅い構築、高精度 | 100-200 |
| **efSearch** | 速い検索、低精度 | 遅い検索、高精度 | 動的に調整 |

---

## 実装優先度

### Phase 1（3-4週間）: 基本実装

- [x] Vector型、DistanceMetric実装
- [x] VectorIndexDefinition設計
- [x] HNSWアルゴリズムのコア実装
  - レイヤー生成
  - 貪欲探索
  - 挿入アルゴリズム
- [x] VectorIndexMaintainer実装
- [x] 基本的なVectorQuery実装

### Phase 2（1-2週間）: 最適化

- [ ] 並列検索のサポート
- [ ] クエリキャッシュ
- [ ] バッチ構築の最適化
- [ ] エッジの剪定ヒューリスティック改善

### Phase 3（1-2週間）: 高度な機能

- [ ] Float16サポート（メモリ削減）
- [ ] 動的efチューニング
- [ ] フィルタリング付き検索（メタデータでフィルタ）
- [ ] インクリメンタル更新の最適化

### Phase 4（将来）: エンタープライズ機能

- [ ] 量子化（Product Quantization）
- [ ] ディスクベースのインデックス（巨大データセット）
- [ ] 分散HNSW（シャーディング）
- [ ] GPU加速（Metal/CUDA）

---

## テスト戦略

### ユニットテスト

```swift
@Suite struct VectorTests {
    @Test func testVectorNormalization() async throws {
        let v = Vector([3.0, 4.0])
        let normalized = v.normalized()

        #expect(abs(normalized.elements[0] - 0.6) < 0.01)
        #expect(abs(normalized.elements[1] - 0.8) < 0.01)
    }

    @Test func testCosineSimilarity() async throws {
        let v1 = Vector([1.0, 0.0])
        let v2 = Vector([0.0, 1.0])

        #expect(v1.cosineSimilarity(to: v2) == 0.0)  // 直交
    }
}

@Suite struct HNSWTests {
    @Test func testLayerGeneration() async throws {
        // レイヤー分布の検証
    }

    @Test func testGreedySearch() async throws {
        // 貪欲探索の動作確認
    }

    @Test func testInsertAndSearch() async throws {
        // 挿入と検索の統合テスト
    }
}
```

### 精度テスト

```swift
@Suite struct VectorAccuracyTests {
    @Test func testRecall() async throws {
        // Recall@10の測定（真の最近傍10個のうち何個を返せるか）
        let groundTruth = computeExactNearestNeighbors(queryVector, k: 10)
        let hnswResults = try await store.query(Product.self)
            .nearestNeighbors(\.embedding, to: queryVector, k: 10, ef: 50)
            .execute()

        let recall = computeRecall(groundTruth, hnswResults)
        #expect(recall > 0.95)  // 95%以上のRecall
    }

    @Test func testRecallVsEf() async throws {
        // efと精度の関係を測定
        for ef in [10, 20, 50, 100, 200] {
            let recall = measureRecall(ef: ef)
            print("ef=\(ef): Recall=\(recall)")
        }
    }
}
```

### パフォーマンステスト

```swift
@Suite struct VectorPerformanceTests {
    @Test func testInsertionThroughput() async throws {
        let start = Date()

        for i in 0..<10_000 {
            let product = Product(
                productID: Int64(i),
                name: "Product \(i)",
                embedding: randomVector(dimensions: 768)
            )
            try await store.save(product)
        }

        let duration = Date().timeIntervalSince(start)
        let throughput = 10_000.0 / duration
        print("Insertion: \(throughput) vec/sec")

        #expect(throughput > 500)  // 500 vec/sec以上
    }

    @Test func testSearchLatency() async throws {
        let queryVector = randomVector(dimensions: 768)

        let start = Date()
        let _ = try await store.query(Product.self)
            .nearestNeighbors(\.embedding, to: queryVector, k: 10, ef: 50)
            .execute()
        let latency = Date().timeIntervalSince(start)

        print("Search latency: \(latency * 1000) ms")
        #expect(latency < 0.1)  // 100ms以内
    }
}
```

---

## 制約と制限

### 初期バージョンの制限

1. **量子化**: Product Quantizationなどの高度な圧縮は未実装
2. **ディスクベース**: すべてのベクトルがメモリに収まる前提（FoundationDBのキャッシュに依存）
3. **分散HNSW**: シャーディングは未実装（単一インデックス）
4. **GPU加速**: CPUのみ（Metalなどの加速は将来実装）

### FoundationDBの制限

1. **トランザクションサイズ**: 10MB（大量のエッジ更新は分割が必要）
2. **実行時間制限**: 5秒（大規模な探索は継続トークンで分割）
3. **読み取りスループット**: ネットワークバンド幅に依存

---

## 競合製品との比較

| データベース | HNSW | 次元制限 | 言語 | 特徴 |
|------------|------|---------|------|------|
| **Pinecone** | ✅ | 20,000 | Managed | フルマネージド |
| **Weaviate** | ✅ | 65,536 | Go | オープンソース、GraphQL |
| **Milvus** | ✅ | 32,768 | C++/Go | エンタープライズ向け |
| **pgvector** | ✅ | 16,000 | PostgreSQL | RDBと統合 |
| **Swift Record Layer** | ✅ | 制限なし | Swift | FoundationDB、型安全 |

**Swift Record Layerの強み**:
- ✅ **型安全**: SwiftのジェネリクスとRecordable
- ✅ **トランザクション**: ACID保証
- ✅ **統合**: 他のインデックス（VALUE、RANK）と組み合わせ可能
- ✅ **スケーラビリティ**: FoundationDBの分散アーキテクチャ

---

## まとめ

**Swift-Native VECTOR Index**は、以下の特徴を持ちます：

✅ **高精度**: HNSW（95-99% Recall）
✅ **高速**: O(log n)検索
✅ **スケーラブル**: FoundationDBの分散特性を活用
✅ **型安全**: SwiftのRecordable APIと統合
✅ **拡張可能**: カスタムメトリック、Float16対応

**ユースケース**:

- 🔍 **意味検索**: RAG、QA、文書検索
- 🖼️ **画像検索**: 視覚的類似画像の検索
- 🛍️ **推薦**: 類似アイテム推薦
- 🔐 **異常検知**: 正常パターンからの逸脱検出

**次のステップ**:

1. Phase 1実装（3-4週間）
2. 精度・パフォーマンステスト
3. 実世界のデータセットでの検証
4. ドキュメントと使用例の整備

---

**Last Updated**: 2025-01-13
**Status**: 設計完了、実装準備完了
**Priority**: 🔴 高（ML/AI統合の重要性）
