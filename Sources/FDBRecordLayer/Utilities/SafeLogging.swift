import Foundation
import FoundationDB
import CryptoKit

// MARK: - Safe Logging Extensions

/// Extensions for safe logging without exposing PII
extension FDB.Bytes {
    /// Safe representation for logging
    ///
    /// Only displays the first 8 bytes and SHA256 hash, hiding the middle portion.
    /// This allows keys that may contain PII (Personally Identifiable Information) to be safely logged.
    ///
    /// - Returns: Sanitized string representation of the key
    public var safeLogRepresentation: String {
        guard !self.isEmpty else { return "<empty>" }

        // First 8 bytes
        let prefix = self.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        // First 8 bytes of SHA256 hash
        let hash = SHA256.hash(data: Data(self))
        let hashHex = hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        return "\(prefix)...<hash:\(hashHex)> (length:\(self.count))"
    }
}

extension Error {
    /// Safe description for logging
    ///
    /// Removes user paths and sensitive information.
    public var safeDescription: String {
        let desc = String(describing: self)
        return desc
            .replacingOccurrences(
                of: #"/Users/[^/]+/"#,
                with: "/Users/<redacted>/",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"/home/[^/]+/"#,
                with: "/home/<redacted>/",
                options: .regularExpression
            )
    }
}
