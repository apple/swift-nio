//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOConcurrencyHelpers
import Dispatch

struct NIORegistration: Registration {
    enum ChannelType {
        case serverSocketChannel(ServerSocketChannel)
        case socketChannel(SocketChannel)
        case datagramChannel(DatagramChannel)
        case pipeChannel(PipeChannel, PipeChannel.Direction)
    }

    var channel: ChannelType

    /// The `SelectorEventSet` in which this `NIORegistration` is interested in.
    var interested: SelectorEventSet

    /// The registration ID for this `NIORegistration` used by the `Selector`.
    var registrationID: SelectorRegistrationID
}

private let nextEventLoopGroupID = NIOAtomic.makeAtomic(value: 0)

/// Called per `NIOThread` that is created for an EventLoop to do custom initialization of the `NIOThread` before the actual `EventLoop` is run on it.
typealias ThreadInitializer = (NIOThread) -> Void

/// An `EventLoopGroup` which will create multiple `EventLoop`s, each tied to its own `NIOThread`.
///
/// The effect of initializing a `MultiThreadedEventLoopGroup` is to spawn `numberOfThreads` fresh threads which will
/// all run their own `EventLoop`. Those threads will not be shut down until `shutdownGracefully` or
/// `syncShutdownGracefully` is called.
///
/// - note: It's good style to call `MultiThreadedEventLoopGroup.shutdownGracefully` or
///         `MultiThreadedEventLoopGroup.syncShutdownGracefully` when you no longer need this `EventLoopGroup`. In
///         many cases that is just before your program exits.
/// - warning: Unit tests often spawn one `MultiThreadedEventLoopGroup` per unit test to force isolation between the
///            tests. In those cases it's important to shut the `MultiThreadedEventLoopGroup` down at the end of the
///            test. A good place to start a `MultiThreadedEventLoopGroup` is the `setUp` method of your `XCTestCase`
///            subclass, a good place to shut it down is the `tearDown` method.
public final class MultiThreadedEventLoopGroup: EventLoopGroup {

    private enum RunState {
        case running
        case closing([(DispatchQueue, (Error?) -> Void)])
        case closed(Error?)
    }

    private static let threadSpecificEventLoop = ThreadSpecificVariable<SelectableEventLoop>()

    private let myGroupID: Int
    private let index = NIOAtomic<Int>.makeAtomic(value: 0)
    private var eventLoops: [SelectableEventLoop]
    private let shutdownLock: Lock = Lock()
    private var runState: RunState = .running

    private static func runTheLoop(thread: NIOThread,
                                   parentGroup: MultiThreadedEventLoopGroup? /* nil iff thread take-over */,
                                   canEventLoopBeShutdownIndividually: Bool,
                                   selectorFactory: @escaping () throws -> NIOPosix.Selector<NIORegistration>,
                                   initializer: @escaping ThreadInitializer,
                                   _ callback: @escaping (SelectableEventLoop) -> Void) {
        assert(NIOThread.current == thread)
        initializer(thread)

        do {
            let loop = SelectableEventLoop(thread: thread,
                                           parentGroup: parentGroup,
                                           selector: try selectorFactory(),
                                           canBeShutdownIndividually: canEventLoopBeShutdownIndividually)
            threadSpecificEventLoop.currentValue = loop
            defer {
                threadSpecificEventLoop.currentValue = nil
            }
            callback(loop)
            try loop.run()
        } catch {
            // We fatalError here because the only reasons this can be hit is if the underlying kqueue/epoll give us
            // errors that we cannot handle which is an unrecoverable error for us.
            fatalError("Unexpected error while running SelectableEventLoop: \(error).")
        }
    }

    private static func setupThreadAndEventLoop(name: String,
                                                parentGroup: MultiThreadedEventLoopGroup,
                                                selectorFactory: @escaping () throws -> NIOPosix.Selector<NIORegistration>,
                                                initializer: @escaping ThreadInitializer)  -> SelectableEventLoop {
        let lock = Lock()
        /* the `loopUpAndRunningGroup` is done by the calling thread when the EventLoop has been created and was written to `_loop` */
        let loopUpAndRunningGroup = DispatchGroup()

        /* synchronised by `lock` */
        var _loop: SelectableEventLoop! = nil

        loopUpAndRunningGroup.enter()
        NIOThread.spawnAndRun(name: name, detachThread: false) { t in
            MultiThreadedEventLoopGroup.runTheLoop(thread: t,
                                                   parentGroup: parentGroup,
                                                   canEventLoopBeShutdownIndividually: false, // part of MTELG
                                                   selectorFactory: selectorFactory,
                                                   initializer: initializer) { l in
                lock.withLock {
                    _loop = l
                }
                loopUpAndRunningGroup.leave()
            }
        }
        loopUpAndRunningGroup.wait()
        return lock.withLock { _loop }
    }

