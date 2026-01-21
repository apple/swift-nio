//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded

func run(identifier: String) {
    measure(identifier: identifier) {
        @inline(never)
        func doEraseResult(loop: EventLoop) {
            // In an ideal implementation the only allocation is this promise.
            let p = loop.makePromise(of: Int.self)
            let f = p.futureResult.map { (r: Int) -> Void in
                // This closure is a value-to-no-value erase that closes over nothing.
                // Ideally this would not allocate.
                return
            }.map { (_: Void) -> Void in
                // This closure is a nothing-to-nothing map, basically a "completed" observer. This should
                // also not allocate, but it has a separate code path to the above.
            }
            p.succeed(0)
        }

        let el = EmbeddedEventLoop()
        for _ in 0..<1000 {
            doEraseResult(loop: el)
        }
        return 1000
    }
}
