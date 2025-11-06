import Foundation
import FoundationDB
import Synchronization

extension Subspace {
    /// Path cache for performance optimization
    private static let pathCache = Mutex<[String: Subspace]>([:])

    /// Create Subspace from Firestore-style path string
    ///
    /// - Parameter path: Path string (e.g., "accounts/acct-001/users")
    /// - Returns: Subspace with prefix tuple ("accounts", "acct-001", "users")
    ///
    /// **Example usage**:
    /// ```swift
    /// let subspace = Subspace.fromPath("accounts/acct-001/users")
    /// // → Subspace with prefix: Tuple("accounts", "acct-001", "users")
    /// ```
    ///
    /// **Key Structure**: Each path component becomes a TupleElement at the same level:
    /// - ✅ Correct: `("accounts", "acct-001", "users")`
    /// - ❌ Wrong: `("", Tuple(["accounts"]), Tuple(["acct-001"]), ...)`
    ///
    /// **Performance**: Path parsing results are cached for efficiency.
    public static func fromPath(_ path: String) -> Subspace {
        // Check cache
        if let cached = pathCache.withLock({ $0[path] }) {
            return cached
        }

        // Parse path components
        let components = path.split(separator: "/").map(String.init)

        // ✅ Start with empty byte array (not empty string tuple)
        var subspace = Subspace(prefix: [])

        // ✅ Add each component as a direct TupleElement (not nested Tuple)
        for component in components {
            subspace = subspace.subspace(component)  // String conforms to TupleElement
        }

        // Cache result
        pathCache.withLock { $0[path] = subspace }

        return subspace
    }

    /// Clear path cache (for testing or memory management)
    public static func clearPathCache() {
        pathCache.withLock { $0.removeAll() }
    }

    /// Get path cache size
    public static func pathCacheSize() -> Int {
        return pathCache.withLock { $0.count }
    }
}
