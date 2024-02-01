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
@preconcurrency import SystemPackage

/// An `AsyncSequence` of ordered chunks read from a file.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct FileChunks: AsyncSequence {
    enum ChunkRange {
        case entireFile
        case partial(Range<Int64>)
    }

    public typealias Element = ByteBuffer

    /// The underlying buffered stream.
    private let stream: BufferedOrAnyStream<ByteBuffer>

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
        let stream = BufferedStream.makeFileChunksStream(
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
        return FileChunkIterator(wrapping: self.stream.makeAsyncIterator())
    }

    public struct FileChunkIterator: AsyncIteratorProtocol {
        private var iterator: BufferedOrAnyStream<ByteBuffer>.AsyncIterator

        fileprivate init(wrapping iterator: BufferedOrAnyStream<ByteBuffer>.AsyncIterator) {
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
extension BufferedStream where Element == ByteBuffer {
    static func makeFileChunksStream(
        of: Element.Type = Element.self,
        handle: SystemFileHandle,
        chunkLength: Int64,
        range: FileChunks.ChunkRange,
        lowWatermark: Int,
        highWatermark: Int
    ) -> BufferedStream<ByteBuffer> {
        let state: ProducerState
        switch range {
        case .entireFile:
            state = ProducerState(handle: handle, range: nil)
        case .partial(let partialRange):
            state = ProducerState(handle: handle, range: partialRange)
        }
        let protectedState = NIOLockedValueBox(state)

        var (stream, source) = BufferedStream.makeStream(
            of: ByteBuffer.self,
            backPressureStrategy: .watermark(low: lowWatermark, high: highWatermark)
        )

        source.onTermination = {
            protectedState.withLockedValue { state in
                state.done()
            }
        }

        // Start producing immediately.
        let producer = FileChunkProducer(
            state: protectedState,
            source: source,
            path: handle.path,
            length: chunkLength
        )
        producer.produceMore()

        return stream
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private struct FileChunkProducer: Sendable {
    let state: NIOLockedValueBox<ProducerState>
    let source: BufferedStream<ByteBuffer>.Source
    let path: FilePath
    let length: Int64

    /// The 'entry point' for producing elements.
    ///
    /// Calling this function will start producing file chunks asynchronously by dispatching work
    /// to the IO executor and feeding the result back to the stream source. On yielding to the
    /// source it will either produce more or be scheduled to produce more. Stopping production
    /// is signalled via the stream's 'onTermination' handler.
    func produceMore() {
        let executor = self.state.withLockedValue { state in
            state.shouldProduceMore()
        }

        // No executor means we're done.
        guard let executor = executor else { return }

        executor.execute {
            try self.readNextChunk()
        } onCompletion: { result in
            self.onReadNextChunkResult(result)
        }
    }

    private func readNextChunk() throws -> ByteBuffer {
        return try self.state.withLockedValue { state in
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
            self.state.withLockedValue { state in state.done() }
            self.source.finish(throwing: error)
        }
    }

    private func onReadNextChunk(_ bytes: ByteBuffer) {
        // Reading short means EOF.
        let readEOF = bytes.readableBytes < self.length
        assert(bytes.readableBytes <= self.length)

        self.state.withLockedValue { state in
            if readEOF {
                state.readEnd()
            } else {
                state.readBytes(bytes.readableBytes)
            }
        }

        // No bytes were read: this must be the end as length is required to be greater than zero.
        if bytes.readableBytes == 0 {
            assert(readEOF, "read zero bytes but did not read EOF")
            self.source.finish(throwing: nil)
            return
        }

        // Bytes were produced: yield them and maybe produce more.
        do {
            let writeResult = try self.source.write(contentsOf: CollectionOfOne(bytes))
            // Exit early if EOF was read; no use in trying to produce more.
            if readEOF {
                self.source.finish(throwing: nil)
                return
            }

            switch writeResult {
            case .produceMore:
                self.produceMore()
            case let .enqueueCallback(token):
                self.source.enqueueCallback(callbackToken: token) {
                    switch $0 {
                    case .success:
                        self.produceMore()
                    case .failure:
                        // The source is finished; mark ourselves as done.
                        self.state.withLockedValue { state in state.done() }
                    }
                }
            }
        } catch {
            // Failure to write means the source is already done, that's okay we just need to
            // update our state and stop producing.
            self.state.withLockedValue { state in state.done() }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private struct ProducerState: Sendable {
    private struct Producing {
        /// The handle to read from.
        var handle: SystemFileHandle.SendableView

        /// An optional range containing the offsets to read from and up to (exclusive)
        /// The lower bound should be updated after each successful read.
        /// The upper bound should be used to check if producer should stop.
        /// If no range is present, then read entire file.
        var range: Range<Int64>?
    }

    private enum State {
        /// Can potentially produce values (if the handle is not closed).
        case producing(Producing)
        /// Done producing values either by reaching EOF, some error or the stream terminating.
        case done
    }

    private var state: State

    init(handle: SystemFileHandle, range: Range<Int64>?) {
        if let range, range.isEmpty {
            self.state = .done
        } else {
            self.state = .producing(.init(handle: handle.sendableView, range: range))
        }
    }

    mutating func shouldProduceMore() -> IOExecutor? {
        switch self.state {
        case let .producing(state):
            return state.handle.executor
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
        case .done:
            return .success(nil)
        }
    }

    mutating func readBytes(_ count: Int) {
        switch self.state {
        case var .producing(state):
            if let currentRange = state.range {
                let newRange = (currentRange.lowerBound + Int64(count))..<currentRange.upperBound
                if newRange.lowerBound >= newRange.upperBound {
                    assert(newRange.lowerBound == newRange.upperBound)
                    self.state = .done
                } else {
                    state.range = newRange
                    self.state = .producing(state)
                }
            } else {
                if count == 0 {
                    self.state = .done
                }
            }
        case .done:
            ()
        }
    }

    mutating func readEnd() {
        switch self.state {
        case .producing:
            self.state = .done
        case .done:
            ()
        }
    }

    mutating func done() {
        self.state = .done
    }
}

#endif
