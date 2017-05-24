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
    
    private let eventLoop: EventLoop
    private var handler: ChannelHandler?
    private var childHandler: ChannelHandler?
    private var options = ChannelOptionStorage()
    private var childOptions = ChannelOptionStorage()

    public init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }
    
    public init() throws {
        self.eventLoop = try EventLoop()
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
    
    public func bind(host: String, port: Int32) -> Future<Void> {
        return bind(address: SocketAddresses.newAddress(for: host, on: port)!)
    }
    
    // TODO: At the moment this never returns but once we make the whole thing multi-threaded it will.
    public func bind(address: SocketAddress) -> Future<Void> {
        do {
            let serverChannel = try ServerSocketChannel(eventLoop: eventLoop)
            
            defer {
                _ = serverChannel.close()
            }
            
            if let serverHandler = handler {
                try serverChannel.pipeline.add(handler: serverHandler)
            }

            try serverChannel.pipeline.add(handler: AcceptHandler(childHandler: childHandler, childOptions: childOptions))
            try options.applyAll(channel: serverChannel)

            try serverChannel.register().then(callback: { (void: Void) -> Future<Void> in
                return serverChannel.bind(address: address)
            }).wait()

            
            try eventLoop.run()
            return eventLoop.newSucceedFuture(result: ())
        } catch let err {
            return eventLoop.newFailedFuture(type: Void.self, error: err)
        }
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
                        try accepted.pipeline.add(handler: handler)
                    }
                } catch {
                    // TODO: Log something ?
                    _ = accepted.close()
                }
            }
            ctx.fireChannelRead(data: data)
        }
    }

    
    public func close() throws {
        try eventLoop.close()
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
