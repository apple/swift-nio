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


/// A simple `ChannelHandler` that catches protocol errors emitted by the
/// `WebSocketFrameDecoder` and automatically generates protocol error responses.
///
/// This `ChannelHandler` provides default error handling for basic errors in the
/// WebSocket protocol, and can be used by users when custom behaviour is not required.
public final class WebSocketProtocolErrorHandler: ChannelInboundHandler {
    public typealias InboundIn = Never
    public typealias OutboundOut = WebSocketFrame

    public init() { }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        if let error = error as? NIOWebSocketError {
            var data = ctx.channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: WebSocketErrorCode(error))
            let frame = WebSocketFrame(fin: true,
                                       opcode: .connectionClose,
                                       data: data)
            ctx.writeAndFlush(self.wrapOutboundOut(frame)).whenComplete {
                ctx.close(promise: nil)
            }
        }

        // Regardless of whether this is an error we want to handle or not, we always
        // forward the error on to let others see it.
        ctx.fireErrorCaught(error)
    }
}
