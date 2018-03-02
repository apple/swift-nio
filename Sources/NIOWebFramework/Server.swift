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
import NIO
import NIOHTTP1

class Server {
    var host: String
    var port: Int
    var group: MultiThreadedEventLoopGroup
    var threadPool: BlockingIOThreadPool
    var fileIO: NonBlockingFileIO
    var router: Router

    init(host: String, port: Int, with router: Router, eventLoopThreads: Int = 1, poolThreads: Int = 6) {
        self.host = host
        self.port = port
        self.router = router
        
        group = MultiThreadedEventLoopGroup(numThreads: eventLoopThreads)
        threadPool = BlockingIOThreadPool(numberOfThreads: poolThreads)
        threadPool.start()

        fileIO = NonBlockingFileIO(threadPool: threadPool)
    }
    
    
    func run() {
        do {
            let bootstrap = ServerBootstrap(group: group)
                // Specify backlog and enable SO_REUSEADDR for the server itself
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                
                // Set the handlers that are applied to the accepted Channels
                .childChannelInitializer { channel in
                    channel.pipeline.addHTTPServerHandlers().then {
                        channel.pipeline.add(handler: Handler(fileIO: self.fileIO, router: self.router))
                    }
                }
                
                // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

            let channel = try bootstrap.bind(host: host, port: port).wait()
            
            print("Server started and listening on \(channel.localAddress!)")
            
            // This will never unblock as we don't close the ServerChannel
            try channel.closeFuture.wait()
        }
        catch {
            print("Error starting server")
        }
    }
}