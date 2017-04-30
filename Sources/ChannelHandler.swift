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

public protocol ChannelHandler {
    func channelActive(ctx: ChannelHandlerContext)
    func channelInactive(ctx: ChannelHandlerContext)
    func channelRead(ctx: ChannelHandlerContext, data: Buffer)
    func channelReadComplete(ctx: ChannelHandlerContext)
    func channelWritabilityChanged(ctx: ChannelHandlerContext, writable: Bool)
    func write(ctx: ChannelHandlerContext, data: Buffer)
    func flush(ctx: ChannelHandlerContext)
    func close(ctx: ChannelHandlerContext)
    func handlerAdded(ctx: ChannelHandlerContext)
    func handlerRemoved(ctx: ChannelHandlerContext)
}

//  Default implementation for the ChannelHandler protocol
extension ChannelHandler {
    
    public func channelActive(ctx: ChannelHandlerContext) {
        ctx.fireChannelActive()
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) {
        ctx.fireChannelInactive()
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: Buffer) {
        ctx.fireChannelRead(data: data)
    }
    
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.fireChannelReadComplete()
    }
    
    public func channelWritabilityChanged(ctx: ChannelHandlerContext, writable: Bool) {
        ctx.fireChannelWritabilityChanged(writable: writable)
    }
    
    public func write(ctx: ChannelHandlerContext, data: Buffer) {
        ctx.write(data: data)
    }
    
   public func flush(ctx: ChannelHandlerContext) {
        ctx.flush()
    }
    
   public func close(ctx: ChannelHandlerContext) {
        ctx.close()
    }
    
    public func handlerAdded(ctx: ChannelHandlerContext) {
        // Do nothing by default
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) {
        // Do nothing by default
    }
}
