//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SystemPackage

/// An `AsyncSequence` of ordered chunks read from a file.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct FileChunks: AsyncSequence, Sendable {
    public typealias Element = ByteBuffer

    /// The underlying buffered stream.
    private let stream: BufferedOrAnyStream<ByteBuffer, FileChunkProducer>

    /// Create a ``FileChunks`` sequence backed by wrapping an `AsyncSequence`.
    @preconcurrency
    public init<S: AsyncSequence & Sendable>(wrapping sequence: S)
    where S.Element == ByteBuffer, S.AsyncIterator: NIOFileSystemSendableMetatype {
        self.stream = BufferedOrAnyStream(wrapping: sequence)
    }

    internal init(
        handle: SystemFileHandle,
        chunkLength: ByteCount,
        range: Range<Int64>
    ) {
        // TODO: choose reasonable watermarks; this should likely be at least somewhat dependent
        // on the chunk size.
        let stream = NIOThrowingAsyncSequenceProducer.makeFileChunksStream(
            of: ByteBuffer.self,
            handle: handle,
            chunkLength: chunkLength.bytes,
            range: range,
            lowWatermark: 4,
            highWatermark: 8
        )

        self.stream = BufferedOrAnyStream(wrapping: stream)
    }

    public func makeAsyncIterator() -> FileChunkIterator {
        FileChunkIterator(wrapping: self.stream.makeAsyncIterator())
    }

    public struct FileChunkIterator: AsyncIteratorProtocol {
        private var iterator: BufferedOrAnyStream<ByteBuffer, FileChunkProducer>.AsyncIterator

        fileprivate init(wrapping iterator: BufferedOrAnyStream<ByteBuffer, FileChunkProducer>.AsyncIterator) {
            self.iterator = iterator
        }

        public mutating func next() async throws -> ByteBuffer? {
            try await self.iterator.next()
        }
    }
}

@available(*, unavailable)
extension FileChunks.FileChunkIterator: Sendable {}

// MARK: - Internal

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private typealias FileChunkSequenceProducer = NIOThrowingAsyncSequenceProducer<
    ByteBuffer, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, FileChunkProducer
