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
internal struct Heap<Element: Comparable> {
    @usableFromInline
    internal private(set) var storage: ContiguousArray<Element> = []

    @usableFromInline
    internal init() {}

    internal func comparator(_ lhs: Element, _ rhs: Element) -> Bool {
        // This heap is always a min-heap.
        lhs < rhs
    }

    // named `PARENT` in CLRS
    private func parentIndex(_ i: Int) -> Int {
        (i - 1) / 2
    }

    // named `LEFT` in CLRS
    internal func leftIndex(_ i: Int) -> Int {
        2 * i + 1
    }

    // named `RIGHT` in CLRS
    internal func rightIndex(_ i: Int) -> Int {
        2 * i + 2
    }

    // named `MAX-HEAPIFY` in CLRS
    private mutating func heapify(_ index: Int) {
        let left = leftIndex(index)
        let right = rightIndex(index)

        var root: Int
        if left <= (storage.count - 1), comparator(storage[left], storage[index]) {
            root = left
        } else {
            root = index
        }

        if right <= (storage.count - 1), comparator(storage[right], storage[root]) {
            root = right
        }

        if root != index {
            storage.swapAt(index, root)
            heapify(root)
        }
    }

    // named `HEAP-INCREASE-KEY` in CRLS
    private mutating func heapRootify(index: Int, key: Element) {
        var index = index
        if comparator(storage[index], key) {
            fatalError("New key must be closer to the root than current key")
        }

        storage[index] = key
        while index > 0, comparator(storage[index], storage[parentIndex(index)]) {
            storage.swapAt(index, parentIndex(index))
            index = parentIndex(index)
        }
    }

    @usableFromInline
    internal mutating func append(_ value: Element) {
        var i = storage.count
        storage.append(value)
        while i > 0, comparator(storage[i], storage[parentIndex(i)]) {
            storage.swapAt(i, parentIndex(i))
            i = parentIndex(i)
        }
    }

    @discardableResult
    @usableFromInline
    internal mutating func removeRoot() -> Element? {
        remove(index: 0)
    }

    @discardableResult
    @usableFromInline
    internal mutating func remove(value: Element) -> Bool {
        if let idx = storage.firstIndex(of: value) {
            remove(index: idx)
            return true
        } else {
            return false
        }
    }

    @discardableResult
    private mutating func remove(index: Int) -> Element? {
        guard storage.count > 0 else {
            return nil
        }
        let element = storage[index]
        if storage.count == 1 || storage[index] == storage[storage.count - 1] {
            storage.removeLast()
        } else if !comparator(storage[index], storage[storage.count - 1]) {
            heapRootify(index: index, key: storage[storage.count - 1])
            storage.removeLast()
        } else {
            storage[index] = storage[storage.count - 1]
            storage.removeLast()
            heapify(index)
        }
        return element
    }
}

extension Heap: CustomDebugStringConvertible {
    @usableFromInline
    var debugDescription: String {
        guard storage.count > 0 else {
            return "<empty heap>"
        }
        let descriptions = storage.map { String(describing: $0) }
        let maxLen: Int = descriptions.map(\.count).max()! // storage checked non-empty above
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
            let lcIdx = leftIndex(rootIndex)
            let rcIdx = rightIndex(rootIndex)
            var leftSpace = 0
            var rightSpace = 0
            if lcIdx < storage.count {
                let sws = subtreeWidths(rootIndex: lcIdx)
                leftSpace += sws.0 + sws.1 + maxLen
            }
            if rcIdx < storage.count {
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
    private var heap: Heap<Element>

    init(heap: Heap<Element>) {
        self.heap = heap
    }

    @usableFromInline
    mutating func next() -> Element? {
        heap.removeRoot()
    }
}

extension Heap: Sequence {
    var startIndex: Int { storage.startIndex }
    var endIndex: Int { storage.endIndex }

    @usableFromInline
    var underestimatedCount: Int {
        storage.count
    }

    @usableFromInline
    func makeIterator() -> HeapIterator<Element> {
        HeapIterator(heap: self)
    }

    subscript(position: Int) -> Element {
        storage[position]
    }

    func index(after i: Int) -> Int {
        i + 1
    }

    var count: Int {
        storage.count
    }
}
