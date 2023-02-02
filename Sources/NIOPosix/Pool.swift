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

protocol PoolElement {
    init()
    func evictedFromPool()
}


class Pool<Element: PoolElement> {
    private let maxSize: Int
    private var elements: [Element]

    public init(maxSize: Int) {
        self.maxSize = maxSize
        self.elements = [Element]()
    }

    deinit {
        for e in elements {
            e.evictedFromPool()
        }
    }

    public func get() -> Element {
        if elements.isEmpty {
            return Element()
        }
        else {
            return elements.removeLast()
        }
    }

    public func put(_ e: Element) {
        if (elements.count == maxSize) {
            e.evictedFromPool()
        }
        else {
            elements.append(e)
        }
    }
}
