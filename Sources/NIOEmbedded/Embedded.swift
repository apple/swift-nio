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

import Dispatch
import _NIODataStructures
import NIOCore


private struct EmbeddedScheduledTask {
    let id: UInt64
    let task: () -> Void
    let failFn: (Error) -> ()
    let readyTime: NIODeadline
    let insertOrder: UInt64

    init(id: UInt64, readyTime: NIODeadline, insertOrder: UInt64, task: @escaping () -> Void, _ failFn: @escaping (Error) -> ()) {
        self.id = id
        self.readyTime = readyTime
        self.insertOrder = insertOrder
        self.task = task
        self.failFn = failFn
    }

    func fail(_ error: Error) {
        self.failFn(error)
    }
}

extension EmbeddedScheduledTask: Comparable {
    static func < (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        if lhs.readyTime == rhs.readyTime {
            return lhs.insertOrder < rhs.insertOrder
        } else {
            return lhs.readyTime < rhs.readyTime
        }
    }

    static func == (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs.id == rhs.id
    }
}

/// An `EventLoop` that is embedded in the current running context with no external
/// control.
///
/// Unlike more complex `EventLoop`s, such as `SelectableEventLoop`, the `EmbeddedEventLoop`
/// has no proper eventing mechanism. Instead, reads and writes are fully controlled by the
/// entity that instantiates the `EmbeddedEventLoop`. This property makes `EmbeddedEventLoop`
/// of limited use for many application purposes, but highly valuable for testing and other
/// kinds of mocking.
///
/// Time is controllable on an `EmbeddedEventLoop`. It begins at `NIODeadline.uptimeNanoseconds(0)`
/// and may be advanced by a fixed amount by using `advanceTime(by:)`, or advanced to a point in
/// time with `advanceTime(to:)`.
///
/// - warning: Unlike `SelectableEventLoop`, `EmbeddedEventLoop` **is not thread-safe**. This
///     is because it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into the `EmbeddedEventLoop` in an
///     unsynchronized fashion.
public final class EmbeddedEventLoop: EventLoop {
    /// The current "time" for this event loop. This is an amount in nanoseconds.
    /* private but tests */ internal var _now: NIODeadline = .uptimeNanoseconds(0)

    private var scheduledTaskCounter: UInt64 = 0
    private var scheduledTasks = PriorityQueue<EmbeddedScheduledTask>()

    /// Keep track of where promises are allocated to ensure we can identify their source if they leak.
    private var _promiseCreationStore: [_NIOEventLoopFutureIdentifier: (file: StaticString, line: UInt)] = [:]

    // The number of the next task to be created. We track the order so that when we execute tasks
    // scheduled at the same time, we may do so in the order in which they were submitted for
    // execution.
    private var taskNumber: UInt64 = 0

    private func nextTaskNumber() -> UInt64 {
        defer {
            self.taskNumber += 1
        }
        return self.taskNumber
    }

    /// - see: `EventLoop.inEventLoop`
    public var inEventLoop: Bool {
        return true
    }

    /// Initialize a new `EmbeddedEventLoop`.
    public init() { }

    /// - see: `EventLoop.scheduleTask(deadline:_:)`
    @discardableResult
    public func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = makePromise()
        self.scheduledTaskCounter += 1
        let task = EmbeddedScheduledTask(id: self.scheduledTaskCounter, readyTime: deadline, insertOrder: self.nextTaskNumber(), task: {
            do {
                promise.succeed(try task())
            } catch let err {
                promise.fail(err)
            }
        }, promise.fail)

