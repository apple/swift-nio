//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
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

#if os(Linux)
import CNIOLinux
#endif

extension Channel {
    func waitForDatagrams(count: Int) throws -> [AddressedEnvelope<ByteBuffer>] {
        try self.pipeline.context(name: "ByteReadRecorder").flatMap { context in
            if let future = (context.handler as? DatagramReadRecorder<ByteBuffer>)?.notifyForDatagrams(count) {
                return future
            }

            XCTFail("Could not wait for reads")
            return self.eventLoop.makeSucceededFuture([] as [AddressedEnvelope<ByteBuffer>])
        }.wait()
    }

    func waitForErrors(count: Int) throws -> [any Error] {
        try self.pipeline.context(name: "ByteReadRecorder").flatMap { context in
            if let future = (context.handler as? DatagramReadRecorder<ByteBuffer>)?.notifyForErrors(count) {
                return future
            }

            XCTFail("Could not wait for errors")
            return self.eventLoop.makeSucceededFuture([])
        }.wait()
    }

    func readCompleteCount() throws -> Int {
        try self.pipeline.context(name: "ByteReadRecorder").map { context in
            (context.handler as! DatagramReadRecorder<ByteBuffer>).readCompleteCount
        }.wait()
    }

    func configureForRecvMmsg(messageCount: Int) throws {
        let totalBufferSize = messageCount * 2048

        try self.setOption(
            .recvAllocator,
            value: FixedSizeRecvByteBufferAllocator(capacity: totalBufferSize)
        ).flatMap {
            self.setOption(.datagramVectorReadMessageCount, value: messageCount)
        }.wait()
    }
}

