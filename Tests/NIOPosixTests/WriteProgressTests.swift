//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License 2.0
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOPosix

// The SAL harness is CInt-fd based and is not available on Windows.
#if !os(Windows)
final class WriteProgressTests: XCTestCase {
    private final class ProgressRecorder: ChannelInboundHandler, Sendable {
        typealias InboundIn = Any

        let events = NIOLockedValueBox<[NIOWriteProgressEvent]>([])
        private let future: EventLoopFuture<Void>?
        let pendingAtEvent = NIOLockedValueBox<[Bool]>([])

        init(future: EventLoopFuture<Void>? = nil) {
            self.future = future
        }

        var bytesWritten: [Int64] {
            self.events.withLockedValue { $0.map(\.bytesWritten) }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? NIOWriteProgressEvent {
                self.events.withLockedValue { $0.append(event) }
                if let future = self.future {
                    self.pendingAtEvent.withLockedValue { $0.append(!future.isFulfilled) }
                }
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    private final class WriteBackOnProgress: ChannelInboundHandler, Sendable {
        typealias InboundIn = Any
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        let events = NIOLockedValueBox<[Int64]>([])
        private let didWriteBack = NIOLockedValueBox(false)

        var bytesWritten: [Int64] {
            self.events.withLockedValue { $0 }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? NIOWriteProgressEvent {
                self.events.withLockedValue { $0.append(event.bytesWritten) }
                let shouldWrite = self.didWriteBack.withLockedValue { didWriteBack in
                    if didWriteBack {
                        return false
                    }
                    didWriteBack = true
                    return true
                }
                if shouldWrite {
                    var callbackBuffer = context.channel.allocator.buffer(capacity: 3)
                    callbackBuffer.writeString("xyz")
                    context.writeAndFlush(self.wrapOutboundOut(callbackBuffer), promise: nil)
                }
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    private final class CloseOnProgress: ChannelInboundHandler, Sendable {
        typealias InboundIn = Any

        let events = NIOLockedValueBox<[Int64]>([])

        var bytesWritten: [Int64] {
            self.events.withLockedValue { $0 }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? NIOWriteProgressEvent {
                self.events.withLockedValue { $0.append(event.bytesWritten) }
                context.close(promise: nil)
                return
            }
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func writableEvent(for channel: SocketChannel) -> SelectorEvent<NIORegistration> {
        SelectorEvent(
            io: [.write],
            registration: NIORegistration(
                channel: .socketChannel(channel),
                interested: [.write],
                registrationID: .initialRegistrationID
            )
        )
    }

    func testPartialWriteReportsProgressBeforePromiseCompletes() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let recorderBox = NIOLockedValueBox<ProgressRecorder?>(nil)
            let buffer = ByteBuffer(string: "hello")

            try context.runSALOnEventLoopAndWait { _, _, _ -> EventLoopFuture<Void> in
                let promise = channel.eventLoop.makePromise(of: Void.self)
                let recorder = ProgressRecorder(future: promise.futureResult)
                recorderBox.withLockedValue { $0 = recorder }
                try channel.pipeline.syncOperations.addHandler(recorder)
                try channel.syncOptions!.setOption(.reportWriteProgress, value: true)
                try channel.syncOptions!.setOption(.writeSpin, value: 0)
                channel.writeAndFlush(buffer, promise: promise)
                return promise.futureResult
            } syscallAssertions: { assertions in
                try assertions.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .processed(2))
                try assertions.assertReregister { _, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read, .write], eventSet)
                    return true
                }
                try assertions.assertWaitingForNotification(result: self.writableEvent(for: channel))
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: buffer.getSlice(at: 2, length: 3)!,
                    return: .processed(3)
                )
                try assertions.assertReregister { _, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read], eventSet)
                    return true
                }
            }

            let recorder = try XCTUnwrap(recorderBox.withLockedValue { $0 })
            XCTAssertEqual([2, 3], recorder.bytesWritten)
            XCTAssertEqual([true, false], recorder.pendingAtEvent.withLockedValue { $0 })
            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.close()
            } syscallAssertions: { assertions in
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testDefaultDisabledDoesNotEmitProgress() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let recorder = ProgressRecorder()
            let buffer = ByteBuffer(string: "hello")

            try context.runSALOnEventLoopAndWait { _, _, _ in
                try channel.pipeline.syncOperations.addHandler(recorder)
                return channel.writeAndFlush(buffer).flatMap { channel.close() }
            } syscallAssertions: { assertions in
                try assertions.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .processed(5))
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }

