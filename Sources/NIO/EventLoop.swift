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

import NIOConcurrencyHelpers
import Dispatch
import class Foundation.Thread
import NIOPriorityQueue
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

public struct Scheduled<T> {
    private let promise: EventLoopPromise<T>
    private let cancellationTask: () -> ()
    
    init(promise: EventLoopPromise<T>, cancellationTask: @escaping () -> ()) {
        self.promise = promise
        promise.futureResult.whenFailure(callback: { error in
            guard let err = error as? EventLoopError else {
                return
            }
            if err == .cancelled {
                cancellationTask()
            }
        })
        self.cancellationTask = cancellationTask
    }
    
    public func cancel() {
        promise.fail(error: EventLoopError.cancelled)
    }
    
    public var futureResult: EventLoopFuture<T> {
        return promise.futureResult
    }
}

public protocol EventLoop: EventLoopGroup {
    var inEventLoop: Bool { get }
    func execute(task: @escaping () -> ())
    func submit<T>(task: @escaping () throws-> (T)) -> EventLoopFuture<T>
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws-> (T)) -> Scheduled<T>
    func newPromise<T>() -> EventLoopPromise<T>
    func newFailedFuture<T>(error: Error) -> EventLoopFuture<T>
    func newSucceedFuture<T>(result: T) -> EventLoopFuture<T>
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
    
    public static func now() -> TimeAmount {
        return nanoseconds(DispatchTime.now().uptimeNanoseconds)
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
    public func submit<T>(task: @escaping () throws-> (T)) -> EventLoopFuture<T> {
        let promise: EventLoopPromise<T> = newPromise()

        execute(task: {() -> () in
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        })

        return promise.futureResult
    }

    public func newPromise<T>() -> EventLoopPromise<T> {
        return EventLoopPromise<T>(eventLoop: self, checkForPossibleDeadlock: true)
    }

    public func newFailedFuture<T>(error: Error) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, checkForPossibleDeadlock: true, error: error)
    }

    public func newSucceedFuture<T>(result: T) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, checkForPossibleDeadlock: true, result: result)
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

private enum EventLoopLifecycleState {
    case open
    case closing
    case closed
}

internal final class SelectableEventLoop : EventLoop {
    private let selector: NIO.Selector<NIORegistration>
    private let thread: pthread_t
    private var scheduledTasks = PriorityQueue<ScheduledTask>(ascending: true)
    private let tasksLock = Lock()
    private var lifecycleState: EventLoopLifecycleState = .open
    
    private let _iovecs: UnsafeMutablePointer<IOVector>
    private let _storageRefs: UnsafeMutablePointer<Unmanaged<AnyObject>>
    
    let iovecs: UnsafeMutableBufferPointer<IOVector>
    let storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>
    
