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

public struct PriorityQueue<T: Comparable> {
    private var heap: Heap<T>
    
    public init(ascending: Bool = false) {
        self.heap = Heap(type: ascending ? .minHeap : .maxHeap)
    }
    
    public mutating func remove(_ key: T) {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        _ = self.heap.remove(value: key)
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
    }
    
    public mutating func push(_ key: T) {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        self.heap.append(key)
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
    }
    
    public func peek() -> T? {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        return self.heap.storage.first
    }
    
    public var isEmpty: Bool {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        return self.heap.storage.isEmpty
    }
    
    public mutating func pop() -> T? {
        assert(self.heap.checkHeapProperty(), "broken heap: \(self.heap.debugDescription)")
        return self.heap.removeRoot()
    }

    public mutating func clear() {
        self.heap = Heap(type: self.heap.type)
    }
}


extension PriorityQueue: Sequence {
    public struct PriorityQueueIterator<T: Comparable>: IteratorProtocol {
        public typealias Element = T

        private var queue: PriorityQueue<T>
        fileprivate init(queue: PriorityQueue<T>) {
            self.queue = queue
        }

        public mutating func next() -> T? {
            return self.queue.pop()
        }
    }

    public typealias Element = T
    public typealias Iterator = PriorityQueueIterator<T>

    public func makeIterator() -> PriorityQueueIterator<Element> {
        return PriorityQueueIterator(queue: self)
    }
}

extension PriorityQueue: CustomStringConvertible {
    public var description: String {
        return "PriorityQueue(count: \(self.underestimatedCount))"
    }
}
