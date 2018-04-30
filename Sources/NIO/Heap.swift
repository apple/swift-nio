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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

internal enum HeapType {
    case maxHeap
    case minHeap

    public func comparator<T: Comparable>(type: T.Type) -> (T, T) -> Bool {
        switch self {
        case .maxHeap:
            return (>)
        case .minHeap:
            return (<)
        }
    }
}

internal struct Heap<T: Comparable> {
    internal let type: HeapType
    internal private(set) var storage: ContiguousArray<T> = []
    private let comparator: (T, T) -> Bool

    internal init?(type: HeapType, storage: ContiguousArray<T>) {
        self.comparator = type.comparator(type: T.self)
        self.storage = storage
        self.type = type
        if !self.checkHeapProperty() {
            return nil
        }
    }

    public init(type: HeapType) {
        self.comparator = type.comparator(type: T.self)
        self.type = type
    }

    // MARK: verbatim from CLRS's (Introduction to Algorithms) Heapsort chapter with the following changes
    //  - added a `compare` parameter to make it either a min or a max heap
    //  - renamed `largest` to `root`
    //  - removed `max` from the method names like `maxHeapify`, `maxHeapInsert` etc
    //  - made the arrays 0-based

    // named `PARENT` in CLRS
    private static func parentIndex(_ i: Int) -> Int {
        return (i-1) / 2
    }

    // named `LEFT` in CLRS
    private static func leftIndex(_ i: Int) -> Int {
        return 2*i + 1
    }

    // named `RIGHT` in CLRS
    private static func rightIndex(_ i: Int) -> Int {
        return 2*i + 2
    }

    // named `MAX-HEAPIFY` in CLRS
    private static func heapify(storage: inout ContiguousArray<T>, compare: (T, T) -> Bool, _ i: Int) {
        let l = Heap<T>.leftIndex(i)
        let r = Heap<T>.rightIndex(i)

        var root: Int
        if l <= (storage.count - 1) && compare(storage[l], storage[i]) {
            root = l
        } else {
            root = i
        }

        if r <= (storage.count - 1) && compare(storage[r], storage[root]) {
            root = r
        }

        if root != i {
            storage.swapAt(i, root)
            heapify(storage: &storage, compare: compare, root)
        }
    }

    // named `MAX-HEAP-INSERT` in CRLS
    private static func heapInsert(storage: inout ContiguousArray<T>, compare: (T, T) -> Bool, key: T) {
        var i = storage.count
        storage.append(key)
        while i > 0 && compare(storage[i], storage[parentIndex(i)]) {
            storage.swapAt(i, parentIndex(i))
            i = parentIndex(i)
        }
    }

    // named `HEAP-INCREASE-KEY` in CRLS
    private static func heapRootify(storage: inout ContiguousArray<T>, compare: (T, T) -> Bool, index: Int, key: T) {
        var index = index
        if compare(storage[index], key) {
            fatalError("New key must be closer to the root than current key")
        }

        storage[index] = key
        while index > 0 && compare(storage[index], storage[parentIndex(index)]) {
            storage.swapAt(index, parentIndex(index))
            index = parentIndex(index)
        }
    }

    // MARK: Swift interface using the low-level methods above
    public mutating func append(_ value: T) {
        Heap<T>.heapInsert(storage: &self.storage, compare: self.comparator, key: value)
    }

    public mutating func removeRoot() -> T? {
        return self.remove(index: 0)
    }

    public mutating func remove(value: T) -> Bool {
        if let idx = self.storage.index(of: value) {
            _ = self.remove(index: idx)
            return true
        } else {
            return false
        }
    }

    private mutating func remove(index: Int) -> T? {
        guard self.storage.count > 0 else {
            return nil
        }
        let element = self.storage[index]
        if self.storage.count == 1 || self.storage[index] == self.storage[self.storage.count - 1] {
            _ = self.storage.removeLast()
        } else if !self.comparator(self.storage[index], self.storage[self.storage.count - 1]) {
            Heap<T>.heapRootify(storage: &self.storage, compare: self.comparator, index: index, key: self.storage[self.storage.count - 1])
            _ = self.storage.removeLast()
        } else {
            self.storage[index] = self.storage[self.storage.count - 1]
            _ = self.storage.removeLast()
            Heap<T>.heapify(storage: &self.storage, compare: self.comparator, index)
        }
        return element
    }

    internal func checkHeapProperty() -> Bool {
        func checkHeapProperty(index: Int) -> Bool {
            let li = Heap<T>.leftIndex(index)
            let ri = Heap<T>.rightIndex(index)
            if index >= self.storage.count {
                return true
            } else {
                let me = self.storage[index]
                var lCond = true
                var rCond = true
                if li < self.storage.count {
                    let l = self.storage[li]
                    lCond = !self.comparator(l, me)
                }
                if ri < self.storage.count {
                    let r = self.storage[ri]
                    rCond = !self.comparator(r, me)
                }
                return lCond && rCond && checkHeapProperty(index: li) && checkHeapProperty(index: ri)
            }
        }
        return checkHeapProperty(index: 0)
    }
}

extension Heap: CustomDebugStringConvertible {
    public var debugDescription: String {
        guard self.storage.count > 0 else {
            return "<empty heap>"
        }
        let descriptions = self.storage.map { String(describing: $0) }
        let maxLen: Int = descriptions.map { $0.count }.max()!
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
            let lcIdx = Heap<T>.leftIndex(rootIndex)
            let rcIdx = Heap<T>.rightIndex(rootIndex)
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

struct HeapIterator<T: Comparable>: IteratorProtocol {
    typealias Element = T

    private var heap: Heap<T>

    init(heap: Heap<T>) {
        self.heap = heap
    }

    mutating func next() -> T? {
        return self.heap.removeRoot()
    }
}

extension Heap: Sequence {
    typealias Element = T

    var startIndex: Int { return self.storage.startIndex }
    var endIndex: Int { return self.storage.endIndex }

    var underestimatedCount: Int {
        return self.storage.count
    }

    func makeIterator() -> HeapIterator<T> {
        return HeapIterator(heap: self)
    }

    subscript(position: Int) -> T {
        return self.storage[position]
    }

    func index(after i: Int) -> Int {
        return i + 1
    }

    var count: Int {
        return self.storage.count
    }
}
