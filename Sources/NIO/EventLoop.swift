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
import ConcurrencyHelpers

public protocol EventLoop: EventLoopGroup {
    var inEventLoop: Bool { get }
    func execute(task: @escaping () -> ())
    func submit<T>(task: @escaping () throws-> (T)) -> Future<T>
    func newPromise<T>() -> Promise<T>
    func newFailedFuture<T>(error: Error) -> Future<T>
    func newSucceedFuture<T>(result: T) -> Future<T>
}

extension EventLoop {
    public func submit<T>(task: @escaping () throws-> (T)) -> Future<T> {
        let promise: Promise<T> = newPromise()

        execute(task: {() -> () in
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        })

        return promise.futureResult
    }

    public func newPromise<T>() -> Promise<T> {
        return Promise<T>(eventLoop: self, checkForPossibleDeadlock: true)
    }

    public func newFailedFuture<T>(error: Error) -> Future<T> {
        return Future<T>(eventLoop: self, checkForPossibleDeadlock: true, error: error)
    }

    public func newSucceedFuture<T>(result: T) -> Future<T> {
        return Future<T>(eventLoop: self, checkForPossibleDeadlock: true, result: result)
    }
    
    public func next() -> EventLoop {
        return self
    }
    
    public func close() throws {
        // Do nothing
    }
}

enum NIORegistration: Registration {
    case serverSocketChannel(ServerSocketChannel, IOEvent)
    case socketChannel(SocketChannel, IOEvent)

    var interested: IOEvent {
        set {
            switch self {
            case .serverSocketChannel(let c, _):
                self = .serverSocketChannel(c, newValue)
            case .socketChannel(let c, _):
                self = .socketChannel(c, newValue)
            }
        }
        get {
            switch self {
            case .serverSocketChannel(_, let i):
                return i
            case .socketChannel(_, let i):
                return i
            }
        }
    }

}

// TODO: Implement scheduling tasks in the future (a.k.a ScheduledExecutoreService
final class SelectableEventLoop : EventLoop {
    private let selector: NIO.Selector<NIORegistration>
    private var thread: pthread_t?
    private var tasks: [() -> ()]
    private let tasksLock = Lock()
    private var closed = false
    
    private let _iovecs: UnsafeMutablePointer<IOVector>
    private let _storageRefs: UnsafeMutablePointer<Unmanaged<AnyObject>>
    
    let iovecs: UnsafeMutableBufferPointer<IOVector>
    let storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>
    
    init() throws {
        self.selector = try NIO.Selector()
        self.tasks = Array()
        self._iovecs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimit)
        self._storageRefs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimit)
        self.iovecs = UnsafeMutableBufferPointer(start: self._iovecs, count: Socket.writevLimit)
        self.storageRefs = UnsafeMutableBufferPointer(start: self._storageRefs, count: Socket.writevLimit)
    }
    
    deinit {
        _iovecs.deallocate(capacity: Socket.writevLimit)
        _storageRefs.deallocate(capacity: Socket.writevLimit)
    }
    
    func register<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.register(selectable: channel.selectable, interested: channel.interestedEvent, makeRegistration: channel.registrationFor(interested:))
    }

    func deregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.deregister(selectable: channel.selectable)
    }
    
    func reregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.reregister(selectable: channel.selectable, interested: channel.interestedEvent)
    }
    
    var inEventLoop: Bool {
        return pthread_self() == thread
    }
    
    func execute(task: @escaping () -> ()) {
        tasksLock.lock()
        tasks.append(task)
        tasksLock.unlock()
        
        // TODO: What should we do in case of error ?
        _ = try? selector.wakeup()
    }

    private func handleEvent<C: SelectableChannel>(_ ev: IOEvent, channel: C) {
        guard handleEvents(channel) else {
            return
        }
        
        switch ev {
        case .write:
            channel.writable()
        case .read:
            channel.readable()
        case .all:
            channel.writable()
            guard handleEvents(channel) else {
                return
            }
            channel.readable()
        case .none:
            // spurious wakup
            break
            
        }
        guard handleEvents(channel) else {
            return
        }

        // Ensure we never reach here if the channel is not open anymore.
        assert(channel.open)

    }

    func run() throws {
        thread = pthread_self()
        defer {
            // Ensure we reset the running Thread when this methods returns.
            thread = nil
        }
        while !closed {
            // Block until there are events to handle or the selector was woken up
            try selector.whenReady(strategy: .block) { ev in
                switch ev.registration {
                case .serverSocketChannel(let chan, _):
                    self.handleEvent(ev.io, channel: chan)
                case .socketChannel(let chan, _):
                    self.handleEvent(ev.io, channel: chan)
                }
            }
            
            // We need to ensure we process all tasks, even if a task added another task again
            while true {
                // TODO: Better locking
                tasksLock.lock()
                if tasks.isEmpty {
                    tasksLock.unlock()
                    break
                }
                // Make a copy of the tasks sso we can execute these while not holding the lock anymore
                var tasksCopy = Array(tasks)
                tasks.removeAll()
                tasksLock.unlock()
                
                // Execute all the tasks that were summited
                while let task = tasksCopy.first {
                    task()
                    
                    let _ = tasksCopy.removeFirst()
                }
            }
        }
    }

    private func handleEvents<C: SelectableChannel>(_ channel: C) -> Bool {
        guard !channel.open else {
            return true
        }
        do {
            try deregister(channel: channel)
        } catch {
            // ignore for now... We should most likely at least log this.
        }

        return false
    }
    
    func close0() throws {
        if inEventLoop {
            try self.selector.close()
        } else {
            try self.submit(task: { () -> (Void) in
                self.closed = true
                try self.selector.close()
            }).wait()
        }
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
final public class MultiThreadedEventLoopGroup : EventLoopGroup {
    
    private let index = Atomic<Int>(value: 0)

    private let eventLoops: [SelectableEventLoop]

    public init(numThreads: Int) throws {
        var loops: [SelectableEventLoop] = []
        for _ in 0..<numThreads {
            let loop = try SelectableEventLoop()
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
            _ = try loop.close0()
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
