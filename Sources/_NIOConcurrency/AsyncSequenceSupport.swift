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
public struct ByteBufferToUInt8AsyncSequence<Upstream: AsyncSequence>: AsyncSequence where Upstream.Element == ByteBuffer {
    public typealias Element = UInt8
    public typealias AsyncIterator = Iterator
    
    public struct Iterator: AsyncIteratorProtocol {
        /*private but*/ @usableFromInline var state: State
        
        @usableFromInline
        enum State {
            case hasBuffer(ByteBuffer, Upstream.AsyncIterator)
            case askForMore(Upstream.AsyncIterator)
            case finished
            case modifying
        }
        
        @usableFromInline
        init(_ upstream: Upstream.AsyncIterator) {
            self.state = .askForMore(upstream)
        }
        
        @inlinable
        public mutating func next() async throws -> Element? {
            switch self.state {
            case .askForMore(var upstream):
                self.state = .modifying
                
                while true {
                    switch try await upstream.next() {
                    case .some(let nextBuffer) where nextBuffer.readableBytes == 0:
                        break
                        
                    case .some(var nextBuffer):
                        assert(nextBuffer.readableBytes > 0)
                        let result = nextBuffer.readInteger(as: UInt8.self)
                        if nextBuffer.readableBytes > 0 {
                            self.state = .hasBuffer(nextBuffer, upstream)
                        } else {
                            self.state = .askForMore(upstream)
                        }
                        return result
                        
                    case .none:
                        self.state = .finished
                        return nil
                    }
                }
                
            case .hasBuffer(var buffer, let upstream):
                assert(buffer.readableBytes > 0)
                self.state = .modifying
                
                let result = buffer.readInteger(as: UInt8.self)
                if buffer.readableBytes > 0 {
                    self.state = .hasBuffer(buffer, upstream)
                } else {
                    self.state = .askForMore(upstream)
                }
                return result
                
            case .finished:
                return nil
                
            case .modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
    }
    
    @inlinable
    public func makeAsyncIterator() -> Iterator {
        Iterator(self.upstream.makeAsyncIterator())
    }
    
    @usableFromInline
    let upstream: Upstream
    
    /*private but*/ @usableFromInline init(_ upstream: Upstream) {
        self.upstream = upstream
    }
}

@usableFromInline
struct TooManyBytesError: Error {
    @usableFromInline
    init() {}
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AsyncSequence where Element == ByteBuffer {
    /// Transform an AsyncSequence of ByteBuffers into an AsyncSequence of single bytes.
    @inlinable
    public func toBytes() -> ByteBufferToUInt8AsyncSequence<Self> {
        ByteBufferToUInt8AsyncSequence(self)
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
            throw TooManyBytesError()
        }
        
        while var next = try await iterator.next() {
            receivedBytes += next.readableBytes
            if receivedBytes > maxBytes {
                throw TooManyBytesError()
            }
            
            buffer.writeBuffer(&next)
        }
        return buffer
    }
}
#endif
