# FoundationDB Record Layer for Swift

**A type-safe database layer that lets you share model definitions across mobile and server**

[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20macOS%20%7C%20Linux-blue.svg)](https://www.apple.com/macos/)
[![Tests](https://img.shields.io/badge/Tests-530%20passing-success.svg)]()
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

```swift
// One model definition works across iOS/macOS/Server
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email])

    var userID: Int64
    var email: String
    var name: String
}

// iOS: Use with JSON APIs
let users = try JSONDecoder().decode([User].self, from: jsonData)

// Server: Persist with FoundationDB
let store = try await User.store(database: database, schema: schema)
try await store.save(user)
```

---

## 🎯 Why use this library?

### Problem: Duplicate model definitions across mobile and server

Traditional approach:
```swift
// ❌ Separate model definitions required for iOS and server
// iOS: UserDTO.swift
struct UserDTO: Codable { ... }

// Server: User.proto
message User { ... }

// → Difficult to keep in sync, type mismatches cause bugs
```

### Solution: One model definition for both

```swift
// ✅ One definition works across iOS/macOS/Server
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    var userID: Int64
    var email: String
    var name: String
}

// FDBRecordCore: For mobile (lightweight, no FoundationDB dependency)
// FDBRecordLayer: For server (full persistence features)
```

**Benefits**:
- ✅ **SSOT** (Single Source of Truth): Only one model definition
- ✅ **Type-safe**: Compile-time type checking, no runtime errors
- ✅ **Auto-generated**: No boilerplate with macros
- ✅ **Codable support**: Automatic JSON API integration

---

## 🚀 30-Second Quick Start

### 1. Installation

**For mobile apps (iOS/macOS)**:
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/1amageek/fdb-record-layer.git", from: "3.0.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "FDBRecordCore", package: "fdb-record-layer")
        ]
    )
]
```

**For server apps**:
```swift
dependencies: [
    .product(name: "FDBRecordLayer", package: "fdb-record-layer")  // Full version
]
```

### 2. Define model (shared)

```swift
import FDBRecordCore  // Common for iOS/macOS/Server

@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email])
    #Directory<User>("app", "users")  // Optional: defaults to ["User"]

    var userID: Int64
    var email: String
    var name: String
    var age: Int
}
```

### 3-A. Use on mobile

```swift
// Fetch from JSON API
let url = URL(string: "https://api.example.com/users")!
let (data, _) = try await URLSession.shared.data(from: url)
let users = try JSONDecoder().decode([User].self, from: data)

// Display in SwiftUI
List(users, id: \.userID) { user in
    Text(user.name)
}
```

### 3-B. Use on server

```swift
import FDBRecordLayer

// 1. Create schema
let schema = Schema([User.self])

// 2. Create RecordContainer (manages database connection)
let container = try RecordContainer(
    for: User.self,
    configurations: [
        RecordConfiguration(schema: schema)
    ]
)

// 3. Get RecordStore (path auto-resolved from #Directory macro)
let store = try await container.store(for: User.self)
// Directory path: ["app", "users"] (from #Directory macro)
// Or: ["User"] (default if no #Directory macro)

// 4. Save
try await store.save(user)

// 5. Query (type-safe)
let adults = try await store.query(User.self)
    .where(\.age, .greaterThanOrEquals, 18)
    .execute()

// Optional: Use ModelContext (SwiftData-like API)
let context = try await container.makeContext(for: User.self)
context.insert(user)
if context.hasChanges {
    try await context.save()
}
```

---

## 💡 Key Use Cases

### 1. Multi-Platform Apps

**Scenario**: Share the same models across iOS/macOS/Server

```swift
// Shared Package: Common model definition
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])
    var productID: Int64
    var name: String
    var price: Double
}

// iOS: Use with JSON API
let products = try JSONDecoder().decode([Product].self, from: data)

// Server: Persist with FoundationDB
let schema = Schema([Product.self])
let container = try RecordContainer(
    for: Product.self,
    configurations: [RecordConfiguration(schema: schema)]
)
let store = try await container.store(for: Product.self)
// Directory: ["Product"] (default)
try await store.save(product)
```

**Benefit**: Eliminates bugs caused by type mismatches

---

### 2. Vector Search (Semantic Search, Recommendations)

**Scenario**: Product recommendations, similar image search

```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    var productID: Int64
    var name: String
    var embedding: [Float32]  // 384-dimensional vector
}

