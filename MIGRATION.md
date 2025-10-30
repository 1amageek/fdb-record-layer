# Migration Guide: RDF Layer to Record Layer

This guide helps you migrate from the existing RDF Layer implementation to the new FoundationDB Record Layer.

## Overview

The RDF Layer and Record Layer serve different purposes:

| Aspect | RDF Layer | Record Layer |
|--------|-----------|--------------|
| **Data Model** | RDF Triples (SPO) | Structured Records (Protobuf) |
| **Schema** | Schema-free | Schema-required (Protobuf) |
| **Indexes** | Fixed (SPO, PSO, POS, OSP) | Flexible (user-defined) |
| **Queries** | Triple pattern matching | Rich query language |
| **Use Case** | Semantic web, graph data | Structured business data |

## Why Migrate?

### Advantages of Record Layer

1. **Structured Schema**: Type-safe records with Protobuf
2. **Rich Queries**: Complex filter predicates and joins
3. **Flexible Indexes**: Define indexes based on your access patterns
4. **Query Optimization**: Automatic query planning
5. **Aggregations**: Built-in count, sum, rank indexes
6. **Secondary Indexes**: Multiple index types for different query patterns

### When to Use Each

**Use RDF Layer if:**
- Working with semantic web data (RDF, SPARQL)
- Schema-free requirements
- Triple-based relationships
- Graph traversal patterns

**Use Record Layer if:**
- Structured business entities (users, orders, products)
- Type-safe schema enforcement
- Complex query requirements
- Aggregation queries
- Application-specific indexes

## Migration Strategy

### Step 1: Analyze Your Data Model

#### RDF Layer (Before)

```swift
// Triples
let triple1 = RDFTriple(
    subject: "http://example.org/user/123",
    predicate: "http://schema.org/name",
    object: "Alice"
)

let triple2 = RDFTriple(
    subject: "http://example.org/user/123",
    predicate: "http://schema.org/email",
    object: "alice@example.com"
)

try await rdfStore.insert(triple1)
try await rdfStore.insert(triple2)
```

#### Record Layer (After)

```protobuf
// user.proto
syntax = "proto3";

message User {
    int64 user_id = 1;
    string name = 2;
    string email = 3;
    int64 created_at = 4;
}

message RecordTypeUnion {
    oneof record {
        User user = 1;
    }
}
```

```swift
// Swift
let user = User.with {
    $0.userID = 123
    $0.name = "Alice"
    $0.email = "alice@example.com"
    $0.createdAt = Date().timeIntervalSince1970
}

try await recordStore.saveRecord(user, context: context)
```

### Step 2: Define Metadata

Create schema definition:

```swift
// Define primary key
let primaryKey = FieldKeyExpression(fieldName: "user_id")

// Define record type
let userRecordType = RecordType(
    name: "User",
    primaryKey: primaryKey,
    secondaryIndexes: ["user_by_email"],
    messageDescriptor: User.messageDescriptor
)

// Define indexes
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email"),
    recordTypes: ["User"]
)

// Build metadata
let metaData = try RecordMetaDataBuilder()
    .setVersion(1)
    .addRecordType(userRecordType)
    .addIndex(emailIndex)
    .setUnionDescriptor(RecordTypeUnion.unionDescriptor)
    .build()
```

### Step 3: Create Record Store

```swift
// RDF Layer (Before)
let rdfStore = try await RDFStore(
    database: database,
    rootPrefix: "my-app"
)

// Record Layer (After)
let recordStore = RecordStore<RecordTypeUnion>(
    database: database,
    subspace: Subspace(rootPrefix: "my-app"),
    metaData: metaData,
    serializer: ProtobufRecordSerializer<RecordTypeUnion>()
)
```

### Step 4: Migrate Operations

#### Insert/Update

```swift
// RDF Layer
try await rdfStore.insert(triple)

// Record Layer
try await database.withRecordContext { context in
    try await recordStore.saveRecord(user, context: context)
}
```

#### Query

```swift
// RDF Layer - Triple pattern
let results = try await rdfStore.query(
    subject: "http://example.org/user/123",
    predicate: nil,
    object: nil
)

// Record Layer - Query by primary key
let user = try await database.withRecordContext { context in
    try await recordStore.loadRecord(
        primaryKey: Tuple(123),
        context: context
    )
}

// Record Layer - Query by index
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
        print(user)
    }
}
```

#### Delete

```swift
// RDF Layer
try await rdfStore.delete(triple)

// Record Layer
try await database.withRecordContext { context in
    try await recordStore.deleteRecord(
        primaryKey: Tuple(123),
        context: context
    )
}
```

