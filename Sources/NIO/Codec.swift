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


/// State of the current decoding process.
public enum DecodingState {
    /// Continue decoding.
    case `continue`

    /// Stop decoding until more data is ready to be processed.
    case needMoreData
}

/// `ChannelInboundHandler` which decodes bytes in a stream-like fashion from one `ByteBuffer` to
/// another message type.
///
/// If a custom frame decoder is required, then one needs to be careful when implementing
/// one with `ByteToMessageDecoder`. Ensure there are enough bytes in the buffer for a
/// complete frame by checking `buffer.readableBytes`. If there are not enough bytes
/// for a complete frame, return without modifying the reader index to allow more bytes to arrive.
///
/// To check for complete frames without modifying the reader index, use methods like `buffer.getInteger`.
/// One _MUST_ use the reader index when using methods like `buffer.getInteger`.
/// For example calling `buffer.getInteger(at: 0)` is assuming the frame starts at the beginning of the buffer, which
/// is not always the case. Use `buffer.getInteger(at: buffer.readerIndex)` instead.
///
/// If you move the reader index forward, either manually or by using one of `buffer.read*` methods, you must ensure
/// that you no longer need to see those bytes again as they will not be returned to you the next time `decode` is called.
/// If you still need those bytes to come back, consider taking a local copy of buffer inside the function to perform your read operations on.
///
/// The `ByteBuffer` passed in as `buffer` is a slice of a larger buffer owned by the `ByteToMessageDecoder` implementation. Some aspects of this buffer are preserved across calls to `decode`, meaning that any changes to those properties you make in your `decode` method will be reflected in the next call to decode. In particular, the following operations are have the described effects:

/// 1. Moving the reader index forward persists across calls. When your method returns, if the reader index has advanced, those bytes are considered "consumed" and will not be available in future calls to `decode`.
///    Please note, however, that the numerical value of the `readerIndex` itself is not preserved, and may not be the same from one call to the next. Please do not rely on this numerical value: if you need
///    to recall where a byte is relative to the `readerIndex`, use an offset rather than an absolute value.
/// 2. Mutating the bytes in the buffer will cause undefined behaviour and likely crash your program
public protocol ByteToMessageDecoder {
    associatedtype InboundOut

    /// Decode from a `ByteBuffer`. This method will be called till either the input
    /// `ByteBuffer` has nothing to read left or `DecodingState.needMoreData` is returned.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - buffer: The `ByteBuffer` from which we decode.
    /// - returns: `DecodingState.continue` if we should continue calling this method or `DecodingState.needMoreData` if it should be called
    //             again once more data is present in the `ByteBuffer`.
    mutating func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState

    /// This method is called once, when the `ChannelHandlerContext` goes inactive (i.e. when `channelInactive` is fired)
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - buffer: The `ByteBuffer` from which we decode.
    ///     - seenEOF: `true` if EOF has been seen. Usually if this is `false` the handler has been removed.
    /// - returns: `DecodingState.continue` if we should continue calling this method or `DecodingState.needMoreData` if it should be called
    //             again when more data is present in the `ByteBuffer`.
    mutating func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws  -> DecodingState

    /// Called once this `ByteToMessageDecoder` is removed from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    mutating func decoderRemoved(ctx: ChannelHandlerContext)

    /// Called when this `ByteToMessageDecoder` is added to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    mutating func decoderAdded(ctx: ChannelHandlerContext)

    /// Determine if the read bytes in the given `ByteBuffer` should be reclaimed and their associated memory freed.
    /// Be aware that reclaiming memory may involve memory copies and so is not free.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to check
    /// - return: `true` if memory should be reclaimed, `false` otherwise.
    mutating func shouldReclaimBytes(buffer: ByteBuffer) -> Bool
}

extension ByteToMessageDecoder {
    public mutating func decoderRemoved(ctx: ChannelHandlerContext) {
    }

    public mutating func decoderAdded(ctx: ChannelHandlerContext) {
    }

