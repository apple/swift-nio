//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import Foundation

fileprivate let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

struct SystemCrashTests {
    let testEBADFIsUnacceptable = CrashTest(
        regex: "Precondition failed: unacceptable errno \(EBADF) Bad file descriptor in", {
            _ = try? NIOPipeBootstrap(group: group).withPipes(inputDescriptor: .max, outputDescriptor: .max - 1).wait()
        })
}
