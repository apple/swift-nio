//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
@testable import NIO
import XCTest

private extension Channel {
    func waitForDatagrams(count: Int) throws -> [AddressedEnvelope<ByteBuffer>] {
        return try self.pipeline.context(name: "ByteReadRecorder").then { context in
            if let future = (context.handler as? DatagramReadRecorder<ByteBuffer>)?.notifyForDatagrams(count) {
                return future
            }

            XCTFail("Could not wait for reads")
            return self.eventLoop.newSucceededFuture(result: [] as [AddressedEnvelope<ByteBuffer>])
        }.wait()
    }
}

/// A class that records datagrams received and forwards them on.
///
/// Used extensively in tests to validate messaging expectations.
private class DatagramReadRecorder<DataType>: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<DataType>
    typealias InboundOut = AddressedEnvelope<DataType>

    var reads: [AddressedEnvelope<DataType>] = []
    var loop: EventLoop? = nil

    var readWaiters: [Int: EventLoopPromise<[AddressedEnvelope<DataType>]>] = [:]

    func channelRegistered(ctx: ChannelHandlerContext) {
        self.loop = ctx.eventLoop
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        reads.append(data)

        if let promise = readWaiters.removeValue(forKey: reads.count) {
            promise.succeed(result: reads)
        }

        ctx.fireChannelRead(self.wrapInboundOut(data))
    }

    func notifyForDatagrams(_ count: Int) -> EventLoopFuture<[AddressedEnvelope<DataType>]> {
        guard reads.count < count else {
            return loop!.newSucceededFuture(result: .init(reads.prefix(count)))
        }

        readWaiters[count] = loop!.newPromise()
        return readWaiters[count]!.futureResult
    }
}

