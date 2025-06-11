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

extension EventLoopFuture {
    /// Get the value/error from an `EventLoopFuture` in an `async` context.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// This function can be used to bridge an `EventLoopFuture` into the `async` world. Ie. if you're in an `async`
    /// function and want to get the result of this future.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @preconcurrency
    @inlinable
    public func get() async throws -> Value where Value: Sendable {
        try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<UnsafeTransfer<Value>, Error>) in
            self.whenComplete { result in
                switch result {
                case .success(let value):
                    cont.resume(returning: UnsafeTransfer(value))
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }.wrappedValue
    }
}

#if canImport(Dispatch)
extension EventLoopGroup {
    /// Shuts down the event loop gracefully.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func shutdownGracefully() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
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
#endif

extension EventLoopPromise {
    /// Complete a future with the result (or error) of the `async` function `body`.
    ///
    /// This function can be used to bridge the `async` world into an `EventLoopPromise`.
    ///
    /// - Parameters:
    ///   - body: The `async` function to run.
    /// - Returns: A `Task` which was created to `await` the `body`.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @discardableResult
    @preconcurrency
    @inlinable
    public func completeWithTask(
        _ body: @escaping @Sendable () async throws -> Value
    ) -> Task<Void, Never> where Value: Sendable {
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
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// - Parameters:
    ///   - data: the data to write
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    @preconcurrency
    public func writeAndFlush<T: Sendable>(_ data: T) async throws {
        try await self.writeAndFlush(data).get()
    }

    /// Set `option` to `value` on this `Channel`.
    /// - Parameters:
    ///   - option: The option to set.
    ///   - value: The new value of the option.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) async throws {
        try await self.setOption(option, value: value).get()
    }

    /// Get the value of `option` for this `Channel`.
    /// - Parameter option: The option to get.
    /// - Returns: The value of the option.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func getOption<Option: ChannelOption>(_ option: Option) async throws -> Option.Value {
        try await self.getOption(option).get()
    }
}

extension ChannelOutboundInvoker {
    /// Register on an `EventLoop` and so have all its IO handled.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// - Parameters:
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func register(file: StaticString = #fileID, line: UInt = #line) async throws {
        try await self.register(file: file, line: line).get()
    }

    /// Bind to a `SocketAddress`.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// - Parameters:
    ///   - address: the `SocketAddress` to which we should bind the `Channel`.
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind(to address: SocketAddress, file: StaticString = #fileID, line: UInt = #line) async throws {
        try await self.bind(to: address, file: file, line: line).get()
    }

    /// Connect to a `SocketAddress`.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// - Parameters:
    ///   - address: the `SocketAddress` to which we should connect the `Channel`.
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect(to address: SocketAddress, file: StaticString = #fileID, line: UInt = #line) async throws {
        try await self.connect(to: address, file: file, line: line).get()
    }

    /// Shortcut for calling `write` and `flush`.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// - Parameters:
    ///   - data: the data to write
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @available(
        *,
        deprecated,
        message: "NIOAny is not Sendable: avoid wrapping the value in NIOAny to silence this warning."
    )
    public func writeAndFlush(_ data: NIOAny, file: StaticString = #fileID, line: UInt = #line) async throws {
        try await self.writeAndFlush(data, file: file, line: line).get()
    }

    /// Close the `Channel` and so the connection if one exists.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// - Parameters:
    ///   - mode: the `CloseMode` that is used
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func close(mode: CloseMode = .all, file: StaticString = #fileID, line: UInt = #line) async throws {
        try await self.close(mode: mode, file: file, line: line).get()
    }

    /// Trigger a custom user outbound event which will flow through the `ChannelPipeline`.
    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    /// - Parameters:
    ///   - event: the event itself.
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    @preconcurrency
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func triggerUserOutboundEvent(
        _ event: Any & Sendable,
        file: StaticString = #fileID,
        line: UInt = #line
    ) async throws {
        try await self.triggerUserOutboundEvent(event, file: file, line: line).get()
    }
}

extension ChannelPipeline {
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @preconcurrency
    public func addHandler(
        _ handler: ChannelHandler & Sendable,
        name: String? = nil,
        position: ChannelPipeline.Position = .last
    ) async throws {
        try await self.addHandler(handler, name: name, position: position).get()
    }

    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @preconcurrency
    public func removeHandler(_ handler: RemovableChannelHandler & Sendable) async throws {
        try await self.removeHandler(handler).get()
    }

    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func removeHandler(name: String) async throws {
        try await self.removeHandler(name: name).get()
    }

