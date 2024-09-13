//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftCertificates open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftCertificates project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftCertificates project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// ``TinyArray`` is a ``RandomAccessCollection`` optimised to store zero or one ``Element``.
/// It supports arbitrary many elements but if only up to one ``Element`` is stored it does **not** allocate separate storage on the heap
/// and instead stores the ``Element`` inline.
public struct _TinyArray<Element> {
    @usableFromInline
    enum Storage {
        case one(Element)
        case arbitrary([Element])
    }

    @usableFromInline
    var storage: Storage
}

// MARK: - TinyArray "public" interface

extension _TinyArray: Equatable where Element: Equatable {}
extension _TinyArray: Hashable where Element: Hashable {}
extension _TinyArray: Sendable where Element: Sendable {}

extension _TinyArray: RandomAccessCollection {
    public typealias Element = Element

    public typealias Index = Int

    @inlinable
    public func makeIterator() -> Iterator {
        Iterator(storage: self.storage)
    }

    public struct Iterator: IteratorProtocol {
        @usableFromInline
        let _storage: Storage
        @usableFromInline
        var _index: Index

        @usableFromInline
        init(storage: Storage) {
            self._storage = storage
            self._index = storage.startIndex
        }

        @inlinable
        public mutating func next() -> Element? {
            if self._index == self._storage.endIndex {
                return nil
            }

            defer {
                self._index &+= 1
            }

            return self._storage[self._index]
        }
    }

    @inlinable
    public subscript(position: Int) -> Element {
        get {
            self.storage[position]
        }
    }

    @inlinable
    public var startIndex: Int {
        self.storage.startIndex
    }

    @inlinable
    public var endIndex: Int {
        self.storage.endIndex
    }
}

extension _TinyArray.Iterator: Sendable where Element: Sendable {}

extension _TinyArray {
    @inlinable
    public init(_ elements: some Sequence<Element>) {
        self.storage = .init(elements)
    }

    @inlinable
    public init(_ elements: some Sequence<Result<Element, some Error>>) throws {
        self.storage = try .init(elements)
    }

    @inlinable
    public init() {
        self.storage = .init()
    }

    @inlinable
    public mutating func append(_ newElement: Element) {
        self.storage.append(newElement)
    }

    @inlinable
    public mutating func append(contentsOf newElements: some Sequence<Element>) {
        self.storage.append(contentsOf: newElements)
    }

    @discardableResult
    @inlinable
    public mutating func remove(at index: Int) -> Element {
        self.storage.remove(at: index)
    }

    @inlinable
    public mutating func removeAll(where shouldBeRemoved: (Element) throws -> Bool) rethrows {
        try self.storage.removeAll(where: shouldBeRemoved)
    }

    @inlinable
    public mutating func sort(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows {
        try self.storage.sort(by: areInIncreasingOrder)
    }
}

// MARK: - TinyArray.Storage "private" implementation

extension _TinyArray.Storage: Equatable where Element: Equatable {
    @inlinable
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.one(let lhs), .one(let rhs)):
            return lhs == rhs
        case (.arbitrary(let lhs), .arbitrary(let rhs)):
            // we don't use lhs.elementsEqual(rhs) so we can hit the fast path from Array
            // if both arrays share the same underlying storage: https://github.com/apple/swift/blob/b42019005988b2d13398025883e285a81d323efa/stdlib/public/core/Array.swift#L1775
            return lhs == rhs

        case (.one(let element), .arbitrary(let array)),
            (.arbitrary(let array), .one(let element)):
            guard array.count == 1 else {
                return false
            }
            return element == array[0]

        }
    }
}
extension _TinyArray.Storage: Hashable where Element: Hashable {
    @inlinable
    func hash(into hasher: inout Hasher) {
        // same strategy as Array: https://github.com/apple/swift/blob/b42019005988b2d13398025883e285a81d323efa/stdlib/public/core/Array.swift#L1801
        hasher.combine(count)
        for element in self {
            hasher.combine(element)
        }
    }
}
extension _TinyArray.Storage: Sendable where Element: Sendable {}

