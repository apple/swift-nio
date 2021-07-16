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
    func localAddress0() throws -> SocketAddress {
        throw ChannelError.ioOnClosedChannel
    }

    func remoteAddress0() throws -> SocketAddress {
        throw ChannelError.ioOnClosedChannel
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }

    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }

    func bind0(to _: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }

    func connect0(to _: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }

    func write0(_: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }

    func flush0() {}

    func read0() {}

    func close0(error _: Error, mode _: CloseMode, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.alreadyClosed)
    }

    func triggerUserOutboundEvent0(_: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }

    func channelRead0(_: NIOAny) {
        // a `DeadChannel` should never be in any running `ChannelPipeline` and therefore the `TailChannelHandler`
        // should never invoke this.
        fatalError("\(#function) called on DeadChannelCore")
    }

    func errorCaught0(error _: Error) {
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
    let eventLoop: EventLoop
    let pipeline: ChannelPipeline

    public var closeFuture: EventLoopFuture<Void> {
        self.eventLoop.makeSucceededFuture(())
    }

    internal init(pipeline: ChannelPipeline) {
        self.pipeline = pipeline
        self.eventLoop = pipeline.eventLoop
    }

    // This is `Channel` API so must be thread-safe.
    var allocator: ByteBufferAllocator {
        ByteBufferAllocator()
    }

    var localAddress: SocketAddress? {
        nil
    }

    var remoteAddress: SocketAddress? {
        nil
    }

    let parent: Channel? = nil

    func setOption<Option: ChannelOption>(_: Option, value _: Option.Value) -> EventLoopFuture<Void> {
        EventLoopFuture(eventLoop: self.pipeline.eventLoop, error: ChannelError.ioOnClosedChannel, file: #file, line: #line)
    }

    func getOption<Option: ChannelOption>(_: Option) -> EventLoopFuture<Option.Value> {
        self.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
    }

    let isWritable = false
    let isActive = false
    let _channelCore: ChannelCore = DeadChannelCore()
}
