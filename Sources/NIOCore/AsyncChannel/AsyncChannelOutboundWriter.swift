//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A ``NIOAsyncChannelWriter`` is used to write and flush new outbound messages in a channel.
///
/// The writer acts as a bridge between the Concurrency and NIO world. It allows to write and flush messages into the
/// underlying ``Channel``. Furthermore, it respects back-pressure of the channel by suspending the calls to write until
/// the channel becomes writable again.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@_spi(AsyncChannel)
public struct NIOAsyncChannelOutboundWriter<OutboundOut: Sendable>: Sendable {
    @usableFromInline
    typealias _Writer = NIOAsyncChannelOutboundWriterHandler<OutboundOut>.Writer

    @usableFromInline
    let _outboundWriter: _Writer

    @inlinable
    init(
        channel: Channel,
        closeRatchet: CloseRatchet
    ) throws {
        let handler = NIOAsyncChannelOutboundWriterHandler<OutboundOut>(
            eventLoop: channel.eventLoop,
            closeRatchet: closeRatchet
        )
        let writer = _Writer.makeWriter(
            elementType: OutboundOut.self,
            isWritable: true,
            delegate: .init(handler: handler)
        )
        handler.sink = writer.sink

        try channel.pipeline.syncOperations.addHandler(handler)

        self._outboundWriter = writer.writer
    }

    @inlinable
    init(outboundWriter: NIOAsyncChannelOutboundWriterHandler<OutboundOut>.Writer) {
        self._outboundWriter = outboundWriter
    }

    /// Send a write into the ``ChannelPipeline`` and flush it right away.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable
    @_spi(AsyncChannel)
    public func write(_ data: OutboundOut) async throws {
        try await self._outboundWriter.yield(data)
    }

    /// Send a sequence of writes into the ``ChannelPipeline`` and flush them right away.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable
    @_spi(AsyncChannel)
    public func write<Writes: Sequence>(contentsOf sequence: Writes) async throws where Writes.Element == OutboundOut {
        try await self._outboundWriter.yield(contentsOf: sequence)
    }

    /// Send a sequence of writes into the ``ChannelPipeline`` and flush them right away.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable
    @_spi(AsyncChannel)
    public func write<Writes: AsyncSequence>(contentsOf sequence: Writes) async throws where Writes.Element == OutboundOut {
        for try await data in sequence {
            try await self._outboundWriter.yield(data)
        }
    }

    /// Finishes the writer.
    ///
    /// This might trigger a half closure if the ``NIOAsyncChannel`` was configured to support it.
    @_spi(AsyncChannel)
    public func finish() {
        self._outboundWriter.finish()
    }
}
