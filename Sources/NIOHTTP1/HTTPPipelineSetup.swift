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
        self.addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: true,
            withClientUpgrade: upgrade
        )
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
        self.addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: enableOutboundHeaderValidation,
            encoderConfiguration: .init(),
            decoderLimitConfiguration: .init(),
            withClientUpgrade: upgrade
        )
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
        self.addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: enableOutboundHeaderValidation,
            encoderConfiguration: encoderConfiguration,
            decoderLimitConfiguration: .init(),
            withClientUpgrade: upgrade
        )
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
    ///   - decoderLimitConfiguration: The limit configuration for the ``HTTPDecoder``.
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
        decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration = .init(),
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
                    decoderLimitConfiguration: decoderLimitConfiguration,
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
                    decoderLimitConfiguration: decoderLimitConfiguration,
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
    @available(*, deprecated, message: "Use configureHTTPServerPipeline(position:configuration:) instead")
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true
    ) -> EventLoopFuture<Void> {
        self.configureHTTPServerPipeline(
            position: position,
            configuration: .init(
                pipeliningAssistance: pipelining,
                serverUpgrade: upgrade.map { NIOHTTPServerPipelineConfiguration.UpgradeConfiguration($0) },
                errorHandling: errorHandling
            )
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
    @available(*, deprecated, message: "Use configureHTTPServerPipeline(position:configuration:) instead")
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true
    ) -> EventLoopFuture<Void> {
        self.configureHTTPServerPipeline(
            position: position,
            configuration: .init(
                pipeliningAssistance: pipelining,
                serverUpgrade: upgrade.map { NIOHTTPServerPipelineConfiguration.UpgradeConfiguration($0) },
                errorHandling: errorHandling,
                outboundHeaderValidation: headerValidation
            )
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
    @available(*, deprecated, message: "Use configureHTTPServerPipeline(position:configuration:) instead")
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration = .init()
    ) -> EventLoopFuture<Void> {
        self.configureHTTPServerPipeline(
            position: position,
            configuration: .init(
                pipeliningAssistance: pipelining,
                serverUpgrade: upgrade.map { NIOHTTPServerPipelineConfiguration.UpgradeConfiguration($0) },
                errorHandling: errorHandling,
                outboundHeaderValidation: headerValidation,
                encoderConfiguration: encoderConfiguration
            )
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
    ///   - decoderLimitConfiguration: The limit configuration for the ``HTTPDecoder``.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    @available(*, deprecated, message: "Use configureHTTPServerPipeline(position:configuration:) instead")
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeSendableConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration = .init(),
        withDecoderLimitConfiguration decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration = .init()
    ) -> EventLoopFuture<Void> {
        self.configureHTTPServerPipeline(
            position: position,
            configuration: .init(
                pipeliningAssistance: pipelining,
                serverUpgrade: upgrade.map { NIOHTTPServerPipelineConfiguration.UpgradeConfiguration($0) },
                errorHandling: errorHandling,
                outboundHeaderValidation: headerValidation,
                encoderConfiguration: encoderConfiguration,
                decoderLimitConfiguration: decoderLimitConfiguration
            )
        )
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately for server use. It
    /// supports the following features, depending on the provided `configuration`:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the ``HTTPServerPipelineHandler``.
    /// 2. Supporting HTTP upgrade, using the ``HTTPServerUpgradeHandler``.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers. Defaults to `.last`.
    ///   - configuration: The configuration for the HTTP server pipeline.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.Position = .last,
        configuration: NIOHTTPServerPipelineConfiguration
    ) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture {
                try self.syncOperations.configureHTTPServerPipeline(
                    position: .init(position),
                    configuration: configuration
                )
            }
        }

        return self.eventLoop.submit {
            try self.syncOperations.configureHTTPServerPipeline(
                position: .init(position),
                configuration: configuration
            )
        }
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
    ///   - decoderLimitConfiguration: The limit configuration for the ``HTTPDecoder``.
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
        decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration = .init(),
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil
    ) throws {
        try self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            enableOutboundHeaderValidation: enableOutboundHeaderValidation,
            encoderConfiguration: encoderConfiguration,
            decoderLimitConfiguration: decoderLimitConfiguration,
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
        decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration = .init(),
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
                decoderLimitConfiguration: decoderLimitConfiguration,
                withClientUpgrade: upgrade
            )
        } else {
            try self._addHTTPClientHandlers(
                position: position,
                leftOverBytesStrategy: leftOverBytesStrategy,
                encoderConfiguration: encoderConfiguration,
                decoderLimitConfiguration: decoderLimitConfiguration
            )
        }
    }

    private func _addHTTPClientHandlers(
        position: ChannelPipeline.SynchronousOperations.Position,
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy,
        encoderConfiguration: HTTPRequestEncoder.Configuration,
        decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration
    ) throws {
        self.eventLoop.assertInEventLoop()
        let requestEncoder = HTTPRequestEncoder(configuration: encoderConfiguration)
        let responseDecoder = HTTPResponseDecoder(
            leftOverBytesStrategy: leftOverBytesStrategy,
            limitConfiguration: decoderLimitConfiguration
        )
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
        decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration,
        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration?
    ) throws {
        self.eventLoop.assertInEventLoop()
        let requestEncoder = HTTPRequestEncoder(configuration: encoderConfiguration)
        let responseDecoder = HTTPResponseDecoder(
            leftOverBytesStrategy: leftOverBytesStrategy,
            limitConfiguration: decoderLimitConfiguration
        )
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
    ///   - decoderLimitConfiguration: The limit configuration for the ``HTTPDecoder``.
    /// - Throws: If the pipeline could not be configured.
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration,
        withDecoderLimitConfiguration decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration,
    ) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation,
            withEncoderConfiguration: encoderConfiguration,
            withDecoderLimitConfiguration: decoderLimitConfiguration
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

    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// This function knows how to set up all first-party HTTP channel handlers appropriately for server use. It
    /// supports the following features, depending on the provided `configuration`:
    ///
    /// 1. Providing assistance handling clients that pipeline HTTP requests, using the `HTTPServerPipelineHandler`.
    /// 2. Supporting HTTP upgrade, using the `HTTPServerUpgradeHandler`.
    /// 3. Providing assistance handling protocol errors.
    /// 4. Validating outbound header fields to protect against response splitting attacks.
    ///
    /// - Important: This **must** be called on the Channel's event loop.
    ///
    /// - Parameters:
    ///   - position: Where in the pipeline to add the HTTP server handlers. Defaults to `.last`.
    ///   - configuration: The configuration for the HTTP server pipeline.
    /// - Throws: If the pipeline could not be configured.
    public func configureHTTPServerPipeline(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        configuration: NIOHTTPServerPipelineConfiguration
    ) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: configuration.pipeliningAssistance,
            withServerUpgrade: configuration.serverUpgrade.map { ($0.upgraders, $0.completionHandler) },
            withErrorHandling: configuration.errorHandling,
            withOutboundHeaderValidation: configuration.outboundHeaderValidation,
            withEncoderConfiguration: configuration.encoderConfiguration,
            withDecoderLimitConfiguration: configuration.decoderLimitConfiguration
        )
    }

    private func _configureHTTPServerPipeline(
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        withPipeliningAssistance pipelining: Bool = true,
        withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
        withErrorHandling errorHandling: Bool = true,
        withOutboundHeaderValidation headerValidation: Bool = true,
        withEncoderConfiguration encoderConfiguration: HTTPResponseEncoder.Configuration = .init(),
        withDecoderLimitConfiguration decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration = .init()
    ) throws {
        self.eventLoop.assertInEventLoop()

        let responseEncoder = HTTPResponseEncoder(configuration: encoderConfiguration)
        // The encoder is outbound-only; the request decoder feeds it each decoded request's method
        // so responses to HEAD/CONNECT are encoded without a body.
        let requestDecoder = HTTPRequestDecoder(
            leftOverBytesStrategy: upgrade == nil ? .dropBytes : .forwardBytes,
            limitConfiguration: decoderLimitConfiguration,
            responseEncoder: responseEncoder
        )

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

/// The configuration for a HTTP server pipeline.
public struct NIOHTTPServerPipelineConfiguration: Sendable {
    /// Whether to provide assistance handling HTTP clients that pipeline their requests. Defaults to `true`. If
    /// `false`, users will need to handle clients that pipeline themselves.
    public var pipeliningAssistance: Bool = true

    /// Whether to add a ``HTTPServerUpgradeHandler`` to the pipeline, configured for HTTP upgrade. Defaults to `nil`,
    /// which will not add the handler to the pipeline. See the documentation on ``HTTPServerUpgradeHandler`` for more
    /// details.
    public var serverUpgrade: UpgradeConfiguration? = nil

    /// Whether to provide assistance handling protocol errors (e.g. failure to parse the HTTP request) by sending
    /// 400 errors. Defaults to `true`.
    public var errorHandling: Bool = true

    /// Whether to validate outbound response headers to confirm that they meet spec compliance. Defaults to `true`.
    public var outboundHeaderValidation: Bool = true

    /// The configuration for the ``HTTPResponseEncoder``.
    public var encoderConfiguration: HTTPResponseEncoder.Configuration = .init()

    /// The limit configuration for the ``HTTPDecoder``.
    public var decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration = .init()

    /// The configuration for HTTP upgrade.
    public struct UpgradeConfiguration: Sendable {
        /// The upgraders the server supports, in order of preference.
        public var upgraders: [HTTPServerProtocolUpgrader & Sendable]

        /// Called once the upgrade is complete, with the context of the handler performing the upgrade.
        public var completionHandler: @Sendable (ChannelHandlerContext) -> Void

        /// Creates an upgrade configuration.
        ///
        /// - Parameters:
        ///   - upgraders: The upgraders the server supports, in order of preference.
        ///   - completionHandler: Called once the upgrade is complete, with the context of the handler performing
        ///     the upgrade.
        public init(
            upgraders: [HTTPServerProtocolUpgrader & Sendable],
            completionHandler: @escaping @Sendable (ChannelHandlerContext) -> Void
        ) {
            self.upgraders = upgraders
            self.completionHandler = completionHandler
        }

        fileprivate init(_ configuration: NIOHTTPServerUpgradeSendableConfiguration) {
            self.init(upgraders: configuration.upgraders, completionHandler: configuration.completionHandler)
        }
    }

    /// The default configuration.
    ///
    /// Uses the following values:
    /// - ``pipeliningAssistance``: `true`
    /// - ``serverUpgrade``: `nil`
    /// - ``errorHandling``: `true`
    /// - ``outboundHeaderValidation``: `true`
    /// - ``encoderConfiguration``: ``HTTPResponseEncoder/Configuration/init()``
    /// - ``decoderLimitConfiguration``: ``NIOHTTPDecoderLimitConfiguration/init()``
    public static var defaults: Self {
        Self()
    }

    fileprivate init(
        pipeliningAssistance: Bool = true,
        serverUpgrade: UpgradeConfiguration? = nil,
        errorHandling: Bool = true,
        outboundHeaderValidation: Bool = true,
        encoderConfiguration: HTTPResponseEncoder.Configuration = .init(),
        decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration = .init()
    ) {
        self.pipeliningAssistance = pipeliningAssistance
        self.serverUpgrade = serverUpgrade
        self.errorHandling = errorHandling
        self.outboundHeaderValidation = outboundHeaderValidation
        self.encoderConfiguration = encoderConfiguration
        self.decoderLimitConfiguration = decoderLimitConfiguration
    }
}
