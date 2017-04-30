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


public class Server {
    
    public class func run(host: String, port: Int32, initPipeline: (ChannelPipeline) -> ()) throws {
        try Server.run(address: SocketAddresses.newAddress(for: host, on: port)!, initPipeline: initPipeline)
    }
    
    public class func run(address: SocketAddress, initPipeline: (ChannelPipeline) -> ()) throws {
        
        // Bootstrap the server and create the Selector on which we register our sockets.
        let selector = try Selector()
        
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
        
        
        // this will register with InterestedEvent.READ and no attachment
        try selector.register(selectable: server)
        
        defer {
            do { try selector.deregister(selectable: server) } catch { }
        }

        try server.setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)
        
        while true {
            // Block until there are events to handle
            if let events = try selector.awaitReady() {
                for ev in events {
                    if ev.isReadable {
                        
                        if ev.selectable is Socket {
                            // We stored the Buffer before as attachment so get it and clear the limit / offset.
                            let channel = ev.attachment as! Channel
                            
                            do {
                                try channel.read0()
                            } catch {
                                try channel.close0()
                            }
                        } else if ev.selectable is ServerSocket {
                            let socket = ev.selectable as! ServerSocket
                            
                            // Accept new connections until there are no more in the backlog
                            while let accepted = try socket.accept() {
                                try accepted.setNonBlocking()
                                try accepted.setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)
                                
                                
                                let channel = Channel(socket: accepted, selector: selector)
                                try channel.attach(initPipeline: initPipeline)
                            }
                        }
                    } else if ev.isWritable  && ev.selectable is Socket{
                        let channel = ev.attachment as! Channel
                        
                        do {
                            try channel.flushNowAndReadAgain()
                        } catch {
                            try channel.close0()
                        }
                    }
                }
            }
        }

    }
}
