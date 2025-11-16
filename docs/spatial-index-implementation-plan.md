# Spatial Index Implementation Plan

## 実装状況

### ✅ 完了（Phase 0: 基礎実装）

| コンポーネント | ファイル | 実装状況 |
|--------------|---------|---------|
| **@Spatial マクロ** | SpatialMacro.swift | ✅ 完了 |
| **GeoCoordinate** | GeoCoordinate.swift | ✅ 完了 |
| **SpatialRepresentable** | GeoCoordinate.swift | ✅ 完了 |
| **SpatialIndexOptions** | IndexDefinition.swift:36-58 | ✅ 完了 |
| **IndexDefinitionType.spatial** | IndexDefinition.swift:86 | ✅ 完了 |

### 🔄 更新が必要（新設計への移行）

| コンポーネント | 変更内容 | 優先度 |
|--------------|---------|--------|
| **SpatialType** | String enum → Associated value enum | 🔴 高 |
| **@Spatial マクロ** | KeyPath直接指定方式に対応 | 🔴 高 |
| **SpatialIndexMaintainer** | KeyPathベース抽出に変更 | 🔴 高 |

### 🚧 実装が必要（Phase 1-4）

| Phase | 機能 | 優先度 | 推定工数 | 備考 |
|-------|------|--------|---------|------|
| **Phase 1** | Geohash + Z-order curve + 動的精度調整 | 🔴 高 | 5-7日 | エッジケース処理含む |
| **Phase 2** | SpatialIndexMaintainer (KeyPath対応) | 🔴 高 | 4-6日 | 新設計対応 (-2日) |
| **Phase 3** | 地理クエリAPI + ストリーミング | 🟡 中 | 4-6日 | ストリーミングカーソル実装 |
| **Phase 4** | 最適化 + プロパティベーステスト | 🟢 低 | 3-4日 | プロパティベースドテスト |

**合計推定工数**: **16-23日** (旧見積: 18-25日、KeyPath対応で-2日削減)

---

## 新設計: KeyPath直接指定方式

### 概要

@Spatialマクロで**KeyPathを直接指定**することで、任意の構造体を空間インデックス化できます。SpatialRepresentableプロトコル準拠は不要です。

**構文**:
```swift
@Spatial(
    type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude
    )
)
```

**利点**:
- ✅ **プロトコル不要**: 任意の構造体で使える
- ✅ **ネストKeyPath対応**: `\.location.coordinates.latitude` など深いネストも可能
- ✅ **フィールド名の柔軟性**: `lat`/`lon`/`alt` など任意の名前に対応
- ✅ **型安全**: KeyPathによるコンパイル時チェック
- ✅ **エレガント**: type内にKeyPathsをネストする論理的構造

---

## Phase 0: 新設計への移行（2-3日）

### 0.1 SpatialTypeの再定義

**実装ファイル**: `Sources/FDBRecordCore/IndexDefinition.swift`

**変更前**:
```swift
// ❌ 旧実装: String enum（KeyPath情報なし）
public enum SpatialType: String, Sendable {
    case geo
    case geo3D
    case cartesian
    case cartesian3D
}
```

**変更後**:
```swift
// ✅ 新実装: Associated value enum（KeyPath情報を含む）
public enum SpatialType: Sendable {
    /// 2D geographic coordinates (latitude, longitude)
    case geo(latitude: AnyKeyPath, longitude: AnyKeyPath)

    /// 3D geographic coordinates (latitude, longitude, altitude)
    case geo3D(latitude: AnyKeyPath, longitude: AnyKeyPath, altitude: AnyKeyPath)

    /// 2D Cartesian coordinates (x, y)
    case cartesian(x: AnyKeyPath, y: AnyKeyPath)

    /// 3D Cartesian coordinates (x, y, z)
    case cartesian3D(x: AnyKeyPath, y: AnyKeyPath, z: AnyKeyPath)

    // ヘルパープロパティ
    public var dimensions: Int {
        switch self {
        case .geo, .cartesian:
            return 2
        case .geo3D, .cartesian3D:
            return 3
        }
    }

    public var coordinateSystem: String {
        switch self {
        case .geo, .geo3D:
            return "geographic"
        case .cartesian, .cartesian3D:
            return "cartesian"
        }
    }

    /// Extract KeyPaths for value extraction
    public var keyPaths: [AnyKeyPath] {
        switch self {
        case .geo(let lat, let lon):
            return [lat, lon]
        case .geo3D(let lat, let lon, let alt):
            return [lat, lon, alt]
        case .cartesian(let x, let y):
            return [x, y]
        case .cartesian3D(let x, let y, let z):
            return [x, y, z]
        }
    }
}
```

