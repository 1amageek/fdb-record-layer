# FoundationDB Record Layer Documentation

**Last Updated:** 2025-01-17
**Version:** 3.0 (Production-Ready - Vector Search & Spatial Indexing Complete)

Welcome to the FoundationDB Record Layer documentation! This directory contains all technical documentation for the Swift implementation.

---

## 📚 Quick Navigation

### 🚀 Getting Started

- [../README.md](../README.md) - Project overview and quick start
- [../Examples/](../Examples/) - Code examples and usage patterns

### 📊 Project Status

- [../CLAUDE.md](../CLAUDE.md) - **Complete development guide** with current status, roadmap, and implementation details
- [../README.md](../README.md) - Project overview with feature status

### 🏗️ Architecture

- [ARCHITECTURE.md](ARCHITECTURE.md) - **START HERE** - System architecture overview
  - System components and layers
  - Concurrency model (why Mutex, not Actor)
  - Multi-tenant architecture
  - Index system design
  - Query system design

### 📖 Design Documents

Detailed design specifications for major features:

- [design/swift-macro-design.md](design/swift-macro-design.md) - SwiftData-style macro API
- [design/directory-layer-design.md](design/directory-layer-design.md) - Directory Layer and multi-tenant architecture
- [design/query-planner-optimization.md](design/query-planner-optimization.md) - Cost-based query optimizer
- [design/metrics-and-logging.md](design/metrics-and-logging.md) - Observability infrastructure
- [design/online-index-scrubber.md](design/online-index-scrubber.md) - Index consistency verification
- [design/metadata-evolution-validator.md](design/metadata-evolution-validator.md) - Schema evolution safety
- [vector_search_optimization_design.md](vector_search_optimization_design.md) - **HNSW Vector Search** (O(log n) nearest neighbor)
- [spatial-index-complete-implementation.md](spatial-index-complete-implementation.md) - **Spatial Indexing** (S2 + Morton Code)
- [design/vector-spatial-macros-design.md](design/vector-spatial-macros-design.md) - @Spatial macro API design

### 📘 User Guides

How-to guides for specific features:

- [guides/getting-started.md](guides/getting-started.md) - Getting started with Record Layer
- [guides/macro-usage-guide.md](guides/macro-usage-guide.md) - Using @Recordable macro API
- [guides/partition-usage.md](guides/partition-usage.md) - Multi-tenant usage patterns
- [guides/query-optimizer.md](guides/query-optimizer.md) - Query optimization guide
- [guides/advanced-index-design.md](guides/advanced-index-design.md) - Index design patterns
- [guides/versionstamp-usage.md](guides/versionstamp-usage.md) - Using version stamps
- [guides/tuple-versionstamp.md](guides/tuple-versionstamp.md) - Tuple with versionstamp
- [guides/best-practices.md](guides/best-practices.md) - Best practices and patterns

---

## 🎯 Documentation by Use Case

### "I'm new to Record Layer"
→ Start with [guides/getting-started.md](guides/getting-started.md)

### "I want to use the macro API"
→ Read [guides/macro-usage-guide.md](guides/macro-usage-guide.md) and [design/swift-macro-design.md](design/swift-macro-design.md)

### "I want to understand the system architecture"
→ Read [ARCHITECTURE.md](ARCHITECTURE.md)

### "I want to build a multi-tenant application"
→ Read [design/directory-layer-design.md](design/directory-layer-design.md) and [guides/partition-usage.md](guides/partition-usage.md)

### "I want to optimize my queries"
→ Read [guides/query-optimizer.md](guides/query-optimizer.md)

### "I want to design indexes efficiently"
→ Read [guides/advanced-index-design.md](guides/advanced-index-design.md)

### "I want to follow best practices"
→ Read [guides/best-practices.md](guides/best-practices.md)

### "I want to see examples"
→ Browse [../Examples/](../Examples/)

### "I want to know what's coming next"
→ Read [../CLAUDE.md](../CLAUDE.md) - See roadmap section at the end

---

## 📦 Document Categories

### Status & Planning
```
../CLAUDE.md                     - Complete development guide (status, roadmap, implementation)
../README.md                     - Project overview
```

### Architecture (1 doc)
```
ARCHITECTURE.md                  - System architecture
```

### Design (6 docs)
```
design/
├── swift-macro-design.md        - Macro API
├── directory-layer-design.md    - Directory Layer & Multi-tenant
├── query-planner-optimization.md - Query optimizer
├── metrics-and-logging.md       - Observability
├── online-index-scrubber.md     - Index scrubbing
└── metadata-evolution-validator.md - Schema evolution
```

### Guides (8 docs)
```
guides/
├── getting-started.md           - Getting started guide
├── macro-usage-guide.md         - Macro API guide
├── partition-usage.md           - Multi-tenant usage
├── query-optimizer.md           - Query optimization
├── advanced-index-design.md     - Index design
├── versionstamp-usage.md        - Version stamps
├── tuple-versionstamp.md        - Tuple + versionstamp
└── best-practices.md            - Best practices
```

