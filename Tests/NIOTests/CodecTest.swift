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

//
import XCTest
@testable import NIO

private var testDecoderIsNotQuadratic_mallocs = 0
private var testDecoderIsNotQuadratic_reallocs = 0
private func testDecoderIsNotQuadratic_freeHook(_ ptr: UnsafeMutableRawPointer?) -> Void {
    free(ptr)
}

private func testDecoderIsNotQuadratic_mallocHook(_ size: Int) -> UnsafeMutableRawPointer? {
    testDecoderIsNotQuadratic_mallocs += 1
    return malloc(size)
}

private func testDecoderIsNotQuadratic_reallocHook(_ ptr: UnsafeMutableRawPointer?, _ count: Int) -> UnsafeMutableRawPointer? {
    testDecoderIsNotQuadratic_reallocs += 1
    return realloc(ptr, count)
}

private func testDecoderIsNotQuadratic_memcpyHook(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> Void {
    _ = memcpy(dst, src, count)
}

private final class ChannelInactivePromiser: ChannelInboundHandler {
    typealias InboundIn = Any

    let channelInactivePromise: EventLoopPromise<Void>

    init(channel: Channel) {
        channelInactivePromise = channel.eventLoop.makePromise()
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelInactivePromise.succeed(())
    }
}

public class ByteToMessageDecoderTest: XCTestCase {
    private final class ByteToInt32Decoder : ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Int32

        func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            guard buffer.readableBytes >= MemoryLayout<Int32>.size else {
                return .needMoreData
            }
            context.fireChannelRead(self.wrapInboundOut(buffer.readInteger()!))
            return .continue
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
            XCTAssertTrue(seenEOF)
            return self.decode(context: context, buffer: &buffer)
        }
    }

    private final class ForeverDecoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Never

        func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            return .needMoreData
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
            XCTAssertTrue(seenEOF)
            return self.decode(context: context, buffer: &buffer)
        }
    }

    private final class LargeChunkDecoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer

        func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            guard case .some(let buffer) = buffer.readSlice(length: 512) else {
                return .needMoreData
            }

            context.fireChannelRead(self.wrapInboundOut(buffer))
            return .continue
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
            XCTAssertTrue(seenEOF)
            return self.decode(context: context, buffer: &buffer)
        }
    }

    // A special case decoder that decodes only once there is 5,120 bytes in the buffer,
    // at which point it decodes exactly 2kB of memory.
    private final class OnceDecoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer

        func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            guard buffer.readableBytes >= 5120 else {
                return .needMoreData
            }

            context.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: 2048)!))
            return .continue
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
            XCTAssertTrue(seenEOF)
            return self.decode(context: context, buffer: &buffer)
        }
    }

    func testDecoder() throws {
        let channel = EmbeddedChannel()

        _ = try channel.pipeline.addHandler(ByteToMessageHandler(ByteToInt32Decoder())).wait()

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.writeInteger(Int32(1))
        let writerIndex = buffer.writerIndex
        buffer.moveWriterIndex(to: writerIndex - 1)

        channel.pipeline.fireChannelRead(NIOAny(buffer))
        XCTAssertNil(channel.readInbound())

        channel.pipeline.fireChannelRead(NIOAny(buffer.getSlice(at: writerIndex - 1, length: 1)!))

        var buffer2 = channel.allocator.buffer(capacity: 32)
        buffer2.writeInteger(Int32(2))
        buffer2.writeInteger(Int32(3))
        channel.pipeline.fireChannelRead(NIOAny(buffer2))

        XCTAssertNoThrow(try channel.finish())

        XCTAssertEqual(Int32(1), channel.readInbound())
        XCTAssertEqual(Int32(2), channel.readInbound())
        XCTAssertEqual(Int32(3), channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }

    func testDecoderPropagatesChannelInactive() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        let inactivePromiser = ChannelInactivePromiser(channel: channel)
        _ = try channel.pipeline.addHandler(ByteToMessageHandler(ByteToInt32Decoder())).wait()
        _ = try channel.pipeline.addHandler(inactivePromiser).wait()

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.writeInteger(Int32(1))
        channel.pipeline.fireChannelRead(NIOAny(buffer))
        XCTAssertEqual(Int32(1), channel.readInbound())

        XCTAssertFalse(inactivePromiser.channelInactivePromise.futureResult.isFulfilled)

        channel.pipeline.fireChannelInactive()
        XCTAssertTrue(inactivePromiser.channelInactivePromise.futureResult.isFulfilled)
    }

    func testDecoderIsNotQuadratic() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        XCTAssertEqual(testDecoderIsNotQuadratic_mallocs, 0)
        XCTAssertEqual(testDecoderIsNotQuadratic_reallocs, 0)
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(ForeverDecoder())).wait())

        let dummyAllocator = ByteBufferAllocator(hookedMalloc: testDecoderIsNotQuadratic_mallocHook,
                                                 hookedRealloc: testDecoderIsNotQuadratic_reallocHook,
                                                 hookedFree: testDecoderIsNotQuadratic_freeHook,
                                                 hookedMemcpy: testDecoderIsNotQuadratic_memcpyHook)
        channel.allocator = dummyAllocator
        var inputBuffer = dummyAllocator.buffer(capacity: 8)
        inputBuffer.writeStaticString("whatwhat")

        for _ in 0..<10 {
            channel.pipeline.fireChannelRead(NIOAny(inputBuffer))
        }

        // We get one extra malloc the first time around the loop, when we have aliased the buffer. From then on it's
        // all reallocs of the underlying buffer.
        XCTAssertEqual(testDecoderIsNotQuadratic_mallocs, 2)
        XCTAssertEqual(testDecoderIsNotQuadratic_reallocs, 3)
    }

    func testMemoryIsReclaimedIfMostIsConsumed() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let decoder = ByteToMessageHandler(LargeChunkDecoder())
        _ = try channel.pipeline.addHandler(decoder).wait()

        // We're going to send in 513 bytes. This will cause a chunk to be passed on, and will leave
        // a 512-byte empty region in a 513 byte buffer. This will not cause a shrink.
        var buffer = channel.allocator.buffer(capacity: 513)
        buffer.writeBytes(Array(repeating: 0x04, count: 513))
        XCTAssertTrue(try channel.writeInbound(buffer))

        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 1)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 512)

        // Now we're going to send in another 513 bytes. This will cause another chunk to be passed in,
        // but now we'll shrink the buffer.
        XCTAssertTrue(try channel.writeInbound(buffer))

        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 2)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 0)
    }

    func testMemoryIsReclaimedIfLotsIsAvailable() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let decoder = ByteToMessageHandler(OnceDecoder())
        _ = try channel.pipeline.addHandler(decoder).wait()

        // We're going to send in 5119 bytes. This will be held.
        var buffer = channel.allocator.buffer(capacity: 5119)
        buffer.writeBytes(Array(repeating: 0x04, count: 5119))
        XCTAssertFalse(try channel.writeInbound(buffer))

        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 5119)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 0)

        // Now we're going to send in one more byte. This will cause a chunk to be passed on,
        // shrinking the held memory to 3072 bytes. However, memory will be reclaimed.
        XCTAssertTrue(try channel.writeInbound(buffer.getSlice(at: 0, length: 1)))
        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 3072)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 0)
    }

    func testDecoderReentranceChannelRead() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        class TestDecoder: ByteToMessageDecoder {

            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            var numberOfDecodeCalls = 0
            var hasReentranced = false

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.numberOfDecodeCalls += 1
                print("\(numberOfDecodeCalls): \(String(decoding: buffer.readableBytesView, as: UTF8.self))")
                var reentrantWriteBuffer = context.channel.allocator.buffer(capacity: 1)
                if self.numberOfDecodeCalls == 2 {
                    // this is the first time, let's fireChannelRead
                    self.hasReentranced = true
                    reentrantWriteBuffer.clear()
                    reentrantWriteBuffer.writeStaticString("3")
                    context.channel.pipeline.fireChannelRead(self.wrapInboundOut(reentrantWriteBuffer))
                }
                context.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: 1)!))
                if self.numberOfDecodeCalls == 2 {
                    reentrantWriteBuffer.clear()
                    reentrantWriteBuffer.writeStaticString("4")
                    context.channel.pipeline.fireChannelRead(self.wrapInboundOut(reentrantWriteBuffer))
                }
                return .continue
            }

            func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                return .needMoreData
            }
        }

        let testDecoder = TestDecoder()

        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(testDecoder)).wait())

        var inputBuffer = channel.allocator.buffer(capacity: 4)
        /* 1 */
        inputBuffer.writeStaticString("1")
        XCTAssertTrue(try channel.writeInbound(inputBuffer))
        inputBuffer.clear()

        /* 2 */
        inputBuffer.writeStaticString("2")
        XCTAssertTrue(try channel.writeInbound(inputBuffer))
        inputBuffer.clear()

        /* 3 */
        inputBuffer.writeStaticString("5")
        XCTAssertTrue(try channel.writeInbound(inputBuffer))
        inputBuffer.clear()

        func readOneInboundString() -> String {
            switch channel.readInbound(as: ByteBuffer.self) {
            case .some(let buffer):
                return String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self)
            case .none:
                XCTFail("expected ByteBuffer found nothing")
                return "no, error from \(#line)"
            }
        }

        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual("1", readOneInboundString())
        XCTAssertEqual("2", readOneInboundString())
        XCTAssertEqual("3", readOneInboundString())
        XCTAssertEqual("4", readOneInboundString())
        XCTAssertEqual("5", readOneInboundString())
        XCTAssertNil(channel.readInbound(as: IOData.self))
        XCTAssertTrue(testDecoder.hasReentranced)
    }

    func testTrivialDecoderDoesSensibleStuffWhenCloseInRead() {
        class HandItThroughDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            var decodeLastCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                let originalBuffer = buffer
                context.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: buffer.readableBytes)!))
                if originalBuffer.readableBytesView.last == "0".utf8.last {
                    context.close().whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                }
                return .needMoreData
            }

            func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                self.decodeLastCalls += 1
                XCTAssertEqual(1, self.decodeLastCalls)
                return .needMoreData
            }
        }

        let decoder = HandItThroughDecoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertTrue(channel.isActive)

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.clear()
        buffer.writeStaticString("1")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("23")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("4567890")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertFalse(channel.isActive)

        XCTAssertEqual("1", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("23", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("4567890", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertNil(channel.readInbound())
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testLeftOversMakeDecodeLastCalled() {
        let lastPromise = EmbeddedEventLoop().makePromise(of: ByteBuffer.self)
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(PairOfBytesDecoder(lastPromise: lastPromise)))

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.clear()
        buffer.writeStaticString("1")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("23")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("4567890x")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.close().wait())
        XCTAssertFalse(channel.isActive)

        XCTAssertEqual("12", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("34", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("56", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("78", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("90", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertNil(channel.readInbound())

        XCTAssertNoThrow(XCTAssertEqual("x", String(decoding: try lastPromise.futureResult.wait().readableBytesView,
                                                    as: Unicode.UTF8.self)))
    }

    func testRemovingHandlerMakesLeftoversAppearInDecodeLast() {
        let lastPromise = EmbeddedEventLoop().makePromise(of: ByteBuffer.self)
        let decoder = PairOfBytesDecoder(lastPromise: lastPromise)
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        defer {
            XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))
        }

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.clear()
        buffer.writeStaticString("1")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("23")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("4567890x")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        channel.pipeline.context(handlerType: ByteToMessageHandler<PairOfBytesDecoder>.self).flatMap { context in
            return channel.pipeline.removeHandler(context: context)
        }.whenFailure { error in
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual("12", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("34", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("56", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("78", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertEqual("90", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self) })
        XCTAssertNil(channel.readInbound())
        (channel.eventLoop as! EmbeddedEventLoop).run()

        XCTAssertNoThrow(XCTAssertEqual("x", String(decoding: try lastPromise.futureResult.wait().readableBytesView,
                                                    as: Unicode.UTF8.self)))
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testStructsWorkAsByteToMessageDecoders() {
        struct WantsOneThenTwoBytesDecoder: ByteToMessageDecoder {
            typealias InboundOut = Int

            var state: Int = 1

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let slice = buffer.readSlice(length: self.state) {
                    defer {
                        self.state += 1
                    }
                    context.fireChannelRead(self.wrapInboundOut(self.state))
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                context.fireChannelRead(self.wrapInboundOut(buffer.readableBytes * -1))
                return .needMoreData
            }
        }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(WantsOneThenTwoBytesDecoder()))

        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.clear()
        buffer.writeStaticString("1")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("23")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("4567890qwer")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertEqual(1, channel.readInbound())
        XCTAssertEqual(2, channel.readInbound())
        XCTAssertEqual(3, channel.readInbound())
        XCTAssertEqual(4, channel.readInbound())
        XCTAssertNil(channel.readInbound())

        XCTAssertNoThrow(try channel.close().wait())
        XCTAssertFalse(channel.isActive)

        XCTAssertEqual(-4, channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }

    func testReentrantChannelReadWhileWholeBufferIsBeingProcessed() {
        struct ProcessAndReentrantylyProcessExponentiallyLessStuffDecoder: ByteToMessageDecoder {
            typealias InboundOut = String
            var state = 16

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTAssertGreaterThan(self.state, 0)
                if let slice = buffer.readSlice(length: self.state) {
                    self.state >>= 1
                    for i in 0..<self.state {
                        XCTAssertNoThrow(try (context.channel as! EmbeddedChannel).writeInbound(slice.getSlice(at: i, length: 1)))
                    }
                    context.fireChannelRead(self.wrapInboundOut(String(decoding: slice.readableBytesView, as: Unicode.UTF8.self)))
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                return try self.decode(context: context, buffer: &buffer)
            }
        }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(ProcessAndReentrantylyProcessExponentiallyLessStuffDecoder()))
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdef")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertEqual("0123456789abcdef", channel.readInbound())
        XCTAssertEqual("01234567", channel.readInbound())
        XCTAssertEqual("0123", channel.readInbound())
        XCTAssertEqual("01", channel.readInbound())
        XCTAssertEqual("0", channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }

    func testReentrantChannelCloseInChannelRead() {
        struct Take16BytesThenCloseAndPassOnDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let slice = buffer.readSlice(length: 16) {
                    context.fireChannelRead(self.wrapInboundOut(slice))
                    context.channel.close().whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                context.fireChannelRead(self.wrapInboundOut(buffer))
                return .needMoreData
            }
        }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(Take16BytesThenCloseAndPassOnDecoder()))
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdefQWER")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertEqual("0123456789abcdef", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)})
        XCTAssertEqual("QWER", channel.readInbound(as: ByteBuffer.self).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)})
        XCTAssertNil(channel.readInbound())
    }

    func testHandlerRemoveInChannelRead() {
        struct Take16BytesThenCloseAndPassOnDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let slice = buffer.readSlice(length: 16) {
                    context.fireChannelRead(self.wrapInboundOut(slice))
                    context.pipeline.removeHandler(context: context).whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertFalse(seenEOF)
                context.fireChannelRead(self.wrapInboundOut(buffer))
                return .needMoreData
            }
        }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(Take16BytesThenCloseAndPassOnDecoder()))
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdefQWER")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertEqual("0123456789abcdef", (channel.readInbound() as ByteBuffer?).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)})
        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual("QWER", (channel.readInbound() as ByteBuffer?).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)})
        XCTAssertNil(channel.readInbound())
    }

    func testChannelCloseInChannelRead() {
        struct Take16BytesThenCloseAndPassOnDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let slice = buffer.readSlice(length: 16) {
                    context.fireChannelRead(self.wrapInboundOut(slice))
                    context.close().whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                return .needMoreData
            }
        }
        class DoNotForwardChannelInactiveHandler: ChannelInboundHandler {
            typealias InboundIn = Never

            func channelInactive(context: ChannelHandlerContext) {
                // just eat this event
            }
        }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(Take16BytesThenCloseAndPassOnDecoder()))
        XCTAssertNoThrow(try channel.pipeline.addHandler(DoNotForwardChannelInactiveHandler(), position: .first).wait())
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdefQWER")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertEqual("0123456789abcdef", (channel.readInbound() as ByteBuffer?).map { String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)})
        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertNil(channel.readInbound()) // no leftovers are forwarded
    }

    func testDecodeLoopGetsInterruptedWhenRemovalIsTriggered() {
        struct Decoder: ByteToMessageDecoder {
            typealias InboundOut = String

            var callsToDecode = 0
            var callsToDecodeLast = 0

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTAssertEqual(9, buffer.readableBytes)
                self.callsToDecode += 1
                XCTAssertEqual(1, self.callsToDecode)
                context.fireChannelRead(self.wrapInboundOut(String(decoding: buffer.readBytes(length: 1)!,
                                                               as: Unicode.UTF8.self)))
                context.pipeline.removeHandler(context: context).whenFailure { error in
                    XCTFail("unexpected error: \(error)")
                }
                return .continue
            }

            mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertFalse(seenEOF)
                self.callsToDecodeLast += 1
                XCTAssertLessThanOrEqual(self.callsToDecodeLast, 2)
                context.fireChannelRead(self.wrapInboundOut(String(decoding: buffer.readBytes(length: 4) ??
                                                                         [ /* "no bytes" */
                                                                            0x6e, 0x6f, 0x20,
                                                                            0x62, 0x79, 0x74, 0x65, 0x73],
                                                               as: Unicode.UTF8.self) + "#\(self.callsToDecodeLast)"))
                return .continue
            }
        }

        let handler = ByteToMessageHandler(Decoder())
        let channel = EmbeddedChannel(handler: handler)
        defer {
            XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))
        }

        var buffer = channel.allocator.buffer(capacity: 9)
        buffer.writeStaticString("012345678")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(1, handler.decoder?.callsToDecode)
        XCTAssertEqual(2, handler.decoder?.callsToDecodeLast)
        ["0", "1234#1", "5678#2"].forEach {
            XCTAssertEqual($0, channel.readInbound())
        }
    }

    func testDecodeLastIsInvokedOnceEvenIfNothingEverArrivedOnChannelClosed() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = ()
            var decodeLastCalls = 0

            public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTFail("did not expect to see decode called")
                return .needMoreData
            }

            public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                self.decodeLastCalls += 1
                XCTAssertEqual(1, self.decodeLastCalls)
                XCTAssertEqual(0, buffer.readableBytes)
                context.fireChannelRead(self.wrapInboundOut(()))
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))

        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertNil(channel.readInbound())

        XCTAssertNoThrow(try channel.close().wait())
        XCTAssertNotNil(channel.readInbound())
        XCTAssertNil(channel.readInbound())

        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testDecodeLastIsInvokedOnceEvenIfNothingEverArrivedOnChannelHalfClosure() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = ()
            var decodeLastCalls = 0

            public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTFail("did not expect to see decode called")
                return .needMoreData
            }

            public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                self.decodeLastCalls += 1
                XCTAssertEqual(1, self.decodeLastCalls)
                XCTAssertEqual(0, buffer.readableBytes)
                context.fireChannelRead(self.wrapInboundOut(()))
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))

        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertNil(channel.readInbound())

        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertNotNil(channel.readInbound())
        XCTAssertNil(channel.readInbound())

        XCTAssertEqual(1, decoder.decodeLastCalls)

        XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))

        XCTAssertNil(channel.readInbound())
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testDecodeLastHasSeenEOFFalseOnHandlerRemoved() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = ()
            var decodeLastCalls = 0

            public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTAssertEqual(1, buffer.readableBytes)
                return .needMoreData
            }

            public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                self.decodeLastCalls += 1
                XCTAssertEqual(1, buffer.readableBytes)
                XCTAssertEqual(1, self.decodeLastCalls)
                XCTAssertFalse(seenEOF)
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 1)
        buffer.writeString("x")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        let removalFuture = channel.pipeline.context(handlerType: ByteToMessageHandler<Decoder>.self).flatMap {
            channel.pipeline.removeHandler(context: $0)
        }
        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertNoThrow(try removalFuture.wait())
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testDecodeLastHasSeenEOFFalseOnHandlerRemovedEvenIfNoData() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = ()
            var decodeLastCalls = 0

            public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTFail("shouldn't have been called")
                return .needMoreData
            }

            public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                self.decodeLastCalls += 1
                XCTAssertEqual(0, buffer.readableBytes)
                XCTAssertEqual(1, self.decodeLastCalls)
                XCTAssertFalse(seenEOF)
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        let removalFuture = channel.pipeline.context(handlerType: ByteToMessageHandler<Decoder>.self).flatMap {
            channel.pipeline.removeHandler(context: $0)
        }
        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertNoThrow(try removalFuture.wait())
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testDecodeLastHasSeenEOFTrueOnChannelInactive() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = ()
            var decodeLastCalls = 0

            public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTAssertEqual(1, buffer.readableBytes)
                return .needMoreData
            }

            public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                self.decodeLastCalls += 1
                XCTAssertEqual(1, buffer.readableBytes)
                XCTAssertEqual(1, self.decodeLastCalls)
                XCTAssertTrue(seenEOF)
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 1)
        buffer.writeString("x")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testWriteObservingByteToMessageDecoderBasic() {
        class Decoder: WriteObservingByteToMessageDecoder {
            typealias OutboundIn = Int
            typealias InboundOut = String

            var allObservedWrites: [Int] = []

            func write(data: Int) {
                self.allObservedWrites.append(data)
            }

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let string = buffer.readString(length: 1) {
                    context.fireChannelRead(self.wrapInboundOut(string))
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                while case .continue = try self.decode(context: context, buffer: &buffer) {}
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 3)
        buffer.writeStaticString("abc")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.writeOutbound(1))
        XCTAssertNoThrow(try channel.writeOutbound(2))
        XCTAssertNoThrow(try channel.writeOutbound(3))
        XCTAssertEqual([1, 2, 3], decoder.allObservedWrites)
        XCTAssertEqual("a", channel.readInbound())
        XCTAssertEqual("b", channel.readInbound())
        XCTAssertEqual("c", channel.readInbound())
        XCTAssertEqual(1, channel.readOutbound())
        XCTAssertEqual(2, channel.readOutbound())
        XCTAssertEqual(3, channel.readOutbound())
        XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))
    }

    func testWriteObservingByteToMessageDecoderWhereWriteIsReentrantlyCalled() {
        class Decoder: WriteObservingByteToMessageDecoder {
            typealias OutboundIn = String
            typealias InboundOut = String

            var allObservedWrites: [String] = []
            var decodeRun = 0

            func write(data: String) {
                self.allObservedWrites.append(data)
            }

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.decodeRun += 1
                if let string = buffer.readString(length: 1) {
                    context.fireChannelRead(self.wrapInboundOut("I: \(self.decodeRun): \(string)"))
                    XCTAssertNoThrow(try (context.channel as! EmbeddedChannel).writeOutbound("O: \(self.decodeRun): \(string)"))
                    if self.decodeRun == 1 {
                        var buffer = context.channel.allocator.buffer(capacity: 1)
                        buffer.writeStaticString("X")
                        XCTAssertNoThrow(try (context.channel as! EmbeddedChannel).writeInbound(buffer))
                    }
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                while case .continue = try self.decode(context: context, buffer: &buffer) {}
                return .needMoreData
            }
        }

        class CheckStateOfDecoderHandler: ChannelOutboundHandler {
            typealias OutboundIn = String
            typealias OutboundOut = String

            private let decoder: Decoder

            init(decoder: Decoder) {
                self.decoder = decoder
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let string = self.unwrapOutboundIn(data)
                context.write(self.wrapOutboundOut("\(string) @ \(decoder.decodeRun)"), promise: promise)
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.pipeline.addHandler(CheckStateOfDecoderHandler(decoder: decoder), position: .first).wait())
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 3)
        XCTAssertNoThrow(try channel.writeOutbound("before"))
        buffer.writeStaticString("ab")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("xyz")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.writeOutbound("after"))
        XCTAssertEqual(["before", "O: 1: a", "O: 2: b", "O: 3: X", "O: 4: x", "O: 5: y", "O: 6: z", "after"],
                       decoder.allObservedWrites)
        XCTAssertEqual("I: 1: a", channel.readInbound())
        XCTAssertEqual("I: 2: b", channel.readInbound())
        XCTAssertEqual("I: 3: X", channel.readInbound())
        XCTAssertEqual("I: 4: x", channel.readInbound())
        XCTAssertEqual("I: 5: y", channel.readInbound())
        XCTAssertEqual("I: 6: z", channel.readInbound())
        XCTAssertNil(channel.readInbound())
        XCTAssertEqual("before @ 0", channel.readOutbound())
        // in the next line, it's important that it ends in '@ 1' because that means the outbound write was forwarded
        // when the Decoder was after decode run 1, ie. before it ever saw the 'b'. It's important we forward writes
        // as soon as possible for correctness but also to keep as few queued writes as possible.
        XCTAssertEqual("O: 1: a @ 1", channel.readOutbound())
        XCTAssertEqual("O: 2: b @ 2", channel.readOutbound())
        XCTAssertEqual("O: 3: X @ 3", channel.readOutbound())
        XCTAssertEqual("O: 4: x @ 4", channel.readOutbound())
        XCTAssertEqual("O: 5: y @ 5", channel.readOutbound())
        XCTAssertEqual("O: 6: z @ 6", channel.readOutbound())
        XCTAssertEqual("after @ 6", channel.readOutbound())
        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))
    }

    func testDecodeMethodsNoLongerCalledIfErrorInDecode() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            struct DecodeError: Error {}

            private var errorThrownAlready = false

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTAssertFalse(self.errorThrownAlready)
                self.errorThrownAlready = true
                throw DecodeError()
            }

            func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTFail("decodeLast should never be called")
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 1)
        buffer.writeString("x")
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssert(error is Decoder.DecodeError)
        }
        XCTAssertNil(channel.readInbound())

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            if case .some(ByteToMessageDecoderError.dataReceivedInErrorState(let error, let receivedBuffer)) =
                error as? ByteToMessageDecoderError {
                XCTAssert(error is Decoder.DecodeError)
                XCTAssertEqual(buffer, receivedBuffer)
            } else {
                XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertNil(channel.readInbound())

        XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))
    }

    func testDecodeMethodsNoLongerCalledIfErrorInDecodeLast() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            struct DecodeError: Error {}

            private var errorThrownAlready = false
            private var decodeCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.decodeCalls += 1
                XCTAssertEqual(1, self.decodeCalls)
                return .needMoreData
            }

            func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
                XCTAssertFalse(self.errorThrownAlready)
                self.errorThrownAlready = true
                throw DecodeError()
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 1)
        buffer.writeString("x")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNil(channel.readInbound())

        XCTAssertThrowsError(try channel.finish()) { error in
            XCTAssert(error is Decoder.DecodeError)
        }
        XCTAssertNil(channel.readInbound())

        XCTAssertNoThrow(try channel.writeInbound(buffer)) // this will go through because the decoder is already 'done'
    }
}

