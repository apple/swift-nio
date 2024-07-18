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

class UnboxingChannelHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = Self.unwrapInboundIn(data)
        context.fireChannelRead(Self.wrapInboundOut(data))
    }
}

func run(identifier: String) {
    let channel = EmbeddedChannel()
    try! channel.pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder())).wait()
    try! channel.pipeline.addHandler(UnboxingChannelHandler()).wait()
    let data = ByteBuffer(bytes: [0x81, 0x00])  // empty websocket

    measure(identifier: identifier) {
        for _ in 0..<1000 {
            try! channel.writeInbound(data)
            let _: WebSocketFrame? = try! channel.readInbound()
        }
        return 1000
    }

    _ = try! channel.finish()
}
