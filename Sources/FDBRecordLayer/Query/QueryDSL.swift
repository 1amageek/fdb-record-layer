import Foundation

// MARK: - Query Result Builder

/// Result Builder for declarative query construction
///
/// **Usage**:
/// ```swift
/// let users = try await store.query {
///     Where(\.email == "alice@example.com")
///     Where(\.age > 18)
///     OrderBy(\.createdAt, .descending)
///     Limit(10)
/// }
/// ```
@resultBuilder
public struct QueryDSL<Record: Recordable> {
    public static func buildBlock(_ components: any QueryDSLComponent<Record>...) -> [any QueryDSLComponent<Record>] {
        components
    }

    public static func buildOptional(_ component: [any QueryDSLComponent<Record>]?) -> [any QueryDSLComponent<Record>] {
        component ?? []
    }

    public static func buildEither(first component: [any QueryDSLComponent<Record>]) -> [any QueryDSLComponent<Record>] {
        component
    }

    public static func buildEither(second component: [any QueryDSLComponent<Record>]) -> [any QueryDSLComponent<Record>] {
        component
    }

    public static func buildArray(_ components: [[any QueryDSLComponent<Record>]]) -> [any QueryDSLComponent<Record>] {
        components.flatMap { $0 }
    }
}

// MARK: - DSL Component Protocol

/// Protocol for query DSL components
public protocol QueryDSLComponent<Record>: Sendable {
    associatedtype Record: Recordable

    /// Apply this component to a QueryBuilder
    func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record>
}

// MARK: - WHERE Component

/// WHERE clause component
public struct Where<Record: Recordable>: QueryDSLComponent {
    private let predicate: Predicate<Record>

    /// Create WHERE clause with predicate
    public init(_ predicate: Predicate<Record>) {
        self.predicate = predicate
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.where(predicate)
    }
}

// MARK: - ORDER BY Component

/// ORDER BY clause component
public struct OrderBy<Record: Recordable>: QueryDSLComponent {
    private let fieldName: String
    private let direction: SortDirection

    /// Create ORDER BY clause
    public init<Value: TupleElement & Comparable>(
        _ keyPath: KeyPath<Record, Value>,
        _ direction: SortDirection = .ascending
    ) {
        self.fieldName = Record.fieldName(for: keyPath)
        self.direction = direction
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.sortOrders.append((field: fieldName, direction: direction))
        return builder
    }
}

// MARK: - LIMIT Component

/// LIMIT clause component
public struct Limit<Record: Recordable>: QueryDSLComponent {
    private let value: Int

    /// Create LIMIT clause
    public init(_ value: Int) {
        self.value = value
    }

    public func apply(to builder: QueryBuilder<Record>) -> QueryBuilder<Record> {
        builder.limit(value)
    }
}

// MARK: - RecordStore Extension

extension RecordStore {
    /// Execute query with Result Builder DSL
    ///
    /// **Usage**:
    /// ```swift
    /// let users = try await store.query {
    ///     Where(\.city == "Tokyo")
    ///     Where(\.age > 18)
    ///     OrderBy(\.createdAt, .descending)
    ///     Limit(100)
    /// }
    /// ```
    public func queryDSL(
        @QueryDSL<Record> _ build: () -> [any QueryDSLComponent<Record>]
    ) async throws -> [Record] {
        // Create QueryBuilder
        var builder = self.query()

        // Apply DSL components
        for component in build() {
            builder = component.apply(to: builder)
        }

        return try await builder.execute()
    }
}
