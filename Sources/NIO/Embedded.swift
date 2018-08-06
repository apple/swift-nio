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
    let readyTime: UInt64

    init(readyTime: UInt64, task: @escaping () -> Void) {
        self.readyTime = readyTime
        self.task = task
    }
}

extension EmbeddedScheduledTask: Comparable {
    public static func < (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }
    public static func == (lhs: EmbeddedScheduledTask, rhs: EmbeddedScheduledTask) -> Bool {
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
    private var now: UInt64 = 0

    private var scheduledTasks = PriorityQueue<EmbeddedScheduledTask>(ascending: true)

    public var inEventLoop: Bool {
        return true
    }

    public init() { }

    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = newPromise()
        let readyTime = now + UInt64(`in`.nanoseconds)
        let task = EmbeddedScheduledTask(readyTime: readyTime) {
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        }

        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.scheduledTasks.remove(task)
        })
        scheduledTasks.push(task)
        return scheduled
    }

    // We're not really running a loop here. Tasks aren't run until run() is called,
    // at which point we run everything that's been submitted. Anything newly submitted
    // either gets on that train if it's still moving or waits until the next call to run().
    public func execute(_ task: @escaping () -> Void) {
        _ = self.scheduleTask(in: .nanoseconds(0), task)
    }

    public func run() {
        // Execute all tasks that are currently enqueued to be executed *now*.
        self.advanceTime(by: .nanoseconds(0))
    }

    /// Runs the event loop and moves "time" forward by the given amount, running any scheduled
    /// tasks that need to be run.
    public func advanceTime(by: TimeAmount) {
        let newTime = self.now + UInt64(by.nanoseconds)

        while let nextTask = self.scheduledTasks.peek() {
            guard nextTask.readyTime <= newTime else {
                break
            }

            // Now we want to grab all tasks that are ready to execute at the same
            // time as the first.
            var tasks = Array<EmbeddedScheduledTask>()
            while let candidateTask = self.scheduledTasks.peek(), candidateTask.readyTime == nextTask.readyTime {
                tasks.append(candidateTask)
                _ = self.scheduledTasks.pop()
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
        closePromise = eventLoop.newPromise()
        self.pipeline = pipeline
        self.eventLoop = eventLoop
    }

    deinit {
        assert(self.pipeline.destroyed, "leaked an open EmbeddedChannel, maybe forgot to call channel.finish()?")
        isOpen = false
        closePromise.succeed(result: ())
    }

    /// Contains the flushed items that went into the `Channel` (and on a regular channel would have hit the network).
    var outboundBuffer: [IOData] = []

    /// Contains the unflushed items that went into the `Channel`
    var pendingOutboundBuffer: [(IOData, EventLoopPromise<Void>?)] = []

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
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }
        isOpen = false
        isActive = false
        promise?.succeed(result: ())

        // As we called register() in the constructor of EmbeddedChannel we also need to ensure we call unregistered here.
        pipeline.fireChannelInactive0()
        pipeline.fireChannelUnregistered0()

        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()
            self.closePromise.succeed(result: ())
        }
    }

    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }

    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        isActive = true
        promise?.succeed(result: ())
        pipeline.fireChannelActive0()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
        pipeline.fireChannelRegistered0()
    }

    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        isActive = true
        register0(promise: promise)
        pipeline.fireChannelActive0()
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard let data = data.tryAsIOData() else {
            promise?.fail(error: ChannelError.writeDataUnsupported)
            return
        }

        self.pendingOutboundBuffer.append((data, promise))
    }

    func flush0() {
        let pendings = self.pendingOutboundBuffer
        self.pendingOutboundBuffer.removeAll()
        for dataAndPromise in pendings {
            self.addToBuffer(buffer: &self.outboundBuffer, data: dataAndPromise.0)
            dataAndPromise.1?.succeed(result: ())
        }
    }

    func read0() {
        // NOOP
    }

    public final func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
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
///   it using `ctx.write`.
/// - note: `EmbeddedChannel` is currently only compatible with
///   `EmbeddedEventLoop`s and cannot be used with `SelectableEventLoop`s from
///   for example `MultiThreadedEventLoopGroup`.
/// - warning: Unlike other `Channel`s, `EmbeddedChannel` **is not thread-safe**. This
///     is because it is intended to be run in the thread that instantiated it. Users are
///     responsible for ensuring they never call into an `EmbeddedChannel` in an
///     unsynchronized fashion. `EmbeddedEventLoop`s notes also apply as
///     `EmbeddedChannel` uses an `EmbeddedEventLoop` as its `EventLoop`.
public class EmbeddedChannel: Channel {