/// A class that records datagrams received and forwards them on.
///
/// Used extensively in tests to validate messaging expectations.
final class DatagramReadRecorder<DataType: Sendable>: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<DataType>
    typealias InboundOut = AddressedEnvelope<DataType>

    enum State {
        case fresh
        case registered
        case active
    }

    var reads: [AddressedEnvelope<DataType>] = []
    var errors: [any Error] = []
    var loop: EventLoop? = nil
    var state: State = .fresh

    var readWaiters: [Int: EventLoopPromise<[AddressedEnvelope<DataType>]>] = [:]
    var errorWaiters: [Int: EventLoopPromise<[any Error]>] = [:]
    var readCompleteCount = 0

    func channelRegistered(context: ChannelHandlerContext) {
        XCTAssertEqual(.fresh, self.state)
        self.state = .registered
        self.loop = context.eventLoop
    }

    func channelActive(context: ChannelHandlerContext) {
        XCTAssertEqual(.registered, self.state)
        self.state = .active
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTAssertEqual(.active, self.state)
        let data = Self.unwrapInboundIn(data)
        reads.append(data)

        if let promise = readWaiters.removeValue(forKey: reads.count) {
            promise.succeed(reads)
        }

        context.fireChannelRead(Self.wrapInboundOut(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.errors.append(error)

        if let promise = self.errorWaiters.removeValue(forKey: self.errors.count) {
            promise.succeed(self.errors)
        }

        context.fireErrorCaught(error)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.readCompleteCount += 1
        context.fireChannelReadComplete()
    }

    func notifyForDatagrams(_ count: Int) -> EventLoopFuture<[AddressedEnvelope<DataType>]> {
        guard reads.count < count else {
            return loop!.makeSucceededFuture(.init(reads.prefix(count)))
        }

        readWaiters[count] = loop!.makePromise()
        return readWaiters[count]!.futureResult
    }

    func notifyForErrors(_ count: Int) -> EventLoopFuture<[any Error]> {
        guard self.errors.count < count else {
            return self.loop!.makeSucceededFuture(.init(self.errors.prefix(count)))
        }

        self.errorWaiters[count] = self.loop!.makePromise()
        return self.errorWaiters[count]!.futureResult
    }
}

class DatagramChannelTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup! = nil
    private var firstChannel: Channel! = nil
    private var secondChannel: Channel! = nil
    private var thirdChannel: Channel! = nil

    private func buildChannel(group: EventLoopGroup, host: String = "127.0.0.1") throws -> Channel {
        try DatagramBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DatagramReadRecorder<ByteBuffer>(),
                        name: "ByteReadRecorder"
                    )
                }
            }
            .bind(host: host, port: 0)
            .wait()
    }

    private var supportsIPv6: Bool {
        do {
            let ipv6Loopback = try SocketAddress(ipAddress: "::1", port: 0)
            return try System.enumerateDevices().contains(where: { $0.address == ipv6Loopback })
        } catch {
            return false
        }
    }

    override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.firstChannel = try! buildChannel(group: group)
        self.secondChannel = try! buildChannel(group: group)
        self.thirdChannel = try! buildChannel(group: group)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
        super.tearDown()
    }

    func testBasicChannelCommunication() throws {
        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(writeData).wait())

        let reads = try self.secondChannel.waitForDatagrams(count: 1)
        XCTAssertEqual(reads.count, 1)
        let read = reads.first!
        XCTAssertEqual(read.data, buffer)
        XCTAssertEqual(read.remoteAddress, self.firstChannel.localAddress!)
    }

    func testEmptyDatagram() throws {
        let buffer = self.firstChannel.allocator.buffer(capacity: 0)
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(writeData).wait())

        let reads = try self.secondChannel.waitForDatagrams(count: 1)
        XCTAssertEqual(reads.count, 1)
        let read = reads.first!
        XCTAssertEqual(read.data, buffer)
        XCTAssertEqual(read.remoteAddress, self.firstChannel.localAddress!)
    }

    func testManyWrites() throws {
        var buffer = firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        var writeFutures: [EventLoopFuture<Void>] = []
        for _ in 0..<5 {
            writeFutures.append(self.firstChannel.write(writeData))
        }
        self.firstChannel.flush()
        XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(writeFutures, on: self.firstChannel.eventLoop).wait())

        let reads = try self.secondChannel.waitForDatagrams(count: 5)

        // These short datagrams should not have been dropped by the kernel.
        XCTAssertEqual(reads.count, 5)

        for read in reads {
            XCTAssertEqual(read.data, buffer)
            XCTAssertEqual(read.remoteAddress, self.firstChannel.localAddress!)
        }
    }

    func testDatagramChannelHasWatermark() throws {
        _ = try self.firstChannel.setOption(
            .writeBufferWaterMark,
            value: ChannelOptions.Types.WriteBufferWaterMark(low: 1, high: 1024)
        ).wait()

        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.writeBytes([UInt8](repeating: 5, count: 256))
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        XCTAssertTrue(self.firstChannel.isWritable)
        for _ in 0..<4 {
            // We submit to the loop here to make sure that we synchronously process the writes and checks
            // on writability.
            let writable: Bool = try self.firstChannel.eventLoop.submit { [firstChannel] in
                firstChannel!.write(writeData, promise: nil)
                return firstChannel!.isWritable
            }.wait()
            XCTAssertTrue(writable)
        }

        let lastWritePromise = self.firstChannel.eventLoop.makePromise(of: Void.self)
        // The last write will push us over the edge.
        var writable: Bool = try self.firstChannel.eventLoop.submit { [firstChannel] in
            firstChannel!.write(writeData, promise: lastWritePromise)
            return firstChannel!.isWritable
        }.wait()
        XCTAssertFalse(writable)

        // Now we're going to flush, and check the writability immediately after.
        self.firstChannel.flush()
        writable = try lastWritePromise.futureResult.map { [firstChannel] _ in
            firstChannel!.isWritable
        }.wait()
        XCTAssertTrue(writable)
    }

    func testWriteFuturesFailWhenChannelClosed() throws {
        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        let promises = (0..<5).map { _ in self.firstChannel.write(writeData) }

        // Now close the channel. When that completes, all the futures should be complete too.
        let fulfilled = try self.firstChannel.close().map {
            promises.map { $0.isFulfilled }.allSatisfy { $0 }
        }.wait()
        XCTAssertTrue(fulfilled)

        for promise in promises {
            XCTAssertThrowsError(try promise.wait()) { error in
                XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
            }
        }
    }

    func testManyManyDatagramWrites() throws {
        // We're going to try to write loads, and loads, and loads of data. In this case, one more
        // write than the iovecs max.

        var overall: EventLoopFuture<Void> = self.firstChannel.eventLoop.makeSucceededFuture(())
        for _ in 0...Socket.writevLimitIOVectors {
            let myPromise = self.firstChannel.eventLoop.makePromise(of: Void.self)
            var buffer = self.firstChannel.allocator.buffer(capacity: 1)
            buffer.writeString("a")
            let envelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
            self.firstChannel.write(envelope, promise: myPromise)
            overall = EventLoopFuture.andAllSucceed([overall, myPromise.futureResult], on: self.firstChannel.eventLoop)
        }
        self.firstChannel.flush()
        XCTAssertNoThrow(try overall.wait())
        // We're not going to check that the datagrams arrive, because some kernels *will* drop them here.
    }

    func testSendmmsgLotsOfData() throws {
        // We defer this work to the background thread because otherwise it incurs an enormous number of context
        // switches.
        let overall = try self.firstChannel.eventLoop.submit { [firstChannel, secondChannel] in
            let myPromise = firstChannel!.eventLoop.makePromise(of: Void.self)
            // For datagrams this buffer cannot be very large, because if it's larger than the path MTU it
            // will cause EMSGSIZE.
            let bufferSize = 1024 * 5
            var buffer = firstChannel!.allocator.buffer(capacity: bufferSize)
            buffer.writeRepeatingByte(4, count: bufferSize)
            let envelope = AddressedEnvelope(remoteAddress: secondChannel!.localAddress!, data: buffer)

            let lotsOfData = Int(Int32.max)
            var written: Int64 = 0
            var overall = firstChannel!.eventLoop.makeSucceededFuture(())
            var datagrams = 0
            while written <= lotsOfData {
                firstChannel!.write(envelope, promise: myPromise)
                overall = EventLoopFuture.andAllSucceed(
                    [overall, myPromise.futureResult],
                    on: firstChannel!.eventLoop
                )
                written += Int64(bufferSize)
                datagrams += 1
            }
            return overall
        }.wait()
        self.firstChannel.flush()

        XCTAssertNoThrow(try overall.wait())
    }

    func testLargeWritesFail() throws {
        // We want to try to trigger EMSGSIZE. To be safe, we're going to allocate a 10MB buffer here and fill it.
        let bufferSize = 1024 * 1024 * 10
        var buffer = self.firstChannel.allocator.buffer(capacity: bufferSize)
        buffer.writeRepeatingByte(4, count: bufferSize)
        let envelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        let writeFut = self.firstChannel.write(envelope)
        self.firstChannel.flush()

        XCTAssertThrowsError(try writeFut.wait()) { error in
            XCTAssertEqual(.writeMessageTooLarge, error as? ChannelError)
        }
    }

    func testOneLargeWriteDoesntPreventOthersWriting() throws {
        // We want to try to trigger EMSGSIZE. To be safe, we're going to allocate a 10MB buffer here and fill it.
        let bufferSize = 1024 * 1024 * 10
        var buffer = self.firstChannel.allocator.buffer(capacity: bufferSize)
        buffer.writeRepeatingByte(4, count: bufferSize)

        // Now we want two envelopes. The first is small, the second is large.
        let firstEnvelope = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer.getSlice(at: buffer.readerIndex, length: 100)!
        )
        let secondEnvelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        // Now, three writes. We're sandwiching the big write between two small ones.
        let firstWrite = self.firstChannel.write(firstEnvelope)
        let secondWrite = self.firstChannel.write(secondEnvelope)
        let thirdWrite = self.firstChannel.writeAndFlush(firstEnvelope)

        // The first and third writes should be fine.
        XCTAssertNoThrow(try firstWrite.wait())
        XCTAssertNoThrow(try thirdWrite.wait())

        // The second should have failed.
        XCTAssertThrowsError(try secondWrite.wait()) { error in
            XCTAssertEqual(.writeMessageTooLarge, error as? ChannelError)
        }
    }

    func testClosingBeforeFlushFailsAllWrites() throws {
        // We want to try to trigger EMSGSIZE. To be safe, we're going to allocate a 10MB buffer here and fill it.
        let bufferSize = 1024 * 1024 * 10
        var buffer = self.firstChannel.allocator.buffer(capacity: bufferSize)
        buffer.writeRepeatingByte(4, count: bufferSize)

        // Now we want two envelopes. The first is small, the second is large.
        let firstEnvelope = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer.getSlice(at: buffer.readerIndex, length: 100)!
        )
        let secondEnvelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        // Now, three writes. We're sandwiching the big write between two small ones.
        let firstWrite = self.firstChannel.write(firstEnvelope)
        let secondWrite = self.firstChannel.write(secondEnvelope)
        let thirdWrite = self.firstChannel.writeAndFlush(firstEnvelope)

        // The first and third writes should be fine.
        XCTAssertNoThrow(try firstWrite.wait())
        XCTAssertNoThrow(try thirdWrite.wait())

        // The second should have failed.
        XCTAssertThrowsError(try secondWrite.wait()) { error in
            XCTAssertEqual(.writeMessageTooLarge, error as? ChannelError)
        }
    }

    public func testRecvMsgFailsWithECONNREFUSED() throws {
        try assertRecvMsgFails(error: ECONNREFUSED, active: true)
    }

    public func testRecvMsgFailsWithENOMEM() throws {
        try assertRecvMsgFails(error: ENOMEM, active: true)
    }

    public func testRecvMsgFailsWithEFAULT() throws {
        try assertRecvMsgFails(error: EFAULT, active: false)
    }

    private func assertRecvMsgFails(error: Int32, active: Bool) throws {
        final class RecvFromHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = AddressedEnvelope<ByteBuffer>
            typealias InboundOut = AddressedEnvelope<ByteBuffer>

            private let promise: EventLoopPromise<IOError>

            init(_ promise: EventLoopPromise<IOError>) {
                self.promise = promise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Should not receive data but got \(Self.unwrapInboundIn(data))")
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                if let ioError = error as? IOError {
                    self.promise.succeed(ioError)
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        class NonRecvFromSocket: Socket {
            private var error: Int32?

            init(error: Int32) throws {
                self.error = error
                try super.init(protocolFamily: .inet, type: .datagram, protocolSubtype: .default)
            }

            override func recvmsg(
                pointer: UnsafeMutableRawBufferPointer,
                storage: inout sockaddr_storage,
                storageLen: inout socklen_t,
                controlBytes: inout UnsafeReceivedControlBytes
            )
                throws -> IOResult<(Int)>
            {
                if let err = self.error {
                    self.error = nil
                    throw IOError(errnoCode: err, reason: "recvfrom")
                }
                return IOResult.wouldBlock(0)
            }
        }
        let socket = try NonRecvFromSocket(error: error)
        let channel = try DatagramChannel(socket: socket, eventLoop: group.next() as! SelectableEventLoop)
        let promise = channel.eventLoop.makePromise(of: IOError.self)
        XCTAssertNoThrow(try channel.register().wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(RecvFromHandler(promise)).wait())
        XCTAssertNoThrow(try channel.bind(to: SocketAddress.init(ipAddress: "127.0.0.1", port: 0)).wait())

        XCTAssertEqual(
            active,
            try channel.eventLoop.submit {
                channel.readable()
                return channel.isActive
            }.wait()
        )

        if active {
            XCTAssertNoThrow(try channel.close().wait())
        }
        let ioError = try promise.futureResult.wait()
        XCTAssertEqual(error, ioError.errnoCode)
    }

    public func testRecvMmsgFailsWithECONNREFUSED() throws {
        try assertRecvMmsgFails(error: ECONNREFUSED, active: true)
    }

    public func testRecvMmsgFailsWithENOMEM() throws {
        try assertRecvMmsgFails(error: ENOMEM, active: true)
    }

    public func testRecvMmsgFailsWithEFAULT() throws {
        try assertRecvMmsgFails(error: EFAULT, active: false)
    }

    private func assertRecvMmsgFails(error: Int32, active: Bool) throws {
        // Only run this test on platforms that support recvmmsg: the others won't even
        // try.
        #if os(Linux) || os(FreeBSD) || os(Android)
        final class RecvMmsgHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = AddressedEnvelope<ByteBuffer>
            typealias InboundOut = AddressedEnvelope<ByteBuffer>

            private let promise: EventLoopPromise<IOError>

            init(_ promise: EventLoopPromise<IOError>) {
                self.promise = promise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Should not receive data but got \(Self.unwrapInboundIn(data))")
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                if let ioError = error as? IOError {
                    self.promise.succeed(ioError)
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        class NonRecvMmsgSocket: Socket {
            private var error: Int32?

            init(error: Int32) throws {
                self.error = error
                try super.init(protocolFamily: .inet, type: .datagram)
            }

            override func recvmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
                if let err = self.error {
                    self.error = nil
                    throw IOError(errnoCode: err, reason: "recvfrom")
                }
                return IOResult.wouldBlock(0)
            }
        }
        let socket = try NonRecvMmsgSocket(error: error)
        let channel = try DatagramChannel(socket: socket, eventLoop: group.next() as! SelectableEventLoop)
        let promise = channel.eventLoop.makePromise(of: IOError.self)
        XCTAssertNoThrow(try channel.register().wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(RecvMmsgHandler(promise)).wait())
        XCTAssertNoThrow(try channel.configureForRecvMmsg(messageCount: 10))
        XCTAssertNoThrow(try channel.bind(to: SocketAddress.init(ipAddress: "127.0.0.1", port: 0)).wait())

        XCTAssertEqual(
            active,
            try channel.eventLoop.submit {
                channel.readable()
                return channel.isActive
            }.wait()
        )

        if active {
            XCTAssertNoThrow(try channel.close().wait())
        }
        let ioError = try promise.futureResult.wait()
        XCTAssertEqual(error, ioError.errnoCode)
        #endif
    }

    public func testSetGetOptionClosedDatagramChannel() throws {
        try assertSetGetOptionOnOpenAndClosed(
            channel: firstChannel,
            option: .maxMessagesPerRead,
            value: 1
        )
    }

    func testWritesAreAccountedCorrectly() throws {
        var buffer = firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")
        let firstWrite = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer.getSlice(at: buffer.readerIndex, length: 5)!
        )
        let secondWrite = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        self.firstChannel.write(firstWrite, promise: nil)
        self.firstChannel.write(secondWrite, promise: nil)
        self.firstChannel.flush()

        let reads = try self.secondChannel.waitForDatagrams(count: 2)

        // These datagrams should not have been dropped by the kernel.
        XCTAssertEqual(reads.count, 2)

        XCTAssertEqual(reads[0].data, buffer.getSlice(at: buffer.readerIndex, length: 5)!)
        XCTAssertEqual(reads[0].remoteAddress, self.firstChannel.localAddress!)
        XCTAssertEqual(reads[1].data, buffer)
        XCTAssertEqual(reads[1].remoteAddress, self.firstChannel.localAddress!)
    }

    func testSettingTwoDistinctChannelOptionsWorksForDatagramChannel() throws {
        let channel = try assertNoThrowWithValue(
            DatagramBootstrap(group: group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelOption(.socketOption(.so_timestamp), value: 1)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try channel.close().wait())
        }
        XCTAssertTrue(try getBoolSocketOption(channel: channel, level: .socket, name: .so_reuseaddr))
        XCTAssertTrue(try getBoolSocketOption(channel: channel, level: .socket, name: .so_timestamp))
        XCTAssertFalse(try getBoolSocketOption(channel: channel, level: .socket, name: .so_keepalive))
    }

    func testUnprocessedOutboundUserEventFailsOnDatagramChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let channel = try DatagramChannel(
            eventLoop: group.next() as! SelectableEventLoop,
            protocolFamily: .inet,
            protocolSubtype: .default
        )
        XCTAssertThrowsError(try channel.triggerUserOutboundEvent("event").wait()) { (error: Error) in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.operationUnsupported, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBasicMultipleReads() throws {
        XCTAssertNoThrow(try self.secondChannel.configureForRecvMmsg(messageCount: 10))

        // This test should exercise recvmmsg.
        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        // We write this in three times.
        self.firstChannel.write(writeData, promise: nil)
        self.firstChannel.write(writeData, promise: nil)
        self.firstChannel.write(writeData, promise: nil)
        self.firstChannel.flush()

        let reads = try self.secondChannel.waitForDatagrams(count: 3)
        XCTAssertEqual(reads.count, 3)

        for (idx, read) in reads.enumerated() {
            XCTAssertEqual(read.data, buffer, "index: \(idx)")
            XCTAssertEqual(read.remoteAddress, self.firstChannel.localAddress!, "index: \(idx)")
        }
    }

    func testMmsgWillTruncateWithoutChangeToAllocator() throws {
        // This test validates that setting a small allocator will lead to datagram truncation.
        // Right now we don't error on truncation, so this test looks for short receives.
        // Setting the recv allocator to 30 bytes forces 3 bytes per message.
        // Sadly, this test only truncates for the platforms with recvmmsg support: the rest don't truncate as 30 bytes is sufficient.
        XCTAssertNoThrow(try self.secondChannel.configureForRecvMmsg(messageCount: 10))
        XCTAssertNoThrow(
            try self.secondChannel.setOption(
                .recvAllocator,
                value: FixedSizeRecvByteBufferAllocator(capacity: 30)
            ).wait()
        )

        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        // We write this in three times.
        self.firstChannel.write(writeData, promise: nil)
        self.firstChannel.write(writeData, promise: nil)
        self.firstChannel.write(writeData, promise: nil)
        self.firstChannel.flush()

        let reads = try self.secondChannel.waitForDatagrams(count: 3)
        XCTAssertEqual(reads.count, 3)

        for (idx, read) in reads.enumerated() {
            #if os(Linux) || os(FreeBSD) || os(Android)
            XCTAssertEqual(read.data.readableBytes, 3, "index: \(idx)")
            #else
            XCTAssertEqual(read.data.readableBytes, 13, "index: \(idx)")
            #endif
            XCTAssertEqual(read.remoteAddress, self.firstChannel.localAddress!, "index: \(idx)")
        }
    }

    func testRecvMmsgForMultipleCycles() throws {
        // The goal of this test is to provide more datagrams than can be received in a single invocation of
        // recvmmsg, and to confirm that they all make it through.
        // This test is allowed to run on systems without recvmmsg: it just exercises the serial read path.
        XCTAssertNoThrow(try self.secondChannel.configureForRecvMmsg(messageCount: 10))

        // We now turn off autoread.
        XCTAssertNoThrow(try self.secondChannel.setOption(.autoRead, value: false).wait())
        XCTAssertNoThrow(try self.secondChannel.setOption(.maxMessagesPerRead, value: 3).wait())

        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("data")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        // Ok, now we're good. Let's queue up a bunch of datagrams. We've configured to receive 10 at a time, so we'll send 30.
        for _ in 0..<29 {
            self.firstChannel.write(writeData, promise: nil)
        }
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(writeData).wait())

        // Now we read. Rather than issue many read() calls, we'll turn autoread back on.
        XCTAssertNoThrow(try self.secondChannel.setOption(.autoRead, value: true).wait())

        // Wait for all 30 datagrams to come through. There should be no loss here, as this is small datagrams on loopback.
        let reads = try self.secondChannel.waitForDatagrams(count: 30)
        XCTAssertEqual(reads.count, 30)

        // Now we want to count the number of readCompletes. On any platform without recvmmsg, we should have seen 10 or more
        // (as max messages per read is 3). On platforms with recvmmsg, we would expect to see
        // substantially fewer than 10, and potentially as low as 1.
        #if os(Linux) || os(FreeBSD) || os(Android)
        XCTAssertLessThan(try assertNoThrowWithValue(self.secondChannel.readCompleteCount()), 10)
        XCTAssertGreaterThanOrEqual(try assertNoThrowWithValue(self.secondChannel.readCompleteCount()), 1)
        #else
        XCTAssertGreaterThanOrEqual(try assertNoThrowWithValue(self.secondChannel.readCompleteCount()), 10)
        #endif
    }

    // Mostly to check the types don't go pop as internally converts between bool and int and back.
    func testSetGetEcnNotificationOption() {
        XCTAssertNoThrow(
            try {
                // IPv4
                try self.firstChannel.setOption(.explicitCongestionNotification, value: true).wait()
                XCTAssertTrue(try self.firstChannel.getOption(.explicitCongestionNotification).wait())

                try self.secondChannel.setOption(.explicitCongestionNotification, value: false).wait()
                XCTAssertFalse(try self.secondChannel.getOption(.explicitCongestionNotification).wait())

                // IPv6
                guard self.supportsIPv6 else {
                    // Skip on non-IPv6 systems
                    return
                }

                do {
                    let channel1 = try buildChannel(group: self.group, host: "::1")
                    try channel1.setOption(.explicitCongestionNotification, value: true).wait()
                    XCTAssertTrue(try channel1.getOption(.explicitCongestionNotification).wait())

                    let channel2 = try buildChannel(group: self.group, host: "::1")
                    try channel2.setOption(.explicitCongestionNotification, value: false).wait()
                    XCTAssertFalse(try channel2.getOption(.explicitCongestionNotification).wait())
                } catch let error as SocketAddressError {
                    switch error {
                    case .unknown:
                        // IPv6 resolution can fail even if supported.
                        return
                    case .unsupported, .unixDomainSocketPathTooLong, .failedToParseIPString:
                        throw error
                    }
                }
            }()
        )
    }

    private func testEcnAndPacketInfoReceive(
        address: String,
        vectorRead: Bool,
        vectorSend: Bool,
        receivePacketInfo: Bool = false
    ) {
        XCTAssertNoThrow(
            try {
                // Fake sending packet to self on the loopback interface if requested
                let expectedPacketInfo = receivePacketInfo ? try constructNIOPacketInfo(address: address) : nil
                let receiveBootstrap: DatagramBootstrap
                if vectorRead {
                    receiveBootstrap = DatagramBootstrap(group: group)
                        .channelOption(.datagramVectorReadMessageCount, value: 4)
                } else {
                    receiveBootstrap = DatagramBootstrap(group: group)
                }

                let receiveChannel =
                    try receiveBootstrap
                    .channelOption(.explicitCongestionNotification, value: true)
                    .channelOption(.receivePacketInfo, value: receivePacketInfo)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                DatagramReadRecorder<ByteBuffer>(),
                                name: "ByteReadRecorder"
                            )
                        }
                    }
                    .bind(host: address, port: 0)
                    .wait()
                defer {
                    XCTAssertNoThrow(try receiveChannel.close().wait())
                }
                let sendChannel = try DatagramBootstrap(group: group)
                    .bind(host: address, port: 0)
                    .wait()
                defer {
                    XCTAssertNoThrow(try sendChannel.close().wait())
                }

                let ecnStates: [NIOExplicitCongestionNotificationState] = [
                    .transportNotCapable,
                    .congestionExperienced,
                    .transportCapableFlag0,
                    .transportCapableFlag1,
                ]
                // Datagrams may be received out-of-order, so we use a sequential integer in the payload.
                let metadataWrites: [(Int, AddressedEnvelope<ByteBuffer>.Metadata?)] = try ecnStates.enumerated()
                    .reduce(into: []) { metadataWrites, ecnState in
                        let writeData = AddressedEnvelope(
                            remoteAddress: receiveChannel.localAddress!,
                            data: sendChannel.allocator.buffer(integer: ecnState.offset),
                            metadata: .init(ecnState: ecnState.element, packetInfo: expectedPacketInfo)
                        )
                        // Sending extra data without flushing should trigger a vector send.
                        if vectorSend {
                            sendChannel.write(writeData, promise: nil)
                            metadataWrites.append((ecnState.offset, writeData.metadata))
                        }
                        try sendChannel.writeAndFlush(writeData).wait()
                        metadataWrites.append((ecnState.offset, writeData.metadata))
                    }

                let expectedNumReads = metadataWrites.count
                let metadataReads = try receiveChannel.waitForDatagrams(count: expectedNumReads).map {
                    ($0.data.getInteger(at: $0.data.readerIndex, as: Int.self)!, $0.metadata)
                }

                // Datagrams may be received out-of-order, so we order reads and writes by payload.
                XCTAssertEqual(
                    metadataReads.sorted { $0.0 < $1.0 }.map { $0.1 },
                    metadataWrites.sorted { $0.0 < $1.0 }.map { $0.1 }
                )
            }()
        )
    }

    private func constructNIOPacketInfo(address: String) throws -> NIOPacketInfo {
        struct InterfaceIndexNotFound: Error {}
        let destinationAddress = try SocketAddress(ipAddress: address, port: 0)
        guard
            let ingressIfaceIndex = try System.enumerateDevices()
                .first(where: { $0.address == destinationAddress })?.interfaceIndex
        else {
            throw InterfaceIndexNotFound()
        }
        return NIOPacketInfo(destinationAddress: destinationAddress, interfaceIndex: ingressIfaceIndex)
    }

    func testEcnSendReceiveIPV4() {
        testEcnAndPacketInfoReceive(address: "127.0.0.1", vectorRead: false, vectorSend: false)
    }

    func testEcnSendReceiveIPV6() {
        guard System.supportsIPv6 else {
            return  // need to skip IPv6 tests if we don't support it.
        }
        testEcnAndPacketInfoReceive(address: "::1", vectorRead: false, vectorSend: false)
    }

    func testEcnSendReceiveIPV4VectorRead() {
        testEcnAndPacketInfoReceive(address: "127.0.0.1", vectorRead: true, vectorSend: false)
    }

    func testEcnSendReceiveIPV6VectorRead() {
        guard System.supportsIPv6 else {
            return  // need to skip IPv6 tests if we don't support it.
        }
        testEcnAndPacketInfoReceive(address: "::1", vectorRead: true, vectorSend: false)
    }

    func testEcnSendReceiveIPV4VectorReadVectorWrite() {
        testEcnAndPacketInfoReceive(address: "127.0.0.1", vectorRead: true, vectorSend: true)
    }

    func testEcnSendReceiveIPV6VectorReadVectorWrite() {
        guard System.supportsIPv6 else {
            return  // need to skip IPv6 tests if we don't support it.
        }
        testEcnAndPacketInfoReceive(address: "::1", vectorRead: true, vectorSend: true)
    }

    func testWritabilityChangeDuringReentrantFlushNow() throws {
        final class EnvelopingHandler: ChannelOutboundHandler, Sendable {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = AddressedEnvelope<ByteBuffer>

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let buffer = Self.unwrapOutboundIn(data)
                context.write(
                    Self.wrapOutboundOut(AddressedEnvelope(remoteAddress: context.channel.localAddress!, data: buffer)),
                    promise: promise
                )
            }
        }

        let loop = self.group.next()
        let becameUnwritable = loop.makePromise(of: Void.self)
        let becameWritable = loop.makePromise(of: Void.self)

        let channel1Future = DatagramBootstrap(group: self.group)
            .bind(host: "localhost", port: 0)
        let channel1 = try assertNoThrowWithValue(try channel1Future.wait())
        defer {
            XCTAssertNoThrow(try channel1.close().wait())
        }

        let channel2Future = DatagramBootstrap(group: self.group)
            .channelOption(.writeBufferWaterMark, value: ReentrantWritabilityChangingHandler.watermark)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = ReentrantWritabilityChangingHandler(
                        becameUnwritable: becameUnwritable,
                        becameWritable: becameWritable
                    )
                    try channel.pipeline.syncOperations.addHandlers([EnvelopingHandler(), handler])
                }
            }
            .bind(host: "localhost", port: 0)
        let channel2 = try assertNoThrowWithValue(try channel2Future.wait())
        defer {
            XCTAssertNoThrow(try channel2.close().wait())
        }

        // Now wait.
        XCTAssertNoThrow(try becameUnwritable.futureResult.wait())
        XCTAssertNoThrow(try becameWritable.futureResult.wait())
    }

    func testSetGetPktInfoOption() {
        XCTAssertNoThrow(
            try {
                // IPv4
                try self.firstChannel.setOption(.receivePacketInfo, value: true).wait()
                XCTAssertTrue(try self.firstChannel.getOption(.receivePacketInfo).wait())

                try self.secondChannel.setOption(.receivePacketInfo, value: false).wait()
                XCTAssertFalse(try self.secondChannel.getOption(.receivePacketInfo).wait())

                // IPv6
                guard self.supportsIPv6 else {
                    // Skip on non-IPv6 systems
                    return
                }

                do {
                    let channel1 = try buildChannel(group: self.group, host: "::1")
                    try channel1.setOption(.receivePacketInfo, value: true).wait()
                    XCTAssertTrue(try channel1.getOption(.receivePacketInfo).wait())

                    let channel2 = try buildChannel(group: self.group, host: "::1")
                    try channel2.setOption(.receivePacketInfo, value: false).wait()
                    XCTAssertFalse(try channel2.getOption(.receivePacketInfo).wait())
                } catch let error as SocketAddressError {
                    switch error {
                    case .unknown:
                        // IPv6 resolution can fail even if supported.
                        return
                    case .unsupported, .unixDomainSocketPathTooLong, .failedToParseIPString:
                        throw error
                    }
                }
            }()
        )
    }

    private func testSimpleReceivePacketInfo(address: String) throws {
        // Fake sending packet to self on the loopback interface
        let expectedPacketInfo = try constructNIOPacketInfo(address: address)

        let receiveChannel = try DatagramBootstrap(group: group)
            .channelOption(.receivePacketInfo, value: true)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DatagramReadRecorder<ByteBuffer>(),
                        name: "ByteReadRecorder"
                    )
                }
            }
            .bind(host: address, port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try receiveChannel.close().wait())
        }
        let sendChannel = try DatagramBootstrap(group: group)
            .bind(host: address, port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try sendChannel.close().wait())
        }

        var buffer = sendChannel.allocator.buffer(capacity: 1)
        buffer.writeRepeatingByte(0, count: 1)

        let writeData = AddressedEnvelope(
            remoteAddress: receiveChannel.localAddress!,
            data: buffer,
            metadata: .init(
                ecnState: .transportNotCapable,
                packetInfo: expectedPacketInfo
            )
        )
        try sendChannel.writeAndFlush(writeData).wait()

        let expectedReads = 1
        let reads = try receiveChannel.waitForDatagrams(count: 1)
        XCTAssertEqual(reads.count, expectedReads)
        XCTAssertEqual(reads[0].metadata?.packetInfo, expectedPacketInfo)
    }

    func testSimpleReceivePacketInfoIPV4() throws {
        try testSimpleReceivePacketInfo(address: "127.0.0.1")
    }

    func testSimpleReceivePacketInfoIPV6() throws {
        guard System.supportsIPv6 else {
            return  // need to skip IPv6 tests if we don't support it.
        }
        try testSimpleReceivePacketInfo(address: "::1")
    }

    func testReceiveEcnAndPacketInfoIPV4() {
        testEcnAndPacketInfoReceive(address: "127.0.0.1", vectorRead: false, vectorSend: false, receivePacketInfo: true)
    }

    func testReceiveEcnAndPacketInfoIPV6() {
        guard System.supportsIPv6 else {
            return  // need to skip IPv6 tests if we don't support it.
        }
        testEcnAndPacketInfoReceive(address: "::1", vectorRead: false, vectorSend: false, receivePacketInfo: true)
    }

    func testReceiveEcnAndPacketInfoIPV4VectorRead() {
        testEcnAndPacketInfoReceive(address: "127.0.0.1", vectorRead: true, vectorSend: false, receivePacketInfo: true)
    }

    func testReceiveEcnAndPacketInfoIPV6VectorRead() {
        guard System.supportsIPv6 else {
            return  // need to skip IPv6 tests if we don't support it.
        }
        testEcnAndPacketInfoReceive(address: "::1", vectorRead: true, vectorSend: false, receivePacketInfo: true)
    }

    func testReceiveEcnAndPacketInfoIPV4VectorReadVectorWrite() {
        testEcnAndPacketInfoReceive(address: "127.0.0.1", vectorRead: true, vectorSend: true, receivePacketInfo: true)
    }

    func testReceiveEcnAndPacketInfoIPV6VectorReadVectorWrite() {
        guard System.supportsIPv6 else {
            return  // need to skip IPv6 tests if we don't support it.
        }
        testEcnAndPacketInfoReceive(address: "::1", vectorRead: true, vectorSend: true, receivePacketInfo: true)
    }

    func testDoingICMPWithoutRoot() throws {
        // This test validates we can send ICMP messages on a datagram socket without having root privilege.
        //
        // This doesn't always work: ability to do this on Linux is gated behind a sysctl (net.ipv4.ping_group_range)
        // which may exclude us. So we have to tolerate this throwing EPERM as well.

        final class EchoRequestHandler: ChannelInboundHandler {
            typealias InboundIn = AddressedEnvelope<ByteBuffer>
            typealias OutboundOut = AddressedEnvelope<ByteBuffer>

            let completePromise: EventLoopPromise<ByteBuffer>

            init(completePromise: EventLoopPromise<ByteBuffer>) {
                self.completePromise = completePromise
            }

            func channelActive(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: 32)

                // We're going to write an ICMP echo packet from scratch, like heroes.
                // Echo request is type 8, code 0.
                // The checksum is tricky: on Linux, the kernel doesn't care what we set, it'll
                // calculate it. On macOS, however, we have to calculate it. For both platforms, then,
                // we calculate it.
                // Identifier is irrelevant.
                // Sequence number does matter, but we'll set to 0.
                let type = UInt8(8)
                let code = UInt8(0)
                let fakeChecksum = UInt16(0)
                let identifier = UInt16(0)
                let sequenceNumber = UInt16(0)
                buffer.writeMultipleIntegers(type, code, fakeChecksum, identifier, sequenceNumber)

                // Then we write a payload, which will be "hello from NIO".
                buffer.writeString("Hello from NIO")

                // Now calculate the checksum, and store it back at offset 2.
                let checksum = buffer.readableBytesView.computeIPChecksum()
                buffer.setInteger(checksum, at: 2)

                // Now wrap it into an addressed envelope pointed at localhost.
                let envelope = AddressedEnvelope(
                    remoteAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0),
                    data: buffer
                )

                context.writeAndFlush(Self.wrapOutboundOut(envelope)).cascadeFailure(to: self.completePromise)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let envelope = Self.unwrapInboundIn(data)

                // Complete with the payload.
                self.completePromise.succeed(envelope.data)
            }
        }

        let loop = self.group.next()
        let completePromise = loop.makePromise(of: ByteBuffer.self)
        do {
            let channel = try DatagramBootstrap(group: group)
                .protocolSubtype(.init(.icmp))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            EchoRequestHandler(completePromise: completePromise)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
            defer {
                XCTAssertNoThrow(try channel.close().wait())
            }

            // Let's try to send an ICMP echo request and get a response.
            var response = try completePromise.futureResult.wait()

            #if canImport(Darwin)
            // Again, a platform difference. On Darwin, this returns a complete IP packet. On Linux, it does not.
            // We assume the Linux platform is the more general approach, but if this test fails on your platform
            // it is _probably_ because it behaves differently. To make this general, we can skip the IPv4 header.
            //
            // To do that, we have to work out how long that header is. That's held in bottom 4 bits of the first
            // byte, which is the IHL field. This is in "number of 32-bit words".
            guard let firstByte = response.getInteger(at: response.readerIndex, as: UInt8.self),
                let _ = response.readSlice(length: Int(firstByte & 0x0F) * 4)
            else {
                XCTFail("Insufficient bytes for IPv4 header")
                return
            }
            #endif

            // Now we've got the ICMP packet. Let's parse this.
            guard let header = response.readMultipleIntegers(as: (UInt8, UInt8, UInt16, UInt16, UInt16).self) else {
                XCTFail("Insufficient bytes for ICMP header")
                return
            }

            // Echo response has type 0, code 0, unpredictable checksum and identifier, same sequence number we sent.
            // type
            XCTAssertEqual(header.0, 0)
            // code
            XCTAssertEqual(header.1, 0)
            // sequence number
            XCTAssertEqual(header.4, 0)

            // Remaining payload should have been our string.
            XCTAssertEqual(String(buffer: response), "Hello from NIO")
        } catch let error as IOError {
            // Firstly, fail this promise in case it leaks.
            completePromise.fail(error)
            if error.errnoCode == EACCES {
                // Acceptable
                return
            }
            XCTFail("Unexpected IOError: \(error)")
        }
    }

    func assertSending(
        data: ByteBuffer,
        from sourceChannel: Channel,
        to destinationChannel: Channel,
        wrappingInAddressedEnvelope shouldWrapInAddressedEnvelope: Bool,
        resultsIn expectedResult: Result<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Wrap data in AddressedEnvelope if required.
        let writeResult: EventLoopFuture<Void>
        if shouldWrapInAddressedEnvelope {
            let envelope = AddressedEnvelope(remoteAddress: destinationChannel.localAddress!, data: data)
            writeResult = sourceChannel.writeAndFlush(envelope)
        } else {
            writeResult = sourceChannel.writeAndFlush(data)
        }

        // Check the expected result.
        switch expectedResult {
        case .success:
            // Check the write succeeded.
            XCTAssertNoThrow(try writeResult.wait())

            // Check the destination received the sent payload.
            let reads = try destinationChannel.waitForDatagrams(count: 1)
            XCTAssertEqual(reads.count, 1)
            let read = reads.first!
            XCTAssertEqual(read.data, data)
            XCTAssertEqual(read.remoteAddress, sourceChannel.localAddress!)

        case .failure(let expectedError):
            // Check the error is of the expected type.
            XCTAssertThrowsError(try writeResult.wait()) { error in
                guard type(of: error) == type(of: expectedError) else {
                    XCTFail(
                        "expected error of type \(type(of: expectedError)), but caught other error of type (\(type(of: error)): \(error)"
                    )
                    return
                }
            }
        }
    }

    func assertSendingHelloWorld(
        from sourceChannel: Channel,
        to destinationChannel: Channel,
        wrappingInAddressedEnvelope shouldWrapInAddressedEnvelope: Bool,
        resultsIn expectedResult: Result<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try self.assertSending(
            data: sourceChannel.allocator.buffer(staticString: "hello, world!"),
            from: sourceChannel,
            to: destinationChannel,
            wrappingInAddressedEnvelope: shouldWrapInAddressedEnvelope,
            resultsIn: expectedResult,
            file: file,
            line: line
        )
    }

    func bufferWrite(
        of data: ByteBuffer,
        from sourceChannel: Channel,
        to destinationChannel: Channel,
        wrappingInAddressedEnvelope shouldWrapInAddressedEnvelope: Bool
    ) -> EventLoopFuture<Void> {
        if shouldWrapInAddressedEnvelope {
            let envelope = AddressedEnvelope(remoteAddress: destinationChannel.localAddress!, data: data)
            return sourceChannel.write(envelope)
        } else {
            return sourceChannel.write(data)
        }
    }

    func bufferWriteOfHelloWorld(
        from sourceChannel: Channel,
        to destinationChannel: Channel,
        wrappingInAddressedEnvelope shouldWrapInAddressedEnvelope: Bool
    ) -> EventLoopFuture<Void> {
        self.bufferWrite(
            of: sourceChannel.allocator.buffer(staticString: "hello, world!"),
            from: sourceChannel,
            to: destinationChannel,
            wrappingInAddressedEnvelope: shouldWrapInAddressedEnvelope
        )
    }

    func testSendingAddressedEnvelopeOnUnconnectedSocketSucceeds() throws {
        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.secondChannel,
            wrappingInAddressedEnvelope: true,
            resultsIn: .success(())
        )
    }

    func testSendingByteBufferOnUnconnectedSocketFails() throws {
        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.secondChannel,
            wrappingInAddressedEnvelope: false,
            resultsIn: .failure(DatagramChannelError.WriteOnUnconnectedSocketWithoutAddress())
        )
    }

    func testSendingByteBufferOnConnectedSocketSucceeds() throws {
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.secondChannel.localAddress!).wait())

        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.secondChannel,
            wrappingInAddressedEnvelope: false,
            resultsIn: .success(())
        )
    }

    func testSendingAddressedEnvelopeOnConnectedSocketSucceeds() throws {
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.secondChannel.localAddress!).wait())

        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.secondChannel,
            wrappingInAddressedEnvelope: true,
            resultsIn: .success(())
        )
    }

    func testSendingAddressedEnvelopeOnConnectedSocketWithDifferentAddressFails() throws {
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.secondChannel.localAddress!).wait())

        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.thirdChannel,
            wrappingInAddressedEnvelope: true,
            resultsIn: .failure(
                DatagramChannelError.WriteOnConnectedSocketWithInvalidAddress(
                    envelopeRemoteAddress: self.thirdChannel.localAddress!,
                    connectedRemoteAddress: self.secondChannel.localAddress!
                )
            )
        )
    }

    func testConnectingSocketAfterFlushingExistingMessages() throws {
        // Send message from firstChannel to secondChannel.
        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.secondChannel,
            wrappingInAddressedEnvelope: true,
            resultsIn: .success(())
        )

        // Connect firstChannel to thirdChannel.
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.thirdChannel.localAddress!).wait())

        // Send message from firstChannel to thirdChannel.
        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.thirdChannel,
            wrappingInAddressedEnvelope: false,
            resultsIn: .success(())
        )
    }

    func testConnectingSocketFailsBufferedWrites() throws {
        // Buffer message from firstChannel to secondChannel.
        let bufferedWrite = bufferWriteOfHelloWorld(
            from: self.firstChannel,
            to: self.secondChannel,
            wrappingInAddressedEnvelope: true
        )

        // Connect firstChannel to thirdChannel.
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.thirdChannel.localAddress!).wait())

        // Check that the buffered write was failed.
        XCTAssertThrowsError(try bufferedWrite.wait()) { error in
            XCTAssertEqual(
                (error as? IOError)?.errnoCode,
                EISCONN,
                "expected EISCONN, but caught other error: \(error)"
            )
        }

        // Send message from firstChannel to thirdChannel.
        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.thirdChannel,
            wrappingInAddressedEnvelope: false,
            resultsIn: .success(())
        )
    }

    func testReconnectingSocketFailsBufferedWrites() throws {
        // Connect firstChannel to secondChannel.
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.secondChannel.localAddress!).wait())

        // Buffer message from firstChannel to secondChannel.
        let bufferedWrite = bufferWriteOfHelloWorld(
            from: self.firstChannel,
            to: self.secondChannel,
            wrappingInAddressedEnvelope: false
        )

        // Connect firstChannel to thirdChannel.
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.thirdChannel.localAddress!).wait())

        // Check that the buffered write was failed.
        XCTAssertThrowsError(try bufferedWrite.wait()) { error in
            XCTAssertEqual(
                (error as? IOError)?.errnoCode,
                EISCONN,
                "expected EISCONN, but caught other error: \(error)"
            )
        }

        // Send message from firstChannel to thirdChannel.
        try self.assertSendingHelloWorld(
            from: self.firstChannel,
            to: self.thirdChannel,
            wrappingInAddressedEnvelope: false,
            resultsIn: .success(())
        )
    }

    func testGSOIsUnsupportedOnNonLinuxPlatforms() throws {
        #if !os(Linux)
        XCTAssertFalse(System.supportsUDPSegmentationOffload)
        #endif
    }

    func testSetGSOOption() throws {
        let didSet = self.firstChannel.setOption(.datagramSegmentSize, value: 1024)
        if System.supportsUDPSegmentationOffload {
            XCTAssertNoThrow(try didSet.wait())
        } else {
            XCTAssertThrowsError(try didSet.wait()) { error in
                XCTAssertEqual(error as? ChannelError, .operationUnsupported)
            }
        }
    }

    func testGetGSOOption() throws {
        let getOption = self.firstChannel.getOption(.datagramSegmentSize)
        if System.supportsUDPSegmentationOffload {
            XCTAssertEqual(try getOption.wait(), 0)  // not-set
        } else {
            XCTAssertThrowsError(try getOption.wait()) { error in
                XCTAssertEqual(error as? ChannelError, .operationUnsupported)
            }
        }
    }

    func testLargeScalarWriteWithGSO() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        // We're going to enable GSO with a segment size of 1000, send one large buffer which
        // contains ten 1000-byte segments. Each segment will contain the bytes corresponding to
        // the index of the segment. We validate that the receiver receives 10 datagrams, each
        // corresponding to one segment from the buffer.
        let segmentSize: CInt = 1000
        let segments = 10

        // Enable GSO
        let didSet = self.firstChannel.setOption(.datagramSegmentSize, value: segmentSize)
        XCTAssertNoThrow(try didSet.wait())

        // Form a handful of segments
        let buffers = (0..<segments).map { i in
            ByteBuffer(repeating: UInt8(i), count: Int(segmentSize))
        }

        // Coalesce the segments into a single buffer.
        var buffer = self.firstChannel.allocator.buffer(capacity: segments * Int(segmentSize))
        for segment in buffers {
            buffer.writeImmutableBuffer(segment)
        }

        for byte in UInt8(0)..<UInt8(10) {
            buffer.writeRepeatingByte(byte, count: Int(segmentSize))
        }

        // Write the single large buffer.
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(writeData).wait())

        // The receiver will receive separate segments.
        let receivedBuffers = try self.secondChannel.waitForDatagrams(count: segments)
        let receivedBytes = receivedBuffers.map { $0.data.readableBytes }.reduce(0, +)
        XCTAssertEqual(Int(segmentSize) * segments, receivedBytes)

        var unusedIndexes = Set(buffers.indices)
        for envelope in receivedBuffers {
            if let index = buffers.firstIndex(of: envelope.data) {
                XCTAssertNotNil(unusedIndexes.remove(index))
            } else {
                XCTFail("No matching buffer")
            }
        }
    }

    func testLargeVectorWriteWithGSO() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        // Similar to the test above, but with multiple writes.
        let segmentSize: CInt = 1000
        let segments = 10

        // Enable GSO
        let didSet = self.firstChannel.setOption(.datagramSegmentSize, value: segmentSize)
        XCTAssertNoThrow(try didSet.wait())

        // Form a handful of segments
        let buffers = (0..<segments).map { i in
            ByteBuffer(repeating: UInt8(i), count: Int(segmentSize))
        }

        // Coalesce the segments into a single buffer.
        var buffer = self.firstChannel.allocator.buffer(capacity: segments * Int(segmentSize))
        for segment in buffers {
            buffer.writeImmutableBuffer(segment)
        }

        for byte in UInt8(0)..<UInt8(10) {
            buffer.writeRepeatingByte(byte, count: Int(segmentSize))
        }

        // Write the single large buffer.
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        let write1 = self.firstChannel.write(writeData)
        let write2 = self.firstChannel.write(writeData)
        self.firstChannel.flush()
        XCTAssertNoThrow(try write1.wait())
        XCTAssertNoThrow(try write2.wait())

        // The receiver will receive separate segments.
        let receivedBuffers = try self.secondChannel.waitForDatagrams(count: segments)
        let receivedBytes = receivedBuffers.map { $0.data.readableBytes }.reduce(0, +)
        XCTAssertEqual(Int(segmentSize) * segments, receivedBytes)

        let keysWithValues = buffers.indices.map { index in (index, 2) }
        var indexCounts = Dictionary(uniqueKeysWithValues: keysWithValues)
        for envelope in receivedBuffers {
            if let index = buffers.firstIndex(of: envelope.data) {
                indexCounts[index, default: 0] -= 1
                XCTAssertGreaterThanOrEqual(indexCounts[index]!, 0)
            } else {
                XCTFail("No matching buffer")
            }
        }
    }

    func testWriteBufferAtGSOSegmentCountLimit() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        let udpMaxSegments = System.udpMaxSegments ?? 64

        var segments = udpMaxSegments

        let segmentSize = 10
        let didSet = self.firstChannel.setOption(.datagramSegmentSize, value: CInt(segmentSize))
        XCTAssertNoThrow(try didSet.wait())

        func send(byteCount: Int) throws {
            let buffer = self.firstChannel.allocator.buffer(repeating: 1, count: byteCount)
            let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
            try self.firstChannel.writeAndFlush(writeData).wait()
        }

        do {
            try send(byteCount: segments * segmentSize)
        } catch let e as IOError where e.errnoCode == EINVAL {
            // Some older kernel versions report EINVAL with 64 segments. Tolerate that
            // failure and try again with a lower limit.
            self.firstChannel = try self.buildChannel(group: self.group)
            let didSet = self.firstChannel.setOption(.datagramSegmentSize, value: CInt(segmentSize))
            XCTAssertNoThrow(try didSet.wait())
            segments = udpMaxSegments - 3
            try send(byteCount: segments * segmentSize)
        }

        let read = try self.secondChannel.waitForDatagrams(count: segments)
        XCTAssertEqual(read.map { $0.data.readableBytes }.reduce(0, +), segments * segmentSize)
    }

    func testWriteBufferAboveGSOSegmentCountLimitShouldError() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        // commonly 64 or 128 on systems which may or may not define UDP_MAX_SEGMENTS, pick the larger to ensure failure
        let udpMaxSegments = System.udpMaxSegments ?? 128

        let segmentSize = 10
        let didSet = self.firstChannel.setOption(.datagramSegmentSize, value: CInt(segmentSize))
        XCTAssertNoThrow(try didSet.wait())

        let buffer = self.firstChannel.allocator.buffer(repeating: 1, count: segmentSize * udpMaxSegments + 1)
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        // The kernel limits messages to a maximum of UDP_MAX_SEGMENTS segments; any more should result in an error.
        XCTAssertThrowsError(try self.firstChannel.writeAndFlush(writeData).wait()) {
            XCTAssert($0 is IOError)
        }
    }

    func testGROIsUnsupportedOnNonLinuxPlatforms() throws {
        #if !os(Linux)
        XCTAssertFalse(System.supportsUDPReceiveOffload)
        #endif
    }

    func testSetGROOption() throws {
        let didSet = self.firstChannel.setOption(.datagramReceiveOffload, value: true)
        if System.supportsUDPReceiveOffload {
            XCTAssertNoThrow(try didSet.wait())
        } else {
            XCTAssertThrowsError(try didSet.wait()) { error in
                XCTAssertEqual(error as? ChannelError, .operationUnsupported)
            }
        }
    }

    func testGetGROOption() throws {
        let getOption = self.firstChannel.getOption(.datagramReceiveOffload)
        if System.supportsUDPReceiveOffload {
            XCTAssertEqual(try getOption.wait(), false)  // not-set

            // Now set and check.
            XCTAssertNoThrow(try self.firstChannel.setOption(.datagramReceiveOffload, value: true).wait())
            XCTAssertTrue(try self.firstChannel.getOption(.datagramReceiveOffload).wait())
        } else {
            XCTAssertThrowsError(try getOption.wait()) { error in
                XCTAssertEqual(error as? ChannelError, .operationUnsupported)
            }
        }
    }

    func testReceiveLargeBufferWithGRO(segments: Int, segmentSize: Int, writes: Int, vectorReads: Int? = nil) throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")
        try XCTSkipUnless(System.supportsUDPReceiveOffload, "UDP_GRO is not supported on this platform")
        try XCTSkipUnless(try self.hasGoodGROSupport())

        /// Set GSO on the first channel.
        XCTAssertNoThrow(
            try self.firstChannel.setOption(.datagramSegmentSize, value: CInt(segmentSize)).wait()
        )
        /// Set GRO on the second channel.
        XCTAssertNoThrow(try self.secondChannel.setOption(.datagramReceiveOffload, value: true).wait())
        /// The third channel has neither set.

        // Enable on second channel
        if let vectorReads = vectorReads {
            XCTAssertNoThrow(
                try self.secondChannel.setOption(.datagramVectorReadMessageCount, value: vectorReads)
                    .wait()
            )
        }

        /// Increase the size of the read buffer for the second and third channels.
        let fixed = FixedSizeRecvByteBufferAllocator(capacity: 1 << 16)
        XCTAssertNoThrow(try self.secondChannel.setOption(.recvAllocator, value: fixed).wait())
        XCTAssertNoThrow(try self.thirdChannel.setOption(.recvAllocator, value: fixed).wait())

        // Write a large datagrams on the first channel. They should be split and then accumulated on the receive side.
        // Form a large buffer to write from the first channel.
        let buffer = self.firstChannel.allocator.buffer(repeating: 1, count: segmentSize * segments)

        // Write to the channel with GRO enabled.
        do {
            let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
            let promises = (0..<writes).map { _ in self.firstChannel.write(writeData) }
            self.firstChannel.flush()
            XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: self.firstChannel.eventLoop).wait())

            // GRO is well supported; we expect `writes` datagrams.
            let datagrams = try self.secondChannel.waitForDatagrams(count: writes)
            for datagram in datagrams {
                XCTAssertEqual(datagram.data.readableBytes, segments * segmentSize)
            }
        }

        // Write to the channel whithout GRO.
        do {
            let writeData = AddressedEnvelope(remoteAddress: self.thirdChannel.localAddress!, data: buffer)
            let promises = (0..<writes).map { _ in self.firstChannel.write(writeData) }
            self.firstChannel.flush()
            XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: self.firstChannel.eventLoop).wait())

            // GRO is not enabled so we expect a `writes * segments` datagrams.
            let datagrams = try self.thirdChannel.waitForDatagrams(count: writes * segments)
            for datagram in datagrams {
                XCTAssertEqual(datagram.data.readableBytes, segmentSize)
            }
        }
    }

    func testChannelCanReceiveLargeBufferWithGROUsingScalarReads() throws {
        try self.testReceiveLargeBufferWithGRO(segments: 10, segmentSize: 1000, writes: 1)
    }

    func testChannelCanReceiveLargeBufferWithGROUsingVectorReads() throws {
        try self.testReceiveLargeBufferWithGRO(segments: 10, segmentSize: 1000, writes: 1, vectorReads: 4)
    }

    func testChannelCanReceiveMultipleLargeBuffersWithGROUsingScalarReads() throws {
        try self.testReceiveLargeBufferWithGRO(segments: 10, segmentSize: 1000, writes: 4)
    }

    func testChannelCanReceiveMultipleLargeBuffersWithGROUsingVectorReads() throws {
        try self.testReceiveLargeBufferWithGRO(segments: 10, segmentSize: 1000, writes: 4, vectorReads: 4)
    }

    func testChannelCanReportWritableBufferedBytes() throws {
        let buffer = self.firstChannel.allocator.buffer(string: "abcd")
        let data = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        let writeCount = 3

        let promises = (0..<writeCount).map { _ in self.firstChannel.write(data) }
        let bufferedAmount = try self.firstChannel.getOption(.bufferedWritableBytes).wait()
        XCTAssertEqual(bufferedAmount, buffer.readableBytes * writeCount)
        self.firstChannel.flush()
        let bufferedAmountAfterFlush = try self.firstChannel.getOption(.bufferedWritableBytes).wait()
        XCTAssertEqual(bufferedAmountAfterFlush, 0)
        XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: self.firstChannel.eventLoop).wait())
        let datagrams = try self.secondChannel.waitForDatagrams(count: writeCount)

        for datagram in datagrams {
            XCTAssertEqual(datagram.data.readableBytes, buffer.readableBytes)
        }
    }

    func testChannelCanReportWritableBufferedBytesWithDataLargerThanSendBuffer() throws {
        self.firstChannel = try DatagramBootstrap(group: self.group)
            .channelOption(.socketOption(.so_sndbuf), value: 16)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DatagramReadRecorder<ByteBuffer>(),
                        name: "ByteReadRecorder"
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let buffer = self.firstChannel.allocator.buffer(repeating: 0xff, count: 16)
        let data = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        let writeCount = 10
        var promises: [EventLoopFuture<Void>] = []

        for i in 0..<writeCount {
            let promise = self.firstChannel.write(data)
            promises.append(promise)
            do {
                if i % 2 == 0 {
                    self.firstChannel.flush()
                    XCTAssertNoThrow(
                        try EventLoopFuture.andAllSucceed(promises, on: self.firstChannel.eventLoop).wait()
                    )
                    let bufferedAmount = try self.firstChannel.getOption(.bufferedWritableBytes).wait()
                    XCTAssertEqual(bufferedAmount, 0)
                } else {
                    let bufferedAmount = try self.firstChannel.getOption(.bufferedWritableBytes).wait()
                    XCTAssertEqual(bufferedAmount, buffer.readableBytes)
                }
            } catch {
                XCTFail("firstChannel should not throw any error, but threw \(error)")
            }
        }

        self.firstChannel.flush()
        XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: self.firstChannel.eventLoop).wait())
        let finalBufferedAmount = try self.firstChannel.getOption(.bufferedWritableBytes).wait()
        XCTAssertEqual(finalBufferedAmount, 0)
        let datagrams = try self.secondChannel.waitForDatagrams(count: writeCount)

        XCTAssertEqual(datagrams.count, writeCount)
        for datagram in datagrams {
            XCTAssertEqual(datagram.data.readableBytes, buffer.readableBytes)
        }
    }

    func testShutdownReadOnConnectedUDP() throws {
        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.writeStaticString("hello, world!")

        // Connect and write
        XCTAssertNoThrow(try self.firstChannel.connect(to: self.secondChannel.localAddress!).wait())

        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(writeData).wait())
        _ = try self.secondChannel.waitForDatagrams(count: 1)

        // Ok, close on the second channel.
        XCTAssertNoThrow(try self.secondChannel.close(mode: .all).wait())
        print("closed")

        // Write again.
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(writeData).wait())

        // This should trigger an error.
        let errors = try self.firstChannel.waitForErrors(count: 1)
        XCTAssertEqual((errors[0] as? IOError)?.errnoCode, ECONNREFUSED)
    }

    private func hasGoodGROSupport() throws -> Bool {
        // Source code for UDP_GRO was added in Linux 5.0. However, this support is somewhat limited
        // and some sources indicate support was actually added in 5.10 (perhaps more widely
        // supported). There is no way (or at least, no obvious way) to detect when support was
        // properly fleshed out on a given kernel version.
        //
        // Anecdotally we have observed UDP_GRO works on 5.15 but not on 5.4. The effect of UDP_GRO
        // not working is that datagrams aren't agregated... in other words, GRO not being enabled.
        // This is fine because it's not always the case that datagrams can be aggregated so
        // applications must be able to tolerate this.
        //
        // It does however make testing GRO somewhat challenging. We need to know when we can assert
        // that datagrams will be aggregated. To do this we run a simple check on loopback (as we
        // use this for all other UDP_GRO tests) and check whether datagrams are aggregated on the
        // receive side. If they aren't then we we don't bother with further testing and instead
        // validate that our kernel is older than 5.15.
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")
        try XCTSkipUnless(System.supportsUDPReceiveOffload, "UDP_GRO is not supported on this platform")
        let sender = try! self.buildChannel(group: self.group)
        let receiver = try! self.buildChannel(group: self.group)
        defer {
            XCTAssertNoThrow(try sender.close().wait())
            XCTAssertNoThrow(try receiver.close().wait())
        }

        let segments = 2
        let segmentSize = 1000

        XCTAssertNoThrow(try sender.setOption(.datagramSegmentSize, value: CInt(segmentSize)).wait())
        XCTAssertNoThrow(try receiver.setOption(.datagramReceiveOffload, value: true).wait())
        let allocator = FixedSizeRecvByteBufferAllocator(capacity: 1 << 16)
        XCTAssertNoThrow(try receiver.setOption(.recvAllocator, value: allocator).wait())

        let buffer = self.firstChannel.allocator.buffer(repeating: 1, count: segmentSize * segments)
        let writeData = AddressedEnvelope(remoteAddress: receiver.localAddress!, data: buffer)
        XCTAssertNoThrow(try sender.writeAndFlush(writeData).wait())

        let received = try receiver.waitForDatagrams(count: 1)
        let hasGoodGROSupport = received.first!.data.readableBytes == buffer.readableBytes

        if !hasGoodGROSupport {
            // Not well supported: check we receive enough datagrams of the expected size.
            let datagrams = try receiver.waitForDatagrams(count: segments)
            for datagram in datagrams {
                XCTAssertEqual(datagram.data.readableBytes, segmentSize)
            }

            #if os(Linux)
            let info = System.systemInfo
            // If our kernel is more recent than 5.15 and we don't have good GRO support then
            // something has gone wrong (or our assumptions about kernel support are incorrect).
            if let major = info.release.major, let minor = info.release.minor {
                if major >= 6 || (major == 5 && minor >= 15) {
                    XCTFail("Platform does not have good GRO support: \(info.release.release)")
                }
            } else {
                XCTFail("Unable to determine Linux x.y release from '\(info.release.release)'")
            }
            #endif
        }

        return hasGoodGROSupport
    }

    // MARK: - Per-Message GSO Tests

    func testLargeScalarWriteWithPerMessageGSO() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        // We're going to send one large buffer with per-message GSO metadata.
        // The kernel should split it into multiple segments.
        let segmentSize = 1000
        let segments = 10

        // Form a handful of segments
        let buffers = (0..<segments).map { i in
            ByteBuffer(repeating: UInt8(i), count: segmentSize)
        }

        // Coalesce the segments into a single buffer.
        var buffer = self.firstChannel.allocator.buffer(capacity: segments * segmentSize)
        for segment in buffers {
            buffer.writeImmutableBuffer(segment)
        }

        // Write the single large buffer with per-message GSO metadata.
        let writeData = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer,
            metadata: .init(ecnState: .transportNotCapable, packetInfo: nil, segmentSize: segmentSize)
        )
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(writeData).wait())

        // The receiver will receive separate segments.
        let receivedBuffers = try self.secondChannel.waitForDatagrams(count: segments)
        let receivedBytes = receivedBuffers.map { $0.data.readableBytes }.reduce(0, +)
        XCTAssertEqual(segmentSize * segments, receivedBytes)

        var unusedIndexes = Set(buffers.indices)
        for envelope in receivedBuffers {
            if let index = buffers.firstIndex(of: envelope.data) {
                XCTAssertNotNil(unusedIndexes.remove(index))
            } else {
                XCTFail("No matching buffer")
            }
        }
    }

    func testLargeVectorWriteWithPerMessageGSO() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        // Similar to the test above, but with multiple writes using different segment sizes.
        let segmentSize1 = 1000
        let segments1 = 10
        let segmentSize2 = 500
        let segments2 = 5

        // Form segments for first write
        let buffers1 = (0..<segments1).map { i in
            ByteBuffer(repeating: UInt8(i), count: segmentSize1)
        }
        var buffer1 = self.firstChannel.allocator.buffer(capacity: segments1 * segmentSize1)
        for segment in buffers1 {
            buffer1.writeImmutableBuffer(segment)
        }

        // Form segments for second write
        let buffers2 = (0..<segments2).map { i in
            ByteBuffer(repeating: UInt8(100 + i), count: segmentSize2)
        }
        var buffer2 = self.firstChannel.allocator.buffer(capacity: segments2 * segmentSize2)
        for segment in buffers2 {
            buffer2.writeImmutableBuffer(segment)
        }

        // Write both buffers with different segment sizes.
        let writeData1 = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer1,
            metadata: .init(ecnState: .transportNotCapable, packetInfo: nil, segmentSize: segmentSize1)
        )
        let writeData2 = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer2,
            metadata: .init(ecnState: .transportNotCapable, packetInfo: nil, segmentSize: segmentSize2)
        )
        let write1 = self.firstChannel.write(writeData1)
        let write2 = self.firstChannel.write(writeData2)
        self.firstChannel.flush()
        XCTAssertNoThrow(try write1.wait())
        XCTAssertNoThrow(try write2.wait())

        // The receiver will receive separate segments from both writes.
        let receivedBuffers = try self.secondChannel.waitForDatagrams(count: segments1 + segments2)
        XCTAssertEqual(receivedBuffers.count, segments1 + segments2)
    }

    func testMixedGSOAndNonGSO() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        // Send some messages with GSO and some without.
        let segmentSize = 1000
        let segments = 5

        // GSO message
        var gsoBuffer = self.firstChannel.allocator.buffer(capacity: segments * segmentSize)
        for _ in 0..<segments {
            gsoBuffer.writeRepeatingByte(1, count: segmentSize)
        }
        let gsoEnvelope = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: gsoBuffer,
            metadata: .init(ecnState: .transportNotCapable, packetInfo: nil, segmentSize: segmentSize)
        )

        // Non-GSO message
        var normalBuffer = self.firstChannel.allocator.buffer(capacity: 100)
        normalBuffer.writeRepeatingByte(2, count: 100)
        let normalEnvelope = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: normalBuffer
        )

        // Send both
        let write1 = self.firstChannel.write(gsoEnvelope)
        let write2 = self.firstChannel.write(normalEnvelope)
        self.firstChannel.flush()
        XCTAssertNoThrow(try write1.wait())
        XCTAssertNoThrow(try write2.wait())

        // Should receive 5 segments + 1 normal message
        let received = try self.secondChannel.waitForDatagrams(count: segments + 1)
        XCTAssertEqual(received.count, segments + 1)
    }

    func testPerMessageGSOOverridesChannelLevel() throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")

        // Set channel-level GSO to one value
        XCTAssertNoThrow(try self.firstChannel.setOption(.datagramSegmentSize, value: CInt(500)).wait())

        // But use per-message GSO with a different value
        let segmentSize = 1000
        let segments = 5

        var buffer = self.firstChannel.allocator.buffer(capacity: segments * segmentSize)
        for i in 0..<segments {
            buffer.writeRepeatingByte(UInt8(i), count: segmentSize)
        }

        let envelope = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer,
            metadata: .init(ecnState: .transportNotCapable, packetInfo: nil, segmentSize: segmentSize)
        )

        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(envelope).wait())

        // Should receive segments of size 1000, not 500
        let received = try self.secondChannel.waitForDatagrams(count: segments)
        for datagram in received {
            XCTAssertEqual(datagram.data.readableBytes, segmentSize)
        }
    }

    func testPerMessageGSOThrowsOnNonLinux() throws {
        #if os(Linux)
        try XCTSkipIf(true, "This test only runs on non-Linux platforms")
        #else
        // On non-Linux platforms, setting segmentSize in metadata should throw an error
        var buffer = self.firstChannel.allocator.buffer(capacity: 1000)
        buffer.writeRepeatingByte(1, count: 1000)

        let envelope = AddressedEnvelope(
            remoteAddress: self.secondChannel.localAddress!,
            data: buffer,
            metadata: .init(ecnState: .transportNotCapable, packetInfo: nil, segmentSize: 500)
        )

        XCTAssertThrowsError(try self.firstChannel.writeAndFlush(envelope).wait()) { error in
            XCTAssertEqual(error as? ChannelError, .operationUnsupported)
        }
        #endif
    }

    // MARK: - Per-Message GRO Tests

    func testReceiveLargeBufferWithPerMessageGRO(
        segments: Int,
        segmentSize: Int,
        writes: Int,
        vectorReads: Int? = nil
    ) throws {
        try XCTSkipUnless(System.supportsUDPSegmentationOffload, "UDP_SEGMENT (GSO) is not supported on this platform")
        try XCTSkipUnless(System.supportsUDPReceiveOffload, "UDP_GRO is not supported on this platform")
        try XCTSkipUnless(try self.hasGoodGROSupport())

        /// Set GSO on the first channel.
        XCTAssertNoThrow(
            try self.firstChannel.setOption(.datagramSegmentSize, value: CInt(segmentSize)).wait()
        )
        /// Set GRO on the second channel.
        XCTAssertNoThrow(try self.secondChannel.setOption(.datagramReceiveOffload, value: true).wait())
        /// Enable per-message GRO segment size reporting on the second channel.
        XCTAssertNoThrow(try self.secondChannel.setOption(.datagramReceiveSegmentSize, value: true).wait())
        /// The third channel has neither set.

        // Enable on second channel
        if let vectorReads = vectorReads {
            XCTAssertNoThrow(
                try self.secondChannel.setOption(.datagramVectorReadMessageCount, value: vectorReads)
                    .wait()
            )
        }

        /// Increase the size of the read buffer for the second and third channels.
        let fixed = FixedSizeRecvByteBufferAllocator(capacity: 1 << 16)
        XCTAssertNoThrow(try self.secondChannel.setOption(.recvAllocator, value: fixed).wait())
        XCTAssertNoThrow(try self.thirdChannel.setOption(.recvAllocator, value: fixed).wait())

        // Write a large datagrams on the first channel. They should be split and then accumulated on the receive side.
        // Form a large buffer to write from the first channel.
        let buffer = self.firstChannel.allocator.buffer(repeating: 1, count: segmentSize * segments)

        // Write to the channel with per-message GRO enabled.
        do {
            let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
            let promises = (0..<writes).map { _ in self.firstChannel.write(writeData) }
            self.firstChannel.flush()
            XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: self.firstChannel.eventLoop).wait())

            // GRO is well supported; we expect `writes` datagrams.
            let datagrams = try self.secondChannel.waitForDatagrams(count: writes)
            for datagram in datagrams {
                XCTAssertEqual(datagram.data.readableBytes, segments * segmentSize)
                // Verify that the metadata contains the segment size
                XCTAssertNotNil(datagram.metadata, "Expected metadata to be present")
                XCTAssertEqual(
                    datagram.metadata?.segmentSize,
                    segmentSize,
                    "Expected segment size to be \(segmentSize)"
                )
            }
        }

        // Write to the channel without GRO.
        do {
            let writeData = AddressedEnvelope(remoteAddress: self.thirdChannel.localAddress!, data: buffer)
            let promises = (0..<writes).map { _ in self.firstChannel.write(writeData) }
            self.firstChannel.flush()
            XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: self.firstChannel.eventLoop).wait())

            // GRO is not enabled so we expect a `writes * segments` datagrams without segment size metadata.
            let datagrams = try self.thirdChannel.waitForDatagrams(count: writes * segments)
            for datagram in datagrams {
                XCTAssertEqual(datagram.data.readableBytes, segmentSize)
                // Without per-message GRO enabled, there should be no segment size in metadata
                XCTAssertNil(datagram.metadata?.segmentSize)
            }
        }
    }

    func testChannelCanReceiveLargeBufferWithPerMessageGROUsingScalarReads() throws {
        try self.testReceiveLargeBufferWithPerMessageGRO(segments: 10, segmentSize: 1000, writes: 1)
    }

    func testChannelCanReceiveLargeBufferWithPerMessageGROUsingVectorReads() throws {
        try self.testReceiveLargeBufferWithPerMessageGRO(segments: 10, segmentSize: 1000, writes: 1, vectorReads: 4)
    }

    func testChannelCanReceiveMultipleLargeBuffersWithPerMessageGROUsingScalarReads() throws {
        try self.testReceiveLargeBufferWithPerMessageGRO(segments: 10, segmentSize: 1000, writes: 4)
    }

    func testChannelCanReceiveMultipleLargeBuffersWithPerMessageGROUsingVectorReads() throws {
        try self.testReceiveLargeBufferWithPerMessageGRO(segments: 10, segmentSize: 1000, writes: 4, vectorReads: 4)
    }

    func testGetPerMessageGROOption() throws {
        let getOption = self.firstChannel.getOption(.datagramReceiveSegmentSize)
        if System.supportsUDPReceiveOffload {
            XCTAssertEqual(try getOption.wait(), false)  // not-set

            // Now set and check.
            XCTAssertNoThrow(try self.firstChannel.setOption(.datagramReceiveSegmentSize, value: true).wait())
            XCTAssertTrue(try self.firstChannel.getOption(.datagramReceiveSegmentSize).wait())
        } else {
            XCTAssertThrowsError(try getOption.wait()) { error in
                XCTAssertEqual(error as? ChannelError, .operationUnsupported)
            }
        }
    }

    func testPerMessageGROThrowsOnNonLinux() throws {
        #if !os(Linux)
        // On non-Linux platforms, setting datagramReceiveSegmentSize should throw an error
        XCTAssertThrowsError(try self.firstChannel.setOption(.datagramReceiveSegmentSize, value: true).wait()) {
            error in
            XCTAssertEqual(error as? ChannelError, .operationUnsupported)
        }
        #endif
    }
}