    ///
    /// - warning: This method currently violates Structured Concurrency because cancellation isn't respected.
    ///
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @available(
        *,
        deprecated,
        message: "Use .syncOperations.removeHandler(context:) instead, this method is not Sendable-safe."
    )
    public func removeHandler(context: ChannelHandlerContext) async throws {
        try await self.removeHandler(context: context).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @available(
        *,
        deprecated,
        message:
            "ChannelHandlerContext is not Sendable and it is therefore not safe to be used outside of its EventLoop"
    )

    @preconcurrency
    public func context(handler: ChannelHandler & Sendable) async throws -> ChannelHandlerContext {
        try await self.context(handler: handler).map { UnsafeTransfer($0) }.get().wrappedValue
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @available(
        *,
        deprecated,
        message:
            "ChannelHandlerContext is not Sendable and it is therefore not safe to be used outside of its EventLoop"
    )
    public func context(name: String) async throws -> ChannelHandlerContext {
        try await self.context(name: name).map { UnsafeTransfer($0) }.get().wrappedValue
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @available(
        *,
        deprecated,
        message:
            "ChannelHandlerContext is not Sendable and it is therefore not safe to be used outside of its EventLoop"
    )
    @inlinable
    @preconcurrency
    public func context<Handler: ChannelHandler & _NIOCoreSendableMetatype>(
        handlerType: Handler.Type
    ) async throws -> ChannelHandlerContext {
        try await self.context(handlerType: handlerType).map { UnsafeTransfer($0) }.get().wrappedValue
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @preconcurrency
    public func addHandlers(
        _ handlers: [ChannelHandler & Sendable],
        position: ChannelPipeline.Position = .last
    ) async throws {
        try await self.addHandlers(handlers, position: position).map { UnsafeTransfer($0) }.get().wrappedValue
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @preconcurrency
    public func addHandlers(
        _ handlers: (ChannelHandler & Sendable)...,
        position: ChannelPipeline.Position = .last
    ) async throws {
        try await self.addHandlers(handlers, position: position)
    }
}

/// An error that is thrown when the number of bytes in an AsyncSequence exceeds the limit.
///
/// When collecting the bytes from an AsyncSequence, there is a limit up to where the content
/// exceeds a certain threshold beyond which the content isn't matching an expected reasonable
/// size to be processed. This error is generally thrown when it is discovered that there are more
/// more bytes in a sequence than what was specified as the maximum. It could be that this upTo
/// limit should be increased, or that the sequence has unexpected content in it.
public struct NIOTooManyBytesError: Error {
    /// Current limit on the maximum number of bytes in the sequence
    public var maxBytes: Int?

    @available(
        *,
        deprecated,
        message: "Construct the NIOTooManyBytesError with the maxBytes limit that triggered this error"
    )
    public init() {
        self.maxBytes = nil
    }

    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }
}

extension NIOTooManyBytesError: Equatable {
    public static func == (lhs: NIOTooManyBytesError, rhs: NIOTooManyBytesError) -> Bool {
        // Equality of the maxBytes isn't of consequence
        true
    }
}

extension NIOTooManyBytesError: Hashable {
    public func hash(into hasher: inout Hasher) {
        // All errors of this type hash to the same value since maxBytes isn't of consequence
        hasher.combine(7)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncSequence where Element: RandomAccessCollection, Element.Element == UInt8 {
    /// Accumulates an `AsyncSequence` of `RandomAccessCollection`s into a single `accumulationBuffer`.
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
                throw NIOTooManyBytesError(maxBytes: maxBytes)
            }
            accumulationBuffer.writeBytes(fragment)
        }
    }

    /// Accumulates an `AsyncSequence` of `RandomAccessCollection`s into a single ``ByteBuffer``.
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
    /// Accumulates an `AsyncSequence` of ``ByteBuffer``s into a single `accumulationBuffer`.
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
                throw NIOTooManyBytesError(maxBytes: maxBytes)
            }
            accumulationBuffer.writeImmutableBuffer(fragment)
        }
    }

    /// Accumulates an `AsyncSequence` of ``ByteBuffer``s into a single ``ByteBuffer``.
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
            throw NIOTooManyBytesError(maxBytes: maxBytes)
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

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncSequenceFromIterator: Sendable where AsyncIterator: Sendable {}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension EventLoop {
    @preconcurrency
    @inlinable
    public func makeFutureWithTask<Return: Sendable>(
        _ body: @Sendable @escaping () async throws -> Return
    ) -> EventLoopFuture<Return> {
        let promise = self.makePromise(of: Return.self)
        promise.completeWithTask(body)
        return promise.futureResult
    }
}
