//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOCore
@testable import NIOPosix
import NIOTestUtils
import Atomics

class StreamChannelTest: XCTestCase {
    var buffer: ByteBuffer! = nil

    override func setUp() {
        self.buffer = ByteBufferAllocator().buffer(capacity: 128)
    }

    override func tearDown() {
        self.buffer = nil
    }

    func testEchoBasic() throws {
        class EchoHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.write(data, promise: nil)
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                context.flush()
            }
        }

        func runTest(chan1: Channel, chan2: Channel) throws {
            var everythingBuffer = chan1.allocator.buffer(capacity: 300000)
            let allDonePromise = chan1.eventLoop.makePromise(of: ByteBuffer.self)
            XCTAssertNoThrow(try chan1.pipeline.addHandler(EchoHandler()).wait())
            XCTAssertNoThrow(try chan2.pipeline.addHandler(AccumulateAllReads(allDonePromise: allDonePromise)).wait())

            for f in [1, 10, 100, 1_000, 10_000, 300_000] {
                let from = everythingBuffer.writerIndex
                everythingBuffer.writeString("\(f)")
                everythingBuffer.writeBytes(repeatElement(UInt8(ascii: "x"), count: f))
                XCTAssertNoThrow(
                    chan2.writeAndFlush(
                        everythingBuffer.getSlice(
                            at: from,
                            length: everythingBuffer.writerIndex - from
                        )!
                    )
                )
            }
            let from = everythingBuffer.writerIndex
            everythingBuffer.writeString("$")  // magic end marker that will cause the channel to close
            XCTAssertNoThrow(chan2.writeAndFlush(everythingBuffer.getSlice(at: from, length: 1)!))
            XCTAssertNoThrow(XCTAssertEqual(everythingBuffer, try allDonePromise.futureResult.wait()))
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testSyncChannelOptions() throws {
        class GetAndSetAutoReadHandler: ChannelInboundHandler {
            typealias InboundIn = Any

            func handlerAdded(context: ChannelHandlerContext) {
                guard let syncOptions = context.channel.syncOptions else {
                    XCTFail("Sync options are not supported on \(type(of: context.channel))")
                    return
                }

                XCTAssertTrue(try syncOptions.getOption(ChannelOptions.autoRead))
                XCTAssertNoThrow(try syncOptions.setOption(ChannelOptions.autoRead, value: false))
                XCTAssertFalse(try syncOptions.getOption(ChannelOptions.autoRead))
            }
        }

        func runTest(chan1: Channel, chan2: Channel) throws {
            XCTAssertNoThrow(try chan1.pipeline.addHandler(GetAndSetAutoReadHandler()).wait())
            XCTAssertNoThrow(try chan2.pipeline.addHandler(GetAndSetAutoReadHandler()).wait())
        }

        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testChannelReturnsNilForDefaultSyncOptionsImplementation() throws {
        class TestChannel: Channel {
            var allocator: ByteBufferAllocator { fatalError() }
            var closeFuture: EventLoopFuture<Void> { fatalError() }
            var pipeline: ChannelPipeline { fatalError() }
            var localAddress: SocketAddress? = nil
            var remoteAddress: SocketAddress? = nil
            var parent: Channel? = nil
            var _channelCore: ChannelCore { fatalError() }
            var eventLoop: EventLoop { fatalError() }
            var isWritable: Bool = false
            var isActive: Bool = false

            func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
                fatalError()
            }

            func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
                fatalError()
            }

            init() {
            }
        }

        let channel = TestChannel()
        XCTAssertNil(channel.syncOptions)
    }

    func testWritabilityStartsTrueGoesFalseAndBackToTrue() throws {
        class WritabilityTrackerStateMachine: ChannelInboundHandler {
            typealias InboundIn = Never
            typealias OutboundOut = ByteBuffer

            enum State: Int {
                case beginsTrue = 0
                case thenFalse = 1
                case thenTrueAgain = 2
            }

            var channelWritabilityChangedCalls = 0
            var state = State.beginsTrue
            let writabilityNowFalsePromise: EventLoopPromise<Void>
            let writeFullyDonePromise: EventLoopPromise<Void>

            init(
                writabilityNowFalsePromise: EventLoopPromise<Void>,
                writeFullyDonePromise: EventLoopPromise<Void>
            ) {
                self.writabilityNowFalsePromise = writabilityNowFalsePromise
                self.writeFullyDonePromise = writeFullyDonePromise
            }

            func handlerAdded(context: ChannelHandlerContext) {
                // 5 MB, this must be safely more than send buffer + receive buffer. The reason is that we don't want
                // the overall write to complete before we make the other end of the channel readable.
                let totalAmount = 5 * 1024 * 1024
                let chunkSize = 10 * 1024
                XCTAssertEqual(.beginsTrue, self.state)
                self.state = .thenFalse
                XCTAssertEqual(true, context.channel.isWritable)

                var buffer = context.channel.allocator.buffer(capacity: chunkSize)
                buffer.writeBytes(repeatElement(UInt8(ascii: "x"), count: chunkSize))
                for _ in 0..<(totalAmount / chunkSize) {
                    context.write(self.wrapOutboundOut(buffer)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                }
                context.write(self.wrapOutboundOut(buffer)).map {
                    XCTAssertEqual(self.state, .thenTrueAgain)
                }.recover { error in
                    XCTFail("unexpected error \(error)")
                }.cascade(to: self.writeFullyDonePromise)
                context.flush()
            }

            func channelWritabilityChanged(context: ChannelHandlerContext) {
                self.channelWritabilityChangedCalls += 1
                XCTAssertEqual(self.state.rawValue % 2 == 0, context.channel.isWritable)
                XCTAssertEqual(State(rawValue: self.channelWritabilityChangedCalls), self.state)
                if let newState = State(rawValue: self.channelWritabilityChangedCalls + 1) {
                    if self.state == .thenFalse {
                        context.eventLoop.scheduleTask(in: .microseconds(100)) {
                            // Let's delay this a tiny little bit just so we get a higher chance to actually exhaust all
                            // the buffers. The delay is not necessary for this test to work but it makes the tests a
                            // little bit harder.
                            self.writabilityNowFalsePromise.succeed(())
                        }
                    }
                    self.state = newState
                }
            }
        }

        func runTest(chan1: Channel, chan2: Channel) throws {
            let allDonePromise = chan1.eventLoop.makePromise(of: ByteBuffer.self)
            let writabilityFalsePromise = chan1.eventLoop.makePromise(of: Void.self)
            let writeFullyDonePromise = chan1.eventLoop.makePromise(of: Void.self)
            XCTAssertNoThrow(try chan2.setOption(ChannelOptions.autoRead, value: false).wait())
            XCTAssertNoThrow(try chan2.pipeline.addHandler(AccumulateAllReads(allDonePromise: allDonePromise)).wait())
            XCTAssertNoThrow(
                try chan1.pipeline.addHandler(
                    WritabilityTrackerStateMachine(
                        writabilityNowFalsePromise: writabilityFalsePromise,
                        writeFullyDonePromise: writeFullyDonePromise
                    )
                ).wait()
            )

            // Writability should turn false because we're writing lots of data and we aren't reading.
            XCTAssertNoThrow(try writabilityFalsePromise.futureResult.wait())
            // Ok, let's read.
            XCTAssertNoThrow(try chan2.setOption(ChannelOptions.autoRead, value: true).wait())
            // Which should lead to the write to complete.
            XCTAssertNoThrow(try writeFullyDonePromise.futureResult.wait())
            // To finish up, let's just tear this down.
            XCTAssertNoThrow(try chan2.close().wait())
            XCTAssertNoThrow(try chan1.closeFuture.wait())
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testHalfCloseOwnOutput() throws {
        func runTest(chan1: Channel, chan2: Channel) throws {
            let readPromise = chan2.eventLoop.makePromise(of: Void.self)
            let eofPromise = chan1.eventLoop.makePromise(of: Void.self)

            XCTAssertNoThrow(try chan1.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait())
            XCTAssertNoThrow(
                try chan1.pipeline.addHandler(FulfillOnFirstEventHandler(userInboundEventTriggeredPromise: eofPromise))
                    .wait()
            )

            // let's close chan2's output
            XCTAssertNoThrow(try chan2.close(mode: .output).wait())
            XCTAssertNoThrow(try eofPromise.futureResult.wait())

            self.buffer.writeString("X")
            XCTAssertNoThrow(
                try chan2.pipeline.addHandler(FulfillOnFirstEventHandler(channelReadPromise: readPromise)).wait()
            )

            // let's write a byte from chan1 to chan2.
            XCTAssertNoThrow(try chan1.writeAndFlush(self.buffer).wait(), "write on \(chan1) failed")

            // and wait for it to arrive
            XCTAssertNoThrow(try readPromise.futureResult.wait())

            XCTAssertNoThrow(try chan1.syncCloseAcceptingAlreadyClosed())
            XCTAssertNoThrow(try chan2.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testHalfCloseOwnInput() {
        func runTest(chan1: Channel, chan2: Channel) throws {

            let readPromise = chan1.eventLoop.makePromise(of: Void.self)

            XCTAssertNoThrow(try chan2.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait())
            // let's close chan2's input
            XCTAssertNoThrow(try chan2.close(mode: .input).wait())

            self.buffer.writeString("X")
            XCTAssertNoThrow(
                try chan1.pipeline.addHandler(FulfillOnFirstEventHandler(channelReadPromise: readPromise)).wait()
            )

            // let's write a byte from chan2 to chan1.
            XCTAssertNoThrow(try chan2.writeAndFlush(self.buffer).wait())

            // and wait for it to arrive
            XCTAssertNoThrow(try readPromise.futureResult.wait())

            XCTAssertNoThrow(try chan1.syncCloseAcceptingAlreadyClosed())
            XCTAssertNoThrow(try chan2.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testDoubleShutdownInput() {
        func runTest(chan1: Channel, chan2: Channel) throws {
            XCTAssertNoThrow(try chan1.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait())
            XCTAssertNoThrow(try chan1.close(mode: .input).wait())
            XCTAssertThrowsError(try chan1.close(mode: .input).wait()) { error in
                XCTAssertEqual(ChannelError.inputClosed, error as? ChannelError, "\(chan1)")
            }
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testDoubleShutdownOutput() {
        func runTest(chan1: Channel, chan2: Channel) throws {
            XCTAssertNoThrow(try chan2.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait())
            XCTAssertNoThrow(try chan1.close(mode: .output).wait())
            XCTAssertThrowsError(try chan1.close(mode: .output).wait()) { error in
                XCTAssertEqual(ChannelError.outputClosed, error as? ChannelError, "\(chan1)")
            }
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testWriteFailsAfterOutputClosed() {
        func runTest(chan1: Channel, chan2: Channel) throws {
            XCTAssertNoThrow(try chan2.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait())
            XCTAssertNoThrow(try chan1.close(mode: .output).wait())
            var buffer = chan1.allocator.buffer(capacity: 10)
            buffer.writeString("helloworld")
            XCTAssertThrowsError(try chan1.writeAndFlush(buffer).wait()) { error in
                XCTAssertEqual(ChannelError.outputClosed, error as? ChannelError, "\(chan1)")
            }
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testVectorWrites() {
        func runTest(chan1: Channel, chan2: Channel) throws {
            let readPromise = chan2.eventLoop.makePromise(of: Void.self)
            XCTAssertNoThrow(chan2.pipeline.addHandler(FulfillOnFirstEventHandler(channelReadPromise: readPromise)))
            var buffer = chan1.allocator.buffer(capacity: 1)
            buffer.writeString("X")
            for _ in 0..<100 {
                chan1.write(buffer, promise: nil)
            }
            chan1.flush()
            XCTAssertNoThrow(try readPromise.futureResult.wait())
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testLotsOfWritesWhilstOtherSideNotReading() {
        // This is a regression test for a problem where we would spin on EVFILT_EXCEPT despite the fact that there
        // was no EOF or any other exceptional event present. So this is a regression test for rdar://53656794 and https://github.com/apple/swift-nio/pull/526.
        class FailOnReadHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            let areReadsOkayNow: ManagedAtomic<Bool>

            init(areReadOkayNow: ManagedAtomic<Bool>) {
                self.areReadsOkayNow = areReadOkayNow
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                guard self.areReadsOkayNow.load(ordering: .relaxed) else {
                    XCTFail("unexpected read of \(self.unwrapInboundIn(data))")
                    return
                }
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                guard self.areReadsOkayNow.load(ordering: .relaxed) else {
                    XCTFail("unexpected readComplete")
                    return
                }
            }
        }

        func runTest(receiver: Channel, sender: Channel) throws {
            let sends = ManagedAtomic(0)
            precondition(
                receiver.eventLoop !== sender.eventLoop,
                "this test cannot run if sender and receiver live on the same EventLoop. \(receiver)"
            )
            XCTAssertNoThrow(try receiver.setOption(ChannelOptions.autoRead, value: false).wait())
            let areReadsOkayNow = ManagedAtomic(false)
            XCTAssertNoThrow(
                try receiver.pipeline.addHandler(FailOnReadHandler(areReadOkayNow: areReadsOkayNow)).wait()
            )

            // We will immediately send exactly the amount of data that fits in the receiver's receive buffer.
            let receiveBufferSize = Int(
                (try? receiver.getOption(ChannelOptions.socketOption(.so_rcvbuf)).wait()) ?? 8192
            )
            var buffer = sender.allocator.buffer(capacity: receiveBufferSize)
            buffer.writeBytes(Array(repeating: UInt8(ascii: "X"), count: receiveBufferSize))

            XCTAssertNoThrow(
                try sender.eventLoop.submit {
                    func send() {
                        var allBuffer = buffer
                        // When we run through this for the first time, we send exactly the receive buffer size, after that
                        // we send one byte at a time. Sending the receive buffer will trigger the EVFILT_EXCEPT loop
                        // (rdar://53656794) for UNIX Domain Sockets and the additional 1 byte send loop will also pretty
                        // reliably trigger it for TCP sockets.
                        let myBuffer = allBuffer.readSlice(
                            length: sends.load(ordering: .relaxed) == 0 ? receiveBufferSize : 1
                        )!
                        sender.writeAndFlush(myBuffer).map {
                            sends.wrappingIncrement(ordering: .relaxed)
                            sender.eventLoop.scheduleTask(in: .microseconds(1)) {
                                send()
                            }
                        }.whenFailure { error in
                            XCTAssert(
                                areReadsOkayNow.load(ordering: .relaxed),
                                "error before the channel should go down"
                            )
                            guard case .some(.ioOnClosedChannel) = error as? ChannelError else {
                                XCTFail("unexpected error: \(error)")
                                return
                            }
                        }
                    }
                    send()
                }.wait()
            )

            for _ in 0..<10 {
                // We just spin here for a little while to check that there are no bogus events available on the
                // selector.
                let eventLoop = (receiver.eventLoop as! SelectableEventLoop)
                XCTAssertNoThrow(
                    try eventLoop._selector.testsOnly_withUnsafeSelectorFD { fd in
                        try assertNoSelectorChanges(fd: fd, selector: eventLoop._selector)
                    },
                    "after \(sends.load(ordering: .relaxed)) sends, we got an unexpected selector event for \(receiver)"
                )
                usleep(10000)
            }
            // We'll soon close the channels, so reads are now acceptable (from the EOF that we may read).
            XCTAssertTrue(areReadsOkayNow.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged)
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(forceSeparateEventLoops: true, runTest))
    }

    func testFlushInWritePromise() {
        class WaitForTwoBytesHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let allDonePromise: EventLoopPromise<Void>
            private var numberOfBytes = 0

            init(allDonePromise: EventLoopPromise<Void>) {
                self.allDonePromise = allDonePromise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                // The two writes could be coalesced, so we add up the bytes and not always the number of read calls.
                self.numberOfBytes += self.unwrapInboundIn(data).readableBytes
                if self.numberOfBytes == 2 {
                    self.allDonePromise.succeed(())
                }
            }
        }

        func runTest(receiver: Channel, sender: Channel) throws {
            let allDonePromise = receiver.eventLoop.makePromise(of: Void.self)
            XCTAssertNoThrow(try sender.setOption(ChannelOptions.writeSpin, value: 0).wait())
            XCTAssertNoThrow(
                try receiver.pipeline.addHandler(WaitForTwoBytesHandler(allDonePromise: allDonePromise)).wait()
            )
            var buffer = sender.allocator.buffer(capacity: 1)
            buffer.writeString("X")
            XCTAssertNoThrow(
                try sender.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
                    let writePromise = sender.eventLoop.makePromise(of: Void.self)
                    let bothWritesResult = writePromise.futureResult.flatMap {
                        sender.writeAndFlush(buffer)
                    }
                    sender.writeAndFlush(buffer, promise: writePromise)
                    return bothWritesResult
                }.wait()
            )
            XCTAssertNoThrow(try allDonePromise.futureResult.wait())
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testWriteAndFlushInChannelWritabilityChangedToTrue() {
        // regression test for rdar://58571521
        final class WriteWhenWritabilityGoesToTrue: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var numberOfCalls = 0

            func channelWritabilityChanged(context: ChannelHandlerContext) {
                self.numberOfCalls += 1

                switch self.numberOfCalls {
                case 1:
                    // This is us exceeding the high water mark
                    XCTAssertFalse(context.channel.isWritable)
                case 2:
                    // This is after the two bytes have been written.
                    XCTAssertTrue(context.channel.isWritable)

                    // Now, let's trigger another write which should cause flushNow to be re-entered. But first, let's
                    // raise the high water mark so we don't get another call straight away.
                    var buffer = context.channel.allocator.buffer(capacity: 5)
                    buffer.writeString("hello")
                    context.channel.setOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 1024, high: 1024))
                        .flatMap {
                            context.writeAndFlush(self.wrapOutboundOut(buffer))
                        }.whenFailure { error in
                            XCTFail("unexpected error: \(error)")
                        }
                default:
                    XCTFail("call \(self.numberOfCalls) to \(#function) unexpected")
                }
            }
        }

        final class WaitForNumberOfBytes: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let allDonePromise: EventLoopPromise<Void>
            private var numberOfReads = 0
            private let expectedNumberOfBytes: Int

            init(numberOfBytes: Int, allDonePromise: EventLoopPromise<Void>) {
                self.expectedNumberOfBytes = numberOfBytes
                self.allDonePromise = allDonePromise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                // The two writes could be coalesced, so we add up the bytes and not always the number of read calls.
                self.numberOfReads += self.unwrapInboundIn(data).readableBytes
                if self.numberOfReads >= self.expectedNumberOfBytes {
                    self.allDonePromise.succeed(())
                }
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                self.allDonePromise.fail(ChannelError.ioOnClosedChannel)
            }
        }

        func runTest(receiver: Channel, sender: Channel) throws {
            // Write spin might just disturb this test so let's switch it off
            XCTAssertNoThrow(try sender.setOption(ChannelOptions.writeSpin, value: 0).wait())
            // Writing more than the high water mark will cause the channel to become unwritable very easily
            XCTAssertNoThrow(
                try sender.setOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 1, high: 1)).wait()
            )

            let sevenBytesReceived = receiver.eventLoop.makePromise(of: Void.self)
            XCTAssertNoThrow(
                try receiver.pipeline.addHandler(
                    WaitForNumberOfBytes(
                        numberOfBytes: 7,
                        allDonePromise: sevenBytesReceived
                    )
                ).wait()
            )

            let eventCounterHandler = EventCounterHandler()
            XCTAssertNoThrow(try sender.pipeline.addHandler(EventCounterHandler()).wait())
            XCTAssertNoThrow(try sender.pipeline.addHandler(WriteWhenWritabilityGoesToTrue()).wait())

            var buffer = sender.allocator.buffer(capacity: 5)
            buffer.writeString("XX")  // 2 bytes, exceeds the high water mark

            XCTAssertTrue(sender.isWritable)
            XCTAssertEqual(0, eventCounterHandler.channelWritabilityChangedCalls)
            XCTAssertNoThrow(try sender.writeAndFlush(buffer).wait())
            XCTAssertNoThrow(try sevenBytesReceived.futureResult.wait())
        }

        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testWritabilityChangedDoesNotGetCalledOnSimpleWrite() {
        func runTest(receiver: Channel, sender: Channel) throws {
            let eventCounter = EventCounterHandler()
            XCTAssertNoThrow(try sender.pipeline.addHandler(eventCounter).wait())
            var buffer = sender.allocator.buffer(capacity: 1)
            buffer.writeString("X")
            XCTAssertNoThrow(try sender.writeAndFlush(buffer).wait())
            XCTAssertEqual(0, eventCounter.channelWritabilityChangedCalls)
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testWriteAndFlushFromReentrantFlushNowTriggeredOutOfWritabilityWhereOuterSaysAllWrittenAndInnerDoesNot() {
        // regression test for rdar://58571521, harder version

        /*
         What we're doing here is to enter exactly the following scenario which used to be an issue.

         1: writable()
         2: --> flushNow (result: .writtenCompletely)
         3:     --> writabilityChanged callout
         4:         --> flushNow because user calls writeAndFlush (result: .couldNotWriteEverything)
         5:         --> registerForWritable (because line 4 could not write everything and flushNow returned .register)
         6: --> unregisterForWritable (because line 2 wrote everything and flushNow returned .unregister)

         line 6 undoes the registration in line 5. The fix makes sure that flushNow never re-enters and therefore the
         problem described above cannot happen anymore.

         Our match plan is the following:
         - receiver: switch off autoRead
         - sender: send 1k chunks of "0"s until we get a writabilityChange to false, then write a "1" sentinel
         - sender: should now be registered for writes
         - receiver: allocate a buffer big enough for the "0....1" and read it out as soon as possible
         - sender: the kernel should now call us with the `writable()` notification
         - sender: the remaining "0...1" should now go out of the door together, which means that `flushNow` decides
                   to `.unregister`
         - sender: because we now `.unregister` and also fall below the low watermark, we will send a writabilityChange
                   notification from which we will send a large 100MB chunk which certainly requires a new `writable()`
                   registration (which was previously lost)
         - receiver: just read off all the bytes
         - test: wait until the 100MB write completes which means that we didn't lost that `writable()` registration and
                 everybody should be happy :)
         */

        final class WriteUntilWriteDoesNotCompletelyInstantlyHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            enum State {
                case writingUntilFull
                case writeSentinel
                case done
            }

            let chunkSize: Int
            let wroteEnoughToBeStuckPromise: EventLoopPromise<Int>
            var state = State.writingUntilFull
            var bytesWritten = 0

            init(chunkSize: Int, wroteEnoughToBeStuckPromise: EventLoopPromise<Int>) {
                self.chunkSize = chunkSize
                self.wroteEnoughToBeStuckPromise = wroteEnoughToBeStuckPromise
            }

            func handlerAdded(context: ChannelHandlerContext) {
                // We set the high watermark such that if we can't write something immediately, we'll get a
                // writabilityChanged notification.
                context.channel.setOption(
                    ChannelOptions.writeBufferWaterMark,
                    value: .init(
                        low: self.chunkSize,
                        high: self.chunkSize + 1
                    )
                ).whenFailure { error in
                    XCTFail("unexpected error \(error)")
                }

                // Write spin count would make the test less deterministic, so let's switch it off.
                context.channel.setOption(ChannelOptions.writeSpin, value: 0).whenFailure { error in
                    XCTFail("unexpected error \(error)")
                }

                context.eventLoop.execute {
                    self.kickOff(context: context)
                }
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertEqual(.done, self.state)
            }

            func kickOff(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: self.chunkSize)
                buffer.writeBytes(Array(repeating: UInt8(ascii: "0"), count: chunkSize))

                func writeOneMore() {
                    self.bytesWritten += buffer.readableBytes
                    context.writeAndFlush(self.wrapOutboundOut(buffer)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    context.eventLoop.scheduleTask(in: .microseconds(100)) {
                        switch self.state {
                        case .writingUntilFull:
                            // We're just enqueuing another chunk.
                            writeOneMore()
                        case .writeSentinel:
                            // We've seen the notification that the channel is unwritable, let's write one more byte.
                            buffer.clear()
                            buffer.writeString("1")
                            self.state = .done
                            self.bytesWritten += 1
                            context.writeAndFlush(self.wrapOutboundOut(buffer)).whenFailure { error in
                                XCTFail("unexpected error \(error)")
                            }
                            self.wroteEnoughToBeStuckPromise.succeed(self.bytesWritten)
                        case .done:
                            ()  // let's ignore this.
                        }
                    }
                }
                context.eventLoop.execute {
                    writeOneMore()  // this kicks everything off
                }
            }

            func channelWritabilityChanged(context: ChannelHandlerContext) {
                switch self.state {
                case .writingUntilFull:
                    XCTAssert(!context.channel.isWritable)
                    self.state = .writeSentinel
                case .writeSentinel:
                    XCTFail("we shouldn't see another notification here writable=\(context.channel.isWritable)")
                case .done:
                    ()  // ignored, we're done
                }
                context.fireChannelWritabilityChanged()
                self.wroteEnoughToBeStuckPromise.futureResult.whenSuccess { _ in
                    context.pipeline.removeHandler(self).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                }
            }
        }

        final class WriteWhenChannelBecomesWritableAgain: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            enum State {
                case waitingForNotWritable
                case waitingForWritableAgain
                case done
            }

            var state = State.waitingForNotWritable
            let beganBigWritePromise: EventLoopPromise<Void>
            let finishedBigWritePromise: EventLoopPromise<Void>

            init(beganBigWritePromise: EventLoopPromise<Void>, finishedBigWritePromise: EventLoopPromise<Void>) {
                self.beganBigWritePromise = beganBigWritePromise
                self.finishedBigWritePromise = finishedBigWritePromise
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertEqual(.done, self.state)
            }

            func channelWritabilityChanged(context: ChannelHandlerContext) {
                switch self.state {
                case .waitingForNotWritable:
                    XCTAssert(!context.channel.isWritable)
                    self.state = .waitingForWritableAgain
                case .waitingForWritableAgain:
                    XCTAssert(context.channel.isWritable)
                    self.state = .done
                    var buffer = context.channel.allocator.buffer(capacity: 10 * 1024 * 1024)
                    buffer.writeBytes(Array(repeating: UInt8(ascii: "X"), count: buffer.capacity - 1))
                    context.writeAndFlush(self.wrapOutboundOut(buffer), promise: self.finishedBigWritePromise)
                    self.beganBigWritePromise.succeed(())
                case .done:
                    ()  // ignored
                }
            }
        }

        final class ReadChunksUntilWeSee1Handler: ChannelDuplexHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundIn = ByteBuffer

            enum State {
                case waitingForInitialOutsideReadCall
                case waitingForZeroesTerminatedByOne
                case done
            }

            var state: State = .waitingForInitialOutsideReadCall

            func handlerAdded(context: ChannelHandlerContext) {
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { error in
                    XCTFail("unexpected error \(error)")
                }
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertEqual(.done, self.state)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let buffer = self.unwrapInboundIn(data)
                switch self.state {
                case .waitingForInitialOutsideReadCall:
                    XCTFail("unexpected \(#function)")
                case .waitingForZeroesTerminatedByOne:
                    buffer.withUnsafeReadableBytes { buffer in
                        if buffer.first(where: { byte in byte == UInt8(ascii: "1") }) != nil {
                            self.state = .done
                        }
                    }
                case .done:
                    ()  // let's ignore those reads, just 100 MB of Xs.
                }
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                switch self.state {
                case .waitingForInitialOutsideReadCall:
                    XCTFail("unexpected \(#function)")
                case .waitingForZeroesTerminatedByOne:
                    context.read()  // read more
                case .done:
                    ()  // let's stop reading forever
                }
            }

            func read(context: ChannelHandlerContext) {
                switch self.state {
                case .waitingForInitialOutsideReadCall:
                    self.state = .waitingForZeroesTerminatedByOne
                case .waitingForZeroesTerminatedByOne, .done:
                    ()  // nothing else to do
                }
                context.read()
            }
        }

        final class FailOnError: ChannelInboundHandler {
            typealias InboundIn = Never

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                XCTFail("unexpected error in \(context.channel): \(error)")
            }
        }

        func runTest(receiver: Channel, sender: Channel) throws {
            // This promise will be fulfilled once we have exhausted all buffers and writes no longer worked for the
            // sender. We can then start reading. The integer is the number of written bytes.
            let wroteEnoughToBeStuckPromise: EventLoopPromise<Int> = sender.eventLoop.makePromise()

            // This promise is fulfilled when we enqueue the big write on the sender side
            let beganBigWritePromise: EventLoopPromise<Void> = sender.eventLoop.makePromise()

            // This promise is fulfilled when we're done writing the big write, ie. all is done.
            let finishedBigWritePromise: EventLoopPromise<Void> = sender.eventLoop.makePromise()

            let chunkSize = 1024

            // We need to not read automatically from the receiving end to be able to force writability notifications
            // for the sender.
            XCTAssertNoThrow(try receiver.setOption(ChannelOptions.autoRead, value: false).wait())

            XCTAssertNoThrow(try receiver.pipeline.addHandler(ReadChunksUntilWeSee1Handler()).wait())

            XCTAssertNoThrow(
                try sender.pipeline.addHandler(
                    WriteWhenChannelBecomesWritableAgain(
                        beganBigWritePromise: beganBigWritePromise,
                        finishedBigWritePromise: finishedBigWritePromise
                    )
                ).wait()
            )
            XCTAssertNoThrow(try sender.pipeline.addHandler(FailOnError()).wait())
            XCTAssertNoThrow(try receiver.pipeline.addHandler(FailOnError()).wait())

            XCTAssertNoThrow(
                try sender.pipeline.addHandler(
                    WriteUntilWriteDoesNotCompletelyInstantlyHandler(
                        chunkSize: chunkSize,
                        wroteEnoughToBeStuckPromise: wroteEnoughToBeStuckPromise
                    ),
                    position: .first
                ).wait()
            )
            var howManyBytes: Int? = nil

            XCTAssertNoThrow(howManyBytes = try wroteEnoughToBeStuckPromise.futureResult.wait())
            guard let bytes = howManyBytes else {
                XCTFail("couldn't determine how much was written.")
                return
            }

            // Let's prepare the receiver's allocator to allocate exactly the right amount of bytes :), ...
            XCTAssertNoThrow(
                try receiver.setOption(
                    ChannelOptions.recvAllocator,
                    value: FixedSizeRecvByteBufferAllocator(capacity: bytes)
                ).wait()
            )

            // ... wait for the sender to not send any more, and ...
            XCTAssertNoThrow(try wroteEnoughToBeStuckPromise.futureResult.wait())

            // ... make the receiver read.
            receiver.read()

            // Now, we wait until the big write has been enqueued, that's when we should enter the main stage of this
            // test.
            XCTAssertNoThrow(try beganBigWritePromise.futureResult.wait())

            // We now just set autoRead to true and let the receiver receive everything to tear everything down.
            XCTAssertNoThrow(try receiver.setOption(ChannelOptions.autoRead, value: true).wait())

            XCTAssertNoThrow(try finishedBigWritePromise.futureResult.wait())
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }

    func testCloseInReEntrantFlushNowCall() {
        func runTest(receiver: Channel, sender: Channel) throws {
            final class CloseInWritabilityChanged: ChannelInboundHandler {
                typealias InboundIn = Never
                typealias OutboundOut = ByteBuffer

                private let amount: Int
                private var numberOfCalls = 0

                init(amount: Int) {
                    self.amount = amount
                }

                func channelWritabilityChanged(context: ChannelHandlerContext) {
                    self.numberOfCalls += 1
                    switch self.numberOfCalls {
                    case 1:
                        XCTAssertFalse(context.channel.isWritable)  // because we sent more than high water
                    case 2:
                        XCTAssertTrue(context.channel.isWritable)  // but actually only 2 bytes

                        // Let's send another 2 bytes, ...
                        var buffer = context.channel.allocator.buffer(capacity: amount)
                        buffer.writeBytes(Array(repeating: UInt8(ascii: "X"), count: amount))
                        context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)

                        // ... and let's close
                        context.close(promise: nil)
                    case 3:
                        XCTAssertFalse(context.channel.isWritable)  // 2 bytes > high water
                    default:
                        XCTFail("\(self.numberOfCalls) calls to \(#function) are unexpected")
                    }
                }
            }

            let amount = 2
            XCTAssertNoThrow(try sender.pipeline.addHandler(CloseInWritabilityChanged(amount: amount)).wait())
            XCTAssertNoThrow(
                try sender.setOption(
                    ChannelOptions.writeBufferWaterMark,
                    value: .init(
                        low: amount - 1,
                        high: amount - 1
                    )
                ).wait()
            )
            var buffer = sender.allocator.buffer(capacity: amount)
            buffer.writeBytes(Array(repeating: UInt8(ascii: "X"), count: amount))
            XCTAssertNoThrow(try sender.writeAndFlush(buffer).wait())
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
    }
}

final class AccumulateAllReads: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    var accumulator: ByteBuffer!
    let allDonePromise: EventLoopPromise<ByteBuffer>

    init(allDonePromise: EventLoopPromise<ByteBuffer>) {
        self.allDonePromise = allDonePromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.accumulator = context.channel.allocator.buffer(capacity: 1024)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        let closeAfter = buffer.readableBytesView.last == UInt8(ascii: "$")
        self.accumulator.writeBuffer(&buffer)
        if closeAfter {
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.allDonePromise.succeed(self.accumulator)
        self.accumulator = nil
    }
}

private func assertNoSelectorChanges(
    fd: CInt,
    selector: NIOPosix.Selector<NIORegistration>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    struct UnexpectedSelectorChanges: Error, CustomStringConvertible {
        let description: String
    }

    #if canImport(Darwin) || os(FreeBSD)
    var ev: kevent = .init()
    var nothing: timespec = .init()
    let numberOfEvents = try KQueue.kevent(
        kq: fd,
        changelist: nil,
        nchanges: 0,
        eventlist: &ev,
        nevents: 1,
        timeout: &nothing
    )
    guard numberOfEvents == 0 else {
        throw UnexpectedSelectorChanges(description: "\(ev)")
    }
    #elseif os(Linux) || os(Android)
    #if !SWIFTNIO_USE_IO_URING
    var ev = Epoll.epoll_event()
    let numberOfEvents = try Epoll.epoll_wait(epfd: fd, events: &ev, maxevents: 1, timeout: 0)
    guard numberOfEvents == 0 else {
        throw UnexpectedSelectorChanges(description: "\(ev) [userdata: \(EPollUserData(rawValue: ev.data.u64))]")
    }
    #else
    let events: UnsafeMutablePointer<URingEvent> = UnsafeMutablePointer.allocate(capacity: 1)
    events.initialize(to: URingEvent())
    let numberOfEvents = try selector.ring.io_uring_wait_cqe_timeout(
        events: events,
        maxevents: 1,
        timeout: TimeAmount.seconds(0)
    )
    events.deinitialize(count: 1)
    events.deallocate()
    guard numberOfEvents == 0 else {
        throw UnexpectedSelectorChanges(description: "\(selector)")
    }
    #endif
    #else
    #warning("assertNoSelectorChanges unsupported on this OS.")
    #endif
}
