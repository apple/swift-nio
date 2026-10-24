//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOCore
import NIOPosix

func runNIOThreadPoolSerialWakeup(pool: NIOThreadPool, count: Int) {
    let sem = DispatchSemaphore(value: 0)
    for _ in 0..<count {
        pool.submit { state in
            precondition(state == .active)
            sem.signal()
        }
        sem.wait()
    }
}
