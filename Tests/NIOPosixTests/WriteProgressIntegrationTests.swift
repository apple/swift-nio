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

import NIOCore
import XCTest

@testable import NIOPosix

final class WriteProgressIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        #if os(Windows)
        throw XCTSkip("Write-progress integration tests require POSIX stream channels")
        #endif
    }

    func testWriteProgressOptionDefaultsOffAndCanBeToggled() throws {
        func runTest(sender: Channel, receiver: Channel) throws {
            let progress = try sender.eventLoop.submit {
                let recorder = WriteProgressRecorder()
                try sender.pipeline.syncOperations.addHandler(recorder)
                return NIOLoopBound(recorder, eventLoop: sender.eventLoop)
            }.wait()

            var first = sender.allocator.buffer(capacity: 256)
            first.writeBytes(Array(repeating: 0x11, count: 256))
            var second = sender.allocator.buffer(capacity: 512)
            second.writeBytes(Array(repeating: 0x22, count: 512))
            var third = sender.allocator.buffer(capacity: 128)
            third.writeBytes(Array(repeating: 0x33, count: 128))
            let totalLength = first.readableBytes + second.readableBytes + third.readableBytes
            let received = receiver.eventLoop.makePromise(of: ByteBuffer.self)
            try receiver.eventLoop.submit {
                try receiver.pipeline.syncOperations.addHandler(
                    ByteCountingHandler(
                        numBytes: totalLength,
                        promise: received
                    )
                )
            }.wait()

            XCTAssertFalse(try sender.getOption(.reportWriteProgress).wait())
            try sender.writeAndFlush(first).wait()

            try sender.setOption(.reportWriteProgress, value: true).wait()
            XCTAssertTrue(try sender.getOption(.reportWriteProgress).wait())
            try sender.writeAndFlush(second).wait()

            try sender.setOption(.reportWriteProgress, value: false).wait()
            XCTAssertFalse(try sender.getOption(.reportWriteProgress).wait())
            try sender.writeAndFlush(third).wait()

            let receivedBuffer = try received.futureResult.wait()
            let events = try sender.eventLoop.submit { progress.value.events }.wait()
            XCTAssertEqual(receivedBuffer.readableBytes, totalLength)
            XCTAssertEqual(events.reduce(0, +), Int64(second.readableBytes))
        }

        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testWriteProgressReportsTheBytesInAFlushedBurst() throws {
        func runTest(sender: Channel, receiver: Channel) throws {
            let progress = try sender.eventLoop.submit {
                let recorder = WriteProgressRecorder()
                try sender.pipeline.syncOperations.addHandler(recorder)
                return NIOLoopBound(recorder, eventLoop: sender.eventLoop)
            }.wait()
            try sender.setOption(.reportWriteProgress, value: true).wait()

            let firstLength = 32 * 1024
            let secondLength = 16 * 1024
            var first = sender.allocator.buffer(capacity: firstLength)
            first.writeBytes(Array(repeating: 0x31, count: firstLength))
            var second = sender.allocator.buffer(capacity: secondLength)
            second.writeBytes(Array(repeating: 0x32, count: secondLength))
            let received = receiver.eventLoop.makePromise(of: ByteBuffer.self)
            try receiver.eventLoop.submit {
                try receiver.pipeline.syncOperations.addHandler(
                    ByteCountingHandler(numBytes: firstLength + secondLength, promise: received)
                )
            }.wait()

            sender.write(first, promise: nil)
            sender.write(second, promise: nil)
            sender.flush()

            let receivedBuffer = try received.futureResult.wait()
            let events = try sender.eventLoop.submit { progress.value.events }.wait()
            XCTAssertEqual(receivedBuffer.readableBytes, firstLength + secondLength)
            XCTAssertEqual(events.reduce(0, +), Int64(firstLength + secondLength))
            XCTAssertFalse(events.isEmpty)
        }

        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testLargeTCPWriteReportsProgressBeforeItsWriteCompletes() throws {
        func runTest(receiver: Channel, sender: Channel) throws {
            precondition(receiver.eventLoop !== sender.eventLoop)
            let payloadLength = 8 * 1024 * 1024

            try receiver.setOption(.autoRead, value: false).wait()
            try sender.setOption(.socketOption(.so_sndbuf), value: 4 * 1024).wait()
            try sender.setOption(.reportWriteProgress, value: true).wait()

            let received = receiver.eventLoop.makePromise(of: ByteBuffer.self)
            try receiver.eventLoop.submit {
                try receiver.pipeline.syncOperations.addHandler(
                    ByteCountingHandler(numBytes: payloadLength, promise: received)
                )
            }.wait()

            let writePromise = sender.eventLoop.makePromise(of: Void.self)
            let writeFuture = writePromise.futureResult
            let progressExpectation = self.expectation(description: "first write-progress event")
            let progress = try sender.eventLoop.submit {
                let recorder = LargeWriteProgressRecorder(
                    writeFuture: writeFuture,
                    firstProgressExpectation: progressExpectation
                )
                try sender.pipeline.syncOperations.addHandler(recorder)
                return NIOLoopBound(recorder, eventLoop: sender.eventLoop)
            }.wait()

            let fallback = receiver.eventLoop.scheduleTask(in: .seconds(1)) {
                receiver.setOption(.autoRead, value: true).whenFailure { _ in }
            }
            defer {
                fallback.cancel()
            }

            let payload = sender.allocator.buffer(repeating: 0x42, count: payloadLength)
            try sender.eventLoop.submit {
                sender.writeAndFlush(payload, promise: writePromise)
            }.wait()

            self.wait(for: [progressExpectation], timeout: 5.0)
            try receiver.setOption(.autoRead, value: true).wait()

            let receivedBuffer = try received.futureResult.wait()
            try writeFuture.wait()
            fallback.cancel()

            let snapshot = try sender.eventLoop.submit {
                (
                    progress.value.totalBytes,
                    progress.value.firstProgressBeforeWriteCompletion,
                    progress.value.sawPositiveProgress
                )
            }.wait()
            XCTAssertTrue(snapshot.2)
            XCTAssertTrue(snapshot.1)
            XCTAssertEqual(snapshot.0, Int64(payloadLength))
            XCTAssertEqual(receivedBuffer.readableBytes, payloadLength)
        }

        XCTAssertNoThrow(try withCrossConnectedTCPChannels(forceSeparateEventLoops: true, runTest))
    }

    func testOutputHalfCloseReportsFinalProgressAndRejectsLaterWrites() throws {
        func runTest(sender: Channel, receiver: Channel) throws {
            let payloadLength = 16 * 1024
            try receiver.setOption(.allowRemoteHalfClosure, value: true).wait()
            try sender.setOption(.reportWriteProgress, value: true).wait()
            let received = receiver.eventLoop.makePromise(of: ByteBuffer.self)
            try receiver.eventLoop.submit {
                try receiver.pipeline.syncOperations.addHandler(
                    ByteCountingHandler(numBytes: payloadLength, promise: received)
                )
            }.wait()
            let progress = try sender.eventLoop.submit {
                let recorder = WriteProgressRecorder()
                try sender.pipeline.syncOperations.addHandler(recorder)
                return NIOLoopBound(recorder, eventLoop: sender.eventLoop)
            }.wait()

            let writePromise = sender.eventLoop.makePromise(of: Void.self)
            let closePromise = sender.eventLoop.makePromise(of: Void.self)
            let payload = sender.allocator.buffer(repeating: 0x42, count: payloadLength)
            try sender.eventLoop.submit {
                sender.write(payload, promise: writePromise)
                sender.close(mode: .output, promise: closePromise)
                sender.flush()
            }.wait()
            try writePromise.futureResult.wait()
            try closePromise.futureResult.wait()
            XCTAssertEqual(try received.futureResult.wait().readableBytes, payloadLength)

            // The output-close event is delivered while the last write is completing; progress follows
            // once the burst's selector updates are complete. Input remains usable after this half-close.
            let snapshot = try sender.eventLoop.submit {
                (progress.value.events.reduce(0, +), progress.value.bytesAfterOutputClosed)
            }.wait()
            XCTAssertEqual(snapshot.0, Int64(payloadLength))
            XCTAssertGreaterThan(snapshot.1, 0)
            XCTAssertTrue(sender.isActive)
            XCTAssertThrowsError(try sender.writeAndFlush(payload).wait()) { error in
                XCTAssertEqual(error as? ChannelError, .outputClosed)
            }
            XCTAssertEqual(
                try sender.eventLoop.submit { progress.value.events.reduce(0, +) }.wait(),
                snapshot.0
            )
        }

        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testWriteProgressReportsFileRegionBytes() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 128 * 1024
        let content = String(repeating: "x", count: numBytes)
        let received = group.next().makePromise(of: ByteBuffer.self)
        let server = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteCountingHandler(numBytes: numBytes, promise: received)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        let client = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelOption(.reportWriteProgress, value: true)
                .connect(to: server.localAddress!)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try client.close().wait())
        }

        let progress = try client.eventLoop.submit {
            let recorder = WriteProgressRecorder()
            try client.pipeline.syncOperations.addHandler(recorder)
            return NIOLoopBound(recorder, eventLoop: client.eventLoop)
        }.wait()

        try withTemporaryFile { _, path in
            try content.write(toFile: path, atomically: false, encoding: .ascii)
            try client.eventLoop.submit {
                try NIOFileHandle(_deprecatedPath: path)
            }.flatMap { handle in
                let region = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: numBytes)
                let promise = client.eventLoop.makePromise(of: Void.self)
                client.pipeline.syncOperations.writeAndFlush(NIOAny(region), promise: promise)
                let bound = NIOLoopBound(handle, eventLoop: client.eventLoop)
                return promise.futureResult.flatMapErrorThrowing { error in
                    try? bound.value.close()
                    throw error
                }.flatMapThrowing {
                    try bound.value.close()
                }
            }.wait()
        }

        let receivedBuffer = try received.futureResult.wait()
        let events = try client.eventLoop.submit { progress.value.events }.wait()
        XCTAssertEqual(receivedBuffer.readableBytes, numBytes)
        XCTAssertEqual(events.reduce(0, +), Int64(numBytes))
        XCTAssertFalse(events.isEmpty)
    }
}

