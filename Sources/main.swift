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


public class EchoHandler: ChannelHandler {
    
    public func channelRead(ctx: ChannelHandlerContext, data: Buffer) {
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
    pipeline.addLast(handler: EchoHandler())
})

