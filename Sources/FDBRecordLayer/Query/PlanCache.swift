import Foundation

// MARK: - CacheKeyable Protocol

/// Protocol for generating stable cache keys
///
/// Types conforming to this protocol can generate deterministic,
/// memory-address-independent cache keys for plan caching.
public protocol CacheKeyable {
    /// Generate a stable cache key
    /// - Returns: A string that uniquely identifies this object's value (not its address)
    func cacheKey() -> String
}

// MARK: - Plan Cache

/// Cache for query execution plans
///
/// Caches optimized plans to avoid re-planning identical queries.
/// Uses stable cache keys to ensure correctness across runs.
public actor PlanCache<Record: Sendable> {
    private var cache: [String: CachedPlan] = [:]
    private let maxSize: Int

    struct CachedPlan {
        let plan: any TypedQueryPlan<Record>
        let cost: QueryCost
        let timestamp: Date
        var hitCount: Int
    }

    public init(maxSize: Int = 1000) {
        self.maxSize = maxSize
    }

    // MARK: - Public API

    /// Get cached plan for query
    ///
    /// - Parameter query: The query to look up
    /// - Returns: The cached plan if available
    public func get(query: TypedRecordQuery<Record>) -> (any TypedQueryPlan<Record>)? {
        let key = cacheKey(query: query)

        guard var cached = cache[key] else {
            return nil
        }

        // Update hit count
        cached.hitCount += 1
        cache[key] = cached

        return cached.plan
    }

    /// Store plan in cache
    ///
    /// - Parameters:
    ///   - query: The query
    ///   - plan: The execution plan
    ///   - cost: The estimated cost
    public func put(
        query: TypedRecordQuery<Record>,
        plan: any TypedQueryPlan<Record>,
        cost: QueryCost
    ) {
        let key = cacheKey(query: query)

        // Evict if cache is full
        if cache.count >= maxSize {
            evictLRU()
        }

        cache[key] = CachedPlan(
            plan: plan,
            cost: cost,
            timestamp: Date(),
            hitCount: 0
        )
    }

    /// Clear all cached plans
    public func clear() {
        cache.removeAll()
    }

    /// Get cache statistics
    public func getStats() -> CacheStats {
        let totalHits = cache.values.reduce(0) { $0 + $1.hitCount }
        let avgHits = cache.isEmpty ? 0.0 : Double(totalHits) / Double(cache.count)

        return CacheStats(
            size: cache.count,
            totalHits: totalHits,
            avgHits: avgHits,
            maxSize: maxSize
        )
    }

    // MARK: - Private Helpers

    /// Generate stable cache key for query
    private func cacheKey(query: TypedRecordQuery<Record>) -> String {
        var components: [String] = []

        // Filter component
        if let filter = query.filter as? CacheKeyable {
            components.append("f:\(filter.cacheKey())")
        }

        // Limit component
        if let limit = query.limit {
            components.append("l:\(limit)")
        }

        // Sort component
        if let sortKeys = query.sort, !sortKeys.isEmpty {
            let sortString = sortKeys.map { sortKey in
                "\(sortKey.fieldName):\(sortKey.ascending ? "asc" : "desc")"
            }.joined(separator: ",")
            components.append("s:\(sortString)")
        }

        // Generate hash for efficient lookup
        let keyString = components.joined(separator: "|")
        return keyString.stableHash()
    }

    /// Evict least recently used entry
    private func evictLRU() {
        guard let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) else {
            return
        }
        cache.removeValue(forKey: oldest.key)
    }
}

// MARK: - Cache Statistics

/// Statistics about plan cache performance
public struct CacheStats: Sendable {
    /// Current cache size
    public let size: Int

    /// Total cache hits across all entries
    public let totalHits: Int

    /// Average hits per entry
    public let avgHits: Double

    /// Maximum cache size
    public let maxSize: Int

    /// Cache hit rate (approximate, based on hits vs size)
    public var estimatedHitRate: Double {
        guard size > 0 else { return 0.0 }
        return Double(totalHits) / Double(size + totalHits)
    }
}

// MARK: - String Extensions

extension String {
    /// Generate stable hash that doesn't depend on memory addresses
    ///
    /// Uses FNV-1a algorithm to ensure deterministic hashing across runs.
    /// Unlike Swift's built-in Hasher, this produces the same hash value
    /// for the same input string across different program executions.
    func stableHash() -> String {
        var hasher = StableHasher()
        hasher.combine(self)
        return "\(hasher.finalize())"
    }
}

// MARK: - StableHasher

/// A hasher that produces stable, deterministic hashes
///
/// Unlike Swift's built-in Hasher, this produces the same hash value
/// across different runs of the program, which is essential for
/// plan caching that needs to persist across runs.
private struct StableHasher {
    private var state: UInt64 = 0xcbf29ce484222325 // FNV-1a offset basis

    mutating func combine(_ value: String) {
        let bytes = value.utf8
        for byte in bytes {
            state ^= UInt64(byte)
            state = state &* 0x100000001b3 // FNV-1a prime
        }
    }

    func finalize() -> UInt64 {
        return state
    }
}

// MARK: - CacheKeyable Implementations

extension TypedFieldQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        let valueDesc = valueDescription(value)
        return "field:\(fieldName):\(comparison):\(valueDesc)"
    }

    private func valueDescription(_ value: any TupleElement) -> String {
        if let str = value as? String {
            return "\"\(str)\""
        } else if let int = value as? Int64 {
            return "\(int)"
        } else if let int = value as? Int {
            return "\(int)"
        } else if let double = value as? Double {
            return "\(double)"
        } else if let bool = value as? Bool {
            return "\(bool)"
        } else {
            return "null"
        }
    }
}

extension TypedAndQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        let childKeys = children
            .compactMap { $0 as? CacheKeyable }
            .map { $0.cacheKey() }
            .sorted()  // Canonical ordering
            .joined(separator: ",")
        return "and:[\(childKeys)]"
    }
}

extension TypedOrQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        let childKeys = children
            .compactMap { $0 as? CacheKeyable }
            .map { $0.cacheKey() }
            .sorted()  // Canonical ordering
            .joined(separator: ",")
        return "or:[\(childKeys)]"
    }
}

extension TypedNotQueryComponent: CacheKeyable {
    public func cacheKey() -> String {
        let childKey = (child as? CacheKeyable)?.cacheKey() ?? "unknown"
        return "not:\(childKey)"
    }
}
