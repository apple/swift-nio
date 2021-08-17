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

private let maxOneByteSize = 125
private let maxTwoByteSize = Int(UInt16.max)
#if arch(arm) || arch(i386)
// on 32-bit platforms we can't put a whole UInt32 in an Int
private let maxNIOFrameSize = Int(UInt32.max / 2)
#else
// on 64-bit platforms this works just fine
private let maxNIOFrameSize = Int(UInt32.max)
#endif

/// An inbound `ChannelHandler` that serializes structured websocket frames into a byte stream
/// for sending on the network.
///
/// This encoder has limited enforcement of compliance to RFC 6455. In particular, to guarantee
/// that the encoder can handle arbitrary extensions, only normative MUST/MUST NOTs that do not
/// relate to extensions (e.g. the requirement that control frames not have lengths larger than
/// 125 bytes) are enforced by this encoder.
///
/// This encoder does not have any support for encoder extensions. If you wish to support
/// extensions, you should implement a message-to-message encoder that performs the appropriate
/// frame transformation as needed.
public final class WebSocketFrameEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = WebSocketFrame
    public typealias OutboundOut = ByteBuffer

    /// This buffer is used to write frame headers into. We hold a buffer here as it's possible we'll be
    /// able to avoid some allocations by re-using it.
    private var headerBuffer: ByteBuffer? = nil

    /// The maximum size of a websocket frame header. One byte for the frame "first byte", one more for the first
    /// length byte and the mask bit, potentially up to 8 more bytes for a 64-bit length field, and potentially 4 bytes
    /// for a mask key.
    private static let maximumFrameHeaderLength: Int = (2 + 4 + 8)

    public init() { }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.headerBuffer = context.channel.allocator.buffer(capacity: WebSocketFrameEncoder.maximumFrameHeaderLength)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.headerBuffer = nil
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)

        // First, we explode the frame structure and apply the mask.
        let frameHeader = FrameHeader(frame: data)
        var (extensionData, applicationData) = self.mask(key: frameHeader.maskKey, extensionData: data.extensionData, applicationData: data.data)

        // Now we attempt to prepend the frame header to the first buffer. If we can't, we'll write to the header buffer. If we have
        // an extension data buffer, that's the first buffer, and we'll also write it here.
        if var unwrappedExtensionData = extensionData {
            extensionData = nil  // Again, forcibly nil to drop the reference.

            if !unwrappedExtensionData.prependFrameHeaderIfPossible(frameHeader) {
                self.writeSeparateHeaderBuffer(frameHeader, context: context)
            }
            context.write(self.wrapOutboundOut(unwrappedExtensionData), promise: nil)
        } else if !applicationData.prependFrameHeaderIfPossible(frameHeader) {
            self.writeSeparateHeaderBuffer(frameHeader, context: context)
        }

        // Ok, now we need to write the application data buffer.
        context.write(self.wrapOutboundOut(applicationData), promise: promise)
    }

    /// Applies the websocket masking operation based on the passed byte buffers.
    private func mask(key: WebSocketMaskingKey?, extensionData: ByteBuffer?, applicationData: ByteBuffer) -> (ByteBuffer?, ByteBuffer) {
        guard let key = key else {
            return (extensionData, applicationData)
        }

        // We take local "copies" here. This is only an issue if someone else is holding onto the parent buffers.
        var extensionData = extensionData
        var applicationData = applicationData

        extensionData?.webSocketMask(key)
        applicationData.webSocketMask(key, indexOffset: (extensionData?.readableBytes ?? 0) % 4)
        return (extensionData, applicationData)
    }

    private func writeSeparateHeaderBuffer(_ frameHeader: FrameHeader, context: ChannelHandlerContext) {
        // Grab the header buffer. We nil it out while we're in this call to avoid the risk of CoWing when we
        // write to it.
        guard var buffer = self.headerBuffer else {
            fatalError("Channel handler lifecycle violated: did not allocate header buffer")
        }
        self.headerBuffer = nil

        // We couldn't prepend the frame header, write it to the header buffer.
        buffer.clear()
        buffer.writeFrameHeader(frameHeader)

        // Ok, frame header away! Before we send it we save it back onto ourselves in case we get recursively called.
        self.headerBuffer = buffer
        context.write(self.wrapOutboundOut(buffer), promise: nil)
    }
}


