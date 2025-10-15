// MARK: NIODecodedAsyncSequence

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Element == ByteBuffer {
    /// Decode the `AsyncSequence<ByteBuffer>` into a sequence of ``Element``s,
    /// using the ``Decoder``, where ``Decoder.InboundOut`` matches ``Element``.
    ///
    /// - Parameters:
    ///   - decoder: The ``Decoder`` to use to decode the ``ByteBuffer``s.
    ///   - maximumBufferSize: The maximum number of bytes to aggregate in-memory.
    ///     An error will be thrown if after decoding an element there is more aggregated data than this amount.
    /// - Returns: A ``NIODecodedAsyncSequence`` that decodes the ``ByteBuffer``s into a sequence of ``Element``s.
    @inlinable
    public func decode<Decoder: NIOSingleStepByteToMessageDecoder, Decoded>(
        using decoder: Decoder,
        maximumBufferSize: Int? = nil
    ) -> NIODecodedAsyncSequence<Self, Decoder, Decoded> where Decoder.InboundOut == Decoded {
        NIODecodedAsyncSequence(
            asyncSequence: self,
            decoder: decoder,
            maximumBufferSize: maximumBufferSize
        )
    }
}

/// A type that decodes an `AsyncSequence<ByteBuffer>` into a sequence of ``Element``s,
/// using the ``Decoder``, where ``Decoder.InboundOut`` matches ``Element``.
///
/// Use ``AsyncSequence/decode(using:maximumBufferSize:)`` to create a ``NIODecodedAsyncSequence``.
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
    Decoder: NIOSingleStepByteToMessageDecoder,
    Element
> where Base.Element == ByteBuffer, Decoder.InboundOut == Element {
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
    /// Create an ``AsyncIterator`` for this ``NIODecodedAsyncSequence``.
    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self)
    }

    /// An ``AsyncIterator`` over a ``NIODecodedAsyncSequence``.
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        enum State: Sendable {
            case readingFromBuffer
            case readLastChunkFromBuffer
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
            self.state = .readingFromBuffer
        }

        /// Decode from the existing buffer of data, if possible.
        @inlinable
        mutating func decodeFromBuffer() throws -> Element? {
            let readLastChunkFromBuffer =
                switch self.state {
                case .readLastChunkFromBuffer:
                    true
                case .finishedDecoding, .readingFromBuffer:
                    false
                }

            // Decode from the buffer if possible
            let (decoded, ended) = try self.processor.decodeNext(
                decodeMode: readLastChunkFromBuffer ? .last : .normal,
                seenEOF: readLastChunkFromBuffer
            )

            if ended {
                // We expect `decodeNext()` to only return `ended == true` only if we've notified it
                // that we've read the last chunk from the buffer.
                assert(readLastChunkFromBuffer)
                self.state = .finishedDecoding
                return decoded
            }

            // If `ended == false` and if `readLastChunkFromBuffer == true` then we must have manged
            // to decode a message. Otherwise something is wrong in `decodeNext()`.
            assert(!readLastChunkFromBuffer || decoded != nil)

            return decoded
        }

        @inlinable
        func assertFinishedDecodingIfNoDecoded(_ decoded: Element?) {
            guard decoded == nil else {
                return
            }
            switch self.state {
            case .finishedDecoding:
                break
            case .readingFromBuffer, .readLastChunkFromBuffer:
                assertionFailure(
                    "'decodeFromBuffer()' must have set the 'state' to '.finishedDecoding' if it returned 'nil'."
                )
            }
        }

        /// Retrieve the next element from the ``NIODecodedAsyncSequence``.
        ///
        /// The same as `next(isolation:)` but not isolated to an actor, which allows
        /// for less availability restrictions.
        @inlinable
        public mutating func next() async throws -> Element? {
            switch self.state {
            case .finishedDecoding:
                return nil
            case .readingFromBuffer, .readLastChunkFromBuffer:
                break
            }

            if let decoded = try self.decodeFromBuffer() {
                return decoded
            }

            loop: while true {
                sw: switch self.state {
                case .readingFromBuffer:
                    /// Loop while we have more data to read.
                    break sw
                case .finishedDecoding, .readLastChunkFromBuffer:
                    break loop
                }

                // Read more data into the buffer so we can decode more messages
                guard let nextBuffer = try await self.baseIterator.next() else {
                    // Ran out of data to read.
                    self.state = .readLastChunkFromBuffer
                    let decoded = try self.decodeFromBuffer()
                    self.assertFinishedDecodingIfNoDecoded(decoded)
                    return decoded
                }

                self.processor.append(nextBuffer)

                if let decoded = try self.decodeFromBuffer() {
                    return decoded
                }
            }

            return nil
        }

        /// Retrieve the next element from the ``NIODecodedAsyncSequence``.
        ///
        /// The same as `next()` but isolated to an actor.
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        @inlinable
        public mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> Element? {
            switch self.state {
            case .finishedDecoding:
                return nil
            case .readingFromBuffer, .readLastChunkFromBuffer:
                break
            }

            if let decoded = try self.decodeFromBuffer() {
                return decoded
            }

            loop: while true {
                sw: switch self.state {
                case .readingFromBuffer:
                    /// Loop while we have more data to read.
                    break sw
                case .finishedDecoding, .readLastChunkFromBuffer:
                    break loop
                }

                // Read more data into the buffer so we can decode more messages
                guard let nextBuffer = try await self.baseIterator.next(isolation: actor) else {
                    // Ran out of data to read.
                    self.state = .readLastChunkFromBuffer
                    let decoded = try self.decodeFromBuffer()
                    self.assertFinishedDecodingIfNoDecoded(decoded)
                    return decoded
                }

                self.processor.append(nextBuffer)

                if let decoded = try self.decodeFromBuffer() {
                    return decoded
                }
            }

            return nil
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIODecodedAsyncSequence: Sendable where Base: Sendable, Decoder: Sendable {}

@available(*, unavailable)
extension NIODecodedAsyncSequence.AsyncIterator: Sendable {}
