//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public struct PriorityQueue<Element: Comparable> {
    @usableFromInline
    internal var _heap: Heap<Element>

    @inlinable
    public init() {
        self._heap = Heap()
    }

    @inlinable
    public mutating func remove(_ key: Element) {
        self._heap.remove(value: key)
    }

    @discardableResult
    @inlinable
    public mutating func removeFirst(where shouldBeRemoved: (Element) throws -> Bool) rethrows -> Element? {
        try self._heap.removeFirst(where: shouldBeRemoved)
    }

    @inlinable
    public mutating func push(_ key: Element) {
        self._heap.append(key)
    }

    @inlinable
    public func peek() -> Element? {
        self._heap.storage.first
    }

    @inlinable
    public var isEmpty: Bool {
        self._heap.storage.isEmpty
    }

    @inlinable
    @discardableResult
    public mutating func pop() -> Element? {
        self._heap.removeRoot()
    }

    @inlinable
    public mutating func clear() {
        self._heap = Heap()
    }
}

extension PriorityQueue: Equatable {
    @inlinable
    public static func == (lhs: PriorityQueue, rhs: PriorityQueue) -> Bool {
        lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }
}

extension PriorityQueue: Sequence {
    public struct Iterator: IteratorProtocol {

        @usableFromInline
        var _queue: PriorityQueue<Element>

        @inlinable
        public init(queue: PriorityQueue<Element>) {
            self._queue = queue
        }

        @inlinable
        public mutating func next() -> Element? {
            self._queue.pop()
        }
    }

    @inlinable
    public func makeIterator() -> Iterator {
        Iterator(queue: self)
    }
}

extension PriorityQueue {
    @inlinable
    public var count: Int {
        self._heap.count
    }
}

extension PriorityQueue: CustomStringConvertible {
    @inlinable
    public var description: String {
        "PriorityQueue(count: \(self.count)): \(Array(self))"
    }
}

extension PriorityQueue: Sendable where Element: Sendable {}
extension PriorityQueue.Iterator: Sendable where Element: Sendable {}
