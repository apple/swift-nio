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
import NIOEmbedded
import XCTest

@testable import NIOCore
@testable import NIOPosix

private let testDecoderIsNotQuadratic_mallocs = NIOLockedValueBox(0)
private let testDecoderIsNotQuadratic_reallocs = NIOLockedValueBox(0)
private func testDecoderIsNotQuadratic_freeHook(_ ptr: UnsafeMutableRawPointer) {
    free(ptr)
}

private func testDecoderIsNotQuadratic_mallocHook(_ size: Int) -> UnsafeMutableRawPointer? {
    testDecoderIsNotQuadratic_mallocs.withLockedValue { $0 += 1 }
    return malloc(size)
}

private func testDecoderIsNotQuadratic_reallocHook(
    _ ptr: UnsafeMutableRawPointer?,
    _ count: Int
) -> UnsafeMutableRawPointer? {
    testDecoderIsNotQuadratic_reallocs.withLockedValue { $0 += 1 }
    return realloc(ptr, count)
}

private func testDecoderIsNotQuadratic_memcpyHook(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int)
{
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

final class ByteToMessageDecoderTest: XCTestCase {
    private final class ByteToInt32Decoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Int32

        func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            guard buffer.readableBytes >= MemoryLayout<Int32>.size else {
                return .needMoreData
            }
            context.fireChannelRead(Self.wrapInboundOut(buffer.readInteger()!))
            return .continue
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState
        {
            XCTAssertTrue(seenEOF)
            return self.decode(context: context, buffer: &buffer)
        }
    }

    private final class ForeverDecoder: ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Never

        func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
            .needMoreData
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState
        {
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

            context.fireChannelRead(Self.wrapInboundOut(buffer))
            return .continue
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState
        {
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

            context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: 2048)!))
            return .continue
        }

        func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState
        {
            XCTAssertTrue(seenEOF)
            return self.decode(context: context, buffer: &buffer)
        }
    }

    func testDecoder() throws {
        let channel = EmbeddedChannel()

        _ = try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ByteToInt32Decoder()))

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.writeInteger(Int32(1))
        let writerIndex = buffer.writerIndex
        buffer.moveWriterIndex(to: writerIndex - 1)

        channel.pipeline.fireChannelRead(buffer)
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        buffer.moveWriterIndex(to: writerIndex)
        channel.pipeline.fireChannelRead(buffer.getSlice(at: writerIndex - 1, length: 1)!)

        var buffer2 = channel.allocator.buffer(capacity: 32)
        buffer2.writeInteger(Int32(2))
        buffer2.writeInteger(Int32(3))
        channel.pipeline.fireChannelRead(buffer2)

        XCTAssertNoThrow(try channel.finish())

        XCTAssertNoThrow(XCTAssertEqual(Int32(1), try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(Int32(2), try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(Int32(3), try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testDecoderPropagatesChannelInactive() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        let inactivePromiser = ChannelInactivePromiser(channel: channel)
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ByteToInt32Decoder()))
        try channel.pipeline.syncOperations.addHandler(inactivePromiser)

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.writeInteger(Int32(1))
        channel.pipeline.fireChannelRead(buffer)
        XCTAssertNoThrow(XCTAssertEqual(Int32(1), try channel.readInbound()))

        XCTAssertFalse(inactivePromiser.channelInactivePromise.futureResult.isFulfilled)

        channel.pipeline.fireChannelInactive()
        XCTAssertTrue(inactivePromiser.channelInactivePromise.futureResult.isFulfilled)
    }

    func testDecoderIsNotQuadratic() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        XCTAssertEqual(testDecoderIsNotQuadratic_mallocs.withLockedValue { $0 }, 0)
        XCTAssertEqual(testDecoderIsNotQuadratic_reallocs.withLockedValue { $0 }, 0)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ForeverDecoder())))

        let dummyAllocator = ByteBufferAllocator(
            hookedMalloc: testDecoderIsNotQuadratic_mallocHook,
            hookedRealloc: testDecoderIsNotQuadratic_reallocHook,
            hookedFree: testDecoderIsNotQuadratic_freeHook,
            hookedMemcpy: testDecoderIsNotQuadratic_memcpyHook
        )
        channel.allocator = dummyAllocator
        var inputBuffer = dummyAllocator.buffer(capacity: 8)
        inputBuffer.writeStaticString("whatwhat")

        for _ in 0..<10 {
            channel.pipeline.fireChannelRead(inputBuffer)
        }

        // We get one extra malloc the first time around the loop, when we have aliased the buffer. From then on it's
        // all reallocs of the underlying buffer.
        XCTAssertEqual(testDecoderIsNotQuadratic_mallocs.withLockedValue { $0 }, 2)
        XCTAssertEqual(testDecoderIsNotQuadratic_reallocs.withLockedValue { $0 }, 3)
    }

    func testMemoryIsReclaimedIfMostIsConsumed() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }

        let decoder = ByteToMessageHandler(LargeChunkDecoder())
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(decoder))

        // We're going to send in 513 bytes. This will cause a chunk to be passed on, and will leave
        // a 512-byte empty region in a byte buffer with a capacity of 1024 bytes. Since 512 empty
        // bytes are exactly 50% of the buffers capacity and not one tiny bit more, the empty space
        // will not be reclaimed.
        var buffer = channel.allocator.buffer(capacity: 513)
        buffer.writeBytes(Array(repeating: 0x04, count: 513))
        XCTAssertNoThrow(XCTAssertTrue(try channel.writeInbound(buffer).isFull))
        XCTAssertNoThrow(XCTAssertEqual(ByteBuffer(repeating: 0x04, count: 512), try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertEqual(decoder.cumulationBuffer!.capacity, 1024)
        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 1)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 512)

        // Next we're going to send in another 513 bytes. This will cause another chunk to be passed
        // into our decoder buffer, which has a capacity of 1024 bytes, before we pass in another
        // 513 bytes. Since we already have written to 513 bytes, there isn't enough space in the
        // buffer, which will cause a resize to a new underlying storage with 2048 bytes. Since the
        // `LargeChunkDecoder` has consumed another 512 bytes, there are now two bytes left to read
        // (513 + 513) - (512 + 512). The reader index is at 1024. The empty space has not been
        // reclaimed: While the capacity is more than 1024 bytes (2048 bytes), the reader index is
        // now at 1024. This means the buffer is exactly 50% consumed and not a tiny bit more, which
        // means no space will be reclaimed.
        XCTAssertNoThrow(XCTAssertTrue(try channel.writeInbound(buffer).isFull))
        XCTAssertNoThrow(XCTAssertEqual(ByteBuffer(repeating: 0x04, count: 512), try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertEqual(decoder.cumulationBuffer!.capacity, 2048)
        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 2)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 1024)

        // Finally we're going to send in another 513 bytes. This will cause another chunk to be
        // passed into our decoder buffer, which has a capacity of 2048 bytes. Since the buffer has
        // enough available space (1022 bytes) there will be no buffer resize before the decoding.
        // After the decoding of another 512 bytes, the buffer will have 1536 empty bytes
        // (3 * 512 bytes). This means that 75% of the buffer's capacity can now be reclaimed, which
        // will lead to a reclaim. The resulting buffer will have a capacity of 2048 bytes (based
        // on its previous growth), with 3 readable bytes remaining.
        XCTAssertNoThrow(XCTAssertTrue(try channel.writeInbound(buffer).isFull))
        XCTAssertNoThrow(XCTAssertEqual(ByteBuffer(repeating: 0x04, count: 512), try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertEqual(decoder.cumulationBuffer!.capacity, 2048)
        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 3)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 0)
    }

    func testMemoryIsReclaimedIfLotsIsAvailable() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }

        let decoder = ByteToMessageHandler(OnceDecoder())
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(decoder))

        // We're going to send in 5119 bytes. This will be held.
        var buffer = channel.allocator.buffer(capacity: 5119)
        buffer.writeBytes(Array(repeating: 0x04, count: 5119))
        XCTAssertNoThrow(XCTAssertTrue(try channel.writeInbound(buffer).isEmpty))

        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 5119)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 0)

        // Now we're going to send in one more byte. This will cause a chunk to be passed on,
        // shrinking the held memory to 3072 bytes. However, memory will be reclaimed.
        XCTAssertNoThrow(XCTAssertTrue(try channel.writeInbound(buffer.getSlice(at: 0, length: 1)).isFull))
        XCTAssertNoThrow(XCTAssertEqual(ByteBuffer(repeating: 0x04, count: 2048), try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertEqual(decoder.cumulationBuffer!.readableBytes, 3072)
        XCTAssertEqual(decoder.cumulationBuffer!.readerIndex, 0)
    }

    func testWeDoNotCallShouldReclaimMemoryAsLongAsWeContinue() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            var numberOfDecodeCalls = 0
            var numberOfShouldReclaimCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.numberOfDecodeCalls += 1

                guard
                    buffer.readSlice(
                        length: [
                            2048, 1024, 512, 256,
                            128, 64, .max,
                        ][self.numberOfDecodeCalls - 1]
                    ) != nil
                else {
                    return .needMoreData
                }

                XCTAssertEqual(0, self.numberOfShouldReclaimCalls)
                return .continue
            }

            func shouldReclaimBytes(buffer: ByteBuffer) -> Bool {
                XCTAssertEqual(7, self.numberOfDecodeCalls)
                XCTAssertEqual(64, buffer.readableBytes)
                self.numberOfShouldReclaimCalls += 1

                return false
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertEqual(64, buffer.readableBytes)
                XCTAssertTrue(seenEOF)
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }

        let buffer = ByteBuffer(repeating: 0, count: 4096)
        XCTAssertEqual(4096, buffer.storageCapacity)

        // We're sending 4096 bytes. The decoder will do:
        // 1. read 2048 -> .continue
        // 2. read 1024 -> .continue
        // 3. read 512 -> .continue
        // 4. read 256 -> .continue
        // 5. read 128 -> .continue
        // 6. read 64 -> .continue
        // 7. read Int.max -> .needMoreData
        //
        // So we're expecting 7 decode calls but only 1 call to shouldReclaimBytes (at the end).
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertEqual(7, decoder.numberOfDecodeCalls)
        XCTAssertEqual(1, decoder.numberOfShouldReclaimCalls)
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
                var reentrantWriteBuffer = context.channel.allocator.buffer(capacity: 1)
                if self.numberOfDecodeCalls == 2 {
                    // this is the first time, let's fireChannelRead
                    self.hasReentranced = true
                    reentrantWriteBuffer.clear()
                    reentrantWriteBuffer.writeStaticString("3")
                    context.channel.pipeline.syncOperations.fireChannelRead(Self.wrapInboundOut(reentrantWriteBuffer))
                }
                context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: 1)!))
                if self.numberOfDecodeCalls == 2 {
                    reentrantWriteBuffer.clear()
                    reentrantWriteBuffer.writeStaticString("4")
                    context.channel.pipeline.syncOperations.fireChannelRead(Self.wrapInboundOut(reentrantWriteBuffer))
                }
                return .continue
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                return .needMoreData
            }
        }

        let testDecoder = TestDecoder()

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(testDecoder)))

        var inputBuffer = channel.allocator.buffer(capacity: 4)
        // 1
        inputBuffer.writeStaticString("1")
        XCTAssertTrue(try channel.writeInbound(inputBuffer).isFull)
        inputBuffer.clear()

        // 2
        inputBuffer.writeStaticString("2")
        XCTAssertTrue(try channel.writeInbound(inputBuffer).isFull)
        inputBuffer.clear()

        // 3
        inputBuffer.writeStaticString("5")
        XCTAssertTrue(try channel.writeInbound(inputBuffer).isFull)
        inputBuffer.clear()

        func readOneInboundString() -> String {
            do {
                switch try channel.readInbound(as: ByteBuffer.self) {
                case .some(let buffer):
                    return String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self)
                case .none:
                    XCTFail("expected ByteBuffer found nothing")
                    return "no, error from \(#line)"
                }
            } catch {
                XCTFail("unexpected error: \(error)")
                return "no, error from \(#line)"
            }
        }

        channel.embeddedEventLoop.run()
        XCTAssertEqual("1", readOneInboundString())
        XCTAssertEqual("2", readOneInboundString())
        XCTAssertEqual("3", readOneInboundString())
        XCTAssertEqual("4", readOneInboundString())
        XCTAssertEqual("5", readOneInboundString())
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound(as: IOData.self)))
        XCTAssertTrue(testDecoder.hasReentranced)
    }

    func testTrivialDecoderDoesSensibleStuffWhenCloseInRead() {
        class HandItThroughDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            var decodeLastCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                let originalBuffer = buffer
                context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: buffer.readableBytes)!))
                if originalBuffer.readableBytesView.last == "0".utf8.last {
                    context.close().whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                }
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
        channel.embeddedEventLoop.run()
        XCTAssertFalse(channel.isActive)

        XCTAssertNoThrow(
            XCTAssertEqual(
                "1",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "23",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "4567890",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
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

        XCTAssertNoThrow(
            XCTAssertEqual(
                "12",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "34",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "56",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "78",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "90",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertNoThrow(
            XCTAssertEqual(
                "x",
                String(
                    decoding: try lastPromise.futureResult.wait().readableBytesView,
                    as: Unicode.UTF8.self
                )
            )
        )
    }

    func testRemovingHandlerMakesLeftoversAppearInDecodeLast() {
        let lastPromise = EmbeddedEventLoop().makePromise(of: ByteBuffer.self)
        let decoder = PairOfBytesDecoder(lastPromise: lastPromise)
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
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
            channel.pipeline.syncOperations.removeHandler(context: context)
        }.whenFailure { error in
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertNoThrow(
            XCTAssertEqual(
                "12",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "34",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "56",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "78",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "90",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
        channel.embeddedEventLoop.run()

        XCTAssertNoThrow(
            XCTAssertEqual(
                "x",
                String(
                    decoding: try lastPromise.futureResult.wait().readableBytesView,
                    as: Unicode.UTF8.self
                )
            )
        )
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testStructsWorkAsByteToMessageDecoders() {
        struct WantsOneThenTwoBytesDecoder: ByteToMessageDecoder {
            typealias InboundOut = Int

            var state: Int = 1

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if buffer.readSlice(length: self.state) != nil {
                    defer {
                        self.state += 1
                    }
                    context.fireChannelRead(Self.wrapInboundOut(self.state))
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                context.fireChannelRead(Self.wrapInboundOut(buffer.readableBytes * -1))
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

        XCTAssertNoThrow(XCTAssertEqual(1, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(2, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(3, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(4, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertNoThrow(try channel.close().wait())
        XCTAssertFalse(channel.isActive)

        XCTAssertNoThrow(XCTAssertEqual(-4, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
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
                        XCTAssertNoThrow(
                            try (context.channel as! EmbeddedChannel).writeInbound(slice.getSlice(at: i, length: 1))
                        )
                    }
                    context.fireChannelRead(
                        Self.wrapInboundOut(String(decoding: slice.readableBytesView, as: Unicode.UTF8.self))
                    )
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                return try self.decode(context: context, buffer: &buffer)
            }
        }
        let channel = EmbeddedChannel(
            handler: ByteToMessageHandler(ProcessAndReentrantylyProcessExponentiallyLessStuffDecoder())
        )
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdef")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertNoThrow(XCTAssertEqual("0123456789abcdef", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("01234567", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("0123", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("01", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("0", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testReentrantChannelCloseInChannelRead() {
        struct Take16BytesThenCloseAndPassOnDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let slice = buffer.readSlice(length: 16) {
                    context.fireChannelRead(Self.wrapInboundOut(slice))
                    context.channel.close().whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                context.fireChannelRead(Self.wrapInboundOut(buffer))
                return .needMoreData
            }
        }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(Take16BytesThenCloseAndPassOnDecoder()))
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdefQWER")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertNoThrow(
            XCTAssertEqual(
                "0123456789abcdef",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                "QWER",
                try channel.readInbound(as: ByteBuffer.self).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testHandlerRemoveInChannelRead() {
        struct Take16BytesThenCloseAndPassOnDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let slice = buffer.readSlice(length: 16) {
                    context.fireChannelRead(Self.wrapInboundOut(slice))
                    context.pipeline.syncOperations.removeHandler(context: context).whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertFalse(seenEOF)
                context.fireChannelRead(Self.wrapInboundOut(buffer))
                return .needMoreData
            }
        }
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(Take16BytesThenCloseAndPassOnDecoder()))
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdefQWER")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertEqual(
            "0123456789abcdef",
            (try channel.readInbound() as ByteBuffer?).map {
                String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
            }
        )
        channel.embeddedEventLoop.run()
        XCTAssertEqual(
            "QWER",
            (try channel.readInbound() as ByteBuffer?).map {
                String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
            }
        )
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testChannelCloseInChannelRead() {
        struct Take16BytesThenCloseAndPassOnDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                if let slice = buffer.readSlice(length: 16) {
                    context.fireChannelRead(Self.wrapInboundOut(slice))
                    context.close().whenFailure { error in
                        XCTFail("unexpected error: \(error)")
                    }
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            mutating func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(DoNotForwardChannelInactiveHandler(), position: .first)
        )
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456789abcdefQWER")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        XCTAssertNoThrow(
            XCTAssertEqual(
                "0123456789abcdef",
                (try channel.readInbound() as ByteBuffer?).map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
            )
        )
        channel.embeddedEventLoop.run()
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))  // no leftovers are forwarded
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
                context.fireChannelRead(
                    Self.wrapInboundOut(
                        String(
                            decoding: buffer.readBytes(length: 1)!,
                            as: Unicode.UTF8.self
                        )
                    )
                )
                context.pipeline.syncOperations.removeHandler(context: context).whenFailure { error in
                    XCTFail("unexpected error: \(error)")
                }
                return .continue
            }

            mutating func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertFalse(seenEOF)
                self.callsToDecodeLast += 1
                XCTAssertLessThanOrEqual(self.callsToDecodeLast, 2)
                context.fireChannelRead(
                    Self.wrapInboundOut(
                        String(
                            decoding: buffer.readBytes(length: 4) ?? [  // "no bytes"
                                0x6e, 0x6f, 0x20,
                                0x62, 0x79, 0x74, 0x65, 0x73,
                            ],
                            as: Unicode.UTF8.self
                        ) + "#\(self.callsToDecodeLast)"
                    )
                )
                return .continue
            }
        }

        let handler = ByteToMessageHandler(Decoder())
        let channel = EmbeddedChannel(handler: handler)
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }

        var buffer = channel.allocator.buffer(capacity: 9)
        buffer.writeStaticString("012345678")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        channel.embeddedEventLoop.run()
        XCTAssertEqual(1, handler.decoder?.callsToDecode)
        XCTAssertEqual(2, handler.decoder?.callsToDecodeLast)
        for expected in ["0", "1234#1", "5678#2"] {
            func workaroundSR9815() {
                XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readInbound()))
            }
            workaroundSR9815()
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

            public func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                self.decodeLastCalls += 1
                XCTAssertEqual(1, self.decodeLastCalls)
                XCTAssertEqual(0, buffer.readableBytes)
                context.fireChannelRead(Self.wrapInboundOut(()))
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))

        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertNoThrow(try channel.close().wait())
        XCTAssertNoThrow(XCTAssertNotNil(try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

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

            public func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertTrue(seenEOF)
                self.decodeLastCalls += 1
                XCTAssertEqual(1, self.decodeLastCalls)
                XCTAssertEqual(0, buffer.readableBytes)
                context.fireChannelRead(Self.wrapInboundOut(()))
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))

        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertNoThrow(XCTAssertNotNil(try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertEqual(1, decoder.decodeLastCalls)

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))

        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
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

            public func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
            channel.pipeline.syncOperations.removeHandler(context: $0)
        }
        channel.embeddedEventLoop.run()
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

            public func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
            channel.pipeline.syncOperations.removeHandler(context: $0)
        }
        channel.embeddedEventLoop.run()
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

            public func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
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
                    context.fireChannelRead(Self.wrapInboundOut(string))
                    return .continue
                } else {
                    return .needMoreData
                }
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
        XCTAssertNoThrow(XCTAssertEqual("a", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("b", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("c", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(1, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual(2, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual(3, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
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
                    context.fireChannelRead(Self.wrapInboundOut("I: \(self.decodeRun): \(string)"))
                    XCTAssertNoThrow(
                        try (context.channel as! EmbeddedChannel).writeOutbound("O: \(self.decodeRun): \(string)")
                    )
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

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
                let string = Self.unwrapOutboundIn(data)
                context.write(Self.wrapOutboundOut("\(string) @ \(decoder.decodeRun)"), promise: promise)
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                CheckStateOfDecoderHandler(decoder: decoder),
                position: .first
            )
        )
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 3)
        XCTAssertNoThrow(try channel.writeOutbound("before"))
        buffer.writeStaticString("ab")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        buffer.clear()
        buffer.writeStaticString("xyz")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.writeOutbound("after"))
        XCTAssertEqual(
            ["before", "O: 1: a", "O: 2: b", "O: 3: X", "O: 4: x", "O: 5: y", "O: 6: z", "after"],
            decoder.allObservedWrites
        )
        XCTAssertNoThrow(XCTAssertEqual("I: 1: a", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("I: 2: b", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("I: 3: X", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("I: 4: x", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("I: 5: y", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("I: 6: z", try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual("before @ 0", try channel.readOutbound()))
        // in the next line, it's important that it ends in '@ 1' because that means the outbound write was forwarded
        // when the Decoder was after decode run 1, ie. before it ever saw the 'b'. It's important we forward writes
        // as soon as possible for correctness but also to keep as few queued writes as possible.
        XCTAssertNoThrow(XCTAssertEqual("O: 1: a @ 1", try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual("O: 2: b @ 2", try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual("O: 3: X @ 3", try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual("O: 4: x @ 4", try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual("O: 5: y @ 5", try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual("O: 6: z @ 6", try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertEqual("after @ 6", try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
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

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            if case .some(ByteToMessageDecoderError.dataReceivedInErrorState(let error, let receivedBuffer)) =
                error as? ByteToMessageDecoderError
            {
                XCTAssert(error is Decoder.DecodeError)
                XCTAssertEqual(buffer, receivedBuffer)
            } else {
                XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
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

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
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
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertThrowsError(try channel.finish()) { error in
            XCTAssert(error is Decoder.DecodeError)
        }
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        // this will go through because the decoder is already 'done'
        XCTAssertNoThrow(try channel.writeInbound(buffer))
    }

    func testBasicLifecycle() {
        class Decoder: ByteToMessageDecoder {
            enum State {
                case constructed
                case added
                case decode
                case decodeLast
                case removed
            }
            var state = State.constructed

            typealias InboundOut = ()

            func decoderAdded(context: ChannelHandlerContext) {
                XCTAssertEqual(.constructed, self.state)
                self.state = .added
            }

            func decoderRemoved(context: ChannelHandlerContext) {
                XCTAssertEqual(.decodeLast, self.state)
                self.state = .removed
            }

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTAssertEqual(.added, self.state)
                XCTAssertEqual(1, buffer.readableBytes)
                self.state = .decode
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertEqual(.decode, self.state)
                XCTAssertEqual(1, buffer.readableBytes)
                self.state = .decodeLast
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 1)
        buffer.writeString("x")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.finish())
        XCTAssertEqual(.removed, decoder.state)
    }

    func testDecodeLoopStopsOnChannelInactive() {
        class CloseAfterThreeMessagesDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            var decodeCalls = 0
            var decodeLastCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.decodeCalls += 1
                XCTAssert(buffer.readableBytes > 0)
                context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: 1)!))
                if self.decodeCalls == 3 {
                    context.close(promise: nil)
                }
                return .continue
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                self.decodeLastCalls += 1
                if buffer.readableBytes > 0 {
                    context.fireErrorCaught(ByteToMessageDecoderError.leftoverDataWhenDone(buffer))
                }
                return .needMoreData
            }
        }

        let decoder = CloseAfterThreeMessagesDecoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        defer {
            XCTAssertFalse(channel.isActive)
        }
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456")
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            if case .some(.leftoverDataWhenDone(let buffer)) = error as? ByteToMessageDecoderError {
                XCTAssertEqual("3456", buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        for i in 0..<3 {
            buffer.clear()
            buffer.writeString("\(i)")
            XCTAssertNoThrow(XCTAssertEqual(buffer, try channel.readInbound(as: ByteBuffer.self)))
        }
        XCTAssertEqual(3, decoder.decodeCalls)
        XCTAssertEqual(1, decoder.decodeLastCalls)
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testDecodeLoopStopsOnInboundHalfClosure() {
        class CloseAfterThreeMessagesDecoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            var decodeCalls = 0
            var decodeLastCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.decodeCalls += 1
                XCTAssert(buffer.readableBytes > 0)
                context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: 1)!))
                if self.decodeCalls == 3 {
                    context.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                }
                return .continue
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                self.decodeLastCalls += 1
                if buffer.readableBytes > 0 {
                    context.fireErrorCaught(ByteToMessageDecoderError.leftoverDataWhenDone(buffer))
                }
                return .needMoreData
            }
        }

        let decoder = CloseAfterThreeMessagesDecoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("0123456")
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            if case .some(.leftoverDataWhenDone(let buffer)) = error as? ByteToMessageDecoderError {
                XCTAssertEqual("3456", buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        for i in 0..<3 {
            buffer.clear()
            buffer.writeString("\(i)")
            XCTAssertNoThrow(XCTAssertEqual(buffer, try channel.readInbound(as: ByteBuffer.self)))
        }
        XCTAssertEqual(3, decoder.decodeCalls)
        XCTAssertEqual(1, decoder.decodeLastCalls)
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testWeForwardReadEOFAndChannelInactive() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            var decodeLastCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTFail("should not have been called")
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                self.decodeLastCalls += 1
                XCTAssertEqual(self.decodeLastCalls, 1)
                XCTAssertTrue(seenEOF)
                XCTAssertEqual(0, buffer.readableBytes)
                return .needMoreData
            }
        }

        class CheckThingsAreOkayHandler: ChannelInboundHandler {
            typealias InboundIn = Never

            var readEOFEvents = 0
            var channelInactiveEvents = 0

            func channelInactive(context: ChannelHandlerContext) {
                self.channelInactiveEvents += 1
                XCTAssertEqual(1, self.channelInactiveEvents)
            }

            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                if let event = event as? ChannelEvent, event == .inputClosed {
                    self.readEOFEvents += 1
                    XCTAssertEqual(1, self.readEOFEvents)
                }
            }
        }

        let decoder = Decoder()
        let checker = CheckThingsAreOkayHandler()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(checker))
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait())
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertEqual(1, decoder.decodeLastCalls)
        XCTAssertEqual(0, checker.channelInactiveEvents)
        XCTAssertEqual(1, checker.readEOFEvents)
        XCTAssertNoThrow(try channel.pipeline.close().wait())
        XCTAssertEqual(1, decoder.decodeLastCalls)
        XCTAssertEqual(1, checker.channelInactiveEvents)
        XCTAssertEqual(1, checker.readEOFEvents)
    }

    func testErrorInDecodeLastWhenCloseIsReceivedReentrantlyInDecode() {
        struct DummyError: Error {}
        struct Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                // simulate a re-entrant trigger of reading EOF
                context.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertEqual("X", buffer.readString(length: buffer.readableBytes))
                throw DummyError()
            }
        }

        let channel = EmbeddedChannel(handler: ByteToMessageHandler(Decoder()))
        var buffer = channel.allocator.buffer(capacity: 1)
        buffer.writeString("X")
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertTrue(error is DummyError)
        }
    }

    func testWeAreOkayWithReceivingDataAfterHalfClosureEOF() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            var decodeCalls = 0
            var decodeLastCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.decodeCalls += 1
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                self.decodeLastCalls += 1
                return .needMoreData
            }
        }

        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("abc")

        XCTAssertEqual(0, decoder.decodeCalls)
        XCTAssertEqual(0, decoder.decodeLastCalls)
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertEqual(1, decoder.decodeCalls)
        XCTAssertEqual(0, decoder.decodeLastCalls)
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertEqual(1, decoder.decodeCalls)
        XCTAssertEqual(1, decoder.decodeLastCalls)
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertEqual(1, decoder.decodeCalls)
        XCTAssertEqual(1, decoder.decodeLastCalls)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testWeAreOkayWithReceivingDataAfterFullClose() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            var decodeCalls = 0
            var decodeLastCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.decodeCalls += 1
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                self.decodeLastCalls += 1
                return .needMoreData
            }
        }
        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("abc")

        XCTAssertEqual(0, decoder.decodeCalls)
        XCTAssertEqual(0, decoder.decodeLastCalls)
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertEqual(1, decoder.decodeCalls)
        XCTAssertEqual(0, decoder.decodeLastCalls)
        XCTAssertTrue(try channel.finish().isClean)
        XCTAssertEqual(1, decoder.decodeCalls)
        XCTAssertEqual(1, decoder.decodeLastCalls)
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertEqual(1, decoder.decodeCalls)
        XCTAssertEqual(1, decoder.decodeLastCalls)
    }

    func testPayloadTooLarge() {
        struct Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                .needMoreData
            }
        }

        let max = 100
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(Decoder(), maximumBufferSize: max))
        var buffer = channel.allocator.buffer(capacity: max + 1)
        buffer.writeString(String(repeating: "*", count: max + 1))
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertTrue(error is ByteToMessageDecoderError.PayloadTooLargeError)
        }
    }

    func testPayloadTooLargeButHandlerOk() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = ByteBuffer

            var decodeCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                self.decodeCalls += 1
                buffer.moveReaderIndex(to: buffer.readableBytes)
                return .continue
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                self.decodeCalls += 1
                buffer.moveReaderIndex(to: buffer.readableBytes)
                return .continue
            }
        }

        let max = 100
        let decoder = Decoder()
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder, maximumBufferSize: max))
        var buffer = channel.allocator.buffer(capacity: max + 1)
        buffer.writeString(String(repeating: "*", count: max + 1))
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        XCTAssertGreaterThan(decoder.decodeCalls, 0)
    }

    func testRemoveHandlerBecauseOfChannelTearDownWhilstUserTriggeredRemovalIsInProgress() {
        class Decoder: ByteToMessageDecoder {
            typealias InboundOut = Never

            var removedCalls = 0

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                XCTFail("\(#function) should never have been called")
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                XCTAssertEqual(0, buffer.readableBytes)
                XCTAssertTrue(seenEOF)
                return .needMoreData
            }

            func decoderRemoved(context: ChannelHandlerContext) {
                self.removedCalls += 1
                XCTAssertEqual(1, self.removedCalls)
            }
        }

        let decoder = Decoder()
        let decoderHandler = ByteToMessageHandler(decoder)
        let channel = EmbeddedChannel(handler: decoderHandler)

        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())

        // We are now trying to get the channel into the following states (ordered by time):
        // 1. user-triggered removal is in progress (started but not completed)
        // 2. `removeHandlers()` as part of the Channel teardown is called
        // 3. user-triggered removal completes
        //
        // The way we can get into this situation might be slightly counter-intuitive but currently, the easiest way
        // to trigger this is:
        // 1. `channel.close()` (because `removeHandlers()` is called inside an `eventLoop.execute` so is delayed
        // 2. user-triggered removal start (`channel.pipeline.removeHandler`) which will also use an
        //    `eventLoop.execute` to ask for the handler to actually be removed.
        // 3. run the event loop (this will now first call `removeHandlers()` which completes the channel tear down
        //    and a little later will complete the user-triggered removal.

        let closeFuture = channel.close()  // close the channel, `removeHandlers` will be called in next EL tick.

        // user-trigger the handler removal (the actual removal will be done on the next EL tick too)
        let removalFuture = channel.pipeline.syncOperations.removeHandler(decoderHandler)

        // run the event loop, this will make `removeHandlers` run first because it was enqueued before the
        // user-triggered handler removal
        channel.embeddedEventLoop.run()

        // just to make sure everything has completed.
        XCTAssertNoThrow(try closeFuture.wait())
        XCTAssertNoThrow(try removalFuture.wait())

        XCTAssertThrowsError(try channel.finish()) { error in
            XCTAssertEqual(ChannelError.alreadyClosed, error as? ChannelError)
        }
    }
}

