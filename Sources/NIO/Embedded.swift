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

import Dispatch

private final class EmbeddedScheduledTask {
    let task: () -> Void
    let readyTime: NIODeadline

    init(readyTime: NIODeadline, task: @escaping () -> Void) {
        self.readyTime = readyTime
        self.task = task
    }
}

extension EmbeddedScheduledTask: Comparable {
    static func < (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }
    static func == (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs === rhs
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
/// - warning: Unlike `SelectableEventLoop`, `EmbeddedEventLoop` **is not thread-safe**. This
///     is because it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into the `EmbeddedEventLoop` in an
///     unsynchronized fashion.
public class EmbeddedEventLoop: EventLoop {
    /// The current "time" for this event loop. This is an amount in nanoseconds.
    private var now: NIODeadline = .uptimeNanoseconds(0)

    private var scheduledTasks = PriorityQueue<EmbeddedScheduledTask>(ascending: true)

    public var inEventLoop: Bool {
        return true
    }

    public init() { }

    @discardableResult
    public func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = makePromise()
        let task = EmbeddedScheduledTask(readyTime: deadline) {
            do {
                promise.succeed(try task())
            } catch let err {
                promise.fail(err)
            }
        }

        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.scheduledTasks.remove(task)
        })
        scheduledTasks.push(task)
        return scheduled
    }

    @discardableResult
    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return scheduleTask(deadline: self.now + `in`, task)
    }

    // We're not really running a loop here. Tasks aren't run until run() is called,
    // at which point we run everything that's been submitted. Anything newly submitted
    // either gets on that train if it's still moving or waits until the next call to run().
    public func execute(_ task: @escaping () -> Void) {
        self.scheduleTask(deadline: self.now, task)
    }

    public func run() {
        // Execute all tasks that are currently enqueued to be executed *now*.
        self.advanceTime(by: .nanoseconds(0))
    }

    /// Runs the event loop and moves "time" forward by the given amount, running any scheduled
    /// tasks that need to be run.
    public func advanceTime(by: TimeAmount) {
        let newTime = self.now + by

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
            self.now = nextTask.readyTime

            for task in tasks {
                task.task()
            }
        }

        // Finally ensure we got the time right.
        self.now = newTime
    }

    func close() throws {
        // Nothing to do here
    }

    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        run()
        queue.sync {
            callback(nil)
        }
    }

    deinit {
        precondition(scheduledTasks.isEmpty, "Embedded event loop freed with unexecuted scheduled tasks!")
    }
}

class EmbeddedChannelCore: ChannelCore {
    var isOpen: Bool = true
    var isActive: Bool = false

    var eventLoop: EventLoop
    var closePromise: EventLoopPromise<Void>
    var error: Error?

    private let pipeline: ChannelPipeline

    init(pipeline: ChannelPipeline, eventLoop: EventLoop) {
        closePromise = eventLoop.makePromise()
        self.pipeline = pipeline
        self.eventLoop = eventLoop
    }

    deinit {
        assert(self.pipeline.destroyed, "leaked an open EmbeddedChannel, maybe forgot to call channel.finish()?")
        isOpen = false
        closePromise.succeed(())
    }

    /// Contains the flushed items that went into the `Channel` (and on a regular channel would have hit the network).
    var outboundBuffer: [NIOAny] = []

    /// Contains the unflushed items that went into the `Channel`
    var pendingOutboundBuffer: [(NIOAny, EventLoopPromise<Void>?)] = []

    /// Contains the items that travelled the `ChannelPipeline` all the way and hit the tail channel handler. On a
    /// regular `Channel` these items would be lost.
    var inboundBuffer: [NIOAny] = []

    func localAddress0() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    func remoteAddress0() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard self.isOpen else {
            promise?.fail(ChannelError.alreadyClosed)
            return
        }
        isOpen = false
        isActive = false
        promise?.succeed(())