    /// Creates a `MultiThreadedEventLoopGroup` instance which uses `numberOfThreads`.
    ///
    /// - note: Don't forget to call `shutdownGracefully` or `syncShutdownGracefully` when you no longer need this
    ///         `EventLoopGroup`. If you forget to shut the `EventLoopGroup` down you will leak `numberOfThreads`
    ///         (kernel) threads which are costly resources. This is especially important in unit tests where one
    ///         `MultiThreadedEventLoopGroup` is started per test case.
    ///
    /// - arguments:
    ///     - numberOfThreads: The number of `Threads` to use.
    public convenience init(numberOfThreads: Int) {
        self.init(numberOfThreads: numberOfThreads, selectorFactory: NIOPosix.Selector<NIORegistration>.init)
    }

    internal convenience init(numberOfThreads: Int,
                              selectorFactory: @escaping () throws -> NIOPosix.Selector<NIORegistration>) {
        precondition(numberOfThreads > 0, "numberOfThreads must be positive")
        let initializers: [ThreadInitializer] = Array(repeating: { _ in }, count: numberOfThreads)
        self.init(threadInitializers: initializers, selectorFactory: selectorFactory)
    }

    /// Creates a `MultiThreadedEventLoopGroup` instance which uses the given `ThreadInitializer`s. One `NIOThread` per `ThreadInitializer` is created and used.
    ///
    /// - arguments:
    ///     - threadInitializers: The `ThreadInitializer`s to use.
    internal init(threadInitializers: [ThreadInitializer],
                  selectorFactory: @escaping () throws -> NIOPosix.Selector<NIORegistration> = NIOPosix.Selector<NIORegistration>.init) {
        let myGroupID = nextEventLoopGroupID.add(1)
        self.myGroupID = myGroupID
        var idx = 0
        self.eventLoops = [] // Just so we're fully initialised and can vend `self` to the `SelectableEventLoop`.
        self.eventLoops = threadInitializers.map { initializer in
            // Maximum name length on linux is 16 by default.
            let ev = MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name: "NIO-ELT-\(myGroupID)-#\(idx)",
                                                                         parentGroup: self,
                                                                         selectorFactory: selectorFactory,
                                                                         initializer: initializer)
            idx += 1
            return ev
        }
    }

    /// Returns the `EventLoop` for the calling thread.
    ///
    /// - returns: The current `EventLoop` for the calling thread or `nil` if none is assigned to the thread.
    public static var currentEventLoop: EventLoop? {
        return self.currentSelectableEventLoop
    }

    internal static var currentSelectableEventLoop: SelectableEventLoop? {
        return threadSpecificEventLoop.currentValue
    }

    /// Returns an `EventLoopIterator` over the `EventLoop`s in this `MultiThreadedEventLoopGroup`.
    ///
    /// - returns: `EventLoopIterator`
    public func makeIterator() -> EventLoopIterator {
        return EventLoopIterator(self.eventLoops)
    }

    /// Returns the next `EventLoop` from this `MultiThreadedEventLoopGroup`.
    ///
    /// `MultiThreadedEventLoopGroup` uses _round robin_ across all its `EventLoop`s to select the next one.
    ///
    /// - returns: The next `EventLoop` to use.
    public func next() -> EventLoop {
        return eventLoops[abs(index.add(1) % eventLoops.count)]
    }

    /// Returns the current `EventLoop` if we are on an `EventLoop` of this `MultiThreadedEventLoopGroup` instance.
    ///
    /// - returns: The `EventLoop`.
    public func any() -> EventLoop {
        if let loop = Self.currentSelectableEventLoop,
           // We are on `loop`'s thread, so we may ask for the its parent group.
           loop.parentGroupCallableFromThisEventLoopOnly() === self {
            // Nice, we can return this.
            loop.assertInEventLoop()
            return loop
        } else {
            // Oh well, let's just vend the next one then.
            return self.next()
        }
    }

    /// Shut this `MultiThreadedEventLoopGroup` down which causes the `EventLoop`s and their associated threads to be
    /// shut down and release their resources.
    ///
    /// Even though calling `shutdownGracefully` more than once should be avoided, it is safe to do so and execution
    /// of the `handler` is guaranteed.
    ///
    /// - parameters:
    ///    - queue: The `DispatchQueue` to run `handler` on when the shutdown operation completes.
    ///    - handler: The handler which is called after the shutdown operation completes. The parameter will be `nil`
    ///               on success and contain the `Error` otherwise.
    public func shutdownGracefully(queue: DispatchQueue, _ handler: @escaping (Error?) -> Void) {
        // This method cannot perform its final cleanup using EventLoopFutures, because it requires that all
        // our event loops still be alive, and they may not be. Instead, we use Dispatch to manage
        // our shutdown signaling, and then do our cleanup once the DispatchQueue is empty.
        let g = DispatchGroup()
        let q = DispatchQueue(label: "nio.shutdownGracefullyQueue", target: queue)
        let wasRunning: Bool = self.shutdownLock.withLock {
            // We need to check the current `runState` and react accordingly.
            switch self.runState {
            case .running:
                // If we are still running, we set the `runState` to `closing`,
                // so that potential future invocations know, that the shutdown
                // has already been initiaited.
                self.runState = .closing([])
                return true
            case .closing(var callbacks):
                // If we are currently closing, we need to register the `handler`
                // for invocation after the shutdown is completed.
                callbacks.append((q, handler))
                self.runState = .closing(callbacks)
                return false
            case .closed(let error):
                // If we are already closed, we can directly dispatch the `handler`
                q.async {
                    handler(error)
                }
                return false
            }
        }

        // If the `runState` was not `running` when `shutdownGracefully` was called,
        // the shutdown has already been initiated and we have to return here.
        guard wasRunning else {
            return
        }

        var result: Result<Void, Error> = .success(())

        for loop in self.eventLoops {
            g.enter()
            loop.initiateClose(queue: q) { closeResult in
                switch closeResult {
                case .success:
                    ()
                case .failure(let error):
                    result = .failure(error)
                }
                g.leave()
            }
        }

        g.notify(queue: q) {
            for loop in self.eventLoops {
                loop.syncFinaliseClose(joinThread: true)
            }
            var overallError: Error?
            var queueCallbackPairs: [(DispatchQueue, (Error?) -> Void)]? = nil
            self.shutdownLock.withLock {
                switch self.runState {
                case .closed, .running:
                    preconditionFailure("MultiThreadedEventLoopGroup in illegal state when closing: \(self.runState)")
                case .closing(let callbacks):
                    queueCallbackPairs = callbacks
                    switch result {
                    case .success:
                        overallError = nil
                    case .failure(let error):
                        overallError = error
                    }
                    self.runState = .closed(overallError)
                }
            }

            queue.async {
                handler(overallError)
            }
            for queueCallbackPair in queueCallbackPairs! {
                queueCallbackPair.0.async {
                    queueCallbackPair.1(overallError)
                }
            }
        }
    }

    /// Convert the calling thread into an `EventLoop`.
    ///
    /// This function will not return until the `EventLoop` has stopped. You can initiate stopping the `EventLoop` by
    /// calling `eventLoop.shutdownGracefully` which will eventually make this function return.
    ///
    /// - parameters:
    ///     - callback: Called _on_ the `EventLoop` that the calling thread was converted to, providing you the
    ///                 `EventLoop` reference. Just like usually on the `EventLoop`, do not block in `callback`.
    public static func withCurrentThreadAsEventLoop(_ callback: @escaping (EventLoop) -> Void) {
        let callingThread = NIOThread.current
        MultiThreadedEventLoopGroup.runTheLoop(thread: callingThread,
                                               parentGroup: nil,
                                               canEventLoopBeShutdownIndividually: true,
                                               selectorFactory: NIOPosix.Selector<NIORegistration>.init,
                                               initializer: { _ in }) { loop in
            loop.assertInEventLoop()
            callback(loop)
        }
    }

    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        if let eventLoop = MultiThreadedEventLoopGroup.currentEventLoop {
            preconditionFailure("""
            BUG DETECTED: syncShutdownGracefully() must not be called when on an EventLoop.
            Calling syncShutdownGracefully() on any EventLoop can lead to deadlocks.
            Current eventLoop: \(eventLoop)
            """, file: file, line: line)
        }
    }
}