        let taskId = task.id
        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.scheduledTasks.removeFirst { $0.id == taskId }
        })
        scheduledTasks.push(task)
        return scheduled
    }

    /// - see: `EventLoop.scheduleTask(in:_:)`
    @discardableResult
    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return scheduleTask(deadline: self._now + `in`, task)
    }

    /// On an `EmbeddedEventLoop`, `execute` will simply use `scheduleTask` with a deadline of _now_. This means that
    /// `task` will be run the next time you call `EmbeddedEventLoop.run`.
    public func execute(_ task: @escaping () -> Void) {
        self.scheduleTask(deadline: self._now, task)
    }

    /// Run all tasks that have previously been submitted to this `EmbeddedEventLoop`, either by calling `execute` or
    /// events that have been enqueued using `scheduleTask`/`scheduleRepeatedTask`/`scheduleRepeatedAsyncTask` and whose
    /// deadlines have expired.
    ///
    /// - seealso: `EmbeddedEventLoop.advanceTime`.
    public func run() {
        // Execute all tasks that are currently enqueued to be executed *now*.
        self.advanceTime(to: self._now)
    }

    /// Runs the event loop and moves "time" forward by the given amount, running any scheduled
    /// tasks that need to be run.
    public func advanceTime(by increment: TimeAmount) {
        self.advanceTime(to: self._now + increment)
    }

    /// Runs the event loop and moves "time" forward to the given point in time, running any scheduled
    /// tasks that need to be run.
    ///
    /// - Note: If `deadline` is before the current time, the current time will not be advanced.
    public func advanceTime(to deadline: NIODeadline) {
        let newTime = max(deadline, self._now)

        while let nextTask = self.scheduledTasks.peek() {
            guard nextTask.readyTime <= newTime else {
                break
            }

            // Now we want to grab all tasks that are ready to execute at the same
            // time as the first.
            var tasks = Array<EmbeddedScheduledTask>()
            while let candidateTask = self.scheduledTasks.peek(), candidateTask.readyTime == nextTask.readyTime {
                tasks.append(candidateTask)
                self.scheduledTasks.pop()
            }

            // Set the time correctly before we call into user code, then
            // call in for all tasks.
            self._now = nextTask.readyTime

            for task in tasks {
                task.task()
            }
        }

        // Finally ensure we got the time right.
        self._now = newTime
    }

    internal func drainScheduledTasksByRunningAllCurrentlyScheduledTasks() {
        var currentlyScheduledTasks = self.scheduledTasks
        while let nextTask = currentlyScheduledTasks.pop() {
            self._now = nextTask.readyTime
            nextTask.task()
        }
        // Just fail all the remaining scheduled tasks. Despite having run all the tasks that were
        // scheduled when we entered the method this may still contain tasks as running the tasks
        // may have enqueued more tasks.
        while let task = self.scheduledTasks.pop() {
            task.fail(EventLoopError.shutdown)
        }
    }

    /// - see: `EventLoop.close`
    func close() throws {
        // Nothing to do here
    }

    /// - see: `EventLoop.shutdownGracefully`
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        run()
        queue.sync {
            callback(nil)
        }
    }

    public func _preconditionSafeToWait(file: StaticString, line: UInt) {
        // EmbeddedEventLoop always allows a wait, as waiting will essentially always block
        // wait()
        return
    }

    public func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self._promiseCreationStore[futureIdentifier] = (file: file, line: line)
    }

    public func _promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)? {
        precondition(_isDebugAssertConfiguration())
        return self._promiseCreationStore.removeValue(forKey: futureIdentifier)
    }

    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        // EmbeddedEventLoop always allows a sync shutdown.
        return
    }

    deinit {
        precondition(scheduledTasks.isEmpty, "Embedded event loop freed with unexecuted scheduled tasks!")
    }
}

@usableFromInline
class EmbeddedChannelCore: ChannelCore {
    var isOpen: Bool = true
    var isActive: Bool = false

    var eventLoop: EventLoop
    var closePromise: EventLoopPromise<Void>
    var error: Optional<Error>

    private let pipeline: ChannelPipeline

    init(pipeline: ChannelPipeline, eventLoop: EventLoop) {
        closePromise = eventLoop.makePromise()
        self.pipeline = pipeline
        self.eventLoop = eventLoop
        self.error = nil
    }

    deinit {
        assert(!self.isOpen && !self.isActive,
               "leaked an open EmbeddedChannel, maybe forgot to call channel.finish()?")
        isOpen = false
        closePromise.succeed(())
    }