### 0.2 @Spatialマクロの更新

**実装ファイル**: `Sources/FDBRecordLayerMacros/SpatialMacro.swift`

**新しい構文サポート**:
```swift
// 2D地理座標
@Spatial(
    type: .geo(
        latitude: \.location.latitude,
        longitude: \.location.longitude
    )
)
var location: Location

// 3D地理座標（高度付き）
@Spatial(
    type: .geo3D(
        latitude: \.position.lat,
        longitude: \.position.lon,
        altitude: \.position.height
    )
)
var position: Position

// 2D Cartesian座標
@Spatial(
    type: .cartesian(
        x: \.coords.x,
        y: \.coords.y
    )
)
var coords: Coordinates

// 3D Cartesian座標
@Spatial(
    type: .cartesian3D(
        x: \.point.x,
        y: \.point.y,
        z: \.point.z
    )
)
var point: Point3D
```

**マクロ実装**:
```swift
public struct SpatialMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // 1. プロパティ宣言の検証
        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: node,
                message: SpatialMacroDiagnostic.notAppliedToProperty
            ))
            return []
        }

        // 2. 引数の抽出
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            context.diagnose(Diagnostic(
                node: node,
                message: SpatialMacroDiagnostic.missingTypeParameter
            ))
            return []
        }

        // 3. type: .geo(latitude: \.x, longitude: \.y) を解析
        guard let typeArg = arguments.first(where: { $0.label?.text == "type" }),
              let functionCall = typeArg.expression.as(FunctionCallExprSyntax.self),
              let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) else {
            context.diagnose(Diagnostic(
                node: node,
                message: SpatialMacroDiagnostic.invalidTypeFormat
            ))
            return []
        }

        let typeName = memberAccess.declName.baseName.text  // "geo", "geo3D", etc.

        // 4. KeyPath引数の検証
        guard let keyPathArgs = functionCall.arguments else {
            context.diagnose(Diagnostic(
                node: functionCall,
                message: SpatialMacroDiagnostic.missingKeyPaths
            ))
            return []
        }

        // 5. タイプごとにKeyPathsを検証
        try validateKeyPaths(typeName: typeName, arguments: keyPathArgs, context: context)

        // 6. @Recordableマクロが収集できるようにメタデータとしてマーク
        return []
    }

    private static func validateKeyPaths(
        typeName: String,
        arguments: LabeledExprListSyntax,
        context: some MacroExpansionContext
    ) throws {
        switch typeName {
        case "geo":
            // latitude:, longitude: が必要
            guard arguments.contains(where: { $0.label?.text == "latitude" }),
                  arguments.contains(where: { $0.label?.text == "longitude" }) else {
                context.diagnose(Diagnostic(
                    node: arguments,
                    message: SpatialMacroDiagnostic.missingGeoKeyPaths
                ))
                return
            }

        case "geo3D":
            // latitude:, longitude:, altitude: が必要
            guard arguments.contains(where: { $0.label?.text == "latitude" }),
                  arguments.contains(where: { $0.label?.text == "longitude" }),
                  arguments.contains(where: { $0.label?.text == "altitude" }) else {
                context.diagnose(Diagnostic(
                    node: arguments,
                    message: SpatialMacroDiagnostic.missingGeo3DKeyPaths
                ))
                return
            }

        case "cartesian":
            // x:, y: が必要
            guard arguments.contains(where: { $0.label?.text == "x" }),
                  arguments.contains(where: { $0.label?.text == "y" }) else {
                context.diagnose(Diagnostic(
                    node: arguments,
                    message: SpatialMacroDiagnostic.missingCartesianKeyPaths
                ))
                return
            }

        case "cartesian3D":
            // x:, y:, z: が必要
            guard arguments.contains(where: { $0.label?.text == "x" }),
                  arguments.contains(where: { $0.label?.text == "y" }),
                  arguments.contains(where: { $0.label?.text == "z" }) else {
                context.diagnose(Diagnostic(
                    node: arguments,
                    message: SpatialMacroDiagnostic.missingCartesian3DKeyPaths
                ))
                return
            }

        default:
            context.diagnose(Diagnostic(
                node: arguments,
                message: SpatialMacroDiagnostic.unknownSpatialType(typeName)
            ))
        }
    }
}

// MARK: - Diagnostics

enum SpatialMacroDiagnostic {
    case notAppliedToProperty
    case missingTypeParameter
    case invalidTypeFormat
    case missingKeyPaths
    case missingGeoKeyPaths
    case missingGeo3DKeyPaths
    case missingCartesianKeyPaths
    case missingCartesian3DKeyPaths
    case unknownSpatialType(String)
}

extension SpatialMacroDiagnostic: DiagnosticMessage {
    var message: String {
        switch self {
        case .notAppliedToProperty:
            return "@Spatial can only be applied to properties"

        case .missingTypeParameter:
            return """
            @Spatial requires 'type:' parameter with KeyPaths

            Example:
            @Spatial(
                type: .geo(
                    latitude: \\.location.latitude,
                    longitude: \\.location.longitude
                )
            )
            """

        case .invalidTypeFormat:
            return """
            Invalid 'type:' format. Expected: .geo(latitude:longitude:), .geo3D(...), etc.
            """

        case .missingKeyPaths:
            return "Missing KeyPath arguments in type parameter"

        case .missingGeoKeyPaths:
            return """
            .geo requires 'latitude:' and 'longitude:' KeyPaths

            Example:
            type: .geo(
                latitude: \\.location.latitude,
                longitude: \\.location.longitude
            )
            """

        case .missingGeo3DKeyPaths:
            return """
            .geo3D requires 'latitude:', 'longitude:', and 'altitude:' KeyPaths

            Example:
            type: .geo3D(
                latitude: \\.position.lat,
                longitude: \\.position.lon,
                altitude: \\.position.height
            )
            """

        case .missingCartesianKeyPaths:
            return """
            .cartesian requires 'x:' and 'y:' KeyPaths

            Example:
            type: .cartesian(
                x: \\.coords.x,
                y: \\.coords.y
            )
            """

        case .missingCartesian3DKeyPaths:
            return """
            .cartesian3D requires 'x:', 'y:', and 'z:' KeyPaths

            Example:
            type: .cartesian3D(
                x: \\.point.x,
                y: \\.point.y,
                z: \\.point.z
            )
            """

        case .unknownSpatialType(let typeName):
            return """
            Unknown spatial type: '\(typeName)'

            Valid types: .geo, .geo3D, .cartesian, .cartesian3D
            """
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "FDBRecordLayerMacros", id: "SpatialMacro")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
```

