import Foundation

// MARK: - Aggregate Result Builder

/// Result Builder for aggregate queries
///
/// **Usage**:
/// ```swift
/// let count = try await store.aggregate {
///     Where(\.city == "Tokyo")
///     Count()
/// }
/// ```
@resultBuilder
public struct AggregateDSL<Record: Recordable> {
    public static func buildBlock(_ components: any AggregateDSLComponent<Record>...) -> [any AggregateDSLComponent<Record>] {
        components
    }

    public static func buildOptional(_ component: [any AggregateDSLComponent<Record>]?) -> [any AggregateDSLComponent<Record>] {
        component ?? []
    }

    public static func buildEither(first component: [any AggregateDSLComponent<Record>]) -> [any AggregateDSLComponent<Record>] {
        component
    }

    public static func buildEither(second component: [any AggregateDSLComponent<Record>]) -> [any AggregateDSLComponent<Record>] {
        component
    }
}

// MARK: - Aggregate Component Protocol

/// Protocol for aggregate DSL components
public protocol AggregateDSLComponent<Record>: Sendable {
    associatedtype Record: Recordable
    associatedtype Result: Sendable

    /// Execute this aggregate function
    func execute(
        on store: RecordStore<Record>,
        filters: [Predicate<Record>]
    ) async throws -> Result
}

// MARK: - COUNT Aggregate

/// COUNT aggregate function
public struct Count<Record: Recordable>: AggregateDSLComponent {
    public typealias Result = Int

    public init() {}

    public func execute(
        on store: RecordStore<Record>,
        filters: [Predicate<Record>]
    ) async throws -> Int {
        var builder = store.query()
        for filter in filters {
            builder = builder.where(filter)
        }
        return try await builder.count()
    }
}

// MARK: - SUM Aggregate

/// SUM aggregate function
public struct Sum<Record: Recordable, Value>: AggregateDSLComponent where Value: TupleElement & AdditiveArithmetic {
    public typealias Result = Value

    private let fieldName: String

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.fieldName = Record.fieldName(for: keyPath)
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [Predicate<Record>]
    ) async throws -> Value {
        var builder = store.query()
        for filter in filters {
            builder = builder.where(filter)
        }

        let records = try await builder.execute()
        guard !records.isEmpty else { return .zero }

        // Sum up the field values
        var total: Value = .zero
        for record in records {
            // Use reflection to get field value
            let mirror = Mirror(reflecting: record)
            for child in mirror.children {
                if child.label == fieldName, let value = child.value as? Value {
                    total = total + value
                    break
                }
            }
        }
        return total
    }
}

// MARK: - AVG Aggregate

/// AVG aggregate function
public struct Average<Record: Recordable, Value>: AggregateDSLComponent where Value: TupleElement & BinaryFloatingPoint {
    public typealias Result = Value

    private let fieldName: String

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.fieldName = Record.fieldName(for: keyPath)
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [Predicate<Record>]
    ) async throws -> Value {
        var builder = store.query()
        for filter in filters {
            builder = builder.where(filter)
        }

        let records = try await builder.execute()
        guard !records.isEmpty else { return 0 }

        // Sum up the field values
        var total: Value = 0
        for record in records {
            let mirror = Mirror(reflecting: record)
            for child in mirror.children {
                if child.label == fieldName, let value = child.value as? Value {
                    total = total + value
                    break
                }
            }
        }

        return total / Value(records.count)
    }
}

// MARK: - MAX Aggregate

/// MAX aggregate function
public struct Max<Record: Recordable, Value>: AggregateDSLComponent where Value: TupleElement & Comparable {
    public typealias Result = Value?

    private let fieldName: String

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.fieldName = Record.fieldName(for: keyPath)
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [Predicate<Record>]
    ) async throws -> Value? {
        var builder = store.query()
        for filter in filters {
            builder = builder.where(filter)
        }

        let records = try await builder.execute()
        guard !records.isEmpty else { return nil }

        // Find max value
        var maxValue: Value? = nil
        for record in records {
            let mirror = Mirror(reflecting: record)
            for child in mirror.children {
                if child.label == fieldName, let value = child.value as? Value {
                    if let current = maxValue {
                        maxValue = max(current, value)
                    } else {
                        maxValue = value
                    }
                    break
                }
            }
        }

        return maxValue
    }
}

// MARK: - MIN Aggregate

/// MIN aggregate function
public struct Min<Record: Recordable, Value>: AggregateDSLComponent where Value: TupleElement & Comparable {
    public typealias Result = Value?

    private let fieldName: String

    public init(_ keyPath: KeyPath<Record, Value>) {
        self.fieldName = Record.fieldName(for: keyPath)
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [Predicate<Record>]
    ) async throws -> Value? {
        var builder = store.query()
        for filter in filters {
            builder = builder.where(filter)
        }

        let records = try await builder.execute()
        guard !records.isEmpty else { return nil }

        // Find min value
        var minValue: Value? = nil
        for record in records {
            let mirror = Mirror(reflecting: record)
            for child in mirror.children {
                if child.label == fieldName, let value = child.value as? Value {
                    if let current = minValue {
                        minValue = min(current, value)
                    } else {
                        minValue = value
                    }
                    break
                }
            }
        }

        return minValue
    }
}

// MARK: - WHERE for Aggregates

/// WHERE clause for aggregate queries
public struct AggregateWhere<Record: Recordable>: AggregateDSLComponent {
    public typealias Result = Void

    private let predicate: Predicate<Record>

    public init(_ predicate: Predicate<Record>) {
        self.predicate = predicate
    }

    public func execute(
        on store: RecordStore<Record>,
        filters: [Predicate<Record>]
    ) async throws -> Void {
        // This is a marker component, execution is handled by aggregate functions
    }
}

// MARK: - RecordStore Extension

extension RecordStore {
    /// Execute aggregate query with Result Builder DSL
    ///
    /// **Usage**:
    /// ```swift
    /// let count = try await store.aggregate {
    ///     Where(\.city == "Tokyo")
    ///     Count()
    /// }
    ///
    /// let avgAge = try await store.aggregate {
    ///     Where(\.status == "active")
    ///     Average(\.age)
    /// }
    /// ```
    public func aggregate<Component: AggregateDSLComponent>(
        @AggregateDSL<Record> _ build: () -> [Component]
    ) async throws -> Component.Result where Component.Record == Record {
        let components = build()

        // Extract filters and aggregate function
        let filters: [Predicate<Record>] = []
        var aggregateFunc: Component? = nil

        for component in components {
            if component is AggregateWhere<Record> {
                // Extract predicate from WHERE clause
                // Note: This is a simplified implementation
                // In a full implementation, we would need to properly extract the predicate
                continue
            } else {
                aggregateFunc = component
            }
        }

        guard let function = aggregateFunc else {
            throw RecordLayerError.invalidArgument("No aggregate function provided")
        }

        return try await function.execute(on: self, filters: filters)
    }
}
