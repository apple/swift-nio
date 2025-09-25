//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
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
import XCTest

@testable import NIOPosix

struct SALContext {
    let eventLoop: SelectableEventLoop
    private let wakeups: LockedBox<Void>
    private let unchecked: Unchecked

    // KernelToUser and UserToKernel are *not* Sendable but we need an escape hatch so that
    // they can be moved from the testing thread to the event-loop and back.
    struct Unchecked: @unchecked Sendable {
        let kernelToUserBox: LockedBox<KernelToUser>
        let userToKernelBox: LockedBox<UserToKernel>
    }

    var selector: HookedSelector {
        self.eventLoop._selector as! HookedSelector
    }

    fileprivate init(
        eventLoop: SelectableEventLoop,
        wakeups: LockedBox<Void>,
        unchecked: Unchecked
    ) {
        self.eventLoop = eventLoop
        self.wakeups = wakeups
        self.unchecked = unchecked
    }

    func runSALOnEventLoop<Result: Sendable>(
        file: StaticString = #filePath,
        line: UInt = #line,
        body:
            @escaping @Sendable (
                _ eventLoop: SelectableEventLoop,
                _ kernelToUser: LockedBox<KernelToUser>,
                _ userToKernal: LockedBox<UserToKernel>
            ) throws -> Result,
        syscallAssertions: (SyscallAssertions) throws -> Void
    ) throws -> Result {
        let box = LockedBox<Swift.Result<Result, Error>>()
        let hookedSelector = self.eventLoop._selector as! HookedSelector

        // To prevent races between the test driver thread (this thread) and the EventLoop (another thread), we need
        // to wait for the EventLoop to finish its tick and park itself. That makes sure both threads are synchronised
        // so we know exactly what the EventLoop thread is currently up to (nothing at all, waiting for a wakeup).
        try self.unchecked.userToKernelBox.assertParkedRightNow()

        self.eventLoop.execute {
            do {
                let result = try body(self.eventLoop, self.unchecked.kernelToUserBox, self.unchecked.userToKernelBox)
                try box.waitForEmptyAndSet(.success(result))
            } catch {
                box.value = .failure(error)
            }
        }
        try hookedSelector.assertWakeup(file: file, line: line)
        try syscallAssertions(SyscallAssertions(selector: hookedSelector))

        // Here as well, we need to synchronise and wait for the EventLoop to finish running its tick.
        try self.unchecked.userToKernelBox.assertParkedRightNow()
        return try box.takeValue().get()
    }

    func runSALOnEventLoopAndWait<Result: Sendable>(
        file: StaticString = #filePath,
        line: UInt = #line,
        body:
            @escaping @Sendable (
                _ eventLoop: SelectableEventLoop,
                _ kernelToUser: LockedBox<KernelToUser>,
                _ userToKernal: LockedBox<UserToKernel>
            ) throws -> EventLoopFuture<Result>,
        syscallAssertions: (SyscallAssertions) throws -> Void
    ) throws -> Result {
        let result = try self.runSALOnEventLoop(body: body, syscallAssertions: syscallAssertions)
        return try result.salWait(context: self)
    }

    func runSALOnEventLoop<Result: Sendable>(
        file: StaticString = #filePath,
        line: UInt = #line,
        body:
            @escaping @Sendable (
                _ eventLoop: SelectableEventLoop,
                _ kernelToUser: LockedBox<KernelToUser>,
                _ userToKernal: LockedBox<UserToKernel>
            ) throws -> Result
    ) throws -> Result {
        try self.runSALOnEventLoop(file: file, line: line, body: body) { _ in }
    }
}

@available(*, unavailable)
extension SALContext: Sendable {}

func withSALContext<R>(body: (SALContext) throws -> R) throws -> R {
    let kernelToUserBox = LockedBox<KernelToUser>(description: "k2u") { newValue in
        if let newValue = newValue {
            SAL.printIfDebug("K --> U: \(newValue)")
        }
    }

    let userToKernelBox = LockedBox<UserToKernel>(description: "u2k") { newValue in
        if let newValue = newValue {
            SAL.printIfDebug("U --> K: \(newValue)")
        }
    }

    let wakeups = LockedBox<Void>(description: "wakeups")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1, metricsDelegate: nil) { thread in
        try HookedSelector(
            userToKernel: userToKernelBox,
            kernelToUser: kernelToUserBox,
            wakeups: wakeups,
            thread: thread
        )
    }
    defer {
        try! group.syncShutdownGracefully()
    }

    let context = SALContext(
        eventLoop: group.next() as! SelectableEventLoop,
        wakeups: wakeups,
        unchecked: SALContext.Unchecked(
            kernelToUserBox: kernelToUserBox,
            userToKernelBox: userToKernelBox
        )
    )

    defer {
        SAL.printIfDebug("=== TEAR DOWN ===")

        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        XCTAssertNoThrow(
            group.shutdownGracefully(queue: DispatchQueue.global()) { error in
                XCTAssertNil(error, "unexpected error: \(error!)")
                dispatchGroup.leave()
            }
        )
        // We're in a slightly tricky situation here. We don't know if the EventLoop thread enters `whenReady` again
        // or not. If it has, we have to wake it up, so let's just put a return value in the 'kernel to user' box, just
        // in case :)
        XCTAssertNoThrow(try kernelToUserBox.waitForEmptyAndSet(.returnSelectorEvent(nil)))
        dispatchGroup.wait()
    }

    let result = try body(context)
    return result
}
