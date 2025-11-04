# FoundationDB Record Layer - Examples

This directory contains practical examples demonstrating how to use the FDB Record Layer.

## Prerequisites

1. **FoundationDB**: Install and run FoundationDB locally
   ```bash
   brew install foundationdb
   brew services start foundationdb
   ```

2. **Protocol Buffers Compiler**: Install `protoc`
   ```bash
   brew install protobuf
   ```

3. **Swift Protobuf Plugin**: Install the Swift plugin for protoc
   ```bash
   brew install swift-protobuf
   ```

## Running the Simple Example

### Step 1: Generate Swift Code from Protobuf

```bash
cd Examples
protoc --swift_out=. User.proto
```

This will generate `User.pb.swift` containing the Swift structs for `User` and `RecordTypeUnion`.

**Note**: Generated `.pb.swift` files are ignored by git (see `.gitignore`).

### Step 2: Run the Example

```bash
swift run SimpleExample
```

### Expected Output

```
FDB Record Layer - Simple Example (Protobuf)
==============================================

1. Initializing FoundationDB...
   ✓ Connected to FoundationDB

2. Defining metadata...
   ✓ Metadata created with 2 indexes

3. Creating record store...
   ✓ Record store created

4. Inserting records...
   ✓ Inserted 3 records

5. Loading record by primary key (user_id = 1)...
   ✓ Record loaded:
     - ID: 1
     - Name: Alice
     - Email: alice@example.com
     - Age: 30

6. Querying records (age >= 30)...
   Query results:
     - Alice (age: 30, email: alice@example.com)
     - Charlie (age: 35, email: charlie@example.com)
   ✓ Found 2 record(s)

7. Querying by email index (email = 'bob@example.com')...
   Query results:
     - Found: Bob (user_id: 2)

8. Deleting record (user_id = 2)...
   ✓ Record deleted

9. Verifying deletion...
   ✓ Record successfully deleted

Example completed successfully!

Key Takeaways:
  • Use Protobuf for type-safe record definitions
  • Indexes are automatically maintained
  • Queries use indexes when available
  • All operations are ACID transactions
```

## What the Example Demonstrates

### 1. Schema Definition (User.proto)

```protobuf
message User {
    int64 user_id = 1;
    string name = 2;
    string email = 3;
    int64 age = 4;
}

message RecordTypeUnion {
    oneof record {
        User user = 1;
    }
}
```

- Defines a `User` message type with 4 fields
- Defines a union type for all record types in the database

### 2. Type-Safe Record Creation

```swift
let alice = User.with {
    $0.userID = 1
    $0.name = "Alice"
    $0.email = "alice@example.com"
    $0.age = 30
}
```

- Uses SwiftProtobuf's `.with` style for initialization
- Type-safe: compiler checks field names and types

### 3. Metadata and Indexes

```swift
let emailIndex = Index(
    name: "user_by_email",
    type: .value,
    rootExpression: FieldKeyExpression(fieldName: "email")
)

let metaData = try RecordMetaDataBuilder()
    .setVersion(1)
    .addRecordType(userType)
    .addIndex(emailIndex)
    .build()
```

- Defines indexes on `email` and `age` fields
- Indexes are automatically maintained on insert/update/delete

### 4. CRUD Operations

```swift
// Create
try await recordStore.saveRecord(alice, context: context)

// Read
let user = try await recordStore.loadRecord(
    primaryKey: Tuple(Int64(1)),
    context: context
)

// Delete
try await recordStore.deleteRecord(
    primaryKey: Tuple(Int64(2)),
    context: context
)
```

### 5. Querying

```swift
let query = RecordQuery(
    recordType: "User",
    filter: FieldQueryComponent(
        fieldName: "age",
        comparison: .greaterThanOrEquals,
        value: Int64(30)
    )
)

let cursor = try await recordStore.executeQuery(query, context: context)
for try await user in cursor {
    print(user.name)
}
```

- Query planner automatically selects appropriate index
- Streaming results with async/await
- Strongly-typed results (returns `User` type)

## File Structure

```
Examples/
├── README.md              # This file
├── User.proto            # Protobuf schema definition
├── User.pb.swift         # Generated (gitignored)
└── SimpleExample.swift   # Example code
```

## Next Steps

After running the simple example, explore:

1. **Add more indexes**: Try creating compound indexes
   ```swift
   let compoundIndex = Index(
       name: "user_by_name_age",
       type: .value,
       rootExpression: ConcatenateKeyExpression(children: [
           FieldKeyExpression(fieldName: "name"),
           FieldKeyExpression(fieldName: "age")
       ])
   )
   ```

2. **Aggregate indexes**: Use COUNT or SUM indexes
   ```swift
   let countIndex = Index(
       name: "user_count_by_age",
       type: .count,
       rootExpression: FieldKeyExpression(fieldName: "age")
   )
   ```

3. **Complex queries**: Combine multiple filters
   ```swift
   let complexQuery = RecordQuery(
       recordType: "User",
       filter: AndQueryComponent(children: [
           FieldQueryComponent(fieldName: "age", comparison: .greaterThan, value: 25),
           FieldQueryComponent(fieldName: "email", comparison: .startsWith, value: "alice")
       ])
   )
   ```

## Troubleshooting

### FoundationDB Connection Error

```
Error: Could not connect to FoundationDB
```

**Solution**: Ensure FoundationDB is running
```bash
brew services start foundationdb
# Verify it's running
fdbcli
```

### Protobuf Generation Error

```
Error: protoc: command not found
```

**Solution**: Install protobuf compiler
```bash
brew install protobuf swift-protobuf
```

### Import Error

```
Error: No such module 'SwiftProtobuf'
```

**Solution**: SwiftProtobuf should be included as a dependency in `Package.swift`

## Further Reading

- [Main README](../README.md) - Full project documentation
- [FoundationDB Documentation](https://apple.github.io/foundationdb/)
- [SwiftProtobuf Guide](https://github.com/apple/swift-protobuf)
- [Record Layer Architecture](../docs/ARCHITECTURE.md)