    public init(thread: pthread_t) throws {
        self.selector = try NIO.Selector()
        self.thread = thread
        self._iovecs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimit)
        self._storageRefs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimit)
        self.iovecs = UnsafeMutableBufferPointer(start: self._iovecs, count: Socket.writevLimit)
        self.storageRefs = UnsafeMutableBufferPointer(start: self._storageRefs, count: Socket.writevLimit)
    }
    
    deinit {
        _iovecs.deallocate(capacity: Socket.writevLimit)
        _storageRefs.deallocate(capacity: Socket.writevLimit)
    }
    
    public func register<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.register(selectable: channel.selectable, interested: channel.interestedEvent, makeRegistration: channel.registrationFor(interested:))
    }

    public func deregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        guard lifecycleState == .open else {
            // Its possible the EventLoop was closed before we were able to call deregister, so just return in this case as there is no harm.
            return
        }
        try selector.deregister(selectable: channel.selectable)
    }
    
    public func reregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.reregister(selectable: channel.selectable, interested: channel.interestedEvent)
    }
    
    public var inEventLoop: Bool {
        return pthread_equal(pthread_self(), thread) != 0
    }

    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws-> (T)) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = newPromise()
        let task = ScheduledTask({
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        }, { error in
            promise.fail(error: error)
        },`in`)
        
        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.tasksLock.lock()
            self.scheduledTasks.remove(task)
            self.tasksLock.unlock()
            self.wakeupSelector()
        })
      
        schedule0(task)
        return scheduled
    }
    
    public func execute(task: @escaping () -> ()) {
        schedule0(ScheduledTask(task, { error in
            // do nothing
        }, .nanoseconds(0)))
    }
    
    private func schedule0(_ task: ScheduledTask) {
        tasksLock.lock()
        scheduledTasks.push(task)
        tasksLock.unlock()
        
        wakeupSelector()
    }
    private func wakeupSelector() {
        do {
            try selector.wakeup()
        } catch let err {
            fatalError("Error during Selector.wakeup(): \(err)")
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
            // spurious wakeup
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
            // No tasks to handle so just block
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
    
    public func run() throws {
        precondition(self.inEventLoop, "tried to run the EventLoop on the wrong thread.")
        defer {
            var tasksCopy = ContiguousArray<ScheduledTask>()
            
            tasksLock.lock()
            while let sched = scheduledTasks.pop() {
                tasksCopy.append(sched)
            }
            tasksLock.unlock()
            
            // Fail all the scheduled tasks.
            while let task = tasksCopy.first {
                task.fail(error: EventLoopError.shutdown)
            }
        }
        while lifecycleState != .closed {
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
                
                // all pending tasks are set to occur in the future, so we can stop looping.
                if tasksCopy.count == 0 {
                    break
                }
                
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
    
    fileprivate func close0() throws {
        if inEventLoop {
            self.lifecycleState = .closed
        } else {
            _ = self.submit(task: { () -> (Void) in
                self.lifecycleState = .closed
            })
        }
    }

    public func closeGently() -> EventLoopFuture<Void> {
        func closeGently0() -> EventLoopFuture<Void> {
            guard self.lifecycleState == .open else {
                return self.newFailedFuture(error: ChannelError.alreadyClosed)
            }
            self.lifecycleState = .closing
            return self.selector.closeGently(eventLoop: self)
        }
        if self.inEventLoop {
            return closeGently0()
        } else {
            let p: EventLoopPromise<Void> = self.newPromise()
            _ = self.submit {
                closeGently0().cascade(promise: p)
            }
            return p.futureResult
        }
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        self.closeGently().whenComplete { closeGentlyResult in
            let closeResult: ()? = try? self.close0()
            switch (closeGentlyResult, closeResult) {
            case (.success(()), .some(())):
                queue.async {
                    callback(nil)
                }
            case (.failure(let error), _):
                queue.async {
                    callback(error)
                }
            case (_, .none):
                queue.async {
                    callback(EventLoopError.shutdownFailed)
                }
            }
        }
    }
}

/**
 Provides an "endless" stream of `EventLoop`s to use.
 */
public protocol EventLoopGroup {
    /// Returns the next `EventLoop` to use.
    func next() -> EventLoop

    /// Shuts down the eventloop gracefully. This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void)
}

extension EventLoopGroup {
    public func shutdownGracefully(_ callback: @escaping (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }

    public func syncShutdownGracefully() throws {
        let errorStorageLock = Lock()
        var errorStorage: Error? = nil
        let continuation = DispatchWorkItem {}
        self.shutdownGracefully { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }
}

/*
 An `EventLoopGroup` which will create multiple `EventLoop`s, each tight to its own `Thread`.
 */
final public class MultiThreadedEventLoopGroup : EventLoopGroup {
    
    private let index = Atomic<Int>(value: 0)
    private let eventLoops: [SelectableEventLoop]

    private static func setupThreadAndEventLoop(name: String) -> SelectableEventLoop {
        let lock = Lock()
        /* the `loopUpAndRunningGroup` is done by the calling thread when the EventLoop has been created and was written to `_loop` */
        let loopUpAndRunningGroup = DispatchGroup()

        /* synchronised by `lock` */
        var _loop: SelectableEventLoop! = nil

        if #available(OSX 10.12, *) {
            loopUpAndRunningGroup.enter()
            let thread = Thread {
                do {
                    /* we try! this as this must work (just setting up kqueue/epoll) or else there's not much we can do here */
                    let l = try! SelectableEventLoop(thread: pthread_self())
                    lock.withLock {
                        _loop = l
                    }
                    loopUpAndRunningGroup.leave()
                    try l.run()
                } catch let err {
                    fatalError("unexpected error while executing EventLoop \(err)")
                }
            }
            thread.start()
            thread.name = name
            loopUpAndRunningGroup.wait()
            return lock.withLock { _loop }
        } else {
            fatalError("Unsupported platform / OS version")
        }
    }

    public init(numThreads: Int) {
        self.eventLoops = (0..<numThreads).map { threadNo in
            MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name: "SwiftNIO event loop thread #\(threadNo)")
        }
    }
    
    public func next() -> EventLoop {
        return eventLoops[(index.add(1) % eventLoops.count).abs()]
    }
    
    internal func unsafeClose() throws {
        for loop in eventLoops {
            // TODO: Should we log this somehow or just rethrow the first error ?
            _ = try loop.close0()
        }
    }

    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        // This method cannot perform its final cleanup using EventLoopFutures, because it requires that all
        // our event loops still be alive, and they may not be. Instead, we use Dispatch to manage
        // our shutdown signaling, and then do our cleanup once the DispatchQueue is empty.
        let g = DispatchGroup()
        let q = DispatchQueue(label: "nio.shutdownGracefullyQueue", target: queue)
        var error: Error? = nil

        for loop in self.eventLoops {
            g.enter()
            loop.closeGently().whenComplete {
                switch $0 {
                case .success:
                    break
                case .failure(let err):
                    q.sync { error = err }
                }
                g.leave()
            }
        }

        g.notify(queue: q) {
            let failure = self.eventLoops.map { try? $0.close0() }.filter { $0 == nil }.count > 0
            if failure {
                error = EventLoopError.shutdownFailed
            }

            callback(error)
        }
    }
}

private final class ScheduledTask {
    let task: () -> ()
    private let failFn: (Error) ->()
    private let readyTime: UInt64
    
    init(_ task: @escaping () -> (), _ failFn: @escaping (Error) -> (), _ time: TimeAmount) {
        self.task = task
        self.failFn = failFn
        self.readyTime = time.nanoseconds + DispatchTime.now().uptimeNanoseconds
    }
    
    func readyIn(_ t: DispatchTime) -> UInt64 {
        if readyTime < t.uptimeNanoseconds {
            return 0
        }
        return readyTime - t.uptimeNanoseconds
    }
    
    func fail(error: Error) {
        failFn(error)
    }
}

extension ScheduledTask : Comparable {
    public static func < (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }
    public static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs === rhs
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
    case cancelled
    case shutdown
    case shutdownFailed
}
