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

/// Common errors thrown by `ByteToMessageDecoder`s.
public enum ByteToMessageDecoderError: Error {
    /// More data has been received by a `ByteToMessageHandler` despite the fact that an error has previously been
    /// emitted. The associated `Error` is the error previously emitted and the `ByteBuffer` is the extra data that has
    /// been received. The common cause for this error to be emitted is the user not having torn down the `Channel`
    /// after previously an `Error` has been sent through the pipeline using `fireErrorCaught`.
    case dataReceivedInErrorState(Error, ByteBuffer)

    /// This error can be thrown by `ByteToMessageDecoder`s if there was unexpectedly some left-over data when the
    /// `ByteToMessageDecoder` was removed from the pipeline or the `Channel` was closed.
    case leftoverDataWhenDone(ByteBuffer)
}

extension ByteToMessageDecoderError {
    // TODO: For NIO 3, make this an enum case (or whatever best way for Errors we have come up with).
    /// This error can be thrown by `ByteToMessageDecoder`s if the incoming payload is larger than the max specified.
    public struct PayloadTooLargeError: Error {
        public init() {}
    }
}


/// `ByteToMessageDecoder`s decode bytes in a stream-like fashion from `ByteBuffer` to another message type.
///
/// ### Purpose
///
/// A `ByteToMessageDecoder` provides a simplified API for handling streams of incoming data that can be broken
/// up into messages. This API boils down to two methods: `decode`, and `decodeLast`. These two methods, when
/// implemented, will be used by a `ByteToMessageHandler` paired with a `ByteToMessageDecoder` to decode the
/// incoming byte stream into a sequence of messages.
///
/// The reason this helper exists is to smooth away some of the boilerplate and edge case handling code that
/// is often necessary when implementing parsers in a SwiftNIO `ChannelPipeline`. A `ByteToMessageDecoder`
/// never needs to worry about how inbound bytes will be buffered, as `ByteToMessageHandler` deals with that
/// automatically. A `ByteToMessageDecoder` also never needs to worry about memory exclusivity violations
/// that can occur when re-entrant `ChannelPipeline` operations occur, as `ByteToMessageHandler` will deal with
/// those as well.
///
/// ### Implementing ByteToMessageDecoder
///
/// A type that implements `ByteToMessageDecoder` may implement two methods: decode and decodeLast. Implementations
/// must implement decode: if they do not implement decodeLast, a default implementation will be used that 
/// simply calls decode.
///
/// `decode` is the main decoding method, and is the one that will be called most often. `decode` is invoked
/// whenever data is received by the wrapping `ByteToMessageHandler`. It is invoked with a `ByteBuffer` containing
/// all the received data (including any data previously buffered), as well as a `ChannelHandlerContext` that can be
/// used in the `decode` function.
///
/// `decode` is called in a loop by the `ByteToMessageHandler`. This loop continues until one of two cases occurs:
///
/// 1. The input `ByteBuffer` has no more readable bytes (i.e. `.readableBytes == 0`); OR
/// 2. The `decode` method returns `.needMoreData`.
///
/// The reason this method is invoked in a loop is to ensure that the stream-like properties of inbound data are
/// respected. It is entirely possible for `ByteToMessageDecoder` to receive either fewer bytes than a single message,
/// or multiple messages in one go. Rather than have the `ByteToMessageDecoder` handle all of the complexity of this,
/// the logic can be boiled down to a single choice: has the `ByteToMessageDecoder` been able to move the state forward
/// or not? If it has, rather than containing an internal loop it may simply return `.continue` in order to request that
/// `decode` be invoked again immediately. If it has not, it can return `.needMoreData` to ask to be left alone until more
/// data has been returned from the network.
///
/// Essentially, if the next parsing step could not be taken because there wasn't enough data available, return `.needMoreData`.
/// Otherwise, return `.continue`. This will allow a `ByteToMessageDecoder` implementation to ignore the awkward way data
/// arrives from the network, and to just treat it as a series of `decode` calls.
///
/// `decodeLast` is a cousin of `decode`. It is also called in a loop, but unlike with `decode` this loop will only ever
/// occur once: when the `ChannelHandlerContext` belonging to this `ByteToMessageDecoder` is about to become invalidated.
/// This invalidation happens in two situations: when EOF is received from the network, or when the `ByteToMessageDecoder`
/// is being removed from the `ChannelPipeline`. The distinction between these two states is captured by the value of
/// `seenEOF`.
///
/// In this condition, the `ByteToMessageDecoder` must now produce any final messages it can with the bytes it has
/// available. In protocols where EOF is used as a message delimiter, having `decodeLast` called with `seenEOF == true`
/// may produce further messages. In other cases, `decodeLast` may choose to deliver any buffered bytes as "leftovers",
/// either in error messages or via `channelRead`. This can occur if, for example, a protocol upgrade is occurring.
///
/// As with `decode`, `decodeLast` is invoked in a loop. This allows the same simplification as `decode` allows: when
/// a message is completely parsed, the `decodeLast` function can return `.continue` and be re-invoked from the top,
/// rather than containing an internal loop.
///
/// Note that the value of `seenEOF` may change between calls to `decodeLast` in some rare situations.
///
/// ### Implementers Notes
///
/// /// `ByteToMessageHandler` will turn your `ByteToMessageDecoder` into a `ChannelInboundHandler`. `ByteToMessageHandler`
/// also solves a couple of tricky issues for you. Most importantly, in a `ByteToMessageDecoder` you do _not_ need to
/// worry about re-entrancy. Your code owns the passed-in `ByteBuffer` for the duration of the `decode`/`decodeLast` call and
/// can modify it at will.
///
/// If a custom frame decoder is required, then one needs to be careful when implementing
/// one with `ByteToMessageDecoder`. Ensure there are enough bytes in the buffer for a
/// complete frame by checking `buffer.readableBytes`. If there are not enough bytes
/// for a complete frame, return without modifying the reader index to allow more bytes to arrive.
///
/// To check for complete frames without modifying the reader index, use methods like `buffer.getInteger`.
/// You  _MUST_ use the reader index when using methods like `buffer.getInteger`.
/// For example calling `buffer.getInteger(at: 0)` is assuming the frame starts at the beginning of the buffer, which
/// is not always the case. Use `buffer.getInteger(at: buffer.readerIndex)` instead.
///
/// If you move the reader index forward, either manually or by using one of `buffer.read*` methods, you must ensure
/// that you no longer need to see those bytes again as they will not be returned to you the next time `decode` is
/// called. If you still need those bytes to come back, consider taking a local copy of buffer inside the function to
/// perform your read operations on.
///
/// The `ByteBuffer` passed in as `buffer` is a slice of a larger buffer owned by the `ByteToMessageDecoder`
/// implementation. Some aspects of this buffer are preserved across calls to `decode`, meaning that any changes to
/// those properties you make in your `decode` method will be reflected in the next call to decode. In particular,
/// moving the reader index forward persists across calls. When your method returns, if the reader index has advanced,
/// those bytes are considered "consumed" and will not be available in future calls to `decode`.
/// Please note, however, that the numerical value of the `readerIndex` itself is not preserved, and may not be the same
/// from one call to the next. Please do not rely on this numerical value: if you need
/// to recall where a byte is relative to the `readerIndex`, use an offset rather than an absolute value.
///
/// ### Using ByteToMessageDecoder
///
/// To add a `ByteToMessageDecoder` to the `ChannelPipeline` use
///
///     channel.pipeline.addHandler(ByteToMessageHandler(MyByteToMessageDecoder()))
///
public protocol ByteToMessageDecoder {
    /// The type of the messages this `ByteToMessageDecoder` decodes to.
    associatedtype InboundOut