### Reference (8 docs)
```
api-reference.md                 - API reference documentation
design-principles.md             - Design principles and philosophy
index.md                         - Documentation index
JAVA_COMPARISON.md               - Comparison with Java Record Layer
storage-design.md                - Storage layer design
swift-query-features-design.md   - Query features design
SQL_QUERY_DESIGN.md              - Future SQL support design
TEST_ISOLATION_GUIDE.md          - Test isolation patterns
```

---

## 🔍 Key Features Documentation

### Type-Safe API (@Recordable Macro) - 100% Complete ✅
- Design: [design/swift-macro-design.md](design/swift-macro-design.md)
- Examples: [../Examples/User+Recordable.swift](../Examples/User+Recordable.swift)
- Status: **Fully implemented** - All macros complete (@Recordable, @PrimaryKey, #Index, #Unique, #Directory, @Relationship, @Default, @Transient, @Spatial)
- Features: Auto-generated store() methods, multi-tenant support with #Directory, SwiftData-style API

### Vector Search (HNSW) - 100% Complete ✅
- Design: [vector_search_optimization_design.md](vector_search_optimization_design.md)
- Implementation: [hnsw_implementation_verification.md](hnsw_implementation_verification.md)
- Status: **Fully implemented** - O(log n) nearest neighbor search
- Features: HNSW algorithm, OnlineIndexer integration, auto strategy selection, 3 distance metrics (cosine, l2, innerProduct)

### Spatial Indexing (S2 + Morton Code) - 100% Complete ✅
- Design: [spatial-index-complete-implementation.md](spatial-index-complete-implementation.md)
- Macro Guide: [spatial-macro-keypath-guide.md](spatial-macro-keypath-guide.md)
- Status: **Fully implemented** - 4 spatial types (.geo, .geo3D, .cartesian, .cartesian3D)
- Features: S2 Geometry (Hilbert curve), Morton Code (Z-order curve), Geohash, dynamic precision selection

### Directory Layer & Multi-Tenant Architecture - 100% Complete ✅
- Design: [design/directory-layer-design.md](design/directory-layer-design.md)
- Usage: [guides/partition-usage.md](guides/partition-usage.md)
- Status: Using FoundationDB standard Directory Layer with `layer: .partition`

### Query Optimization - 100% Complete ✅
- Design: [design/query-planner-optimization.md](design/query-planner-optimization.md)
- Usage: [guides/query-optimizer.md](guides/query-optimizer.md)
- Features: Cost-based planner, Covering Index detection, IN-join optimization

### Index Management - 100% Complete ✅
- Design: [design/online-index-scrubber.md](design/online-index-scrubber.md)
- Usage: [guides/advanced-index-design.md](guides/advanced-index-design.md)
- Features: Online indexing, index scrubbing, RangeSet progress tracking

### Migration Manager - 100% Complete ✅
- Implementation: Complete with 24 tests passing
- Features: Schema evolution, lightweight migration, multi-step migration, idempotent execution

### Observability - 100% Complete ✅
- Design: [design/metrics-and-logging.md](design/metrics-and-logging.md)

---

## 📝 Documentation Standards

All documentation in this repository follows these standards:

1. **Last Updated Date**: Every document includes a "Last Updated" date
2. **Status Indicator**: Documents marked as ✅ Current, ⚠️ Outdated, or 🚧 In Progress
3. **Clear Structure**: Table of contents for long documents
4. **Code Examples**: Swift code blocks with syntax highlighting
5. **Cross-References**: Links to related documents

---

## 🤝 Contributing

When adding or updating documentation:

1. ✅ Add "Last Updated" date at the top
2. ✅ Update this README if adding new documents
3. ✅ Follow the naming convention: `kebab-case.md`
4. ✅ Place in appropriate directory (design/ or guides/)
5. ✅ Add cross-references to related documents

---

## 📚 External Resources

### FoundationDB
- [Official Documentation](https://apple.github.io/foundationdb/)
- [CLAUDE.md](../CLAUDE.md) - Comprehensive FoundationDB usage guide
- [DeepWiki: FoundationDB](https://deepwiki.com/apple/foundationdb)

### Record Layer (Java)
- [Java Implementation](https://foundationdb.github.io/fdb-record-layer/)
- [DeepWiki: Record Layer](https://deepwiki.com/FoundationDB/fdb-record-layer)

### Swift
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Swift Macros](https://docs.swift.org/swift-book/LanguageGuide/Macros.html)

---

**Maintained by:** Claude Code
**Last Major Update:** 2025-01-17 (Phase 6 Complete - Vector Search & Spatial Indexing, **525 Tests Passing**)
