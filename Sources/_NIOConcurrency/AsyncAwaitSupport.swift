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

import NIO

#if compiler(>=5.5)
    import _Concurrency

    public extension EventLoopFuture {
        /// Get the value/error from an `EventLoopFuture` in an `async` context.
        ///
        /// This function can be used to bridge an `EventLoopFuture` into the `async` world. Ie. if you're in an `async`
        /// function and want to get the result of this future.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        @inlinable
        func get() async throws -> Value {
            try await withUnsafeThrowingContinuation { cont in
                self.whenComplete { result in
                    switch result {
                    case let .success(value):
                        cont.resume(returning: value)
                    case let .failure(error):
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    public extension EventLoopGroup {
        /// Shuts down the event loop gracefully.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        @inlinable
        func shutdownGracefully() async throws {
            try await withCheckedThrowingContinuation { cont in
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

    public extension EventLoopPromise {
        /// Complete a future with the result (or error) of the `async` function `body`.
        ///
        /// This function can be used to bridge the `async` world into an `EventLoopPromise`.
        ///
        /// - parameters:
        ///   - body: The `async` function to run.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        @inlinable
        func completeWithAsync(_ body: @escaping () async throws -> Value) {
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

    public extension Channel {
        /// Shortcut for calling `write` and `flush`.
        ///
        /// - parameters:
        ///     - data: the data to write
        ///     - promise: the `EventLoopPromise` that will be notified once the `write` operation completes,
        ///                or `nil` if not interested in the outcome of the operation.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        @inlinable
        func writeAndFlush<T>(_ any: T) async throws {
            try await writeAndFlush(any).get()
        }

        /// Set `option` to `value` on this `Channel`.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        @inlinable
        func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) async throws {
            try await setOption(option, value: value).get()
        }

        /// Get the value of `option` for this `Channel`.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        @inlinable
        func getOption<Option: ChannelOption>(_ option: Option) async throws -> Option.Value {
            try await getOption(option).get()
        }
    }

    public extension ChannelOutboundInvoker {
        /// Register on an `EventLoop` and so have all its IO handled.
        ///
        /// - returns: the future which will be notified once the operation completes.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func register(file: StaticString = #file, line: UInt = #line) async throws {
            try await register(file: file, line: line).get()
        }

        /// Bind to a `SocketAddress`.
        /// - parameters:
        ///     - to: the `SocketAddress` to which we should bind the `Channel`.
        /// - returns: the future which will be notified once the operation completes.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func bind(to address: SocketAddress, file: StaticString = #file, line: UInt = #line) async throws {
            try await bind(to: address, file: file, line: line).get()
        }

        /// Connect to a `SocketAddress`.
        /// - parameters:
        ///     - to: the `SocketAddress` to which we should connect the `Channel`.
        /// - returns: the future which will be notified once the operation completes.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func connect(to address: SocketAddress, file: StaticString = #file, line: UInt = #line) async throws {
            try await connect(to: address, file: file, line: line).get()
        }

        /// Shortcut for calling `write` and `flush`.
        ///
        /// - parameters:
        ///     - data: the data to write
        /// - returns: the future which will be notified once the `write` operation completes.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func writeAndFlush(_ data: NIOAny, file: StaticString = #file, line: UInt = #line) async throws {
            try await writeAndFlush(data, file: file, line: line).get()
        }

        /// Close the `Channel` and so the connection if one exists.
        ///
        /// - parameters:
        ///     - mode: the `CloseMode` that is used
        /// - returns: the future which will be notified once the operation completes.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func close(mode: CloseMode = .all, file: StaticString = #file, line: UInt = #line) async throws {
            try await close(mode: mode, file: file, line: line).get()
        }

        /// Trigger a custom user outbound event which will flow through the `ChannelPipeline`.
        ///
        /// - parameters:
        ///     - event: the event itself.
        /// - returns: the future which will be notified once the operation completes.
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func triggerUserOutboundEvent(_ event: Any, file: StaticString = #file, line: UInt = #line) async throws {
            try await triggerUserOutboundEvent(event, file: file, line: line).get()
        }
    }

    public extension ChannelPipeline {
        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func addHandler(_ handler: ChannelHandler,
                        name: String? = nil,
                        position: ChannelPipeline.Position = .last) async throws
        {
            try await addHandler(handler, name: name, position: position).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func removeHandler(_ handler: RemovableChannelHandler) async throws {
            try await removeHandler(handler).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func removeHandler(name: String) async throws {
            try await removeHandler(name: name).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func removeHandler(context: ChannelHandlerContext) async throws {
            try await removeHandler(context: context).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func context(handler: ChannelHandler) async throws -> ChannelHandlerContext {
            try await context(handler: handler).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func context(name: String) async throws -> ChannelHandlerContext {
            try await context(name: name).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        @inlinable
        func context<Handler: ChannelHandler>(handlerType: Handler.Type) async throws -> ChannelHandlerContext {
            try await context(handlerType: handlerType).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func addHandlers(_ handlers: [ChannelHandler],
                         position: ChannelPipeline.Position = .last) async throws
        {
            try await addHandlers(handlers, position: position).get()
        }

        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
        func addHandlers(_ handlers: ChannelHandler...,
                         position: ChannelPipeline.Position = .last) async throws
        {
            try await addHandlers(handlers, position: position)
        }
    }
#endif