### 0.3 RecordableMacroでのIndexDefinition生成

**実装ファイル**: `Sources/FDBRecordLayerMacros/RecordableMacro.swift`

```swift
func collectSpatialIndexes(from members: MemberBlockItemListSyntax) -> [DeclSyntax] {
    var spatialIndexes: [DeclSyntax] = []

    for member in members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            continue
        }

        let propertyName = pattern.identifier.text

        // @Spatial属性を探す
        for attribute in varDecl.attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                  attr.attributeName.trimmedDescription == "Spatial" else {
                continue
            }

            // type: .geo(latitude: \.x, longitude: \.y) を解析
            guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                  let typeArg = arguments.first(where: { $0.label?.text == "type" }),
                  let functionCall = typeArg.expression.as(FunctionCallExprSyntax.self),
                  let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) else {
                continue
            }

            let typeName = memberAccess.declName.baseName.text
            let keyPathArgs = functionCall.arguments

            // IndexDefinitionを生成
            let indexDef = generateSpatialIndexDefinition(
                typeName: typeName,
                keyPathArgs: keyPathArgs,
                propertyName: propertyName
            )

            spatialIndexes.append(indexDef)
        }
    }

    return spatialIndexes
}

private func generateSpatialIndexDefinition(
    typeName: String,
    keyPathArgs: LabeledExprListSyntax?,
    propertyName: String
) -> DeclSyntax {

    guard let args = keyPathArgs else {
        fatalError("Missing KeyPath arguments")
    }

    switch typeName {
    case "geo":
        let latKeyPath = extractKeyPathString(from: args, label: "latitude")
        let lonKeyPath = extractKeyPathString(from: args, label: "longitude")

        return """
        IndexDefinition(
            name: "\(recordName)_\(propertyName)_spatial",
            recordType: "\(recordName)",
            fields: ["\(propertyName)"],
            unique: false,
            indexType: .spatial(SpatialIndexOptions(
                type: .geo(
                    latitude: \\\(recordName).\(latKeyPath),
                    longitude: \\\(recordName).\(lonKeyPath)
                )
            ))
        )
        """

    case "geo3D":
        let latKeyPath = extractKeyPathString(from: args, label: "latitude")
        let lonKeyPath = extractKeyPathString(from: args, label: "longitude")
        let altKeyPath = extractKeyPathString(from: args, label: "altitude")

        return """
        IndexDefinition(
            name: "\(recordName)_\(propertyName)_spatial",
            recordType: "\(recordName)",
            fields: ["\(propertyName)"],
            unique: false,
            indexType: .spatial(SpatialIndexOptions(
                type: .geo3D(
                    latitude: \\\(recordName).\(latKeyPath),
                    longitude: \\\(recordName).\(lonKeyPath),
                    altitude: \\\(recordName).\(altKeyPath)
                ),
                altitudeRange: 0...10000  // TODO: パラメータ化
            ))
        )
        """

    case "cartesian":
        let xKeyPath = extractKeyPathString(from: args, label: "x")
        let yKeyPath = extractKeyPathString(from: args, label: "y")

        return """
        IndexDefinition(
            name: "\(recordName)_\(propertyName)_spatial",
            recordType: "\(recordName)",
            fields: ["\(propertyName)"],
            unique: false,
            indexType: .spatial(SpatialIndexOptions(
                type: .cartesian(
                    x: \\\(recordName).\(xKeyPath),
                    y: \\\(recordName).\(yKeyPath)
                )
            ))
        )
        """

    case "cartesian3D":
        let xKeyPath = extractKeyPathString(from: args, label: "x")
        let yKeyPath = extractKeyPathString(from: args, label: "y")
        let zKeyPath = extractKeyPathString(from: args, label: "z")

        return """
        IndexDefinition(
            name: "\(recordName)_\(propertyName)_spatial",
            recordType: "\(recordName)",
            fields: ["\(propertyName)"],
            unique: false,
            indexType: .spatial(SpatialIndexOptions(
                type: .cartesian3D(
                    x: \\\(recordName).\(xKeyPath),
                    y: \\\(recordName).\(yKeyPath),
                    z: \\\(recordName).\(zKeyPath)
                )
            ))
        )
        """

    default:
        fatalError("Unknown spatial type: \(typeName)")
    }
}

private func extractKeyPathString(from args: LabeledExprListSyntax, label: String) -> String {
    guard let arg = args.first(where: { $0.label?.text == label }),
          let keyPathExpr = arg.expression.as(KeyPathExprSyntax.self) else {
        fatalError("Missing KeyPath for label: \(label)")
    }

    // \.location.latitude → "location.latitude"
    return keyPathExpr.components.map { component in
        if let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
            return property.declName.baseName.text
        }
        return ""
    }.joined(separator: ".")
}
```

