import Foundation

/// Query component visitor protocol
///
/// Implements the Visitor pattern for traversing query components.
/// Used for query analysis and transformation (e.g., extracting IN predicates).
///
/// **Example**:
/// ```swift
/// struct MyVisitor {
///     mutating func visit<Record: Sendable>(_ component: any TypedQueryComponent<Record>) throws {
///         // Process component
///     }
/// }
///
/// var visitor = InExtractor()
/// if let filter = query.filter {
///     try visitor.visit(filter)
/// }
/// ```
///
/// **Note**: This is a simplified visitor pattern that works with TypedQueryComponent
/// directly, without requiring a protocol for visitation.
