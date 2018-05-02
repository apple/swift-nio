//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

internal struct PriorityQueue<Element: Comparable> {
    private var heap: Heap<Element>

    public init(ascending: Bool = false) {
        self.heap = Heap(type: ascending ? .minHeap : .maxHeap)
    }

    public mutating func remove(_ key: Element) {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        _ = self.heap.remove(value: key)
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
    }

    public mutating func push(_ key: Element) {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        self.heap.append(key)
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
    }

    public func peek() -> Element? {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        return self.heap.storage.first
    }

    public var isEmpty: Bool {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        return self.heap.storage.isEmpty
    }

    public mutating func pop() -> Element? {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        return self.heap.removeRoot()
    }

    public mutating func clear() {
        self.heap = Heap(type: self.heap.type)
    }
}

extension PriorityQueue: Equatable {
    public static func ==(lhs: PriorityQueue, rhs: PriorityQueue) -> Bool {
        return lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }
}

extension PriorityQueue: Sequence {
    public struct Iterator: IteratorProtocol {

        private var queue: PriorityQueue<Element>
        fileprivate init(queue: PriorityQueue<Element>) {
            self.queue = queue
        }

        public mutating func next() -> Element? {
            return self.queue.pop()
        }
    }

    public func makeIterator() -> Iterator {
        return Iterator(queue: self)
    }
}

internal extension PriorityQueue {
    var count: Int {
        return self.heap.count
    }
}

extension PriorityQueue: CustomStringConvertible {
    public var description: String {
        return "PriorityQueue(count: \(self.underestimatedCount)): \(Array(self))"
    }
}

extension PriorityQueue {
  @available(*, deprecated, renamed: "Element")
  public typealias T = Element
  @available(*, deprecated, renamed: "PriorityQueue.Iterator")
  typealias PriorityQueueIterator<T: Comparable> = PriorityQueue<T>.Iterator
}

extension PriorityQueue.Iterator {
  @available(*, deprecated, renamed: "Element")
  typealias T = Element
}
