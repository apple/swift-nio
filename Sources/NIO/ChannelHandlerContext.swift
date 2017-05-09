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
    
    var prev: ChannelHandlerContext?
    var next: ChannelHandlerContext?
    
    init(handler: ChannelHandler, pipeline: ChannelPipeline) {
        self.handler = handler
        self.pipeline = pipeline
    }
    
    public func fireChannelActive() {
        next!.invokeChannelActive()
    }
    
    func invokeChannelActive() {
        do {
            try handler.channelActive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    public func fireChannelInactive() {
        next!.invokeChannelInactive()
    }
    
    func invokeChannelInactive() {
        do {
            try handler.channelInactive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    public func fireChannelRead(data: Buffer) {
        next!.invokeChannelRead(data: data)
    }
    
    func invokeChannelRead(data: Buffer) {
        do {
            try handler.channelRead(ctx: self, data: data)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    public func fireChannelReadComplete() {
        next!.invokeChannelReadComplete()
    }
    
    func invokeChannelReadComplete() {
        do {
            try handler.channelReadComplete(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        next!.invokeChannelWritabilityChanged(writable: writable)
    }
    
    public func invokeChannelWritabilityChanged(writable: Bool) {
        do {
            try handler.channelWritabilityChanged(ctx: self, writable: writable)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }

    public func fireErrorCaught(error: Error) {
        next!.invokeErrorCaught(error: error)
    }
    
    func invokeErrorCaught(error: Error) {
        do {
            try handler.errorCaught(ctx: self, error: error)
        } catch {
            // TODO: What to do ?
        }
    }
    
    public func fireUserEventTriggered(event: AnyClass) {
        next!.invokeUserEventTriggered(event: event)
    }
    
    func invokeUserEventTriggered(event: AnyClass) {
        do {
            try handler.userEventTriggered(ctx: self, event: event)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    public func write(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWrite(data: data, promise: promise)
        return promise.futureResult
    }

    func invokeWrite(data: Buffer, promise: Promise<Void>) {
        handler.write(ctx: self, data: data, promise: promise)
    }
    
    public func writeAndFlush(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWriteAndFlush(data: data, promise: promise)        
        return promise.futureResult
    }
    
    public func flush() {
        prev!.invokeFlush()
    }
    
    func invokeFlush() {
        handler.flush(ctx: self)
    }
    
    func invokeWriteAndFlush(data: Buffer, promise: Promise<Void>) {
        handler.write(ctx: self, data: data, promise: promise)
        handler.flush(ctx: self)
    }
    
    public func read() {
        prev!.invokeRead()
    }
    
    func invokeRead() {
        handler.read(ctx: self)
    }
    
    public func close(promise: Promise<Void>) -> Future<Void> {
        prev!.invokeClose(promise: promise)
        return promise.futureResult
    }
    
    func invokeClose(promise: Promise<Void>) {
        handler.close(ctx: self, promise: promise)
    }
    
    func invokeHandlerAdded() throws {
        try handler.handlerAdded(ctx: self)
    }
    
    func invokeHandlerRemoved() throws {
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
