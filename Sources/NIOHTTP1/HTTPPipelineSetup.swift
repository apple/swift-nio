//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// Configuration required to configure a HTTP client pipeline for upgrade.
///
/// See the documentation for `HTTPClientUpgradeHandler` for details on these
/// properties.
public typealias NIOHTTPClientUpgradeConfiguration = (
    upgraders: [NIOHTTPClientProtocolUpgrader], completionHandler: @Sendable (ChannelHandlerContext) -> Void
)

public typealias NIOHTTPClientUpgradeSendableConfiguration = (
    upgraders: [NIOHTTPClientProtocolUpgrader & Sendable], completionHandler: @Sendable (ChannelHandlerContext) -> Void
)

/// Configuration required to configure a HTTP server pipeline for upgrade.
///
/// See the documentation for `HTTPServerUpgradeHandler` for details on these
/// properties.
@available(*, deprecated, renamed: "NIOHTTPServerUpgradeConfiguration")
public typealias HTTPUpgradeConfiguration = NIOHTTPServerUpgradeConfiguration

public typealias NIOHTTPServerUpgradeConfiguration = (
    upgraders: [HTTPServerProtocolUpgrader], completionHandler: @Sendable (ChannelHandlerContext) -> Void
)

public typealias NIOHTTPServerUpgradeSendableConfiguration = (
    upgraders: [HTTPServerProtocolUpgrader & Sendable], completionHandler: @Sendable (ChannelHandlerContext) -> Void
)

extension ChannelPipeline {
    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func addHTTPClientHandlers(
        position: Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes
    ) -> EventLoopFuture<Void> {
        self.addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: nil
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func addHTTPClientHandlers(
        position: Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeSendableConfiguration?
    ) -> EventLoopFuture<Void> {
        self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: upgrade
        )
    }

    private func _addHTTPClientHandlers(
        position: Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeSendableConfiguration?
    ) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>

        if self.eventLoop.inEventLoop {
            let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
            let result = Result<Void, Error> {
                try self.syncOperations.addHTTPClientHandlers(
                    position: syncPosition,
                    leftOverBytesStrategy: leftOverBytesStrategy,
                    withClientUpgrade: upgrade
                )
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
                try self.syncOperations.addHTTPClientHandlers(
                    position: syncPosition,
                    leftOverBytesStrategy: leftOverBytesStrategy,
                    withClientUpgrade: upgrade
                )
            }
        }

