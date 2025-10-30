# FoundationDB Record Layer - Swift Implementation

A Swift implementation of FoundationDB Record Layer, providing a structured record-oriented database built on top of [FoundationDB](https://www.foundationdb.org/).

## Overview

The Record Layer provides a powerful abstraction for storing and querying structured data in FoundationDB, featuring:

- **Structured Schema**: Type-safe records using Protocol Buffers
- **Secondary Indexes**: Flexible indexing with automatic maintenance
- **Query Optimization**: Cost-based query planner for efficient execution
- **Online Index Building**: Build indexes without downtime
- **ACID Transactions**: Full transactional guarantees from FoundationDB
- **Mutex-based Concurrency**: Thread-safe operations using NSLock

## Features

### 📦 Record Storage

Store structured records with Protobuf schemas:

```swift
// Define your schema
message User {
    int64 user_id = 1;
    string name = 2;
    string email = 3;
    int64 created_at = 4;
}

// Save records
let user = User.with {
    $0.userID = 123
    $0.name = "Alice"
    $0.email = "alice@example.com"
}

try await database.withRecordContext { context in
    try await recordStore.saveRecord(user, context: context)
}
```

### 🔍 Flexible Indexing

Define indexes for your access patterns:

```swift
// Email index for lookups
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email")
)

// Compound index for range queries
let cityAgeIndex = Index(
    name: "user_by_city_age",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "age")
    ])
)

// Count aggregation
let cityCountIndex = Index(
    name: "user_count_by_city",
    type: .count,
    rootExpression: FieldKeyExpression(fieldName: "city")
)
```

### 🔎 Rich Query Language

Express complex queries with automatic optimization:

```swift
let query = RecordQuery(
    recordType: "User",
    filter: AndQueryComponent(children: [
        FieldQueryComponent(
            fieldName: "city",
            comparison: .equals,
            value: "San Francisco"
        ),
        FieldQueryComponent(
            fieldName: "age",
            comparison: .greaterThanOrEquals,
            value: 18
        )
    ]),
    sort: [SortKey(expression: FieldKeyExpression(fieldName: "name"))]
)

try await database.withRecordContext { context in
    let cursor = try await recordStore.executeQuery(query, context: context)
    for try await user in cursor {
        print(user.name)
    }
}
```

### 🏗️ Online Index Building

Build indexes without blocking writes:

```swift
let indexer = OnlineIndexer(
    store: recordStore,
    index: emailIndex,
    database: database
)

try await indexer.buildIndex()
```

### 📊 Index Types

- **Value Index**: Standard B-tree index for lookups and range scans
- **Count Index**: Aggregation index for counting grouped records
- **Sum Index**: Aggregation index for summing values
- **Rank Index**: Leaderboard and ranking functionality

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/fdb-record-layer.git", from: "1.0.0")
]
```

### Requirements

- Swift 6.0+
- macOS 15.0+
- FoundationDB 7.1.0+

## Quick Start

### 1. Install FoundationDB

```bash
# macOS
brew install foundationdb

# Start the service
brew services start foundationdb
```

### 2. Define Your Schema

Create a `.proto` file:

```protobuf
syntax = "proto3";

message User {
    int64 user_id = 1;
    string name = 2;
    string email = 3;
}

message RecordTypeUnion {
    oneof record {
        User user = 1;
    }
}
```

### 3. Create Metadata

```swift
import FDBRecordLayer
import FoundationDB

// Define schema
let primaryKey = FieldKeyExpression(fieldName: "user_id")

let userRecordType = RecordType(
    name: "User",
    primaryKey: primaryKey,
    messageDescriptor: User.messageDescriptor
)

let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email")
)

let metaData = try RecordMetaDataBuilder()
    .setVersion(1)
    .addRecordType(userRecordType)
    .addIndex(emailIndex)
    .setUnionDescriptor(RecordTypeUnion.unionDescriptor)
    .build()
```

### 4. Create Record Store

```swift
// Initialize FoundationDB
try await FDBClient.initialize()
let database = try FDBClient.openDatabase()

// Create record store
let recordStore = RecordStore<RecordTypeUnion>(
    database: database,
    subspace: Subspace(rootPrefix: "my-app"),
    metaData: metaData,
    serializer: ProtobufRecordSerializer<RecordTypeUnion>()
)
```

### 5. Perform Operations

```swift
// Save a record
let user = User.with {
    $0.userID = 1
    $0.name = "Alice"
    $0.email = "alice@example.com"
}

try await database.withRecordContext { context in
    try await recordStore.saveRecord(user, context: context)
}

// Load a record
try await database.withRecordContext { context in
    let loaded = try await recordStore.loadRecord(
        primaryKey: Tuple(1),
        context: context
    )
    print(loaded?.name ?? "Not found")
}

// Query records
let query = RecordQuery(
    recordType: "User",
    filter: FieldQueryComponent(
        fieldName: "email",
        comparison: .equals,
        value: "alice@example.com"
    )
)

try await database.withRecordContext { context in
    let cursor = try await recordStore.executeQuery(query, context: context)
    for try await user in cursor {
        print(user.name)
    }
}
```

## Architecture

The Record Layer is organized into several key components:

```
┌─────────────────────────────────────────────────────────┐
│                   Application Layer                      │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│              RecordStore<M>                              │
│  - saveRecord()  - loadRecord()  - executeQuery()        │
└─────┬──────────┬──────────┬──────────┬─────────────────┘
      │          │          │          │
      ▼          ▼          ▼          ▼