extension System {
    #if os(Linux)
    internal static let systemInfo: SystemInfo = {
        var info = utsname()
        let rc = CNIOLinux_system_info(&info)
        assert(rc == 0)
        return SystemInfo(utsname: info)
    }()

    struct SystemInfo {
        var machine: String
        var nodeName: String
        var sysName: String
        var release: Release
        var version: String

        struct Release {
            var release: String

            var major: Int?
            var minor: Int?

            init(parsing release: String) {
                self.release = release

                let components = release.split(separator: ".", maxSplits: 1)

                if components.count == 2 {
                    self.major = Int(components[0])
                    self.minor = components[1].split(separator: ".").first.map(String.init).flatMap(Int.init)
                } else {
                    self.major = nil
                    self.minor = nil
                }
            }
        }

        init(utsname info: utsname) {
            self.machine = withUnsafeBytes(of: info.machine) { bytes in
                let pointer = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
                return pointer.map { String(cString: $0) } ?? ""
            }

            self.nodeName = withUnsafeBytes(of: info.nodename) { bytes in
                let pointer = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
                return pointer.map { String(cString: $0) } ?? ""
            }

            self.sysName = withUnsafeBytes(of: info.sysname) { bytes in
                let pointer = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
                return pointer.map { String(cString: $0) } ?? ""
            }

            self.version = withUnsafeBytes(of: info.version) { bytes in
                let pointer = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
                return pointer.map { String(cString: $0) } ?? ""
            }

            self.release = withUnsafeBytes(of: info.release) { bytes in
                let pointer = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
                let release = pointer.map { String(cString: $0) } ?? ""
                return Release(parsing: release)
            }
        }
    }
    #endif
}
