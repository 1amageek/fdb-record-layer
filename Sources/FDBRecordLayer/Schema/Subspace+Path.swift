import Foundation
import FoundationDB
import Synchronization

extension Subspace {
    /// Path cache for performance optimization
    private static let pathCache = Mutex<[String: Subspace]>([:])

    /// Creates a subspace from a Firestore-style path string.
    ///
    /// The path string is split by "/" separators, with each component becoming
    /// a tuple element at the same level. Results are cached for performance.
    ///
    /// Example:
    /// ```swift
    /// let subspace = Subspace(path: "accounts/acct-001/users")
    /// // Equivalent to: Subspace with prefix Tuple("accounts", "acct-001", "users")
    /// ```
    ///
    /// **Key Structure**: Each path component becomes a TupleElement at the same level:
    /// - Correct: `("accounts", "acct-001", "users")`
    /// - Wrong: `("", Tuple(["accounts"]), Tuple(["acct-001"]), ...)`
    ///
    /// - Parameter path: Path string using "/" as separator
    public init(path: String) {
        // Check cache
        if let cached = Self.pathCache.withLock({ $0[path] }) {
            self = cached
            return
        }

        // Parse path components
        let components = path.split(separator: "/").map(String.init)

        // Start with empty byte array (not empty string tuple)
        var subspace = Subspace(prefix: [])

        // Add each component as a direct TupleElement (not nested Tuple)
        for component in components {
            subspace = subspace.subspace(component)  // String conforms to TupleElement
        }

        // Cache result
        Self.pathCache.withLock { $0[path] = subspace }

        self = subspace
    }

    /// Clear the path parsing cache
    ///
    /// Useful for testing or memory management when the cache grows too large.
    public static func clearCache() {
        pathCache.withLock { $0.removeAll() }
    }

    /// Current number of cached paths
    public static var cacheSize: Int {
        pathCache.withLock { $0.count }
    }
}
