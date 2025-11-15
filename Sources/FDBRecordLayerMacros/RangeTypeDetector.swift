import Foundation
import SwiftSyntax

/// Range型の検出情報
public enum RangeTypeInfo {
    /// Range<Bound> - 半開区間 [a, b)
    case range(boundType: String)

    /// ClosedRange<Bound> - 閉区間 [a, b]
    case closedRange(boundType: String)

    /// PartialRangeFrom<Bound> - [a, ∞)
    case partialRangeFrom(boundType: String)

    /// PartialRangeThrough<Bound> - (-∞, b]
    case partialRangeThrough(boundType: String)

    /// PartialRangeUpTo<Bound> - (-∞, b)
    case partialRangeUpTo(boundType: String)

    /// UnboundedRange - (-∞, ∞) - インデックス化不可
    case unboundedRange

    /// Range型ではない
    case notRange

    /// 開始時刻インデックスが必要か
    public var needsStartIndex: Bool {
        switch self {
        case .range, .closedRange, .partialRangeFrom:
            return true
        default:
            return false
        }
    }

    /// 終了時刻インデックスが必要か
    public var needsEndIndex: Bool {
        switch self {
        case .range, .closedRange, .partialRangeThrough, .partialRangeUpTo:
            return true
        default:
            return false
        }
    }

    /// 境界タイプ
    public var boundaryType: String {
        switch self {
        case .range, .partialRangeUpTo:
            return "halfOpen"
        case .closedRange, .partialRangeFrom, .partialRangeThrough:
            return "closed"
        default:
            return "halfOpen"  // デフォルト
        }
    }

    /// Bound型を取得
    public var boundType: String? {
        switch self {
        case .range(let bound), .closedRange(let bound),
             .partialRangeFrom(let bound), .partialRangeThrough(let bound),
             .partialRangeUpTo(let bound):
            return bound
        default:
            return nil
        }
    }
}

/// Range型検出器
public struct RangeTypeDetector {
    /// 型文字列からRange型情報を検出
    ///
    /// - Parameter typeString: 型文字列（例: "Range<Date>", "ClosedRange<Int64>"）
    /// - Returns: Range型情報
    public static func detectRangeType(_ typeString: String) -> RangeTypeInfo {
        let cleaned = typeString.trimmingCharacters(in: .whitespaces)

        // UnboundedRange
        if cleaned == "UnboundedRange" {
            return .unboundedRange
        }

        // Range<Bound>
        if cleaned.hasPrefix("Range<") {
            if let bound = extractBoundType(from: cleaned, prefix: "Range<") {
                return .range(boundType: bound)
            }
        }

        // ClosedRange<Bound>
        if cleaned.hasPrefix("ClosedRange<") {
            if let bound = extractBoundType(from: cleaned, prefix: "ClosedRange<") {
                return .closedRange(boundType: bound)
            }
        }

        // PartialRangeFrom<Bound>
        if cleaned.hasPrefix("PartialRangeFrom<") {
            if let bound = extractBoundType(from: cleaned, prefix: "PartialRangeFrom<") {
                return .partialRangeFrom(boundType: bound)
            }
        }

        // PartialRangeThrough<Bound>
        if cleaned.hasPrefix("PartialRangeThrough<") {
            if let bound = extractBoundType(from: cleaned, prefix: "PartialRangeThrough<") {
                return .partialRangeThrough(boundType: bound)
            }
        }

        // PartialRangeUpTo<Bound>
        if cleaned.hasPrefix("PartialRangeUpTo<") {
            if let bound = extractBoundType(from: cleaned, prefix: "PartialRangeUpTo<") {
                return .partialRangeUpTo(boundType: bound)
            }
        }

        return .notRange
    }

    /// TypeSyntaxからRange型情報を検出
    ///
    /// - Parameter typeSyntax: TypeSyntax
    /// - Returns: Range型情報
    public static func detectRangeType(from typeSyntax: TypeSyntax) -> RangeTypeInfo {
        let typeString = typeSyntax.trimmedDescription
        return detectRangeType(typeString)
    }

    /// IdentifierTypeSyntaxからRange型情報を検出
    ///
    /// - Parameter identifierType: IdentifierTypeSyntax
    /// - Returns: Range型情報
    public static func detectRangeType(from identifierType: IdentifierTypeSyntax) -> RangeTypeInfo {
        let typeName = identifierType.name.text

        // ジェネリック引数を取得
        guard let genericArgs = identifierType.genericArgumentClause?.arguments,
              let firstArg = genericArgs.first else {
            // ジェネリック引数がない場合
            if typeName == "UnboundedRange" {
                return .unboundedRange
            }
            return .notRange
        }

        let boundType = firstArg.argument.trimmedDescription

        switch typeName {
        case "Range":
            return .range(boundType: boundType)
        case "ClosedRange":
            return .closedRange(boundType: boundType)
        case "PartialRangeFrom":
            return .partialRangeFrom(boundType: boundType)
        case "PartialRangeThrough":
            return .partialRangeThrough(boundType: boundType)
        case "PartialRangeUpTo":
            return .partialRangeUpTo(boundType: boundType)
        default:
            return .notRange
        }
    }

    // MARK: - Private Helpers

    /// 型文字列からBound型を抽出
    ///
    /// - Parameters:
    ///   - typeString: 型文字列（例: "Range<Date>"）
    ///   - prefix: プレフィックス（例: "Range<"）
    /// - Returns: Bound型（例: "Date"）
    private static func extractBoundType(from typeString: String, prefix: String) -> String? {
        guard typeString.hasPrefix(prefix), typeString.hasSuffix(">") else {
            return nil
        }

        let startIndex = typeString.index(typeString.startIndex, offsetBy: prefix.count)
        let endIndex = typeString.index(before: typeString.endIndex)

        guard startIndex < endIndex else {
            return nil
        }

        let bound = String(typeString[startIndex..<endIndex])
        return bound.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - CustomStringConvertible

extension RangeTypeInfo: CustomStringConvertible {
    public var description: String {
        switch self {
        case .range(let bound):
            return "Range<\(bound)>"
        case .closedRange(let bound):
            return "ClosedRange<\(bound)>"
        case .partialRangeFrom(let bound):
            return "PartialRangeFrom<\(bound)>"
        case .partialRangeThrough(let bound):
            return "PartialRangeThrough<\(bound)>"
        case .partialRangeUpTo(let bound):
            return "PartialRangeUpTo<\(bound)>"
        case .unboundedRange:
            return "UnboundedRange"
        case .notRange:
            return "Not a Range type"
        }
    }
}