    /// Contains the flushed items that went into the `Channel` (and on a regular channel would have hit the network).
    @usableFromInline
    var outboundBuffer: CircularBuffer<NIOAny> = CircularBuffer()

    /// Contains the unflushed items that went into the `Channel`
    @usableFromInline
    var pendingOutboundBuffer: MarkedCircularBuffer<(NIOAny, EventLoopPromise<Void>?)> = MarkedCircularBuffer(initialCapacity: 16)

    /// Contains the items that travelled the `ChannelPipeline` all the way and hit the tail channel handler. On a
    /// regular `Channel` these items would be lost.
    @usableFromInline
    var inboundBuffer: CircularBuffer<NIOAny> = CircularBuffer()

    @usableFromInline
    func localAddress0() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    @usableFromInline
    func remoteAddress0() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    @usableFromInline
    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard self.isOpen else {
            promise?.fail(ChannelError.alreadyClosed)
            return
        }
        isOpen = false
        isActive = false
        promise?.succeed(())

        // As we called register() in the constructor of EmbeddedChannel we also need to ensure we call unregistered here.
        self.pipeline.syncOperations.fireChannelInactive()
        self.pipeline.syncOperations.fireChannelUnregistered()

        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.removeHandlers(pipeline: self.pipeline)
            self.closePromise.succeed(())
        }
    }

    @usableFromInline
    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }

    @usableFromInline
    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        isActive = true
        promise?.succeed(())
        self.pipeline.syncOperations.fireChannelActive()
    }

    @usableFromInline
    func register0(promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
        self.pipeline.syncOperations.fireChannelRegistered()
    }

    @usableFromInline
    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        isActive = true
        register0(promise: promise)
        self.pipeline.syncOperations.fireChannelActive()
    }

    @usableFromInline
    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.pendingOutboundBuffer.append((data, promise))
    }

    @usableFromInline
    func flush0() {
        self.pendingOutboundBuffer.mark()

        while self.pendingOutboundBuffer.hasMark, let dataAndPromise = self.pendingOutboundBuffer.popFirst() {
            self.addToBuffer(buffer: &self.outboundBuffer, data: dataAndPromise.0)
            dataAndPromise.1?.succeed(())
        }
    }

    @usableFromInline
    func read0() {
        // NOOP
    }

    public final func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    @usableFromInline
    func channelRead0(_ data: NIOAny) {
        addToBuffer(buffer: &inboundBuffer, data: data)
    }

    public func errorCaught0(error: Error) {
        if self.error == nil {
            self.error = error
        }
    }

    private func addToBuffer<T>(buffer: inout CircularBuffer<T>, data: T) {
        buffer.append(data)
    }
}

/// `EmbeddedChannel` is a `Channel` implementation that does neither any
/// actual IO nor has a proper eventing mechanism. The prime use-case for
/// `EmbeddedChannel` is in unit tests when you want to feed the inbound events
/// and check the outbound events manually.
///
/// Please remember to call `finish()` when you are no longer using this
/// `EmbeddedChannel`.
///
/// To feed events through an `EmbeddedChannel`'s `ChannelPipeline` use
/// `EmbeddedChannel.writeInbound` which accepts data of any type. It will then
/// forward that data through the `ChannelPipeline` and the subsequent
/// `ChannelInboundHandler` will receive it through the usual `channelRead`
/// event. The user is responsible for making sure the first
/// `ChannelInboundHandler` expects data of that type.
///
/// `EmbeddedChannel` automatically collects arriving outbound data and makes it
/// available one-by-one through `readOutbound`.
///
/// - note: `EmbeddedChannel` is currently only compatible with
///   `EmbeddedEventLoop`s and cannot be used with `SelectableEventLoop`s from
///   for example `MultiThreadedEventLoopGroup`.
/// - warning: Unlike other `Channel`s, `EmbeddedChannel` **is not thread-safe**. This
///     is because it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into an `EmbeddedChannel` in an
///     unsynchronized fashion. `EmbeddedEventLoop`s notes also apply as
///     `EmbeddedChannel` uses an `EmbeddedEventLoop` as its `EventLoop`.
public final class EmbeddedChannel: Channel {
    /// `LeftOverState` represents any left-over inbound, outbound, and pending outbound events that hit the
    /// `EmbeddedChannel` and were not consumed when `finish` was called on the `EmbeddedChannel`.
    ///
    /// `EmbeddedChannel` is most useful in testing and usually in unit tests, you want to consume all inbound and
    /// outbound data to verify they are what you expect. Therefore, when you `finish` an `EmbeddedChannel` it will
    /// return if it's either `.clean` (no left overs) or that it has `.leftOvers`.
    public enum LeftOverState {
        /// The `EmbeddedChannel` is clean, ie. no inbound, outbound, or pending outbound data left on `finish`.
        case clean