private final class WriteProgressRecorder: ChannelInboundHandler {
    typealias InboundIn = Any

    private(set) var events: [Int64] = []
    private var sawOutputClosed = false
    private(set) var bytesAfterOutputClosed: Int64 = 0

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let progress = event as? NIOWriteProgressEvent {
            self.events.append(progress.bytesWritten)
            if self.sawOutputClosed {
                self.bytesAfterOutputClosed += progress.bytesWritten
            }
        } else if event as? ChannelEvent == .some(.outputClosed) {
            self.sawOutputClosed = true
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class LargeWriteProgressRecorder: ChannelInboundHandler {
    typealias InboundIn = Any

    let writeFuture: EventLoopFuture<Void>
    let firstProgressExpectation: XCTestExpectation
    var totalBytes: Int64 = 0
    var sawPositiveProgress = false
    var firstProgressBeforeWriteCompletion = false

    init(writeFuture: EventLoopFuture<Void>, firstProgressExpectation: XCTestExpectation) {
        self.writeFuture = writeFuture
        self.firstProgressExpectation = firstProgressExpectation
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let progress = event as? NIOWriteProgressEvent, progress.bytesWritten > 0 {
            self.totalBytes += progress.bytesWritten
            if !self.sawPositiveProgress {
                self.sawPositiveProgress = true
                self.firstProgressBeforeWriteCompletion = !self.writeFuture.isFulfilled
                self.firstProgressExpectation.fulfill()
            }
        }
        context.fireUserInboundEventTriggered(event)
    }
}