        return future
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - enableOutboundHeaderValidation: Whether the pipeline should confirm that outbound headers are well-formed.
    ///         Defaults to `true`.
    ///   - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientUpgradeHandler`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func addHTTPClientHandlers(
        position: Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        enableOutboundHeaderValidation: Bool = true,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeSendableConfiguration? = nil
    ) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>

        if self.eventLoop.inEventLoop {
            let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
            let result = Result<Void, Error> {
                try self.syncOperations.addHTTPClientHandlers(
                    position: syncPosition,
                    leftOverBytesStrategy: leftOverBytesStrategy,
                    enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                    withClientUpgrade: upgrade
                )
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
                try self.syncOperations.addHTTPClientHandlers(
                    position: syncPosition,
                    leftOverBytesStrategy: leftOverBytesStrategy,
                    enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                    withClientUpgrade: upgrade
                )
            }
        }

        return future
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - enableOutboundHeaderValidation: Whether the pipeline should confirm that outbound headers are well-formed.
    ///         Defaults to `true`.
    ///   - encoderConfiguration: The configuration for the ``HTTPRequestEncoder``.
    ///   - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientUpgradeHandler`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func addHTTPClientHandlers(
        position: Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        enableOutboundHeaderValidation: Bool = true,
        encoderConfiguration: HTTPRequestEncoder.Configuration = .init(),
        withClientUpgrade upgrade: NIOHTTPClientUpgradeSendableConfiguration? = nil
    ) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>

        if self.eventLoop.inEventLoop {
            let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
            let result = Result<Void, Error> {
                try self.syncOperations.addHTTPClientHandlers(
                    position: syncPosition,
                    leftOverBytesStrategy: leftOverBytesStrategy,
                    enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                    encoderConfiguration: encoderConfiguration,
                    withClientUpgrade: upgrade
                )
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
                try self.syncOperations.addHTTPClientHandlers(
                    position: syncPosition,
                    leftOverBytesStrategy: leftOverBytesStrategy,
                    enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                    encoderConfiguration: encoderConfiguration,
                    withClientUpgrade: upgrade
                )
            }
        }

        return future
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true
    ) -> EventLoopFuture<Void> {
        self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     ``HTTPServerPipelineHandler``.
    /// 2. Supporting HTTP upgrade, using the ``HTTPServerUpgradeHandler``.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///   - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true
    ) -> EventLoopFuture<Void> {
        self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     ``HTTPServerPipelineHandler``.
    /// 2. Supporting HTTP upgrade, using the ``HTTPServerUpgradeHandler``.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///   - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    ///   - encoderConfiguration: The configuration for the ``HTTPResponseEncoder``.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration = .init()
    ) -> EventLoopFuture<Void> {
        self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation,
            withEncoderConfiguration: encoderConfiguration
        )
    }

    private func _configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration = .init()
    ) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>

        if self.eventLoop.inEventLoop {
            let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
            let result = Result<Void, Error> {
                try self.syncOperations.configureHTTPServerPipeline(
                    position: syncPosition,
                    withPipeliningAssistance: pipelining,
                    withServerUpgrade: upgrade,
                    withErrorHandling: errorHandling,
                    withOutboundHeaderValidation: headerValidation,
                    withEncoderConfiguration: encoderConfiguration
                )
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
                try self.syncOperations.configureHTTPServerPipeline(
                    position: syncPosition,
                    withPipeliningAssistance: pipelining,
                    withServerUpgrade: upgrade,
                    withErrorHandling: errorHandling,
                    withOutboundHeaderValidation: headerValidation,
                    withEncoderConfiguration: encoderConfiguration
                )
            }
        }

        return future
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - Throws: If the pipeline could not be configured.
    public func addHTTPClientHandlers(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        try self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: upgrade
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - Throws: If the pipeline could not be configured.
    @available(*, deprecated, message: "Use ChannelPipeline.SynchronousOperations.Position instead")
    @_disfavoredOverload
    @preconcurrency
    public func addHTTPClientHandlers(
        position: ChannelPipeline.Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
        try self._addHTTPClientHandlers(
            position: syncPosition,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: upgrade
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - enableOutboundHeaderValidation: Whether or not request header validation is enforced.
    ///   - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientProtocolUpgrader`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - Throws: If the pipeline could not be configured.
    public func addHTTPClientHandlers(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        enableOutboundHeaderValidation: Bool = true,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        try self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: enableOutboundHeaderValidation,
            withClientUpgrade: upgrade
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - enableOutboundHeaderValidation: Whether or not request header validation is enforced.
    ///   - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientProtocolUpgrader`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - Throws: If the pipeline could not be configured.
    @available(*, deprecated, message: "Use ChannelPipeline.SynchronousOperations.Position instead")
    @_disfavoredOverload
    public func addHTTPClientHandlers(
        position: ChannelPipeline.Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        enableOutboundHeaderValidation: Bool = true,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
        try self._addHTTPClientHandlers(
            position: syncPosition,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: enableOutboundHeaderValidation,
            withClientUpgrade: upgrade
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - enableOutboundHeaderValidation: Whether or not request header validation is enforced.
    ///   - encoderConfiguration: The configuration for the ``HTTPRequestEncoder``.
    ///   - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientProtocolUpgrader`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - Throws: If the pipeline could not be configured.
    public func addHTTPClientHandlers(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        enableOutboundHeaderValidation: Bool = true,
        encoderConfiguration: HTTPRequestEncoder.Configuration = .init(),
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        try self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: enableOutboundHeaderValidation,
            encoderConfiguration: encoderConfiguration,
            withClientUpgrade: upgrade
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///   - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///   - enableOutboundHeaderValidation: Whether or not request header validation is enforced.
    ///   - encoderConfiguration: The configuration for the ``HTTPRequestEncoder``.
    ///   - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientProtocolUpgrader`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - Throws: If the pipeline could not be configured.
    @available(*, deprecated, message: "Use ChannelPipeline.SynchronousOperations.Position instead")
    @_disfavoredOverload
    public func addHTTPClientHandlers(
        position: ChannelPipeline.Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        enableOutboundHeaderValidation: Bool = true,
        encoderConfiguration: HTTPRequestEncoder.Configuration = .init(),
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
        try self._addHTTPClientHandlers(
            position: syncPosition,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: enableOutboundHeaderValidation,
            encoderConfiguration: encoderConfiguration,
            withClientUpgrade: upgrade
        )
    }

    private func _addHTTPClientHandlers(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        enableOutboundHeaderValidation: Bool = true,
        encoderConfiguration: HTTPRequestEncoder.Configuration = .init(),
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        // Why two separate functions? With the fast-path (no upgrader, yes header validator) we can promote the Array of handlers
        // to the stack and skip an allocation.
        if upgrade != nil || enableOutboundHeaderValidation != true {
            try self._addHTTPClientHandlersFallback(
                position: position,
                leftOverBytesStrategy: leftOverBytesStrategy,
                enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                encoderConfiguration: encoderConfiguration,
                withClientUpgrade: upgrade
            )
        } else {
            try self._addHTTPClientHandlers(
                position: position,
                leftOverBytesStrategy: leftOverBytesStrategy,
                encoderConfiguration: encoderConfiguration
            )
        }
    }

    private func _addHTTPClientHandlers(
        position: ChannelPipeline.SynchronousOperations.Position,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy,
        encoderConfiguration: HTTPRequestEncoder.Configuration
    ) throws {
        self.eventLoop.assertInEventLoop()
        let requestEncoder = HTTPRequestEncoder(configuration: encoderConfiguration)
        let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy: leftOverBytesStrategy)
        let requestHeaderValidator = NIOHTTPRequestHeadersValidator()
        let handlers: [ChannelHandler] = [
            requestEncoder, ByteToMessageHandler(responseDecoder), requestHeaderValidator,
        ]
        try self.addHandlers(handlers, position: position)
    }

    private func _addHTTPClientHandlersFallback(
        position: ChannelPipeline.SynchronousOperations.Position,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy,
        enableOutboundHeaderValidation: Bool,
        encoderConfiguration: HTTPRequestEncoder.Configuration,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration?
    ) throws {
        self.eventLoop.assertInEventLoop()
        let requestEncoder = HTTPRequestEncoder(configuration: encoderConfiguration)
        let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy: leftOverBytesStrategy)
        var handlers: [RemovableChannelHandler] = [requestEncoder, ByteToMessageHandler(responseDecoder)]

        if enableOutboundHeaderValidation {
            handlers.append(NIOHTTPRequestHeadersValidator())
        }

        if let upgrade = upgrade {
            let upgrader = NIOHTTPClientUpgradeHandler(
                upgraders: upgrade.upgraders,
                httpHandlers: handlers,
                upgradeCompletionHandler: upgrade.completionHandler
            )
            handlers.append(upgrader)
        }

        try self.addHandlers(handlers, position: position)
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    /// - Throws: If the pipeline could not be configured.
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true
    ) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    /// - Throws: If the pipeline could not be configured.
    @preconcurrency
    @available(*, deprecated, message: "Use ChannelPipeline.SynchronousOperations.Position instead")
    @_disfavoredOverload
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true
    ) throws {
        let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
        try self._configureHTTPServerPipeline(
            position: syncPosition,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///   - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    /// - Throws: If the pipeline could not be configured.
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true
    ) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///   - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    /// - Throws: If the pipeline could not be configured.
    @available(*, deprecated, message: "Use ChannelPipeline.SynchronousOperations.Position instead")
    @_disfavoredOverload
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true
    ) throws {
        let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
        try self._configureHTTPServerPipeline(
            position: syncPosition,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///   - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    ///   - encoderConfiguration: The configuration for the ``HTTPRequestEncoder``.
    /// - Throws: If the pipeline could not be configured.
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration
    ) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation,
            withEncoderConfiguration: encoderConfiguration
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately
    /// for server use. It supports the following features:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the
    ///     `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// This method will likely be extended in future with more support for other first-party
    /// features.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///   - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///   - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///   - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///   - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    ///   - encoderConfiguration: The configuration for the ``HTTPRequestEncoder``.
    /// - Throws: If the pipeline could not be configured.
    @available(*, deprecated, message: "Use ChannelPipeline.SynchronousOperations.Position instead")
    @_disfavoredOverload
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration
    ) throws {
        let syncPosition = ChannelPipeline.SynchronousOperations.Position(position)
        try self._configureHTTPServerPipeline(
            position: syncPosition,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation,
            withEncoderConfiguration: encoderConfiguration
        )
    }

    private func _configureHTTPServerPipeline(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration = .init()
    ) throws {
        self.eventLoop.assertInEventLoop()

        let responseEncoder = HTTPResponseEncoder(configuration: encoderConfiguration)
        let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: upgrade == nil ? .dropBytes : .forwardBytes)

        var handlers: [RemovableChannelHandler] = [responseEncoder, ByteToMessageHandler(requestDecoder)]

        if pipelining {
            handlers.append(HTTPServerPipelineHandler())
        }

        if headerValidation {
            handlers.append(NIOHTTPResponseHeadersValidator())
        }

        if errorHandling {
            handlers.append(HTTPServerProtocolErrorHandler())
        }

        if let (upgraders, completionHandler) = upgrade {
            let upgrader = HTTPServerUpgradeHandler(
                upgraders: upgraders,
                httpEncoder: responseEncoder,
                extraHTTPHandlers: Array(handlers.dropFirst()),
                upgradeCompletionHandler: completionHandler
            )
            handlers.append(upgrader)
        }

        try self.addHandlers(handlers, position: position)
    }
}