    /// Default implementation to detect once bytes should be reclaimed.
    public func shouldReclaimBytes(buffer: ByteBuffer) -> Bool {
        // We want to reclaim in the following cases:
        //
        // 1. If there is more than 2kB of memory to reclaim
        // 2. If the buffer is more than 50% reclaimable memory and is at least
        //    1kB in size.
        if buffer.readerIndex > 2048 {
            return true
        }
        return buffer.capacity > 1024 && (buffer.capacity - buffer.readerIndex) >= buffer.readerIndex
    }

    public func wrapInboundOut(_ value: InboundOut) -> NIOAny {
        return NIOAny(value)
    }
}

private extension ChannelHandlerContext {
    func withThrowingToFireErrorAndClose<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            self.fireErrorCaught(error)
            self.close(promise: nil)
            return nil
        }
    }
}

private struct B2MDBuffer {
    /// `B2MDBuffer`'s internal state, either we're already processing a buffer or we're ready to.
    private enum State {
        case processingInProgress
        case ready
    }

    /// Can we produce a buffer to be processed right now or not?
    enum BufferAvailability {
        /// No, because no bytes available
        case nothingAvailable
        /// No, because we're already processing one
        case bufferAlreadyBeingProcessed
        /// Yes please, here we go.
        case available(ByteBuffer)
    }

    /// Result of a try to process a buffer.
    enum BufferProcessingResult {
        /// Could not process a buffer because we are already processing one on the same call stack.
        case cannotProcessReentrantly
        /// Yes, we did process some.
        case didProcess(DecodingState)
    }

    private var state: State = .ready
    private var buffers: CircularBuffer<ByteBuffer> = CircularBuffer(initialCapacity: 4)
    private let emptyByteBuffer: ByteBuffer

    init(emptyByteBuffer: ByteBuffer) {
        assert(emptyByteBuffer.readableBytes == 0)
        self.emptyByteBuffer = emptyByteBuffer
    }
}

// MARK: B2MDBuffer Main API
extension B2MDBuffer {
    /// Start processing some bytes if possible, if we receive a returned buffer (through `.available(ByteBuffer)`)
    /// we _must_ indicate the processing has finished by calling `finishProcessing`.
    mutating func startProcessing(allowEmptyBuffer: Bool) -> BufferAvailability {
        switch self.state {
        case .processingInProgress:
            return .bufferAlreadyBeingProcessed
        case .ready where self.buffers.count > 0:
            var buffer = self.buffers.removeFirst()
            buffer.writeBuffers(self.buffers)
            self.buffers.removeAll(keepingCapacity: self.buffers.capacity < 16) // don't grow too much
            if buffer.readableBytes > 0 || allowEmptyBuffer {
                self.state = .processingInProgress
                return .available(buffer)
            } else {
                return .nothingAvailable
            }
        case .ready:
            assert(self.buffers.count == 0)
            if allowEmptyBuffer {
                self.state = .processingInProgress
                return .available(self.emptyByteBuffer)
            }
            return .nothingAvailable
        }
    }


    mutating func finishProcessing(remainder buffer: ByteBuffer) -> Void {
        assert(self.state == .processingInProgress)
        self.state = .ready
        if buffer.readableBytes > 0 {
            self.buffers.prepend(buffer)
        } else {
            var buffer = buffer
            buffer.clear()
            buffer.writeBuffers(self.buffers)
            self.buffers.removeAll(keepingCapacity: self.buffers.capacity < 16) // don't grow too much
            self.buffers.append(buffer)
        }
    }

    mutating func append(buffer: ByteBuffer) {
        if buffer.readableBytes > 0 {
            self.buffers.append(buffer)
        }
    }
}

// MARK: B2MDBuffer Helpers
private extension ByteBuffer {
    mutating func writeBuffers(_ buffers: CircularBuffer<ByteBuffer>) {
        guard buffers.count > 0 else {
            return
        }
        var requiredCapacity: Int = self.writerIndex
        for buffer in buffers {
            requiredCapacity += buffer.readableBytes
        }
        self.reserveCapacity(requiredCapacity)
        for var buffer in buffers {
            self.writeBuffer(&buffer)
        }
    }
}

private extension B2MDBuffer {
    func _testOnlyOneBuffer() -> ByteBuffer? {
        switch self.buffers.count {
        case 0:
            return nil
        case 1:
            return self.buffers.first
        default:
            let firstIndex = self.buffers.startIndex
            var firstBuffer = self.buffers[firstIndex]
            for var buffer in self.buffers[self.buffers.index(after: firstIndex)...] {
                firstBuffer.writeBuffer(&buffer)
            }
            return firstBuffer
        }
    }
}

