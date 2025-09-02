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

import SystemPackage

@usableFromInline
internal final class Ref<Value> {
    @usableFromInline
    var value: Value
    @inlinable
    init(_ value: Value) {
        self.value = value
    }
}

@available(*, unavailable)
extension Ref: Sendable {}

extension String {
    init(randomAlphaNumericOfLength length: Int) {
        precondition(length > 0)

        let characters = (0..<length).lazy.map {
            _ in Array.alphaNumericValues.randomElement()!
        }
        self = String(decoding: characters, as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    fileprivate static let alphaNumericValues: [UInt8] = {
        var alphaNumericValues = Array(UInt8(ascii: "a")...UInt8(ascii: "z"))
        alphaNumericValues.append(contentsOf: UInt8(ascii: "A")...UInt8(ascii: "Z"))
        alphaNumericValues.append(contentsOf: UInt8(ascii: "0")...UInt8(ascii: "9"))
        return alphaNumericValues
    }()
}