final class DatagramChannelTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup! = nil
    private var firstChannel: Channel! = nil
    private var secondChannel: Channel! = nil

    private func buildChannel(group: EventLoopGroup) throws -> Channel {
        return try DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.add(name: "ByteReadRecorder", handler: DatagramReadRecorder<ByteBuffer>())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    override func setUp() {
        super.setUp()
        self.group = MultiThreadedEventLoopGroup(numThreads: 1)
        self.firstChannel = try! buildChannel(group: group)
        self.secondChannel = try! buildChannel(group: group)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
        super.tearDown()
    }

    func testBasicChannelCommunication() throws {
        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.write(staticString: "hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        XCTAssertNoThrow(try self.firstChannel.writeAndFlush(NIOAny(writeData)).wait())

        let reads = try self.secondChannel.waitForDatagrams(count: 1)
        XCTAssertEqual(reads.count, 1)
        let read = reads.first!
        XCTAssertEqual(read.data, buffer)
        XCTAssertEqual(read.remoteAddress, self.firstChannel.localAddress!)
    }

    func testManyWrites() throws {
        var buffer = firstChannel.allocator.buffer(capacity: 256)
        buffer.write(staticString: "hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        for _ in 0..<5 {
            self.firstChannel.write(NIOAny(writeData), promise: nil)
        }
        XCTAssertNoThrow(try self.firstChannel.flush().wait())

        let reads = try self.secondChannel.waitForDatagrams(count: 5)

        // These short datagrams should not have been dropped by the kernel.
        XCTAssertEqual(reads.count, 5)

        for read in reads {
            XCTAssertEqual(read.data, buffer)
            XCTAssertEqual(read.remoteAddress, self.firstChannel.localAddress!)
        }
    }

    func testConnectionFails() throws {
        do {
            try self.firstChannel.connect(to: self.secondChannel.localAddress!).wait()
        } catch ChannelError.operationUnsupported {
            // All is well
        } catch {
            XCTFail("Encountered error: \(error)")
        }
    }

    func testDatagramChannelHasWatermark() throws {
        _ = try self.firstChannel.setOption(option: ChannelOptions.writeBufferWaterMark, value: 1..<1024).wait()

        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.write(bytes: [UInt8](repeating: 5, count: 256))
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        XCTAssertTrue(self.firstChannel.isWritable)
        for _ in 0..<4 {
            // We submit to the loop here to make sure that we synchronously process the writes and checks
            // on writability.
            let writable: Bool = try self.firstChannel.eventLoop.submit {
                self.firstChannel.write(NIOAny(writeData), promise: nil)
                return self.firstChannel.isWritable
            }.wait()
            XCTAssertTrue(writable)
        }

        // The last write will push us over the edge.
        var writable: Bool = try self.firstChannel.eventLoop.submit {
            self.firstChannel.write(NIOAny(writeData), promise: nil)
            return self.firstChannel.isWritable
            }.wait()
        XCTAssertFalse(writable)

        // Now we're going to flush, and check the writability immediately after.
        writable = try self.firstChannel.flush().map { _ in self.firstChannel.isWritable }.wait()
        XCTAssertTrue(writable)
    }

    func testWriteFuturesFailWhenChannelClosed() throws {
        var buffer = self.firstChannel.allocator.buffer(capacity: 256)
        buffer.write(staticString: "hello, world!")
        let writeData = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
        let promises = (0..<5).map { _ in self.firstChannel.write(NIOAny(writeData)) }

        // Now close the channel. When that completes, all the futures should be complete too.
        let fulfilled = try self.firstChannel.close().map {
            promises.map { $0.fulfilled }.reduce(true, { $0 && $1 })
        }.wait()
        XCTAssertTrue(fulfilled)

        promises.forEach {
            do {
                try $0.wait()
                XCTFail("Did not error")
            } catch ChannelError.alreadyClosed {
                // All good
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testManyManyDatagramWrites() throws {
        // We're going to try to write loads, and loads, and loads of data. In this case, one more
        // write than the iovecs max.
        for _ in 0...Socket.writevLimitIOVectors {
            var buffer = self.firstChannel.allocator.buffer(capacity: 1)
            buffer.write(string: "a")
            let envelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)
            self.firstChannel.write(NIOAny(envelope), promise: nil)
        }
        XCTAssertNoThrow(try self.firstChannel.flush().wait())

        // We're not going to check that the datagrams arrive, because some kernels *will* drop them here.
    }

    func testSendmmsgLotsOfData() throws {
        var datagrams = 0

        // We defer this work to the background thread because otherwise it incurs an enormous number of context
        // switches.
        _ = try self.firstChannel.eventLoop.submit {
            // For datagrams this buffer cannot be very large, becuase if it's larger than the path MTU it
            // will cause EMSGSIZE.
            let bufferSize = 1024 * 5
            var buffer = self.firstChannel.allocator.buffer(capacity: bufferSize)
            buffer.writeWithUnsafeMutableBytes {
                _ = memset($0.baseAddress!, 4, $0.count)
                return $0.count
            }
            let envelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

            var written = 0
            while written <= Int(INT32_MAX) {
                self.firstChannel.write(NIOAny(envelope), promise: nil)
                written += bufferSize
                datagrams += 1
            }
        }.wait()

        XCTAssertNoThrow(try self.firstChannel.flush().wait())
    }

    func testLargeWritesFail() throws {
        // We want to try to trigger EMSGSIZE. To be safe, we're going to allocate a 10MB buffer here and fill it.
        let bufferSize = 1024 * 1024 * 10
        var buffer = self.firstChannel.allocator.buffer(capacity: bufferSize)
        buffer.writeWithUnsafeMutableBytes {
            _ = memset($0.baseAddress!, 4, $0.count)
            return $0.count
        }
        let envelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        let writeFut = self.firstChannel.write(NIOAny(envelope))
        self.firstChannel.flush(promise: nil)

        do {
            try writeFut.wait()
            XCTFail("Did not throw")
        } catch ChannelError.writeMessageTooLarge {
            // All good
        } catch {
            XCTFail("Got unexpected error \(error)")
        }
    }

    func testOneLargeWriteDoesntPreventOthersWriting() throws {
        // We want to try to trigger EMSGSIZE. To be safe, we're going to allocate a 10MB buffer here and fill it.
        let bufferSize = 1024 * 1024 * 10
        var buffer = self.firstChannel.allocator.buffer(capacity: bufferSize)
        buffer.writeWithUnsafeMutableBytes {
            _ = memset($0.baseAddress!, 4, $0.count)
            return $0.count
        }

        // Now we want two envelopes. The first is small, the second is large.
        let firstEnvelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer.getSlice(at: buffer.readerIndex, length: 100)!)
        let secondEnvelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        // Now, three writes. We're sandwiching the big write between two small ones.
        let firstWrite = self.firstChannel.write(NIOAny(firstEnvelope))
        let secondWrite = self.firstChannel.write(NIOAny(secondEnvelope))
        let thirdWrite = self.firstChannel.write(NIOAny(firstEnvelope))
        let flushPromise = self.firstChannel.flush()

        // The first and third writes should be fine.
        XCTAssertNoThrow(try firstWrite.wait())
        XCTAssertNoThrow(try thirdWrite.wait())

        // The second should have failed.
        do {
            try secondWrite.wait()
            XCTFail("Did not throw")
        } catch ChannelError.writeMessageTooLarge {
            // All good
        } catch {
            XCTFail("Got unexpected error \(error)")
        }

        // The flush promise should also have failed.
        do {
            try flushPromise.wait()
        } catch let e as NIOCompositeError {
            XCTAssertEqual(e.count, 1)
            switch e[0] {
            case ChannelError.writeMessageTooLarge:
                break
            default:
                XCTFail("Unexpected inner error: \(e[0])")
            }
        } catch {
            XCTFail("Got unexpected error \(error)")
        }
    }

    func testClosingBeforeFlushFailsAllWrites() throws {
        // We want to try to trigger EMSGSIZE. To be safe, we're going to allocate a 10MB buffer here and fill it.
        let bufferSize = 1024 * 1024 * 10
        var buffer = self.firstChannel.allocator.buffer(capacity: bufferSize)
        buffer.writeWithUnsafeMutableBytes {
            _ = memset($0.baseAddress!, 4, $0.count)
            return $0.count
        }

        // Now we want two envelopes. The first is small, the second is large.
        let firstEnvelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer.getSlice(at: buffer.readerIndex, length: 100)!)
        let secondEnvelope = AddressedEnvelope(remoteAddress: self.secondChannel.localAddress!, data: buffer)

        // Now, three writes. We're sandwiching the big write between two small ones.
        let firstWrite = self.firstChannel.write(NIOAny(firstEnvelope))
        let secondWrite = self.firstChannel.write(NIOAny(secondEnvelope))
        let thirdWrite = self.firstChannel.write(NIOAny(firstEnvelope))
        let flushPromise = self.firstChannel.flush()

        // The first and third writes should be fine.
        XCTAssertNoThrow(try firstWrite.wait())
        XCTAssertNoThrow(try thirdWrite.wait())

        // The second should have failed.
        do {
            try secondWrite.wait()
            XCTFail("Did not throw")
        } catch ChannelError.writeMessageTooLarge {
            // All good
        } catch {
            XCTFail("Got unexpected error \(error)")
        }

        // The flush promise should also have failed.
        do {
            try flushPromise.wait()
        } catch let e as NIOCompositeError {
            XCTAssertEqual(e.count, 1)
            switch e[0] {
            case ChannelError.writeMessageTooLarge:
                break
            default:
                XCTFail("Unexpected inner error: \(e[0])")
            }
        } catch {
            XCTFail("Got unexpected error \(error)")
        }
    }

    func testFastFlush() throws {
        // A flush on empty succeeds immediately.
        try self.firstChannel.flush().wait()
    }
}
