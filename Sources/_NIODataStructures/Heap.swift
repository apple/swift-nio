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
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin.C
#elseif os(Linux) || os(FreeBSD) || os(Android)
import Glibc
#endif

@usableFromInline
internal struct Heap<Element: Comparable> {
    @usableFromInline
    internal private(set) var storage: Array<Element>

    @inlinable
    internal init() {
        self.storage = []
    }

    @inlinable
    internal func comparator(_ lhs: Element, _ rhs: Element) -> Bool {
        // This heap is always a min-heap.
        return lhs < rhs
    }

    // named `PARENT` in CLRS
    @inlinable
    internal func parentIndex(_ i: Int) -> Int {
        return (i-1) / 2
    }

    // named `LEFT` in CLRS
    @inlinable
    internal func leftIndex(_ i: Int) -> Int {
        return 2*i + 1
    }

    // named `RIGHT` in CLRS
    @inlinable
    internal func rightIndex(_ i: Int) -> Int {
        return 2*i + 2
    }

    // named `MAX-HEAPIFY` in CLRS
    /* private but */ @inlinable
    mutating func _heapify(_ index: Int) {
        let left = self.leftIndex(index)
        let right = self.rightIndex(index)

        var root: Int
        if left <= (self.storage.count - 1) && self.comparator(storage[left], storage[index]) {
            root = left
        } else {
            root = index
        }

        if right <= (self.storage.count - 1) && self.comparator(storage[right], storage[root]) {
            root = right
        }

        if root != index {
            self.storage.swapAt(index, root)
            self._heapify(root)
        }
    }

    // named `HEAP-INCREASE-KEY` in CRLS
    /* private but */ @inlinable
    mutating func _heapRootify(index: Int, key: Element) {
        var index = index
        if self.comparator(storage[index], key) {
            fatalError("New key must be closer to the root than current key")
        }

        self.storage[index] = key
        while index > 0 && self.comparator(self.storage[index], self.storage[self.parentIndex(index)]) {
            self.storage.swapAt(index, self.parentIndex(index))
            index = self.parentIndex(index)
        }
    }

    @inlinable
    internal mutating func append(_ value: Element) {
        var i = self.storage.count
        self.storage.append(value)
        while i > 0 && self.comparator(self.storage[i], self.storage[self.parentIndex(i)]) {
            self.storage.swapAt(i, self.parentIndex(i))
            i = self.parentIndex(i)
        }
    }

    @discardableResult
    @inlinable
    internal mutating func removeRoot() -> Element? {
        return self._remove(index: 0)
    }

    @discardableResult
    @inlinable
    internal mutating func remove(value: Element) -> Bool {
        if let idx = self.storage.firstIndex(of: value) {
            self._remove(index: idx)
            return true
        } else {
            return false
        }
    }
    
    @inlinable
    internal mutating func removeFirst(where shouldBeRemoved: (Element) throws -> Bool) rethrows {
        guard self.storage.count > 0 else {
            return
        }

        guard let index = try self.storage.firstIndex(where: shouldBeRemoved) else {
            return
        }
        
        self._remove(index: index)
    }

    @discardableResult
    /* private but */ @inlinable
    mutating func _remove(index: Int) -> Element? {
        guard self.storage.count > 0 else {
            return nil
        }
        let element = self.storage[index]
        if self.storage.count == 1 || self.storage[index] == self.storage[self.storage.count - 1] {
            self.storage.removeLast()
        } else if !self.comparator(self.storage[index], self.storage[self.storage.count - 1]) {
            self._heapRootify(index: index, key: self.storage[self.storage.count - 1])
            self.storage.removeLast()
        } else {
            self.storage[index] = self.storage[self.storage.count - 1]
            self.storage.removeLast()
            self._heapify(index)
        }
        return element
    }
}

extension Heap: CustomDebugStringConvertible {
    @inlinable
    var debugDescription: String {
        guard self.storage.count > 0 else {
            return "<empty heap>"
        }
        let descriptions = self.storage.map { String(describing: $0) }
        let maxLen: Int = descriptions.map { $0.count }.max()! // storage checked non-empty above
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
            if lcIdx < self.storage.count {
                let sws = subtreeWidths(rootIndex: lcIdx)
                leftSpace += sws.0 + sws.1 + maxLen
            }
            if rcIdx < self.storage.count {
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
                return Int(log2(Double(index + 1)))
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
    /* private but */ @usableFromInline
    var _heap: Heap<Element>

    @inlinable
    init(heap: Heap<Element>) {
        self._heap = heap
    }

    @inlinable
    mutating func next() -> Element? {
        return self._heap.removeRoot()
    }
}

extension Heap: Sequence {
    @inlinable
    var startIndex: Int {
        return self.storage.startIndex
    }

    @inlinable
    var endIndex: Int {
        return self.storage.endIndex
    }

    @inlinable
    var underestimatedCount: Int {
        return self.storage.count
    }

    @inlinable
    func makeIterator() -> HeapIterator<Element> {
        return HeapIterator(heap: self)
    }

    @inlinable
    subscript(position: Int) -> Element {
        return self.storage[position]
    }

    @inlinable
    func index(after i: Int) -> Int {
        return i + 1
    }

    @inlinable
    var count: Int {
        return self.storage.count
    }
}
