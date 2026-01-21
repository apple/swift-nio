//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
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
    let data = CircularBuffer(repeating: UInt8(0xfe), count: 1024)

    measure(identifier: identifier) {
        var count = 0

        for _ in 0..<1_000 {
            let copy = Array(data)
            count &+= copy.count
        }

        return count
    }
}
