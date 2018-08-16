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

import NIO

private let maxOneByteSize = 125
private let maxTwoByteSize = Int(UInt16.max)
#if arch(arm) // 32-bit, Raspi/AppleWatch/etc
    // Note(hh): This is not a _proper_ fix, but necessary because
    //           other places extend on that. Should be fine in
    //           practice on 32-bit platforms.
    private let maxNIOFrameSize = Int(Int32.max / 4)
#else
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

    public init() { }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)

        var maskSize: Int
        var maskBitMask: UInt8
        if data.maskKey != nil {
            maskSize = 4
            maskBitMask = 0x80
        } else {
            maskSize = 0
            maskBitMask = 0
        }

        // Calculate the "base" length of the data: that is, everything except the variable-length
        // frame encoding. That's two octets for initial frame header, maybe 4 bytes for the masking
        // key, and whatever the other data is.
        let baseLength = data.length + maskSize + 2

        // Time to add the extra bytes. To avoid checking this twice, we also start writing stuff out here.
        var buffer: ByteBuffer
        switch data.length {
        case 0...maxOneByteSize:
            buffer = ctx.channel.allocator.buffer(capacity: baseLength)
            buffer.write(integer: data.firstByte)
            buffer.write(integer: UInt8(data.length) | maskBitMask)
        case (maxOneByteSize + 1)...maxTwoByteSize:
            buffer = ctx.channel.allocator.buffer(capacity: baseLength + 2)
            buffer.write(integer: data.firstByte)
            buffer.write(integer: UInt8(126) | maskBitMask)
            buffer.write(integer: UInt16(data.length))
        case (maxTwoByteSize + 1)...maxNIOFrameSize:
            buffer = ctx.channel.allocator.buffer(capacity: baseLength + 8)
            buffer.write(integer: data.firstByte)
            buffer.write(integer: UInt8(127) | maskBitMask)
            buffer.write(integer: UInt64(data.length))
        default:
            fatalError("NIO cannot serialize frames longer than \(maxNIOFrameSize)")
        }

        if let maskKey = data.maskKey {
            buffer.write(bytes: maskKey)
        }

        // Ok, frame header away!
        ctx.write(self.wrapOutboundOut(buffer), promise: nil)

        // Next, let's mask the extension and application data and send
        // them too.
        let (extensionData, applicationData) = self.mask(key: data.maskKey, extensionData: data.extensionData, applicationData: data.data)

        // Now we can send our byte buffers out. We attach the write promise to the last
        // of the frame data.
        if let extensionData = extensionData {
            ctx.write(self.wrapOutboundOut(extensionData), promise: nil)
        }
        ctx.write(self.wrapOutboundOut(applicationData), promise: promise)
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
}
