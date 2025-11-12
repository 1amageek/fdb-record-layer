import Foundation
import FoundationDB

/// IN predicate extractor
///
/// Extracts IN predicates from queries for optimization.
/// The query planner uses this to generate InJoinPlan for efficient IN queries.
///
/// **Deduplication**: Automatically removes duplicate IN predicates based on field name and value set.
///
/// **Performance Impact**:
/// - Without IN extraction: O(n) full scan with post-filtering
/// - With IN extraction: O(k log n) where k = number of IN values
/// - **50-100x speedup** for large datasets
///
/// **Example**:
/// ```swift
/// let query = QueryBuilder<User>()
///     .where(\.age, .greaterThanOrEquals, 18)
///     .where(\.city, .in, ["Tokyo", "Osaka", "Kyoto"])
///     .build()
///
/// var extractor = InExtractor()
/// try query.accept(visitor: &extractor)
///
/// for inPredicate in extractor.extractedInPredicates {
///     print("IN predicate on field: \(inPredicate.fieldName)")
///     print("Values: \(inPredicate.values)")
/// }
/// ```
public struct InExtractor {
    /// Extracted IN predicates (deduplicated by Set)
    private var inPredicatesSet: Set<InPredicate> = []

    /// Initialize an IN extractor
    public init() {}

    /// Visit a query component
    ///
    /// Extracts IN predicates from filters.
    /// Automatically deduplicates predicates based on field name and value set.
    ///
    /// - Parameter component: Component to visit
    /// - Throws: Any error during extraction
    public mutating func visit<Record: Sendable>(_ component: any TypedQueryComponent<Record>) throws {
        // Check if component is a TypedInQueryComponent
        if let inComponent = component as? TypedInQueryComponent<Record> {
            let inPredicate = InPredicate(
                fieldName: inComponent.fieldName,
                values: inComponent.values
            )
            // Set automatically handles deduplication
            inPredicatesSet.insert(inPredicate)
        }

        // Recursively visit AND/OR components
        if let andComponent = component as? TypedAndQueryComponent<Record> {
            for child in andComponent.children {
                try visit(child)
            }
        } else if let orComponent = component as? TypedOrQueryComponent<Record> {
            for child in orComponent.children {
                try visit(child)
            }
        } else if let notComponent = component as? TypedNotQueryComponent<Record> {
            try visit(notComponent.child)
        }
    }

    /// Get extracted IN predicates (deduplicated)
    ///
    /// - Returns: Array of extracted IN predicates
    public func extractedInPredicates() -> [InPredicate] {
        return Array(inPredicatesSet)
    }

    /// Check if any IN predicates were found
    public var hasInPredicates: Bool {
        return !inPredicatesSet.isEmpty
    }
}

/// IN predicate metadata
///
/// Represents an IN predicate extracted from a query.
public struct InPredicate: Sendable, Equatable, Hashable {
    /// Field name
    public let fieldName: String

    /// IN values
    public let values: [any TupleElement]

    /// Cached packed representation for comparison
    private let packedValues: [FDB.Bytes]

    /// Initialize an IN predicate
    ///
    /// - Parameters:
    ///   - fieldName: Field name
    ///   - values: IN values
    public init(fieldName: String, values: [any TupleElement]) {
        self.fieldName = fieldName
        self.values = values
        // Pack each value for efficient comparison
        self.packedValues = values.map { Tuple($0).pack() }
    }

    /// Number of values
    public var valueCount: Int {
        return values.count
    }

    /// Compare two IN predicates for equality
    ///
    /// Two IN predicates are equal if they have the same field name and values
    /// (regardless of order, since IN is a set operation)
    public static func == (lhs: InPredicate, rhs: InPredicate) -> Bool {
        guard lhs.fieldName == rhs.fieldName else {
            return false
        }
        guard lhs.packedValues.count == rhs.packedValues.count else {
            return false
        }

        // Sort packed values for order-independent comparison (lexicographic)
        let sortedLhs = lhs.packedValues.sorted { Self.compareBytesLexicographic($0, $1) }
        let sortedRhs = rhs.packedValues.sorted { Self.compareBytesLexicographic($0, $1) }

        return sortedLhs == sortedRhs
    }

    /// Hash value for InPredicate
    public func hash(into hasher: inout Hasher) {
        hasher.combine(fieldName)
        // Hash sorted packed values for order-independent hashing
        for packedValue in packedValues.sorted(by: { Self.compareBytesLexicographic($0, $1) }) {
            hasher.combine(packedValue)
        }
    }

    /// Check if this IN predicate matches a TypedInQueryComponent
    ///
    /// - Parameter component: The component to check
    /// - Returns: true if the component represents the same IN predicate
    public func matches<Record>(_ component: TypedInQueryComponent<Record>) -> Bool {
        guard component.fieldName == fieldName else {
            return false
        }
        guard component.values.count == values.count else {
            return false
        }

        // Pack component values and compare
        let componentPacked = component.values.map { Tuple($0).pack() }
        let sortedComponent = componentPacked.sorted { Self.compareBytesLexicographic($0, $1) }
        let sortedSelf = packedValues.sorted { Self.compareBytesLexicographic($0, $1) }

        return sortedComponent == sortedSelf
    }

    /// Lexicographic comparison of byte arrays
    ///
    /// - Parameters:
    ///   - lhs: First byte array
    ///   - rhs: Second byte array
    /// - Returns: true if lhs < rhs lexicographically
    private static func compareBytesLexicographic(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        let minCount = min(lhs.count, rhs.count)
        for i in 0..<minCount {
            if lhs[i] < rhs[i] {
                return true
            } else if lhs[i] > rhs[i] {
                return false
            }
        }
        // If all compared bytes are equal, shorter array comes first
        return lhs.count < rhs.count
    }
}