public class ByteToMessageHandler<Decoder: ByteToMessageDecoder> {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = Decoder.InboundOut

    private enum DecodeMode {
        /// This is a usual decode, ie. not the last chunk
        case normal

        /// Last chunk
        case last
    }

    private enum RemovalState {
        case notBeingRemoved
        case removalStarted
        case removalCompleted
    }

    private enum State {
        case active
        case leftoversNeedProcessing
        case done
    }

    internal private(set) var decoder: Decoder? // only `nil` if we're already decoding (ie. we're re-entered)
    private var state: State = .active
    private var removalState: RemovalState = .notBeingRemoved
    // sadly to construct a B2MDBuffer we need an empty ByteBuffer which we can only get from the allocator, so IUO.
    private var buffer: B2MDBuffer!
    private var seenEOF: Bool = false

    public init(_ decoder: Decoder) {
        self.decoder = decoder
    }

    deinit {
        assert(self.removalState == .removalCompleted, "illegal state in deinit: removalState = \(self.removalState)")
        assert(self.state == .done, "illegal state in deinit: state = \(self.state)")
    }
}

// MARK: ByteToMessageHandler: Test Helpers
extension ByteToMessageHandler {
    internal var cumulationBuffer: ByteBuffer? {
        return self.buffer._testOnlyOneBuffer()
    }
}

// MARK: ByteToMessageHandler's Main API
extension ByteToMessageHandler {
    private func withNextBuffer(allowEmptyBuffer: Bool, _ body: (inout Decoder, inout ByteBuffer) throws -> DecodingState) rethrows -> B2MDBuffer.BufferProcessingResult {
        switch self.buffer.startProcessing(allowEmptyBuffer: allowEmptyBuffer) {
        case .bufferAlreadyBeingProcessed:
            return .cannotProcessReentrantly
        case .nothingAvailable:
            return .didProcess(.needMoreData)
        case .available(var buffer):
            var decoder: Decoder? = nil
            swap(&decoder, &self.decoder)
            assert(decoder != nil) // self.decoder only `nil` if we're being re-entered, but .available means we're not
            defer {
                swap(&decoder, &self.decoder)
                if buffer.readableBytes > 0 {
                    // we asserted above that the decoder we just swapped back in was non-nil so now `self.decoder` must
                    // be non-nil.
                    if self.decoder!.shouldReclaimBytes(buffer: buffer) {
                        buffer.discardReadBytes()
                    }
                }
                self.buffer.finishProcessing(remainder: buffer)
            }
            return .didProcess(try body(&decoder!, &buffer))
        }
    }

    private func processLeftovers(ctx: ChannelHandlerContext) {
        guard self.state == .active else {
            // we are processing or have already processed the leftovers
            return
        }

        ctx.withThrowingToFireErrorAndClose {
            switch try self.decodeLoop(ctx: ctx, decodeMode: .last) {
            case .didProcess:
                self.state = .done
            case .cannotProcessReentrantly:
                self.state = .leftoversNeedProcessing
            }
        }
    }

    private func decodeLoop(ctx: ChannelHandlerContext, decodeMode: DecodeMode) throws -> B2MDBuffer.BufferProcessingResult {
        var allowEmptyBuffer = decodeMode == .last
        while decodeMode == .last || self.removalState == .notBeingRemoved {
            let result = try self.withNextBuffer(allowEmptyBuffer: allowEmptyBuffer) { decoder, buffer in
                if decodeMode == .normal {
                    return try decoder.decode(ctx: ctx, buffer: &buffer)
                } else {
                    allowEmptyBuffer = false
                    return try decoder.decodeLast(ctx: ctx, buffer: &buffer, seenEOF: self.seenEOF)
                }
            }
            switch result {
            case .didProcess(.continue):
                continue
            case .didProcess(.needMoreData):
                return .didProcess(.needMoreData)
            case .cannotProcessReentrantly:
                return .cannotProcessReentrantly
            }
        }
        return .didProcess(.continue)
    }
}

