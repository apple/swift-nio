//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if swift(>=5.5)
import struct NIO.ByteBuffer

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
public struct NIOByteBufferToUInt8AsyncSequence<Upstream: AsyncSequence>: AsyncSequence where Upstream.Element == ByteBuffer {
    public typealias Element = UInt8
    public typealias AsyncIterator = Iterator
    
    @usableFromInline
    let upstream: Upstream
    
    @inlinable
    init(_ upstream: Upstream) {
        self.upstream = upstream
    }
    
    @inlinable
    public func makeAsyncIterator() -> Iterator {
        Iterator(self.upstream.makeAsyncIterator())
    }
    
    public struct Iterator: AsyncIteratorProtocol {
        /*private but*/ @usableFromInline var state: State
        
        @usableFromInline
        enum State {
            case hasBuffer(ByteBuffer, Upstream.AsyncIterator)
            case askForMore(Upstream.AsyncIterator)
            case finished
            
            @inlinable
            init(buffer: ByteBuffer, upstream: Upstream.AsyncIterator) {
                if buffer.readableBytes > 0 {
                    self = .hasBuffer(buffer, upstream)
                } else {
                    self = .askForMore(upstream)
                }
            }
        }
        
        @inlinable
        init(_ upstream: Upstream.AsyncIterator) {
            self.state = .askForMore(upstream)
        }
        
        @inlinable
        public mutating func next() async throws -> Element? {
            switch self.state {
            case .askForMore(var upstream):
                while true {
                    switch try await upstream.next() {
                    case .some(let nextBuffer) where nextBuffer.readableBytes == 0:
                        // we received an empty buffer. for this reason, let's continue and get the
                        // next buffer fro, the sequence
                        continue
                        
                    case .some(var nextBuffer):
                        assert(nextBuffer.readableBytes > 0)
                        let result = nextBuffer.readInteger(as: UInt8.self)
                        self.state = .init(buffer: nextBuffer, upstream: upstream)
                        return result
                        
                    case .none:
                        self.state = .finished
                        return nil
                    }
                }
                
            case .hasBuffer(var buffer, let upstream):
                assert(buffer.readableBytes > 0)
                let result = buffer.readInteger(as: UInt8.self)
                self.state = .init(buffer: buffer, upstream: upstream)
                return result
                
            case .finished:
                return nil
            }
        }
    }
    
}

public struct NIOTooManyBytesError: Error {
    public init() {}
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AsyncSequence where Element == ByteBuffer {
    /// Transform an AsyncSequence of ByteBuffers into an AsyncSequence of single bytes.
    @inlinable
    public func toBytes() -> NIOByteBufferToUInt8AsyncSequence<Self> {
        NIOByteBufferToUInt8AsyncSequence(self)
    }
    
    /// Consume an ``Swift/AsyncSequence`` of ``NIO/ByteBuffer``s into a single `ByteBuffer`.
    ///
    /// - Parameter maxBytes: The maximum number of bytes that the result ByteBuffer is allowed to have.
    /// - Returns: A ``NIO/ByteBuffer`` that holds all the bytes of the AsyncSequence
    @inlinable
    public func consume(maxBytes: Int) async throws -> ByteBuffer? {
        var iterator = self.makeAsyncIterator()
        guard var buffer = try await iterator.next() else {
            return nil
        }
        
        var receivedBytes = buffer.readableBytes
        if receivedBytes > maxBytes {
            throw NIOTooManyBytesError()
        }
        
        while var next = try await iterator.next() {
            receivedBytes += next.readableBytes
            if receivedBytes > maxBytes {
                throw NIOTooManyBytesError()
            }
            
            buffer.writeBuffer(&next)
        }
        return buffer
    }
}
#endif