    /// Decode from a `ByteBuffer`.
    ///
    /// This method will be called in a loop until either the input `ByteBuffer` has nothing to read left or
    /// `DecodingState.needMoreData` is returned. If `DecodingState.continue` is returned and the `ByteBuffer`
    /// contains more readable bytes, this method will immediately be invoked again, unless `decodeLast` needs
    /// to be invoked instead.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - buffer: The `ByteBuffer` from which we decode.
    /// - returns: `DecodingState.continue` if we should continue calling this method or `DecodingState.needMoreData` if it should be called
    ///            again once more data is present in the `ByteBuffer`.
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState

    /// Decode from a `ByteBuffer` when no more data is incoming and the `ByteToMessageDecoder` is about to leave
    /// the pipeline.
    ///
    /// This method is called in a loop only once, when the `ChannelHandlerContext` goes inactive (i.e. when `channelInactive` is fired or
    /// the `ByteToMessageDecoder` is removed from the pipeline).
    ///
    /// Like with `decode`, this method will be called in a loop until either `DecodingState.needMoreData` is returned from the method
    /// or until the input `ByteBuffer` has no more readable bytes. If `DecodingState.continue` is returned and the `ByteBuffer`
    /// contains more readable bytes, this method will immediately be invoked again.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - buffer: The `ByteBuffer` from which we decode.
    ///     - seenEOF: `true` if EOF has been seen. Usually if this is `false` the handler has been removed.
    /// - returns: `DecodingState.continue` if we should continue calling this method or `DecodingState.needMoreData` if it should be called
    ///            again when more data is present in the `ByteBuffer`.
    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws  -> DecodingState