extension _TinyArray.Storage: RandomAccessCollection {
    @inlinable
    subscript(position: Int) -> Element {
        get {
            switch self {
            case .one(let element):
                guard position == 0 else {
                    fatalError("index \(position) out of bounds")
                }
                return element
            case .arbitrary(let elements):
                return elements[position]
            }
        }
    }

    @inlinable
    var startIndex: Int {
        0
    }

    @inlinable
    var endIndex: Int {
        switch self {
        case .one: return 1
        case .arbitrary(let elements): return elements.endIndex
        }
    }
}

extension _TinyArray.Storage {
    @inlinable
    init(_ elements: some Sequence<Element>) {
        self = .arbitrary([])
        self.append(contentsOf: elements)
    }

    @inlinable
    init(_ newElements: some Sequence<Result<Element, some Error>>) throws {
        var iterator = newElements.makeIterator()
        guard let firstElement = try iterator.next()?.get() else {
            self = .arbitrary([])
            return
        }
        guard let secondElement = try iterator.next()?.get() else {
            // newElements just contains a single element
            // and we hit the fast path
            self = .one(firstElement)
            return
        }

        var elements: [Element] = []
        elements.reserveCapacity(newElements.underestimatedCount)
        elements.append(firstElement)
        elements.append(secondElement)
        while let nextElement = try iterator.next()?.get() {
            elements.append(nextElement)
        }
        self = .arbitrary(elements)
    }

    @inlinable
    init() {
        self = .arbitrary([])
    }

    @inlinable
    mutating func append(_ newElement: Element) {
        self.append(contentsOf: CollectionOfOne(newElement))
    }

    @inlinable
    mutating func append(contentsOf newElements: some Sequence<Element>) {
        switch self {
        case .one(let firstElement):
            var iterator = newElements.makeIterator()
            guard let secondElement = iterator.next() else {
                // newElements is empty, nothing to do
                return
            }
            var elements: [Element] = []
            elements.reserveCapacity(1 + newElements.underestimatedCount)
            elements.append(firstElement)
            elements.append(secondElement)
            elements.appendRemainingElements(from: &iterator)
            self = .arbitrary(elements)

        case .arbitrary(var elements):
            if elements.isEmpty {
                // if `self` is currently empty and `newElements` just contains a single
                // element, we skip allocating an array and set `self` to `.one(firstElement)`
                var iterator = newElements.makeIterator()
                guard let firstElement = iterator.next() else {
                    // newElements is empty, nothing to do
                    return
                }
                guard let secondElement = iterator.next() else {
                    // newElements just contains a single element
                    // and we hit the fast path
                    self = .one(firstElement)
                    return
                }
                elements.reserveCapacity(elements.count + newElements.underestimatedCount)
                elements.append(firstElement)
                elements.append(secondElement)
                elements.appendRemainingElements(from: &iterator)
                self = .arbitrary(elements)

            } else {
                elements.append(contentsOf: newElements)
                self = .arbitrary(elements)
            }

        }
    }

    @discardableResult
    @inlinable
    mutating func remove(at index: Int) -> Element {
        switch self {
        case .one(let oldElement):
            guard index == 0 else {
                fatalError("index \(index) out of bounds")
            }
            self = .arbitrary([])
            return oldElement

        case .arbitrary(var elements):
            defer {
                self = .arbitrary(elements)
            }
            return elements.remove(at: index)

        }
    }

    @inlinable
    mutating func removeAll(where shouldBeRemoved: (Element) throws -> Bool) rethrows {
        switch self {
        case .one(let oldElement):
            if try shouldBeRemoved(oldElement) {
                self = .arbitrary([])
            }

        case .arbitrary(var elements):
            defer {
                self = .arbitrary(elements)
            }
            return try elements.removeAll(where: shouldBeRemoved)

        }
    }

    @inlinable
    mutating func sort(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows {
        switch self {
        case .one:
            // a collection of just one element is always sorted, nothing to do
            break
        case .arbitrary(var elements):
            defer {
                self = .arbitrary(elements)
            }

            try elements.sort(by: areInIncreasingOrder)
        }
    }
}

extension Array {
    @inlinable
    mutating func appendRemainingElements(from iterator: inout some IteratorProtocol<Element>) {
        while let nextElement = iterator.next() {
            append(nextElement)
        }
    }
}
