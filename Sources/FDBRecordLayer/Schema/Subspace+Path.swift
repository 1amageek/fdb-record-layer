import Foundation
import FoundationDB
import Synchronization

extension Subspace {
    /// Path cache for performance optimization
    private static let pathCache = Mutex<[String: Subspace]>([:])

    /// Create Subspace from Firestore-style path string
    ///
    /// - Parameter path: Path string (e.g., "accounts/acct-001/users")
    /// - Returns: Subspace
    ///
    /// **Example usage**:
    /// ```swift
    /// let subspace = Subspace.fromPath("accounts/acct-001/users")
    /// // → Subspace(["accounts", "acct-001", "users"])
    /// ```
    ///
    /// **Performance**: Path parsing results are cached for efficiency.
    public static func fromPath(_ path: String) -> Subspace {
        // Check cache
        if let cached = pathCache.withLock({ $0[path] }) {
            return cached
        }

        // Parse path
        let components = path.split(separator: "/").map(String.init)
        var subspace = Subspace(rootPrefix: "")
        for component in components {
            subspace = subspace.subspace(Tuple([component]))
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