    /// Called once this `ByteToMessageDecoder` is removed from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    mutating func decoderRemoved(context: ChannelHandlerContext)

    /// Called when this `ByteToMessageDecoder` is added to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    mutating func decoderAdded(context: ChannelHandlerContext)

    /// Determine if the read bytes in the given `ByteBuffer` should be reclaimed and their associated memory freed.
    /// Be aware that reclaiming memory may involve memory copies and so is not free.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to check
    /// - return: `true` if memory should be reclaimed, `false` otherwise.
    mutating func shouldReclaimBytes(buffer: ByteBuffer) -> Bool
}

/// Some `ByteToMessageDecoder`s need to observe `write`s (which are outbound events). `ByteToMessageDecoder`s which
/// implement the `WriteObservingByteToMessageDecoder` protocol will be notified about every outbound write.
///
/// `WriteObservingByteToMessageDecoder` may only observe a `write` and must not try to transform or block it in any
/// way. After the `write` method returns the `write` will be forwarded to the next outbound handler.
public protocol WriteObservingByteToMessageDecoder: ByteToMessageDecoder {
    /// The type of `write`s.
    associatedtype OutboundIn

    /// `write` is called for every incoming `write` incoming to the corresponding `ByteToMessageHandler`.
    ///
    /// - parameters:
    ///    - data: The data that was written.
    mutating func write(data: OutboundIn)
}

extension ByteToMessageDecoder {
    public mutating func decoderRemoved(context: ChannelHandlerContext) {
    }

    public mutating func decoderAdded(context: ChannelHandlerContext) {
    }

    /// Default implementation to detect once bytes should be reclaimed.
    public func shouldReclaimBytes(buffer: ByteBuffer) -> Bool {
        // We want to reclaim in the following cases:
        //
        // 1. If there is at least 2kB of memory to reclaim
        // 2. If the buffer is more than 50% reclaimable memory and is at least
        //    1kB in size.
        if buffer.readerIndex >= 2048 {
            return true
        }
        return buffer.storageCapacity > 1024 && (buffer.storageCapacity - buffer.readerIndex) < buffer.readerIndex
    }

    public func wrapInboundOut(_ value: InboundOut) -> NIOAny {
        return NIOAny(value)
    }
    
