# Swift Query Features Design

> **Design Philosophy**: Leverage Swift language features for intuitive, type-safe APIs that feel natural to Swift developers, not Java ports.

## Overview

This document outlines the design for 5 missing query features in the Swift Record Layer:

1. **TEXT Index** - Full-text search with natural language queries
2. **SPATIAL Index** - Geographic queries with SwiftUI-like coordinate types
3. **Distinct Plan** - Type-safe duplicate removal with KeyPath selection
4. **First N Plan** - Optimized early termination with Result Builder DSL
5. **FlatMap Plan** - Nested collection flattening with Swift Sequence API

**Note**: IN Join Plan already exists as `TypedInJoinPlan` (TypedQueryPlan.swift:236-359)

---

## 1. TEXT Index: Full-Text Search

### Design Goals

- **Natural Language**: Intuitive query syntax for text search
- **Type Safety**: Compile-time validation of searchable fields
- **Performance**: Tokenization and inverted index storage
- **Extensibility**: Pluggable tokenizers and analyzers

### Swift-Idiomatic Features

1. **Result Builder DSL** for query construction
2. **KeyPath-based** field selection
3. **OptionSet** for search options
4. **Async/Await** for query execution

### Index Definition

```swift
// IndexType extension
extension IndexType {
    case text       // Full-text search index
}

// Index factory method
extension Index {
    /// Creates a full-text search index
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - on: Text field to index
    ///   - tokenizer: Tokenization strategy (default: .standard)
    ///   - analyzer: Text analyzer (default: .english)
    ///   - recordTypes: Optional record types
    /// - Returns: TEXT index instance
    public static func text(
        named name: String,
        on expression: KeyExpression,
        tokenizer: TextTokenizer = .standard,
        analyzer: TextAnalyzer = .english,
        recordTypes: Set<String>? = nil
    ) -> Index {
        Index(
            name: name,
            type: .text,
            rootExpression: expression,
            recordTypes: recordTypes,
            options: IndexOptions(
                textTokenizer: tokenizer,
                textAnalyzer: analyzer
            )
        )
    }
}
```

### IndexOptions Extension

```swift
extension IndexOptions {
    /// Text tokenizer strategy
    public var textTokenizer: TextTokenizer?

    /// Text analyzer for language processing
    public var textAnalyzer: TextAnalyzer?
}
```

### Tokenizer Design

```swift
/// Text tokenization strategy
public enum TextTokenizer: String, Sendable {
    /// Standard tokenizer (whitespace + punctuation)
    case standard

    /// Whitespace only
    case whitespace

    /// N-gram tokenizer
    case ngram(n: Int = 3)

    /// Edge n-gram (for autocomplete)
    case edgeNgram(minGram: Int = 2, maxGram: Int = 10)
}

/// Text analyzer for language-specific processing
public enum TextAnalyzer: String, Sendable {
    case english
    case japanese       // MeCab/Kuromoji equivalent
    case chinese        // CJK analyzer
    case cjk            // Combined CJK
    case multilingual   // Language detection + appropriate analyzer

    /// Custom analyzer with stemming/stopwords
    case custom(stemmer: Stemmer, stopwords: Set<String>)
}

/// Stemming algorithm
public enum Stemmer: Sendable {
    case porter         // Porter stemmer
    case snowball       // Snowball stemmer
    case none           // No stemming
}
```

### Query API

```swift
// QueryBuilder extension
extension QueryBuilder {
    /// Full-text search on a text field
    ///
    /// **Example**:
    /// ```swift
    /// let results = try await store.query()
    ///     .text(\.description, contains: "machine learning")
    ///     .execute()
    /// ```
    public func text<Value: StringProtocol>(
        _ keyPath: KeyPath<T, Value>,
        contains query: String,
        options: TextSearchOptions = []
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        let filter = TypedTextQueryComponent<T>(
            fieldName: fieldName,
            query: query,
            options: options
        )
        filters.append(filter)
        return self
    }

    /// Full-text search with Result Builder
    public func text<Value: StringProtocol>(
        _ keyPath: KeyPath<T, Value>,
        @TextQueryBuilder _ builder: () -> TextQuery
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        let textQuery = builder()
        let filter = TypedTextQueryComponent<T>(
            fieldName: fieldName,
            textQuery: textQuery
        )
        filters.append(filter)
        return self
    }
}
```

### Text Search Options

```swift
/// Options for text search
public struct TextSearchOptions: OptionSet, Sendable {
    public let rawValue: Int

    /// Case-insensitive search
    public static let caseInsensitive = TextSearchOptions(rawValue: 1 << 0)

    /// Fuzzy matching (Levenshtein distance ≤ 2)
    public static let fuzzy = TextSearchOptions(rawValue: 1 << 1)

    /// Prefix matching (for autocomplete)
    public static let prefix = TextSearchOptions(rawValue: 1 << 2)

    /// Phrase matching (exact word order)
    public static let phrase = TextSearchOptions(rawValue: 1 << 3)

    /// Stemming enabled
    public static let stemming = TextSearchOptions(rawValue: 1 << 4)
}
```

### Result Builder DSL

```swift
/// Result builder for composing text queries
@resultBuilder
public struct TextQueryBuilder {
    public static func buildBlock(_ components: TextQuery...) -> TextQuery {
        .and(components)
    }

    public static func buildEither(first component: TextQuery) -> TextQuery {
        component
    }

    public static func buildEither(second component: TextQuery) -> TextQuery {
        component
    }

    public static func buildOptional(_ component: TextQuery?) -> TextQuery {
        component ?? .matchAll
    }
}

