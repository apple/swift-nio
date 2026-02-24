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

import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest

private class CloseSwallower: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private var closePromise: EventLoopPromise<Void>? = nil
    private var context: ChannelHandlerContext? = nil

    func allowClose() {
        self.context!.close(promise: self.closePromise)
        self.context = nil
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.closePromise = promise
        self.context = context
    }
}

/// A class that calls context.close() when it receives a decoded websocket frame, and validates that it does
/// not receive two.
private final class SynchronousCloser: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private var closeFrame: WebSocketFrame?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        guard case .connectionClose = frame.opcode else {
            context.fireChannelRead(data)
            return
        }

        // Ok, connection close. Confirm we haven't seen one before.
        XCTAssertNil(self.closeFrame)
        self.closeFrame = frame

        // Now we're going to call close.
        context.close(promise: nil)
    }
}

final class WebSocketFrameDecoderTest: XCTestCase {
    var decoderChannel: EmbeddedChannel!
    var encoderChannel: EmbeddedChannel!
    var buffer: ByteBuffer!

    override func setUp() {
        self.decoderChannel = EmbeddedChannel()
        self.encoderChannel = EmbeddedChannel()
        self.buffer = decoderChannel.allocator.buffer(capacity: 128)
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(ByteToMessageHandler(WebSocketFrameDecoder()))
        )
        XCTAssertNoThrow(try self.encoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder()))
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.encoderChannel.finish())
        _ = try? self.decoderChannel.finish()
        self.encoderChannel = nil
        self.buffer = nil
    }

    private func frameForFrame(_ frame: WebSocketFrame) -> WebSocketFrame? {
        self.encoderChannel.writeAndFlush(frame, promise: nil)

        do {
            while let d = try self.encoderChannel.readOutbound(as: ByteBuffer.self) {
                XCTAssertNoThrow(try self.decoderChannel.writeInbound(d))
            }

            guard let producedFrame: WebSocketFrame = try self.decoderChannel.readInbound() else {
                XCTFail("Did not produce a frame")
                return nil
            }

            // Should only have gotten one frame!
            XCTAssertNoThrow(XCTAssertNil(try self.decoderChannel.readInbound(as: WebSocketFrame.self)))
            return producedFrame
        } catch {
            XCTFail("unexpected error: \(error)")
            return nil
        }
    }

    private func assertFrameRoundTrips(frame: WebSocketFrame) {
        XCTAssertEqual(frameForFrame(frame), frame)
    }

    private func assertFrameDoesNotRoundTrip(frame: WebSocketFrame) {
        XCTAssertNotEqual(frameForFrame(frame), frame)
    }

    private func swapDecoder(for handler: ChannelHandler) {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        let f = self.decoderChannel.pipeline.context(handlerType: ByteToMessageHandler<WebSocketFrameDecoder>.self)
            .assumeIsolated()
            .flatMap { context in
                if let handler = context.handler as? RemovableChannelHandler {
                    return self.decoderChannel.pipeline.syncOperations.removeHandler(handler)
                } else {
                    return context.eventLoop.makeFailedFuture(ChannelError.unremovableHandler)
                }
            }

        // we need to run the event loop here because removal is not synchronous
        (self.decoderChannel.eventLoop as! EmbeddedEventLoop).run()

        XCTAssertNoThrow(
            try f.flatMapThrowing {
                try self.decoderChannel.pipeline.syncOperations.addHandler(handler)
            }.nonisolated().wait()
        )
    }

    func testFramesWithoutBodies() throws {
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: self.buffer)
        assertFrameRoundTrips(frame: frame)
    }

    func testFramesWithExtensionDataDontRoundTrip() throws {
        // We don't know what the extensions are, so all data goes in...well...data.
        self.buffer.writeBytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(
            fin: false,
            opcode: .binary,
            data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
            extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!
        )
        assertFrameDoesNotRoundTrip(frame: frame)
    }

    func testFramesWithExtensionDataCanBeRecovered() throws {
        self.buffer.writeBytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(
            fin: false,
            opcode: .binary,
            data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
            extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!
        )
        var newFrame = frameForFrame(frame)!
        // Copy some data out into the extension on the frame. The first 5 bytes are extension.
        newFrame.extensionData = newFrame.data.readSlice(length: 5)
        XCTAssertEqual(newFrame, frame)
    }

    func testFramesWithReservedBitsSetRoundTrip() throws {
        self.buffer.writeBytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(
            fin: false,
            rsv1: true,
            rsv2: true,
            rsv3: true,
            opcode: .binary,
            data: self.buffer
        )
        assertFrameRoundTrips(frame: frame)
    }

    func testFramesWith16BitLengthsRoundTrip() throws {
        self.buffer.writeBytes(Array(repeating: UInt8(4), count: 300))
        let frame = WebSocketFrame(
            fin: true,
            opcode: .binary,
            data: self.buffer
        )
        assertFrameRoundTrips(frame: frame)
    }

    func testFramesWith64BitLengthsRoundTrip() throws {
        // We need a new decoder channel here, because the max length would otherwise trigger an error.
        _ = try! self.decoderChannel.finish()
        self.decoderChannel = EmbeddedChannel()
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(
                ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 80000))
            )
        )

        self.buffer.writeBytes(Array(repeating: UInt8(4), count: 66000))
        let frame = WebSocketFrame(
            fin: true,
            opcode: .binary,
            data: self.buffer
        )
        assertFrameRoundTrips(frame: frame)
    }

    func testMaskedFramesRoundTripWithMaskingIntact() throws {
        self.buffer.writeBytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(
            fin: false,
            opcode: .binary,
            maskKey: [0x80, 0x77, 0x11, 0x33],
            data: self.buffer
        )
        let producedFrame = frameForFrame(frame)!
        XCTAssertEqual(producedFrame.fin, frame.fin)
        XCTAssertEqual(producedFrame.rsv1, frame.rsv1)
        XCTAssertEqual(producedFrame.rsv2, frame.rsv2)
        XCTAssertEqual(producedFrame.rsv3, frame.rsv3)
        XCTAssertEqual(producedFrame.maskKey, frame.maskKey)
        XCTAssertEqual(producedFrame.length, frame.length)

        // The produced frame contains the masked data in its data field.
        var maskedBuffer = self.buffer!
        maskedBuffer.webSocketMask([0x80, 0x77, 0x11, 0x33])
        XCTAssertEqual(maskedBuffer, producedFrame.data)

        // But we can get the unmasked data back.
        XCTAssertEqual(producedFrame.unmaskedData, self.buffer)
    }

    func testMaskedFramesRoundTripWithMaskingIntactEvenWithExtensions() throws {
        self.buffer.writeBytes([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(
            fin: false,
            opcode: .binary,
            maskKey: [0x80, 0x77, 0x11, 0x33],
            data: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!,
            extensionData: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!
        )
        var producedFrame = frameForFrame(frame)!
        XCTAssertEqual(producedFrame.fin, frame.fin)
        XCTAssertEqual(producedFrame.rsv1, frame.rsv1)
        XCTAssertEqual(producedFrame.rsv2, frame.rsv2)
        XCTAssertEqual(producedFrame.rsv3, frame.rsv3)
        XCTAssertEqual(producedFrame.maskKey, frame.maskKey)
        XCTAssertEqual(producedFrame.length, frame.length)

        // The produced frame contains the masked data in its data field, but doesn't know which is extension and which
        // is not. Let's fix that up first.
        producedFrame.extensionData = producedFrame.data.readSlice(length: 5)

        var maskedBuffer = self.buffer!
        maskedBuffer.webSocketMask([0x80, 0x77, 0x11, 0x33])
        XCTAssertEqual(maskedBuffer.getSlice(at: maskedBuffer.readerIndex + 5, length: 5)!, producedFrame.data)
        XCTAssertEqual(maskedBuffer.getSlice(at: maskedBuffer.readerIndex, length: 5)!, producedFrame.extensionData)

        // But we can get the unmasked data back.
        XCTAssertEqual(producedFrame.unmaskedData, self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!)
        XCTAssertEqual(
            producedFrame.unmaskedExtensionData,
            self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!
        )
    }

    func testDecoderRejectsOverlongFrames() throws {
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims that the length of the frame is 16385 bytes,
        // larger than the frame max.
        self.buffer.writeBytes([0x81, 0xFE, 0x40, 0x01])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.invalidFrameLength, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual([0x88, 0x02, 0x03, 0xF1], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testDecoderRejectsFragmentedControlFrames() throws {
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.writeBytes([0x09, 0x00])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.fragmentedControlFrame, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual([0x88, 0x02, 0x03, 0xEA], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testDecoderRejectsMultibyteControlFrameLengths() throws {
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims this is a ping frame with 126 bytes of data.
        self.buffer.writeBytes([0x89, 0x7E, 0x00, 0x7E])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.multiByteControlFrameLength, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual([0x88, 0x02, 0x03, 0xEA], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testIgnoresFurtherDataAfterRejectedFrame() throws {
        let swallower = CloseSwallower()
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(swallower, position: .first))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.writeBytes([0x09, 0x00])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.fragmentedControlFrame, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual([0x88, 0x02, 0x03, 0xEA], try self.decoderChannel.readAllOutboundBytes()))

        // Now write another broken frame, this time an overlong frame.
        self.buffer.clear()
        let wrongFrame: [UInt8] = [0x81, 0xFE, 0x40, 0x01]
        self.buffer.writeBytes(wrongFrame)
        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            if case .some(.dataReceivedInErrorState(let innerError, let data)) = error as? ByteToMessageDecoderError {
                // ok
                XCTAssertEqual(.fragmentedControlFrame, innerError as? NIOWebSocketError)
                XCTAssertEqual(wrongFrame, Array(data.readableBytesView))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }

        // No extra data should have been sent.
        XCTAssertNoThrow(XCTAssertNil(try self.decoderChannel.readOutbound()))

        // Allow the channel to close.
        swallower.allowClose()

        // Take the handler out for cleanliness.
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.removeHandler(swallower).wait())
    }

    func testClosingSynchronouslyOnChannelRead() throws {
        // We're going to send a connectionClose frame and confirm we only see it once.
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(SynchronousCloser()))

        var errorCodeBuffer = self.encoderChannel.allocator.buffer(capacity: 4)
        errorCodeBuffer.write(webSocketErrorCode: .normalClosure)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: errorCodeBuffer)

        // Write the frame, send it through the decoder channel. We need to do this in one go to trigger
        // a double-parse edge case.
        self.encoderChannel.write(frame, promise: nil)
        var frameBuffer = self.decoderChannel.allocator.buffer(capacity: 10)
        while var d = try self.encoderChannel.readOutbound(as: ByteBuffer.self) {
            frameBuffer.writeBuffer(&d)
        }
        XCTAssertNoThrow(try self.decoderChannel.writeInbound(frameBuffer))

        // No data should have been sent or received.
        XCTAssertNoThrow(XCTAssertNil(try self.decoderChannel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try self.decoderChannel.readInbound(as: WebSocketFrame.self)))
    }

    func testDecoderRejectsOverlongFramesWithNoAutomaticErrorHandling() {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )

        // A fake frame header that claims that the length of the frame is 16385 bytes,
        // larger than the frame max.
        self.buffer.writeBytes([0x81, 0xFE, 0x40, 0x01])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.invalidFrameLength, error as? NIOWebSocketError)
        }

        // No error frame should be written.
        XCTAssertNoThrow(XCTAssertEqual([], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testDecoderRejectsFragmentedControlFramesWithNoAutomaticErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.writeBytes([0x09, 0x00])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.fragmentedControlFrame, error as? NIOWebSocketError)
        }

        // No error frame should be written.
        XCTAssertNoThrow(XCTAssertEqual([], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testDecoderRejectsMultibyteControlFrameLengthsWithNoAutomaticErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )

        // A fake frame header that claims this is a ping frame with 126 bytes of data.
        self.buffer.writeBytes([0x89, 0x7E, 0x00, 0x7E])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.multiByteControlFrameLength, error as? NIOWebSocketError)
        }

        // No error frame should be written.
        XCTAssertNoThrow(XCTAssertEqual([], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testIgnoresFurtherDataAfterRejectedFrameWithNoAutomaticErrorHandling() {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.writeBytes([0x09, 0x00])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.fragmentedControlFrame, error as? NIOWebSocketError)
        }

        // No error frame should be written.
        XCTAssertNoThrow(XCTAssertEqual([], try self.decoderChannel.readAllOutboundBytes()))

        // Now write another broken frame, this time an overlong frame.
        self.buffer.clear()
        let wrongFrame: [UInt8] = [0x81, 0xFE, 0x40, 0x01]
        self.buffer.writeBytes(wrongFrame)
        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            if case .some(.dataReceivedInErrorState(let innerError, let data)) = error as? ByteToMessageDecoderError {
                // ok
                XCTAssertEqual(.fragmentedControlFrame, innerError as? NIOWebSocketError)
                XCTAssertEqual(wrongFrame, Array(data.readableBytesView))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }

        // No extra data should have been sent.
        XCTAssertNoThrow(XCTAssertNil(try self.decoderChannel.readOutbound()))
    }

    func testDecoderRejectsOverlongFramesWithSeparateErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims that the length of the frame is 16385 bytes,
        // larger than the frame max.
        self.buffer.writeBytes([0x81, 0xFE, 0x40, 0x01])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.invalidFrameLength, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual([0x88, 0x02, 0x03, 0xF1], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testDecoderRejectsFragmentedControlFramesWithSeparateErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.writeBytes([0x09, 0x00])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.fragmentedControlFrame, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual([0x88, 0x02, 0x03, 0xEA], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testDecoderRejectsMultibyteControlFrameLengthsWithSeparateErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims this is a ping frame with 126 bytes of data.
        self.buffer.writeBytes([0x89, 0x7E, 0x00, 0x7E])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.multiByteControlFrameLength, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual(try self.decoderChannel.readAllOutboundBytes(), [0x88, 0x02, 0x03, 0xEA]))
    }

    func testIgnoresFurtherDataAfterRejectedFrameWithSeparateErrorHandling() {
        let swallower = CloseSwallower()
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: ByteToMessageHandler(WebSocketFrameDecoder()))
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(swallower, position: .first))

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.writeBytes([0x09, 0x00])

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.fragmentedControlFrame, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual(try self.decoderChannel.readAllOutboundBytes(), [0x88, 0x02, 0x03, 0xEA]))

        // Now write another broken frame, this time an overlong frame.
        self.buffer.clear()
        let wrongFrame: [UInt8] = [0x81, 0xFE, 0x40, 0x01]
        self.buffer.writeBytes(wrongFrame)
        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            if case .some(.dataReceivedInErrorState(let innerError, let data)) = error as? ByteToMessageDecoderError {
                // ok
                XCTAssertEqual(.fragmentedControlFrame, innerError as? NIOWebSocketError)
                XCTAssertEqual(wrongFrame, Array(data.readableBytesView))
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }

        // No extra data should have been sent.
        XCTAssertNoThrow(XCTAssertNil(try self.decoderChannel.readOutbound()))

        // Allow the channel to close.
        swallower.allowClose()

        // Take the handler out for cleanliness.
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.removeHandler(swallower).wait())
    }

    func testErrorHandlerDoesNotSwallowRandomErrors() throws {
        XCTAssertNoThrow(
            try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder(), position: .first)
        )
        XCTAssertNoThrow(try self.decoderChannel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler()))

        // A fake frame header that claims that the length of the frame is 16385 bytes,
        // larger than the frame max.
        self.buffer.writeBytes([0x81, 0xFE, 0x40, 0x01])

        struct Dummy: Error {}

        self.decoderChannel.pipeline.fireErrorCaught(Dummy())
        XCTAssertThrowsError(try self.decoderChannel.throwIfErrorCaught()) { error in
            XCTAssertNotNil(error as? Dummy, "unexpected error: \(error)")
        }

        XCTAssertThrowsError(try self.decoderChannel.writeInbound(self.buffer)) { error in
            XCTAssertEqual(.invalidFrameLength, error as? NIOWebSocketError)
        }

        // We expect that an error frame will have been written out.
        XCTAssertNoThrow(XCTAssertEqual([0x88, 0x02, 0x03, 0xF1], try self.decoderChannel.readAllOutboundBytes()))
    }

    func testWebSocketFrameDescription() {
        let byteBuffer = ByteBuffer()
        let webSocketFrame = WebSocketFrame(
            fin: true,
            rsv1: true,
            rsv2: true,
            rsv3: true,
            opcode: .binary,
            maskKey: nil,
            data: byteBuffer,
            extensionData: nil
        )

        let expectedOutput = """
            maskKey: nil, \
            fin: true, \
            rsv1: true, \
            rsv2: true, \
            rsv3: true, \
            opcode: WebSocketOpcode.binary, \
            length: 0, \
            data: \(String(describing: byteBuffer)), \
            extensionData: nil, \
            unmaskedData: \(String(describing: byteBuffer)), \
            unmaskedDataExtension: nil
            """

        XCTAssertEqual(expectedOutput, String(describing: webSocketFrame))
    }

    func testWebSocketFrameDebugDescription() {
        let byteBuffer = ByteBuffer()
        let webSocketFrame = WebSocketFrame(
            fin: true,
            rsv1: true,
            rsv2: true,
            rsv3: true,
            opcode: .binary,
            maskKey: nil,
            data: byteBuffer,
            extensionData: nil
        )

        let expectedOutput = """
            (\
            maskKey: nil, \
            fin: true, \
            rsv1: true, \
            rsv2: true, \
            rsv3: true, \
            opcode: WebSocketOpcode.binary, \
            length: 0, \
            data: \(String(describing: byteBuffer)), \
            extensionData: nil, \
            unmaskedData: \(String(describing: byteBuffer)), \
            unmaskedDataExtension: nil\
            )
            """

        XCTAssertEqual(expectedOutput, webSocketFrame.debugDescription)
    }
}
