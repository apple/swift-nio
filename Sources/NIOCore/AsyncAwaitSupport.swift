//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if swift(>=5.5) && canImport(_Concurrency)
public typealias NIOSendable = Swift.Sendable
#else
public typealias NIOSendable = Any
#endif

#if compiler(>=5.5.2) && canImport(_Concurrency)

extension EventLoopFuture {
    /// Get the value/error from an `EventLoopFuture` in an `async` context.
    ///
    /// This function can be used to bridge an `EventLoopFuture` into the `async` world. Ie. if you're in an `async`
    /// function and want to get the result of this future.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func get() async throws -> Value {
        return try await withUnsafeThrowingContinuation { cont in
            self.whenComplete { result in
                switch result {
                case .success(let value):
                    cont.resume(returning: value)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

extension EventLoopGroup {
    /// Shuts down the event loop gracefully.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func shutdownGracefully() async throws {
        return try await withCheckedThrowingContinuation { cont in
            self.shutdownGracefully { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }
}

extension EventLoopPromise {
    /// Complete a future with the result (or error) of the `async` function `body`.
    ///
    /// This function can be used to bridge the `async` world into an `EventLoopPromise`.
    ///
    /// - parameters:
    ///   - body: The `async` function to run.
    /// - returns: A `Task` which was created to `await` the `body`.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @discardableResult
    @inlinable
    public func completeWithTask(_ body: @escaping @Sendable () async throws -> Value) -> Task<Void, Never> {
        Task {
            do {
                let value = try await body()
                self.succeed(value)
            } catch {
                self.fail(error)
            }
        }
    }
}

extension Channel {
    /// Shortcut for calling `write` and `flush`.
    ///
    /// - parameters:
    ///     - data: the data to write
    ///     - promise: the `EventLoopPromise` that will be notified once the `write` operation completes,
    ///                or `nil` if not interested in the outcome of the operation.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func writeAndFlush<T>(_ any: T) async throws {
        try await self.writeAndFlush(any).get()
    }

    /// Set `option` to `value` on this `Channel`.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) async throws {
        try await self.setOption(option, value: value).get()
    }

    /// Get the value of `option` for this `Channel`.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func getOption<Option: ChannelOption>(_ option: Option) async throws -> Option.Value {
        return try await self.getOption(option).get()
    }
}

extension ChannelOutboundInvoker {
    /// Register on an `EventLoop` and so have all its IO handled.
    ///
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func register(file: StaticString = #file, line: UInt = #line) async throws {
        try await self.register(file: file, line: line).get()
    }

    /// Bind to a `SocketAddress`.
    /// - parameters:
    ///     - to: the `SocketAddress` to which we should bind the `Channel`.
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind(to address: SocketAddress, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.bind(to: address, file: file, line: line).get()
    }

    /// Connect to a `SocketAddress`.
    /// - parameters:
    ///     - to: the `SocketAddress` to which we should connect the `Channel`.
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect(to address: SocketAddress, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.connect(to: address, file: file, line: line).get()
    }

    /// Shortcut for calling `write` and `flush`.
    ///
    /// - parameters:
    ///     - data: the data to write
    /// - returns: the future which will be notified once the `write` operation completes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func writeAndFlush(_ data: NIOAny, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.writeAndFlush(data, file: file, line: line).get()
    }

    /// Close the `Channel` and so the connection if one exists.
    ///
    /// - parameters:
    ///     - mode: the `CloseMode` that is used
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func close(mode: CloseMode = .all, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.close(mode: mode, file: file, line: line).get()
    }

    /// Trigger a custom user outbound event which will flow through the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - event: the event itself.
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func triggerUserOutboundEvent(_ event: Any, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.triggerUserOutboundEvent(event, file: file, line: line).get()
    }
}

extension ChannelPipeline {
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func addHandler(_ handler: ChannelHandler,
                           name: String? = nil,
                           position: ChannelPipeline.Position = .last) async throws {
        try await self.addHandler(handler, name: name, position: position).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func removeHandler(_ handler: RemovableChannelHandler) async throws {
        try await self.removeHandler(handler).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func removeHandler(name: String) async throws {
        try await self.removeHandler(name: name).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func removeHandler(context: ChannelHandlerContext) async throws {
        try await self.removeHandler(context: context).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func context(handler: ChannelHandler) async throws -> ChannelHandlerContext {
        return try await self.context(handler: handler).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func context(name: String) async throws -> ChannelHandlerContext {
        return try await self.context(name: name).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func context<Handler: ChannelHandler>(handlerType: Handler.Type) async throws -> ChannelHandlerContext {
        return try await self.context(handlerType: handlerType).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func addHandlers(_ handlers: [ChannelHandler],
                            position: ChannelPipeline.Position = .last) async throws {
        try await self.addHandlers(handlers, position: position).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func addHandlers(_ handlers: ChannelHandler...,
                            position: ChannelPipeline.Position = .last) async throws {
        try await self.addHandlers(handlers, position: position)
    }
}

public struct NIOTooManyBytesError: Error {
     public init() {}
 }

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncSequence where Element: RandomAccessCollection, Element.Element == UInt8 {
    /// Accumulates an ``Swift/AsyncSequence`` of ``Swift/RandomAccessCollection``s into a single `accumulationBuffer`.
    /// - Parameters:
    ///   - accumulationBuffer: buffer to write all the elements of `self` into
    ///   - maxBytes: The maximum number of bytes this method is allowed to write into `accumulationBuffer`
    /// - Throws: `NIOTooManyBytesError` if the the sequence contains more than `maxBytes`.
    /// Note that previous elements of `self` might already be write to `accumulationBuffer`.
    @inlinable
    public func collect(
        upTo maxBytes: Int,
        into accumulationBuffer: inout ByteBuffer
    ) async throws {
        precondition(maxBytes >= 0, "`maxBytes` must be greater than or equal to zero")
        var bytesRead = 0
        for try await fragment in self {
            bytesRead += fragment.count
            guard bytesRead <= maxBytes else {
                throw NIOTooManyBytesError()
            }
            accumulationBuffer.writeBytes(fragment)
        }
    }
    
    /// Accumulates an ``Swift/AsyncSequence`` of ``Swift/RandomAccessCollection``s into a single ``NIO/ByteBuffer``.
    /// - Parameters:
    ///   - maxBytes: The maximum number of bytes this method is allowed to accumulate
    ///   - allocator: Allocator used for allocating the result `ByteBuffer`
    /// - Throws: `NIOTooManyBytesError` if the the sequence contains more than `maxBytes`.
    @inlinable
    public func collect(
        upTo maxBytes: Int,
        using allocator: ByteBufferAllocator
    ) async throws -> ByteBuffer {
        precondition(maxBytes >= 0, "`maxBytes` must be greater than or equal to zero")
        var accumulationBuffer = allocator.buffer(capacity: Swift.min(maxBytes, 1024))
        try await self.collect(upTo: maxBytes, into: &accumulationBuffer)
        return accumulationBuffer
    }
}

// MARK: optimised methods for ByteBuffer

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncSequence where Element == ByteBuffer {
    /// Accumulates an ``Swift/AsyncSequence`` of ``ByteBuffer``s into a single `accumulationBuffer`.
    /// - Parameters:
    ///   - accumulationBuffer: buffer to write all the elements of `self` into
    ///   - maxBytes: The maximum number of bytes this method is allowed to write into `accumulationBuffer`
    /// - Throws: ``NIOTooManyBytesError`` if the the sequence contains more than `maxBytes`.
    /// Note that previous elements of `self` might be already write to `accumulationBuffer`.
    @inlinable
    public func collect(
        upTo maxBytes: Int,
        into accumulationBuffer: inout ByteBuffer
    ) async throws {
        precondition(maxBytes >= 0, "`maxBytes` must be greater than or equal to zero")
        var bytesRead = 0
        for try await fragment in self {
            bytesRead += fragment.readableBytes
            guard bytesRead <= maxBytes else {
                throw NIOTooManyBytesError()
            }
            accumulationBuffer.writeImmutableBuffer(fragment)
        }
    }
    
    /// Accumulates an ``Swift/AsyncSequence`` of ``ByteBuffer``s into a single ``ByteBuffer``.
    /// - Parameters:
    ///   - maxBytes: The maximum number of bytes this method is allowed to accumulate
    /// - Throws: `NIOTooManyBytesError` if the the sequence contains more than `maxBytes`.
    @inlinable
    public func collect(
        upTo maxBytes: Int
    ) async throws -> ByteBuffer {
        precondition(maxBytes >= 0, "`maxBytes` must be greater than or equal to zero")
        // we use the first `ByteBuffer` to accumulate all subsequent `ByteBuffer`s into.
        // this has also the benefit of not copying at all,
        // if the async sequence contains only one element.
        var iterator = self.makeAsyncIterator()
        guard var head = try await iterator.next() else {
            return ByteBuffer()
        }
        guard head.readableBytes <= maxBytes else {
            throw NIOTooManyBytesError()
        }
        
        let tail = AsyncSequenceFromIterator(iterator)
        // it is guaranteed that
        // `maxBytes >= 0 && head.readableBytes >= 0 && head.readableBytes <= maxBytes`
        // This implies that `maxBytes - head.readableBytes >= 0`
        // we can therefore use wrapping subtraction
        try await tail.collect(upTo: maxBytes &- head.readableBytes, into: &head)
        return head
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
struct AsyncSequenceFromIterator<AsyncIterator: AsyncIteratorProtocol>: AsyncSequence {
    @usableFromInline typealias Element = AsyncIterator.Element
    
    @usableFromInline var iterator: AsyncIterator
    
    @inlinable init(_ iterator: AsyncIterator) {
        self.iterator = iterator
    }
    
    @inlinable func makeAsyncIterator() -> AsyncIterator {
        self.iterator
    }
}

#endif
