import Foundation
import Synchronization

/// Thread-safe box for storing mutable state in Sendable types
///
/// SendableBox provides a thread-safe container for mutable values that need to be
/// stored in Sendable types. It uses Swift's `Mutex` for efficient and safe synchronization.
///
/// **型制約**:
/// `Value` は `Sendable` に準拠している必要があります。これにより、スレッド間で
/// 安全にデータを共有できることが保証されます。
///
/// **使用例**:
/// ```swift
/// final class MyClass: Sendable {
///     private let counter: SendableBox<Int>
///
///     init() {
///         self.counter = SendableBox(0)
///     }
///
///     func increment() {
///         counter.withLock { value in
///             value += 1
///         }
///     }
///
///     func getValue() -> Int {
///         return counter.withLock { $0 }
///     }
/// }
/// ```
final class SendableBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    /// Initialize with an initial value
    ///
    /// - Parameter initialValue: The initial value to store
    init(_ initialValue: Value) {
        self.mutex = Mutex(initialValue)
    }

    /// Access the value within a locked context
    ///
    /// This method provides exclusive access to the value, ensuring thread safety.
    /// The closure is executed while holding the lock.
    ///
    /// - Parameter body: A closure that receives exclusive access to the value
    /// - Returns: The value returned by the closure
    /// - Throws: Any error thrown by the closure
    func withLock<Result: Sendable>(_ body: (inout sending Value) throws -> sending Result) rethrows -> Result {
        return try mutex.withLock(body)
    }

    /// Read the current value
    ///
    /// This is a convenience method equivalent to `withLock { $0 }`
    ///
    /// - Returns: The current value
    var value: Value {
        return mutex.withLock { $0 }
    }

    /// Update the value
    ///
    /// This is a convenience method for updating the entire value
    ///
    /// - Parameter newValue: The new value to store
    func setValue(_ newValue: Value) {
        mutex.withLock { $0 = newValue }
    }
}

// MARK: - Convenience Extensions

extension SendableBox where Value: RangeReplaceableCollection {
    /// Append an element to a collection
    func append(_ element: Value.Element) {
        withLock { $0.append(element) }
    }

    /// Remove all elements from the collection
    func removeAll() {
        withLock { $0.removeAll() }
    }
}

extension SendableBox where Value: BinaryInteger {
    /// Increment the value
    func increment() {
        withLock { $0 += 1 }
    }

    /// Decrement the value
    func decrement() {
        withLock { $0 -= 1 }
    }
}