        /// The `EmbeddedChannel` has inbound, outbound, or pending outbound data left on `finish`.
        case leftOvers(inbound: [NIOAny], outbound: [NIOAny], pendingOutbound: [NIOAny])

        /// `true` if the `EmbeddedChannel` was `clean` on `finish`, ie. there is no unconsumed inbound, outbound, or
        /// pending outbound data left on the `Channel`.
        public var isClean: Bool {
            if case .clean = self {
                return true
            } else {
                return false
            }
        }

        /// `true` if the `EmbeddedChannel` if there was unconsumed inbound, outbound, or pending outbound data left
        /// on the `Channel` when it was `finish`ed.
        public var hasLeftOvers: Bool {
            return !self.isClean
        }
    }

    /// `BufferState` represents the state of either the inbound, or the outbound `EmbeddedChannel` buffer. These
    /// buffers contain data that travelled the `ChannelPipeline` all the way.
    ///
    /// If the last `ChannelHandler` explicitly (by calling `fireChannelRead`) or implicitly (by not implementing
    /// `channelRead`) sends inbound data into the end of the `EmbeddedChannel`, it will be held in the
    /// `EmbeddedChannel`'s inbound buffer. Similarly for `write` on the outbound side. The state of the respective
    /// buffer will be returned from `writeInbound`/`writeOutbound` as a `BufferState`.
    public enum BufferState {
        /// The buffer is empty.
        case empty

        /// The buffer is non-empty.
        case full([NIOAny])

        /// Returns `true` is the buffer was empty.
        public var isEmpty: Bool {
            if case .empty = self {
                return true
            } else {
                return false
            }
        }

        /// Returns `true` if the buffer was non-empty.
        public var isFull: Bool {
            return !self.isEmpty
        }
    }

    /// `WrongTypeError` is throws if you use `readInbound` or `readOutbound` and request a certain type but the first
    /// item in the respective buffer is of a different type.
    public struct WrongTypeError: Error, Equatable {
        /// The type you expected.
        public let expected: Any.Type

        /// The type of the actual first element.
        public let actual: Any.Type

        public init(expected: Any.Type, actual: Any.Type) {
            self.expected = expected
            self.actual = actual
        }

        public static func == (lhs: WrongTypeError, rhs: WrongTypeError) -> Bool {
            return lhs.expected == rhs.expected && lhs.actual == rhs.actual
        }
    }

    /// Returns `true` if the `EmbeddedChannel` is 'active'.
    ///
    /// An active `EmbeddedChannel` can be closed by calling `close` or `finish` on the `EmbeddedChannel`.
    ///
    /// - note: An `EmbeddedChannel` starts _inactive_ and can be activated, for example by calling `connect`.
    public var isActive: Bool { return channelcore.isActive }

    /// - see: `Channel.closeFuture`
    public var closeFuture: EventLoopFuture<Void> { return channelcore.closePromise.futureResult }

    @usableFromInline
    /*private but usableFromInline */ lazy var channelcore: EmbeddedChannelCore = EmbeddedChannelCore(pipeline: self._pipeline, eventLoop: self.eventLoop)