    public var isActive: Bool { return channelcore.isActive }
    public var closeFuture: EventLoopFuture<Void> { return channelcore.closePromise.futureResult }

    private lazy var channelcore: EmbeddedChannelCore = EmbeddedChannelCore(pipeline: self._pipeline, eventLoop: self.eventLoop)

    public var _unsafe: ChannelCore {
        return channelcore
    }

    public var pipeline: ChannelPipeline {
        return _pipeline
    }

    public var isWritable: Bool {
        return true
    }

    public func finish() throws -> Bool {
        try close().wait()
        (self.eventLoop as! EmbeddedEventLoop).run()
        try throwIfErrorCaught()
        return !channelcore.outboundBuffer.isEmpty || !channelcore.inboundBuffer.isEmpty || !channelcore.pendingOutboundBuffer.isEmpty
    }

    private var _pipeline: ChannelPipeline!
    public var allocator: ByteBufferAllocator = ByteBufferAllocator()
    public var eventLoop: EventLoop = EmbeddedEventLoop()

    public let localAddress: SocketAddress? = nil
    public let remoteAddress: SocketAddress? = nil

    // Embedded channels never have parents.
    public let parent: Channel? = nil

    public func readOutbound() -> IOData? {
        return readFromBuffer(buffer: &channelcore.outboundBuffer)
    }

    public func readInbound<T>() -> T? {
        return readFromBuffer(buffer: &channelcore.inboundBuffer)
    }

    /// Writes `data` into the `EmbeddedChannel`'s pipeline. This will result in a `channelRead` and a
    /// `channelReadComplete` event for the first `ChannelHandler`.
    ///
    /// - parameters:
    ///    - data: The data to fire through the pipeline.
    /// - returns: If the `inboundBuffer` now contains items. The `inboundBuffer` will be empty until some item
    ///            travels the `ChannelPipeline` all the way and hits the tail channel handler.
    @discardableResult public func writeInbound<T>(_ data: T) throws -> Bool {
        pipeline.fireChannelRead(NIOAny(data))
        pipeline.fireChannelReadComplete()
        try throwIfErrorCaught()
        return !channelcore.inboundBuffer.isEmpty
    }

    @discardableResult public func writeOutbound<T>(_ data: T) throws -> Bool {
        try writeAndFlush(NIOAny(data)).wait()
        return !channelcore.outboundBuffer.isEmpty
    }

    public func throwIfErrorCaught() throws {
        if let error = channelcore.error {
            channelcore.error = nil
            throw error
        }
    }

    private func readFromBuffer(buffer: inout [IOData]) -> IOData? {
        if buffer.isEmpty {
            return nil
        }
        return buffer.removeFirst()
    }

    private func readFromBuffer<T>(buffer: inout [NIOAny]) -> T? {
        if buffer.isEmpty {
            return nil
        }
        return (buffer.removeFirst().forceAs(type: T.self))
    }

    /// Create a new instance.
    ///
    /// During creation it will automatically also register itself on the `EmbeddedEventLoop`.
    ///
    /// - parameters:
    ///     - handler: The `ChannelHandler` to add to the `ChannelPipeline` before register or `nil` if none should be added.
    ///     - loop: The `EmbeddedEventLoop` to use.
    public init(handler: ChannelHandler? = nil, loop: EmbeddedEventLoop = EmbeddedEventLoop()) {
        self.eventLoop = loop
        self._pipeline = ChannelPipeline(channel: self)

        if let handler = handler {
            // This will be propagated via fireErrorCaught
            _ = try? _pipeline.add(handler: handler).wait()
        }

        // This will never throw...
        _ = try? register().wait()
    }

    public func setOption<T>(option: T, value: T.OptionType) -> EventLoopFuture<Void> where T: ChannelOption {
        // No options supported
        fatalError("no options supported")
    }

    public func getOption<T>(option: T) -> EventLoopFuture<T.OptionType> where T: ChannelOption {
        if option is AutoReadOption {
            return self.eventLoop.newSucceededFuture(result: true as! T.OptionType)
        }
        fatalError("option \(option) not supported")
    }
}
