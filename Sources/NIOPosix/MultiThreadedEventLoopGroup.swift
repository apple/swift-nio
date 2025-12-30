//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import NIOConcurrencyHelpers
import NIOCore

#if canImport(Dispatch)
import Dispatch
#endif

@usableFromInline
struct NIORegistration: Registration {
    enum ChannelType {
        case serverSocketChannel(ServerSocketChannel)
        case socketChannel(SocketChannel)
        case datagramChannel(DatagramChannel)
        case pipeChannel(PipeChannel, PipeChannel.Direction)
    }

    var channel: ChannelType

    /// The `SelectorEventSet` in which this `NIORegistration` is interested in.
    @usableFromInline
    var interested: SelectorEventSet

    /// The registration ID for this `NIORegistration` used by the `Selector`.
    @usableFromInline
    var registrationID: SelectorRegistrationID
}

@available(*, unavailable)
extension NIORegistration: Sendable {}

/// Called per `NIOThread` that is created for an EventLoop to do custom initialization of the `NIOThread` before the actual `EventLoop` is run on it.
typealias ThreadInitializer = (NIOThread) -> Void

/// An `EventLoopGroup` which will create multiple `EventLoop`s, each tied to its own `NIOThread`.
///
/// The effect of initializing a `MultiThreadedEventLoopGroup` is to spawn `numberOfThreads` fresh threads which will
/// all run their own `EventLoop`. Those threads will not be shut down until `shutdownGracefully` or
/// `syncShutdownGracefully` is called.
///
/// - warning: Unit tests often spawn one `MultiThreadedEventLoopGroup` per unit test to force isolation between the
///            tests. In those cases it's important to shut the `MultiThreadedEventLoopGroup` down at the end of the
///            test. A good place to start a `MultiThreadedEventLoopGroup` is the `setUp` method of your `XCTestCase`
///            subclass, a good place to shut it down is the `tearDown` method.
public final class MultiThreadedEventLoopGroup: EventLoopGroup {
    typealias _ShutdownGracefullyCallback = @Sendable (Error?) -> Void

    private enum RunState {
        case running
        case closing([(DispatchQueue, _ShutdownGracefullyCallback)])
        case closed(Error?)
    }

    internal enum _CanBeShutDown {
        case yes
        case no
        case notByUser
    }

    private static let threadSpecificEventLoop = ThreadSpecificVariable<SelectableEventLoop>()

    private let myGroupID: Int
    private let index = ManagedAtomic<Int>(0)
    private var eventLoops: [SelectableEventLoop]
    private let shutdownLock: NIOLock = NIOLock()
    private let threadNamePrefix: String
    private var runState: RunState = .running
    private let canBeShutDown: _CanBeShutDown

    private static func runTheLoop(
        thread: NIOThread,
        uniqueID: SelectableEventLoopUniqueID,
        parentGroup: MultiThreadedEventLoopGroup?,  // nil iff thread take-over
        canEventLoopBeShutdownIndividually: Bool,
        selectorFactory: @escaping (NIOThread) throws -> NIOPosix.Selector<NIORegistration>,
        initializer: @escaping ThreadInitializer,
        metricsDelegate: NIOEventLoopMetricsDelegate?,
        _ callback: @escaping (SelectableEventLoop) -> Void
    ) {
        assert(thread.isCurrentSlow)
        uniqueID.attachToCurrentThread()
        defer {
            uniqueID.detachFromCurrentThread()
        }
        initializer(thread)

        do {
            let loop = SelectableEventLoop(
                thread: thread,
                uniqueID: uniqueID,
                parentGroup: parentGroup,
                selector: try selectorFactory(thread),
                canBeShutdownIndividually: canEventLoopBeShutdownIndividually,
                metricsDelegate: metricsDelegate
            )
            Self.threadSpecificEventLoop.currentValue = loop
            defer {
                Self.threadSpecificEventLoop.currentValue = nil
            }
            callback(loop)
            try loop.run()
        } catch {
            // We fatalError here because the only reasons this can be hit is if the underlying kqueue/epoll give us
            // errors that we cannot handle which is an unrecoverable error for us.
            fatalError("Unexpected error while running SelectableEventLoop: \(error).")
        }
    }

