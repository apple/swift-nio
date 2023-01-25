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

public class Pool<Element> {
    private let maxSize: Int
    private let ctor: () -> Element
    private let dtor: (Element) -> Void
    private var elements: [Element]

    public init(maxSize: Int, ctor: @escaping () -> Element, dtor: @escaping (Element) -> Void) {
        self.maxSize = maxSize
        self.ctor = ctor
        self.dtor = dtor
        self.elements = [Element]()
    }

    deinit {
        while !elements.isEmpty {
            let e = elements.removeLast()
            dtor(e)
        }
    }

    public func get() -> Element {
        if elements.isEmpty {
            return ctor()
        }
        else {
            return elements.removeLast()
        }
    }

    public func put(_ e: Element) {
        if (elements.count == maxSize) {
            dtor(e)
        }
        else {
            elements.append(e)
        }
    }
}
