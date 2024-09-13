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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@preconcurrency import SystemPackage

/// An `AsyncSequence` of ordered chunks read from a file.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct FileChunks: AsyncSequence, Sendable {
    enum ChunkRange {
        case entireFile
        case partial(Range<Int64>)
    }

    public typealias Element = ByteBuffer

    /// The underlying buffered stream.
    private let stream: BufferedOrAnyStream<ByteBuffer, FileChunkProducer>

    /// Create a ``FileChunks`` sequence backed by wrapping an `AsyncSequence`.
    public init<S: AsyncSequence & Sendable>(wrapping sequence: S) where S.Element == ByteBuffer {
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
            length: chunkLength
        )

        let nioThrowingAsyncSequence = NIOThrowingAsyncSequenceProducer.makeSequence(
            elementType: ByteBuffer.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 4,
                highWatermark: 8
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
    let length: Int64

    init(range: FileChunks.ChunkRange, handle: SystemFileHandle, length: Int64) {
        let state: ProducerState
        switch range {
        case .entireFile:
            state = .init(handle: handle, range: nil)
        case .partial(let partialRange):
            state = .init(handle: handle, range: partialRange)
        }

        self.state = NIOLockedValueBox(state)
        self.path = handle.path
        self.length = length
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
            state.shouldProduceMore()
        }

        // No executor means we're done.
        guard let threadPool = threadPool else { return }

        threadPool.submit {
            let result: Result<ByteBuffer, Error>
            switch $0 {
            case .active:
                result = Result { try self.readNextChunk() }
            case .cancelled:
                result = .failure(CancellationError())
            }
            self.onReadNextChunkResult(result)
        }
    }

    private func readNextChunk() throws -> ByteBuffer {
        try self.state.withLockedValue { state in
            state.produceMore()
        }.flatMap {
            if let (descriptor, range) = $0 {
                if let range {
                    let remainingBytes = range.upperBound - range.lowerBound
                    let clampedLength = min(self.length, remainingBytes)
                    return descriptor.readChunk(
                        fromAbsoluteOffset: range.lowerBound,
                        length: clampedLength
                    ).mapError { error in
                        .read(usingSyscall: .pread, error: error, path: self.path, location: .here())
                    }
                } else {
                    return descriptor.readChunk(length: self.length).mapError { error in
                        .read(usingSyscall: .read, error: error, path: self.path, location: .here())
                    }
                }
            } else {
                // nil means done: return empty to indicate the stream should finish.
                return .success(ByteBuffer())
            }
        }.get()
    }

    private func onReadNextChunkResult(_ result: Result<ByteBuffer, Error>) {
        switch result {
        case let .success(bytes):
            self.onReadNextChunk(bytes)
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
    }

    private func onReadNextChunk(_ buffer: ByteBuffer) {
        // Reading short means EOF.
        let readEOF = buffer.readableBytes < self.length
        assert(buffer.readableBytes <= self.length)

        let source = self.state.withLockedValue { state in
            if readEOF {
                state.didReadEnd()
            } else {
                state.didReadBytes(buffer.readableBytes)
            }
            return state.source
        }

        guard let source else {
            assertionFailure("unexpectedly missing source")
            return
        }

        // No bytes were read: this must be the end as length is required to be greater than zero.
        if buffer.readableBytes == 0 {
            assert(readEOF, "read zero bytes but did not read EOF")
            source.finish()
            self.clearSource()
            return
        }

        // Bytes were produced: yield them and maybe produce more.
        let writeResult = source.yield(contentsOf: CollectionOfOne(buffer))

        // Exit early if EOF was read; no use in trying to produce more.
        if readEOF {
            source.finish()
            self.clearSource()
            return
        }

        switch writeResult {
        case .produceMore:
            self.produceMore()
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
        /// The handle to read from.
        var handle: SystemFileHandle.SendableView

        /// An optional range containing the offsets to read from and up to (exclusive)
        /// The lower bound should be updated after each successful read.
        /// The upper bound should be used to check if producer should stop.
        /// If no range is present, then read entire file.
        var range: Range<Int64>?
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

    mutating func shouldProduceMore() -> NIOThreadPool? {
        switch self.state {
        case let .producing(state):
            return state.handle.threadPool
        case .pausedProducing:
            return nil
        case .done:
            return nil
        }
    }

    mutating func produceMore() -> Result<(FileDescriptor, Range<Int64>?)?, FileSystemError> {
        switch self.state {
        case let .producing(state):
            if let descriptor = state.handle.descriptorIfAvailable() {
                return .success((descriptor, state.range))
            } else {
                let error = FileSystemError(
                    code: .closed,
                    message: "Cannot read from closed file ('\(state.handle.path)').",
                    cause: nil,
                    location: .here()
                )
                return .failure(error)
            }
        case .pausedProducing:
            return .success(nil)
        case .done:
            return .success(nil)
        }
    }

    mutating func didReadBytes(_ count: Int) {
        switch self.state {
        case var .producing(state):
            if state.didReadBytes(count) {
                self.state = .done(emptyRange: false)
            } else {
                self.state = .producing(state)
            }
        case var .pausedProducing(state):
            if state.didReadBytes(count) {
                self.state = .done(emptyRange: false)
            } else {
                self.state = .pausedProducing(state)
            }
        case .done:
            ()
        }
    }

    mutating func didReadEnd() {
        switch self.state {
        case .pausedProducing, .producing:
            self.state = .done(emptyRange: false)
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
    /// Updates the range (the offsets to read from and up to) to reflect the number of bytes which have been read.
    /// - Parameter count: The number of bytes which have been read.
    /// - Returns: Returns `True` if there are no remaining bytes to read, `False` otherwise.
    mutating func didReadBytes(_ count: Int) -> Bool {
        guard let currentRange = self.range else {
            // if we read 0 bytes we are done
            return count == 0
        }

        let newLowerBound = currentRange.lowerBound + Int64(count)

        // we have run out of bytes to read, we are done
        if newLowerBound >= currentRange.upperBound {
            self.range = currentRange.upperBound..<currentRange.upperBound
            return true
        }

        // update range, we are not done
        self.range = newLowerBound..<currentRange.upperBound
        return false
    }
}
#endif
