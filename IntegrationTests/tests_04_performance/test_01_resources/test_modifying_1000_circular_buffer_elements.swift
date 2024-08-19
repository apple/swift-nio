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

import NIOCore

func run(identifier: String) {
    var buffer = CircularBuffer<[Int]>(initialCapacity: 100)
    for _ in 0..<100 {
        buffer.append([])
    }

    measure(identifier: identifier) {
        for idx in 0..<1000 {
            let index = buffer.index(buffer.startIndex, offsetBy: idx % 100)
            buffer.modify(index) { value in
                value.append(idx)
            }
        }
        return buffer.last!.last!
    }
}
