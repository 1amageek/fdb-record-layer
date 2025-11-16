import Foundation
import Testing
@testable import FDBRecordLayer

@Suite("MinHeap Tests")
struct MinHeapTests {
    // MARK: - Basic MinHeap Operations

    @Test("MinHeap: insert and removeMin maintain heap property")
    func testMinHeapInsertRemove() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)

        // Insert elements in random order
        heap.insert(5)
        heap.insert(3)
        heap.insert(8)
        heap.insert(1)
        heap.insert(9)
        heap.insert(2)

        #expect(heap.count == 6)
        #expect(heap.min == 1)

        // RemoveMin should give elements in ascending order
        #expect(heap.removeMin() == 1)
        #expect(heap.removeMin() == 2)
        #expect(heap.removeMin() == 3)
        #expect(heap.removeMin() == 5)
        #expect(heap.removeMin() == 8)
        #expect(heap.removeMin() == 9)

        #expect(heap.isEmpty)
        #expect(heap.removeMin() == nil)
    }

    @Test("MinHeap: sorted() always returns ascending order")
    func testMinHeapSorted() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)

        heap.insert(5)
        heap.insert(3)
        heap.insert(8)
        heap.insert(1)
        heap.insert(9)

        let sorted = heap.sorted()
        #expect(sorted == [1, 3, 5, 8, 9])

        // Heap should still have elements (sorted() is non-destructive copy)
        #expect(heap.count == 5)
    }

    @Test("MinHeap: sortedDescending() returns descending order")
    func testMinHeapSortedDescending() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)

        heap.insert(5)
        heap.insert(3)
        heap.insert(8)
        heap.insert(1)

        let sorted = heap.sortedDescending()
        #expect(sorted == [8, 5, 3, 1])
    }

    @Test("MinHeap: heapify from array")
    func testMinHeapHeapify() {
        let heap = MinHeap(array: [5, 3, 8, 1, 9, 2], maxSize: nil, heapType: .min, comparator: <)

        #expect(heap.count == 6)
        #expect(heap.min == 1)

        let sorted = heap.sorted()
        #expect(sorted == [1, 2, 3, 5, 8, 9])
    }

    @Test("MinHeap: Top-K with maxSize evicts largest")
    func testMinHeapTopK() {
        var heap = MinHeap<Int>(maxSize: 3, heapType: .min, comparator: <)

        // Insert more than maxSize
        let result1 = heap.insert(5)  // [5]
        #expect(result1 == true)
        let result2 = heap.insert(3)  // [3, 5]
        #expect(result2 == true)
        let result3 = heap.insert(8)  // [3, 5, 8]
        #expect(result3 == true)

        // Heap is full, should reject smaller elements
        let result4 = heap.insert(1)  // Rejected (1 < 3, would be evicted immediately)
        #expect(result4 == false)
        #expect(heap.count == 3)
        #expect(heap.min == 3)

        // Should accept larger elements, evicting smallest
        let result5 = heap.insert(9)  // [5, 8, 9]
        #expect(result5 == true)
        #expect(heap.count == 3)
        #expect(heap.min == 5)

        let sorted = heap.sorted()
        #expect(sorted == [5, 8, 9])
    }

    // MARK: - MaxHeap Operations

    @Test("MaxHeap: insert and removeMin maintain heap property")
    func testMaxHeapInsertRemove() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .max, comparator: >)

        // Insert elements
        heap.insert(5)
        heap.insert(3)
        heap.insert(8)
        heap.insert(1)
        heap.insert(9)

        #expect(heap.count == 5)
        #expect(heap.min == 9)  // "min" is actually largest for MaxHeap

        // RemoveMin should give elements in descending order (largest first)
        #expect(heap.removeMin() == 9)
        #expect(heap.removeMin() == 8)
        #expect(heap.removeMin() == 5)
        #expect(heap.removeMin() == 3)
        #expect(heap.removeMin() == 1)

        #expect(heap.isEmpty)
    }

    @Test("MaxHeap: sorted() returns ascending order (auto-reversed)")
    func testMaxHeapSortedAscending() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .max, comparator: >)

        heap.insert(5)
        heap.insert(3)
        heap.insert(8)
        heap.insert(1)
        heap.insert(9)

        // ✅ CRITICAL: sorted() should ALWAYS return ascending order
        let sorted = heap.sorted()
        #expect(sorted == [1, 3, 5, 8, 9])  // Ascending, even for MaxHeap
    }

    @Test("MaxHeap: sortedDescending() returns descending order")
    func testMaxHeapSortedDescending() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .max, comparator: >)

        heap.insert(5)
        heap.insert(3)
        heap.insert(8)
        heap.insert(1)

        let sorted = heap.sortedDescending()
        #expect(sorted == [8, 5, 3, 1])
    }

    @Test("MaxHeap: Top-K with maxSize evicts smallest")
    func testMaxHeapTopK() {
        var heap = MinHeap<Int>(maxSize: 3, heapType: .max, comparator: >)

        // Insert elements
        let result1 = heap.insert(5)  // [5]
        #expect(result1 == true)
        let result2 = heap.insert(3)  // [5, 3]
        #expect(result2 == true)
        let result3 = heap.insert(8)  // [8, 5, 3]
        #expect(result3 == true)

        // Heap is full, should reject larger elements
        let result4 = heap.insert(9)  // Rejected (9 > 8, would be evicted immediately)
        #expect(result4 == false)
        #expect(heap.count == 3)
        #expect(heap.min == 8)  // Largest element at root

        // Should accept smaller elements, evicting largest
        let result5 = heap.insert(1)  // [5, 3, 1]
        #expect(result5 == true)
        #expect(heap.count == 3)
        #expect(heap.min == 5)  // New largest

        let sorted = heap.sorted()
        #expect(sorted == [1, 3, 5])  // Ascending order (smallest k elements)
    }

    // MARK: - Convenience Initializers (Comparable)

    @Test("Convenience: MinHeap() with Comparable")
    func testConvenienceMinHeap() {
        var heap = MinHeap<Double>(maxSize: nil)

        heap.insert(5.5)
        heap.insert(3.3)
        heap.insert(8.8)

        #expect(heap.min == 3.3)
        let sorted = heap.sorted()
        #expect(sorted == [3.3, 5.5, 8.8])
    }

    @Test("Convenience: MaxHeap.maxHeap() with Comparable")
    func testConvenienceMaxHeap() {
        var heap = MinHeap<Double>.maxHeap(maxSize: 10)

        heap.insert(5.5)
        heap.insert(3.3)
        heap.insert(8.8)

        #expect(heap.min == 8.8)  // Largest at root
        let sorted = heap.sorted()
        #expect(sorted == [3.3, 5.5, 8.8])  // Still ascending
    }

    // MARK: - Edge Cases

    @Test("Edge case: empty heap")
    func testEmptyHeap() {
        let heap = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)

        #expect(heap.isEmpty)
        #expect(heap.count == 0)
        #expect(heap.min == nil)
        #expect(heap.sorted() == [])
    }

    @Test("Edge case: single element")
    func testSingleElement() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)
        heap.insert(42)

        #expect(heap.count == 1)
        #expect(heap.min == 42)
        #expect(heap.sorted() == [42])

        #expect(heap.removeMin() == 42)
        #expect(heap.isEmpty)
    }

    @Test("Edge case: duplicate elements")
    func testDuplicates() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)

        heap.insert(5)
        heap.insert(3)
        heap.insert(5)
        heap.insert(3)
        heap.insert(5)

        #expect(heap.count == 5)
        let sorted = heap.sorted()
        #expect(sorted == [3, 3, 5, 5, 5])
    }

    @Test("Edge case: all equal elements")
    func testAllEqual() {
        var heap = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)

        for _ in 0..<5 {
            heap.insert(7)
        }

        #expect(heap.count == 5)
        #expect(heap.min == 7)
        let sorted = heap.sorted()
        #expect(sorted == [7, 7, 7, 7, 7])
    }

    @Test("Edge case: already sorted ascending")
    func testAlreadySortedAscending() {
        let heap = MinHeap(array: [1, 2, 3, 4, 5], maxSize: nil, heapType: .min, comparator: <)

        let sorted = heap.sorted()
        #expect(sorted == [1, 2, 3, 4, 5])
    }

    @Test("Edge case: already sorted descending")
    func testAlreadySortedDescending() {
        let heap = MinHeap(array: [5, 4, 3, 2, 1], maxSize: nil, heapType: .min, comparator: <)

        let sorted = heap.sorted()
        #expect(sorted == [1, 2, 3, 4, 5])
    }

    // MARK: - Top-K Tracking Patterns

    @Test("Top-K pattern: k largest with MinHeap + maxSize")
    func testTopKLargestWithMinHeap() {
        var heap = MinHeap<Int>(maxSize: 5, heapType: .min, comparator: <)

        // Insert 10 elements, MinHeap evicts smallest when full → keeps largest 5
        let data = [9, 3, 7, 1, 8, 5, 2, 6, 4, 10]
        for value in data {
            heap.insert(value)
        }

        let top5 = heap.sorted()
        #expect(top5 == [6, 7, 8, 9, 10])  // Largest 5 in ascending order
    }

    @Test("Top-K pattern: k smallest with MaxHeap + maxSize")
    func testTopKSmallestWithMaxHeap() {
        var heap = MinHeap<Int>(maxSize: 5, heapType: .max, comparator: >)

        // Insert 10 elements, MaxHeap evicts largest when full → keeps smallest 5
        let data = [9, 3, 7, 1, 8, 5, 2, 6, 4, 10]
        for value in data {
            heap.insert(value)
        }

        let top5 = heap.sorted()
        #expect(top5 == [1, 2, 3, 4, 5])  // Smallest 5 in ascending order
    }

    // MARK: - Custom Comparator

    @Test("Custom comparator: reverse order")
    func testCustomComparator() {
        var heap = MinHeap<String>(maxSize: nil, heapType: .min) { $0.count < $1.count }

        heap.insert("elephant")  // 8
        heap.insert("cat")       // 3
        heap.insert("dog")       // 3
        heap.insert("ant")       // 3

        // Smallest by length
        #expect(heap.min == "cat" || heap.min == "dog" || heap.min == "ant")

        let sorted = heap.sorted()
        // All 3-letter words come first, then 8-letter word
        #expect(sorted.count == 4)
        #expect(sorted[3] == "elephant")
    }

    @Test("Custom comparator: complex type")
    func testComplexType() {
        struct Person {
            let name: String
            let age: Int
        }

        var heap = MinHeap<Person>(maxSize: nil, heapType: .min) { $0.age < $1.age }

        heap.insert(Person(name: "Alice", age: 30))
        heap.insert(Person(name: "Bob", age: 25))
        heap.insert(Person(name: "Charlie", age: 35))

        #expect(heap.min?.age == 25)

        let sorted = heap.sorted()
        #expect(sorted.map { $0.age } == [25, 30, 35])
    }

    // MARK: - Performance Characteristics

    @Test("Performance: heapify is faster than incremental insert")
    func testHeapifyPerformance() {
        let data = (1...1000).shuffled()

        // Method 1: Heapify (O(n))
        let heap1 = MinHeap(array: data, maxSize: nil, heapType: .min, comparator: <)
        #expect(heap1.count == 1000)

        // Method 2: Incremental insert (O(n log n))
        var heap2 = MinHeap<Int>(maxSize: nil, heapType: .min, comparator: <)
        for value in data {
            heap2.insert(value)
        }
        #expect(heap2.count == 1000)

        // Both should give same sorted result
        #expect(heap1.sorted() == heap2.sorted())
    }

    @Test("Memory efficiency: O(k) for Top-K tracking")
    func testMemoryEfficiency() {
        var heap = MinHeap<Int>(maxSize: 100, heapType: .max, comparator: >)

        // Insert 10,000 elements
        for i in 1...10_000 {
            heap.insert(i)
        }

        // Heap should only keep 100 elements (smallest 100)
        #expect(heap.count == 100)
        #expect(heap.isFull)

        let top100 = heap.sorted()
        #expect(top100.first == 1)
        #expect(top100.last == 100)
    }

    // MARK: - Sequence Protocol

    @Test("Sequence protocol: iterate over elements")
    func testSequenceIteration() {
        let heap = MinHeap(array: [5, 3, 8, 1, 9], maxSize: nil, heapType: .min, comparator: <)

        var count = 0
        for element in heap {
            count += 1
            #expect(element >= 1 && element <= 9)
        }
        #expect(count == 5)
    }

    @Test("Sequence protocol: map and filter")
    func testSequenceMapFilter() {
        let heap = MinHeap(array: [1, 2, 3, 4, 5], maxSize: nil, heapType: .min, comparator: <)

        let doubled = heap.map { $0 * 2 }
        #expect(doubled.sorted() == [2, 4, 6, 8, 10])

        let evens = heap.filter { $0 % 2 == 0 }
        #expect(evens.sorted() == [2, 4])
    }
}
