import Foundation
import FoundationDB
import CryptoKit

// MARK: - Safe Logging Extensions

/// Extensions for safe logging without exposing PII
extension FDB.Bytes {
    /// ログ出力用の安全な表現
    ///
    /// 先頭8バイトとSHA256ハッシュのみを表示し、中間部分は隠蔽します。
    /// これにより、PII（個人識別情報）を含む可能性があるキーを安全にログに記録できます。
    ///
    /// - Returns: 安全化されたキーの文字列表現
    public var safeLogRepresentation: String {
        guard !self.isEmpty else { return "<empty>" }

        // 先頭8バイト
        let prefix = self.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        // SHA256ハッシュの先頭8バイト
        let hash = SHA256.hash(data: Data(self))
        let hashHex = hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        return "\(prefix)...<hash:\(hashHex)> (length:\(self.count))"
    }
}

extension Error {
    /// ログ出力用の安全な説明
    ///
    /// ユーザーパスや機密情報を除去します。
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