        // As we called register() in the constructor of EmbeddedChannel we also need to ensure we call unregistered here.
        pipeline.fireChannelInactive0()
        pipeline.fireChannelUnregistered0()

        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()
            self.closePromise.succeed(())
        }
    }

    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }

    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        isActive = true
        promise?.succeed(())
        pipeline.fireChannelActive0()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
        pipeline.fireChannelRegistered0()
    }

    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        isActive = true
        register0(promise: promise)
        pipeline.fireChannelActive0()
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.pendingOutboundBuffer.append((data, promise))
    }

    func flush0() {
        let pendings = self.pendingOutboundBuffer
        self.pendingOutboundBuffer.removeAll()
        for dataAndPromise in pendings {
            self.addToBuffer(buffer: &self.outboundBuffer, data: dataAndPromise.0)
            dataAndPromise.1?.succeed(())
        }
    }

    func read0() {
        // NOOP
    }

    public final func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    func channelRead0(_ data: NIOAny) {
        addToBuffer(buffer: &inboundBuffer, data: data)
    }

    public func errorCaught0(error: Error) {
        if self.error == nil {
            self.error = error
        }
    }

    private func addToBuffer<T>(buffer: inout [T], data: T) {
        buffer.append(data)
    }
}

/// `EmbeddedChannel` is a `Channel` implementation that does neither any
/// actual IO nor has a proper eventing mechanism. The prime use-case for
/// `EmbeddedChannel` is in unit tests when you want to feed the inbound events
/// and check the outbound events manually.
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
/// - note: Due to [#243](https://github.com/apple/swift-nio/issues/243)
///   `EmbeddedChannel` expects outbound data to be of `IOData` type. This is an
///   incorrect and unfortunate assumption that will be fixed with the next
///   major NIO release when we can change the public API again. If you do need
///   to collect outbound data that is not `IOData` you can create a custom
///   `ChannelOutboundHandler`, insert it at the very beginning of the
///   `ChannelPipeline` and collect the outbound data there. Just don't forward
///   it using `context.write`.
/// - note: `EmbeddedChannel` is currently only compatible with
///   `EmbeddedEventLoop`s and cannot be used with `SelectableEventLoop`s from
///   for example `MultiThreadedEventLoopGroup`.
/// - warning: Unlike other `Channel`s, `EmbeddedChannel` **is not thread-safe**. This
///     is because it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into an `EmbeddedChannel` in an
///     unsynchronized fashion. `EmbeddedEventLoop`s notes also apply as
///     `EmbeddedChannel` uses an `EmbeddedEventLoop` as its `EventLoop`.
public class EmbeddedChannel: Channel {
    public enum LeftOverState {
        case clean
        case leftOvers(inbound: [NIOAny], outbound: [NIOAny], pendingOutbound: [NIOAny])

        public var isClean: Bool {
            if case .clean = self {
                return true
            } else {
                return false
            }
        }

        public var hasLeftOvers: Bool {
            return !self.isClean
        }
    }

    public enum BufferState {
        case empty
        case full([NIOAny])

        public var isEmpty: Bool {
            if case .empty = self {
                return true
            } else {
                return false
            }
        }

        public var isFull: Bool {
            return !self.isEmpty
        }
    }

    public var isActive: Bool { return channelcore.isActive }
    public var closeFuture: EventLoopFuture<Void> { return channelcore.closePromise.futureResult }

    private lazy var channelcore: EmbeddedChannelCore = EmbeddedChannelCore(pipeline: self._pipeline, eventLoop: self.eventLoop)

    public var _channelCore: ChannelCore {
        return channelcore
    }

    public var pipeline: ChannelPipeline {
        return _pipeline
    }

    public var isWritable: Bool {
        return true
    }

