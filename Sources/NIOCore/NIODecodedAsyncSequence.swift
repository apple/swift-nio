// MARK: NIODecodedAsyncSequence

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Element == ByteBuffer {
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

/// A sequence that decodes an ``AsyncSequence`` of ``ByteBuffer``s into a sequence of `Element`s,
/// using the ``Decoder``.
///
/// Use the ``AsyncSequence/decode(using:)`` function to create a ``NIODecodedAsyncSequence``.
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
    /// Create an ``AsyncIterator`` for this ``DecodeSequence``.
    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self)
    }

    /// An ``AsyncIterator`` over a ``DecodeSequence``.
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

        /// Retrieve the next element from the ``NIODecodedAsyncSequence``.
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
                    break sw
                case .finishedDecoding, .readLastChunkFromBuffer:
                    break loop
                }

                // Read more data into the buffer so we can decode more messages
                guard let nextBuffer = try await self.baseIterator.next() else {
                    // Ran out of data to read.
                    self.state = .readLastChunkFromBuffer
                    let decoded = try self.decodeFromBuffer()

                    if decoded == nil {
                        switch self.state {
                        case .finishedDecoding:
                            break
                        case .readingFromBuffer, .readLastChunkFromBuffer:
                            assertionFailure(
                                "'decodeFromBuffer()' must have set the 'state' to '.finishedDecoding' if it returned 'nil'."
                            )
                        }
                    }

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
