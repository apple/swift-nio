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

public class ChannelHandlerContext : ChannelInboundInvoker, ChannelOutboundInvoker {
    
    public let handler: ChannelHandler
    public let pipeline: ChannelPipeline
    
    var prev: ChannelHandlerContext?
    var next: ChannelHandlerContext?
    
    init(handler: ChannelHandler, pipeline: ChannelPipeline) {
        self.handler = handler
        self.pipeline = pipeline
    }
    
    public func fireChannelActive() {
        next?.invokeChannelActive()
    }
    
    func invokeChannelActive() {
        handler.channelActive(ctx: self)
    }
    
    public func fireChannelInactive() {
        next?.invokeChannelInactive()
    }
    
    func invokeChannelInactive() {
        handler.channelInactive(ctx: self)
    }
    
    public func fireChannelRead(data: Buffer) {
        next?.invokeChannelRead(data: data)
    }
    
    func invokeChannelRead(data: Buffer) {
        handler.channelRead(ctx: self, data: data)
    }
    
    public func fireChannelReadComplete() {
        next?.invokeChannelReadComplete()
    }
    
    func invokeChannelReadComplete() {
        handler.channelReadComplete(ctx: self)
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        next?.invokeChannelWritabilityChanged(writable: writable)
    }
    
    public func invokeChannelWritabilityChanged(writable: Bool) {
        handler.channelWritabilityChanged(ctx: self, writable: writable)
    }

    public func write(data: Buffer) {
        prev?.invokeWrite(data: data)
    }

    func invokeWrite(data: Buffer) {
        handler.write(ctx: self, data: data)
    }
    
    public func writeAndFlush(data: Buffer) {
        if let p = prev {
            p.write(data: data)
            p.flush()
        }
    }
    
    public func flush() {
        prev?.invokeFlush()
    }
    
    func invokeFlush() {
        handler.flush(ctx: self)
    }
    
    public func close() {
        prev?.invokeClose()
    }
    
    func invokeClose() {
        handler.close(ctx: self)
    }
    
    func invokeHandlerAdded() {
        handler.handlerAdded(ctx: self)
    }
    
    func invokeHandlerRemoved() {
        handler.handlerRemoved(ctx: self)
    }
}