extension ByteBuffer {
    fileprivate mutating func prependFrameHeaderIfPossible(_ frameHeader: FrameHeader) -> Bool {
        let written: Int? = self.modifyIfUniquelyOwned { buffer in
            let startIndex = buffer.readerIndex - frameHeader.requiredBytes

            guard startIndex >= 0 else {
                return 0
            }

            let written = buffer.setFrameHeader(frameHeader, at: startIndex)
            buffer.moveReaderIndex(to: startIndex)
            return written
        }

        switch written {
        case .none, .some(0):
            return false
        case .some(let x):
            assert(x == frameHeader.requiredBytes)
            return true
        }
    }

    @discardableResult
    fileprivate mutating func writeFrameHeader(_ frameHeader: FrameHeader) -> Int {
        let written = self.setFrameHeader(frameHeader, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    @discardableResult
    private mutating func setFrameHeader(_ frameHeader: FrameHeader, at index: Int) -> Int {
        var writeIndex = index

        // Calculate some information about the mask.
        let maskBitMask: UInt8 = frameHeader.maskKey != nil ? 0x80 : 0x00
        let frameLength = frameHeader.length

        // Time to add the extra bytes. To avoid checking this twice, we also start writing stuff out here.
        switch frameLength {
        case 0...maxOneByteSize:
            writeIndex += self.setInteger(frameHeader.firstByte, at: writeIndex)
            writeIndex += self.setInteger(UInt8(frameLength) | maskBitMask, at: writeIndex)
        case (maxOneByteSize + 1)...maxTwoByteSize:
            writeIndex += self.setInteger(frameHeader.firstByte, at: writeIndex)
            writeIndex += self.setInteger(UInt8(126) | maskBitMask, at: writeIndex)
            writeIndex += self.setInteger(UInt16(frameLength), at: writeIndex)
        case (maxTwoByteSize + 1)...maxNIOFrameSize:
            writeIndex += self.setInteger(frameHeader.firstByte, at: writeIndex)
            writeIndex += self.setInteger(UInt8(127) | maskBitMask, at: writeIndex)
            writeIndex += self.setInteger(UInt64(frameLength), at: writeIndex)
        default:
            fatalError("NIO cannot serialize frames longer than \(maxNIOFrameSize)")
        }

        if let maskKey = frameHeader.maskKey {
            writeIndex += self.setBytes(maskKey, at: writeIndex)
        }

        return writeIndex - index
    }
}


/// A helper object that holds only a websocket frame header. Used to avoid accidentally CoWing on some paths.
fileprivate struct FrameHeader {
    var length: Int
    var maskKey: WebSocketMaskingKey?
    var firstByte: UInt8 = 0

    init(frame: WebSocketFrame) {
        self.maskKey = frame.maskKey
        self.firstByte = frame.firstByte
        self.length = frame.length
    }

    var requiredBytes: Int {
        var size = 2  // First byte and initial length byte

        switch self.length {
        case 0...maxOneByteSize:
            // Only requires the initial length byte
            break
        case (maxOneByteSize + 1)...maxTwoByteSize:
            // Requires an extra UInt16
            size += MemoryLayout<UInt16>.size
        case (maxTwoByteSize + 1)...maxNIOFrameSize:
            size += MemoryLayout<UInt64>.size
        default:
            fatalError("NIO cannot serialize frames longer than \(maxNIOFrameSize)")
        }

        if maskKey != nil {
            size += 4  // Masking key
        }


        return size
    }
}