            XCTAssertEqual([], recorder.bytesWritten)
        }
    }

    func testWouldBlockZeroIsSilentAndLaterPositiveProgressIsReported() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let recorderBox = NIOLockedValueBox<ProgressRecorder?>(nil)
            let buffer = ByteBuffer(string: "hello")

            try context.runSALOnEventLoopAndWait { _, _, _ -> EventLoopFuture<Void> in
                let promise = channel.eventLoop.makePromise(of: Void.self)
                let recorder = ProgressRecorder(future: promise.futureResult)
                recorderBox.withLockedValue { $0 = recorder }
                try channel.pipeline.syncOperations.addHandler(recorder)
                try channel.syncOptions!.setOption(.reportWriteProgress, value: true)
                try channel.syncOptions!.setOption(.writeSpin, value: 0)
                channel.writeAndFlush(buffer, promise: promise)
                return promise.futureResult
            } syscallAssertions: { assertions in
                try assertions.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .wouldBlock(0))
                try assertions.assertReregister { _, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read, .write], eventSet)
                    return true
                }
                try assertions.assertWaitingForNotification(result: self.writableEvent(for: channel))
                try assertions.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .wouldBlock(2))
                try assertions.assertWaitingForNotification(result: self.writableEvent(for: channel))
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: buffer.getSlice(at: 2, length: 3)!,
                    return: .processed(3)
                )
                try assertions.assertReregister { _, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read], eventSet)
                    return true
                }
            }

            let recorder = try XCTUnwrap(recorderBox.withLockedValue { $0 })
            XCTAssertEqual([2, 3], recorder.bytesWritten)
            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.close()
            } syscallAssertions: { assertions in
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testVectorWriteProgressIsAggregatedIntoOneEvent() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let recorder = ProgressRecorder()
            let first = ByteBuffer(string: "abc")
            let second = ByteBuffer(string: "def")

            try context.runSALOnEventLoopAndWait { _, _, _ -> EventLoopFuture<Void> in
                try channel.pipeline.syncOperations.addHandler(recorder)
                try channel.syncOptions!.setOption(.reportWriteProgress, value: true)
                channel.write(first, promise: nil)
                return channel.writeAndFlush(second).flatMap { channel.close() }
            } syscallAssertions: { assertions in
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [first, second],
                    return: .processed(6)
                )
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }

            XCTAssertEqual([6], recorder.bytesWritten)
        }
    }

    func testProgressFromMultipleWriteSyscallsIsCoalesced() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let recorder = ProgressRecorder()
            let first = ByteBuffer(string: "abc")
            let second = ByteBuffer(string: "def")

            try context.runSALOnEventLoopAndWait { _, _, _ -> EventLoopFuture<Void> in
                try channel.pipeline.syncOperations.addHandler(recorder)
                try channel.syncOptions!.setOption(.reportWriteProgress, value: true)
                try channel.syncOptions!.setOption(.writeSpin, value: 1)
                channel.write(first, promise: nil)
                return channel.writeAndFlush(second).flatMap { channel.close() }
            } syscallAssertions: { assertions in
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [first, second],
                    return: .processed(4)
                )
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: second.getSlice(at: 1, length: 2)!,
                    return: .processed(2)
                )
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }

            XCTAssertEqual([6], recorder.bytesWritten)
        }
    }

    func testProgressHandlerCanWriteAndFlushWithoutLosingRegistration() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let handler = WriteBackOnProgress()
            let futureBox = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)
            let buffer = ByteBuffer(string: "abcd")

            try context.runSALOnEventLoop { _, _, _ in
                try channel.pipeline.syncOperations.addHandler(handler)
                try channel.syncOptions!.setOption(.reportWriteProgress, value: true)
                try channel.syncOptions!.setOption(.writeSpin, value: 0)
                futureBox.withLockedValue { $0 = channel.writeAndFlush(buffer) }
            } syscallAssertions: { assertions in
                try assertions.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .processed(2))
                try assertions.assertReregister { _, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read, .write], eventSet)
                    return true
                }
                try assertions.assertWaitingForNotification(result: self.writableEvent(for: channel))
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [buffer.getSlice(at: 2, length: 2)!, ByteBuffer(string: "xyz")],
                    return: .processed(5)
                )
                try assertions.assertReregister { _, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read], eventSet)
                    return true
                }
            }

            XCTAssertNoThrow(try XCTUnwrap(futureBox.withLockedValue { $0 }).salWait(context: context))
            XCTAssertEqual([2, 5], handler.bytesWritten)
            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.close()
            } syscallAssertions: { assertions in
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testProgressHandlerCanCloseChannelDuringNotification() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let handler = CloseOnProgress()
            let futureBox = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)
            let buffer = ByteBuffer(string: "abcd")

            try context.runSALOnEventLoop { _, _, _ in
                try channel.pipeline.syncOperations.addHandler(handler)
                try channel.syncOptions!.setOption(.reportWriteProgress, value: true)
                try channel.syncOptions!.setOption(.writeSpin, value: 0)
                futureBox.withLockedValue { $0 = channel.writeAndFlush(buffer) }
            } syscallAssertions: { assertions in
                try assertions.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .processed(2))
                try assertions.assertReregister { _, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read, .write], eventSet)
                    return true
                }
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }

            XCTAssertEqual([2], handler.bytesWritten)
            let writeFuture = try XCTUnwrap(futureBox.withLockedValue { $0 })
            XCTAssertThrowsError(try writeFuture.salWait(context: context))
        }
    }

    func testWriteErrorAfterPartialProgressSuppressesTheFailedBurstEvent() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )
            let recorderBox = NIOLockedValueBox<ProgressRecorder?>(nil)
            let futureBox = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)
            let buffer = ByteBuffer(string: "abcd")
            let expectedError = IOError(errnoCode: EPIPE, reason: "broken pipe")

            try context.runSALOnEventLoop { _, _, _ in
                let recorder = ProgressRecorder()
                recorderBox.withLockedValue { $0 = recorder }
                try channel.pipeline.syncOperations.addHandler(recorder)
                try channel.syncOptions!.setOption(.reportWriteProgress, value: true)
                try channel.syncOptions!.setOption(.writeSpin, value: 1)
                futureBox.withLockedValue { $0 = channel.writeAndFlush(buffer) }
            } syscallAssertions: { assertions in
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: buffer,
                    return: .processed(2)
                )
                try assertions.assertSyscallAndReturn(.error(expectedError)) { syscall in
                    if case .write(let fd, let remainder) = syscall {
                        return fd == .max && remainder == buffer.getSlice(at: 2, length: 2)!
                    } else {
                        return false
                    }
                }
                try assertions.assertRead(expectedFD: .max, expectedBufferSpace: 2048, return: ByteBuffer())
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }

            let recorder = try XCTUnwrap(recorderBox.withLockedValue { $0 })
            XCTAssertEqual([], recorder.bytesWritten)
            let writeFuture = try XCTUnwrap(futureBox.withLockedValue { $0 })
            XCTAssertThrowsError(try writeFuture.salWait(context: context)) { error in
                XCTAssertEqual(expectedError.errnoCode, (error as? IOError)?.errnoCode)
            }
        }
    }

    func testReportWriteProgressOptionDefaultsFalseAndCanBeToggled() throws {
        try withSALContext { context in
            let localAddress = try SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let remoteAddress = try SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: remoteAddress
            )

            try context.runSALOnEventLoopAndWait { _, _, _ -> EventLoopFuture<Void> in
                let options = channel.syncOptions!
                XCTAssertFalse(try options.getOption(.reportWriteProgress))
                try options.setOption(.reportWriteProgress, value: true)
                XCTAssertTrue(try options.getOption(.reportWriteProgress))
                try options.setOption(.reportWriteProgress, value: false)
                XCTAssertFalse(try options.getOption(.reportWriteProgress))
                XCTAssertEqual(
                    NIOWriteProgressEvent(bytesWritten: 7),
                    NIOWriteProgressEvent(bytesWritten: 7)
                )
                return channel.close()
            } syscallAssertions: { assertions in
                try assertions.assertDeregister { _ in true }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }
}
#endif