    /// - see: `Channel._channelCore`
    public var _channelCore: ChannelCore {
        return channelcore
    }

    /// - see: `Channel.pipeline`
    public var pipeline: ChannelPipeline {
        return _pipeline
    }

    /// - see: `Channel.isWritable`
    public var isWritable: Bool = true

    /// Synchronously closes the `EmbeddedChannel`.
    ///
    /// Errors in the `EmbeddedChannel` can be consumed using `throwIfErrorCaught`.
    ///
    /// - parameters:
    ///     - acceptAlreadyClosed: Whether `finish` should throw if the `EmbeddedChannel` has been previously `close`d.
    /// - returns: The `LeftOverState` of the `EmbeddedChannel`. If all the inbound and outbound events have been
    ///            consumed (using `readInbound` / `readOutbound`) and there are no pending outbound events (unflushed
    ///            writes) this will be `.clean`. If there are any unconsumed inbound, outbound, or pending outbound
    ///            events, the `EmbeddedChannel` will returns those as `.leftOvers(inbound:outbound:pendingOutbound:)`.
    public func finish(acceptAlreadyClosed: Bool) throws -> LeftOverState {
        do {
            try close().wait()
        } catch let error as ChannelError {
            guard error == .alreadyClosed && acceptAlreadyClosed else {
                throw error
            }
        }
        self.embeddedEventLoop.drainScheduledTasksByRunningAllCurrentlyScheduledTasks()
        self.embeddedEventLoop.run()
        try throwIfErrorCaught()
        let c = self.channelcore
        if c.outboundBuffer.isEmpty && c.inboundBuffer.isEmpty && c.pendingOutboundBuffer.isEmpty {
            return .clean
        } else {
            return .leftOvers(inbound: Array(c.inboundBuffer),
                              outbound: Array(c.outboundBuffer),
                              pendingOutbound: c.pendingOutboundBuffer.map { $0.0 })
        }
    }

    /// Synchronously closes the `EmbeddedChannel`.
    ///
    /// This method will throw if the `Channel` hit any unconsumed errors or if the `close` fails. Errors in the
    /// `EmbeddedChannel` can be consumed using `throwIfErrorCaught`.
    ///
    /// - returns: The `LeftOverState` of the `EmbeddedChannel`. If all the inbound and outbound events have been
    ///            consumed (using `readInbound` / `readOutbound`) and there are no pending outbound events (unflushed
    ///            writes) this will be `.clean`. If there are any unconsumed inbound, outbound, or pending outbound
    ///            events, the `EmbeddedChannel` will returns those as `.leftOvers(inbound:outbound:pendingOutbound:)`.
    public func finish() throws -> LeftOverState {
        return try self.finish(acceptAlreadyClosed: false)
    }

    private var _pipeline: ChannelPipeline!

    /// - see: `Channel.allocator`
    public var allocator: ByteBufferAllocator = ByteBufferAllocator()

    /// - see: `Channel.eventLoop`
    public var eventLoop: EventLoop {
        return self.embeddedEventLoop
    }

    /// Returns the `EmbeddedEventLoop` that this `EmbeddedChannel` uses. This will return the same instance as
    /// `EmbeddedChannel.eventLoop` but as the concrete `EmbeddedEventLoop` rather than as `EventLoop` existential.
    public var embeddedEventLoop: EmbeddedEventLoop = EmbeddedEventLoop()

    /// - see: `Channel.localAddress`
    public var localAddress: SocketAddress? = nil

    /// - see: `Channel.remoteAddress`
    public var remoteAddress: SocketAddress? = nil

    /// `nil` because `EmbeddedChannel`s don't have parents.
    public let parent: Channel? = nil