    private static func setupThreadAndEventLoop(
        name: String,
        uniqueID: SelectableEventLoopUniqueID,
        parentGroup: MultiThreadedEventLoopGroup,
        selectorFactory: @escaping (NIOThread) throws -> NIOPosix.Selector<NIORegistration>,
        initializer: @escaping ThreadInitializer,
        metricsDelegate: NIOEventLoopMetricsDelegate?
    ) -> SelectableEventLoop {
        let lock = ConditionLock(value: 0)

        // synchronised by `lock`
        var _loop: SelectableEventLoop! = nil

        NIOThread.spawnAndRun(name: name) { t in
            MultiThreadedEventLoopGroup.runTheLoop(
                thread: t,
                uniqueID: uniqueID,
                parentGroup: parentGroup,
                canEventLoopBeShutdownIndividually: false,  // part of MTELG
                selectorFactory: selectorFactory,
                initializer: initializer,
                metricsDelegate: metricsDelegate
            ) { l in
                lock.lock(whenValue: 0)
                _loop = l
                lock.unlock(withValue: 1)
            }
        }
        lock.lock(whenValue: 1)
        defer { lock.unlock() }
        return _loop!
    }

    /// Creates a `MultiThreadedEventLoopGroup` instance which uses `numberOfThreads`.
    ///
    /// - Note: Don't forget to call `shutdownGracefully` or `syncShutdownGracefully` when you no longer need this
    ///         `EventLoopGroup`. If you forget to shut the `EventLoopGroup` down you will leak `numberOfThreads`
    ///         (kernel) threads which are costly resources. This is especially important in unit tests where one
    ///         `MultiThreadedEventLoopGroup` is started per test case.
    ///
    /// - arguments:
    ///   - numberOfThreads: The number of `Threads` to use.
    public convenience init(numberOfThreads: Int) {
        self.init(
            numberOfThreads: numberOfThreads,
            canBeShutDown: .yes,
            metricsDelegate: nil,
            selectorFactory: NIOPosix.Selector<NIORegistration>.init
        )
    }

    /// Creates a `MultiThreadedEventLoopGroup` instance which uses `numberOfThreads`.
    ///
    /// - Note: Don't forget to call `shutdownGracefully` or `syncShutdownGracefully` when you no longer need this
    ///         `EventLoopGroup`. If you forget to shut the `EventLoopGroup` down you will leak `numberOfThreads`
    ///         (kernel) threads which are costly resources. This is especially important in unit tests where one
    ///         `MultiThreadedEventLoopGroup` is started per test case.
    ///
    /// - Parameters:
    ///    - numberOfThreads: The number of `Threads` to use.
    ///    - metricsDelegate: Delegate for collecting information from this eventloop
    public convenience init(numberOfThreads: Int, metricsDelegate: NIOEventLoopMetricsDelegate) {
        self.init(
            numberOfThreads: numberOfThreads,
            canBeShutDown: .yes,
            metricsDelegate: metricsDelegate,
            selectorFactory: NIOPosix.Selector<NIORegistration>.init
        )
    }

    /// Create a ``MultiThreadedEventLoopGroup`` that cannot be shut down and must not be `deinit`ed.
    ///
    /// This is only useful for global singletons.
    public static func _makePerpetualGroup(
        threadNamePrefix: String,
        numberOfThreads: Int
    ) -> MultiThreadedEventLoopGroup {
        self.init(
            numberOfThreads: numberOfThreads,
            canBeShutDown: .no,
            threadNamePrefix: threadNamePrefix,
            metricsDelegate: nil,
            selectorFactory: NIOPosix.Selector<NIORegistration>.init
        )
    }

    internal convenience init(
        numberOfThreads: Int,
        metricsDelegate: NIOEventLoopMetricsDelegate?,
        selectorFactory: @escaping (NIOThread) throws -> NIOPosix.Selector<NIORegistration>
    ) {
        precondition(numberOfThreads > 0, "numberOfThreads must be positive")
        let initializers: [ThreadInitializer] = Array(repeating: { _ in }, count: numberOfThreads)
        self.init(
            threadInitializers: initializers,
            canBeShutDown: .yes,
            metricsDelegate: metricsDelegate,
            selectorFactory: selectorFactory
        )
    }

