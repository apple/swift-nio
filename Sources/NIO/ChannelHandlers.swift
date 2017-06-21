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
//  Contains ChannelHandler implementations which are generic and can be re-used easily.
//
//

import Foundation

/**
 ChannelHandler implementation which enforces back-pressure by stop reading from the remote-peer when it can not write back fast-enough and start reading again
 once pending data was written.
*/
public class BackPressureHandler: ChannelInboundHandler, ChannelOutboundHandler {
    private var readPending: Bool = false
    private var writable: Bool = true;
    
    public init() { }

    public func read(ctx: ChannelHandlerContext) {
        if writable {
            ctx.read()
        } else {
            readPending = true
        }
    }
    
    public func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        self.writable = ctx.channel!.isWritable
        if writable {
            if readPending {
                readPending = false
                ctx.read()
            }
        } else {
            ctx.flush()
        }
        
        // Propagate the event as the user may still want to do something based on it.
        ctx.fireChannelWritabilityChanged()
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) {
        if readPending {
            ctx.read()
        }
    }
}

public class ChannelInitializer: ChannelInboundHandler {
    private let initChannel: (Channel) -> (Future<Void>)
    
    public init(initChannel: @escaping (Channel) -> (Future<Void>)) {
        self.initChannel = initChannel
    }

    public func channelRegistered(ctx: ChannelHandlerContext) throws {
        defer {
            let _ = ctx.pipeline?.remove(handler: self)
        }
        
        if let ch = ctx.channel {
            
            let f = initChannel(ch)
        
            f.whenSuccess { () -> Void in ctx.fireChannelRegistered() }
            f.whenFailure(callback: { ctx.fireErrorCaught(error: $0) })
        } else {
            ctx.fireChannelRegistered()
        }
    }
}