---

## Phase 1: Geohash + Z-order Curve + 動的精度調整（5-7日）

### 1.1 Geohashエンコーディング

**目的**: 緯度経度を1次元のソート可能な文字列に変換

**実装ファイル**: `Sources/FDBRecordLayer/Spatial/Geohash.swift`

**API設計**:
```swift
public struct Geohash: Sendable {
    /// Encode geographic coordinates to geohash string
    /// - Parameters:
    ///   - latitude: Latitude in degrees [-90, 90]
    ///   - longitude: Longitude in degrees [-180, 180]
    ///   - precision: Number of characters (4-12, default: 12)
    /// - Returns: Geohash string (e.g., "xn76urx6")
    public static func encode(
        latitude: Double,
        longitude: Double,
        precision: Int = 12
    ) -> String

    /// Decode geohash string to bounding box
    /// - Parameter geohash: Geohash string
    /// - Returns: (minLat, maxLat, minLon, maxLon)
    public static func decode(_ geohash: String) -> (Double, Double, Double, Double)

    /// Get neighboring geohashes (8 directions)
    public static func neighbors(_ geohash: String) -> [String]

    /// Get all geohash prefixes covering a bounding box
    /// - Parameters:
    ///   - minLat, maxLat, minLon, maxLon: Bounding box coordinates
    ///   - precision: Target precision
    /// - Returns: Array of geohash prefixes (最大1000個、超過時は自動的に精度を下げる)
    ///
    /// **エッジケース処理**:
    /// - **日付変更線**: minLon > maxLon の場合、2つの境界ボックスに分割
    /// - **極地**: 緯度が±89度を超える場合、精度を自動的に下げる
    /// - **細長い境界ボックス**: アスペクト比10:1以上の場合、分割して処理
    /// - **プレフィックス数上限**: 1000個を超えた場合、精度を1段階下げて再試行
    public static func coveringGeohashes(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        precision: Int
    ) -> [String]

    /// Calculate optimal geohash precision for bounding box size
    /// - Parameter boundingBoxSizeKm: Bounding box diagonal length in km
    /// - Returns: Optimal precision (4-12)
    public static func optimalPrecision(boundingBoxSizeKm: Double) -> Int

    /// Calculate bounding box diagonal length in km
    public static func boundingBoxSizeKm(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double
    ) -> Double
}
```

**精度テーブル**:
```swift
// Geohash精度 vs 誤差範囲（実測値ベース）
public enum GeohashPrecision {
    case region      // 4文字: ±20km
    case city        // 5文字: ±2.4km
    case neighborhood // 7文字: ±76m
    case street      // 9文字: ±2.4m
    case building    // 10文字: ±60cm
    case precise     // 12文字: ±0.6m (デフォルト)
}
```

