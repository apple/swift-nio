//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@usableFromInline
internal struct PriorityQueue<Element: Comparable> {
    @usableFromInline
    internal var _heap: Heap<Element>

    internal init() {
        self._heap = Heap()
    }

    @inlinable
    internal mutating func remove(_ key: Element) {
        self._heap.remove(value: key)
    }

    @inlinable
    internal mutating func push(_ key: Element) {
        self._heap.append(key)
    }

    @inlinable
    internal func peek() -> Element? {
        return self._heap.storage.first
    }

    @inlinable
    internal var isEmpty: Bool {
        return self._heap.storage.isEmpty
    }

    @inlinable
    @discardableResult
    internal mutating func pop() -> Element? {
        return self._heap.removeRoot()
    }

    @inlinable
    internal mutating func clear() {
        self._heap = Heap()
    }
}

extension PriorityQueue: Equatable {
    @usableFromInline
    internal static func ==(lhs: PriorityQueue, rhs: PriorityQueue) -> Bool {
        return lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }
}

extension PriorityQueue: Sequence {
    @usableFromInline
    struct Iterator: IteratorProtocol {

        private var queue: PriorityQueue<Element>
        fileprivate init(queue: PriorityQueue<Element>) {
            self.queue = queue
        }

        public mutating func next() -> Element? {
            return self.queue.pop()
        }
    }

    @usableFromInline
    func makeIterator() -> Iterator {
        return Iterator(queue: self)
    }
}

extension PriorityQueue {
    var count: Int {
        return self._heap.count
    }
}

extension PriorityQueue: CustomStringConvertible {
    @usableFromInline
    var description: String {
        return "PriorityQueue(count: \(self.count)): \(Array(self))"
    }
}
