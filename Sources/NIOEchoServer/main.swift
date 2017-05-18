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
import Foundation
import NIO
import Future


public class EchoHandler: ChannelHandler {
    
    public func channelActive(ctx: ChannelHandlerContext) throws {
        try ctx.channel?.setOption(option: ChannelOptions.Socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: Any) {
        let f = ctx.write(data: data)

        // If the write fails close the channel
        f.whenFailure(callback: { error in
            let _ = ctx.close()
        })
    }
    
    // Flush it out. This will use gathering writes for max performance once implemented
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }
    
    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        print("error: {}", error)
        let _ = ctx.close()
    }
}

try Server.run(host: "0.0.0.0", port: 9999, initPipeline: { pipeline in
    // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
    try pipeline.add(handler: BackPressureHandler())
    try pipeline.add(handler: EchoHandler())
})

