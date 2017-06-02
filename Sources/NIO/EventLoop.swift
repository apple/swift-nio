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
import ConcurrencyHelpers


// TODO: Implement scheduling tasks in the future (a.k.a ScheduledExecutoreService
public class EventLoop : EventLoopGroup {
    private let selector: Sockets.Selector
    private var thread: Thread?
    private var tasks: [() -> ()]
    private let tasksLock = Lock()
    private var closed = false

    init() throws {
        self.selector = try Sockets.Selector()
        self.tasks = Array()
    }
    
    func register(channel: Channel) throws {
        assert(inEventLoop)
        try selector.register(selectable: channel.socket, interested: channel.interestedEvent, attachment: channel)
    }
    
    func deregister(channel: Channel) throws {
        assert(inEventLoop)
        try selector.deregister(selectable: channel.socket)
    }
    
    func reregister(channel: Channel) throws {
        assert(inEventLoop)
        try selector.reregister(selectable: channel.socket, interested: channel.interestedEvent)
    }
    
    public var inEventLoop: Bool {
        return Thread.current.isEqual(thread)
    }
    
    public func execute(task: @escaping () -> ()) {
        tasksLock.lock()
        tasks.append(task)
        tasksLock.unlock()
        
        // TODO: What should we do in case of error ?
        _ = try? selector.wakeup()
    }

    public func submit<T>(task: @escaping () throws-> (T)) -> Future<T> {
        let promise = Promise<T>()
        
        execute(task: {() -> () in
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        })
        
        return promise.futureResult
    }

    func run() throws {
        thread = Thread.current
        defer {
            // Ensure we reset the running Thread when this methods returns.
            thread = nil
        }
        while !closed {
            // Block until there are events to handle or the selector was woken up
            try selector.whenReady(strategy: .block) { ev in

                guard let channel = ev.attachment as? Channel else {
                    fatalError("ev.attachment has type \(type(of: ev.attachment)), expected Channel")
                }

                guard handleEvents(channel) else {
                    return
                }

                if ev.isWritable {
                    channel.writable()
                    
                    guard handleEvents(channel) else {
                        return
                    }
                }

                if ev.isReadable {
                    channel.readable()
                    
                    guard handleEvents(channel) else {
                        return
                    }
                }

                // Ensure we never reach here if the channel is not open anymore.
                assert(!channel.closed)
            }
            
            // TODO: Better locking
            tasksLock.lock()
            // Execute all the tasks that were summited
            while let task = tasks.first {
                task()
                
                let _ = tasks.removeFirst()
            }
            tasksLock.unlock()
        }
    }

    private func handleEvents(_ channel: Channel) -> Bool {
        if !channel.closed {
            return true
        }
        do {
            try deregister(channel: channel)
        } catch {
            // ignore for now... We should most likely at least log this.
        }

        return false
    }
    
    fileprivate func close() throws {
        if inEventLoop {
            try self.selector.close()
        } else {
            try self.submit(task: { () -> (Void) in
                self.closed = true
                try self.selector.close()
            }).wait()
        }
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
    
    public func next() -> EventLoop {
        return self
    }
}

/**
 Provides an "endless" stream of `EventLoop`s to use.
 */
public protocol EventLoopGroup {
    /*
     Returns the next `EventLoop` to use.
    */
    func next() -> EventLoop
}

/*
 An `EventLoopGroup` which will create multiple `EventLoop`s, each tight to its own `Thread`.
 */
public class MultiThreadedEventLoopGroup : EventLoopGroup {
    
    private let index = Atomic<Int>(value: 0)

    private let eventLoops: [EventLoop]

    public init(numThreads: Int) throws {
        var loops: [EventLoop] = []
        for _ in 0..<numThreads {
            let loop = try EventLoop()
            loops.append(loop)
        }
        
        eventLoops = loops

        for loop in loops {
            if #available(OSX 10.12, *) {
                let t = Thread {
                    do {
                        try loop.run()
                    } catch let err {
                        fatalError("unexpected error while executing EventLoop \(err)")
                    }
                }
                t.start()
            } else {
                fatalError("Unsupported platform / OS version")
            }
        }
    }
    
    public func next() -> EventLoop {
        return eventLoops[(index.add(1) % eventLoops.count).abs()]
    }
    
    public func close() throws {
        for loop in eventLoops {
            // TODO: Should we log this somehow or just rethrow the first error ?
            _ = try loop.close()
        }
    }
}

extension Int {
    public func abs() -> Int {
        if self >= 0 {
            return self
        }
        return -self
    }
}