/// Text query components
public enum TextQuery: Sendable {
    /// Match all documents
    case matchAll

    /// Match term
    case term(String)

    /// Match phrase
    case phrase(String)

    /// Prefix match (autocomplete)
    case prefix(String)

    /// Fuzzy match
    case fuzzy(String, maxDistance: Int = 2)

    /// Boolean AND
    case and([TextQuery])

    /// Boolean OR
    case or([TextQuery])

    /// Boolean NOT
    case not(TextQuery)

    /// Proximity search (words within N positions)
    case proximity(String, String, maxDistance: Int)
}

// Convenience operators
extension TextQuery {
    public static func && (lhs: TextQuery, rhs: TextQuery) -> TextQuery {
        .and([lhs, rhs])
    }

    public static func || (lhs: TextQuery, rhs: TextQuery) -> TextQuery {
        .or([lhs, rhs])
    }

    public static prefix func ! (query: TextQuery) -> TextQuery {
        .not(query)
    }
}
```

### Usage Examples

```swift
// Simple text search
let products = try await store.query()
    .text(\.description, contains: "machine learning")
    .execute()

// Fuzzy search for autocomplete
let users = try await store.query()
    .text(\.name, contains: "Alice", options: [.fuzzy, .prefix])
    .execute()

// Complex query with Result Builder
let articles = try await store.query()
    .text(\.content) {
        .phrase("artificial intelligence")
        .or([
            .term("machine"),
            .term("deep"),
            .term("neural")
        ])
        !.term("hype")
    }
    .execute()

// Multi-field search
let documents = try await store.query()
    .text(\.title, contains: "Swift")
    .text(\.body, contains: "concurrency")
    .execute()
```

### Storage Layout

```
TEXT Index Subspace: <app>/<I>/<index_name>
├── <TOKENS>/
│   ├── <token1>/<primaryKey1> = frequency (Int64)
│   ├── <token1>/<primaryKey2> = frequency
│   └── ...
├── <POSITIONS>/
│   ├── <token1>/<primaryKey1> = [position1, position2, ...] (Array<Int>)
│   └── ...
└── <METADATA>/
    ├── total_documents = count (Int64)
    └── token_counts = <token> → document_count (Map)
```

### Index Maintainer

```swift
/// TEXT index maintainer
public final class TextIndexMaintainer<Record: Sendable>: GenericIndexMaintainer<Record> {
    private let tokenizer: TextTokenizer
    private let analyzer: TextAnalyzer

    public init(
        index: Index,
        subspace: Subspace,
        tokenizer: TextTokenizer = .standard,
        analyzer: TextAnalyzer = .english
    ) {
        self.tokenizer = tokenizer
        self.analyzer = analyzer
        super.init(index: index, subspace: subspace)
    }

    override public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old tokens
        if let oldRecord = oldRecord {
            let oldTokens = try extractAndTokenize(oldRecord, recordAccess: recordAccess)
            try await removeTokens(oldTokens, primaryKey: primaryKey, transaction: transaction)
        }

        // Add new tokens
        if let newRecord = newRecord {
            let newTokens = try extractAndTokenize(newRecord, recordAccess: recordAccess)
            try await addTokens(newTokens, primaryKey: primaryKey, transaction: transaction)
        }
    }

    /// Extract text and tokenize
    private func extractAndTokenize(
        _ record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> [(token: String, positions: [Int])] {
        // Extract text field
        let fieldValues = try recordAccess.extractField(
            from: record,
            fieldName: index.rootExpression.fieldName
        )

        guard let text = fieldValues.first as? String else {
            return []
        }

        // Tokenize
        let tokens = tokenize(text, using: tokenizer)

        // Analyze (stem, lowercase, filter stopwords)
        let analyzed = analyze(tokens, using: analyzer)

        return analyzed
    }

    /// Tokenize text
    private func tokenize(
        _ text: String,
        using strategy: TextTokenizer
    ) -> [(token: String, position: Int)] {
        switch strategy {
        case .standard:
            return standardTokenize(text)
        case .whitespace:
            return whitespaceTokenize(text)
        case .ngram(let n):
            return ngramTokenize(text, n: n)
        case .edgeNgram(let minGram, let maxGram):
            return edgeNgramTokenize(text, minGram: minGram, maxGram: maxGram)
        }
    }

    /// Analyze tokens (stemming, lowercasing, stopword removal)
    private func analyze(
        _ tokens: [(token: String, position: Int)],
        using analyzer: TextAnalyzer
    ) -> [(token: String, positions: [Int])] {
        // Group by token
        var tokenMap: [String: [Int]] = [:]

        for (token, position) in tokens {
            let processed = processToken(token, using: analyzer)
            guard !processed.isEmpty else { continue }

            tokenMap[processed, default: []].append(position)
        }

        return tokenMap.map { (token: $0.key, positions: $0.value) }
    }

    /// Process single token
    private func processToken(_ token: String, using analyzer: TextAnalyzer) -> String {
        var result = token.lowercased()

        switch analyzer {
        case .english:
            // Remove English stopwords
            if englishStopwords.contains(result) {
                return ""
            }
            // Apply Porter stemmer
            result = porterStem(result)

        case .japanese:
            // MeCab/Kuromoji tokenization (future implementation)
            break

        case .chinese, .cjk:
            // CJK tokenization (future implementation)
            break

        case .multilingual:
            // Language detection + appropriate processing
            break

        case .custom(let stemmer, let stopwords):
            if stopwords.contains(result) {
                return ""
            }
            switch stemmer {
            case .porter:
                result = porterStem(result)
            case .snowball:
                result = snowballStem(result)
            case .none:
                break
            }
        }

        return result
    }
}