    internal convenience init(
        numberOfThreads: Int,
        canBeShutDown: _CanBeShutDown,
        threadNamePrefix: String,
        metricsDelegate: NIOEventLoopMetricsDelegate?,
        selectorFactory: @escaping (NIOThread) throws -> NIOPosix.Selector<NIORegistration>
    ) {
        precondition(numberOfThreads > 0, "numberOfThreads must be positive")
        let initializers: [ThreadInitializer] = Array(repeating: { _ in }, count: numberOfThreads)
        self.init(
            threadInitializers: initializers,
            canBeShutDown: canBeShutDown,
            threadNamePrefix: threadNamePrefix,
            metricsDelegate: metricsDelegate,
            selectorFactory: selectorFactory
        )
    }

    internal convenience init(
        numberOfThreads: Int,
        canBeShutDown: _CanBeShutDown,
        metricsDelegate: NIOEventLoopMetricsDelegate?,
        selectorFactory: @escaping (NIOThread) throws -> NIOPosix.Selector<NIORegistration>
    ) {
        precondition(numberOfThreads > 0, "numberOfThreads must be positive")
        let initializers: [ThreadInitializer] = Array(repeating: { _ in }, count: numberOfThreads)
        self.init(
            threadInitializers: initializers,
            canBeShutDown: canBeShutDown,
            metricsDelegate: metricsDelegate,
            selectorFactory: selectorFactory
        )
    }

    internal convenience init(
        threadInitializers: [ThreadInitializer],
        metricsDelegate: NIOEventLoopMetricsDelegate?,
        selectorFactory: @escaping (NIOThread) throws -> NIOPosix.Selector<NIORegistration> = NIOPosix.Selector<
            NIORegistration
        >
        .init
    ) {
        self.init(
            threadInitializers: threadInitializers,
            canBeShutDown: .yes,
            metricsDelegate: metricsDelegate,
            selectorFactory: selectorFactory
        )
    }

    /// Creates a `MultiThreadedEventLoopGroup` instance which uses the given `ThreadInitializer`s. One `NIOThread` per `ThreadInitializer` is created and used.
    ///
    /// - arguments:
    ///   - threadInitializers: The `ThreadInitializer`s to use.
    internal init(
        threadInitializers: [ThreadInitializer],
        canBeShutDown: _CanBeShutDown,
        threadNamePrefix: String = "NIO-ELT-",
        metricsDelegate: NIOEventLoopMetricsDelegate?,
        selectorFactory: @escaping (NIOThread) throws -> Selector<NIORegistration> = Selector<NIORegistration>
            .init
    ) {
        self.threadNamePrefix = threadNamePrefix
        let firstLoopID = SelectableEventLoopUniqueID.makeNextGroup()
        self.myGroupID = firstLoopID.groupID
        self.canBeShutDown = canBeShutDown
        self.eventLoops = []  // Just so we're fully initialised and can vend `self` to the `SelectableEventLoop`.
        var loopUniqueID = firstLoopID
        self.eventLoops = threadInitializers.map { initializer in
            // Maximum name length on linux is 16 by default.
            let ev = MultiThreadedEventLoopGroup.setupThreadAndEventLoop(
                name: "\(threadNamePrefix)\(loopUniqueID.groupID)-#\(loopUniqueID.loopID)",
                uniqueID: loopUniqueID,
                parentGroup: self,
                selectorFactory: selectorFactory,
                initializer: initializer,
                metricsDelegate: metricsDelegate
            )
            loopUniqueID.nextLoop()
            return ev
        }
    }

    deinit {
        assert(
            self.canBeShutDown != .no,
            "Perpetual MTELG shut down, you must ensure that perpetual MTELGs don't deinit"
        )
    }

    /// Returns the `EventLoop` for the calling thread.
    ///
    /// - Returns: The current `EventLoop` for the calling thread or `nil` if none is assigned to the thread.
    public static var currentEventLoop: EventLoop? {
        self.currentSelectableEventLoop
    }

    internal static var currentSelectableEventLoop: SelectableEventLoop? {
        threadSpecificEventLoop.currentValue
    }

    /// Returns an `EventLoopIterator` over the `EventLoop`s in this `MultiThreadedEventLoopGroup`.
    ///
    /// - Returns: `EventLoopIterator`
    public func makeIterator() -> EventLoopIterator {
        EventLoopIterator(self.eventLoops)
    }

