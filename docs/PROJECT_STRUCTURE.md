# Project Structure

This document outlines the file and directory structure for the Swift implementation of FoundationDB Record Layer.

## Directory Layout

```
fdb-record-layer/
├── Package.swift                    # SPM package definition
├── README.md                        # Project overview
├── ARCHITECTURE.md                  # Architecture documentation
├── PROJECT_STRUCTURE.md            # This file
├── MIGRATION.md                    # Migration guide from RDF Layer
├── CLAUDE.md                       # Development guidelines (fdb-swift-bindings usage)
│
├── Sources/
│   └── FDBRecordLayer/
│       ├── Core/
│       │   ├── RecordMetaData.swift         # Schema definitions
│       │   ├── RecordType.swift             # Record type definitions
│       │   ├── Index.swift                  # Index definitions
│       │   ├── KeyExpression.swift          # Key extraction logic
│       │   ├── Subspace.swift               # Subspace management
│       │   └── Types.swift                  # Common types and errors
│       │
│       ├── Serialization/
│       │   ├── RecordAccess.swift           # Record access protocol
│       │   ├── GenericRecordAccess.swift    # Generic implementation (recommended)
│       │   └── Recordable.swift             # Recordable protocol
│       │
│       ├── Transaction/
│       │   ├── RecordContext.swift          # Transaction context
│       │   └── DatabaseExtensions.swift     # Convenience extensions
│       │
│       ├── Store/
│       │   ├── RecordStore.swift            # Main record store
│       │   ├── RecordStoreBuilder.swift     # Builder pattern
│       │   └── RecordStoreProtocol.swift    # Protocol definition
│       │
│       ├── Index/
│       │   ├── IndexMaintainer.swift        # Maintainer protocol
│       │   ├── ValueIndex.swift             # Value index implementation
│       │   ├── CountIndex.swift             # Count aggregation
│       │   ├── SumIndex.swift               # Sum aggregation
│       │   ├── RankIndex.swift              # Rank/leaderboard
│       │   ├── IndexState.swift             # Index state management
│       │   └── OnlineIndexer.swift          # Online index builder
│       │
│       ├── Query/
│       │   ├── RecordQuery.swift            # Query definition
│       │   ├── QueryComponent.swift         # Filter components
│       │   ├── QueryPlan.swift              # Execution plans
│       │   ├── RecordQueryPlanner.swift     # Query planner
│       │   ├── RecordCursor.swift           # Result iteration
│       │   ├── BooleanNormalizer.swift      # DNF conversion
│       │   └── PlannerConfiguration.swift   # Planner config
│       │
│       └── Utilities/
│           ├── RangeSet.swift               # Range tracking
│           ├── TupleHelpers.swift           # Tuple utilities
│           └── Logging.swift                # Logging helpers
│
├── Tests/
│   ├── FDBRecordLayerTests/
│   │   ├── Core/
│   │   │   ├── SubspaceTests.swift
│   │   │   ├── RecordMetaDataTests.swift
│   │   │   └── KeyExpressionTests.swift
│   │   │
│   │   ├── Serialization/
│   │   │   └── RecordableTests.swift
│   │   │
│   │   ├── Store/
│   │   │   ├── RecordStoreTests.swift
│   │   │   ├── RecordStoreCRUDTests.swift
│   │   │   └── RecordContextTests.swift
│   │   │
│   │   ├── Index/
│   │   │   ├── ValueIndexTests.swift
│   │   │   ├── CountIndexTests.swift
│   │   │   ├── SumIndexTests.swift
│   │   │   └── OnlineIndexerTests.swift
│   │   │
│   │   ├── Query/
│   │   │   ├── QueryPlannerTests.swift
│   │   │   ├── QueryExecutionTests.swift
│   │   │   └── RecordCursorTests.swift
│   │   │
│   │   ├── Integration/
│   │   │   ├── EndToEndTests.swift
│   │   │   ├── ConcurrencyTests.swift
│   │   │   └── PerformanceTests.swift
│   │   │
│   │   └── Fixtures/
│   │       ├── TestProtos.swift             # Test protobuf messages
│   │       ├── TestMetaData.swift           # Test schemas
│   │       └── TestHelpers.swift            # Test utilities
│   │
│   └── Resources/
│       └── test.proto                       # Test Protobuf definitions
│
├── Examples/
│   ├── SimpleRecordStore/
│   │   ├── Package.swift
│   │   ├── Sources/
│   │   │   └── main.swift                   # Basic usage example
│   │   └── Protos/
│   │       └── user.proto                   # Example schema
│   │
│   ├── QueryExample/
│   │   ├── Package.swift
│   │   └── Sources/
│   │       └── main.swift                   # Query examples
│   │
│   └── OnlineIndexExample/
│       ├── Package.swift
│       └── Sources/
│           └── main.swift                   # Index building example
│
├── Documentation/
│   ├── GettingStarted.md                    # Quick start guide
│   ├── Metadata.md                          # Metadata guide
│   ├── Indexes.md                           # Index guide
│   ├── Queries.md                           # Query guide
│   ├── OnlineIndexing.md                    # Online indexer guide
│   └── Performance.md                       # Performance tuning
│
└── Scripts/
    ├── setup.sh                             # Setup script
    ├── generate-protos.sh                   # Protobuf generation
    └── run-tests.sh                         # Test runner
```