## Migration Patterns

### Pattern 1: Entities with Properties

#### RDF Style

```
<user:123> <name> "Alice"
<user:123> <email> "alice@example.com"
<user:123> <age> 30
```

#### Record Style

```protobuf
message User {
    int64 id = 1;
    string name = 2;
    string email = 3;
    int32 age = 4;
}
```

### Pattern 2: Relationships

#### RDF Style

```
<user:123> <knows> <user:456>
<user:123> <knows> <user:789>
```

#### Record Style (Option 1: Embedded)

```protobuf
message User {
    int64 id = 1;
    repeated int64 knows_user_ids = 2;
}
```

#### Record Style (Option 2: Separate Record Type)

```protobuf
message Relationship {
    int64 from_user_id = 1;
    int64 to_user_id = 2;
    string relationship_type = 3;
}
```

### Pattern 3: Multi-valued Properties

#### RDF Style

```
<user:123> <hobby> "Reading"
<user:123> <hobby> "Hiking"
```

#### Record Style

```protobuf
message User {
    int64 id = 1;
    repeated string hobbies = 2;
}
```

## Data Migration Script

### Export from RDF Layer

```swift
// Export all triples
let triples = try await rdfStore.all()

// Group by subject to form records
var recordMap: [String: [String: [String]]] = [:]

for triple in triples {
    if recordMap[triple.subject] == nil {
        recordMap[triple.subject] = [:]
    }

    if recordMap[triple.subject]![triple.predicate] == nil {
        recordMap[triple.subject]![triple.predicate] = []
    }

    recordMap[triple.subject]![triple.predicate]!.append(triple.object)
}

// Convert to records
for (subject, properties) in recordMap {
    let user = User.with {
        $0.id = extractID(from: subject)
        $0.name = properties["http://schema.org/name"]?.first ?? ""
        $0.email = properties["http://schema.org/email"]?.first ?? ""
    }

    try await recordStore.saveRecord(user, context: context)
}
```

### Full Migration Example

```swift
actor DataMigrator {
    let rdfStore: RDFStore
    let recordStore: RecordStore<RecordTypeUnion>
    let database: any DatabaseProtocol

    func migrateUsers() async throws {
        // 1. Query all user triples from RDF store
        let userTriples = try await rdfStore.query(
            subject: nil,
            predicate: "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
            object: "http://schema.org/Person"
        )

        // 2. Group triples by subject
        let subjects = Set(userTriples.map { $0.subject })

        // 3. Convert each subject to a User record
        for subject in subjects {
            let properties = try await rdfStore.query(
                subject: subject,
                predicate: nil,
                object: nil
            )

            let user = try buildUser(from: properties)

            // 4. Save to record store
            try await database.withRecordContext { context in
                try await recordStore.saveRecord(user, context: context)
            }
        }
    }

    private func buildUser(from triples: [RDFTriple]) throws -> User {
        var user = User()

        for triple in triples {
            switch triple.predicate {
            case "http://schema.org/name":
                user.name = triple.object
            case "http://schema.org/email":
                user.email = triple.object
            case "http://example.org/userId":
                user.userID = Int64(triple.object) ?? 0
            default:
                break
            }
        }

        return user
    }
}

// Usage
let migrator = DataMigrator(
    rdfStore: rdfStore,
    recordStore: recordStore,
    database: database
)

try await migrator.migrateUsers()
```

## Query Migration Examples

### Example 1: Find by Property

```swift
// RDF Layer
let results = try await rdfStore.query(
    subject: nil,
    predicate: "http://schema.org/email",
    object: "alice@example.com"
)

// Record Layer
let query = RecordQuery(
    recordType: "User",
    filter: FieldQueryComponent(
        fieldName: "email",
        comparison: .equals,
        value: "alice@example.com"
    )
)

let cursor = try await recordStore.executeQuery(query, context: context)
```

### Example 2: Range Query

```swift
// RDF Layer (not directly supported)
// Would need to fetch all and filter

// Record Layer
let query = RecordQuery(
    recordType: "User",
    filter: AndQueryComponent(children: [
        FieldQueryComponent(
            fieldName: "age",
            comparison: .greaterThanOrEquals,
            value: 18
        ),
        FieldQueryComponent(
            fieldName: "age",
            comparison: .lessThan,
            value: 65
        )
    ])
)
```

### Example 3: Complex Filter