extension MultiThreadedEventLoopGroup: CustomStringConvertible {
    public var description: String {
        return "MultiThreadedEventLoopGroup { threadPattern = NIO-ELT-\(self.myGroupID)-#* }"
    }
}

@usableFromInline
internal struct ScheduledTask {
    /// The id of the scheduled task.
    ///
    /// - Important: This id has two purposes. First, it is used to give this struct an identity so that we can implement ``Equatable``
    ///     Second, it is used to give the tasks an order which we use to execute them.
    ///     This means, the ids need to be unique for a given ``SelectableEventLoop`` and they need to be in ascending order.
    @usableFromInline
    let id: UInt64
    let task: () -> Void
    private let failFn: (Error) ->()
    @usableFromInline
    internal let _readyTime: NIODeadline

    @usableFromInline
    init(id: UInt64, _ task: @escaping () -> Void, _ failFn: @escaping (Error) -> Void, _ time: NIODeadline) {
        self.id = id
        self.task = task
        self.failFn = failFn
        self._readyTime = time
    }

    func readyIn(_ t: NIODeadline) -> TimeAmount {
        if _readyTime < t {
            return .nanoseconds(0)
        }
        return _readyTime - t
    }

    func fail(_ error: Error) {
        failFn(error)
    }
}

extension ScheduledTask: CustomStringConvertible {
    @usableFromInline
    var description: String {
        return "ScheduledTask(readyTime: \(self._readyTime))"
    }
}

extension ScheduledTask: Comparable {
    @usableFromInline
    static func < (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        if lhs._readyTime == rhs._readyTime {
            return lhs.id < rhs.id
        } else {
            return lhs._readyTime < rhs._readyTime
        }
    }

    @usableFromInline
    static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs.id == rhs.id
    }
}
