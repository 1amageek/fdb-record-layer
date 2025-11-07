# FoundationDB Record Layer Documentation

**Last Updated:** 2025-01-15
**Version:** 2.0 (Phase 2a Complete)

Welcome to the FoundationDB Record Layer documentation! This directory contains all technical documentation for the Swift implementation.

---

## 📚 Quick Navigation

### 🚀 Getting Started

- [../README.md](../README.md) - Project overview and quick start
- [../Examples/](../Examples/) - Code examples and usage patterns

### 📊 Project Status

- [STATUS.md](STATUS.md) - Current project status and features
- [REMAINING_WORK.md](REMAINING_WORK.md) - Roadmap and planned features
- [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) - Detailed implementation plan

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
- [design/metadata-evolution-validator.md](design/metadata-evolution-validator.md) - Schema evolution safety (planned)

### 📘 User Guides

How-to guides for specific features:

- [guides/partition-usage.md](guides/partition-usage.md) - Multi-tenant usage patterns
- [guides/query-optimizer.md](guides/query-optimizer.md) - Query optimization guide
- [guides/advanced-index-design.md](guides/advanced-index-design.md) - Index design patterns
- [guides/versionstamp-usage.md](guides/versionstamp-usage.md) - Using version stamps
- [guides/tuple-versionstamp.md](guides/tuple-versionstamp.md) - Tuple with versionstamp

---

## 🎯 Documentation by Use Case

### "I want to understand the system architecture"
→ Read [ARCHITECTURE.md](ARCHITECTURE.md)

### "I want to build a multi-tenant application"
→ Read [design/directory-layer-design.md](design/directory-layer-design.md) and [guides/partition-usage.md](guides/partition-usage.md)

### "I want to optimize my queries"
→ Read [guides/query-optimizer.md](guides/query-optimizer.md)

### "I want to design indexes efficiently"
→ Read [guides/advanced-index-design.md](guides/advanced-index-design.md)

### "I want to understand the macro API"
→ Read [design/swift-macro-design.md](design/swift-macro-design.md)

### "I want to see examples"
→ Browse [../Examples/](../Examples/)

### "I want to know what's coming next"
→ Read [REMAINING_WORK.md](REMAINING_WORK.md)

---

## 📦 Document Categories

### Status & Planning (3 docs)
```
STATUS.md                        - Project status
REMAINING_WORK.md                - Roadmap
IMPLEMENTATION_ROADMAP.md        - Implementation plan
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

### Guides (5 docs)
```
guides/
├── partition-usage.md           - Multi-tenant usage
├── query-optimizer.md           - Query optimization
├── advanced-index-design.md     - Index design
├── versionstamp-usage.md        - Version stamps
└── tuple-versionstamp.md        - Tuple + versionstamp
```

---

## 🔍 Key Features Documentation

### Type-Safe API (@Recordable Macro) - 95% Complete
- Design: [design/swift-macro-design.md](design/swift-macro-design.md)
- Examples: [../Examples/User+Recordable.swift](../Examples/User+Recordable.swift)
- Status: Core macros complete (@Recordable, @PrimaryKey, #Index, @Relationship)
- Note: Protobuf definitions are created manually for multi-language compatibility

### Directory Layer & Multi-Tenant Architecture
- Design: [design/directory-layer-design.md](design/directory-layer-design.md)
- Usage: [guides/partition-usage.md](guides/partition-usage.md)
- Status: Using FoundationDB standard Directory Layer with `layer: .partition`

### Query Optimization
- Design: [design/query-planner-optimization.md](design/query-planner-optimization.md)
- Usage: [guides/query-optimizer.md](guides/query-optimizer.md)

### Index Management
- Design: [design/online-index-scrubber.md](design/online-index-scrubber.md)
- Usage: [guides/advanced-index-design.md](guides/advanced-index-design.md)

### Observability
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
**Last Major Update:** 2025-01-15 (Phase 2a Documentation Reorganization)