public class MessageToByteEncoderTest: XCTestCase {

    private final class Int32ToByteEncoder : MessageToByteEncoder {
        typealias OutboundIn = Int32
        typealias OutboundOut = ByteBuffer

        public func encode(context: ChannelHandlerContext, data value: Int32, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, out.writableBytes)
            out.writeInteger(value)
        }

        public func allocateOutBuffer(context: ChannelHandlerContext, data: Int32) throws -> ByteBuffer {
            return context.channel.allocator.buffer(capacity: MemoryLayout<Int32>.size)
        }
    }

    private final class Int32ToByteEncoderWithDefaultImpl : MessageToByteEncoder {
        typealias OutboundIn = Int32
        typealias OutboundOut = ByteBuffer

        public func encode(context: ChannelHandlerContext, data value: Int32, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, 256)
            out.writeInteger(value)
        }
    }

    func testEncoderOverrideAllocateOutBuffer() throws {
        try testEncoder(Int32ToByteEncoder())
    }

    func testEncoder() throws {
        try testEncoder(Int32ToByteEncoderWithDefaultImpl())
    }

    private func testEncoder(_ handler: ChannelHandler) throws {
        let channel = EmbeddedChannel()

        _ = try channel.pipeline.addHandler(Int32ToByteEncoder()).wait()

        _ = try channel.writeAndFlush(NIOAny(Int32(5))).wait()

        if var buffer = channel.readOutbound(as: ByteBuffer.self) {
            XCTAssertEqual(Int32(5), buffer.readInteger())
            XCTAssertEqual(0, buffer.readableBytes)
        } else {
            XCTFail("couldn't read ByteBuffer from channel")
        }

        XCTAssertFalse(try channel.finish())

    }
}

private class PairOfBytesDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    private let lastPromise: EventLoopPromise<ByteBuffer>
    var decodeLastCalls = 0

    init(lastPromise: EventLoopPromise<ByteBuffer>) {
        self.lastPromise = lastPromise
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let slice = buffer.readSlice(length: 2) {
            context.fireChannelRead(self.wrapInboundOut(slice))
            return .continue
        } else {
            return .needMoreData
        }
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        self.decodeLastCalls += 1
        XCTAssertEqual(1, self.decodeLastCalls)
        self.lastPromise.succeed(buffer)
        return .needMoreData
    }
}
