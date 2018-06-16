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


///
/// A decoder that splits the received `ByteBuffer` by a fixed number
/// of bytes. For example, if you received the following four fragmented packets:
///
/// +---+----+------+----+
/// | A | BC | DEFG | HI |
/// +---+----+------+----+
/// 
/// A `FixedLengthFrameDecoder` will decode them into the
/// following three packets with the fixed length:
///
/// +-----+-----+-----+
/// | ABC | DEF | GHI |
/// +-----+-----+-----+
///
public final class FixedLengthFrameDecoder: ByteToMessageDecoder {

    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    public var cumulationBuffer: ByteBuffer?

    private let frameLength: Int

    /// Create `FixedLengthFrameDecoder` with a given frame length.
    ///
    /// - parameters:
    ///    - frameLength: The length of a frame.
    public init(frameLength: Int) {
        self.frameLength = frameLength
    }

    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let slice = buffer.readSlice(length: frameLength) else {
            return .needMoreData
        }

        ctx.fireChannelRead(self.wrapInboundOut(slice))
        return .continue
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        guard let buffer = cumulationBuffer, buffer.readableBytes > 0 else {
            return
        }

        ctx.fireErrorCaught(ChannelPipelineError.removedWithLeftOverBytes(buffer))
    }

}