    public mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws  -> DecodingState {
        while try self.decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
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
            assert(self.buffers.isEmpty)
            if allowEmptyBuffer {
                self.state = .processingInProgress
                return .available(self.emptyByteBuffer)
            }
            return .nothingAvailable
        }
    }

    mutating func finishProcessing(remainder buffer: inout ByteBuffer) -> Void {
        assert(self.state == .processingInProgress)
        self.state = .ready
        if buffer.readableBytes == 0 && self.buffers.isEmpty {
            // fast path, no bytes left and no other buffers, just return
            return
        }
        if buffer.readableBytes > 0 {
            self.buffers.prepend(buffer)
        } else {
            buffer.discardReadBytes()
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

/// A handler which turns a given `ByteToMessageDecoder` into a `ChannelInboundHandler` that can then be added to a
/// `ChannelPipeline`.
///
/// Most importantly, `ByteToMessageHandler` handles the tricky buffer management for you and flattens out all
/// re-entrancy on `channelRead` that may happen in the `ChannelPipeline`.
public final class ByteToMessageHandler<Decoder: ByteToMessageDecoder> {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = Decoder.InboundOut

    private enum DecodeMode {
        /// This is a usual decode, ie. not the last chunk
        case normal

        /// Last chunk
        case last
    }

    private enum RemovalState {
        /// Not added to any `ChannelPipeline` yet.
        case notAddedToPipeline

        /// No one tried to remove this handler.
        case notBeingRemoved

        /// The user-triggered removal has been started but isn't complete yet. This state will not be entered if the
        /// removal is triggered by Channel teardown.
        case removalStarted

        /// The user-triggered removal is complete. This state will not be entered if the removal is triggered by
        /// Channel teardown.
        case removalCompleted

        /// This handler has been removed from the pipeline.
        case handlerRemovedCalled
    }

    private enum State {
        case active
        case leftoversNeedProcessing
        case done
        case error(Error)

        var isError: Bool {
            switch self {
            case .active, .leftoversNeedProcessing, .done:
                return false
            case .error:
                return true
            }
        }

        var isFinalState: Bool {
            switch self {
            case .active, .leftoversNeedProcessing:
                return false
            case .done, .error:
                return true
            }
        }

        var isActive: Bool {
            switch self {
            case .done, .error, .leftoversNeedProcessing:
                return false
            case .active:
                return true
            }
        }

        var isLeftoversNeedProcessing: Bool {
            switch self {
            case .done, .error, .active:
                return false
            case .leftoversNeedProcessing:
                return true
            }
        }
    }

    internal private(set) var decoder: Decoder? // only `nil` if we're already decoding (ie. we're re-entered)
    private let maximumBufferSize: Int?
    private var queuedWrites = CircularBuffer<NIOAny>(initialCapacity: 1) // queues writes received whilst we're already decoding (re-entrant write)
    private var state: State = .active {
        willSet {
            assert(!self.state.isFinalState, "illegal state on state set: \(self.state)") // we can never leave final states
        }
    }
    private var removalState: RemovalState = .notAddedToPipeline
    // sadly to construct a B2MDBuffer we need an empty ByteBuffer which we can only get from the allocator, so IUO.
    private var buffer: B2MDBuffer!
    private var seenEOF: Bool = false
    private var selfAsCanDequeueWrites: CanDequeueWrites? = nil

    /// @see: ByteToMessageHandler.init(_:maximumBufferSize)
    public convenience init(_ decoder: Decoder) {
        self.init(decoder, maximumBufferSize: nil)
    }

    /// Initialize a `ByteToMessageHandler`.
    ///
    /// - parameters:
    ///     - decoder: The `ByteToMessageDecoder` to decode the bytes into message.
    ///     - maximumBufferSize: The maximum number of bytes to aggregate in-memory.
    public init(_ decoder: Decoder, maximumBufferSize: Int? = nil) {
        self.decoder = decoder
        self.maximumBufferSize = maximumBufferSize
    }

    deinit {
        if self.removalState != .notAddedToPipeline {
            // we have been added to the pipeline, if not, we don't need to check our state.
            assert(self.removalState == .handlerRemovedCalled,
                   "illegal state in deinit: removalState = \(self.removalState)")
            assert(self.state.isFinalState, "illegal state in deinit: state = \(self.state)")
        }
    }
}

// MARK: ByteToMessageHandler: Test Helpers
extension ByteToMessageHandler {
    internal var cumulationBuffer: ByteBuffer? {
        return self.buffer._testOnlyOneBuffer()
    }
}

private protocol CanDequeueWrites {
    func dequeueWrites()
}

extension ByteToMessageHandler: CanDequeueWrites where Decoder: WriteObservingByteToMessageDecoder {
    fileprivate func dequeueWrites() {
        while self.queuedWrites.count > 0 {
            // self.decoder can't be `nil`, this is only allowed to be called when we're not already on the stack
            self.decoder!.write(data: self.unwrapOutboundIn(self.queuedWrites.removeFirst()))
        }
    }
}


// MARK: ByteToMessageHandler's Main API
extension ByteToMessageHandler {
    @inline(__always) // allocations otherwise (reconsider with Swift 5.1)
    private func withNextBuffer(allowEmptyBuffer: Bool, _ body: (inout Decoder, inout ByteBuffer) throws -> DecodingState) rethrows -> B2MDBuffer.BufferProcessingResult {
        switch self.buffer.startProcessing(allowEmptyBuffer: allowEmptyBuffer) {
        case .bufferAlreadyBeingProcessed:
            return .cannotProcessReentrantly
        case .nothingAvailable:
            return .didProcess(.needMoreData)
        case .available(var buffer):
            var possiblyReclaimBytes = false
            var decoder: Decoder? = nil
            swap(&decoder, &self.decoder)
            assert(decoder != nil) // self.decoder only `nil` if we're being re-entered, but .available means we're not
            defer {
                swap(&decoder, &self.decoder)
                if buffer.readableBytes > 0 && possiblyReclaimBytes {
                    // we asserted above that the decoder we just swapped back in was non-nil so now `self.decoder` must
                    // be non-nil.
                    if self.decoder!.shouldReclaimBytes(buffer: buffer) {
                        buffer.discardReadBytes()
                    }
                }
                self.buffer.finishProcessing(remainder: &buffer)
            }
            let decodeResult = try body(&decoder!, &buffer)

            // If we .continue, there's no point in trying to reclaim bytes because we'll loop again. If we need more
            // data on the other hand, we should try to reclaim some of those bytes.
            possiblyReclaimBytes = decodeResult == .needMoreData
            return .didProcess(decodeResult)
        }
    }

    private func processLeftovers(context: ChannelHandlerContext) {
        guard self.state.isActive else {
            // we are processing or have already processed the leftovers
            return
        }

        do {
            switch try self.decodeLoop(context: context, decodeMode: .last) {
            case .didProcess:
                self.state = .done
            case .cannotProcessReentrantly:
                self.state = .leftoversNeedProcessing
            }
        } catch {
            self.state = .error(error)
            context.fireErrorCaught(error)
        }
    }

    private func tryDecodeWrites() {
        if self.queuedWrites.count > 0 {
            // this must succeed because unless we implement `CanDequeueWrites`, `queuedWrites` must always be empty.
            self.selfAsCanDequeueWrites!.dequeueWrites()
        }
    }

    private func decodeLoop(context: ChannelHandlerContext, decodeMode: DecodeMode) throws -> B2MDBuffer.BufferProcessingResult {
        assert(!self.state.isError)
        var allowEmptyBuffer = decodeMode == .last
        while (self.state.isActive && self.removalState == .notBeingRemoved) || decodeMode == .last {
            let result = try self.withNextBuffer(allowEmptyBuffer: allowEmptyBuffer) { decoder, buffer in
                let decoderResult: DecodingState
                if decodeMode == .normal {
                    assert(self.state.isActive, "illegal state for normal decode: \(self.state)")
                    decoderResult = try decoder.decode(context: context, buffer: &buffer)
                } else {
                    allowEmptyBuffer = false
                    decoderResult = try decoder.decodeLast(context: context, buffer: &buffer, seenEOF: self.seenEOF)
                }
                if decoderResult == .needMoreData, let maximumBufferSize = self.maximumBufferSize, buffer.readableBytes > maximumBufferSize {
                    throw ByteToMessageDecoderError.PayloadTooLargeError()
                }
                return decoderResult
            }
            switch result {
            case .didProcess(.continue):
                self.tryDecodeWrites()
                continue
            case .didProcess(.needMoreData):
                if self.queuedWrites.count > 0 {
                    self.tryDecodeWrites()
                    continue // we might have received more, so let's spin once more
                } else {
                    return .didProcess(.needMoreData)
                }
            case .cannotProcessReentrantly:
                return .cannotProcessReentrantly
            }
        }
        return .didProcess(.continue)
    }
}


// MARK: ByteToMessageHandler: ChannelInboundHandler
extension ByteToMessageHandler: ChannelInboundHandler {

    public func handlerAdded(context: ChannelHandlerContext) {
        guard self.removalState == .notAddedToPipeline else {
            preconditionFailure("\(self) got readded to a ChannelPipeline but ByteToMessageHandler is single-use")
        }
        self.removalState = .notBeingRemoved
        self.buffer = B2MDBuffer(emptyByteBuffer: context.channel.allocator.buffer(capacity: 0))
        // here we can force it because we know that the decoder isn't in use if we're just adding this handler
        self.selfAsCanDequeueWrites = self as? CanDequeueWrites // we need to cache this as it allocates.
        self.decoder!.decoderAdded(context: context)
    }


    public func handlerRemoved(context: ChannelHandlerContext) {
        // very likely, the removal state is `.notBeingRemoved` or `.removalCompleted` here but we can't assert it
        // because the pipeline might be torn down during the formal removal process.
        self.removalState = .handlerRemovedCalled
        if !self.state.isFinalState {
            self.state = .done
        }

        self.selfAsCanDequeueWrites = nil

        // here we can force it because we know that the decoder isn't in use because the removal is always
        // eventLoop.execute'd
        self.decoder!.decoderRemoved(context: context)
    }

    /// Calls `decode` until there is nothing left to decode.
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if case .error(let error) = self.state {
            context.fireErrorCaught(ByteToMessageDecoderError.dataReceivedInErrorState(error, buffer))
            return
        }
        self.buffer.append(buffer: buffer)
        do {
            switch try self.decodeLoop(context: context, decodeMode: .normal) {
            case .didProcess:
                switch self.state {
                case .active:
                    () // cool, all normal
                case .done, .error:
                    () // fair, all done already
                case .leftoversNeedProcessing:
                    // seems like we received a `channelInactive` or `handlerRemoved` whilst we were processing a read
                    switch try self.decodeLoop(context: context, decodeMode: .last) {
                    case .didProcess:
                        () // expected and cool
                    case .cannotProcessReentrantly:
                        preconditionFailure("bug in NIO: non-reentrant decode loop couldn't run \(self), \(self.state)")
                    }
                    self.state = .done
                }
            case .cannotProcessReentrantly:
                // fine, will be done later
                ()
            }
        } catch {
            self.state = .error(error)
            context.fireErrorCaught(error)
        }
    }

    /// Call `decodeLast` before forward the event through the pipeline.
    public func channelInactive(context: ChannelHandlerContext) {
        self.seenEOF = true

        self.processLeftovers(context: context)

        context.fireChannelInactive()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event as? ChannelEvent == .some(.inputClosed) {
            self.seenEOF = true

            self.processLeftovers(context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

extension ByteToMessageHandler: ChannelOutboundHandler, _ChannelOutboundHandler where Decoder: WriteObservingByteToMessageDecoder {
    public typealias OutboundIn = Decoder.OutboundIn
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if self.decoder != nil {
            let data = self.unwrapOutboundIn(data)
            assert(self.queuedWrites.isEmpty)
            self.decoder!.write(data: data)
        } else {
            self.queuedWrites.append(data)
        }
        context.write(data, promise: promise)
    }
}

/// A protocol for straightforward encoders which encode custom messages to `ByteBuffer`s.
/// To add a `MessageToByteEncoder` to a `ChannelPipeline`, use
/// `channel.pipeline.addHandler(MessageToByteHandler(myEncoder)`.
public protocol MessageToByteEncoder {
    associatedtype OutboundIn

    /// Called once there is data to encode.
    ///
    /// - parameters:
    ///     - data: The data to encode into a `ByteBuffer`.
    ///     - out: The `ByteBuffer` into which we want to encode.
    func encode(data: OutboundIn, out: inout ByteBuffer) throws
}

extension ByteToMessageHandler: RemovableChannelHandler {
    public func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        precondition(self.removalState == .notBeingRemoved)
        self.removalState = .removalStarted
        context.eventLoop.execute {
            self.processLeftovers(context: context)
            assert(!self.state.isLeftoversNeedProcessing, "illegal state: \(self.state)")
            switch self.removalState {
            case .removalStarted:
                self.removalState = .removalCompleted
            case .handlerRemovedCalled:
                // if we're here, then the channel has also been torn down between the start and the completion of
                // the user-triggered removal. That's okay.
                ()
            default:
                assertionFailure("illegal removal state: \(self.removalState)")
            }
            // this is necessary as it'll complete the promise.
            context.leavePipeline(removalToken: removalToken)
        }
    }
}

/// A handler which turns a given `MessageToByteEncoder` into a `ChannelOutboundHandler` that can then be added to a
/// `ChannelPipeline`.
public final class MessageToByteHandler<Encoder: MessageToByteEncoder>: ChannelOutboundHandler {
    public typealias OutboundOut = ByteBuffer
    public typealias OutboundIn = Encoder.OutboundIn

    private enum State {
        case notInChannelYet
        case operational
        case error(Error)
        case done

        var readyToBeAddedToChannel: Bool {
            switch self {
            case .notInChannelYet:
                return true
            case .operational, .error, .done:
                return false
            }
        }
    }

    private var state: State = .notInChannelYet
    private let encoder: Encoder
    private var buffer: ByteBuffer? = nil

    public init(_ encoder: Encoder) {
        self.encoder = encoder
    }
}

extension MessageToByteHandler {
    public func handlerAdded(context: ChannelHandlerContext) {
        precondition(self.state.readyToBeAddedToChannel,
                     "illegal state when adding to Channel: \(self.state)")
        self.state = .operational
        self.buffer = context.channel.allocator.buffer(capacity: 256)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.state = .done
        self.buffer = nil
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.state {
        case .notInChannelYet:
            preconditionFailure("MessageToByteHandler.write called before it was added to a Channel")
        case .error(let error):
            promise?.fail(error)
            context.fireErrorCaught(error)
            return
        case .done:
            // let's just ignore this
            return
        case .operational:
            // there's actually some work to do here
            break
        }
        let data = self.unwrapOutboundIn(data)

        do {
            self.buffer!.clear()
            try self.encoder.encode(data: data, out: &self.buffer!)
            context.write(self.wrapOutboundOut(self.buffer!), promise: promise)
        } catch {
            self.state = .error(error)
            promise?.fail(error)
            context.fireErrorCaught(error)
        }
    }
}