>

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOThrowingAsyncSequenceProducer
where
    Element == ByteBuffer,
    Failure == Error,
    Strategy == NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
    Delegate == FileChunkProducer
{
    static func makeFileChunksStream(
        of: Element.Type = Element.self,
        handle: SystemFileHandle,
        chunkLength: Int64,
        range: Range<Int64>,
        lowWatermark: Int,
        highWatermark: Int
    ) -> FileChunkSequenceProducer {

        let producer = FileChunkProducer(
            range: range,
            handle: handle,
            chunkLength: chunkLength
        )

        let nioThrowingAsyncSequence = NIOThrowingAsyncSequenceProducer.makeSequence(
            elementType: ByteBuffer.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: lowWatermark,
                highWatermark: highWatermark
            ),
            finishOnDeinit: false,
            delegate: producer
        )

        producer.setSource(nioThrowingAsyncSequence.source)

        return nioThrowingAsyncSequence.sequence
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private final class FileChunkProducer: NIOAsyncSequenceProducerDelegate, Sendable {
    let state: NIOLockedValueBox<ProducerState>

    let path: FilePath
    let chunkLength: Int64

    init(range: Range<Int64>, handle: SystemFileHandle, chunkLength: Int64) {
        self.state = NIOLockedValueBox(ProducerState(handle: handle, range: range))
        self.path = handle.path
        self.chunkLength = chunkLength
    }

    /// sets the source within the producer state
    func setSource(_ source: FileChunkSequenceProducer.Source) {
        self.state.withLockedValue { state in
            switch state.state {
            case .producing, .pausedProducing:
                state.source = source
            case .done(let emptyRange):
                if emptyRange {
                    source.finish()
                }
            }
        }
    }

    func clearSource() {
        self.state.withLockedValue { state in
            state.source = nil
        }
    }

    /// The 'entry point' for producing elements.
    ///
    /// Calling this function will start producing file chunks asynchronously by dispatching work
    /// to the IO executor and feeding the result back to the stream source. On yielding to the
    /// source it will either produce more or be scheduled to produce more. Stopping production
    /// is signaled via the stream's 'onTermination' handler.
    func produceMore() {
        let threadPool = self.state.withLockedValue { state in
            state.activeThreadPool()
        }
        // No thread pool means we're done.
        guard let threadPool = threadPool else { return }

        threadPool.submit { workItemState in
            // update state to reflect that we have been requested to perform a read
            // the read may be performed immediately, queued to be performed later or ignored
            let requestedReadAction = self.state.withLockedValue { state in
                state.requestedProduceMore()
            }

            switch requestedReadAction {
            case .performRead:
                let result: Result<ByteBuffer, Error>
                switch workItemState {
                case .active:
                    result = Result { try self.readNextChunk() }
                case .cancelled:
                    result = .failure(CancellationError())
                }

                switch result {
                case let .success(bytes):
                    self.didReadNextChunk(bytes)
                case let .failure(error):
                    // Failed to read: update our state then notify the stream so consumers receive the
                    // error.
                    let source = self.state.withLockedValue { state in
                        state.done()
                        return state.source
                    }
                    source?.finish(error)
                    self.clearSource()
                }

            case .stop:
                return
            }

            let performedReadAction = self.state.withLockedValue { state in
                state.performedProduceMore()
            }

            switch performedReadAction {
            case .readMore:
                self.produceMore()
            case .stop:
                return
            }

        }
    }

    private func readNextChunk() throws -> ByteBuffer {
        try self.state.withLockedValue { state in
            state.fileReadingState()
        }.flatMap {
            if let (descriptor, range, readMode) = $0 {
                // The upper bound of the range is the number of bytes which may still be read; never
                // read more than that, regardless of how the file is being read.
                let remainingBytes = range.upperBound - range.lowerBound
                let clampedLength = min(self.chunkLength, remainingBytes)
                switch readMode {
                case .positional:
                    return descriptor.readChunk(
                        fromAbsoluteOffset: range.lowerBound,
                        length: clampedLength
                    ).flatMapError { error in
                        // Unseekable files (pipes, FIFOs, sockets) can only be read sequentially,
                        // which is only possible when starting from the beginning of the file.
                        if range.lowerBound == 0, let errno = error as? Errno,
                            errno == .illegalSeek || errno == .noSuchAddressOrDevice
                        {
                            return self.readNextChunkSequentiallyFromNowOn(length: clampedLength)
                        } else {
                            return .failure(
                                .read(usingSyscall: .pread, error: error, path: self.path, location: .here())
                            )
                        }
                    }
                case .sequential:
                    return descriptor.readChunk(length: clampedLength).mapError { error in
                        .read(usingSyscall: .read, error: error, path: self.path, location: .here())
                    }
                }
            } else {
                // nil means done: return empty to indicate the stream should finish.
                return .success(ByteBuffer())
            }
        }.get()
    }

    private func readNextChunkSequentiallyFromNowOn(length: Int64) -> Result<ByteBuffer, FileSystemError> {
        // The handle may have been closed, or the stream terminated, while the first read was in
        // progress, so get the descriptor again.
        self.state.withLockedValue { state in
            state.switchToSequentialReads()
            return state.fileReadingState()
        }.flatMap {
            if let (descriptor, _, _) = $0 {
                return descriptor.readChunk(length: length).mapError { error in
                    .read(usingSyscall: .read, error: error, path: self.path, location: .here())
                }
            } else {
                // nil means done: don't start a read which might block, there's nobody to read
                // for. Return empty to indicate the stream should finish.
                return .success(ByteBuffer())
            }
        }
    }

    private func didReadNextChunk(_ buffer: ByteBuffer) {
        assert(buffer.readableBytes <= self.chunkLength)

        let (source, wasDone, isDone): (FileChunkSequenceProducer.Source?, Bool, Bool) = self.state
            .withLockedValue { state in
                // The stream may have been terminated while the read was in progress.
                let wasDone = state.isDone

                state.didReadBytes(buffer.readableBytes)

                // Reading no bytes means the end of the file has been reached. Reading fewer bytes
                // than requested does not: for a pipe or FIFO it just means that fewer bytes were
                // available. If the requested range has been exhausted then 'didReadBytes' has
                // already marked the state as done.
                if buffer.readableBytes == 0 {
                    state.done()
                }

                return (state.source, wasDone, state.isDone)
            }

        guard let source else {
            return
        }

        // Nothing is wanted any more: don't yield to a source which is finished.
        if wasDone {
            source.finish()
            self.clearSource()
            return
        }

        // Never yield an empty chunk: it isn't meaningful to consumers.
        let yieldResult: FileChunkSequenceProducer.Source.YieldResult?
        if buffer.readableBytes > 0 {
            yieldResult = source.yield(contentsOf: CollectionOfOne(buffer))
        } else {
            yieldResult = nil
        }

        // Finish only after yielding the final chunk, and never yield to a finished source.
        if isDone {
            source.finish()
            self.clearSource()
            return
        }

        switch yieldResult {
        case .produceMore, .none:
            ()
        case .stopProducing:
            self.state.withLockedValue { state in state.pauseProducing() }
        case .dropped:
            // The source is finished; mark ourselves as done.
            self.state.withLockedValue { state in state.done() }
        }
    }

    func didTerminate() {
        self.state.withLockedValue { state in
            state.done()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private struct ProducerState: Sendable {
    fileprivate struct Producing {
        /// Possible states for activity relating to performing a read from disk
        internal enum ActivityState {
            /// The producer is not currently performing a read from disk
            case inactive
            /// The producer is in the critical section for reading from disk
            case active
            /// The producer is in the critical section for reading from disk and a further read has been requested.
            /// This can happen e.g. if a sequence indicates that production should be paused then unpauses and calls
            /// back into the code before the initial read block has exited.
            case activeAndQueued
        }

        /// How the file is being read.
        internal enum ReadMode {
            /// Read from the absolute offset given by the lower bound of the range (with `pread`).
            /// This is how every file is read to begin with.
            case positional
            /// Read from the file's current position (with `read`). The file turned out to be
            /// unseekable (a pipe, FIFO or socket) so the lower bound of the range is only used to
            /// track how many bytes have been read.
            case sequential
        }

        /// The handle to read from.
        var handle: SystemFileHandle.SendableView

        /// The range containing the offsets to read from and up to (exclusive).
        /// The lower bound should be updated after each successful read, in either read mode.
        /// The upper bound should be used to check if producer should stop; for a sequential read
        /// it's the budget of bytes which may be read.
        /// Reading the entire file is represented by `0..<Int64.max`.
        var range: Range<Int64>

        /// How the file is being read.
        var readMode: ReadMode = .positional

        /// Keep track of whether or not we are currently actively engaged in a read
        /// to protect against re-entrant behavior.
        var activityState: ActivityState = .inactive
    }

    internal enum State {
        /// Can potentially produce values (if the handle is not closed).
        case producing(Producing)
        /// Backpressure policy means that we should stop producing new values for now
        case pausedProducing(Producing)
        /// Done producing values either by reaching EOF, some error or the stream terminating.
        case done(emptyRange: Bool)
    }

    internal var state: State

    /// The route via which file chunks are yielded,
    /// the sourcing end of the `FileChunkSequenceProducer`
    internal var source: FileChunkSequenceProducer.Source?

    init(handle: SystemFileHandle, range: Range<Int64>) {
        if range.isEmpty {
            self.state = .done(emptyRange: true)
        } else {
            self.state = .producing(.init(handle: handle.sendableView, range: range))
        }
    }

    /// Actions which may be taken after 'produce more' is requested.
    ///
    /// Either perform the read immediately or (optionally queue the read then) stop.
    internal enum RequestedProduceMoreAction {
        case performRead
        case stop
    }

    /// Update state to reflect that 'produce more' has been requested.
    mutating func requestedProduceMore() -> RequestedProduceMoreAction {
        switch self.state {
        case .producing(var producingState):
            switch producingState.activityState {
            case .inactive:
                producingState.activityState = .active
                self.state = .producing(producingState)
                return .performRead
            case .active:
                producingState.activityState = .activeAndQueued
                self.state = .producing(producingState)
                return .stop
            case .activeAndQueued:
                return .stop
            }

        case .pausedProducing(var producingState):
            switch producingState.activityState {
            case .inactive:
                producingState.activityState = .active
                self.state = .producing(producingState)
                return .performRead
            case .active:
                producingState.activityState = .activeAndQueued
                self.state = .pausedProducing(producingState)
                return .stop
            case .activeAndQueued:
                return .stop
            }

        case .done:
            return .stop
        }
    }

    /// Actions which may be taken after a more data is produced.
    ///
    /// Either go on to read more or stop.
    internal enum PerformedProduceMoreAction {
        case readMore
        case stop
    }

    /// Update state to reflect that a more data has been produced.
    mutating func performedProduceMore() -> PerformedProduceMoreAction {
        switch self.state {
        case .producing(var producingState):
            let oldActivityState = producingState.activityState

            producingState.activityState = .inactive
            self.state = .producing(producingState)

            switch oldActivityState {
            case .inactive:
                preconditionFailure()
            case .active, .activeAndQueued:
                return .readMore
            }

        case .pausedProducing(var producingState):
            let oldActivityState = producingState.activityState

            producingState.activityState = .inactive
            self.state = .pausedProducing(producingState)

            switch oldActivityState {
            case .inactive:
                preconditionFailure()
            case .active:
                return .stop
            case .activeAndQueued:
                return .readMore
            }

        case .done:
            return .stop
        }
    }

    mutating func activeThreadPool() -> NIOThreadPool? {
        switch self.state {
        case .producing(let producingState), .pausedProducing(let producingState):
            return producingState.handle.threadPool
        case .done:
            return nil
        }
    }

    mutating func fileReadingState() -> Result<
        (FileDescriptor, Range<Int64>, Producing.ReadMode)?, FileSystemError
    > {
        switch self.state {
        case .producing(let producingState), .pausedProducing(let producingState):
            if let descriptor = producingState.handle.descriptorIfAvailable() {
                return .success((descriptor, producingState.range, producingState.readMode))
            } else {
                let error = FileSystemError(
                    code: .closed,
                    message: "Cannot read from closed file ('\(producingState.handle.path)').",
                    cause: nil,
                    location: .here()
                )
                return .failure(error)
            }
        case .done:
            return .success(nil)
        }
    }

    mutating func didReadBytes(_ count: Int) {
        switch self.state {
        case var .producing(state):
            switch state.updateRangeWithReadBytes(count) {
            case .moreToRead:
                self.state = .producing(state)
            case .cannotReadMore:
                self.state = .done(emptyRange: false)
            }
        case var .pausedProducing(state):
            switch state.updateRangeWithReadBytes(count) {
            case .moreToRead:
                self.state = .pausedProducing(state)
            case .cannotReadMore:
                self.state = .done(emptyRange: false)
            }
        case .done:
            ()
        }
    }

    /// Reads the rest of the file from its current position instead of from absolute offsets.
    mutating func switchToSequentialReads() {
        switch self.state {
        case .producing(var state):
            state.readMode = .sequential
            self.state = .producing(state)
        case .pausedProducing(var state):
            state.readMode = .sequential
            self.state = .pausedProducing(state)
        case .done:
            ()
        }
    }

    mutating func pauseProducing() {
        switch self.state {
        case .producing(let state):
            self.state = .pausedProducing(state)
        case .pausedProducing, .done:
            ()
        }
    }

    mutating func done() {
        self.state = .done(emptyRange: false)
    }

    /// Whether the producer has finished producing values.
    var isDone: Bool {
        switch self.state {
        case .done:
            return true
        case .producing, .pausedProducing:
            return false
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension ProducerState.Producing {
    internal enum RangeUpdateOutcome {
        case moreToRead
        case cannotReadMore
    }

    /// Updates the range (the offsets to read from and up to) to reflect the number of bytes which have been read.
    /// - Parameter count: The number of bytes which have been read.
    /// - Returns: Returns `.moreToRead` if there are no remaining bytes to read, `.cannotReadMore` otherwise.
    mutating func updateRangeWithReadBytes(_ count: Int) -> RangeUpdateOutcome {
        let newLowerBound = self.range.lowerBound + Int64(count)

        // we have run out of bytes to read, we are done
        if newLowerBound >= self.range.upperBound {
            self.range = self.range.upperBound..<self.range.upperBound
            return .cannotReadMore
        }

        // update range, we are not done
        self.range = newLowerBound..<self.range.upperBound
        return .moreToRead
    }
}