    /// Synchronously closes the `EmbeddedChannel`.
    ///
    /// This method will throw if the `Channel` hit any unconsumed errors or if the `close` fails. Errors in the
    /// `EmbeddedChannel` can be consumed using `throwIfErrorCaught`.
    ///
    /// - returns: The `LeftOverState` of the `EmbeddedChannel`. If all the inbound and outbound events have been
    //             consumed (using `readInbound` / `readOutbound`) and there are no pending outbound events (unflushed
    //             writes) this will be `.clean`. If there are any unconsumed inbound, outbound, or pending outbound
    //             events, the `EmbeddedChannel` will returns those as `.leftOvers(inbound:outbound:pendingOutbound:)`.
    public func finish() throws -> LeftOverState {
        try close().wait()
        self.embeddedEventLoop.run()
        try throwIfErrorCaught()
        let c = self.channelcore
        if c.outboundBuffer.isEmpty && c.inboundBuffer.isEmpty && c.pendingOutboundBuffer.isEmpty {
            return .clean
        } else {
            return .leftOvers(inbound: c.inboundBuffer,
                              outbound: c.outboundBuffer,
                              pendingOutbound: c.pendingOutboundBuffer.map { $0.0 })
        }
    }

    private var _pipeline: ChannelPipeline!
    public var allocator: ByteBufferAllocator = ByteBufferAllocator()
    public var eventLoop: EventLoop {
        return self.embeddedEventLoop
    }

    public var embeddedEventLoop: EmbeddedEventLoop = EmbeddedEventLoop()

    public var localAddress: SocketAddress? = nil
    public var remoteAddress: SocketAddress? = nil

    // Embedded channels never have parents.
    public let parent: Channel? = nil

    public struct WrongTypeError: Error, Equatable {
        public let expected: Any.Type
        public let actual: Any.Type

        public static func == (lhs: WrongTypeError, rhs: WrongTypeError) -> Bool {
            return lhs.expected == rhs.expected && lhs.actual == rhs.actual
        }
    }

    public func readOutbound<T>(as type: T.Type = T.self) throws -> T? {
        return try readFromBuffer(buffer: &channelcore.outboundBuffer)
    }

    public func readInbound<T>(as type: T.Type = T.self) throws -> T? {
        return try readFromBuffer(buffer: &channelcore.inboundBuffer)
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
    @discardableResult public func writeInbound<T>(_ data: T) throws -> BufferState {
        pipeline.fireChannelRead(NIOAny(data))
        pipeline.fireChannelReadComplete()
        try throwIfErrorCaught()
        return self.channelcore.inboundBuffer.isEmpty ? .empty : .full(self.channelcore.inboundBuffer)
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
    @discardableResult public func writeOutbound<T>(_ data: T) throws -> BufferState {
        try writeAndFlush(NIOAny(data)).wait()
        return self.channelcore.outboundBuffer.isEmpty ? .empty : .full(self.channelcore.outboundBuffer)
    }

    public func throwIfErrorCaught() throws {
        if let error = channelcore.error {
            channelcore.error = nil
            throw error
        }
    }

    private func readFromBuffer<T>(buffer: inout [NIOAny]) throws -> T? {
        if buffer.isEmpty {
            return nil
        }
        let elem = buffer.removeFirst()
        guard let t = elem.tryAs(type: T.self) else {
            throw WrongTypeError(expected: T.self, actual: type(of: elem.forceAs(type: Any.self)))
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
    public init(handler: ChannelHandler? = nil, loop: EmbeddedEventLoop = EmbeddedEventLoop()) {
        self.embeddedEventLoop = loop
        self._pipeline = ChannelPipeline(channel: self)

        if let handler = handler {
            // This will be propagated via fireErrorCaught
            _ = try? _pipeline.addHandler(handler).wait()
        }

        // This will never throw...
        try! register().wait()
    }

    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        // No options supported
        fatalError("no options supported")
    }

    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value>  {
        if option is AutoReadOption {
            return self.eventLoop.makeSucceededFuture(true as! Option.Value)
        }
        fatalError("option \(option) not supported")
    }

    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.localAddress = address
        }
        pipeline.bind(to: address, promise: promise)
    }

    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.remoteAddress = address
        }
        pipeline.connect(to: address, promise: promise)
    }
}
