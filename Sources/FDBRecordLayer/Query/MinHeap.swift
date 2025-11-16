import Foundation

/// Generic MinHeap/MaxHeap data structure for Top-K optimization
///
/// **v2.1 API Design**: `sorted()` ALWAYS returns ascending order (smallest first)
/// regardless of whether using MinHeap or MaxHeap comparator. This prevents bugs
/// when tracking Top-K with MaxHeap.
///
/// **Example: Top-10 smallest distances (MinHeap)**:
/// ```swift
/// var heap = MinHeap<Double>(maxSize: 10, heapType: .min) { $0 < $1 }
/// for distance in distances {
///     heap.insert(distance)
/// }
/// let top10 = heap.sorted()  // ✅ [1.2, 1.5, 2.0, ...] (ascending)
/// ```
///
/// **Example: Top-10 largest distances (MaxHeap for tracking smallest)**:
/// ```swift
/// var heap = MinHeap<Double>(maxSize: 10, heapType: .max) { $0 > $1 }
/// for distance in distances {
///     heap.insert(distance)  // Keeps smallest 10
/// }
/// let top10 = heap.sorted()  // ✅ [1.2, 1.5, 2.0, ...] (ascending, auto-reversed)
/// ```
///
/// **Memory**: O(k) instead of O(n) for Top-K tracking
/// **Insertion**: O(log k) amortized
public struct MinHeap<Element> {
    /// Heap type (Min or Max)
    public enum HeapType {
        case min  // Smallest element at root (comparator: <)
        case max  // Largest element at root (comparator: >)
    }

    /// Internal storage (heap-ordered array)
    private(set) var elements: [Element]

    /// Comparator for heap ordering
    ///
    /// - MinHeap: `{ $0 < $1 }` (smallest at root)
    /// - MaxHeap: `{ $0 > $1 }` (largest at root)
    private let comparator: (Element, Element) -> Bool

    /// Heap type (min or max)
    private let heapType: HeapType

    /// Maximum heap size (for Top-K tracking)
    ///
    /// When maxSize is reached, insert() will evict the root element
    /// if the new element should replace it.
    private let maxSize: Int?

    /// Number of elements in heap
    public var count: Int {
        return elements.count
    }

    /// Whether heap is empty
    public var isEmpty: Bool {
        return elements.isEmpty
    }

    /// Whether heap is at maximum capacity
    public var isFull: Bool {
        guard let maxSize = maxSize else { return false }
        return count >= maxSize
    }

    /// Peek at minimum element (root) without removing
    public var min: Element? {
        return elements.first
    }

    /// Initialize empty heap
    ///
    /// - Parameters:
    ///   - maxSize: Optional maximum size for Top-K tracking (nil = unlimited)
    ///   - heapType: Heap type (.min or .max)
    ///   - comparator: Comparison function (MinHeap: `<`, MaxHeap: `>`)
    public init(maxSize: Int? = nil, heapType: HeapType, comparator: @escaping (Element, Element) -> Bool) {
        self.elements = []
        self.comparator = comparator
        self.heapType = heapType
        self.maxSize = maxSize

        if let maxSize = maxSize {
            self.elements.reserveCapacity(maxSize)
        }
    }

    /// Initialize from array (heapify in O(n))
    ///
    /// - Parameters:
    ///   - array: Initial elements
    ///   - maxSize: Optional maximum size
    ///   - heapType: Heap type (.min or .max)
    ///   - comparator: Comparison function
    public init(array: [Element], maxSize: Int? = nil, heapType: HeapType, comparator: @escaping (Element, Element) -> Bool) {
        self.comparator = comparator
        self.heapType = heapType
        self.maxSize = maxSize

        if let maxSize = maxSize, array.count > maxSize {
            // Take only first maxSize elements if array is larger
            self.elements = Array(array.prefix(maxSize))
        } else {
            self.elements = array
        }

        // Heapify: start from last non-leaf node and sift down
        if !elements.isEmpty {
            for i in stride(from: (elements.count / 2) - 1, through: 0, by: -1) {
                siftDown(from: i)
            }
        }
    }

    /// Insert element into heap
    ///
    /// **Behavior with maxSize**:
    /// - If heap is not full, insert normally
    /// - If heap is full and new element should replace root, evict root and insert
    /// - If heap is full and new element should not be inserted, ignore it
    ///
    /// - Parameter element: Element to insert
    /// - Returns: true if element was inserted, false if heap is full and element was rejected
    @discardableResult
    public mutating func insert(_ element: Element) -> Bool {
        // Check if heap is at capacity
        if let maxSize = maxSize, count >= maxSize {
            // If new element should replace root (heap is full)
            guard let root = min else { return false }

            // For MinHeap: insert if element > root (keep largest k elements)
            // For MaxHeap: insert if element < root (keep smallest k elements)
            if comparator(element, root) {
                // New element should not be in heap
                return false
            } else {
                // Replace root with new element
                elements[0] = element
                siftDown(from: 0)
                return true
            }
        }

        // Heap is not full, normal insertion
        elements.append(element)
        siftUp(from: elements.count - 1)
        return true
    }

