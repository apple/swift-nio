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

#if !canImport(Darwin) || os(macOS)
import NIOCore
import NIOPosix

struct StrictCrashTests {
    let testEventLoopSheduleAfterShutdown = CrashTest(
        regex: "Fatal error: Cannot schedule tasks on an EventLoop that has already shut down."
    ) {
        setenv("SWIFTNIO_STRICT", "1", 1)
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = elg.next()
        try! elg.syncShutdownGracefully()
        loop.execute {
            print("Crash should happen before this line is printed.")
        }
    }
}
#endif
