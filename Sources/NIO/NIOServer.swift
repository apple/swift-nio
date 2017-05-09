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


public class Server {
    
    public class func run(host: String, port: Int32, initPipeline: (ChannelPipeline) -> ()) throws {
        try Server.run(address: SocketAddresses.newAddress(for: host, on: port)!, initPipeline: initPipeline)
    }
    
    public class func run(address: SocketAddress, initPipeline: (ChannelPipeline) -> ()) throws {
        
        // Bootstrap the server and create the Selector on which we register our sockets.
        let selector = try Sockets.Selector()
        
        defer {
            do { try selector.close() } catch { }
        }
        
        let server = try ServerSocket()
        
        defer {
            do { try server.close() } catch { }
        }
        
        try server.bind(address: address)
        try server.listen()
        
        try server.setNonBlocking()
        try server.setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)

        let eventLoop: EventLoop = try EventLoop()
        
        try eventLoop.register(server: server)
        
        defer {
            do { try eventLoop.close() } catch { }
        }
        try eventLoop.run(initPipeline: initPipeline)
    }
}
