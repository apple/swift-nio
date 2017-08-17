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
import SwiftPriorityQueue
import Dispatch

public protocol EventLoop: EventLoopGroup {
    var inEventLoop: Bool { get }
    func execute(task: @escaping () -> ())
    func submit<T>(task: @escaping () throws-> (T)) -> Future<T>
    func schedule<T>(task: @escaping () throws-> (T), in: TimeAmount) -> Future<T>
    func newPromise<T>() -> Promise<T>
    func newFailedFuture<T>(error: Error) -> Future<T>
    func newSucceedFuture<T>(result: T) -> Future<T>
}

public struct TimeAmount {
    public let nanoseconds: UInt64

    private init(_ nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }
    
    public static func nanoseconds(_ amount: UInt64) -> TimeAmount {
        return TimeAmount(amount)
    }
    
    public static func microseconds(_ amount: UInt64) -> TimeAmount {
        return TimeAmount(amount * 1000)
    }

    public static func milliseconds(_ amount: Int) -> TimeAmount {
        return TimeAmount(UInt64(amount) * 1000 * 1000)
    }
    
    public static func seconds(_ amount: Int) -> TimeAmount {
        return TimeAmount(UInt64(amount) * 1000 * 1000 * 1000)
    }
    
    public static func minutes(_ amount: Int) -> TimeAmount {
        return TimeAmount(UInt64(amount) * 1000 * 1000 * 1000 * 60)
    }

    public static func hours(_ amount: Int) -> TimeAmount {
        return TimeAmount(UInt64(amount) * 1000 * 1000 * 1000 * 60 * 60)
    }
}

extension TimeAmount: Comparable {
    public static func < (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds < rhs.nanoseconds
    }
    public static func == (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds == rhs.nanoseconds
    }
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

private func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try execute()
    #else
    return try autoreleasepool {
        try execute()
    }
    #endif
}

final class SelectableEventLoop : EventLoop {
    
    private let selector: NIO.Selector<NIORegistration>
    private var thread: pthread_t?
    private var scheduledTasks = PriorityQueue<ScheduledTask>(ascending: true)
    private let tasksLock = Lock()
    private var closed = false
    
    private let _iovecs: UnsafeMutablePointer<IOVector>
    private let _storageRefs: UnsafeMutablePointer<Unmanaged<AnyObject>>
    
    let iovecs: UnsafeMutableBufferPointer<IOVector>
    let storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>
    
    init() throws {
        self.selector = try NIO.Selector()
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
        guard !closed else {
            // Its possible the EventLoop was closed before we were able to call deregister, so just return in this case as there is no harm.
            return
        }
        try selector.deregister(selectable: channel.selectable)
    }
    
    func reregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.reregister(selectable: channel.selectable, interested: channel.interestedEvent)
    }
    
    var inEventLoop: Bool {
        return pthread_self() == thread
    }
    
    func schedule<T>(task: @escaping () throws -> (T), in: TimeAmount) -> Future<T> {
        let promise: Promise<T> = newPromise()
        tasksLock.lock()
        scheduledTasks.push(ScheduledTask({() -> () in
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        }, `in`))
        tasksLock.unlock()
        
        wakeupSelector()

        return promise.futureResult
    }
    
    func execute(task: @escaping () -> ()) {
        tasksLock.lock()
        scheduledTasks.push(ScheduledTask(task, .nanoseconds(0)))
        tasksLock.unlock()
        
        wakeupSelector()
    }
    
    private func wakeupSelector() {
        do {
            try selector.wakeup()
        } catch let err {
            fatalError("Error during Selector.wakeup(): \(err)");
        }
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

    private func currentSelectorStrategy() -> SelectorStrategy {
        // TODO: Just use an atomic
        tasksLock.lock()
        let scheduled = scheduledTasks.peek()
        tasksLock.unlock()

        guard let sched = scheduled else {
            // Not tasks to handle so just block
            return .block
        }
        
        let nanos: UInt64 = sched.readyIn(DispatchTime.now())

        if nanos == 0 {
            // Something is ready to be processed just do a non-blocking select of events.
            return .now
        } else {
            return .blockUntilTimeout(nanoseconds: nanos)
        }
    }
    
    func run() throws {
        thread = pthread_self()
        defer {
            // Ensure we reset the running Thread when this methods returns.
            thread = nil
        }
        while !closed {
            // Block until there are events to handle or the selector was woken up
            /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
            try withAutoReleasePool {
                
                try selector.whenReady(strategy: currentSelectorStrategy()) { ev in
                    switch ev.registration {
                    case .serverSocketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    case .socketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    }
                }
            }
            
            // We need to ensure we process all tasks, even if a task added another task again
            while true {
                // TODO: Better locking
                tasksLock.lock()
                if scheduledTasks.isEmpty {
                    tasksLock.unlock()
                    break
                }
                var tasksCopy = ContiguousArray<() -> ()>()

                // We only fetch the time one time as this may be expensive and is generally good enough as if we miss anything we will just do a non-blocking select again anyway.
                let now = DispatchTime.now()
                
                // Make a copy of the tasks so we can execute these while not holding the lock anymore
                while let task = scheduledTasks.peek(), task.readyIn(now) == 0 {
                    tasksCopy.append(task.task)

                    let _ = scheduledTasks.pop()
                }
                tasksLock.unlock()
                
                // Execute all the tasks that were summited
                while let task = tasksCopy.first {
                    /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
                    withAutoReleasePool {
                        task()
                    }
                    
                    let _ = tasksCopy.removeFirst()
                }
            }
        }
        // This EventLoop was closed so also close the underlying selector.
        try self.selector.close()
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

private struct ScheduledTask {
    let task: () -> ()
    private let readyTime: UInt64
    
    init(_ task: @escaping () -> (), _ time: TimeAmount) {
        self.task = task
        self.readyTime = time.nanoseconds + DispatchTime.now().uptimeNanoseconds
    }
    
    func readyIn(_ t: DispatchTime) -> UInt64 {
        if readyTime < t.uptimeNanoseconds {
            return 0
        }
        return readyTime - t.uptimeNanoseconds
    }
}

extension ScheduledTask : Comparable {
    public static func < (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }
    public static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs.readyTime == rhs.readyTime
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

public enum EventLoopError: Error {
    case unsupportedOperation
}