    /// Returns the next `EventLoop` from this `MultiThreadedEventLoopGroup`.
    ///
    /// `MultiThreadedEventLoopGroup` uses _round robin_ across all its `EventLoop`s to select the next one.
    ///
    /// - Returns: The next `EventLoop` to use.
    public func next() -> EventLoop {
        eventLoops[abs(index.loadThenWrappingIncrement(ordering: .relaxed) % eventLoops.count)]
    }

    /// Returns the current `EventLoop` if we are on an `EventLoop` of this `MultiThreadedEventLoopGroup` instance.
    ///
    /// - Returns: The `EventLoop`.
    public func any() -> EventLoop {
        if let loop = Self.currentSelectableEventLoop,
            // We are on `loop`'s thread, so we may ask for the its parent group.
            loop.parentGroupCallableFromThisEventLoopOnly() === self
        {
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
    /// - Parameters:
    ///    - queue: The `DispatchQueue` to run `handler` on when the shutdown operation completes.
    ///    - handler: The handler which is called after the shutdown operation completes. The parameter will be `nil`
    ///               on success and contain the `Error` otherwise.
    @preconcurrency
    public func shutdownGracefully(queue: DispatchQueue, _ handler: @escaping @Sendable (Error?) -> Void) {
        self._shutdownGracefully(queue: queue, handler)
    }

    internal func _shutdownGracefully(
        queue: DispatchQueue,
        allowShuttingDownOverride: Bool = false,
        _ handler: @escaping _ShutdownGracefullyCallback
    ) {
        switch self.canBeShutDown {
        case .yes:
            ()  // ok
        case .no:
            queue.async {
                handler(EventLoopError._unsupportedOperation)
            }
            return
        case .notByUser:
            guard allowShuttingDownOverride else {
                queue.async {
                    handler(EventLoopError._unsupportedOperation)
                }
                return
            }
        }

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

        let result: NIOLockedValueBox<Result<Void, Error>> = NIOLockedValueBox(.success(()))

        for loop in self.eventLoops {
            g.enter()
            loop.initiateClose(queue: q) { closeResult in
                switch closeResult {
                case .success:
                    ()
                case .failure(let error):
                    result.withLockedValue {
                        $0 = .failure(error)
                    }
                }
                g.leave()
            }
        }

        g.notify(queue: q) {
            for loop in self.eventLoops {
                loop.syncFinaliseClose(joinThread: true)
            }
            let (overallError, queueCallbackPairs): (Error?, [(DispatchQueue, _ShutdownGracefullyCallback)]) = self
                .shutdownLock.withLock {
                    switch self.runState {
                    case .closed, .running:
                        preconditionFailure(
                            "MultiThreadedEventLoopGroup in illegal state when closing: \(self.runState)"
                        )
                    case .closing(let callbacks):
                        let overallError: Error? = result.withLockedValue {
                            switch $0 {
                            case .success:
                                return nil
                            case .failure(let error):
                                return error
                            }
                        }
                        self.runState = .closed(overallError)
                        return (overallError, callbacks)
                    }
                }

            queue.async {
                handler(overallError)
            }
            for queueCallbackPair in queueCallbackPairs {
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
    /// - Parameters:
    ///   - callback: Called _on_ the `EventLoop` that the calling thread was converted to, providing you the
    ///                 `EventLoop` reference. Just like usually on the `EventLoop`, do not block in `callback`.
    public static func withCurrentThreadAsEventLoop(_ callback: @escaping (EventLoop) -> Void) {
        NIOThread.withCurrentThread { callingThread in
            MultiThreadedEventLoopGroup.runTheLoop(
                thread: callingThread,
                uniqueID: .makeNextGroup(),
                parentGroup: nil,
                canEventLoopBeShutdownIndividually: true,
                selectorFactory: NIOPosix.Selector<NIORegistration>.init,
                initializer: { _ in },
                metricsDelegate: nil,
                { loop in
                    loop.assertInEventLoop()
                    callback(loop)
                }
            )
        }
    }

    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        if let eventLoop = MultiThreadedEventLoopGroup.currentEventLoop {
            preconditionFailure(
                """
                BUG DETECTED: syncShutdownGracefully() must not be called when on an EventLoop.
                Calling syncShutdownGracefully() on any EventLoop can lead to deadlocks.
                Current eventLoop: \(eventLoop)
                """,
                file: file,
                line: line
            )
        }
    }
}

extension MultiThreadedEventLoopGroup: @unchecked Sendable {}

extension MultiThreadedEventLoopGroup: CustomStringConvertible {
    public var description: String {
        "MultiThreadedEventLoopGroup { threadPattern = \(self.threadNamePrefix)\(self.myGroupID)-#* }"
    }
}

@usableFromInline
struct ErasedUnownedJob: Sendable {
    @usableFromInline
    let erasedJob: any Sendable

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    init(job: UnownedJob) {
        self.erasedJob = job
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @inlinable
    var unownedJob: UnownedJob {
        // This force-cast is safe since we only store an UnownedJob
        self.erasedJob as! UnownedJob
    }
}

@usableFromInline
internal struct ScheduledTask {
    @usableFromInline
    enum Kind {
        case task(task: () -> Void, failFn: (Error) -> Void)
        case callback(any NIOScheduledCallbackHandler)
    }

    @usableFromInline
    let kind: Kind

    /// The id of the scheduled task.
    ///
    /// - Important: This id has two purposes. First, it is used to give this struct an identity so that we can implement ``Equatable``
    ///     Second, it is used to give the tasks an order which we use to execute them.
    ///     This means, the ids need to be unique for a given ``SelectableEventLoop`` and they need to be in ascending order.
    @usableFromInline
    let id: UInt64

    @usableFromInline
    internal let readyTime: NIODeadline

    @usableFromInline
    init(id: UInt64, _ task: @escaping () -> Void, _ failFn: @escaping (Error) -> Void, _ time: NIODeadline) {
        self.id = id
        self.readyTime = time
        self.kind = .task(task: task, failFn: failFn)
    }

    @usableFromInline
    init(id: UInt64, _ handler: any NIOScheduledCallbackHandler, _ time: NIODeadline) {
        self.id = id
        self.readyTime = time
        self.kind = .callback(handler)
    }
}

extension ScheduledTask: CustomStringConvertible {
    @usableFromInline
    var description: String {
        "ScheduledTask(readyTime: \(self.readyTime))"
    }
}

extension ScheduledTask: Comparable {
    @usableFromInline
    static func < (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        if lhs.readyTime == rhs.readyTime {
            return lhs.id < rhs.id
        } else {
            return lhs.readyTime < rhs.readyTime
        }
    }

    @usableFromInline
    static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        lhs.id == rhs.id
    }
}

@available(*, unavailable)
extension ScheduledTask: Sendable {}

@available(*, unavailable)
extension ScheduledTask.Kind: Sendable {}

extension NIODeadline {
    @inlinable
    func readyIn(_ target: NIODeadline) -> TimeAmount {
        if self < target {
            return .nanoseconds(0)
        }
        return self - target
    }
}

extension MultiThreadedEventLoopGroup {
    /// Start & automatically shut down a new ``MultiThreadedEventLoopGroup``.
    ///
    /// This method allows to start & automatically dispose of a ``MultiThreadedEventLoopGroup`` following the principle of Structured Concurrency.
    /// The ``MultiThreadedEventLoopGroup`` is guaranteed to be shut down upon return, whether `body` throws or not.
    ///
    /// - Note: Outside of top-level code (typically in your main function) or tests, you should generally not use this function to create a new
    ///         ``MultiThreadedEventLoopGroup`` because creating & destroying threads is expensive. Instead, share an existing one.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public static func withEventLoopGroup<Result>(
        numberOfThreads: Int,
        metricsDelegate: (any NIOEventLoopMetricsDelegate)? = nil,
        isolation actor: isolated (any Actor)? = #isolation,
        _ body: (MultiThreadedEventLoopGroup) async throws -> Result
    ) async throws -> Result {
        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: numberOfThreads,
            canBeShutDown: .notByUser,  // We want to prevent direct user shutdowns.
            metricsDelegate: metricsDelegate,
            selectorFactory: NIOPosix.Selector<NIORegistration>.init
        )
        return try await asyncDo {
            try await body(group)
        } finally: { _ in
            let q = DispatchQueue(label: "MTELG.shutdown")
            let _: () = try await withCheckedThrowingContinuation { (cont) -> Void in
                group._shutdownGracefully(queue: q, allowShuttingDownOverride: true) { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }
}
