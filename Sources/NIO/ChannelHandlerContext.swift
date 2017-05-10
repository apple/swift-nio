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
import Future

public class ChannelHandlerContext : ChannelInboundInvoker, ChannelOutboundInvoker {

    var prev: ChannelHandlerContext?
    var next: ChannelHandlerContext?

    public let handler: ChannelHandler
    public let pipeline: ChannelPipeline
   
    public var channel: Channel {
        get {
            return pipeline.channel
        }
    }
    
    public var allocator: BufferAllocator {
        get {
            return channel.allocator
        }
    }
    
    public var eventLoop: EventLoop {
        get {
            return channel.eventLoop
        }
    }
    
    // Only created from within Channel
    init(handler: ChannelHandler, pipeline: ChannelPipeline) {
        self.handler = handler
        self.pipeline = pipeline
    }
    
    public func fireChannelRegistered() {
        next!.invokeChannelRegistered()
    }
    
    public func fireChannelUnregistered() {
        next!.invokeChannelUnregistered()
    }
    
    public func fireChannelActive() {
        next!.invokeChannelActive()
    }
    
    public func fireChannelInactive() {
        next!.invokeChannelInactive()
    }

    public func fireChannelRead(data: AnyObject) {
        next!.invokeChannelRead(data: data)
    }
    
    public func fireChannelReadComplete() {
        next!.invokeChannelReadComplete()
    }

    public func fireChannelWritabilityChanged(writable: Bool) {
        next!.invokeChannelWritabilityChanged(writable: writable)
    }

    public func fireErrorCaught(error: Error) {
        next!.invokeErrorCaught(error: error)
    }
    
    public func fireUserEventTriggered(event: AnyClass) {
        next!.invokeUserEventTriggered(event: event)
    }
    
    public func write(data: AnyObject, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWrite(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func writeAndFlush(data: AnyObject, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWriteAndFlush(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func flush() {
        prev!.invokeFlush()
    }
    
    public func read() {
        prev!.invokeRead()
    }

    
    public func close(promise: Promise<Void>) -> Future<Void> {
        prev!.invokeClose(promise: promise)
        return promise.futureResult
    }
    
    
    // Methods that are invoked itself by this class itself or ChannelPipeline
    func invokeChannelRegistered() {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.channelRegistered(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelUnregistered() {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.channelUnregistered(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelActive() {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.channelActive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelInactive() {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.channelInactive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelRead(data: AnyObject) {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.channelRead(ctx: self, data: data)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelReadComplete() {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.channelReadComplete(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelWritabilityChanged(writable: Bool) {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.channelWritabilityChanged(ctx: self, writable: writable)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeErrorCaught(error: Error) {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.errorCaught(ctx: self, error: error)
        } catch {
            // TODO: What to do ?
        }
    }

    func invokeUserEventTriggered(event: AnyClass) {
        assert(channel.eventLoop.inEventLoop())
        
        do {
            try handler.userEventTriggered(ctx: self, event: event)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }

    func invokeWrite(data: AnyObject, promise: Promise<Void>) {
        assert(channel.eventLoop.inEventLoop())
        
        handler.write(ctx: self, data: data, promise: promise)
    }
    
    func invokeFlush() {
        assert(channel.eventLoop.inEventLoop())
        
        handler.flush(ctx: self)
    }
    
    func invokeWriteAndFlush(data: AnyObject, promise: Promise<Void>) {
        assert(channel.eventLoop.inEventLoop())
        handler.write(ctx: self, data: data, promise: promise)
        handler.flush(ctx: self)
    }
    
    func invokeRead() {
        assert(channel.eventLoop.inEventLoop())
        
        handler.read(ctx: self)
    }
    
    func invokeClose(promise: Promise<Void>) {
        assert(channel.eventLoop.inEventLoop())
        
        handler.close(ctx: self, promise: promise)
    }
    
    func invokeHandlerAdded() throws {
        assert(channel.eventLoop.inEventLoop())

        try handler.handlerAdded(ctx: self)
    }
    
    func invokeHandlerRemoved() throws {
        assert(channel.eventLoop.inEventLoop())

        try handler.handlerRemoved(ctx: self)
    }
    
    private func safeErrorCaught(ctx: ChannelHandlerContext, error: Error) {
        do {
            try handler.errorCaught(ctx: ctx, error: error)
        } catch {
            // TOOO: What to do here ?
        }
    }
}