final class MessageToByteEncoderTest: XCTestCase {
    private struct Int32ToByteEncoder: MessageToByteEncoder {
        typealias OutboundIn = Int32

        public func encode(data value: Int32, out: inout ByteBuffer) throws {
            out.writeInteger(value)
        }
    }

    private final class Int32ToByteEncoderWithDefaultImpl: MessageToByteEncoder {
        typealias OutboundIn = Int32

        public func encode(data value: Int32, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, 256)
            out.writeInteger(value)
        }
    }

    func testEncoderOverrideAllocateOutBuffer() throws {
        try testEncoder(MessageToByteHandler(Int32ToByteEncoder()))
    }

    func testEncoder() throws {
        try testEncoder(MessageToByteHandler(Int32ToByteEncoderWithDefaultImpl()))
    }

    private func testEncoder(_ handler: ChannelHandler, file: StaticString = #filePath, line: UInt = #line) throws {
        let channel = EmbeddedChannel()

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(Int32ToByteEncoder())),
            file: (file),
            line: line
        )

        XCTAssertNoThrow(try channel.writeAndFlush(Int32(5)).wait(), file: (file), line: line)

        if var buffer = try channel.readOutbound(as: ByteBuffer.self) {
            XCTAssertEqual(Int32(5), buffer.readInteger())
            XCTAssertEqual(0, buffer.readableBytes)
        } else {
            XCTFail("couldn't read ByteBuffer from channel")
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testB2MHIsHappyNeverBeingAddedToAPipeline() {
        @inline(never)
        func createAndReleaseIt() {
            struct Decoder: ByteToMessageDecoder {
                typealias InboundOut = Never

                func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                    XCTFail()
                    return .needMoreData
                }

                func decodeLast(
                    context: ChannelHandlerContext,
                    buffer: inout ByteBuffer,
                    seenEOF: Bool
                ) throws -> DecodingState {
                    XCTFail()
                    return .needMoreData
                }
            }
            _ = ByteToMessageHandler(Decoder())
        }
        createAndReleaseIt()
    }

    func testM2BHIsHappyNeverBeingAddedToAPipeline() {
        @inline(never)
        func createAndReleaseIt() {
            struct Encoder: MessageToByteEncoder {
                typealias OutboundIn = Void

                func encode(data: Void, out: inout ByteBuffer) throws {
                    XCTFail()
                }
            }
            _ = MessageToByteHandler(Encoder())
        }
        createAndReleaseIt()
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
            context.fireChannelRead(Self.wrapInboundOut(slice))
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

final class MessageToByteHandlerTest: XCTestCase {
    private struct ThrowingMessageToByteEncoder: MessageToByteEncoder {
        private struct HandlerError: Error {}

        typealias OutboundIn = Int

        public func encode(data value: Int, out: inout ByteBuffer) throws {
            if value == 0 {
                out.writeInteger(value)
            } else {
                throw HandlerError()
            }
        }
    }

    func testThrowingEncoderFailsPromises() {
        let channel = EmbeddedChannel()

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(ThrowingMessageToByteEncoder()))
        )

        XCTAssertNoThrow(try channel.writeAndFlush(0).wait())

        XCTAssertThrowsError(try channel.writeAndFlush(1).wait())

        XCTAssertThrowsError(try channel.writeAndFlush(0).wait())
    }
}
