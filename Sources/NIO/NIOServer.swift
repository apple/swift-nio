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


// TODO: Remove this in favor of ServerBootstrap once ported.
public class Server {
    
    private init() { }

    public class func run(host: String, port: Int32, initChannel: @escaping (Channel) throws -> ()) throws {
        try Server.run(address: SocketAddresses.newAddress(for: host, on: port)!, initChannel: initChannel)
    }
    
    public class func run(address: SocketAddress, initChannel: @escaping (Channel) throws -> ()) throws {
        
        let eventLoop: EventLoop = try EventLoop()

        defer {
            _ = try? eventLoop.close()
        }
        
        let serverChannel = try ServerSocketChannel(eventLoop: eventLoop)
        
        defer {
           _ = serverChannel.close()
        }

        
        try serverChannel.pipeline.add(handler: AcceptHandler(childHandler: ChannelInitializer(initChannel: initChannel)))
        try serverChannel.register().then{
            return serverChannel.bind(address: address)
        }.wait()
        
        try eventLoop.run()
    }
    
    private class AcceptHandler : ChannelHandler {
        
        private let childHandler: ChannelHandler
        
        init(childHandler: ChannelHandler) {
            self.childHandler = childHandler
        }
        
        func channelRead(ctx: ChannelHandlerContext, data: Any) {
            if let accepted = data as? SocketChannel {
                do {
                    try accepted.pipeline.add(handler: childHandler)
                } catch {
                    _ = accepted.close()
                }
            }
            ctx.fireChannelRead(data: data)
        }
    }
}
