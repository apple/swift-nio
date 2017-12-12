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

class EmbeddedEventLoop : EventLoop {

    let queue = DispatchQueue(label: "embeddedEventLoopQueue", qos: .utility)
    var inEventLoop: Bool = true
    var isRunning: Bool = false

    // Would be better to have this as a Queue
    var tasks: [() -> ()] = Array()
    
    public func newPromise<T>() -> EventLoopPromise<T> {
        return EventLoopPromise<T>(eventLoop: self, checkForPossibleDeadlock: false)
    }
    
    public func newFailedFuture<T>(error: Error) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, checkForPossibleDeadlock: false, error: error)
    }
    
    public func newSucceedFuture<T>(result: T) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, checkForPossibleDeadlock: false, result: result)
    }
    
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws-> (T)) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = newPromise()
        promise.fail(error: EventLoopError.unsupportedOperation)
        return Scheduled(promise: promise, cancellationTask: {
            // Nothing to do as we fail the promise before
        })
    }
    
    // We're not really running a loop here. Tasks aren't run until run() is called,
    // at which point we run everything that's been submitted. Anything newly submitted
    // either gets on that train if it's still moving or
    func execute(task: @escaping () -> ()) {
        queue.sync {
            if isRunning && tasks.isEmpty {
                task()
            } else {
                tasks.append(task)
            }
        }
    }

    func run() throws {
        queue.sync {
            isRunning = true
            while !tasks.isEmpty {
                tasks[0]()
                tasks = Array(tasks.dropFirst(1)) // TODO: Seriously, get a queue
            }
        }
    }

    func close() throws {
        // Nothing to do here
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        queue.async {
            callback(nil)
        }
    }
}

class EmbeddedChannelCore : ChannelCore {
    var closed: Bool = false
    var isActive: Bool = false

    
    var eventLoop: EventLoop = EmbeddedEventLoop()
    var closePromise: EventLoopPromise<Void>
    var error: Error?
    
    private unowned let pipeline: ChannelPipeline

    init(pipeline: ChannelPipeline) {
        closePromise = eventLoop.newPromise()
        self.pipeline = pipeline
    }
    
    deinit {
        closed = true
        closePromise.succeed(result: ())
    }

    var outboundBuffer: [IOData] = []
    var inboundBuffer: [NIOAny] = []
    
    func close0(error: Error, promise: EventLoopPromise<Void>?) {
        if closed {
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }
        closed = true
        promise?.succeed(result: ())

        // As we called register() in the constructor of EmbeddedChannel we also need to ensure we call unregistered here.
        isActive = false
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
        promise?.succeed(result: ())
        pipeline.fireChannelRegistered0()
        isActive = true
        pipeline.fireChannelActive0()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }

    func write0(data: IOData, promise: EventLoopPromise<Void>?) {
        addToBuffer(buffer: &outboundBuffer, data: data)
        promise?.succeed(result: ())
    }

    func flush0(promise: EventLoopPromise<Void>?) {
        if closed {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        promise?.succeed(result: ())
    }

    func read0(promise: EventLoopPromise<Void>?) {
        if closed {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        promise?.succeed(result: ())
    }
    
    public final func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }
    
    func channelRead0(data: NIOAny) {
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

public class EmbeddedChannel : Channel {
    public var isActive: Bool { return channelcore.isActive }
    public var closeFuture: EventLoopFuture<Void> { return channelcore.closePromise.futureResult }

    private lazy var channelcore: EmbeddedChannelCore = EmbeddedChannelCore(pipeline: self._pipeline)

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
        try throwIfErrorCaught()
        return !channelcore.outboundBuffer.isEmpty || !channelcore.inboundBuffer.isEmpty
    }
    
    private var _pipeline: ChannelPipeline!
    public let allocator: ByteBufferAllocator = ByteBufferAllocator()
    public var eventLoop: EventLoop = EmbeddedEventLoop()

    public var localAddress: SocketAddress? = nil
    public var remoteAddress: SocketAddress? = nil

    // Embedded channels never have parents.
    public let parent: Channel? = nil
    
    public func readOutbound() -> IOData? {
        return readFromBuffer(buffer: &channelcore.outboundBuffer)
    }
    
    public func readInbound<T>() -> T? {
        return readFromBuffer(buffer: &channelcore.inboundBuffer)
    }
    
    @discardableResult public func writeInbound<T>(data: T) throws -> Bool {
        pipeline.fireChannelRead(data: NIOAny(data))
        pipeline.fireChannelReadComplete()
        try throwIfErrorCaught()
        return !channelcore.inboundBuffer.isEmpty
    }
    
    @discardableResult public func writeOutbound<T>(data: T) throws -> Bool {
        try writeAndFlush(data: NIOAny(data)).wait()
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
    
    init() {
        _pipeline = ChannelPipeline(channel: self)
        
        // we should just register it directly and this will never throw.
        _ = try? register().wait()
    }
    
    init(handler: ChannelHandler) throws {
        _pipeline = ChannelPipeline(channel: self)
        try _pipeline.add(handler: handler).wait()
        
        // we should just register it directly and this will never throw.
        _ = try? register().wait()
    }

    public func setOption<T>(option: T, value: T.OptionType) throws where T : ChannelOption {
        // No options supported
    }

    public func getOption<T>(option: T) throws -> T.OptionType where T : ChannelOption {
        if option is AutoReadOption {
            return true as! T.OptionType
        }
        fatalError("option \(option) not supported")
    }
}