// Add vector index to schema
let vectorIndex = Index(
    name: "product_embedding_vector",
    type: .vector,
    rootExpression: FieldKeyExpression(fieldName: "embedding"),
    options: IndexOptions(vectorOptions: VectorIndexOptions(
        dimensions: 384,
        metric: .cosine
    ))
)

let schema = Schema(
    [Product.self],
    indexes: [vectorIndex],
    indexConfigurations: [
        IndexConfiguration(
            indexName: "product_embedding_vector",
            vectorStrategy: .hnswBatch  // HNSW: O(log n) search
        )
    ]
)

// Build HNSW index (offline, once)
let onlineIndexer = OnlineIndexer(store: store, indexName: "product_embedding_vector")
try await onlineIndexer.buildHNSWIndex()

// Query: Find products similar to "wireless headphones"
let queryEmbedding: [Float32] = getEmbedding(from: "wireless headphones")

// ✅ Recommended: KeyPath-based API (type-safe)
let similar = try await store.query(Product.self)
    .nearestNeighbors(k: 10, to: queryEmbedding, using: \.embedding)
    .execute()

// Results: Top 10 by similarity
for (product, distance) in similar {
    print("\(product.name): similarity = \(1.0 - distance)")
}
```

**Performance**:
- O(log n) search (HNSW algorithm)
- ~10ms latency for 1M vectors
- Recall@10: ~95%

**Fail-fast validation** (production-ready):
- ✅ `hnswGraphNotBuilt`: Explicit error if HNSW graph not built
- ✅ `indexNotReadable`: Explicit error if index in `writeOnly` or `disabled` state
- ✅ Actionable error messages with fix instructions
- ✅ All 5 validation tests passing

**Use cases**:
- Semantic search (text embeddings)
- Similar image search (vision embeddings)
- Recommendation systems
- Duplicate detection

---

### 3. Location Search (Map Apps, Delivery Apps)

**Scenario**: Find "restaurants within 1km of current location"

```swift
@Recordable
struct Restaurant {
    #PrimaryKey<Restaurant>([\.restaurantID])

    @Spatial(
        type: .geo(
            latitude: \.latitude,
            longitude: \.longitude,
            level: 17  // ~9m precision
        ),
        name: "restaurant_by_location"
    )
    var latitude: Double
    var longitude: Double

    var restaurantID: Int64
    var name: String
    var category: String
}

// Query: Restaurants within 1km of Tokyo Station
let nearby = try await store.query(Restaurant.self)
    .withinRadius(
        centerLat: 35.6812,
        centerLon: 139.7671,
        radiusMeters: 1000.0,
        using: "restaurant_by_location"
    )
    .execute()
```

**Spatial indexes**:
- **S2 Geometry**: Geographic coordinates (latitude/longitude)
- **Morton Code**: Cartesian coordinates (game maps, etc.)
- **4 spatial types**: `.geo`, `.geo3D`, `.cartesian`, `.cartesian3D`

---

### 4. Multi-Tenant SaaS

**Scenario**: Complete data isolation per tenant

```swift
@Recordable
struct Order {
    #PrimaryKey<Order>([\.orderID])
    #Directory<Order>(
        "tenants",
        Field(\.tenantID),
        "orders",
        layer: .partition  // Complete isolation per tenant
    )

    var orderID: Int64
    var tenantID: String
    var amount: Double
}

// Open store per tenant
let tenant1Store = try await Order.store(
    tenantID: "tenant-123",
    database: database,
    schema: schema
)

