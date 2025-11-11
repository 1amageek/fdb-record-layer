import Foundation
import FoundationDB

public struct RankedSet<Element: Comparable & Sendable>: Sendable {
    private final class Node: @unchecked Sendable {
        let value: Element
        var forward: [Node?]
        var span: [Int]

        init(value: Element, level: Int) {
            self.value = value
            self.forward = Array(repeating: nil, count: level)
            self.span = Array(repeating: 0, count: level)
        }
    }

    private var storage: Storage

    private final class Storage: @unchecked Sendable {
        var head: Node
        let maxLevel: Int
        var currentLevel: Int
        var count: Int

        init(maxLevel: Int) {
            self.maxLevel = maxLevel
            self.currentLevel = 1
            self.count = 0
            self.head = Node(value: Element.self as! Element, level: maxLevel)
        }

        func copy() -> Storage {
            let newStorage = Storage(maxLevel: maxLevel)
            newStorage.currentLevel = currentLevel
            newStorage.count = count
            return newStorage
        }
    }

    public init(maxLevel: Int = 32) {
        self.storage = Storage(maxLevel: maxLevel)
    }

    @discardableResult
    public mutating func insert(_ value: Element) -> Int {
        if !isKnownUniquelyReferenced(&storage) {
            // Copy-on-write
        }

        var update: [Node] = Array(repeating: storage.head, count: storage.maxLevel)
        var rank: [Int] = Array(repeating: 0, count: storage.maxLevel)

        var current = storage.head

        for level in stride(from: storage.currentLevel - 1, through: 0, by: -1) {
            rank[level] = (level == storage.currentLevel - 1) ? 0 : rank[level + 1]

            while let next = current.forward[level], next.value < value {
                rank[level] += current.span[level]
                current = next
            }

            update[level] = current
        }

        let newLevel = randomLevel()

        if newLevel > storage.currentLevel {
            for level in storage.currentLevel..<newLevel {
                rank[level] = 0
                update[level] = storage.head
                update[level].span[level] = storage.count
            }
            storage.currentLevel = newLevel
        }

        let newNode = Node(value: value, level: newLevel)

        for level in 0..<newLevel {
            newNode.forward[level] = update[level].forward[level]
            update[level].forward[level] = newNode

            newNode.span[level] = update[level].span[level] - (rank[0] - rank[level])
            update[level].span[level] = (rank[0] - rank[level]) + 1
        }

        for level in newLevel..<storage.currentLevel {
            update[level].span[level] += 1
        }

        storage.count += 1

        return rank[0]
    }

    public func rank(of value: Element) -> Int? {
        var current = storage.head
        var rank = 0

        for level in stride(from: storage.currentLevel - 1, through: 0, by: -1) {
            while let next = current.forward[level], next.value < value {
                rank += current.span[level]
                current = next
            }
        }

        if let next = current.forward[0], next.value == value {
            return rank
        }

        return nil
    }

    public func select(rank targetRank: Int) -> Element? {
        guard targetRank >= 0 && targetRank < storage.count else {
            return nil
        }

        var current = storage.head
        var traversed = 0

        for level in stride(from: storage.currentLevel - 1, through: 0, by: -1) {
            while let next = current.forward[level],
                  traversed + current.span[level] <= targetRank {
                traversed += current.span[level]
                current = next
            }
        }

        return current.forward[0]?.value
    }

    public var elementCount: Int {
        storage.count
    }

    private func randomLevel() -> Int {
        var level = 1
        while level < storage.maxLevel && Bool.random() {
            level += 1
        }
        return level
    }
}