┌──────────┐ ┌────────┐ ┌─────────┐ ┌──────────────┐
│ Record   │ │ Index  │ │  Query  │ │ RecordMeta   │
│ Context  │ │Maintain│ │ Planner │ │    Data      │
└──────────┘ └────────┘ └─────────┘ └──────────────┘
      │          │          │          │
      └──────────┴──────────┴──────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│              FoundationDB Layer                          │
└─────────────────────────────────────────────────────────┘
```

For detailed architecture information, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Documentation

- [Architecture Guide](ARCHITECTURE.md) - Detailed design and implementation
- [Project Structure](PROJECT_STRUCTURE.md) - File organization and conventions
- [Migration Guide](MIGRATION.md) - Migrating from RDF Layer
- [Getting Started](Documentation/GettingStarted.md) - Tutorial and examples
- [Metadata Guide](Documentation/Metadata.md) - Schema definition
- [Index Guide](Documentation/Indexes.md) - Index types and usage
- [Query Guide](Documentation/Queries.md) - Query language reference
- [Performance Guide](Documentation/Performance.md) - Optimization tips

## Examples

See the `Examples/` directory for complete examples:

- [SimpleRecordStore](Examples/SimpleRecordStore/) - Basic CRUD operations
- [QueryExample](Examples/QueryExample/) - Complex queries
- [OnlineIndexExample](Examples/OnlineIndexExample/) - Index building

## Comparison with RDF Layer

| Feature | RDF Layer | Record Layer |
|---------|-----------|--------------|
| Data Model | RDF Triples | Structured Records |
| Schema | Schema-free | Protobuf schemas |
| Indexes | Fixed (SPO, PSO, POS, OSP) | User-defined |
| Query | Triple patterns | Rich query language |
| Aggregation | Manual | Built-in (count, sum, rank) |
| Use Case | Semantic web, graphs | Business applications |

For migration instructions, see [MIGRATION.md](MIGRATION.md).

## Performance

The Record Layer is designed for high performance:

- **Batch Operations**: Efficient batch inserts and updates
- **Index Optimization**: Query planner selects optimal indexes
- **Streaming Queries**: Memory-efficient result iteration
- **Atomic Operations**: Lock-free counters and aggregations

Performance tips:
- Define indexes for your query patterns
- Use batch operations for bulk inserts
- Enable compression for large records
- Use snapshot reads for read-only queries

See [Performance Guide](Documentation/Performance.md) for details.

## Development Status

**Current Phase:** Design and Documentation

### Completed
- ✅ Architecture design
- ✅ API design
- ✅ Documentation

### In Progress
- 🚧 Core types implementation
- 🚧 Subspace management
- 🚧 RecordStore implementation

### Planned
- ⏳ Serialization layer
- ⏳ Index maintenance
- ⏳ Query system
- ⏳ Online indexer

See [Implementation Roadmap](ARCHITECTURE.md#implementation-roadmap) for the full schedule.

## Contributing

Contributions are welcome! Please see our contributing guidelines (coming soon).

### Development Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/fdb-record-layer.git
cd fdb-record-layer

# Install dependencies
swift package resolve

# Build the project
swift build

# Run tests
swift test
```

## Testing

```bash
# Run all tests
swift test

# Run specific test
swift test --filter RecordStoreTests

# Run with coverage
swift test --enable-code-coverage
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [FoundationDB](https://www.foundationdb.org/) - The underlying database
- [fdb-record-layer](https://github.com/FoundationDB/fdb-record-layer) - The Java implementation that inspired this project
- [fdb-swift-bindings](https://github.com/foundationdb/fdb-swift-bindings) - Swift bindings for FoundationDB

## Support

- 📚 [Documentation](ARCHITECTURE.md)
- 🐛 [Issue Tracker](https://github.com/yourusername/fdb-record-layer/issues)
- 💬 [Discussions](https://github.com/yourusername/fdb-record-layer/discussions)

## Resources

- [FoundationDB Documentation](https://apple.github.io/foundationdb/)
- [FoundationDB Record Layer (Java)](https://foundationdb.github.io/fdb-record-layer/)
- [Swift Protobuf](https://github.com/apple/swift-protobuf)
- [fdb-swift-bindings Documentation](CLAUDE.md)

## Roadmap

### Version 1.0 (Target: Q1 2026)
- Core record store functionality
- Value indexes
- Basic query support
- Online index building

### Version 2.0 (Target: Q2 2026)
- Rank indexes
- Advanced query features
- Compression and encryption
- Performance optimizations

### Version 3.0 (Target: Q3 2026)
- Lucene integration (full-text search)
- Spatial indexes
- Advanced aggregations
- Multi-tenancy support

## FAQ

### Q: How does this compare to CoreData or Realm?

A: The Record Layer provides:
- **Distributed**: FoundationDB is a distributed database
- **ACID**: Full transactional guarantees across multiple nodes
- **Scalable**: Handles terabytes of data
- **Flexible**: User-defined schemas and indexes

### Q: Can I use this in production?

A: Not yet. The project is currently in the design phase. We recommend waiting for version 1.0.

### Q: Does this support Swift Concurrency (async/await)?

A: Yes! All APIs use async/await for modern Swift concurrency.

### Q: Can I migrate from the RDF Layer?

A: Yes, see the [Migration Guide](MIGRATION.md) for detailed instructions.

### Q: What about iOS/watchOS/tvOS support?

A: Currently, only macOS is supported. iOS support requires FoundationDB client support on iOS, which is not currently available.

## Contact

- Email: your-email@example.com
- GitHub: [@yourusername](https://github.com/yourusername)
- Twitter: [@yourhandle](https://twitter.com/yourhandle)

---

**Built with ❤️ using Swift and FoundationDB**