// Standard English stopwords
private let englishStopwords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
    "if", "in", "into", "is", "it", "no", "not", "of", "on", "or",
    "such", "that", "the", "their", "then", "there", "these", "they",
    "this", "to", "was", "will", "with"
]
```

### Query Plan

```swift
/// TEXT index scan plan
public struct TypedTextIndexScanPlan<Record: Sendable>: TypedQueryPlan {
    public let indexName: String
    public let indexSubspace: Subspace
    public let textQuery: TextQuery
    public let primaryKeyLength: Int

    public init(
        indexName: String,
        indexSubspace: Subspace,
        textQuery: TextQuery,
        primaryKeyLength: Int
    ) {
        self.indexName = indexName
        self.indexSubspace = indexSubspace
        self.textQuery = textQuery
        self.primaryKeyLength = primaryKeyLength
    }

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        let transaction = context.getTransaction()

        // Extract tokens from query
        let queryTokens = extractTokens(from: textQuery)

        // Fetch matching documents from inverted index
        var documentScores: [Data: Double] = [:]

        for token in queryTokens {
            let tokenSubspace = indexSubspace.subspace("TOKENS").subspace(token)
            let (beginKey, endKey) = tokenSubspace.range()

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterThan(endKey),
                snapshot: snapshot
            )

