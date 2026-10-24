//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Element == ByteBuffer {
    /// Decode the `AsyncSequence<ByteBuffer>` into a sequence of `Element`s,
    /// using the `Decoder`, where `Decoder.InboundOut` matches `Element`.
    ///
    /// Usage:
    /// ```swift
    /// let myDecoder = MyNIOSingleStepByteToMessageDecoder()
    /// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
    /// let decodedSequence = baseSequence.decode(using: myDecoder)
    ///
    /// for try await element in decodedSequence {
    ///     print("Decoded an element!", element)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - decoder: The `Decoder` to use to decode the ``ByteBuffer``s.
    ///   - maximumBufferSize: The maximum number of bytes to aggregate in-memory.
    ///     An error will be thrown if after decoding an element there is more aggregated data than this amount.
    /// - Returns: A ``NIODecodedAsyncSequence`` that decodes the ``ByteBuffer``s into a sequence of `Element`s.
    @inlinable
    public func decode<Decoder: NIOSingleStepByteToMessageDecoder>(
        using decoder: Decoder,
        maximumBufferSize: Int? = nil
    ) -> NIODecodedAsyncSequence<Self, Decoder> {
        NIODecodedAsyncSequence(
            asyncSequence: self,
            decoder: decoder,
            maximumBufferSize: maximumBufferSize
        )
    }
}

/// A type that decodes an `AsyncSequence<ByteBuffer>` into a sequence of ``Element``s,
/// using the `Decoder`, where `Decoder.InboundOut` matches ``Element``.
///
/// Use `AsyncSequence/decode(using:maximumBufferSize:)` to create a ``NIODecodedAsyncSequence``.
///
/// Usage:
/// ```swift
/// let myDecoder = MyNIOSingleStepByteToMessageDecoder()
/// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
/// let decodedSequence = baseSequence.decode(using: myDecoder)
///
/// for try await element in decodedSequence {
///     print("Decoded an element!", element)
/// }
/// ```
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct NIODecodedAsyncSequence<
    Base: AsyncSequence,
    Decoder: NIOSingleStepByteToMessageDecoder
> where Base.Element == ByteBuffer {
    @usableFromInline
    var asyncSequence: Base
    @usableFromInline
    var decoder: Decoder
    @usableFromInline
    var maximumBufferSize: Int?

    @inlinable
    init(asyncSequence: Base, decoder: Decoder, maximumBufferSize: Int? = nil) {
        self.asyncSequence = asyncSequence
        self.decoder = decoder
        self.maximumBufferSize = maximumBufferSize
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIODecodedAsyncSequence: AsyncSequence {
    public typealias Element = Decoder.InboundOut

    /// Create an ``AsyncIterator`` for this ``NIODecodedAsyncSequence``.
    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self)
    }

    /// An ``AsyncIterator`` over a ``NIODecodedAsyncSequence``.
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        enum State: Sendable {
            case canReadFromBaseIterator
            case baseIteratorIsExhausted
            case finishedDecoding
        }

        @usableFromInline
        var baseIterator: Base.AsyncIterator
        @usableFromInline
        var processor: NIOSingleStepByteToMessageProcessor<Decoder>
        @usableFromInline
        var state: State

        @inlinable
        init(base: NIODecodedAsyncSequence) {
            self.baseIterator = base.asyncSequence.makeAsyncIterator()
            self.processor = NIOSingleStepByteToMessageProcessor(
                base.decoder,
                maximumBufferSize: base.maximumBufferSize
            )
            self.state = .canReadFromBaseIterator
        }

        /// Retrieve the next element from the ``NIODecodedAsyncSequence``.
        ///
        /// The same as `next(isolation:)` but not isolated to an actor, which allows
        /// for less availability restrictions.
        @inlinable
        public mutating func next() async throws -> Element? {
            while true {
                switch self.state {
                case .finishedDecoding:
                    return nil
                case .canReadFromBaseIterator:
                    let (decoded, ended) = try self.processor.decodeNext(
                        decodeMode: .normal,
                        seenEOF: false
                    )

                    // We expect `decodeNext()` to only return `ended == true` only if we've notified it
                    // that we've read the last chunk from the buffer, using `decodeMode: .last`.
                    assert(!ended)

                    if let decoded {
                        return decoded
                    }

                    // Read more data into the buffer so we can decode more messages
                    guard let nextBuffer = try await self.baseIterator.next() else {
                        // Ran out of data to read.
                        self.state = .baseIteratorIsExhausted
                        continue
                    }
                    self.processor.append(nextBuffer)
                case .baseIteratorIsExhausted:
                    let (decoded, ended) = try self.processor.decodeNext(
                        decodeMode: .last,
                        seenEOF: true
                    )

                    if ended {
                        self.state = .finishedDecoding
                    }

                    return decoded
                }
            }

            fatalError("Unreachable code")
        }

        /// Retrieve the next element from the ``NIODecodedAsyncSequence``.
        ///
        /// The same as `next()` but isolated to an actor.
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        @inlinable
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Element? {
            while true {
                switch self.state {
                case .finishedDecoding:
                    return nil
                case .canReadFromBaseIterator:
                    let (decoded, ended) = try self.processor.decodeNext(
                        decodeMode: .normal,
                        seenEOF: false
                    )

                    // We expect `decodeNext()` to only return `ended == true` only if we've notified it
                    // that we've read the last chunk from the buffer, using `decodeMode: .last`.
                    assert(!ended)

                    if let decoded {
                        return decoded
                    }

                    // Read more data into the buffer so we can decode more messages
                    guard let nextBuffer = try await self.baseIterator.next(isolation: actor) else {
                        // Ran out of data to read.
                        self.state = .baseIteratorIsExhausted
                        continue
                    }
                    self.processor.append(nextBuffer)
                case .baseIteratorIsExhausted:
                    let (decoded, ended) = try self.processor.decodeNext(
                        decodeMode: .last,
                        seenEOF: true
                    )

                    if ended {
                        self.state = .finishedDecoding
                    }

                    return decoded
                }
            }

            fatalError("Unreachable code")
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIODecodedAsyncSequence: Sendable where Base: Sendable, Decoder: Sendable {}

@available(*, unavailable)
extension NIODecodedAsyncSequence.AsyncIterator: Sendable {}