// MARK: ByteToMessageHandler: ChannelInboundHandler
extension ByteToMessageHandler: ChannelInboundHandler {

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.buffer = B2MDBuffer(emptyByteBuffer: ctx.channel.allocator.buffer(capacity: 0))
        // here we can force it because we know that the decoder isn't in use if we're just adding this handler
        self.decoder!.decoderAdded(ctx: ctx)
    }


    public func handlerRemoved(ctx: ChannelHandlerContext) {
        // very likely, the removal state is `.notBeingRemoved` or `.removalCompleted` here but we can't assert it
        // because the pipeline might be torn down during the formal removal process.
        self.removalState = .removalCompleted
        self.state = .done
    }

    /// Calls `decode` until there is nothing left to decode.
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        self.buffer.append(buffer: self.unwrapInboundIn(data))
        ctx.withThrowingToFireErrorAndClose {
            switch try self.decodeLoop(ctx: ctx, decodeMode: .normal) {
            case .didProcess:
                switch self.state {
                case .active:
                    () // cool, all normal
                case .done:
                    () // fair, all done already
                case .leftoversNeedProcessing:
                    // seems like we received a `channelInactive` or `handlerRemoved` whilst we were processing a read
                    defer {
                        self.state = .done
                    }
                    switch try self.decodeLoop(ctx: ctx, decodeMode: .last) {
                    case .didProcess:
                        () // expected and cool
                    case .cannotProcessReentrantly:
                        preconditionFailure("bug in NIO: non-reentrant decode loop couldn't run \(self), \(self.state)")
                    }
                }
            case .cannotProcessReentrantly:
                // fine, will be done later
                ()
            }
        }
    }

    /// Call `decodeLast` before forward the event through the pipeline.
    public func channelInactive(ctx: ChannelHandlerContext) {
        self.seenEOF = true

        self.processLeftovers(ctx: ctx)

        ctx.fireChannelInactive()
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if event as? ChannelEvent == .some(.inputClosed) {
            self.seenEOF = true

            self.processLeftovers(ctx: ctx)
        }
        ctx.fireUserInboundEventTriggered(event)
    }
}

/// `ChannelOutboundHandler` which allows users to encode custom messages to a `ByteBuffer` easily.
public protocol MessageToByteEncoder: ChannelOutboundHandler where OutboundOut == ByteBuffer {

    /// Called once there is data to encode. The used `ByteBuffer` is allocated by `allocateOutBuffer`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - data: The data to encode into a `ByteBuffer`.
    ///     - out: The `ByteBuffer` into which we want to encode.
    func encode(ctx: ChannelHandlerContext, data: OutboundIn, out: inout ByteBuffer) throws

    /// Returns a `ByteBuffer` to be used by `encode`.
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - data: The data to encode into a `ByteBuffer` by `encode`.
    /// - return: A `ByteBuffer` to use.
    func allocateOutBuffer(ctx: ChannelHandlerContext, data: OutboundIn) throws -> ByteBuffer
}

extension MessageToByteEncoder {

    /// Encodes the data into a `ByteBuffer` and writes it.
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        do {
            let data = self.unwrapOutboundIn(data)
            var buffer: ByteBuffer = try allocateOutBuffer(ctx: ctx, data: data)
            try encode(ctx: ctx, data: data, out: &buffer)
            ctx.write(self.wrapOutboundOut(buffer), promise: promise)
        } catch let err {
            promise?.fail(err)
        }
    }

    /// Default implementation which just allocates a `ByteBuffer` with capacity of `256`.
    public func allocateOutBuffer(ctx: ChannelHandlerContext, data: OutboundIn) throws -> ByteBuffer {
        return ctx.channel.allocator.buffer(capacity: 256)
    }
}

extension ByteToMessageHandler: RemovableChannelHandler {
    public func removeHandler(ctx: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        precondition(self.removalState == .notBeingRemoved)
        self.removalState = .removalStarted
        ctx.eventLoop.execute {
            self.processLeftovers(ctx: ctx)
            assert(self.state != .leftoversNeedProcessing)
            assert(self.removalState == .removalStarted)
            self.removalState = .removalCompleted
            ctx.leavePipeline(removalToken: removalToken)
        }
    }
}
