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
#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#elseif os(Windows)
import ucrt
#elseif canImport(Bionic)
@preconcurrency import Bionic
#else
#error("The Heap module was unable to identify your C library.")
#endif

@usableFromInline
internal struct Heap<Element: Comparable> {
    @usableFromInline
    internal var _storage: [Element]

    /// Read-only view of the heap's backing storage.
    ///
    /// - Note: `_storage` must only be modified by `Heap` itself.
    @inlinable
    internal var storage: [Element] {
        self._storage
    }

    @inlinable
    internal init() {
        self._storage = []
    }

    @inlinable
    internal func comparator(_ lhs: Element, _ rhs: Element) -> Bool {
        // This heap is always a min-heap.
        lhs < rhs
    }

    // named `PARENT` in CLRS
    @inlinable
    internal func parentIndex(_ i: Int) -> Int {
        (i - 1) / 2
    }

    // named `LEFT` in CLRS
    @inlinable
    internal func leftIndex(_ i: Int) -> Int {
        2 * i + 1
    }

    // named `RIGHT` in CLRS
    @inlinable
    internal func rightIndex(_ i: Int) -> Int {
        2 * i + 2
    }

    // named `MAX-HEAPIFY` in CLRS
    @inlinable
    mutating func _heapify(_ index: Int) {
        let left = self.leftIndex(index)
        let right = self.rightIndex(index)

        var root: Int
        if left <= (self._storage.count - 1) && self.comparator(self._storage[left], self._storage[index]) {
            root = left
        } else {
            root = index
        }

        if right <= (self._storage.count - 1) && self.comparator(self._storage[right], self._storage[root]) {
            root = right
        }

        if root != index {
            self._storage.swapAt(index, root)
            self._heapify(root)
        }
    }

    // named `HEAP-INCREASE-KEY` in CRLS
    @inlinable
    mutating func _heapRootify(index: Int, key: Element) {
        var index = index
        if self.comparator(self._storage[index], key) {
            fatalError("New key must be closer to the root than current key")
        }

        self._storage[index] = key
        while index > 0 && self.comparator(self._storage[index], self._storage[self.parentIndex(index)]) {
            self._storage.swapAt(index, self.parentIndex(index))
            index = self.parentIndex(index)
        }
    }

    @inlinable
    internal mutating func append(_ value: Element) {
        var i = self._storage.count
        self._storage.append(value)
        while i > 0 && self.comparator(self._storage[i], self._storage[self.parentIndex(i)]) {
            self._storage.swapAt(i, self.parentIndex(i))
            i = self.parentIndex(i)
        }
    }

    @discardableResult
    @inlinable
    internal mutating func removeRoot() -> Element? {
        self._remove(index: 0)
    }

    @discardableResult
    @inlinable
    internal mutating func remove(value: Element) -> Bool {
        if let idx = self._storage.firstIndex(of: value) {
            self._remove(index: idx)
            return true
        } else {
            return false
        }
    }

    @discardableResult
    @inlinable
    internal mutating func removeFirst(where shouldBeRemoved: (Element) throws -> Bool) rethrows -> Element? {
        guard self._storage.count > 0 else {
            return nil
        }

        guard let index = try self._storage.firstIndex(where: shouldBeRemoved) else {
            return nil
        }

        return self._remove(index: index)
    }

    @discardableResult
    @inlinable
    mutating func _remove(index: Int) -> Element? {
        guard self._storage.count > 0 else {
            return nil
        }
        let element = self._storage[index]
        if self._storage.count == 1 || self._storage[index] == self._storage[self._storage.count - 1] {
            self._storage.removeLast()
        } else if !self.comparator(self._storage[index], self._storage[self._storage.count - 1]) {
            self._heapRootify(index: index, key: self._storage[self._storage.count - 1])
            self._storage.removeLast()
        } else {
            self._storage[index] = self._storage[self._storage.count - 1]
            self._storage.removeLast()
            self._heapify(index)
        }
        return element
    }
}

extension Heap: CustomDebugStringConvertible {
    @inlinable
    var debugDescription: String {
        guard self._storage.count > 0 else {
            return "<empty heap>"
        }
        let descriptions = self._storage.map { String(describing: $0) }
        let maxLen: Int = descriptions.map { $0.count }.max()!  // storage checked non-empty above
        let paddedDescs = descriptions.map { (desc: String) -> String in
            var desc = desc
            while desc.count < maxLen {
                if desc.count % 2 == 0 {
                    desc = " \(desc)"
                } else {
                    desc = "\(desc) "
                }
            }
            return desc
        }

        var all = "\n"
        let spacing = String(repeating: " ", count: maxLen)
        func subtreeWidths(rootIndex: Int) -> (Int, Int) {
            let lcIdx = self.leftIndex(rootIndex)
            let rcIdx = self.rightIndex(rootIndex)
            var leftSpace = 0
            var rightSpace = 0
            if lcIdx < self._storage.count {
                let sws = subtreeWidths(rootIndex: lcIdx)
                leftSpace += sws.0 + sws.1 + maxLen
            }
            if rcIdx < self._storage.count {
                let sws = subtreeWidths(rootIndex: rcIdx)
                rightSpace += sws.0 + sws.1 + maxLen
            }
            return (leftSpace, rightSpace)
        }
        for (index, desc) in paddedDescs.enumerated() {
            let (leftWidth, rightWidth) = subtreeWidths(rootIndex: index)
            all += String(repeating: " ", count: leftWidth)
            all += desc
            all += String(repeating: " ", count: rightWidth)

            func height(index: Int) -> Int {
                Int(log2(Double(index + 1)))
            }
            let myHeight = height(index: index)
            let nextHeight = height(index: index + 1)
            if myHeight != nextHeight {
                all += "\n"
            } else {
                all += spacing
            }
        }
        all += "\n"
        return all
    }
}

@usableFromInline
struct HeapIterator<Element: Comparable>: IteratorProtocol {
    @usableFromInline
    var _heap: Heap<Element>

    @inlinable
    init(heap: Heap<Element>) {
        self._heap = heap
    }

    @inlinable
    mutating func next() -> Element? {
        self._heap.removeRoot()
    }
}

extension Heap: Sequence {
    @inlinable
    var startIndex: Int {
        self._storage.startIndex
    }

    @inlinable
    var endIndex: Int {
        self._storage.endIndex
    }

    @inlinable
    var underestimatedCount: Int {
        self._storage.count
    }

    @inlinable
    func makeIterator() -> HeapIterator<Element> {
        HeapIterator(heap: self)
    }

    @inlinable
    subscript(position: Int) -> Element {
        self._storage[position]
    }

    @inlinable
    func index(after i: Int) -> Int {
        i + 1
    }

    @inlinable
    var count: Int {
        self._storage.count
    }
}

extension Heap: Sendable where Element: Sendable {}
extension HeapIterator: Sendable where Element: Sendable {}
