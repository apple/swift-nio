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
        handler.channelActive(ctx: self)
    }
    
    public func fireChannelInactive() {
        next!.invokeChannelInactive()
    }
    
    func invokeChannelInactive() {
        handler.channelInactive(ctx: self)
    }
    
    public func fireChannelRead(data: Buffer) {
        next!.invokeChannelRead(data: data)
    }
    
    func invokeChannelRead(data: Buffer) {
        handler.channelRead(ctx: self, data: data)
    }
    
    public func fireChannelReadComplete() {
        next!.invokeChannelReadComplete()
    }
    
    func invokeChannelReadComplete() {
        handler.channelReadComplete(ctx: self)
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        next!.invokeChannelWritabilityChanged(writable: writable)
    }
    
    public func invokeChannelWritabilityChanged(writable: Bool) {
        handler.channelWritabilityChanged(ctx: self, writable: writable)
    }

    public func fireErrorCaught(error: Error) {
        next!.invokeErrorCaught(error: error)
    }
    
    func invokeErrorCaught(error: Error) {
        handler.errorCaught(ctx: self, error: error)
    }
    
    public func write(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWrite(data: data, promise: promise)
        return promise.futureResult
    }

    func invokeWrite(data: Buffer, promise: Promise<Void>) {
        handler.write(ctx: self, data: data, promise: promise)
    }
    
    public func writeAndFlush(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWrite(data: data, promise: promise)
        prev!.invokeFlush()
        
        return promise.futureResult
    }
    
    public func flush() {
        prev!.invokeFlush()
    }
    
    func invokeFlush() {
        handler.flush(ctx: self)
    }
    
    public func close(promise: Promise<Void>) -> Future<Void> {
        prev!.invokeClose(promise: promise)
        return promise.futureResult
    }
    
    func invokeClose(promise: Promise<Void>) {
        handler.close(ctx: self, promise: promise)
    }
    
    func invokeHandlerAdded() {
        handler.handlerAdded(ctx: self)
    }
    
    func invokeHandlerRemoved() {
        handler.handlerRemoved(ctx: self)
    }
}