**注意**: Geohash 12文字の精度は理論上±0.6-1.8cmですが、実際は丸め誤差により±0.6m程度です。

**動的精度調整の実装**:
```swift
public static func optimalPrecision(boundingBoxSizeKm: Double) -> Int {
    switch boundingBoxSizeKm {
    case 0..<0.001: return 12  // <1m: ±0.6m
    case 0.001..<0.01: return 11  // <10m: ±7.4cm
    case 0.01..<0.1: return 10  // <100m: ±60cm
    case 0.1..<1: return 9  // <1km: ±2.4m
    case 1..<10: return 8  // <10km: ±19m
    case 10..<50: return 7  // <50km: ±76m
    case 50..<100: return 6  // <100km: ±610m
    default: return 5  // >=100km: ±2.4km
    }
}
```

### 1.2 Z-order Curve (Morton Code)

**実装ファイル**: `Sources/FDBRecordLayer/Spatial/MortonCode.swift`

**API設計**:
```swift
public struct MortonCode: Sendable {
    /// Encode 2D coordinates to Morton code
    public static func encode2D(x: Double, y: Double) -> UInt64

    /// Encode 3D coordinates to Morton code
    public static func encode3D(x: Double, y: Double, z: Double) -> UInt64

    /// Decode Morton code to 2D coordinates
    public static func decode2D(_ code: UInt64) -> (x: Double, y: Double)

    /// Decode Morton code to 3D coordinates
    public static func decode3D(_ code: UInt64) -> (x: Double, y: Double, z: Double)
}
```

---

## Phase 2: SpatialIndexMaintainer（KeyPath対応）（4-6日）

### 2.1 SpatialIndexMaintainer

**実装ファイル**: `Sources/FDBRecordLayer/Index/SpatialIndexMaintainer.swift`

**KeyPathベースの値抽出**:
```swift
public final class SpatialIndexMaintainer<Record: Sendable>: IndexMaintainer, Sendable {
    private let index: Index
    private let subspace: Subspace
    private let options: SpatialIndexOptions

    public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // 1. 古いインデックスエントリを削除
        if let old = oldRecord {
            let spatialKey = try buildSpatialKey(record: old, recordAccess: recordAccess)
            transaction.clear(key: spatialKey)
        }

        // 2. 新しいインデックスエントリを追加
        if let new = newRecord {
            let spatialKey = try buildSpatialKey(record: new, recordAccess: recordAccess)
            let primaryKey = recordAccess.extractPrimaryKey(from: new)
            transaction.setValue(primaryKey.pack(), for: spatialKey)
        }
    }

    private func buildSpatialKey(
        record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> FDB.Bytes {
        let spatialType = options.type
        let primaryKey = recordAccess.extractPrimaryKey(from: record)

        switch spatialType {
        case .geo(let latKeyPath, let lonKeyPath):
            // ✅ KeyPathから直接値を抽出
            let lat = record[keyPath: latKeyPath as! KeyPath<Record, Double>]
            let lon = record[keyPath: lonKeyPath as! KeyPath<Record, Double>]

            // Geohashエンコード
            let geohash = Geohash.encode(latitude: lat, longitude: lon, precision: 12)
            return subspace.pack(Tuple(geohash, primaryKey))

        case .geo3D(let latKeyPath, let lonKeyPath, let altKeyPath):
            let lat = record[keyPath: latKeyPath as! KeyPath<Record, Double>]
            let lon = record[keyPath: lonKeyPath as! KeyPath<Record, Double>]
            let alt = record[keyPath: altKeyPath as! KeyPath<Record, Double>]

            // 正規化
            let normLat = (lat + 90.0) / 180.0
            let normLon = (lon + 180.0) / 360.0
            let normAlt = (alt - options.altitudeRange!.lowerBound) /
                         (options.altitudeRange!.upperBound - options.altitudeRange!.lowerBound)

            // Morton codeエンコード (3D)
            let morton = MortonCode.encode3D(x: normLon, y: normLat, z: normAlt)
            return subspace.pack(Tuple(Int64(bitPattern: morton), primaryKey))

        case .cartesian(let xKeyPath, let yKeyPath):
            let x = record[keyPath: xKeyPath as! KeyPath<Record, Double>]
            let y = record[keyPath: yKeyPath as! KeyPath<Record, Double>]

            let morton = MortonCode.encode2D(x: x, y: y)
            return subspace.pack(Tuple(Int64(bitPattern: morton), primaryKey))

        case .cartesian3D(let xKeyPath, let yKeyPath, let zKeyPath):
            let x = record[keyPath: xKeyPath as! KeyPath<Record, Double>]
            let y = record[keyPath: yKeyPath as! KeyPath<Record, Double>]
            let z = record[keyPath: zKeyPath as! KeyPath<Record, Double>]

            let morton = MortonCode.encode3D(x: x, y: y, z: z)
            return subspace.pack(Tuple(Int64(bitPattern: morton), primaryKey))
        }
    }
}
```

