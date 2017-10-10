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

/**
 ChannelHandler implementation which enforces back-pressure by stop reading from the remote-peer when it can not write back fast-enough and start reading again
 once pending data was written.
*/
public class BackPressureHandler: ChannelInboundHandler, _ChannelOutboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private enum PendingRead {
        case none
        case promise(promise: Promise<Void>?)
    }
    
    private var pendingRead: PendingRead = .none
    private var writable: Bool = true;
    
    public init() { }

    public func read(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        if writable {
            ctx.read(promise: promise)
        } else {
            switch pendingRead {
            case .none:
                pendingRead = .promise(promise: promise)
            case .promise(let pending):
                if let pending = pending {
                    if let promise = promise {
                        pending.futureResult.cascade(promise: promise)
                    }
                } else {
                    pendingRead = .promise(promise: promise)
                }
            }
        }
    }
    
    public func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        self.writable = ctx.channel!.isWritable
        if writable {
            mayRead(ctx: ctx)
        } else {
            ctx.flush(promise: nil)
        }
        
        // Propagate the event as the user may still want to do something based on it.
        ctx.fireChannelWritabilityChanged()
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) {
        mayRead(ctx: ctx)
    }
    
    private func mayRead(ctx: ChannelHandlerContext) {
        if case let .promise(promise) = pendingRead {
            pendingRead = .none
            ctx.read(promise: promise)
        }
    }
}

public class ChannelInitializer: _ChannelInboundHandler {
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
            f.whenComplete(callback: { v in
                switch v {
                case .failure(let err):
                    ctx.fireErrorCaught(error: err)
                case .success(_):
                    ctx.fireChannelRegistered()
                }
            })
        } else {
            ctx.fireChannelRegistered()
        }
    }
}
