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

import DequeModule
import NIOCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private struct Delegate: NIOAsyncWriterSinkDelegate, Sendable {
    typealias Element = Int

    func didYield(contentsOf sequence: Deque<Int>) {}

    func didTerminate(error: Error?) {}
}

func run(identifier: String) {
    guard #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) else {
        return
    }
    measure(identifier: identifier) {
        let delegate = Delegate()
        let newWriter = NIOAsyncWriter<Int, Delegate>.makeWriter(isWritable: true, delegate: delegate)
        let writer = newWriter.writer

        for i in 0..<1_000_000 {
            try! await writer.yield(i)
        }

        return 1_000_000
    }
}
