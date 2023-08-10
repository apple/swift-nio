//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

struct ByteBufferCrashTests {
    #if !canImport(Darwin) || os(macOS)
    let testMovingReaderIndexPastWriterIndex = CrashTest(
        regex: #"Precondition failed: new readerIndex: 1, expected: range\(0, 0\)"#
    ) {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.moveReaderIndex(forwardBy: 1)
    }

    let testAllocatingNegativeSize = CrashTest(
        regex: #"Precondition failed: ByteBuffer capacity must be positive."#
    ) {
        _ = ByteBufferAllocator().buffer(capacity: -1)
    }
    #endif
}