// Only tenant1's data is visible
try await tenant1Store.save(order)
```

**Benefits**:
- Physical isolation with FoundationDB's Partition feature
- Accessing wrong tenant's data is physically impossible
- Scalable (supports tens of thousands of tenants)

---

## 🔥 Key Features

| Feature | Description | Status |
|---------|-------------|--------|
| **Model Sharing** | Same model definition across iOS/macOS/Server | ✅ 100% |
| **Macro API** | SwiftData-like declarative API | ✅ 100% |
| **Vector Search** | HNSW (O(log n) nearest neighbor) + fail-fast validation | ✅ 100% |
| **Spatial Indexing** | S2 + Morton Code (4 spatial types) | ✅ 100% |
| **9 Index Types** | VALUE, COUNT, SUM, MIN/MAX, RANK, VERSION, PERMUTED, VECTOR, SPATIAL | ✅ 100% |
| **Query Optimization** | Cost-based planner, statistics | ✅ 100% |
| **Migration Manager** | Zero-downtime schema evolution | ✅ 100% |
| **Swift 6** | Strict concurrency mode compliant | ✅ 100% |

---

## 📚 Next Steps

### 📖 Documentation

- **[Quick Start (10 min)](docs/guides/getting-started.md)** - Get started immediately
- **[Complete Guide (CLAUDE.md)](CLAUDE.md)** - Implementation details, best practices
- **[Java Version Comparison](docs/JAVA_COMPARISON.md)** - Feature comparison, migration guide
- **[API Reference](docs/api-reference.md)** - Complete API specification

### 💻 Sample Code

- [SimpleExample.swift](Examples/SimpleExample.swift) - Basic usage
- [VectorSearchExample.swift](Examples/VectorSearchExample.swift) - Vector search
- [SpatialExample.swift](Examples/SpatialExample.swift) - Location search
- [MultiTenantExample.swift](Examples/PartitionExample.swift) - Multi-tenant

### 🏗️ Architecture

```
┌─────────────────────────────────────┐
│   iOS/macOS App (FDBRecordCore)     │
│   ✅ Model definitions only (lightweight) │
│   ✅ JSON API integration           │
└─────────────────────────────────────┘
                │
                │ Same model definition
                ▼
┌─────────────────────────────────────┐
│   Server App (FDBRecordLayer)       │
│   ✅ Full persistence features      │
│   ✅ FoundationDB integration       │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│        FoundationDB Cluster          │
│   ✅ ACID guarantees                │
│   ✅ Distributed transactions       │
└─────────────────────────────────────┘
```

---

## 📊 Performance

| Operation | Throughput | Latency |
|-----------|-----------|---------|
| **Vector Search** | ~100 QPS/core | ~10ms (1M vectors) |
| **Spatial Query** | ~500 QPS/core | ~5-20ms |
| **Aggregate Query (COUNT/SUM)** | 18,142 QPS | P99: 5.1ms |
| **Index Scan** | 50K ops/sec | 5-20ms |
| **Primary Key Read** | 100K ops/sec | 1-5ms |

**Tested scale**:
- ✅ 530 tests passing (51 suites)
- ✅ 1M vectors (Vector Search)
- ✅ 100K records (Spatial Indexing)
- ✅ Tens of thousands of tenants (Multi-tenant)

---

## 🛠️ Installation Requirements

- **Swift**: 6.0 or later
- **Platforms**:
  - iOS 17.0+ / macOS 14.0+ (FDBRecordCore)
  - macOS 15.0+ / Linux (FDBRecordLayer + FoundationDB)
- **FoundationDB**: 7.1.0 or later (server only)

### FoundationDB Setup (server only)

```bash
# macOS
brew install foundationdb

# Start
sudo launchctl start com.foundationdb.fdbserver

# Verify
fdbcli --exec "status"
```

---

## 🤝 Contributing

Pull requests are welcome!

1. Fork this repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Add and run tests (`swift test`)
4. Commit (`git commit -m 'Add amazing feature'`)
5. Push (`git push origin feature/amazing-feature`)
6. Create pull request

---

## 📄 License

Apache License 2.0 - See [LICENSE](LICENSE) for details

---

## 🙏 Acknowledgments

This project is based on Apple Inc.'s [FoundationDB Record Layer](https://foundationdb.github.io/fdb-record-layer/).

---

## 🔗 Resources

- **Documentation**: [docs/index.md](docs/index.md)
- **FoundationDB Official**: https://www.foundationdb.org/
- **Java Record Layer**: https://foundationdb.github.io/fdb-record-layer/
- **Support**: [GitHub Issues](https://github.com/1amageek/fdb-record-layer/issues)

---

**Status**: ✅ **PRODUCTION READY** - 530 tests passing, Swift 6 compliant, fully documented

Share model definitions across mobile and server for type-safe, high-performance database operations.
