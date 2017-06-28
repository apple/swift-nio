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
import Sockets

public protocol ChannelHandler : class {
    func handlerAdded(ctx: ChannelHandlerContext) throws
    func handlerRemoved(ctx: ChannelHandlerContext) throws
}

public protocol ChannelOutboundHandler : ChannelHandler {
    func register(ctx: ChannelHandlerContext, promise: Promise<Void>?)
    func bind(ctx: ChannelHandlerContext, local: SocketAddress, promise: Promise<Void>?)
    func connect(ctx: ChannelHandlerContext, remote: SocketAddress, promise: Promise<Void>?)
    func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?)
    func flush(ctx: ChannelHandlerContext, promise: Promise<Void>?)
    // TODO: Think about make this more flexible in terms of influence the allocation that is used to read the next amount of data
    func read(ctx: ChannelHandlerContext, promise: Promise<Void>?)
    func close(ctx: ChannelHandlerContext, promise: Promise<Void>?)
}

public protocol ChannelInboundHandler : ChannelHandler {
    func channelRegistered(ctx: ChannelHandlerContext) throws
    func channelUnregistered(ctx: ChannelHandlerContext) throws
    func channelActive(ctx: ChannelHandlerContext) throws
    func channelInactive(ctx: ChannelHandlerContext) throws
    func channelRead(ctx: ChannelHandlerContext, data: IOData) throws
    func channelReadComplete(ctx: ChannelHandlerContext) throws
    func channelWritabilityChanged(ctx: ChannelHandlerContext) throws
    func userEventTriggered(ctx: ChannelHandlerContext, event: Any) throws
    func errorCaught(ctx: ChannelHandlerContext, error: Error) throws
}

//  Default implementation for the ChannelHandler protocol
public extension ChannelHandler {
    
    public func handlerAdded(ctx: ChannelHandlerContext) {
        // Do nothing by default
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) {
        // Do nothing by default
    }
}

public extension ChannelOutboundHandler {
    
    public func register(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.register(promise: promise)
    }
    
    public func bind(ctx: ChannelHandlerContext, local: SocketAddress, promise: Promise<Void>?) {
        ctx.bind(local: local, promise: promise)
    }
    
    public func connect(ctx: ChannelHandlerContext, remote: SocketAddress, promise: Promise<Void>?) {
        ctx.connect(remote: remote, promise: promise)
    }
    
    public func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?) {
        ctx.write(data: data, promise: promise)
    }
    
    public func flush(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.flush(promise: promise)
    }
    
    public func read(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.read(promise: promise)
    }
    
    public func close(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.close(promise: promise)
    }
}


public extension ChannelInboundHandler {
    
    public func channelRegistered(ctx: ChannelHandlerContext) {
        ctx.fireChannelRegistered()
    }
    
    public func channelUnregistered(ctx: ChannelHandlerContext) {
        ctx.fireChannelUnregistered()
    }
    
    public func channelActive(ctx: ChannelHandlerContext) {
        ctx.fireChannelActive()
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) {
        ctx.fireChannelInactive()
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: IOData) {
        ctx.fireChannelRead(data: data)
    }
    
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.fireChannelReadComplete()
    }
    
    public func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        ctx.fireChannelWritabilityChanged()
    }
    
    public func userEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        ctx.fireUserEventTriggered(event: event)
    }
    
    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.fireErrorCaught(error: error)
    }
}