---

## Phase 3: 地理クエリAPI + ストリーミング（4-6日）

### 3.1 QueryBuilder拡張

**ファイル**: `Sources/FDBRecordLayer/Query/QueryBuilder.swift`

```swift
extension QueryBuilder {
    /// Within bounding box query (geo)
    public func withinBoundingBox(
        lat latKeyPath: KeyPath<T, Double>,
        lon lonKeyPath: KeyPath<T, Double>,
        boundingBox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    ) -> Self {
        let latField = T.fieldName(for: latKeyPath)
        let lonField = T.fieldName(for: lonKeyPath)

        let spatialFilter = SpatialBoundingBoxQueryComponent<T>(
            latField: latField,
            lonField: lonField,
            minLat: boundingBox.minLat,
            maxLat: boundingBox.maxLat,
            minLon: boundingBox.minLon,
            maxLon: boundingBox.maxLon
        )

        filters.append(spatialFilter)
        return self
    }

    /// Near point query (radius search)
    public func near(
        lat latKeyPath: KeyPath<T, Double>,
        lon lonKeyPath: KeyPath<T, Double>,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) -> Self {
        // 実装は withinBoundingBox と同様
        // ...
    }
}
```

### 3.2 SpatialIndexScanPlan（ストリーミング対応）

**ファイル**: `Sources/FDBRecordLayer/Query/SpatialIndexScanPlan.swift`

**✅ 単一トランザクション + ストリーミングカーソル**:
```swift
public struct SpatialIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    private let index: Index
    private let subspace: Subspace
    private let geohashPrefixes: [String]
    private let filter: (Record) -> Bool

    public func execute(
        database: any DatabaseProtocol,
        recordAccess: any RecordAccess<Record>,
        schema: Schema
    ) async throws -> AnyTypedRecordCursor<Record> {

        // ✅ ストリーミングカーソル（メモリ効率的）
        let stream = AsyncStream<Record> { continuation in
            Task {
                try await database.withTransaction { transaction in
                    for prefix in geohashPrefixes {
                        let beginKey = subspace.pack(Tuple(prefix))
                        var endKey = subspace.pack(Tuple(prefix))
                        endKey.append(0xFF)

                        let sequence = transaction.getRange(
                            beginSelector: .firstGreaterOrEqual(beginKey),
                            endSelector: .firstGreaterOrEqual(endKey),
                            snapshot: true
                        )

                        // ストリーミング処理（メモリに全キーを保持しない）
                        for try await (key, _) in sequence {
                            let tuple = try subspace.unpack(key)
                            let primaryKeyTuple = Tuple([tuple[1]])

                            if let record = try await loadRecord(
                                primaryKey: primaryKeyTuple,
                                transaction: transaction,
                                recordAccess: recordAccess,
                                schema: schema
                            ), filter(record) {
                                continuation.yield(record)
                            }
                        }
                    }
                    continuation.finish()
                }
            }
        }

        return AnyTypedRecordCursor(AsyncStreamCursor(stream: stream))
    }
}
```

### 3.3 TypedRecordQueryPlanner（動的精度調整統合）

**ファイル**: `Sources/FDBRecordLayer/Query/TypedRecordQueryPlanner.swift`

```swift
private func planSpatialBoundingBox(
    _ filter: SpatialBoundingBoxQueryComponent<Record>
) async throws -> (any TypedQueryPlan<Record>)? {

    guard let spatialIndex = applicableIndexes.first(where: { index in
        if case .spatial = index.type {
            return indexFieldsMatch(index, latField: filter.latField, lonField: filter.lonField)
        }
        return false
    }) else {
        return nil
    }

    // ✅ 動的精度調整
    let boxSizeKm = Geohash.boundingBoxSizeKm(
        minLat: filter.minLat, maxLat: filter.maxLat,
        minLon: filter.minLon, maxLon: filter.maxLon
    )
    let precision = Geohash.optimalPrecision(boundingBoxSizeKm: boxSizeKm)

    let geohashPrefixes = Geohash.coveringGeohashes(
        minLat: filter.minLat,
        maxLat: filter.maxLat,
        minLon: filter.minLon,
        maxLon: filter.maxLon,
        precision: precision
    )

    // 精密フィルタ関数
    let preciseFilter: (Record) -> Bool = { record in
        // 実装...
    }

    return SpatialIndexScanPlan(
        index: spatialIndex,
        subspace: indexSubspace(for: spatialIndex),
        geohashPrefixes: geohashPrefixes,
        filter: preciseFilter
    )
}
```

