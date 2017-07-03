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

public final class ServerBootstrap {
    
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
    
    public func bind(to host: String, on port: Int32) -> Future<Channel> {
        let evGroup = group
        do {
            let address = try SocketAddresses.newAddress(for: host, on: port)
            return bind0(evGroup: evGroup, to: address)
        } catch let err {
            return evGroup.next().newFailedFuture(error: err)
        }
    }

    public func bind(to address: SocketAddress) -> Future<Channel> {
        return bind0(evGroup: group, to: address)
    }
    
    private func bind0(evGroup: EventLoopGroup, to address: SocketAddress) -> Future<Channel> {
        let chEvGroup = childGroup
        let opts = options
        let eventLoop = evGroup.next()
        let h = handler
        let chHandler = childHandler
        let chOptions = childOptions
        
        let promise: Promise<Channel> = eventLoop.newPromise()
        do {
            let serverChannel = try ServerSocketChannel(eventLoop: eventLoop as! SelectableEventLoop, group: chEvGroup)
            
            func finishServerSetup() {
                do {
                    try opts.applyAll(channel: serverChannel)
                    let f = serverChannel.register().then(callback: { (_) -> Future<()> in serverChannel.bind(to: address) })
                    f.whenComplete(callback: { v in
                        switch v {
                        case .failure(let err):
                            promise.fail(error: err)
                        case .success(_):
                            promise.succeed(result: serverChannel)
                        }
                    })
                } catch let err {
                    promise.fail(error: err)
                }
            }

            func addAcceptHandlerAndFinishServerSetup() {
                let f = serverChannel.pipeline.add(handler: AcceptHandler(childHandler: chHandler, childOptions: chOptions))
                f.whenComplete(callback: { v in
                    switch v {
                    case .failure(let err):
                        promise.fail(error: err)
                    case .success(_):
                        finishServerSetup()
                    }
                })
            }

            if let serverHandler = h {
                let future = serverChannel.pipeline.add(handler: serverHandler)
                future.whenComplete(callback: { v in
                    switch v {
                    case .failure(let err):
                        promise.fail(error: err)
                    case .success(_):
                        addAcceptHandlerAndFinishServerSetup()
                    }
                })
            } else {
                addAcceptHandlerAndFinishServerSetup()
            }
        } catch let err {
            promise.fail(error: err)
        }

        return promise.futureResult
    }
    
    private class AcceptHandler : ChannelInboundHandler {
        
        private let childHandler: ChannelHandler?
        private let childOptions: ChannelOptionStorage
        
        init(childHandler: ChannelHandler?, childOptions: ChannelOptionStorage) {
            self.childHandler = childHandler
            self.childOptions = childOptions
        }
        
        func channelRead(ctx: ChannelHandlerContext, data: IOData) {
            let accepted = data.forceAsOther() as SocketChannel
            do {
                try self.childOptions.applyAll(channel: accepted)

                if let handler = childHandler {
                    let f = accepted.pipeline.add(handler: handler)
                    f.whenComplete(callback: { v in
                        switch v {
                        case .failure(let err):
                            self.closeAndFire(ctx: ctx, accepted: accepted, err: err)
                        case .success(_):
                            if ctx.eventLoop.inEventLoop {
                                ctx.fireChannelRead(data: data)
                            } else {
                                ctx.eventLoop.execute {
                                    ctx.fireChannelRead(data: data)
                                }
                            }
                        }
                    })
                }
            } catch let err {
                closeAndFire(ctx: ctx, accepted: accepted, err: err)
            }
        }
        
        private func closeAndFire(ctx: ChannelHandlerContext, accepted: SocketChannel, err: Error) {
            _ = accepted.close()
            if ctx.eventLoop.inEventLoop {
                ctx.fireErrorCaught(error: err)
            } else {
                ctx.eventLoop.execute {
                    ctx.fireErrorCaught(error: err)
                }
            }
        }
    }
}

public final class ClientBootstrap {
    
    private let group: EventLoopGroup
    private var handler: ChannelHandler?
    private var options = ChannelOptionStorage()

    public init(group: EventLoopGroup) {
        self.group = group
    }
    
    public func handler(handler: ChannelHandler) -> Self {
        self.handler = handler
        return self
    }
    
    public func option<T: ChannelOption>(option: T, value: T.OptionType) -> Self {
        options.put(key: option, value: value)
        return self
    }
    
    public func bind(to host: String, on port: Int32) -> Future<Channel> {
        let evGroup = group

        do {
            let address = try SocketAddresses.newAddress(for: host, on: port)
            return execute(evGroup: evGroup, fn: { channel in
                return channel.bind(to: address)
            })
        } catch let err {
            return evGroup.next().newFailedFuture(error: err)
        }
    }
    
    public func bind(to address: SocketAddress) -> Future<Channel> {
        return execute(evGroup: group, fn: { channel in
            return channel.bind(to: address)
        })
    }
    
    public func connect(to host: String, on port: Int32) -> Future<Channel> {
        let evGroup = group
        
        do {
            let address = try SocketAddresses.newAddress(for: host, on: port)
            return execute(evGroup: group, fn: { channel in
                return channel.connect(to: address)
            })
        } catch let err {
            return evGroup.next().newFailedFuture(error: err)
        }
    }
    
    public func connect(to address: SocketAddress) -> Future<Channel> {
        return execute(evGroup: group, fn: { channel in
            return channel.connect(to: address)
        })
    }

    private func execute(evGroup: EventLoopGroup, fn: @escaping (Channel) -> Future<Void>) -> Future<Channel> {
        let eventLoop = evGroup.next()
        let h = handler
        let opts = options
        
        let promise: Promise<Channel> = eventLoop.newPromise()
        do {
            let channel = try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop)
            
            func finishClientSetup() {
                do {
                    try opts.applyAll(channel: channel)
                    let f = channel.register().then  { (_) -> Future<Void> in
                        fn(channel)
                    }
                    f.whenComplete(callback: { v in
                        switch v {
                        case .failure(let err):
                            promise.fail(error: err)
                        case .success(_):
                            promise.succeed(result: channel)
                        }
                    })
                } catch let err {
                    promise.fail(error: err)
                }
            }
            
            if let clientHandler = h {
                let future = channel.pipeline.add(handler: clientHandler)
                future.whenComplete(callback: { v in
                    switch v {
                    case .failure(let err):
                        promise.fail(error: err)
                    case .success(_):
                        finishClientSetup()
                    }
                })
            } else {
                finishClientSetup()
            }
        } catch let err {
            promise.fail(error: err)
        }
        
        return promise.futureResult
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
        self.storage = self.storage.map { typeAndValue in
            let (type, value) = typeAndValue
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
