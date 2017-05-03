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

public class EventLoop {
    let selector: Selector
    
    init() throws{
        self.selector = try Selector()
    }
    
    func register(server: ServerSocket) throws {
        try self.selector.register(selectable: server)
    }
    
    public func run(initPipeline: (ChannelPipeline) -> ()) throws {
        while true {
            // Block until there are events to handle
            if let events = try selector.awaitReady() {
                for ev in events {
                    if ev.isReadable {
                        
                        if ev.selectable is Socket {
                            // We stored the Buffer before as attachment so get it and clear the limit / offset.
                            let channel = ev.attachment as! Channel
                            
                            channel.read0()
                            
                        } else if ev.selectable is ServerSocket {
                            let socket = ev.selectable as! ServerSocket
                            
                            // Accept new connections until there are no more in the backlog
                            while let accepted = try socket.accept() {
                                try accepted.setNonBlocking()                                
                                
                                let channel = Channel(socket: accepted, selector: selector)
                                try channel.attach(initPipeline: initPipeline)
                            }
                        }
                    } else if ev.isWritable  && ev.selectable is Socket{
                        let channel = ev.attachment as! Channel
                        
                        channel.flushNowAndReadAgain()
                    }
                }
            }
        }
    }
    
    public func close() throws {
        try self.selector.close()
    }
}