---

## Phase 4: 最適化 + プロパティベーステスト（3-4日）

### 4.1 テスト戦略

**ユニットテスト**: `Tests/FDBRecordLayerTests/Spatial/`

```swift
// GeohashTests.swift
@Test("Geohash encoding round-trip")
func testGeohashRoundTrip() {
    let lat = 35.6895
    let lon = 139.6917
    let precision = 12

    let geohash = Geohash.encode(latitude: lat, longitude: lon, precision: precision)
    let (minLat, maxLat, minLon, maxLon) = Geohash.decode(geohash)

    // ✅ 境界ボックスベースの検証（文字列比較ではない）
    #expect(lat >= minLat && lat <= maxLat)
    #expect(lon >= minLon && lon <= maxLon)

    // 境界ボックスのサイズが期待される精度範囲内
    let boxSizeKm = Geohash.boundingBoxSizeKm(
        minLat: minLat, maxLat: maxLat,
        minLon: minLon, maxLon: maxLon
    )
    #expect(boxSizeKm < 0.001)  // precision 12: ~0.6m
}

@Test("Geohash properties")
func testGeohashProperties() {
    // プロパティベースドテスト
    for _ in 0..<100 {
        let lat = Double.random(in: -90...90)
        let lon = Double.random(in: -180...180)
        let precision = Int.random(in: 5...12)

        let geohash = Geohash.encode(latitude: lat, longitude: lon, precision: precision)
        let (minLat, maxLat, minLon, maxLon) = Geohash.decode(geohash)

        // Property 1: エンコード→デコードで元の座標が境界ボックス内
        #expect(lat >= minLat && lat <= maxLat)
        #expect(lon >= minLon && lon <= maxLon)
    }
}

// SpatialIndexEndToEndTests.swift
@Test("Spatial index with nested KeyPaths")
func testNestedKeyPathSpatialIndex() async throws {
    let (database, schema) = try await setupTestDatabase()

    @Recordable
    struct Restaurant {
        #PrimaryKey<Restaurant>([\.id])

        var id: Int64
        var name: String

        @Spatial(
            type: .geo(
                latitude: \.address.location.latitude,
                longitude: \.address.location.longitude
            )
        )
        var address: Address
    }

    struct Address: Codable, Sendable {
        var street: String
        var location: Location
    }

    struct Location: Codable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    let store = try await Restaurant.store(database: database, schema: schema)

    // レストランを保存
    let restaurant = Restaurant(
        id: 1,
        name: "Sushi Bar",
        address: Address(
            street: "Ginza 1-1-1",
            location: Location(latitude: 35.6762, longitude: 139.7653)
        )
    )
    try await store.save(restaurant)

    // Bounding boxクエリ
    let results = try await store.query()
        .withinBoundingBox(
            lat: \.address.location.latitude,
            lon: \.address.location.longitude,
            boundingBox: (minLat: 35.6, maxLat: 35.7, minLon: 139.7, maxLon: 139.8)
        )
        .execute()

    #expect(results.count == 1)
    #expect(results.first?.name == "Sushi Bar")
}

@Test("Dateline wrapping query")
func testDatelineWrapping() async throws {
    // 日付変更線をまたぐ境界ボックス: [東京 → ハワイ]
    let results = try await store.query()
        .withinBoundingBox(
            lat: \.location.latitude,
            lon: \.location.longitude,
            boundingBox: (minLat: 20, maxLat: 40, minLon: 130, maxLon: -150)
        )
        .execute()
    // ...
}
```

---

## 使用例

### 例1: ネスト構造のレストラン検索

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.id])

    var id: Int64
    var name: String
    var cuisine: String

    @Spatial(
        type: .geo(
            latitude: \.address.location.latitude,
            longitude: \.address.location.longitude
        )
    )
    var address: Address
}

struct Address: Codable, Sendable {
    var street: String
    var city: String
    var location: Location
}

struct Location: Codable, Sendable {
    var latitude: Double
    var longitude: Double
}

// 使用例: 銀座周辺のレストランを検索
let restaurants = try await store.query()
    .withinBoundingBox(
        lat: \.address.location.latitude,
        lon: \.address.location.longitude,
        boundingBox: (minLat: 35.67, maxLat: 35.68, minLon: 139.76, maxLon: 139.77)
    )
    .where(\.cuisine, .equals, "Japanese")
    .execute()
```

### 例2: 3Dドローン追跡

```swift
@Recordable
struct Drone {
    #PrimaryKey<Drone>([\.id])

