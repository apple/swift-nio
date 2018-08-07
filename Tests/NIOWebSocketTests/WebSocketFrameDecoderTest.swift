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

import XCTest
import NIO
import NIOWebSocket

private class CloseSwallower: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private var closePromise: EventLoopPromise<Void>? = nil
    private var ctx: ChannelHandlerContext? = nil

    public func allowClose() {
        self.ctx!.close(promise: self.closePromise)
    }

    func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.closePromise = promise
        self.ctx = ctx
    }
}

/// A class that calls ctx.close() when it receives a decoded websocket frame, and validates that it does
/// not receive two.
private final class SynchronousCloser: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private var closeFrame: WebSocketFrame?

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        guard case .connectionClose = frame.opcode else {
            ctx.fireChannelRead(data)
            return
        }

        // Ok, connection close. Confirm we haven't seen one before.
        XCTAssertNil(self.closeFrame)
        self.closeFrame = frame

        // Now we're going to call close.
        ctx.close(promise: nil)
    }
}

public class WebSocketFrameDecoderTest: XCTestCase {
    public var decoderChannel: EmbeddedChannel!
    public var encoderChannel: EmbeddedChannel!
    public var buffer: ByteBuffer!

    public override func setUp() {
        self.decoderChannel = EmbeddedChannel()
        self.encoderChannel = EmbeddedChannel()
        self.buffer = decoderChannel.allocator.buffer(capacity: 128)
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameDecoder()).wait())
        XCTAssertNoThrow(try self.encoderChannel.pipeline.add(handler: WebSocketFrameEncoder()).wait())
    }

    public override func tearDown() {
        XCTAssertNoThrow(try self.encoderChannel.finish())
        _ = try? self.decoderChannel.finish()
        self.encoderChannel = nil
        self.buffer = nil
    }

    private func frameForFrame(_ frame: WebSocketFrame) -> WebSocketFrame? {
        self.encoderChannel.writeAndFlush(frame, promise: nil)

        while case .some(.byteBuffer(let d)) = self.encoderChannel.readOutbound() {
            XCTAssertNoThrow(try self.decoderChannel.writeInbound(d))
        }

        guard let producedFrame: WebSocketFrame = self.decoderChannel.readInbound() else {
            XCTFail("Did not produce a frame")
            return nil
        }
        // Should only have gotten one frame!
        XCTAssertNil(self.decoderChannel.readInbound() as WebSocketFrame?)
        return producedFrame
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
        XCTAssertNoThrow(try self.decoderChannel.pipeline.context(handlerType: WebSocketFrameDecoder.self).then {
            self.decoderChannel.pipeline.remove(handler: $0.handler)
        }.then { (_: Bool) in
            self.decoderChannel.pipeline.add(handler: handler)
        }.wait())
    }

    public func testFramesWithoutBodies() throws {
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: self.buffer)
        assertFrameRoundTrips(frame: frame)
    }

    public func testFramesWithExtensionDataDontRoundTrip() throws {
        // We don't know what the extensions are, so all data goes in...well...data.
        self.buffer.write(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(fin: false,
                                   opcode: .binary,
                                   data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
                                   extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!)
        assertFrameDoesNotRoundTrip(frame: frame)
    }

    public func testFramesWithExtensionDataCanBeRecovered() throws {
        self.buffer.write(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(fin: false,
                                   opcode: .binary,
                                   data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
                                   extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!)
        var newFrame = frameForFrame(frame)!
        // Copy some data out into the extension on the frame. The first 5 bytes are extension.
        newFrame.extensionData = newFrame.data.readSlice(length: 5)
        XCTAssertEqual(newFrame, frame)
    }

    public func testFramesWithReservedBitsSetRoundTrip() throws {
        self.buffer.write(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(fin: false,
                                   rsv1: true,
                                   rsv2: true,
                                   rsv3: true,
                                   opcode: .binary,
                                   data: self.buffer)
        assertFrameRoundTrips(frame: frame)
    }

    public func testFramesWith16BitLengthsRoundTrip() throws {
        self.buffer.write(bytes: Array(repeating: UInt8(4), count: 300))
        let frame = WebSocketFrame(fin: true,
                                   opcode: .binary,
                                   data: self.buffer)
        assertFrameRoundTrips(frame: frame)
    }

    public func testFramesWith64BitLengthsRoundTrip() throws {
        // We need a new decoder channel here, because the max length would otherwise trigger an error.
        _ = try! self.decoderChannel.finish()
        self.decoderChannel = EmbeddedChannel()
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameDecoder(maxFrameSize: 80000)).wait())

        self.buffer.write(bytes: Array(repeating: UInt8(4), count: 66000))
        let frame = WebSocketFrame(fin: true,
                                   opcode: .binary,
                                   data: self.buffer)
        assertFrameRoundTrips(frame: frame)
    }

    public func testMaskedFramesRoundTripWithMaskingIntact() throws {
        self.buffer.write(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(fin: false,
                                   opcode: .binary,
                                   maskKey: [0x80, 0x77, 0x11, 0x33],
                                   data: self.buffer)
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

    public func testMaskedFramesRoundTripWithMaskingIntactEvenWithExtensions() throws {
        self.buffer.write(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let frame = WebSocketFrame(fin: false,
                                   opcode: .binary,
                                   maskKey: [0x80, 0x77, 0x11, 0x33],
                                   data: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!,
                                   extensionData: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!)
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
        XCTAssertEqual(producedFrame.unmaskedExtensionData, self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!)
    }

    public func testDecoderRejectsOverlongFrames() throws {
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())

        // A fake frame header that claims that the length of the frame is 16385 bytes,
        // larger than the frame max.
        self.buffer.write(bytes: [0x81, 0xFE, 0x40, 0x01])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.invalidFrameLength {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xF1])
    }

    public func testDecoderRejectsFragmentedControlFrames() throws {
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.write(bytes: [0x09, 0x00])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.fragmentedControlFrame {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xEA])
    }

    public func testDecoderRejectsMultibyteControlFrameLengths() throws {
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())

        // A fake frame header that claims this is a ping frame with 126 bytes of data.
        self.buffer.write(bytes: [0x89, 0x7E, 0x00, 0x7E])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.multiByteControlFrameLength {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xEA])
    }

    func testIgnoresFurtherDataAfterRejectedFrame() throws {
        let swallower = CloseSwallower()
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: swallower, first: true).wait())

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.write(bytes: [0x09, 0x00])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.fragmentedControlFrame {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xEA])

        // Now write another broken frame, this time an overlong frame.
        // No error should occur here.
        self.buffer.clear()
        self.buffer.write(bytes: [0x81, 0xFE, 0x40, 0x01])
        XCTAssertNoThrow(try self.decoderChannel.writeInbound(self.buffer))

        // No extra data should have been sent.
        XCTAssertNil(self.decoderChannel.readOutbound())

        // Allow the channel to close.
        swallower.allowClose()

        // Take the handler out for cleanliness.
        XCTAssertNoThrow(try self.decoderChannel.pipeline.remove(handler: swallower).wait())
    }

    public func testClosingSynchronouslyOnChannelRead() throws {
        // We're going to send a connectionClose frame and confirm we only see it once.
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: SynchronousCloser()).wait())

        var errorCodeBuffer = self.encoderChannel.allocator.buffer(capacity: 4)
        errorCodeBuffer.write(webSocketErrorCode: .normalClosure)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: errorCodeBuffer)

        // Write the frame, send it through the decoder channel. We need to do this in one go to trigger
        // a double-parse edge case.
        self.encoderChannel.write(frame, promise: nil)
        var frameBuffer = self.decoderChannel.allocator.buffer(capacity: 10)
        while case .some(.byteBuffer(var d)) = self.encoderChannel.readOutbound() {
            frameBuffer.write(buffer: &d)
        }
        XCTAssertNoThrow(try self.decoderChannel.writeInbound(frameBuffer))

        // No data should have been sent or received.
        XCTAssertNil(self.decoderChannel.readOutbound())
        XCTAssertNil(self.decoderChannel.readInbound() as WebSocketFrame?)
    }

    public func testDecoderRejectsOverlongFramesWithNoAutomaticErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())

        // A fake frame header that claims that the length of the frame is 16385 bytes,
        // larger than the frame max.
        self.buffer.write(bytes: [0x81, 0xFE, 0x40, 0x01])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.invalidFrameLength {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // No error frame should be written.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [])
    }

    public func testDecoderRejectsFragmentedControlFramesWithNoAutomaticErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.write(bytes: [0x09, 0x00])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.fragmentedControlFrame {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // No error frame should be written.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [])
    }

    public func testDecoderRejectsMultibyteControlFrameLengthsWithNoAutomaticErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
        self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())

        // A fake frame header that claims this is a ping frame with 126 bytes of data.
        self.buffer.write(bytes: [0x89, 0x7E, 0x00, 0x7E])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.multiByteControlFrameLength {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // No error frame should be written.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [])
    }

    func testIgnoresFurtherDataAfterRejectedFrameWithNoAutomaticErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling. We still insert
        // an encoder because we want to fail gracefully if a frame is written.
         self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.write(bytes: [0x09, 0x00])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.fragmentedControlFrame {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // No error frame should be written.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [])

        // Now write another broken frame, this time an overlong frame.
        // No error should occur here.
        self.buffer.clear()
        self.buffer.write(bytes: [0x81, 0xFE, 0x40, 0x01])
        XCTAssertNoThrow(try self.decoderChannel.writeInbound(self.buffer))

        // No extra data should have been sent.
        XCTAssertNil(self.decoderChannel.readOutbound())
    }

    public func testDecoderRejectsOverlongFramesWithSeparateErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketProtocolErrorHandler()).wait())

        // A fake frame header that claims that the length of the frame is 16385 bytes,
        // larger than the frame max.
        self.buffer.write(bytes: [0x81, 0xFE, 0x40, 0x01])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.invalidFrameLength {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xF1])
    }

    public func testDecoderRejectsFragmentedControlFramesWithSeparateErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketProtocolErrorHandler()).wait())

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.write(bytes: [0x09, 0x00])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.fragmentedControlFrame {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xEA])
    }

    public func testDecoderRejectsMultibyteControlFrameLengthsWithSeparateErrorHandling() throws {
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketProtocolErrorHandler()).wait())

        // A fake frame header that claims this is a ping frame with 126 bytes of data.
        self.buffer.write(bytes: [0x89, 0x7E, 0x00, 0x7E])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.multiByteControlFrameLength {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xEA])
    }

    func testIgnoresFurtherDataAfterRejectedFrameWithSeparateErrorHandling() throws {
        let swallower = CloseSwallower()
        // We need to insert a decoder that doesn't do error handling, and then a separate error
        // handler.
        self.swapDecoder(for: WebSocketFrameDecoder(automaticErrorHandling: false))
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketFrameEncoder(), first: true).wait())
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: WebSocketProtocolErrorHandler()).wait())
        XCTAssertNoThrow(try self.decoderChannel.pipeline.add(handler: swallower, first: true).wait())

        // A fake frame header that claims this is a fragmented ping frame.
        self.buffer.write(bytes: [0x09, 0x00])

        do {
            try self.decoderChannel.writeInbound(self.buffer)
            XCTFail("did not throw")
        } catch NIOWebSocketError.fragmentedControlFrame {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We expect that an error frame will have been written out.
        let errorFrame = self.decoderChannel.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xEA])

        // Now write another broken frame, this time an overlong frame.
        // No error should occur here.
        self.buffer.clear()
        self.buffer.write(bytes: [0x81, 0xFE, 0x40, 0x01])
        XCTAssertNoThrow(try self.decoderChannel.writeInbound(self.buffer))

        // No extra data should have been sent.
        XCTAssertNil(self.decoderChannel.readOutbound())

        // Allow the channel to close.
        swallower.allowClose()

        // Take the handler out for cleanliness.
        XCTAssertNoThrow(try self.decoderChannel.pipeline.remove(handler: swallower).wait())
    }
}
