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
    let allocator = ByteBufferAllocator()
    let data = Array(repeating: UInt8(0), count: 1024)

    measure(identifier: identifier) {
        var count = 0

        for _ in 0..<1_000 {
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            var view = ByteBufferView(buffer)

            // Unfortunately this CoWs: https://bugs.swift.org/browse/SR-11675
            view[0] = 42
            view.replaceSubrange(0..<4, with: [0x0, 0x1, 0x2, 0x3])

            var modified = ByteBuffer(view)
            modified.setBytes([0xa, 0xb, 0xc], at: modified.readerIndex)
            count &+= modified.readableBytes
        }

        return count
    }
}
