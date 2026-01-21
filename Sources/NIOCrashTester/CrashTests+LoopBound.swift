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
import NIOPosix

private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

struct LoopBoundTests {
    #if !canImport(Darwin) || os(macOS)
    let testInitChecksEventLoop = CrashTest(
        regex: "NIOCore/NIOLoopBound.swift:[0-9]+: Precondition failed"
    ) {
        _ = NIOLoopBound(1, eventLoop: group.any())  // BOOM
    }

    let testInitOfBoxChecksEventLoop = CrashTest(
        regex: "NIOCore/NIOLoopBound.swift:[0-9]+: Precondition failed"
    ) {
        _ = NIOLoopBoundBox(1, eventLoop: group.any())  // BOOM
    }

    let testGetChecksEventLoop = CrashTest(
        regex: "NIOCore/NIOLoopBound.swift:[0-9]+: Precondition failed"
    ) {
        let loop = group.any()
        let sendable = try? loop.submit {
            NIOLoopBound(1, eventLoop: loop)
        }.wait()
        _ = sendable?.value  // BOOM
    }

    let testGetOfBoxChecksEventLoop = CrashTest(
        regex: "NIOCore/NIOLoopBound.swift:[0-9]+: Precondition failed"
    ) {
        let loop = group.any()
        let sendable = try? loop.submit {
            NIOLoopBoundBox(1, eventLoop: loop)
        }.wait()
        _ = sendable?.value  // BOOM
    }

    let testSetChecksEventLoop = CrashTest(
        regex: "NIOCore/NIOLoopBound.swift:[0-9]+: Precondition failed"
    ) {
        let loop = group.any()
        let sendable = try? loop.submit {
            NIOLoopBound(1, eventLoop: loop)
        }.wait()
        var sendableVar = sendable
        sendableVar?.value = 2
    }

    let testSetOfBoxChecksEventLoop = CrashTest(
        regex: "NIOCore/NIOLoopBound.swift:[0-9]+: Precondition failed"
    ) {
        let loop = group.any()
        let sendable = try? loop.submit {
            NIOLoopBoundBox(1, eventLoop: loop)
        }.wait()
        sendable?.value = 2
    }
    #endif
}
