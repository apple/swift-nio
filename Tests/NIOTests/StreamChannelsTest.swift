//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIO
import NIOConcurrencyHelpers

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
                XCTAssertNoThrow(chan2.writeAndFlush(everythingBuffer.getSlice(at: from,
                                                                               length: everythingBuffer.writerIndex - from)!))
            }
            let from = everythingBuffer.writerIndex
            everythingBuffer.writeString("$") // magic end marker that will cause the channel to close
            XCTAssertNoThrow(chan2.writeAndFlush(everythingBuffer.getSlice(at: from, length: 1)!))
            XCTAssertNoThrow(XCTAssertEqual(everythingBuffer, try allDonePromise.futureResult.wait()))
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(runTest))
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

            init(writabilityNowFalsePromise: EventLoopPromise<Void>,
                 writeFullyDonePromise: EventLoopPromise<Void>) {
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
                for _ in 0 ..< (totalAmount / chunkSize) {
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
            XCTAssertNoThrow(try chan1.pipeline.addHandler(WritabilityTrackerStateMachine(writabilityNowFalsePromise: writabilityFalsePromise,
                                                                                          writeFullyDonePromise: writeFullyDonePromise)).wait())

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
            XCTAssertNoThrow(try chan1.pipeline.addHandler(FulfillOnFirstEventHandler(userInboundEventTriggeredPromise: eofPromise)).wait())

            // let's close chan2's output
            XCTAssertNoThrow(try chan2.close(mode: .output).wait())
            XCTAssertNoThrow(try eofPromise.futureResult.wait())

            self.buffer.writeString("X")
            XCTAssertNoThrow(try chan2.pipeline.addHandler(FulfillOnFirstEventHandler(channelReadPromise: readPromise)).wait())

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
            XCTAssertNoThrow(try chan1.pipeline.addHandler(FulfillOnFirstEventHandler(channelReadPromise: readPromise)).wait())

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

            let areReadsOkayNow: NIOAtomic<Bool>

            init(areReadOkayNow: NIOAtomic<Bool>) {
                self.areReadsOkayNow = areReadOkayNow
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                guard self.areReadsOkayNow.load() else {
                    XCTFail("unexpected read of \(self.unwrapInboundIn(data))")
                    return
                }
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                guard self.areReadsOkayNow.load() else {
                    XCTFail("unexpected readComplete")
                    return
                }
            }
        }

        func runTest(receiver: Channel, sender: Channel) throws {
            let sends = NIOAtomic<Int>.makeAtomic(value: 0)
            precondition(receiver.eventLoop !== sender.eventLoop,
                         "this test cannot run if sender and receiver live on the same EventLoop. \(receiver)")
            XCTAssertNoThrow(try receiver.setOption(ChannelOptions.autoRead, value: false).wait())
            let areReadsOkayNow: NIOAtomic<Bool> = .makeAtomic(value: false)
            XCTAssertNoThrow(try receiver.pipeline.addHandler(FailOnReadHandler(areReadOkayNow: areReadsOkayNow)).wait())

            // We will immediately send exactly the amount of data that fits in the receiver's receive buffer.
            let receiveBufferSize = Int((try? receiver.getOption(ChannelOptions.socket(.init(SOL_SOCKET),
                                                                                       .init(SO_RCVBUF))).wait()) ?? 8192)
            var buffer = sender.allocator.buffer(capacity: receiveBufferSize)
            buffer.writeBytes(Array(repeating: UInt8(ascii: "X"), count: receiveBufferSize))

            XCTAssertNoThrow(try sender.eventLoop.submit {
                func send() {
                    var allBuffer = buffer
                    // When we run through this for the first time, we send exactly the receive buffer size, after that
                    // we send one byte at a time. Sending the receive buffer will trigger the EVFILT_EXCEPT loop
                    // (rdar://53656794) for UNIX Domain Sockets and the additional 1 byte send loop will also pretty
                    // reliably trigger it for TCP sockets.
                    let myBuffer = allBuffer.readSlice(length: sends.load() == 0 ? receiveBufferSize : 1)!
                    sender.writeAndFlush(myBuffer).map {
                        _ = sends.add(1)
                        sender.eventLoop.scheduleTask(in: .microseconds(1)) {
                            send()
                        }
                    }.whenFailure { error in
                        XCTAssert(areReadsOkayNow.load(), "error before the channel should go down")
                        guard case .some(.ioOnClosedChannel) = error as? ChannelError else {
                            XCTFail("unexpected error: \(error)")
                            return
                        }
                    }
                }
                send()
            }.wait())

            for _ in 0..<10 {
                // We just spin here for a little while to check that there are no bogus events available on the
                // selector.
                XCTAssertNoThrow(try (receiver.eventLoop as! SelectableEventLoop)
                    ._selector.testsOnly_withUnsafeSelectorFD { fd in
                        try assertNoSelectorChanges(fd: fd)
                    }, "after \(sends.load()) sends, we got an unexpected selector event for \(receiver)")
                usleep(10000)
            }
            // We'll soon close the channels, so reads are now acceptable (from the EOF that we may read).
            XCTAssertTrue(areReadsOkayNow.compareAndExchange(expected: false, desired: true))
        }
        XCTAssertNoThrow(try forEachCrossConnectedStreamChannelPair(forceSeparateEventLoops: true, runTest))
    }
}

final class AccumulateAllReads: ChannelInboundHandler {
    typealias InboundIn =  ByteBuffer

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

private func assertNoSelectorChanges(fd: CInt, file: StaticString = #file, line: UInt = #line) throws {
    struct UnexpectedSelectorChanges: Error, CustomStringConvertible {
        let description: String
    }

    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(FreeBSD)
    var ev: kevent = .init()
    var nothing: timespec = .init()
    let numberOfEvents = try KQueue.kevent(kq: fd, changelist: nil, nchanges: 0, eventlist: &ev, nevents: 1, timeout: &nothing)
    guard numberOfEvents == 0 else {
        throw UnexpectedSelectorChanges(description: "\(ev)")
    }
    #elseif os(Linux) || os(Android)
    var ev = Epoll.epoll_event()
    let numberOfEvents = try Epoll.epoll_wait(epfd: fd, events: &ev, maxevents: 1, timeout: 0)
    guard numberOfEvents == 0 else {
        throw UnexpectedSelectorChanges(description: "\(ev)")
    }
    #else
    #warning("assertNoSelectorChanges unsupported on this OS.")
    #endif
}
