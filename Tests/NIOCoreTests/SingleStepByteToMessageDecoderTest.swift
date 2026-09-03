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

import NIOEmbedded
import Testing

@testable import NIOCore

struct NIOSingleStepByteToMessageDecoderTests {
    private final class ByteToInt32Decoder: NIOSingleStepByteToMessageDecoder {
        typealias InboundOut = Int32

        func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
            buffer.readInteger()
        }

        func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
            #expect(seenEOF)
            return try self.decode(buffer: &buffer)
        }
    }

    private final class LargeChunkDecoder: NIOSingleStepByteToMessageDecoder {
        typealias InboundOut = ByteBuffer

        func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
            buffer.readSlice(length: 512)
        }

        func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
            #expect(!seenEOF)
            return try self.decode(buffer: &buffer)
        }
    }

    // A special case decoder that decodes only once there is 5,120 bytes in the buffer,
    // at which point it decodes exactly 2kB of memory.
    private final class OnceDecoder: NIOSingleStepByteToMessageDecoder {
        typealias InboundOut = ByteBuffer

        func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
            guard buffer.readableBytes >= 5120 else {
                return nil
            }

            return buffer.readSlice(length: 2048)!
        }

        func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
            #expect(!seenEOF)
            return try self.decode(buffer: &buffer)
        }
    }

    private final class PairOfBytesDecoder: NIOSingleStepByteToMessageDecoder {
        typealias InboundOut = ByteBuffer

        var decodeLastCalls = 0
        var lastBuffer: ByteBuffer?

        func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
            buffer.readSlice(length: 2)
        }

        func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
            self.decodeLastCalls += 1
            #expect(1 == self.decodeLastCalls)
            self.lastBuffer = buffer
            return nil
        }
    }

    private final class MessageReceiver<InboundOut> {
        var messages: CircularBuffer<InboundOut> = CircularBuffer()

        func receiveMessage(message: InboundOut) {
            messages.append(message)
        }

        var count: Int { messages.count }

        func retrieveMessage() -> InboundOut? {
            if messages.isEmpty {
                return nil
            }
            return messages.removeFirst()
        }
    }

    @Test func decoder() throws {
        let allocator = ByteBufferAllocator()
        let processor = NIOSingleStepByteToMessageProcessor(ByteToInt32Decoder())
        let messageReceiver: MessageReceiver<Int32> = MessageReceiver()

        var buffer = allocator.buffer(capacity: 32)
        buffer.writeInteger(Int32(1))
        let writerIndex = buffer.writerIndex
        buffer.moveWriterIndex(to: writerIndex - 1)

        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(messageReceiver.retrieveMessage() == nil)

        buffer.moveWriterIndex(to: writerIndex)
        try processor.process(
            buffer: buffer.getSlice(at: writerIndex - 1, length: 1)!,
            messageReceiver.receiveMessage
        )

        var buffer2 = allocator.buffer(capacity: 32)
        buffer2.writeInteger(Int32(2))
        buffer2.writeInteger(Int32(3))
        #expect(throws: Never.self) { try processor.process(buffer: buffer2, messageReceiver.receiveMessage) }

        #expect(throws: Never.self) { try processor.finishProcessing(seenEOF: true, messageReceiver.receiveMessage) }

        #expect(Int32(1) == messageReceiver.retrieveMessage())
        #expect(Int32(2) == messageReceiver.retrieveMessage())
        #expect(Int32(3) == messageReceiver.retrieveMessage())
        #expect(messageReceiver.retrieveMessage() == nil)
    }

    @Test func memoryIsReclaimedIfMostIsConsumed() {
        let allocator = ByteBufferAllocator()
        let processor = NIOSingleStepByteToMessageProcessor(LargeChunkDecoder())
        let messageReceiver: MessageReceiver<ByteBuffer> = MessageReceiver()
        defer {
            #expect(throws: Never.self) {
                try processor.finishProcessing(seenEOF: false, messageReceiver.receiveMessage)
            }
        }

        // We're going to send in 513 bytes. This will cause a chunk to be passed on, and will leave
        // a 512-byte empty region in a byte buffer with a capacity of 1024 bytes. Since 512 empty
        // bytes are exactly 50% of the buffers capacity and not one tiny bit more, the empty space
        // will not be reclaimed.
        var buffer = allocator.buffer(capacity: 513)
        buffer.writeBytes(Array(repeating: 0x04, count: 513))
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }

        #expect(512 == messageReceiver.retrieveMessage()!.readableBytes)

        #expect(processor._buffer!.capacity == 1024)
        #expect(1 == processor._buffer!.readableBytes)
        #expect(512 == processor._buffer!.readerIndex)

        // Next we're going to send in another 513 bytes. This will cause another chunk to be passed
        // into our decoder buffer, which has a capacity of 1024 bytes, before we pass in another
        // 513 bytes. Since we already have written to 513 bytes, there isn't enough space in the
        // buffer, which will cause a resize to a new underlying storage with 2048 bytes. Since the
        // `LargeChunkDecoder` has consumed another 512 bytes, there are now two bytes left to read
        // (513 + 513) - (512 + 512). The reader index is at 1024. The empty space has not been
        // reclaimed: While the capacity is more than 1024 bytes (2048 bytes), the reader index is
        // now at 1024. This means the buffer is exactly 50% consumed and not a tiny bit more, which
        // means no space will be reclaimed.
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(512 == messageReceiver.retrieveMessage()!.readableBytes)

        #expect(processor._buffer!.capacity == 2048)
        #expect(2 == processor._buffer!.readableBytes)
        #expect(1024 == processor._buffer!.readerIndex)

        // Finally we're going to send in another 513 bytes. This will cause another chunk to be
        // passed into our decoder buffer, which has a capacity of 2048 bytes. Since the buffer has
        // enough available space (1022 bytes) there will be no buffer resize before the decoding.
        // After the decoding of another 512 bytes, the buffer will have 1536 empty bytes
        // (3 * 512 bytes). This means that 75% of the buffer's capacity can now be reclaimed, which
        // will lead to a reclaim. The resulting buffer will have a capacity of 2048 bytes (based
        // on its previous growth), with 3 readable bytes remaining.

        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(512 == messageReceiver.retrieveMessage()!.readableBytes)

        #expect(processor._buffer!.capacity == 2048)
        #expect(3 == processor._buffer!.readableBytes)
        #expect(0 == processor._buffer!.readerIndex)
    }

    @Test func memoryIsReclaimedIfLotsIsAvailable() {
        let allocator = ByteBufferAllocator()
        let processor = NIOSingleStepByteToMessageProcessor(OnceDecoder())
        let messageReceiver: MessageReceiver<ByteBuffer> = MessageReceiver()
        defer {
            #expect(throws: Never.self) {
                try processor.finishProcessing(seenEOF: false, messageReceiver.receiveMessage)
            }
        }

        // We're going to send in 5119 bytes. This will be held.
        var buffer = allocator.buffer(capacity: 5119)
        buffer.writeBytes(Array(repeating: 0x04, count: 5119))
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(0 == messageReceiver.count)

        #expect(5119 == processor._buffer!.readableBytes)
        #expect(0 == processor._buffer!.readerIndex)

        // Now we're going to send in one more byte. This will cause a chunk to be passed on,
        // shrinking the held memory to 3072 bytes. However, memory will be reclaimed.
        #expect(throws: Never.self) {
            try processor.process(buffer: buffer.getSlice(at: 0, length: 1)!, messageReceiver.receiveMessage)
        }
        #expect(2048 == messageReceiver.retrieveMessage()!.readableBytes)
        #expect(3072 == processor._buffer!.readableBytes)
        #expect(0 == processor._buffer!.readerIndex)
    }

    @Test func leftOversMakeDecodeLastCalled() {
        let allocator = ByteBufferAllocator()
        let decoder = PairOfBytesDecoder()
        let processor = NIOSingleStepByteToMessageProcessor(decoder)
        let messageReceiver: MessageReceiver<ByteBuffer> = MessageReceiver()

        var buffer = allocator.buffer(capacity: 16)
        buffer.clear()
        buffer.writeStaticString("1")
        #expect(processor.unprocessedBytes == 0)
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(processor.unprocessedBytes == 1)
        buffer.clear()
        buffer.writeStaticString("23")
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(processor.unprocessedBytes == 1)
        buffer.clear()
        buffer.writeStaticString("4567890x")
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(processor.unprocessedBytes == 1)
        #expect(throws: Never.self) { try processor.finishProcessing(seenEOF: false, messageReceiver.receiveMessage) }
        #expect(processor.unprocessedBytes == 1)

        #expect(
            "12"
                == messageReceiver.retrieveMessage().map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
        )
        #expect(
            "34"
                == messageReceiver.retrieveMessage().map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
        )
        #expect(
            "56"
                == messageReceiver.retrieveMessage().map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
        )
        #expect(
            "78"
                == messageReceiver.retrieveMessage().map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
        )
        #expect(
            "90"
                == messageReceiver.retrieveMessage().map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
        )
        #expect(messageReceiver.retrieveMessage() == nil)

        #expect(
            "x"
                == decoder.lastBuffer.map {
                    String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
                }
        )
        #expect(1 == decoder.decodeLastCalls)
    }

    @Test func structsWorkAsOSBTMDecoders() {
        struct WantsOneThenTwoOSBTMDecoder: NIOSingleStepByteToMessageDecoder {
            typealias InboundOut = Int

            var state: Int = 1

            mutating func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
                if buffer.readSlice(length: self.state) != nil {
                    defer {
                        self.state += 1
                    }
                    return self.state
                } else {
                    return nil
                }
            }

            mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
                #expect(seenEOF)
                if self.state > 0 {
                    self.state = 0
                    return buffer.readableBytes * -1
                } else {
                    return nil
                }
            }
        }
        let allocator = ByteBufferAllocator()
        let processor = NIOSingleStepByteToMessageProcessor(WantsOneThenTwoOSBTMDecoder())
        let messageReceiver: MessageReceiver<Int> = MessageReceiver()

        var buffer = allocator.buffer(capacity: 16)
        buffer.clear()
        buffer.writeStaticString("1")
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        buffer.clear()
        buffer.writeStaticString("23")
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        buffer.clear()
        buffer.writeStaticString("4567890qwer")
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }

        #expect(1 == messageReceiver.retrieveMessage())
        #expect(2 == messageReceiver.retrieveMessage())
        #expect(3 == messageReceiver.retrieveMessage())
        #expect(4 == messageReceiver.retrieveMessage())
        #expect(messageReceiver.retrieveMessage() == nil)

        #expect(throws: Never.self) { try processor.finishProcessing(seenEOF: true, messageReceiver.receiveMessage) }

        #expect(-4 == messageReceiver.retrieveMessage())
        #expect(messageReceiver.retrieveMessage() == nil)
    }

    @Test func decodeLastIsInvokedOnceEvenIfNothingEverArrivedOnChannelClosed() {
        final class Decoder: NIOSingleStepByteToMessageDecoder {
            typealias InboundOut = ()
            var decodeLastCalls = 0

            func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
                Issue.record("did not expect to see decode called")
                return nil
            }

            func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
                #expect(seenEOF)
                self.decodeLastCalls += 1
                #expect(1 == self.decodeLastCalls)
                #expect(0 == buffer.readableBytes)
                return ()
            }
        }

        let decoder = Decoder()
        let processor = NIOSingleStepByteToMessageProcessor(decoder)
        let messageReceiver: MessageReceiver<()> = MessageReceiver()

        #expect(0 == messageReceiver.count)

        #expect(throws: Never.self) { try processor.finishProcessing(seenEOF: true, messageReceiver.receiveMessage) }
        #expect(messageReceiver.retrieveMessage() != nil)
        #expect(messageReceiver.retrieveMessage() == nil)

        #expect(1 == decoder.decodeLastCalls)
    }

    @Test func payloadTooLarge() {
        struct Decoder: NIOSingleStepByteToMessageDecoder {
            typealias InboundOut = Never

            func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
                nil
            }

            func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
                nil
            }
        }

        let max = 100
        let allocator = ByteBufferAllocator()
        let processor = NIOSingleStepByteToMessageProcessor(Decoder(), maximumBufferSize: max)
        let messageReceiver: MessageReceiver<Never> = MessageReceiver()

        var buffer = allocator.buffer(capacity: max + 1)
        buffer.writeString(String(repeating: "*", count: max + 1))
        #expect(throws: ByteToMessageDecoderError.PayloadTooLargeError.self) {
            try processor.process(buffer: buffer, messageReceiver.receiveMessage)
        }
    }

    @Test func payloadTooLargeButHandlerOk() {
        final class Decoder: NIOSingleStepByteToMessageDecoder {
            typealias InboundOut = String

            var decodeCalls = 0

            func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
                self.decodeCalls += 1
                return buffer.readString(length: buffer.readableBytes)
            }

            func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
                try decode(buffer: &buffer)
            }
        }

        let max = 100
        let allocator = ByteBufferAllocator()
        let decoder = Decoder()
        let processor = NIOSingleStepByteToMessageProcessor(decoder, maximumBufferSize: max)
        let messageReceiver: MessageReceiver<String> = MessageReceiver()

        var buffer = allocator.buffer(capacity: max + 1)
        buffer.writeString(String(repeating: "*", count: max + 1))
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(throws: Never.self) { try processor.finishProcessing(seenEOF: false, messageReceiver.receiveMessage) }
        #expect(0 == processor._buffer!.readableBytes)
        #expect(decoder.decodeCalls > 0)
    }

    @Test func reentrancy() throws {
        final class ReentrantWriteProducingHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = String
            var processor: NIOSingleStepByteToMessageProcessor<OneByteStringDecoder>? = nil
            var produced = 0

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if self.processor == nil {
                    self.processor = NIOSingleStepByteToMessageProcessor(OneByteStringDecoder())
                }
                do {
                    try self.processor!.process(buffer: Self.unwrapInboundIn(data)) { message in
                        self.produced += 1
                        // Produce an extra write the first time we are called to test reentrancy
                        if self.produced == 1 {
                            let buf = ByteBuffer(string: "X")
                            #expect(throws: Never.self) {
                                try (context.channel as! EmbeddedChannel).writeInbound(buf)
                            }
                        }
                        context.fireChannelRead(Self.wrapInboundOut(message))
                    }
                } catch {
                    context.fireErrorCaught(error)
                }
            }
        }

        final class OneByteStringDecoder: NIOSingleStepByteToMessageDecoder {
            typealias InboundOut = String

            func decode(buffer: inout ByteBuffer) throws -> String? {
                buffer.readString(length: 1)
            }

            func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> String? {
                #expect(seenEOF)
                return try self.decode(buffer: &buffer)
            }
        }

        let channel = EmbeddedChannel(handler: ReentrantWriteProducingHandler())
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("a")
        #expect(throws: Never.self) { try channel.writeInbound(buffer) }
        #expect("X" == (try channel.readInbound(as: String.self)))
        #expect("a" == (try channel.readInbound(as: String.self)))
        #expect(try channel.finish().isClean)
    }

    @Test func weDoNotCallShouldReclaimMemoryAsLongAsFramesAreProduced() {
        struct TestByteToMessageDecoder: NIOSingleStepByteToMessageDecoder {
            typealias InboundOut = TestMessage

            enum TestMessage: Equatable {
                case foo
            }

            var lastByteBuffer: ByteBuffer?
            var decodeHits = 0
            var reclaimHits = 0

            mutating func decode(buffer: inout ByteBuffer) throws -> TestMessage? {
                #expect(self.decodeHits * 3 == buffer.readerIndex)
                self.decodeHits += 1
                guard buffer.readableBytes >= 3 else {
                    return nil
                }
                buffer.moveReaderIndex(forwardBy: 3)
                return .foo
            }

            mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> TestMessage? {
                try self.decode(buffer: &buffer)
            }

            mutating func shouldReclaimBytes(buffer: ByteBuffer) -> Bool {
                self.reclaimHits += 1
                return true
            }
        }

        let decoder = TestByteToMessageDecoder()
        let processor = NIOSingleStepByteToMessageProcessor(decoder, maximumBufferSize: nil)

        let buffer = ByteBuffer(repeating: 0, count: 3001)
        var callbackCount = 0
        #expect(throws: Never.self) {
            try processor.process(buffer: buffer) { _ in
                callbackCount += 1
            }
        }

        #expect(callbackCount == 1000)
        #expect(processor.decoder.decodeHits == 1001)
        #expect(processor.decoder.reclaimHits == 1)
        #expect(processor._buffer!.readableBytes == 1)
    }

    @Test func unprocessedBytes() {
        let allocator = ByteBufferAllocator()
        let processor = NIOSingleStepByteToMessageProcessor(LargeChunkDecoder())  // reads slices of 512 bytes
        let messageReceiver: MessageReceiver<ByteBuffer> = MessageReceiver()

        // We're going to send in 128 bytes. This will be held.
        var buffer = allocator.buffer(capacity: 128)
        buffer.writeBytes(Array(repeating: 0x04, count: 128))
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(0 == messageReceiver.count)
        #expect(processor.unprocessedBytes == 128)

        // Adding 513 bytes, will cause a message to be returned and an extra byte to be saved.
        buffer.clear()
        buffer.writeBytes(Array(repeating: 0x04, count: 513))
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(1 == messageReceiver.count)
        #expect(processor.unprocessedBytes == 129)

        // Adding 255 bytes, will cause 255 more bytes to be held.
        buffer.clear()
        buffer.writeBytes(Array(repeating: 0x04, count: 255))
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(1 == messageReceiver.count)
        #expect(processor.unprocessedBytes == 384)

        // Adding 128 bytes, will cause another message to be returned and the buffer to be empty.
        buffer.clear()
        buffer.writeBytes(Array(repeating: 0x04, count: 128))
        #expect(throws: Never.self) { try processor.process(buffer: buffer, messageReceiver.receiveMessage) }
        #expect(2 == messageReceiver.count)
        #expect(processor.unprocessedBytes == 0)
    }

    /// Tests re-entrancy by having a nested decoding operation empty the buffer and exit part way
    /// through the outer processing step
    @Test func errorDuringNestedDecoding() {
        final class ThrowingOnLastDecoder: NIOSingleStepByteToMessageDecoder {
            /// `ByteBuffer` is the expected type passed in.
            typealias InboundIn = ByteBuffer
            /// `ByteBuffer`s will be passed to the next stage.
            typealias InboundOut = ByteBuffer

            init() {}

            struct DecodeLastError: Error {}

            func decodeLast(buffer: inout NIOCore.ByteBuffer, seenEOF: Bool) throws -> NIOCore.ByteBuffer? {
                buffer = ByteBuffer()  // to allow the decode loop to exit
                throw DecodeLastError()
            }

            func decode(buffer: inout NIOCore.ByteBuffer) throws -> NIOCore.ByteBuffer? {
                ByteBuffer()
            }
        }

        let decoder = ThrowingOnLastDecoder()
        let b2mp = NIOSingleStepByteToMessageProcessor(decoder)
        var errorObserved = false
        #expect(throws: Never.self) {
            try b2mp.process(buffer: ByteBuffer(string: "1\n\n2\n3\n")) { line in
                // We will throw an error to exit the decoding within the nested process call prematurely.
                // Unless this is carefully handled we can be left in an inconsistent state which the outer call will encounter
                do {
                    try b2mp.finishProcessing(seenEOF: true) { _ in }
                } catch _ as ThrowingOnLastDecoder.DecodeLastError {
                    errorObserved = true
                }
            }
        }
        #expect(errorObserved)
    }
}
