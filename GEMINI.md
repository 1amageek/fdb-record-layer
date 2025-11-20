# Gemini Code Assistant Context

This document provides context for the Gemini AI code assistant to understand the `fdb-record-layer` project.

## Project Overview

The `fdb-record-layer` is a Swift library that provides a type-safe, structured layer on top of FoundationDB. It is inspired by Apple's own [Java-based Record Layer](https://foundationdb.github.io/fdb-record-layer/) and aims to provide a modern, Swift-native developer experience.

The core idea is to allow developers to define their data models once using Swift structs and have them seamlessly work for both client-side (iOS/macOS) applications (e.g., decoding from JSON) and server-side persistence with FoundationDB.

### Key Features

*   **Model Sharing:** A single `@Recordable` struct definition works across client and server. `FDBRecordCore` is a lightweight module for client-side use, while `FDBRecordLayer` provides full server-side capabilities.
*   **Type Safety:** Leverages Swift's type system and macros (`@Recordable`, `#PrimaryKey`, `#Index`) to provide compile-time safety for database operations, queries, and migrations.
*   **Modern API:** The API is inspired by SwiftData, offering a familiar feel with `RecordContext` for change tracking and a `QueryBuilder` for fluent, type-safe queries.
*   **Rich Indexing:** Supports a wide variety of index types, including `VALUE`, `COUNT`, `SUM`, `VECTOR` (for HNSW-based semantic search), and `SPATIAL` (for location-based queries).
*   **High Performance:** The concurrency model is built on `Mutex` rather than `Actor` for fine-grained locking and higher throughput.
*   **Multi-Tenancy:** Built-in support for data isolation using FoundationDB's partition layer, managed via a `PartitionManager`.
*   **Production Ready:** The project is designed for production use, with a focus on comprehensive testing, error handling, and Swift 6 concurrency compliance.

### Architecture

The system is layered:

1.  **Application Layer:** Defines models using `@Recordable` structs.
2.  **Record Store Layer:** The `RecordContext` and `RecordStore<T>` provide the main API for CRUD operations and querying. The `PartitionManager` handles multi-tenant data isolation.
3.  **Query & Index Layer:** A cost-based `TypedRecordQueryPlanner` optimizes queries. The `IndexManager` handles automatic index maintenance. Online (zero-downtime) index building and scrubbing are supported.
4.  **FoundationDB Layer:** Handles Tuple encoding/decoding and transaction management.
5.  **FoundationDB Cluster:** The underlying distributed, ACID-compliant database.

## Building and Running

The project uses Swift Package Manager (SPM).

*   **Build the project:**
    ```bash
    swift build
    ```

*   **Run tests:**
    ```bash
    swift test
    ```

*   **FoundationDB Dependency (Server-side):**
    The `FDBRecordLayer` target requires FoundationDB to be installed. On macOS, this can be done via Homebrew:
    ```bash
    brew install foundationdb
    sudo launchctl start com.foundationdb.fdbserver
    fdbcli --exec "status"
    ```

## Development Conventions

The project has extensive coding guidelines (see `CODING_GUIDELINES.md`), with a strong emphasis on:

*   **Clarity and Type Safety:** Prioritize clear, explicit, and type-safe code over cleverness. `Sendable` conformance is strictly managed.
*   **API Design:** Follow Swift API Design Guidelines. Keep the public API surface minimal and well-documented.
*   **Performance:** Performance optimizations must be justified with benchmarks. `unsafe` code is avoided unless absolutely necessary and well-reasoned.
*   **Error Handling:** Use typed `throws` where possible. Fatal errors are avoided in library code; instead, descriptive errors are thrown.
*   **Testing:** Tests must be reproducible, independent, and cover a wide range of cases including edge conditions and error paths.
*   **Documentation:** All public APIs must have comprehensive DocC comments with valid code examples. Complex implementation details should have explanatory comments.
*   **Asynchronous Code:** The project uses a `final class + Mutex` pattern for managing shared state in concurrent environments, preferring it over `Actor` for higher I/O throughput.

## Key Files and Directories

*   `Package.swift`: Defines the SPM package, targets (`FDBRecordCore`, `FDBRecordLayer`, `FDBRecordLayerMacros`), and dependencies.
*   `README.md`: High-level introduction, quick start guide, and feature overview.
*   `docs/ARCHITECTURE.md`: The definitive guide to the system's architecture, components, and design decisions.
*   `CODING_GUIDELINES.md`: Detailed Swift coding style, best practices, and patterns to follow.
*   `Sources/`: Contains the source code for the three main targets.
    *   `Sources/FDBRecordCore/`: The lightweight, client-side library. Contains core protocols like `Recordable`.
    *   `Sources/FDBRecordLayer/`: The full, server-side library with FoundationDB integration.
        *   `Context/RecordContext.swift`: The main entry point for a SwiftData-like user experience.
        *   `Store/RecordStore.swift`: The primary interface for record operations on a specific type.
        *   `Index/`: Contains implementations for all index types (Value, Vector, Spatial, etc.).
        *   `Query/`: Home to the query planner, cost estimator, and query execution logic.
    *   `Sources/FDBRecordLayerMacros/`: Implementation of the Swift macros (`@Recordable`, `@PrimaryKey`, etc.).
*   `Tests/`: Contains the unit and integration tests for the project, using the `swift-testing` library.