    /// Remove and return minimum element (root)
    ///
    /// - Returns: Minimum element, or nil if heap is empty
    @discardableResult
    public mutating func removeMin() -> Element? {
        guard !elements.isEmpty else { return nil }

        if elements.count == 1 {
            return elements.removeLast()
        }

        let min = elements[0]
        elements[0] = elements.removeLast()
        siftDown(from: 0)
        return min
    }

    /// Convert heap to sorted array in ascending order (smallest first)
    ///
    /// **⚠️ CRITICAL (v2.1)**: This method ALWAYS returns ascending order,
    /// regardless of heap type. For MaxHeap, this internally reverses the result.
    ///
    /// **Time Complexity**: O(n log n)
    /// **Space Complexity**: O(n)
    ///
    /// - Returns: Array sorted in ascending order (smallest to largest)
    public func sorted() -> [Element] {
        var copy = self
        var result: [Element] = []
        result.reserveCapacity(count)

        while let min = copy.removeMin() {
            result.append(min)
        }

        // ✅ v2.1 FIX: Reverse if MaxHeap to get ascending order
        switch heapType {
        case .min:
            return result  // MinHeap removeMin() gives ascending order
        case .max:
            return result.reversed()  // MaxHeap removeMin() gives descending order
        }
    }

    /// Convert heap to sorted array in descending order (largest first)
    ///
    /// **Time Complexity**: O(n log n)
    /// **Space Complexity**: O(n)
    ///
    /// - Returns: Array sorted in descending order (largest to smallest)
    public func sortedDescending() -> [Element] {
        return sorted().reversed()
    }

    // MARK: - Internal Heap Operations

    /// Sift element up to maintain heap property
    ///
    /// - Parameter index: Index of element to sift up
    private mutating func siftUp(from index: Int) {
        var childIndex = index
        let child = elements[childIndex]
        var parentIndex = (childIndex - 1) / 2

        while childIndex > 0 && comparator(child, elements[parentIndex]) {
            elements[childIndex] = elements[parentIndex]
            childIndex = parentIndex
            parentIndex = (childIndex - 1) / 2
        }

        elements[childIndex] = child
    }

    /// Sift element down to maintain heap property
    ///
    /// **Algorithm**:
    /// 1. Find minimum child among all children
    /// 2. Compare minimum child with parent value (not current element)
    /// 3. If child < parent, move child up and continue
    /// 4. Otherwise, parent is in correct position
    ///
    /// - Parameter index: Index of element to sift down
    private mutating func siftDown(from index: Int) {
        var parentIndex = index
        let count = elements.count
        let parent = elements[parentIndex]

        while true {
            let leftChildIndex = 2 * parentIndex + 1
            let rightChildIndex = 2 * parentIndex + 2

            // No children, parent is in correct position
            guard leftChildIndex < count else { break }

            // Find minimum child
            var minChildIndex = leftChildIndex
            if rightChildIndex < count && comparator(elements[rightChildIndex], elements[leftChildIndex]) {
                minChildIndex = rightChildIndex
            }

            // Compare minimum child with PARENT (not with current element at parentIndex)
            if comparator(elements[minChildIndex], parent) {
                // Child < parent, move child up
                elements[parentIndex] = elements[minChildIndex]
                parentIndex = minChildIndex
            } else {
                // Parent is in correct position
                break
            }
        }

        elements[parentIndex] = parent
    }
}

// MARK: - Comparable-based Convenience Initializers

extension MinHeap where Element: Comparable {
    /// Initialize MinHeap with default < comparator (smallest at root)
    ///
    /// - Parameter maxSize: Optional maximum size for Top-K tracking
    public init(maxSize: Int? = nil) {
        self.init(maxSize: maxSize, heapType: .min, comparator: <)
    }

    /// Initialize MaxHeap with > comparator (largest at root, for tracking smallest k)
    ///
    /// **Use Case**: Track Top-K smallest elements by using MaxHeap to evict largest
    ///
    /// - Parameter maxSize: Maximum size (required for MaxHeap Top-K pattern)
    public static func maxHeap(maxSize: Int) -> MinHeap<Element> {
        return MinHeap<Element>(maxSize: maxSize, heapType: .max, comparator: >)
    }
}

// MARK: - CustomStringConvertible

extension MinHeap: CustomStringConvertible {
    public var description: String {
        return "MinHeap(count: \(count), elements: \(elements))"
    }
}

// MARK: - Sequence (non-destructive iteration)

extension MinHeap: Sequence {
    public func makeIterator() -> IndexingIterator<[Element]> {
        return elements.makeIterator()
    }
}
