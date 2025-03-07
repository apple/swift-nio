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

#if !canImport(Darwin) || os(macOS)
import NIOCore
import NIOPosix
import Foundation

private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

struct SystemCrashTests {
    let testEBADFIsUnacceptable = CrashTest(
        regex: "Precondition failed: unacceptable errno \(EBADF) Bad file descriptor in",
        {
            _ = try? NIOPipeBootstrap(group: group).takingOwnershipOfDescriptors(input: .max, output: .max - 1).wait()
        }
    )
}
#endif