## Module Organization

### Core Module

Foundation types and metadata management:
- `RecordMetaData`: Central schema definition
- `RecordType`: Individual record type definition
- `Index`: Index definition
- `KeyExpression`: Key extraction expressions
- `Subspace`: Key space management

### Serialization Module

Record access and serialization:
- `RecordAccess`: Protocol for record access and serialization
- `GenericRecordAccess`: Generic implementation for Recordable types (recommended)
- `Recordable`: Protocol for defining record types with field extraction

### Transaction Module

Transaction lifecycle management:
- `RecordContext`: Transaction context wrapper
- Database extensions for convenience

### Store Module

Record storage and retrieval:
- `RecordStore`: Main API for record operations
- `RecordStoreBuilder`: Builder pattern for configuration
- CRUD operations implementation

### Index Module

Index maintenance and building:
- `IndexMaintainer`: Protocol for index maintainers
- Type-specific maintainers (Value, Count, Sum, Rank)
- `OnlineIndexer`: Concurrent index building
- `IndexState`: State management

### Query Module

Query planning and execution:
- `RecordQuery`: Query definition
- `QueryComponent`: Filter predicates
- `RecordQueryPlanner`: Query optimization
- `QueryPlan`: Execution plans
- `RecordCursor`: Result iteration

### Utilities Module

Helper functions and utilities:
- `RangeSet`: Range tracking for index building
- `TupleHelpers`: Tuple encoding utilities
- Logging helpers

## File Naming Conventions

### Source Files

- Use PascalCase for file names
- Match the primary type name in the file
- One primary type per file
- Related types can be in the same file if small

Examples:
- `RecordStore.swift` - Contains `RecordStore` class
- `IndexMaintainer.swift` - Contains `IndexMaintainer` protocol and small related types
- `Types.swift` - Contains multiple small related types

### Test Files

- Mirror source file structure
- Append "Tests" to source file name
- Group related tests in subdirectories

Examples:
- `RecordStoreTests.swift` - Tests for RecordStore
- `Integration/EndToEndTests.swift` - Integration tests

### Documentation Files

- Use PascalCase for markdown files
- Clear, descriptive names
- Place in `Documentation/` directory

Examples:
- `GettingStarted.md`
- `OnlineIndexing.md`

## Import Organization

### Standard Import Order

1. Foundation/System frameworks
2. FoundationDB
3. SwiftProtobuf
4. Logging
5. Internal modules

Example:
```swift
import Foundation
import FoundationDB
import SwiftProtobuf
import Logging

// Internal imports
// (none needed if in same module)
```

## Code Organization Within Files

### Recommended Structure

```swift
// 1. Imports
import Foundation
import FoundationDB

// 2. Type Definition
/// Documentation
public struct/class/enum TypeName {

    // 3. Nested Types (if any)
    enum NestedType {
        // ...
    }

    // 4. Properties
    private let property: Type
    public var publicProperty: Type

    // 5. Initialization
    public init(...) {
        // ...
    }

    // 6. Public Methods
    public func publicMethod() {
        // ...
    }

    // 7. Internal Methods
    func internalMethod() {
        // ...
    }

    // 8. Private Methods
    private func privateMethod() {
        // ...
    }
}

// 9. Extensions
extension TypeName {
    // Related functionality
}

// 10. Protocol Conformances
extension TypeName: ProtocolName {
    // Protocol implementation
}
```