    /// If available, this method reads one element of type `T` out of the `EmbeddedChannel`'s outbound buffer. If the
    /// first element was of a different type than requested, `EmbeddedChannel.WrongTypeError` will be thrown, if there
    /// are no elements in the outbound buffer, `nil` will be returned.
    ///
    /// Data hits the `EmbeddedChannel`'s outbound buffer when data was written using `write`, then `flush`ed, and
    /// then travelled the `ChannelPipeline` all the way too the front. For data to hit the outbound buffer, the very
    /// first `ChannelHandler` must have written and flushed it either explicitly (by calling
    /// `ChannelHandlerContext.write` and `flush`) or implicitly by not implementing `write`/`flush`.
    ///
    /// - note: Outbound events travel the `ChannelPipeline` _back to front_.
    /// - note: `EmbeddedChannel.writeOutbound` will `write` data through the `ChannelPipeline`, starting with last
    ///         `ChannelHandler`.
    @inlinable
    public func readOutbound<T>(as type: T.Type = T.self) throws -> T? {
        return try _readFromBuffer(buffer: &channelcore.outboundBuffer)
    }

    /// If available, this method reads one element of type `T` out of the `EmbeddedChannel`'s inbound buffer. If the
    /// first element was of a different type than requested, `EmbeddedChannel.WrongTypeError` will be thrown, if there
    /// are no elements in the outbound buffer, `nil` will be returned.
    ///
    /// Data hits the `EmbeddedChannel`'s inbound buffer when data was send through the pipeline using `fireChannelRead`
    /// and then travelled the `ChannelPipeline` all the way too the back. For data to hit the inbound buffer, the
    /// last `ChannelHandler` must have send the event either explicitly (by calling
    /// `ChannelHandlerContext.fireChannelRead`) or implicitly by not implementing `channelRead`.
    ///
    /// - note: `EmbeddedChannel.writeInbound` will fire data through the `ChannelPipeline` using `fireChannelRead`.
    @inlinable
    public func readInbound<T>(as type: T.Type = T.self) throws -> T? {
        return try _readFromBuffer(buffer: &channelcore.inboundBuffer)
    }

    /// Sends an inbound `channelRead` event followed by a `channelReadComplete` event through the `ChannelPipeline`.
    ///
    /// The immediate effect being that the first `ChannelInboundHandler` will get its `channelRead` method called
    /// with the data you provide.
    ///
    /// - parameters:
    ///    - data: The data to fire through the pipeline.
    /// - returns: The state of the inbound buffer which contains all the events that travelled the `ChannelPipeline`
    //             all the way.
    @inlinable
    @discardableResult public func writeInbound<T>(_ data: T) throws -> BufferState {
        pipeline.fireChannelRead(NIOAny(data))
        pipeline.fireChannelReadComplete()
        try throwIfErrorCaught()
        return self.channelcore.inboundBuffer.isEmpty ? .empty : .full(Array(self.channelcore.inboundBuffer))
    }

    /// Sends an outbound `writeAndFlush` event through the `ChannelPipeline`.
    ///
    /// The immediate effect being that the first `ChannelOutboundHandler` will get its `write` method called
    /// with the data you provide. Note that the first `ChannelOutboundHandler` in the pipeline is the _last_ handler
    /// because outbound events travel the pipeline from back to front.
    ///
    /// - parameters:
    ///    - data: The data to fire through the pipeline.
    /// - returns: The state of the outbound buffer which contains all the events that travelled the `ChannelPipeline`
    //             all the way.
    @inlinable
    @discardableResult public func writeOutbound<T>(_ data: T) throws -> BufferState {
        try writeAndFlush(NIOAny(data)).wait()
        return self.channelcore.outboundBuffer.isEmpty ? .empty : .full(Array(self.channelcore.outboundBuffer))
    }

    /// This method will throw the error that is stored in the `EmbeddedChannel` if any.
    ///
    /// The `EmbeddedChannel` will store an error some error travels the `ChannelPipeline` all the way past its end.
    public func throwIfErrorCaught() throws {
        if let error = channelcore.error {
            channelcore.error = nil
            throw error
        }
    }