    var id: Int64
    var model: String

    @Spatial(
        type: .geo3D(
            latitude: \.position.lat,
            longitude: \.position.lon,
            altitude: \.position.height
        )
    )
    var position: Position
}

struct Position: Codable, Sendable {
    var lat: Double
    var lon: Double
    var height: Double  // メートル
}

// 使用例: 特定高度範囲のドローンを検索
let drones = try await store.query()
    .withinBoundingBox(
        lat: \.position.lat,
        lon: \.position.lon,
        boundingBox: (minLat: 35.6, maxLat: 35.7, minLon: 139.7, maxLon: 139.8)
    )
    .where(\.position.height, .greaterThan, 100)
    .where(\.position.height, .lessThan, 500)
    .execute()
```

### 例3: ゲームワールドのエンティティ検索

```swift
@Recordable
struct GameEntity {
    #PrimaryKey<GameEntity>([\.id])

    var id: Int64
    var type: String

    @Spatial(
        type: .cartesian(
            x: \.coords.x,
            y: \.coords.y
        )
    )
    var coords: Coordinates
}

struct Coordinates: Codable, Sendable {
    var x: Double
    var y: Double
}

// 使用例: プレイヤー周辺のエンティティを検索
let nearbyEntities = try await store.query()
    .withinBoundingBox(
        lat: \.coords.x,  // Cartesianでも同じAPI
        lon: \.coords.y,
        boundingBox: (minLat: playerX - 100, maxLat: playerX + 100,
                     minLon: playerY - 100, maxLon: playerY + 100)
    )
    .execute()
```

### 例4: フラット構造（異なるフィールド名）

```swift
@Recordable
struct POI {
    #PrimaryKey<POI>([\.id])

    var id: Int64
    var name: String

    @Spatial(
        type: .geo(
            latitude: \.lat,     // ← フィールド名が異なる
            longitude: \.lng     // ← フィールド名が異なる
        )
    )
    var lat: Double
    var lng: Double
}
```

---

## 実装スケジュール

| Phase | タスク | 推定工数 | 優先度 |
|-------|--------|---------|--------|
| **Phase 0** | 新設計への移行（SpatialType, マクロ更新） | 2-3日 | 🔴 最優先 |
| **Phase 1** | Geohash + Morton Code + 動的精度調整 | 5-7日 | 🔴 高 |
| **Phase 2** | SpatialIndexMaintainer (KeyPath対応) | 4-6日 | 🔴 高 |
| **Phase 3** | 地理クエリAPI + ストリーミング | 4-6日 | 🟡 中 |
| **Phase 4** | 最適化 + プロパティベーステスト | 3-4日 | 🟢 低 |

**合計推定工数**: **18-26日**

---

## 依存関係とリスク

### 依存関係

| 依存先 | 影響 |
|--------|------|
| **KeyPath system** | 新設計の中核（Swift標準機能） |
| **IndexManager** | SpatialIndexMaintainerの登録 |
| **TypedRecordQueryPlanner** | Spatial query planの生成 |
| **@Recordable macro** | Spatial fieldsのメタデータ生成 |

### リスク

| リスク | 確率 | 影響 | 対策 |
|--------|------|------|------|
| **KeyPath型消去の問題** | 中 | 高 | AnyKeyPathからのダウンキャスト検証を強化 |
| **日付変更線バグ** | 中 | 高 | E2Eテストで検証（東京→ハワイ） |
| **極地パフォーマンス** | 低 | 中 | 精度を動的に下げる |
| **プレフィックス爆発** | 中 | 高 | 上限1000に制限、自動精度調整 |

---

## 参考資料

### 既存実装

1. **Swift版 (既存)**:
   - `@Spatial` macro (SpatialMacro.swift)
   - `GeoCoordinate` (GeoCoordinate.swift)
   - `SpatialRepresentable` protocol

2. **Java FoundationDB Record Layer**:
   - `GeohashFunctionKeyExpression.java`
   - `SpatialIndexMaintainer.java`

### アルゴリズム

1. **Geohash**:
   - [Geohash Wikipedia](https://en.wikipedia.org/wiki/Geohash)
   - Precision table: https://www.movable-type.co.uk/scripts/geohash.html

2. **Z-order curve (Morton code)**:
   - [Z-order curve Wikipedia](https://en.wikipedia.org/wiki/Z-order_curve)
   - Bit interleaving algorithms

3. **Haversine formula**:
   - [Haversine formula](https://en.wikipedia.org/wiki/Haversine_formula)

---

**Last Updated**: 2025-01-16
**Status**: Phase 0設計完了、Phase 1-4実装待ち
**Completion**: 10% (基礎実装完了、新設計への移行が必要)
