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

    // visible for ChannelPipeline to modify and also marked as weak to ensure we not create a 
    // reference-cycle for the doubly-linked-list
    weak var prev: ChannelHandlerContext?

    var next: ChannelHandlerContext?
    
    // marked as weak to not create a reference cycle between this instance and the pipeline
    public private(set) weak var pipeline: ChannelPipeline?

    public let handler: ChannelHandler
    public let name: String
    public let eventLoop: EventLoop
    
    // Only created from within ChannelPipeline
    init(name: String, handler: ChannelHandler, pipeline: ChannelPipeline) {
        self.name = name
        self.handler = handler
        self.pipeline = pipeline
        self.eventLoop = pipeline.eventLoop
    }
    
    public func fireChannelRegistered() {
        if let ctx = next {
            ctx.invokeChannelRegistered()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelUnregistered() {
        if let ctx = next {
            ctx.invokeChannelUnregistered()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelActive() {
        if let ctx = next {
            ctx.invokeChannelActive()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelInactive() {
        if let ctx = next {
            ctx.invokeChannelInactive()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }

    public func fireChannelRead(data: Any) {
        if let ctx = next {
            ctx.invokeChannelRead(data: data)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelReadComplete() {
        if let ctx = next {
            ctx.invokeChannelReadComplete()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }

    public func fireChannelWritabilityChanged(writable: Bool) {
        if let ctx = next {
            ctx.invokeChannelWritabilityChanged(writable: writable)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }

    public func fireErrorCaught(error: Error) {
        if let ctx = next {
            ctx.invokeErrorCaught(error: error)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireUserEventTriggered(event: Any) {
        if let ctx = next {
            ctx.invokeUserEventTriggered(event: event)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func write(data: Any, promise: Promise<Void>) -> Future<Void> {
        if let ctx = prev {
            ctx.invokeWrite(data: data, promise: promise)
        } else {
            promise.fail(error: ChannelPipelineException.alreadyRemoved)
        }
        return promise.futureResult
    }
    
    public func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void> {
        if let ctx = prev {
            ctx.invokeWriteAndFlush(data: data, promise: promise)
        } else {
            promise.fail(error: ChannelPipelineException.alreadyRemoved)
        }
        return promise.futureResult
    }
    
    public func flush() {
        prev?.invokeFlush()
    }
    
    public func read() {
        prev?.invokeRead()
    }
    
    public func close(promise: Promise<Void>) -> Future<Void> {
        if let ctx = prev {
            ctx.invokeClose(promise: promise)
        } else {
            promise.fail(error: ChannelPipelineException.alreadyRemoved)
        }

        return promise.futureResult
    }
    
    func invokeChannelRegistered() {
        assert(inEventLoop)
        
        do {
            try handler.channelRegistered(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelUnregistered() {
        assert(inEventLoop)
        
        do {
            try handler.channelUnregistered(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelActive() {
        assert(inEventLoop)
        
        do {
            try handler.channelActive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelInactive() {
        assert(inEventLoop)
        
        do {
            try handler.channelInactive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelRead(data: Any) {
        assert(inEventLoop)
        
        do {
            try handler.channelRead(ctx: self, data: data)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelReadComplete() {
        assert(inEventLoop)
        
        do {
            try handler.channelReadComplete(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelWritabilityChanged(writable: Bool) {
        assert(inEventLoop)
        
        do {
            try handler.channelWritabilityChanged(ctx: self, writable: writable)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeErrorCaught(error: Error) {
        assert(inEventLoop)
        
        do {
            try handler.errorCaught(ctx: self, error: error)
        } catch {
            // TODO: What to do ?
        }
    }

    func invokeUserEventTriggered(event: Any) {
        assert(inEventLoop)
        
        do {
            try handler.userEventTriggered(ctx: self, event: event)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }

    func invokeWrite(data: Any, promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.write(ctx: self, data: data, promise: promise)
    }
    
    func invokeFlush() {
        assert(inEventLoop)
        
        handler.flush(ctx: self)
    }
    
    func invokeWriteAndFlush(data: Any, promise: Promise<Void>) {
        assert(inEventLoop)

        handler.write(ctx: self, data: data, promise: promise)
        handler.flush(ctx: self)
    }
    
    func invokeRead() {
        assert(inEventLoop)
        
        handler.read(ctx: self)
    }
    
    func invokeClose(promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.close(ctx: self, promise: promise)
    }
    
    func invokeHandlerAdded() throws {
        assert(inEventLoop)

        try handler.handlerAdded(ctx: self)
    }
    
    func invokeHandlerRemoved() throws {
        assert(inEventLoop)

        defer {
            pipeline = nil
            prev = nil
            next = nil
        }
        try handler.handlerRemoved(ctx: self)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }
    
    private func safeErrorCaught(ctx: ChannelHandlerContext, error: Error) {
        do {
            try handler.errorCaught(ctx: ctx, error: error)
        } catch {
            // TOOO: What to do here ?
        }
    }
}
