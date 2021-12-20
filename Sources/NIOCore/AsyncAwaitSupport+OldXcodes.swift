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

#if compiler(>=5.5) && !compiler(>=5.5.2) && canImport(_Concurrency) 

extension EventLoopFuture {
    /// Get the value/error from an `EventLoopFuture` in an `async` context.
    ///
    /// This function can be used to bridge an `EventLoopFuture` into the `async` world. Ie. if you're in an `async`
    /// function and want to get the result of this future.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @inlinable
    public func writeAndFlush<T>(_ any: T) async throws {
        try await self.writeAndFlush(any).get()
    }

    /// Set `option` to `value` on this `Channel`.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @inlinable
    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) async throws {
        try await self.setOption(option, value: value).get()
    }

    /// Get the value of `option` for this `Channel`.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @inlinable
    public func getOption<Option: ChannelOption>(_ option: Option) async throws -> Option.Value {
        return try await self.getOption(option).get()
    }
}

extension ChannelOutboundInvoker {
    /// Register on an `EventLoop` and so have all its IO handled.
    ///
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func register(file: StaticString = #file, line: UInt = #line) async throws {
        try await self.register(file: file, line: line).get()
    }

    /// Bind to a `SocketAddress`.
    /// - parameters:
    ///     - to: the `SocketAddress` to which we should bind the `Channel`.
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func bind(to address: SocketAddress, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.bind(to: address, file: file, line: line).get()
    }

    /// Connect to a `SocketAddress`.
    /// - parameters:
    ///     - to: the `SocketAddress` to which we should connect the `Channel`.
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func connect(to address: SocketAddress, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.connect(to: address, file: file, line: line).get()
    }

    /// Shortcut for calling `write` and `flush`.
    ///
    /// - parameters:
    ///     - data: the data to write
    /// - returns: the future which will be notified once the `write` operation completes.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func writeAndFlush(_ data: NIOAny, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.writeAndFlush(data, file: file, line: line).get()
    }

    /// Close the `Channel` and so the connection if one exists.
    ///
    /// - parameters:
    ///     - mode: the `CloseMode` that is used
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func close(mode: CloseMode = .all, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.close(mode: mode, file: file, line: line).get()
    }

    /// Trigger a custom user outbound event which will flow through the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - event: the event itself.
    /// - returns: the future which will be notified once the operation completes.
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func triggerUserOutboundEvent(_ event: Any, file: StaticString = #file, line: UInt = #line) async throws {
        try await self.triggerUserOutboundEvent(event, file: file, line: line).get()
    }
}

extension ChannelPipeline {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func addHandler(_ handler: ChannelHandler,
                           name: String? = nil,
                           position: ChannelPipeline.Position = .last) async throws {
        try await self.addHandler(handler, name: name, position: position).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func removeHandler(_ handler: RemovableChannelHandler) async throws {
        try await self.removeHandler(handler).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func removeHandler(name: String) async throws {
        try await self.removeHandler(name: name).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func removeHandler(context: ChannelHandlerContext) async throws {
        try await self.removeHandler(context: context).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func context(handler: ChannelHandler) async throws -> ChannelHandlerContext {
        return try await self.context(handler: handler).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func context(name: String) async throws -> ChannelHandlerContext {
        return try await self.context(name: name).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @inlinable
    public func context<Handler: ChannelHandler>(handlerType: Handler.Type) async throws -> ChannelHandlerContext {
        return try await self.context(handlerType: handlerType).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func addHandlers(_ handlers: [ChannelHandler],
                            position: ChannelPipeline.Position = .last) async throws {
        try await self.addHandlers(handlers, position: position).get()
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    public func addHandlers(_ handlers: ChannelHandler...,
                            position: ChannelPipeline.Position = .last) async throws {
        try await self.addHandlers(handlers, position: position)
    }
}
#endif
