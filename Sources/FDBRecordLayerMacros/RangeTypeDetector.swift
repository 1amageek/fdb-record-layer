//
//  RangeTypeDetector.swift
//  FDBRecordLayer
//
//  Created by Gemini
//

import Foundation

/// A utility for detecting Swift Range types from a string representation.
///
/// This detector analyzes a type name string (e.g., "Range<Date>", "Optional<ClosedRange<Int>>")
/// and returns structured information about the range, including its base type and boundary characteristics.
/// This is necessary because Swift macros do not have access to full type reflection at compile time.
enum RangeTypeDetector {

    /// Information about a detected range type.
    struct RangeInfo {
        /// The base type of the range, e.g., "Date" from "Range<Date>".
        let boundType: String

        /// The category of the range (e.g., full range, partial range, or not a range).
        let category: RangeCategory

        /// Whether this is a ClosedRange (true) or Range (false)
        let isClosed: Bool

        /// Get boundary type for index metadata
        var boundaryType: BoundaryType {
            switch category {
            case .full:
                return isClosed ? .closed : .halfOpen
            case .partialFrom, .partialUpTo:
                return .halfOpen  // PartialRange は常に halfOpen
            case .notRange:
                return .halfOpen
            }
        }
    }

    /// Boundary type for Range indexes
    enum BoundaryType: String {
        case halfOpen
        case closed
    }

    /// The category of a range, determining which boundaries it has.
    enum RangeCategory {
        /// A full range with both a lower and an upper bound, e.g., `Range<T>` or `ClosedRange<T>`.
        case full

        /// A partial range with only a lower bound, e.g., `PartialRangeFrom<T>`.
        case partialFrom

        /// A partial range with only an upper bound, e.g., `PartialRangeUpTo<T>` or `PartialRangeThrough<T>`.
        case partialUpTo

        /// Not a range type.
        case notRange
    }

    /// Analyzes a type string to detect if it represents a range.
    ///
    /// - Parameter typeName: The string representation of the type, e.g., "Range<Date>".
    /// - Returns: A `RangeInfo` struct containing details about the detected range, or `nil` if it's not a range type.
    static func detectRange(from typeName: String) -> RangeInfo? {
        if typeName.contains("ClosedRange<") {
            guard let boundType = extractGenericArgument(from: typeName) else { return nil }
            return RangeInfo(boundType: boundType, category: .full, isClosed: true)
        }
        if typeName.contains("Range<") {
            guard let boundType = extractGenericArgument(from: typeName) else { return nil }
            return RangeInfo(boundType: boundType, category: .full, isClosed: false)
        }
        if typeName.contains("PartialRangeFrom<") {
            guard let boundType = extractGenericArgument(from: typeName) else { return nil }
            return RangeInfo(boundType: boundType, category: .partialFrom, isClosed: false)
        }
        if typeName.contains("PartialRangeThrough<") || typeName.contains("PartialRangeUpTo<") {
            guard let boundType = extractGenericArgument(from: typeName) else { return nil }
            return RangeInfo(boundType: boundType, category: .partialUpTo, isClosed: false)
        }
        // Note: UnboundedRange is not considered a valid range for indexing.
        return nil
    }

    /// Extracts the generic argument from a type string.
    /// Example: "Optional<Range<Date>>" -> "Range<Date>"
    /// Example: "Range<Date>" -> "Date"
    private static func extractGenericArgument(from typeName: String) -> String? {
        guard let firstAngleBracket = typeName.firstIndex(of: "<"),
              let lastAngleBracket = typeName.lastIndex(of: ">") else {
            return nil
        }

        let startIndex = typeName.index(after: firstAngleBracket)
        let endIndex = lastAngleBracket

        guard startIndex < endIndex else { return nil }

        return String(typeName[startIndex..<endIndex])
    }
}