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
    enum ChunkRange {
        case entireFile
        case partial(Range<Int64>)
    }

    public typealias Element = ByteBuffer

    /// The buffered stream.
    private let stream: BufferedOrAnyStream<ByteBuffer, FileChunkProducer>

    /// Create a ``FileChunks`` sequence backed by wrapping an `AsyncSequence`.
    @preconcurrency
    public init<S: AsyncSequence & Sendable>(wrapping sequence: S)
    where S.Element == ByteBuffer, S.AsyncIterator: _NIOFileSystemSendableMetatype {
        self.stream = BufferedOrAnyStream(wrapping: sequence)
    }

    internal init(
        handle: SystemFileHandle,
        chunkLength: ByteCount,
        range: Range<Int64>
    ) {
        let chunkRange: ChunkRange
        if range.lowerBound == 0, range.upperBound == .max {
            chunkRange = .entireFile
        } else {
            chunkRange = .partial(range)
        }

        // TODO: choose reasonable watermarks; this should likely be at least somewhat dependent
        // on the chunk size.
        let stream = NIOThrowingAsyncSequenceProducer.makeFileChunksStream(
            of: ByteBuffer.self,
            handle: handle,
            chunkLength: chunkLength.bytes,
            range: chunkRange,
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
        range: FileChunks.ChunkRange,
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

    init(range: FileChunks.ChunkRange, handle: SystemFileHandle, chunkLength: Int64) {
        let state: ProducerState
        switch range {
        case .entireFile:
            state = .init(handle: handle, range: nil)
        case .partial(let partialRange):
            state = .init(handle: handle, range: partialRange)
        }

        self.state = NIOLockedValueBox(state)
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
            if let (descriptor, range) = $0 {
                if let range {
                    let remainingBytes = range.upperBound - range.lowerBound
                    let clampedLength = min(self.chunkLength, remainingBytes)
                    return descriptor.readChunk(
                        fromAbsoluteOffset: range.lowerBound,
                        length: clampedLength
                    ).mapError { error in
                        .read(usingSyscall: .pread, error: error, path: self.path, location: .here())
                    }
                } else {
                    return descriptor.readChunk(length: self.chunkLength).mapError { error in
                        .read(usingSyscall: .read, error: error, path: self.path, location: .here())
                    }
                }
            } else {
                // nil means done: return empty to indicate the stream should finish.
                return .success(ByteBuffer())
            }
        }.get()
    }

    private func didReadNextChunk(_ buffer: ByteBuffer) {
        let chunkLength = self.chunkLength
        assert(buffer.readableBytes <= chunkLength)

        let (source, initialState): (FileChunkSequenceProducer.Source?, ProducerState.State) = self.state
            .withLockedValue { state in
                state.didReadBytes(buffer.readableBytes)

                // finishing short indicates the file is done
                if buffer.readableBytes < chunkLength {
                    state.state = .done(emptyRange: false)
                }
                return (state.source, state.state)
            }

        guard let source else {
            return
        }

        // No bytes were produced, nothing more to do.
        if buffer.readableBytes == 0 {
            source.finish()
            self.clearSource()
        }

        // Yield bytes and maybe produce more.
        let yieldResult = source.yield(contentsOf: CollectionOfOne(buffer))

        switch initialState {
        case .done:
            source.finish()
            self.clearSource()
            return
        case .producing, .pausedProducing:
            ()
        }

        switch yieldResult {
        case .produceMore:
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

        /// The handle to read from.
        var handle: SystemFileHandle.SendableView

        /// An optional range containing the offsets to read from and up to (exclusive)
        /// The lower bound should be updated after each successful read.
        /// The upper bound should be used to check if producer should stop.
        /// If no range is present, then read entire file.
        var range: Range<Int64>?

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

    init(handle: SystemFileHandle, range: Range<Int64>?) {
        if let range, range.isEmpty {
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

    mutating func fileReadingState() -> Result<(FileDescriptor, Range<Int64>?)?, FileSystemError> {
        switch self.state {
        case .producing(let producingState), .pausedProducing(let producingState):
            if let descriptor = producingState.handle.descriptorIfAvailable() {
                return .success((descriptor, producingState.range))
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
        guard let currentRange = self.range else {
            // we are reading the whole file, just keep going
            return .moreToRead
        }

        let newLowerBound = currentRange.lowerBound + Int64(count)

        // we have run out of bytes to read, we are done
        if newLowerBound >= currentRange.upperBound {
            self.range = currentRange.upperBound..<currentRange.upperBound
            return .cannotReadMore
        }

        // update range, we are not done
        self.range = newLowerBound..<currentRange.upperBound
        return .moreToRead
    }
}