```swift
// RDF Layer (requires multiple queries)
// Query 1: Find users in city
// Query 2: Find users with hobby
// Application logic: intersect results

// Record Layer (single query)
let query = RecordQuery(
    recordType: "User",
    filter: AndQueryComponent(children: [
        FieldQueryComponent(
            fieldName: "city",
            comparison: .equals,
            value: "San Francisco"
        ),
        FieldQueryComponent(
            fieldName: "hobbies",
            comparison: .contains,
            value: "Hiking"
        )
    ])
)
```

## Performance Considerations

### Index Design

RDF Layer has fixed indexes (SPO, PSO, POS, OSP). Record Layer allows custom indexes.

**Design indexes for your query patterns:**

```swift
// Common query: Find users by email
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email")
)

// Common query: Find users by city and age
let cityAgeIndex = Index(
    name: "user_by_city_age",
    type: .value,
    rootExpression: ConcatenateKeyExpression(children: [
        FieldKeyExpression(fieldName: "city"),
        FieldKeyExpression(fieldName: "age")
    ])
)

// Aggregation: Count users by city
let cityCountIndex = Index(
    name: "user_count_by_city",
    type: .count,
    rootExpression: FieldKeyExpression(fieldName: "city")
)
```

### Batch Operations

```swift
// RDF Layer
try await rdfStore.insertBatch(triples)

// Record Layer
try await database.withRecordContext { context in
    for record in records {
        try await recordStore.saveRecord(record, context: context)
    }
}
```

## Coexistence Strategy

You can run both layers simultaneously during migration:

```swift
actor DualStore {
    let rdfStore: RDFStore
    let recordStore: RecordStore<RecordTypeUnion>

    func saveUser(_ user: User) async throws {
        // Write to both stores
        try await recordStore.saveRecord(user, context: context)

        // Convert to triples for backward compatibility
        let triples = convertToTriples(user)
        try await rdfStore.insertBatch(triples)
    }

    private func convertToTriples(_ user: User) -> [RDFTriple] {
        let subject = "http://example.org/user/\(user.userID)"

        return [
            RDFTriple(
                subject: subject,
                predicate: "http://schema.org/name",
                object: user.name
            ),
            RDFTriple(
                subject: subject,
                predicate: "http://schema.org/email",
                object: user.email
            )
        ]
    }
}
```

## Checklist

### Pre-Migration

- [ ] Analyze current RDF data model
- [ ] Design Protobuf schema
- [ ] Define indexes for query patterns
- [ ] Create RecordMetaData
- [ ] Write migration script
- [ ] Test migration on sample data

### Migration

- [ ] Back up existing RDF data
- [ ] Run migration script
- [ ] Verify data integrity
- [ ] Test application with Record Layer
- [ ] Performance testing

### Post-Migration

- [ ] Monitor query performance
- [ ] Optimize indexes if needed
- [ ] Update application documentation
- [ ] Remove RDF Layer dependencies (if fully migrated)

## Troubleshooting

### Issue: Data Loss During Migration

**Solution:** Always back up before migrating:

```swift
// Export RDF data
let allTriples = try await rdfStore.all()
let jsonData = try JSONEncoder().encode(allTriples)
try jsonData.write(to: URL(fileURLWithPath: "backup.json"))
```

### Issue: Slow Queries After Migration

**Solution:** Add appropriate indexes:

```swift
// Analyze slow queries
// Add index for frequently queried fields
let index = Index(
    name: "optimized_index",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "frequently_queried_field")
)

// Build index online (without downtime)
let indexer = OnlineIndexer(
    store: recordStore,
    index: index,
    database: database
)
try await indexer.buildIndex()
```

### Issue: Schema Evolution

**Solution:** Use Protobuf field numbers and metadata versions:

```protobuf
// Version 1
message User {
    int64 id = 1;
    string name = 2;
}

// Version 2 (add field)
message User {
    int64 id = 1;
    string name = 2;
    string email = 3;  // New field
}
```

Update metadata version:
```swift
let metaData = try RecordMetaDataBuilder()
    .setVersion(2)  // Increment version
    // ...
    .build()
```

## Resources

- [Record Layer Architecture](ARCHITECTURE.md)
- [Getting Started Guide](Documentation/GettingStarted.md)
- [Index Guide](Documentation/Indexes.md)
- [Query Guide](Documentation/Queries.md)

## Support

If you encounter issues during migration, please:
1. Check this guide
2. Review the [Architecture documentation](ARCHITECTURE.md)
3. Check existing issues on GitHub
4. Create a new issue with details about your migration scenario
