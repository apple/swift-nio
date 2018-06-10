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
        channelInactivePromise = channel.eventLoop.newPromise()
    }

    func channelInactive(ctx: ChannelHandlerContext) {
        channelInactivePromise.succeed(result: ())
    }
}

public class ByteToMessageDecoderTest: XCTestCase {
    private final class ByteToInt32Decoder : ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Int32

        var cumulationBuffer: ByteBuffer?


        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            guard buffer.readableBytes >= MemoryLayout<Int32>.size else {
                return .needMoreData
            }
            ctx.fireChannelRead(self.wrapInboundOut(buffer.readInteger()!))
            return .continue
        }
    }

    private final class ForeverDecoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Never

        var cumulationBuffer: ByteBuffer?

        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            return .needMoreData
        }
    }

    private final class LargeChunkDecoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer

        var cumulationBuffer: ByteBuffer?

        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            guard case .some(let buffer) = buffer.readSlice(length: 512) else {
                return .needMoreData
            }

            ctx.fireChannelRead(self.wrapInboundOut(buffer))
            return .continue
        }
    }

    // A special case decoder that decodes only once there is 5,120 bytes in the buffer,
    // at which point it decodes exactly 2kB of memory.
    private final class OnceDecoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer

        var cumulationBuffer: ByteBuffer?

        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            guard buffer.readableBytes >= 5120 else {
                return .needMoreData
            }

            ctx.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: 2048)!))
            return .continue
        }
    }

    func testDecoder() throws {
        let channel = EmbeddedChannel()

        _ = try channel.pipeline.add(handler: ByteToInt32Decoder()).wait()

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.write(integer: Int32(1))
        let writerIndex = buffer.writerIndex
        buffer.moveWriterIndex(to: writerIndex - 1)

        channel.pipeline.fireChannelRead(NIOAny(buffer))
        XCTAssertNil(channel.readInbound())

        channel.pipeline.fireChannelRead(NIOAny(buffer.getSlice(at: writerIndex - 1, length: 1)!))

        var buffer2 = channel.allocator.buffer(capacity: 32)
        buffer2.write(integer: Int32(2))
        buffer2.write(integer: Int32(3))
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
        _ = try channel.pipeline.add(handler: ByteToInt32Decoder()).wait()
        _ = try channel.pipeline.add(handler: inactivePromiser).wait()

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.write(integer: Int32(1))
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
        XCTAssertNoThrow(try channel.pipeline.add(handler: ForeverDecoder()).wait())

        let dummyAllocator = ByteBufferAllocator(hookedMalloc: testDecoderIsNotQuadratic_mallocHook,
                                                 hookedRealloc: testDecoderIsNotQuadratic_reallocHook,
                                                 hookedFree: testDecoderIsNotQuadratic_freeHook,
                                                 hookedMemcpy: testDecoderIsNotQuadratic_memcpyHook)
        channel.allocator = dummyAllocator
        var inputBuffer = dummyAllocator.buffer(capacity: 8)
        inputBuffer.write(staticString: "whatwhat")

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

        let decoder = LargeChunkDecoder()
        _ = try channel.pipeline.add(handler: decoder).wait()

        // We're going to send in 513 bytes. This will cause a chunk to be passed on, and will leave
        // a 512-byte empty region in a 513 byte buffer. This will not cause a shrink.
        var buffer = channel.allocator.buffer(capacity: 513)
        buffer.write(bytes: Array(repeating: 0x04, count: 513))
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

        let decoder = OnceDecoder()
        _ = try channel.pipeline.add(handler: decoder).wait()

        // We're going to send in 5119 bytes. This will be held.
        var buffer = channel.allocator.buffer(capacity: 5119)
        buffer.write(bytes: Array(repeating: 0x04, count: 5119))
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

            var cumulationBuffer: ByteBuffer?
            var reentranced: Bool = false
            var decode: Bool = false

            func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                guard !self.decode else {
                    self.reentranced = true
                    return .needMoreData
                }
                self.decode = true
                defer {
                    self.decode = false
                }

                if !self.reentranced {
                    ctx.channel.pipeline.fireChannelRead(self.wrapInboundOut(buffer))
                }
                ctx.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: 2)!))
                return .continue
            }
        }

        XCTAssertNoThrow(try channel.pipeline.add(handler: TestDecoder()).wait())

        var inputBuffer = channel.allocator.buffer(capacity: 4)
        inputBuffer.write(staticString: "xxxx")
        XCTAssertTrue(try channel.writeInbound(inputBuffer))

        let buffer = inputBuffer.readSlice(length: 2)!
        XCTAssertEqual(buffer, channel.readInbound())
        XCTAssertEqual(buffer, channel.readInbound())
        XCTAssertEqual(buffer, channel.readInbound())
        XCTAssertEqual(buffer, channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }

    func testDecoderWriteIntoCumulationBuffer() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        class WriteDecoder: ByteToMessageDecoder {

            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            var cumulationBuffer: ByteBuffer?

            func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTAssertTrue(buffer.readableBytes <= 4)

                ctx.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: 2)!))

                if buffer.readableBytes > 0 {
                    // This should not be visible anymore after we exit the method which also means we should never see more then 4 readableBytes.
                    buffer.set(integer: UInt(0), at: buffer.readerIndex)
                    XCTAssertEqual(UInt(0), buffer.getInteger(at: buffer.readerIndex))
                }

                return .continue
            }
        }

        XCTAssertNoThrow(try channel.pipeline.add(handler: WriteDecoder()).wait())

        var inputBuffer = channel.allocator.buffer(capacity: 4)
        inputBuffer.write(staticString: "xxxx")
        XCTAssertTrue(try channel.writeInbound(inputBuffer))

        let buffer = inputBuffer.readSlice(length: 2)!
        XCTAssertEqual(buffer, channel.readInbound())
        XCTAssertEqual(buffer, channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }
}

public class MessageToByteEncoderTest: XCTestCase {

    private final class Int32ToByteEncoder : MessageToByteEncoder {
        typealias OutboundIn = Int32
        typealias OutboundOut = ByteBuffer

        public func encode(ctx: ChannelHandlerContext, data value: Int32, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, out.writableBytes)
            out.write(integer: value)
        }

        public func allocateOutBuffer(ctx: ChannelHandlerContext, data: Int32) throws -> ByteBuffer {
            return ctx.channel.allocator.buffer(capacity: MemoryLayout<Int32>.size)
        }
    }

    private final class Int32ToByteEncoderWithDefaultImpl : MessageToByteEncoder {
        typealias OutboundIn = Int32
        typealias OutboundOut = ByteBuffer

        public func encode(ctx: ChannelHandlerContext, data value: Int32, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, 256)
            out.write(integer: value)
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

        _ = try channel.pipeline.add(handler: Int32ToByteEncoder()).wait()

        _ = try channel.writeAndFlush(NIOAny(Int32(5))).wait()

        if case .some(.byteBuffer(var buffer)) = channel.readOutbound() {
            XCTAssertEqual(Int32(5), buffer.readInteger())
            XCTAssertEqual(0, buffer.readableBytes)
        } else {
            XCTFail("couldn't read ByteBuffer from channel")
        }

        XCTAssertFalse(try channel.finish())

    }
}