            for try await (key, valueBytes) in sequence {
                // Extract primary key
                let tuple = try tokenSubspace.unpack(key)
                let primaryKeyElements = Array(tuple.suffix(primaryKeyLength))
                let primaryKeyTuple = TupleHelpers.toTuple(primaryKeyElements)

                // Decode frequency
                let frequency = valueBytes.withUnsafeBytes { $0.load(as: Int64.self) }

                // TF-IDF scoring (simplified)
                let score = Double(frequency) // TODO: Add IDF component

                let recordKey = subspace.subspace("R").pack(primaryKeyTuple)
                let recordKeyData = Data(recordKey)
                documentScores[recordKeyData, default: 0.0] += score
            }
        }

        // Sort by relevance score
        let sortedDocs = documentScores.sorted { $0.value > $1.value }

        // Fetch records
        let stream = AsyncThrowingStream<Record, Error> { continuation in
            Task {
                do {
                    for (recordKeyData, _) in sortedDocs {
                        let recordKey = [UInt8](recordKeyData)
                        guard let recordBytes = try await transaction.getValue(
                            for: recordKey,
                            snapshot: snapshot
                        ) else {
                            continue
                        }

                        let record = try recordAccess.deserialize(recordBytes)
                        continuation.yield(record)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return AnyTypedRecordCursor(ArrayCursor(sequence: stream))
    }

    /// Extract tokens from text query
    private func extractTokens(from query: TextQuery) -> [String] {
        switch query {
        case .matchAll:
            return []
        case .term(let term):
            return [term.lowercased()]
        case .phrase(let phrase):
            return phrase.lowercased().split(separator: " ").map(String.init)
        case .prefix(let prefix):
            return [prefix.lowercased()]
        case .fuzzy(let term, _):
            return [term.lowercased()] // TODO: Generate variations
        case .and(let queries), .or(let queries):
            return queries.flatMap { extractTokens(from: $0) }
        case .not(let query):
            return extractTokens(from: query)
        case .proximity(let term1, let term2, _):
            return [term1.lowercased(), term2.lowercased()]
        }
    }
}
```

---

## 2. SPATIAL Index: Geographic Queries

### Design Goals

- **SwiftUI-Like**: Use familiar coordinate types (`CLLocationCoordinate2D`)
- **Type Safety**: Compile-time validation of spatial operations
- **Performance**: R-tree or Geohash-based indexing
- **Extensibility**: Support multiple spatial indexing strategies

### Swift-Idiomatic Features

1. **CoreLocation Integration**: `CLLocationCoordinate2D`, `MKCoordinateRegion`
2. **KeyPath-based** field selection
3. **OptionSet** for search options
4. **Swift Measurement API** for distances

### Index Definition

```swift
// IndexType extension
extension IndexType {
    case spatial    // Spatial (geographic) index
}

// Index factory method
extension Index {
    /// Creates a spatial index
    ///
    /// - Parameters:
    ///   - name: Index name
    ///   - on: Coordinate field expression
    ///   - strategy: Indexing strategy (default: .geohash)
    ///   - recordTypes: Optional record types
    /// - Returns: SPATIAL index instance
    public static func spatial(
        named name: String,
        on expression: KeyExpression,
        strategy: SpatialIndexingStrategy = .geohash(precision: 7),
        recordTypes: Set<String>? = nil
    ) -> Index {
        Index(
            name: name,
            type: .spatial,
            rootExpression: expression,
            recordTypes: recordTypes,
            options: IndexOptions(spatialStrategy: strategy)
        )
    }
}
```

### IndexOptions Extension

```swift
extension IndexOptions {
    /// Spatial indexing strategy
    public var spatialStrategy: SpatialIndexingStrategy?
}
```

### Spatial Indexing Strategy

```swift
/// Spatial indexing strategy
public enum SpatialIndexingStrategy: Sendable {
    /// Geohash-based indexing
    /// - precision: Geohash precision (1-12 characters)
    ///   - 5: ~5km precision
    ///   - 6: ~1.2km precision
    ///   - 7: ~150m precision
    ///   - 8: ~38m precision
    case geohash(precision: Int)

    /// Quad-tree based indexing
    case quadTree(maxDepth: Int = 20)

    /// S2 geometry based indexing (Google's S2)
    case s2(level: Int = 15)
}
```

### Coordinate Types

```swift
import CoreLocation

/// Coordinate protocol for spatial queries
public protocol Coordinate: Sendable {
    var latitude: Double { get }
    var longitude: Double { get }
}

extension CLLocationCoordinate2D: Coordinate {}

/// Bounding box for spatial queries
public struct BoundingBox: Sendable {
    public let minLat: Double
    public let maxLat: Double
    public let minLon: Double
    public let maxLon: Double

    public init(
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double
    ) {
        self.minLat = minLatitude
        self.maxLat = maxLatitude
        self.minLon = minLongitude
        self.maxLon = maxLongitude
    }

    /// Create bounding box from region
    public init(region: MKCoordinateRegion) {
        self.init(
            minLatitude: region.center.latitude - region.span.latitudeDelta / 2,
            maxLatitude: region.center.latitude + region.span.latitudeDelta / 2,
            minLongitude: region.center.longitude - region.span.longitudeDelta / 2,
            maxLongitude: region.center.longitude + region.span.longitudeDelta / 2
        )
    }

    /// Create bounding box from center + radius
    public init(center: CLLocationCoordinate2D, radius: Measurement<UnitLength>) {
        let radiusInMeters = radius.converted(to: .meters).value
        let latDelta = radiusInMeters / 111_320.0 // meters per degree latitude
        let lonDelta = radiusInMeters / (111_320.0 * cos(center.latitude * .pi / 180))

        self.init(
            minLatitude: center.latitude - latDelta,
            maxLatitude: center.latitude + latDelta,
            minLongitude: center.longitude - lonDelta,
            maxLongitude: center.longitude + lonDelta
        )
    }
}
```

### Query API

```swift
// QueryBuilder extension
extension QueryBuilder {
    /// Spatial query within bounding box
    ///
    /// **Example**:
    /// ```swift
    /// let locations = try await store.query()
    ///     .spatial(\.coordinate, within: boundingBox)
    ///     .execute()
    /// ```
    public func spatial(
        _ keyPath: KeyPath<T, CLLocationCoordinate2D>,
        within box: BoundingBox
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        let filter = TypedSpatialQueryComponent<T>(
            fieldName: fieldName,
            predicate: .withinBox(box)
        )
        filters.append(filter)
        return self
    }

    /// Spatial query within radius
    public func spatial(
        _ keyPath: KeyPath<T, CLLocationCoordinate2D>,
        near center: CLLocationCoordinate2D,
        radius: Measurement<UnitLength>
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        let filter = TypedSpatialQueryComponent<T>(
            fieldName: fieldName,
            predicate: .withinRadius(center: center, radius: radius)
        )
        filters.append(filter)
        return self
    }
}
```

### Spatial Query Predicate

```swift
/// Spatial query predicate
public enum SpatialPredicate: Sendable {
    /// Points within bounding box
    case withinBox(BoundingBox)

    /// Points within radius of center
    case withinRadius(center: CLLocationCoordinate2D, radius: Measurement<UnitLength>)

    /// Points within polygon
    case withinPolygon([CLLocationCoordinate2D])
}
```

### Usage Examples

```swift
// Find nearby restaurants within 1km
let restaurants = try await store.query()
    .spatial(\.location, near: userLocation, radius: Measurement(value: 1, unit: .kilometers))
    .where(\.category == "restaurant")
    .orderBy(\.rating, .descending)
    .execute()

// Find stores in Tokyo
let tokyoBounds = BoundingBox(
    minLatitude: 35.5,
    maxLatitude: 35.8,
    minLongitude: 139.5,
    maxLongitude: 139.9
)
let stores = try await store.query()
    .spatial(\.location, within: tokyoBounds)
    .execute()

// Region-based search
let region = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
)
let pois = try await store.query()
    .spatial(\.coordinate, within: BoundingBox(region: region))
    .execute()
```

### Storage Layout

```
SPATIAL Index Subspace: <app>/<I>/<index_name>
├── <GEOHASH>/
│   ├── <geohash_prefix>/
│   │   ├── <full_geohash>/<primaryKey1> = (lat, lon) encoded
│   │   ├── <full_geohash>/<primaryKey2> = (lat, lon) encoded
│   │   └── ...
│   └── ...
└── <METADATA>/
    └── bounds = (minLat, maxLat, minLon, maxLon)
```

### Index Maintainer

```swift
/// SPATIAL index maintainer
public final class SpatialIndexMaintainer<Record: Sendable>: GenericIndexMaintainer<Record> {
    private let strategy: SpatialIndexingStrategy

    public init(
        index: Index,
        subspace: Subspace,
        strategy: SpatialIndexingStrategy = .geohash(precision: 7)
    ) {
        self.strategy = strategy
        super.init(index: index, subspace: subspace)
    }

    override public func updateIndex(
        oldRecord: Record?,
        newRecord: Record?,
        primaryKey: Tuple,
        recordAccess: any RecordAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws {
        // Remove old coordinate
        if let oldRecord = oldRecord {
            let oldCoord = try extractCoordinate(oldRecord, recordAccess: recordAccess)
            try await removeCoordinate(oldCoord, primaryKey: primaryKey, transaction: transaction)
        }

        // Add new coordinate
        if let newRecord = newRecord {
            let newCoord = try extractCoordinate(newRecord, recordAccess: recordAccess)
            try await addCoordinate(newCoord, primaryKey: primaryKey, transaction: transaction)
        }
    }

    /// Extract coordinate from record
    private func extractCoordinate(
        _ record: Record,
        recordAccess: any RecordAccess<Record>
    ) throws -> CLLocationCoordinate2D {
        let fieldValues = try recordAccess.extractField(
            from: record,
            fieldName: index.rootExpression.fieldName
        )

        // Expect (latitude, longitude) tuple
        guard fieldValues.count == 2,
              let lat = fieldValues[0] as? Double,
              let lon = fieldValues[1] as? Double else {
            throw RecordLayerError.invalidCoordinate
        }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Add coordinate to index
    private func addCoordinate(
        _ coord: CLLocationCoordinate2D,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let geohash = encodeGeohash(coord, precision: geohashPrecision)

        // Store with geohash as prefix
        let geohashSubspace = subspace.subspace("GEOHASH").subspace(geohash)
        let key = geohashSubspace.pack(primaryKey)

        // Encode (lat, lon) as value
        var bytes = [UInt8]()
        withUnsafeBytes(of: coord.latitude) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: coord.longitude) { bytes.append(contentsOf: $0) }

        transaction.set(key: key, value: bytes)
    }

    /// Encode coordinate to geohash
    private func encodeGeohash(
        _ coord: CLLocationCoordinate2D,
        precision: Int
    ) -> String {
        // Base32 alphabet
        let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

        var geohash = ""
        var minLat = -90.0, maxLat = 90.0
        var minLon = -180.0, maxLon = 180.0
        var bits = 0
        var bit = 0
        var ch = 0

        while geohash.count < precision {
            if bits % 2 == 0 {
                // Longitude
                let mid = (minLon + maxLon) / 2
                if coord.longitude > mid {
                    ch |= (1 << (4 - bit))
                    minLon = mid
                } else {
                    maxLon = mid
                }
            } else {
                // Latitude
                let mid = (minLat + maxLat) / 2
                if coord.latitude > mid {
                    ch |= (1 << (4 - bit))
                    minLat = mid
                } else {
                    maxLat = mid
                }
            }

            bits += 1
            bit += 1

            if bit == 5 {
                geohash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }

        return geohash
    }

    private var geohashPrecision: Int {
        switch strategy {
        case .geohash(let precision):
            return precision
        default:
            return 7
        }
    }
}
```

---

## 3. Distinct Plan: Type-Safe Duplicate Removal

### Design Goals

- **Type Safety**: Compile-time validation of distinct fields
- **KeyPath-based**: Select fields for uniqueness check
- **Performance**: Set-based or streaming deduplication
- **Memory Efficient**: Streaming when possible

### Swift-Idiomatic Features

1. **KeyPath selection** of distinct fields
2. **Generic constraints** for Hashable fields
3. **Streaming API** with minimal memory usage

### Query API

```swift
// IMPORTANT: These properties must be added to QueryBuilder's main declaration
// Extensions cannot contain stored properties in Swift
// Modify QueryBuilder in QueryBuilder.swift to add:
//
//   private var distinctFields: [String] = []
//   private var distinctAll: Bool = false

// QueryBuilder extension
extension QueryBuilder {
    /// Select distinct records based on a field
    ///
    /// **Example**:
    /// ```swift
    /// let uniqueCities = try await store.query()
    ///     .distinct(by: \.city)
    ///     .execute()
    /// ```
    public func distinct<Value: Hashable>(
        by keyPath: KeyPath<T, Value>
    ) -> Self {
        let fieldName = T.fieldName(for: keyPath)
        // Store distinct field for plan generation
        distinctFields.append(fieldName)
        return self
    }

    /// Select distinct records based on multiple fields
    public func distinct(
        by keyPaths: KeyPath<T, some Hashable>...
    ) -> Self {
        for keyPath in keyPaths {
            let fieldName = T.fieldName(for: keyPath)
            distinctFields.append(fieldName)
        }
        return self
    }

    /// Select distinct records (all fields - uses primary key)
    public func distinct() -> Self {
        distinctAll = true
        return self
    }
}
```

### Plan Design

```swift
/// Distinct plan (removes duplicates based on selected fields)
///
/// This plan wraps another query plan and removes duplicate records.
/// Deduplication is based on:
/// - Specific fields (via KeyPath)
/// - All fields (record equality)
/// - Primary key (automatic when no fields specified)
///
/// **Performance**:
/// - Memory: O(n) where n is number of unique values
/// - Time: O(n) with Set-based deduplication
/// - Streaming: Not possible (must buffer all unique values)
///
/// **Usage**:
/// ```swift
/// let plan = TypedDistinctPlan(
///     childPlan: indexScanPlan,
///     distinctFields: ["city"]
/// )
/// ```
public struct TypedDistinctPlan<Record: Sendable>: TypedQueryPlan {
    // MARK: - Properties

    /// Child plan producing potentially duplicate results
    public let childPlan: any TypedQueryPlan<Record>

    /// Fields to check for uniqueness (nil = all fields)
    public let distinctFields: [String]?

    /// Schema for primary key extraction
    public let schema: Schema

    // MARK: - Initialization

    public init(
        childPlan: any TypedQueryPlan<Record>,
        distinctFields: [String]? = nil,
        schema: Schema
    ) {
        self.childPlan = childPlan
        self.distinctFields = distinctFields
        self.schema = schema
    }

    // MARK: - TypedQueryPlan

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Execute child plan
        let childCursor = try await childPlan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: snapshot
        )

        // Apply distinct filtering
        let distinctCursor = TypedDistinctCursor(
            source: childCursor,
            recordAccess: recordAccess,
            distinctFields: distinctFields,
            schema: schema
        )

        return AnyTypedRecordCursor(distinctCursor)
    }
}

// MARK: - TypedDistinctCursor

/// Cursor that filters out duplicate records
struct TypedDistinctCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let source: AnyTypedRecordCursor<Record>
    private let recordAccess: any RecordAccess<Record>
    private let distinctFields: [String]?
    private let schema: Schema  // ADDED: For primary key extraction

    init(
        source: AnyTypedRecordCursor<Record>,
        recordAccess: any RecordAccess<Record>,
        distinctFields: [String]?,
        schema: Schema
    ) {
        self.source = source
        self.recordAccess = recordAccess
        self.distinctFields = distinctFields
        self.schema = schema
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var sourceIterator: AnyTypedRecordCursor<Record>.AnyAsyncIterator
        let recordAccess: any RecordAccess<Record>
        let distinctFields: [String]?
        let schema: Schema  // ADDED: For primary key extraction

        /// Set of seen values (Data for stable hashing)
        var seenValues = Set<Data>()

        public mutating func next() async throws -> Record? {
            while let record = try await sourceIterator.next() {
                // Extract value for uniqueness check
                let value = try extractDistinctValue(from: record)

                // Convert to Data for stable hashing
                let valueData = value.pack()

                // Check if seen before
                if seenValues.contains(valueData) {
                    continue // Skip duplicate
                }

                // Mark as seen
                seenValues.insert(valueData)

                return record
            }

            return nil
        }

        /// Extract value to check for uniqueness
        private func extractDistinctValue(from record: Record) throws -> Tuple {
            if let fields = distinctFields {
                // Extract specified fields
                var elements: [any TupleElement] = []
                for fieldName in fields {
                    let fieldValues = try recordAccess.extractField(
                        from: record,
                        fieldName: fieldName
                    )
                    elements.append(contentsOf: fieldValues)
                }
                return TupleHelpers.toTuple(elements)
            } else {
                // FIXED: Use schema-derived primary key expression
                // Do NOT hardcode "id" - different schemas use different PK names
                // Get entity from schema to obtain canonical primary key expression
                guard let entity = schema.entity(named: Record.recordName) else {
                    throw RecordLayerError.entityNotFound(Record.recordName)
                }

                return try recordAccess.extractPrimaryKey(
                    from: record,
                    using: entity.primaryKeyExpression
                )
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            sourceIterator: source.makeAsyncIterator(),
            recordAccess: recordAccess,
            distinctFields: distinctFields,
            schema: schema
        )
    }
}
```

### Usage Examples

```swift
// Distinct by single field
let uniqueCities = try await store.query()
    .distinct(by: \.city)
    .execute()

// Distinct by multiple fields
let uniqueCombinations = try await store.query()
    .distinct(by: \.country, \.city)
    .execute()

// Distinct all (remove exact duplicates)
let uniqueUsers = try await store.query()
    .distinct()
    .execute()

// Distinct with filter
let uniqueActiveUsers = try await store.query()
    .where(\.isActive == true)
    .distinct(by: \.email)
    .execute()
```

---

## 4. First N Plan: Optimized Early Termination

### Design Goals

- **Early Termination**: Stop query execution as soon as N results are found
- **Index Awareness**: Push limit down to index scans
- **Type Safety**: Compile-time validation

### Difference from Limit Plan

| Feature | TypedLimitPlan | TypedFirstNPlan |
|---------|----------------|-----------------|
| **Termination** | Collects all, then limits | Stops at N |
| **Index Push-down** | ❌ No | ⚠️ Future Enhancement |
| **Short-circuit** | ❌ No | ✅ Yes (Cursor-level) |
| **Use Case** | Post-processing limit | Early termination |

**Note**: Index push-down (propagating limit hints to `TypedIndexScanPlan`) is a future
enhancement that requires planner modifications. Current implementation provides cursor-level
early termination, which already improves performance by stopping iteration immediately.

### Query API

```swift
// IMPORTANT: This property must be added to QueryBuilder's main declaration
// Extensions cannot contain stored properties in Swift
// Modify QueryBuilder in QueryBuilder.swift to add:
//
//   private var firstN: Int?

// QueryBuilder enhancement
extension QueryBuilder {
    /// Take first N records (optimized early termination)
    ///
    /// This is more efficient than `.limit(N)` because it:
    /// 1. Stops query execution immediately after N results (cursor-level)
    /// 2. Future: Pushes limit down to index scans (requires planner changes)
    /// 3. Future: Short-circuits Union/Intersection operations
    ///
    /// **Example**:
    /// ```swift
    /// let topRated = try await store.query()
    ///     .orderBy(\.rating, .descending)
    ///     .first(10)
    ///     .execute()
    /// ```
    public func first(_ count: Int) -> Self {
        self.firstN = count
        return self
    }
}
```

### Plan Design

```swift
/// First N plan (early termination optimization)
///
/// Unlike TypedLimitPlan, this plan:
/// - Stops iteration immediately after N results
/// - Propagates limit hint to child plans for index optimization
/// - Short-circuits boolean operations (Union/Intersection)
///
/// **Performance**:
/// - I/O: Minimal (stops reading after N)
/// - Memory: O(1) (streaming)
/// - Time: O(N) instead of O(total)
///
/// **Usage**:
/// ```swift
/// let plan = TypedFirstNPlan(
///     childPlan: indexScanPlan,
///     count: 10
/// )
/// ```
public struct TypedFirstNPlan<Record: Sendable>: TypedQueryPlan {
    // MARK: - Properties

    /// Child plan
    public let childPlan: any TypedQueryPlan<Record>

    /// Number of results to return
    public let count: Int

    // MARK: - Initialization

    public init(childPlan: any TypedQueryPlan<Record>, count: Int) {
        self.childPlan = childPlan
        self.count = count
    }

    // MARK: - TypedQueryPlan

    public func execute(
        subspace: Subspace,
        recordAccess: any RecordAccess<Record>,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyTypedRecordCursor<Record> {
        // Execute child plan
        let childCursor = try await childPlan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: snapshot
        )

        // Apply early termination
        let firstNCursor = TypedFirstNCursor(source: childCursor, count: count)

        return AnyTypedRecordCursor(firstNCursor)
    }
}

// MARK: - TypedFirstNCursor

/// Cursor that stops after N results
struct TypedFirstNCursor<Record: Sendable>: TypedRecordCursor {
    public typealias Element = Record

    private let source: AnyTypedRecordCursor<Record>
    private let count: Int

    init(source: AnyTypedRecordCursor<Record>, count: Int) {
        self.source = source
        self.count = count
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var sourceIterator: AnyTypedRecordCursor<Record>.AnyAsyncIterator
        let count: Int
        var emitted: Int = 0

        public mutating func next() async throws -> Record? {
            guard emitted < count else {
                return nil // Early termination
            }

            guard let record = try await sourceIterator.next() else {
                return nil
            }

            emitted += 1
            return record
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
            sourceIterator: source.makeAsyncIterator(),
            count: count
        )
    }
}
```

### Usage Examples

```swift
// Top 10 results
let top10 = try await store.query()
    .orderBy(\.score, .descending)
    .first(10)
    .execute()

// First match (equivalent to .first())
let firstMatch = try await store.query()
    .where(\.status == "active")
    .first(1)
    .execute()

// Early termination with filter
let recent5 = try await store.query()
    .where(\.createdAt > cutoffDate)
    .orderBy(\.createdAt, .descending)
    .first(5)
    .execute()
```

---

## 5. FlatMap Plan: Nested Collection Flattening

### Design Goals

- **Natural Swift API**: Similar to `Sequence.flatMap`
- **Type Safety**: Generic constraints for nested collections
- **Performance**: Streaming with minimal buffering

### Swift-Idiomatic Features

1. **Generic constraints** for nested types
2. **KeyPath-based** field selection
3. **Streaming API**

### Query API

```swift
// QueryBuilder extension
extension QueryBuilder {
    /// FlatMap over a nested collection field
    ///
    /// **Example**:
    /// ```swift
    /// // User has field: tags: [String]
    /// let allTags = try await store.query()
    ///     .flatMap(\.tags)
    ///     .distinct()
    ///     .execute()
    /// ```
    public func flatMap<Value>(
        _ keyPath: KeyPath<T, [Value]>
    ) -> FlatMapQueryBuilder<T, Value> {
        let fieldName = T.fieldName(for: keyPath)
        return FlatMapQueryBuilder(
            base: self,
            fieldName: fieldName
        )
    }
}

/// Query builder for flatMap operations
public final class FlatMapQueryBuilder<T: Recordable, Element> {
    private let base: QueryBuilder<T>
    private let fieldName: String

    internal init(base: QueryBuilder<T>, fieldName: String) {
        self.base = base
        self.fieldName = fieldName
    }

    /// Execute and return flattened elements
    public func execute() async throws -> [Element] {
        let records = try await base.execute()

        var results: [Element] = []
        for record in records {
            let recordAccess = GenericRecordAccess<T>()
            let fieldValues = try recordAccess.extractField(
                from: record,
                fieldName: fieldName
            )

            // Assume field contains array
            for value in fieldValues {
                if let element = value as? Element {
                    results.append(element)
                }
            }
        }

        return results
    }

    /// Apply distinct to flattened elements
    public func distinct() -> Self where Element: Hashable {
        // TODO: Store distinct flag
        return self
    }
}
```

### Plan Design

**IMPORTANT**: FlatMap requires architectural changes to support returning elements instead of records.
Current `TypedQueryPlan` protocol is designed for record-level operations only.

**Recommended Approach**:

```swift
/// Protocol for plans that return elements (not records)
public protocol TypedElementPlan<Element>: Sendable {
    associatedtype Element: TupleElement

    func execute(
        subspace: Subspace,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyElementCursor<Element>
}

/// Cursor that iterates over elements
public struct AnyElementCursor<Element: TupleElement>: AsyncSequence {
    public typealias AsyncIterator = AnyElementIterator<Element>

    private let _makeAsyncIterator: () -> AnyElementIterator<Element>

    init<C: AsyncSequence>(_ cursor: C) where C.Element == Element {
        self._makeAsyncIterator = {
            AnyElementIterator(cursor.makeAsyncIterator())
        }
    }

    public func makeAsyncIterator() -> AnyElementIterator<Element> {
        return _makeAsyncIterator()
    }
}

/// Type-erased element iterator
public struct AnyElementIterator<Element: TupleElement>: AsyncIteratorProtocol {
    private var _next: () async throws -> Element?

    init<I: AsyncIteratorProtocol>(_ iterator: I) where I.Element == Element {
        var iterator = iterator
        self._next = { try await iterator.next() }
    }

    public mutating func next() async throws -> Element? {
        return try await _next()
    }
}

/// FlatMap plan (flatten nested collections)
///
/// **Architecture Change Required**:
/// This plan implements `TypedElementPlan<Element>` instead of `TypedQueryPlan<Record>`.
///
/// **Usage**:
/// ```swift
/// let plan = TypedFlatMapPlan<Product, String>(
///     childPlan: scanPlan,
///     fieldName: "tags",
///     recordAccess: recordAccess
/// )
/// let cursor = try await plan.execute(
///     subspace: subspace,
///     context: context,
///     snapshot: true
/// )
/// for try await tag in cursor {
///     print(tag) // String
/// }
/// ```
public struct TypedFlatMapPlan<Record: Sendable, Element: TupleElement>: TypedElementPlan {
    // MARK: - Properties

    /// Child plan producing records
    public let childPlan: any TypedQueryPlan<Record>

    /// Field name containing collection
    public let fieldName: String

    /// Record access for field extraction
    public let recordAccess: any RecordAccess<Record>

    // MARK: - Initialization

    public init(
        childPlan: any TypedQueryPlan<Record>,
        fieldName: String,
        recordAccess: any RecordAccess<Record>
    ) {
        self.childPlan = childPlan
        self.fieldName = fieldName
        self.recordAccess = recordAccess
    }

    // MARK: - TypedElementPlan

    public func execute(
        subspace: Subspace,
        context: RecordContext,
        snapshot: Bool
    ) async throws -> AnyElementCursor<Element> {
        // Execute child plan to get records
        let childCursor = try await childPlan.execute(
            subspace: subspace,
            recordAccess: recordAccess,
            context: context,
            snapshot: snapshot
        )

        // Create flatMap cursor
        let flatMapCursor = FlatMapCursor<Record, Element>(
            source: childCursor,
            fieldName: fieldName,
            recordAccess: recordAccess
        )

        return AnyElementCursor(flatMapCursor)
    }
}

/// Cursor that flattens nested collections
struct FlatMapCursor<Record: Sendable, Element: TupleElement>: AsyncSequence, AsyncIteratorProtocol {
    typealias Element = Element

    private var sourceIterator: AnyTypedRecordCursor<Record>.AnyAsyncIterator
    private let fieldName: String
    private let recordAccess: any RecordAccess<Record>

    /// Buffer of elements from current record
    private var buffer: [Element] = []
    private var bufferIndex: Int = 0

    init(
        source: AnyTypedRecordCursor<Record>,
        fieldName: String,
        recordAccess: any RecordAccess<Record>
    ) {
        self.sourceIterator = source.makeAsyncIterator()
        self.fieldName = fieldName
        self.recordAccess = recordAccess
    }

    mutating func next() async throws -> Element? {
        // Return next element from buffer if available
        if bufferIndex < buffer.count {
            let element = buffer[bufferIndex]
            bufferIndex += 1
            return element
        }

        // Fetch next record and extract collection
        while let record = try await sourceIterator.next() {
            let fieldValues = try recordAccess.extractField(
                from: record,
                fieldName: fieldName
            )

            // Cast to target element type
            buffer = fieldValues.compactMap { $0 as? Element }
            bufferIndex = 0

            if !buffer.isEmpty {
                let element = buffer[bufferIndex]
                bufferIndex += 1
                return element
            }
        }

        // No more records
        return nil
    }

    func makeAsyncIterator() -> FlatMapCursor {
        return self
    }
}
```

**Note**: This design requires creating a separate element-level query API parallel to
the record-level API. Implementation priority is **LOW** due to architectural complexity.

### Usage Examples

```swift
// Flatten tags from all products
let allTags = try await store.query()
    .flatMap(\.tags)
    .execute()

// Distinct tags
let uniqueTags = try await store.query()
    .flatMap(\.tags)
    .distinct()
    .execute()

// FlatMap with filter
let activeTags = try await store.query()
    .where(\.isActive == true)
    .flatMap(\.tags)
    .execute()
```

---

## Summary

### Implementation Priority

1. **🟠 HIGH: Distinct Plan** - Essential for data deduplication
2. **🟡 MEDIUM: TEXT Index** - Common use case, high value
3. **🟡 MEDIUM: First N Plan** - Performance optimization
4. **🟢 LOW: SPATIAL Index** - Specialized use case
5. **🟢 LOW: FlatMap Plan** - Nice-to-have, requires architecture changes

### Swift Language Features Leveraged

| Feature | Usage |
|---------|-------|
| **Result Builders** | TEXT query DSL (`@TextQueryBuilder`) |
| **KeyPath** | Type-safe field selection |
| **OptionSet** | Search options (`TextSearchOptions`) |
| **Generic Constraints** | `Hashable`, `Comparable` for type safety |
| **CoreLocation** | Native coordinate types |
| **Measurement API** | Type-safe distances |
| **Async/Await** | Natural asynchronous operations |
| **Protocol-Oriented** | Extensible tokenizers, analyzers |

### Key Differences from Java

1. **No Lucene Dependency**: Pure Swift text indexing
2. **CoreLocation Integration**: Native iOS/macOS coordinate types
3. **Result Builders**: Intuitive query DSL
4. **KeyPath Selection**: Compile-time field validation
5. **OptionSet**: Swift-idiomatic flags
6. **Measurement API**: Type-safe units

### Next Steps

1. Implement **TypedDistinctPlan** (HIGH priority)
2. Implement **TypedFirstNPlan** (MEDIUM priority)
3. Design TEXT tokenizer system
4. Implement Geohash encoding for SPATIAL
5. Consider FlatMap architectural changes (separate element cursor type)

---

**Design Document Version**: 1.0
**Author**: Claude Code Assistant
**Date**: 2025-01-11