    @inlinable
    func _readFromBuffer<T>(buffer: inout CircularBuffer<NIOAny>) throws -> T? {
        if buffer.isEmpty {
            return nil
        }
        let elem = buffer.removeFirst()
        guard let t = self._channelCore.tryUnwrapData(elem, as: T.self) else {
            throw WrongTypeError(expected: T.self, actual: type(of: self._channelCore.tryUnwrapData(elem, as: Any.self)!))
        }
        return t
    }

    /// Create a new instance.
    ///
    /// During creation it will automatically also register itself on the `EmbeddedEventLoop`.
    ///
    /// - parameters:
    ///     - handler: The `ChannelHandler` to add to the `ChannelPipeline` before register or `nil` if none should be added.
    ///     - loop: The `EmbeddedEventLoop` to use.
    public convenience init(handler: ChannelHandler? = nil, loop: EmbeddedEventLoop = EmbeddedEventLoop()) {
        let handlers = handler.map { [$0] } ?? []
        self.init(handlers: handlers, loop: loop)
    }
    
    /// Create a new instance.
    ///
    /// During creation it will automatically also register itself on the `EmbeddedEventLoop`.
    ///
    /// - parameters:
    ///     - handlers: The `ChannelHandler`s to add to the `ChannelPipeline` before register.
    ///     - loop: The `EmbeddedEventLoop` to use.
    public init(handlers: [ChannelHandler], loop: EmbeddedEventLoop = EmbeddedEventLoop()) {
        self.embeddedEventLoop = loop
        self._pipeline = ChannelPipeline(channel: self)

        try! self._pipeline.syncOperations.addHandlers(handlers)

        // This will never throw...
        try! register().wait()
    }

    /// - see: `Channel.setOption`
    @inlinable
    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        self.setOptionSync(option, value: value)
        return self.eventLoop.makeSucceededVoidFuture()
    }

    @inlinable
    internal func setOptionSync<Option: ChannelOption>(_ option: Option, value: Option.Value) {
        // No options supported
        fatalError("no options supported")
    }

    /// - see: `Channel.getOption`
    @inlinable
    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value>  {
        return self.eventLoop.makeSucceededFuture(self.getOptionSync(option))
    }

    @inlinable
    internal func getOptionSync<Option: ChannelOption>(_ option: Option) -> Option.Value {
        if option is ChannelOptions.Types.AutoReadOption {
            return true as! Option.Value
        }
        fatalError("option \(option) not supported")
    }

    /// Fires the (outbound) `bind` event through the `ChannelPipeline`. If the event hits the `EmbeddedChannel` which
    /// happens when it travels the `ChannelPipeline` all the way to the front, this will also set the
    /// `EmbeddedChannel`'s `localAddress`.
    ///
    /// - parameters:
    ///     - address: The address to fake-bind to.
    ///     - promise: The `EventLoopPromise` which will be fulfilled when the fake-bind operation has been done.
    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.localAddress = address
        }
        pipeline.bind(to: address, promise: promise)
    }

    /// Fires the (outbound) `connect` event through the `ChannelPipeline`. If the event hits the `EmbeddedChannel`
    /// which happens when it travels the `ChannelPipeline` all the way to the front, this will also set the
    /// `EmbeddedChannel`'s `remoteAddress`.
    ///
    /// - parameters:
    ///     - address: The address to fake-bind to.
    ///     - promise: The `EventLoopPromise` which will be fulfilled when the fake-bind operation has been done.
    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.remoteAddress = address
        }
        pipeline.connect(to: address, promise: promise)
    }
}

extension EmbeddedChannel {
    public struct SynchronousOptions: NIOSynchronousChannelOptions {
        @usableFromInline
        internal let channel: EmbeddedChannel

        fileprivate init(channel: EmbeddedChannel) {
            self.channel = channel
        }

        @inlinable
        public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
            self.channel.setOptionSync(option, value: value)
        }

        @inlinable
        public func getOption<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
            return self.channel.getOptionSync(option)
        }
    }

    public final var syncOptions: NIOSynchronousChannelOptions? {
        return SynchronousOptions(channel: self)
    }
}