### MARK Comments

Use MARK comments to organize code:

```swift
// MARK: - Section Name
// MARK: Subsection Name
```

Example:
```swift
class RecordStore {
    // MARK: - Properties

    private let database: DatabaseProtocol

    // MARK: - Initialization

    init(database: DatabaseProtocol) {
        // ...
    }

    // MARK: - Public API

    func saveRecord() {
        // ...
    }

    // MARK: - Index Management

    private func updateIndexes() {
        // ...
    }
}
```

## Dependencies

### Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fdb-record-layer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FDBRecordLayer",
            targets: ["FDBRecordLayer"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/foundationdb/fdb-swift-bindings.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.20.0"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "FDBRecordLayer",
            dependencies: [
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "FDBRecordLayerTests",
            dependencies: ["FDBRecordLayer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

## Git Workflow

### Branch Strategy

- `main` - Stable, production-ready code
- `develop` - Integration branch for features
- `feature/*` - Feature development
- `fix/*` - Bug fixes
- `docs/*` - Documentation updates

### Commit Messages

Follow conventional commits:

```
type(scope): subject

body

footer
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `test`: Tests
- `refactor`: Code refactoring
- `perf`: Performance improvement
- `chore`: Maintenance

Examples:
```
feat(store): add batch insert support

Implement batch insert for improved performance when inserting
multiple records in a single transaction.

Closes #42
```

```
fix(index): correct count decrement in delete

The count index was not properly decrementing when records were
deleted, leading to incorrect counts.
```

## Build and Test

### Build Commands

```bash
# Build the project
swift build

# Build in release mode
swift build -c release

# Run tests
swift test

# Run specific test
swift test --filter RecordStoreTests

# Generate code coverage
swift test --enable-code-coverage
```

### Development Workflow

1. Create feature branch from `develop`
2. Implement feature with tests
3. Run tests locally
4. Update documentation
5. Create pull request to `develop`
6. Code review
7. Merge to `develop`
8. Periodic releases to `main`

## Documentation

### Code Documentation

Use Swift's documentation comments:

```swift
/// Brief description of the type or function.
///
/// Detailed description with multiple paragraphs if needed.
/// Use markdown for formatting.
///
/// ## Usage
///
/// ```swift
/// let store = RecordStore(...)
/// try await store.saveRecord(record)
/// ```
///
/// - Parameters:
///   - parameter: Description of parameter
///   - another: Description of another parameter
/// - Returns: Description of return value
/// - Throws: Description of errors that can be thrown
/// - Note: Additional notes
/// - Warning: Important warnings
/// - SeeAlso: Related types or functions
public func functionName(parameter: Type, another: Type) throws -> ReturnType {
    // ...
}
```

### README Structure

Each major module should have a README:

```markdown
# Module Name

Brief description.

## Overview

Detailed overview of the module.

## Key Types

- `TypeName`: Description
- `AnotherType`: Description

## Usage

Example code showing common usage patterns.

## See Also

Links to related documentation.
```

## Performance Considerations

### Key Files for Performance

- `RecordStore.swift` - CRUD operation hot path
- `IndexMaintainer.swift` - Index update hot path
- `RecordCursor.swift` - Query result iteration
- `Subspace.swift` - Key encoding/decoding

### Profiling

Profile these operations:
- Batch inserts
- Index scans
- Query planning
- Serialization/deserialization

### Benchmarks

Maintain benchmarks in `Tests/Integration/PerformanceTests.swift`

## Continuous Integration

### GitHub Actions

```yaml
# .github/workflows/swift.yml
name: Swift

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest

    steps:
    - uses: actions/checkout@v2
    - name: Install FoundationDB
      run: |
        # Install FDB
    - name: Build
      run: swift build
    - name: Run tests
      run: swift test
```

## Release Process

1. Update version in `Package.swift`
2. Update `CHANGELOG.md`
3. Create release branch: `release/vX.Y.Z`
4. Run full test suite
5. Merge to `main`
6. Tag release: `git tag vX.Y.Z`
7. Create GitHub release with notes
8. Announce release

## Maintenance

### Regular Tasks

- Update dependencies quarterly
- Review and close stale issues
- Update documentation for API changes
- Performance regression testing
- Security audit

### Deprecation Policy

- Mark as deprecated with `@available` attribute
- Provide migration path in documentation
- Remove after 2 major versions
