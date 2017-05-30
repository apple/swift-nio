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
import Future

public class ServerBootstrap {
    
    private let group: EventLoopGroup
    private let childGroup: EventLoopGroup
    private var handler: ChannelHandler?
    private var childHandler: ChannelHandler?
    private var options = ChannelOptionStorage()
    private var childOptions = ChannelOptionStorage()

    public convenience init(group: EventLoopGroup) {
        self.init(group: group, childGroup: group)
    }
    
    public init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        self.group = group
        self.childGroup = childGroup
    }
    
    public func handler(handler: ChannelHandler) -> Self {
        self.handler = handler
        return self
    }
    
    public func handler(childHandler: ChannelHandler) -> Self {
        self.childHandler = childHandler
        return self
    }
    
    public func option<T: ChannelOption>(option: T, value: T.OptionType) -> Self {
        options.put(key: option, value: value)
        return self
    }
    
    public func option<T: ChannelOption>(childOption: T, childValue: T.OptionType) -> Self {
        childOptions.put(key: childOption, value: childValue)
        return self
    }
    
    public func bind(host: String, port: Int32) -> Future<Channel> {
        return bind(local: SocketAddresses.newAddress(for: host, on: port)!)
    }

    public func bind(local: SocketAddress) -> Future<Channel> {
        let evGroup = group
        let chEvGroup = childGroup
        let opts = options
        let eventLoop = evGroup.next()
        let h = handler
        let chHandler = childHandler
        let chOptions = childOptions
        
        let promise = eventLoop.newPromise(type: Channel.self)
        do {
            let serverChannel = try ServerSocketChannel(eventLoop: eventLoop, group: chEvGroup)
            
            func finishServerSetup() {
                do {
                    try opts.applyAll(channel: serverChannel)
                    let f = serverChannel.register().then(callback: { serverChannel.bind(local: local) })
                    f.whenSuccess {
                        promise.succeed(result: serverChannel)
                    }
                    f.cascadeFailure(promise: promise)
                } catch let err {
                    promise.fail(error: err)
                }
            }
            
            if let serverHandler = h {
                let future = serverChannel.pipeline.add(handler: serverHandler)
                future.whenSuccess {
                    let f = serverChannel.pipeline.add(handler: AcceptHandler(childHandler: chHandler, childOptions: chOptions))
                    f.whenSuccess { finishServerSetup() }
                    f.cascadeFailure(promise: promise)
                }
                future.cascadeFailure(promise: promise)
            } else {
                let f = serverChannel.pipeline.add(handler: AcceptHandler(childHandler: chHandler, childOptions: chOptions))
                f.whenSuccess { finishServerSetup() }
                f.cascadeFailure(promise: promise)
            }
        } catch let err {
            promise.fail(error: err)
        }

        return promise.futureResult
    }
    
    private class AcceptHandler : ChannelHandler {
        
        private let childHandler: ChannelHandler?
        private let childOptions: ChannelOptionStorage
        
        init(childHandler: ChannelHandler?, childOptions: ChannelOptionStorage) {
            self.childHandler = childHandler
            self.childOptions = childOptions
        }
        
        func channelRead(ctx: ChannelHandlerContext, data: Any) {
            if let accepted = data as? SocketChannel {
                do {
                    try self.childOptions.applyAll(channel: accepted)

                    if let handler = childHandler {
                        let f = accepted.pipeline.add(handler: handler)
                        f.whenSuccess { ctx.fireChannelRead(data: data) }
                        f.whenFailure( callback: { err in
                            self.closeAndFire(ctx: ctx, accepted: accepted, err: err)
                        })
                    }
                } catch let err {
                    closeAndFire(ctx: ctx, accepted: accepted, err: err)
                }
            } else {
                ctx.fireChannelRead(data: data)
            }
        }
        
        private func closeAndFire(ctx: ChannelHandlerContext, accepted: SocketChannel, err: Error) {
            _ = accepted.close()
            ctx.fireErrorCaught(error: err)
        }
    }
}

fileprivate struct ChannelOptionStorage {
    private var storage: [(Any, (Any, (Channel) -> (Any, Any) throws -> Void))] = []
    
    mutating func put<K: ChannelOption>(key: K,
                             value newValue: K.OptionType) {
        func applier(_ t: Channel) -> (Any, Any) throws -> Void {
            return { (x, y) in
                try t.setOption(option: x as! K, value: y as! K.OptionType)
            }
        }
        var hasSet = false
        self.storage = self.storage.map { (type, value) in
            if type is K {
                hasSet = true
                return (key, (newValue, applier))
            } else {
                return (type, value)
            }
        }
        if !hasSet {
            self.storage.append((key, (newValue, applier)))
        }
    }
  
    func applyAll(channel: Channel) throws {
        for (type, value) in self.storage {
            try value.1(channel)(type, value.0)
        }
    }
}

// TODO: Add ClientBootstrap once we support client as well.
