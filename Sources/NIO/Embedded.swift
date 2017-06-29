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
import Dispatch
import Sockets

class EmbeddedEventLoop : EventLoop {

    let queue = DispatchQueue(label: "embeddedEventLoopQueue", qos: .utility)
    var inEventLoop: Bool = true
    var isRunning: Bool = false

    // Would be better to have this as a Queue
    var tasks: [() -> ()] = Array()
    
    public func newPromise<T>() -> Promise<T> {
        return Promise<T>(eventLoop: self, checkForPossibleDeadlock: false)
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


}

class EmbeddedChannelCore : ChannelCore {
    var closed: Bool { return closePromise.futureResult.fulfilled }

    
    var eventLoop: EventLoop = EmbeddedEventLoop()
    var closePromise: Promise<Void>
    
    private unowned let pipeline: ChannelPipeline

    init(pipeline: ChannelPipeline) {
        closePromise = eventLoop.newPromise()
        self.pipeline = pipeline
    }
    
    deinit { closePromise.succeed(result: ()) }

    var outboundBuffer: [Any] = []

    func close0(error: Error, promise: Promise<Void>?) {
        promise?.succeed(result: ())
        
        // As we called register() in the constructor of EmbeddedChannel we also need to ensure we call unregistered here.
        pipeline.fireChannelUnregistered0()
        pipeline.fireChannelInactive0()
        
        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()
            self.closePromise.succeed(result: ())
        }
    }

    func bind0(to address: SocketAddress, promise: Promise<Void>?) {
        promise?.succeed(result: ())
    }

    func connect0(to address: SocketAddress, promise: Promise<Void>?) {
        promise?.succeed(result: ())
    }

    func register0(promise: Promise<Void>?) {
        promise?.succeed(result: ())
    }

    func write0(data: IOData, promise: Promise<Void>?) {
        outboundBuffer.append(data.forceAsByteBuffer())
        promise?.succeed(result: ())
    }

    func flush0(promise: Promise<Void>?) {
        promise?.succeed(result: ())
    }

    func read0(promise: Promise<Void>?) {
        promise?.succeed(result: ())
    }

    func readIfNeeded0() {
    }
    
    func channelRead0(data: IOData) {
    }
}

public class EmbeddedChannel : Channel {
    public var closeFuture: Future<Void> { return channelcore.closePromise.futureResult }

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
    
    private var _pipeline: ChannelPipeline!
    public let allocator: ByteBufferAllocator = ByteBufferAllocator()
    public var eventLoop: EventLoop = EmbeddedEventLoop()

    public var localAddress: SocketAddress? = nil
    public var remoteAddress: SocketAddress? = nil
    var outboundBuffer: [Any] { return (_unsafe as! EmbeddedChannelCore).outboundBuffer }

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
        fatalError("option \(option) not supported")
    }
}
