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
import Sockets

// TODO: Implement scheduling tasks in the future (a.k.a ScheduledExecutoreService
public class EventLoop {
    let selector: Sockets.Selector
    var tasks: [() -> ()]
    var thread: Thread?

    init() throws{
        self.selector = try Sockets.Selector()
        self.tasks = Array()
    }
    
    func register(server: ServerSocket) throws {
        try self.selector.register(selectable: server)
    }
    
    func register(channel: Channel) throws {
        try selector.register(selectable: channel.socket, interested: channel.interestedEvent, attachment: channel)
    }
    
    func deregister(channel: Channel) throws {
        try selector.deregister(selectable: channel.socket)
    }
    
    func reregister(channel: Channel) throws {
        try selector.reregister(selectable: channel.socket, interested: channel.interestedEvent)
    }
    
    public var inEventLoop: Bool {
        return Thread.current.isEqual(thread)
    }
    
    public func execute(task: @escaping () -> ()) {
        tasks.append(task)
    }

    public func schedule<T>(task: @escaping () -> (T)) -> Future<T> {
        let promise = Promise<T>()
        tasks.append({() -> () in
            promise.succeed(result: task())
        })
            
        return promise.futureResult
    }

    public func run(initPipeline: (ChannelPipeline) throws -> ()) throws {
        thread = Thread.current
        
        defer {
            // Reset the thread once we exit this method.
            thread = nil
        }
        
        while true {
            // Block until there are events to handle
            if let events = try selector.awaitReady() {
                for ev in events {
                    if ev.selectable is Socket {
                        let channel = ev.attachment as! Channel

                        guard handleEvents(channel) else {
                            continue
                        }

                        if ev.isWritable {
                            channel.flushFromEventLoop()
                            
                            guard handleEvents(channel) else {
                                continue
                            }
                        }
                        
                        if ev.isReadable {
                            channel.readFromEventLoop()
                            
                            guard handleEvents(channel) else {
                                continue
                            }
                        }
                        
                        // Ensure we never reach here if the channel is not open anymore.
                        assert(channel.open)
                    } else if ev.selectable is ServerSocket {
                        let socket = ev.selectable as! ServerSocket
                        
                        // This should be never true
                        assert(!ev.isWritable)
                        
                        // Only accept one time as we only try to read one time as well
                        if let accepted = try socket.accept() {
                            try accepted.setNonBlocking()
                            
                            let channel = Channel(socket: accepted, eventLoop: self)
                            channel.registerOnEventLoop(initPipeline: initPipeline)
                            if channel.open {
                                channel.pipeline.fireChannelActive()
                            }
                        }
                    }
                }
                
                // Execute all the tasks that were summited
                while let task = tasks.first {
                    task()

                    let _ = tasks.removeFirst()
                }
            }
        }
    }

    private func handleEvents(_ channel: Channel) -> Bool {
        if channel.open {
            return true
        }
        do {
            try deregister(channel: channel)
        } catch {
            // ignore for now... We should most likely at least log this.
        }

        return false
    }
    
    public func close() throws {
        try self.selector.close()
    }
    
    public func newPromise<T>(type: T.Type) -> Promise<T> {
        return Promise<T>()
    }
    
    public func newFailedFuture<T>(type: T.Type, error: Error) -> Future<T> {
        let promise = newPromise(type: type)
        promise.fail(error: error)
        return promise.futureResult
    }
    
    public func newSucceedFuture<T>(result: T) -> Future<T> {
        let promise = newPromise(type: type(of: result))
        promise.succeed(result: result)
        return promise.futureResult
    }
}
