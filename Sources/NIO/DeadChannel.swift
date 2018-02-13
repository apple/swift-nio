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

/// A `DeadChannelCore` is a `ChannelCore` for a `DeadChannel`. A `DeadChannel` is used as a replacement `Channel` when
/// the original `Channel` is closed. Given that the original `Channel` is closed the `DeadChannelCore` should fail
/// all operations.
private final class DeadChannelCore: ChannelCore {
    func register0(promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.ioOnClosedChannel)
    }

    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.ioOnClosedChannel)
    }

    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.ioOnClosedChannel)
    }

    func write0(data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.ioOnClosedChannel)
    }

    func flush0(promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.ioOnClosedChannel)
    }

    func read0(promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.ioOnClosedChannel)
    }

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.alreadyClosed)
    }

    func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.ioOnClosedChannel)
    }

    func channelRead0(data: NIOAny) {
        // a `DeadChannel` should never be in any running `ChannelPipeline` and therefore the `TailChannelHandler`
        // should never invoke this.
        fatalError("\(#function) called on DeadChannelCore")
    }

    func errorCaught0(error: Error) {
        // a `DeadChannel` should never be in any running `ChannelPipeline` and therefore the `TailChannelHandler`
        // should never invoke this.
        fatalError("\(#function) called on DeadChannelCore")
    }
}

/// This represents a `Channel` which is already closed and therefore all the operations do fail.
/// A `ChannelPipeline` that is associated with a closed `Channel` must be careful to no longer use that original
/// channel as it only holds an unowned reference to the original `Channel`. `DeadChannel` serves as a replacement
/// that can be used when the original `Channel` might no longer be valid.
internal final class DeadChannel: Channel {
    let pipeline: ChannelPipeline

    var eventLoop: EventLoop {
        return self.pipeline.eventLoop
    }

    internal init(pipeline: ChannelPipeline) {
        self.pipeline = pipeline
    }

    var allocator: ByteBufferAllocator {
        return ByteBufferAllocator()
    }

    var closeFuture: EventLoopFuture<Void> {
        return self.pipeline.eventLoop.newSucceededFuture(result: ())
    }

    let localAddress: SocketAddress? = nil

    let remoteAddress: SocketAddress? = nil

    let parent: Channel? = nil

    func setOption<T>(option: T, value: T.OptionType) -> EventLoopFuture<Void> where T : ChannelOption {
        return EventLoopFuture(eventLoop: self.pipeline.eventLoop, error: ChannelError.ioOnClosedChannel, file: #file, line: #line)
    }

    func getOption<T>(option: T) throws -> T.OptionType where T : ChannelOption {
        throw ChannelError.ioOnClosedChannel
    }

    let isWritable = false
    let isActive = false
    let _unsafe: ChannelCore = DeadChannelCore()
}
