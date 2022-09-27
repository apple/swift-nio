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

#if swift(>=5.7)
/// Configuration required to configure a HTTP client pipeline for upgrade.
///
/// See the documentation for `HTTPClientUpgradeHandler` for details on these
/// properties.
public typealias NIOHTTPClientUpgradeConfiguration = (upgraders: [NIOHTTPClientProtocolUpgrader], completionHandler: @Sendable (ChannelHandlerContext) -> Void)
#else
/// Configuration required to configure a HTTP client pipeline for upgrade.
///
/// See the documentation for `HTTPClientUpgradeHandler` for details on these
/// properties.
public typealias NIOHTTPClientUpgradeConfiguration = (upgraders: [NIOHTTPClientProtocolUpgrader], completionHandler: (ChannelHandlerContext) -> Void)
#endif

/// Configuration required to configure a HTTP server pipeline for upgrade.
///
/// See the documentation for `HTTPServerUpgradeHandler` for details on these
/// properties.
@available(*, deprecated, renamed: "NIOHTTPServerUpgradeConfiguration")
public typealias HTTPUpgradeConfiguration = NIOHTTPServerUpgradeConfiguration

#if swift(>=5.7)
public typealias NIOHTTPServerUpgradeConfiguration = (upgraders: [HTTPServerProtocolUpgrader], completionHandler: @Sendable (ChannelHandlerContext) -> Void)
#else
public typealias NIOHTTPServerUpgradeConfiguration = (upgraders: [HTTPServerProtocolUpgrader], completionHandler: (ChannelHandlerContext) -> Void)
#endif

extension ChannelPipeline {
    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func addHTTPClientHandlers(position: Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes) -> EventLoopFuture<Void> {
        return self.addHTTPClientHandlers(position: position,
                                          leftOverBytesStrategy: leftOverBytesStrategy,
                                          withClientUpgrade: nil)
    }

    #if swift(>=5.7)
    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///     - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func addHTTPClientHandlers(position: Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                      withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration?) -> EventLoopFuture<Void> {
        self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: upgrade
        )
    }
    #else
    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///     - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func addHTTPClientHandlers(position: Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                      withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration?) -> EventLoopFuture<Void> {
        self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: upgrade
        )
    }
    #endif
    
    private func _addHTTPClientHandlers(position: Position = .last,
                                        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration?) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>

        if self.eventLoop.inEventLoop {
            let result = Result<Void, Error> {
                try self.syncOperations.addHTTPClientHandlers(position: position,
                                                              leftOverBytesStrategy: leftOverBytesStrategy,
                                                              withClientUpgrade: upgrade)
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                return try self.syncOperations.addHTTPClientHandlers(position: position,
                                                                     leftOverBytesStrategy: leftOverBytesStrategy,
                                                                     withClientUpgrade: upgrade)
            }
        }

        return future
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///     - enableOutboundHeaderValidation: Whether the pipeline should confirm that outbound headers are well-formed.
    ///         Defaults to `true`.
    ///     - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientUpgradeHandler`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func addHTTPClientHandlers(position: Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                      enableOutboundHeaderValidation: Bool = true,
                                      withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>

        if self.eventLoop.inEventLoop {
            let result = Result<Void, Error> {
                try self.syncOperations.addHTTPClientHandlers(position: position,
                                                              leftOverBytesStrategy: leftOverBytesStrategy,
                                                              enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                                                              withClientUpgrade: upgrade)
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                return try self.syncOperations.addHTTPClientHandlers(position: position,
                                                                     leftOverBytesStrategy: leftOverBytesStrategy,
                                                                     enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                                                                     withClientUpgrade: upgrade)
            }
        }

        return future
    }
    
    #if swift(>=5.7)
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
    /// - parameters:
    ///     - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///     - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///     - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///     - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @preconcurrency
    public func configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                            withPipeliningAssistance pipelining: Bool = true,
                                            withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                            withErrorHandling errorHandling: Bool = true) -> EventLoopFuture<Void> {
        self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling
        )
    }
    #else
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
    /// - parameters:
    ///     - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///     - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///     - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///     - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                            withPipeliningAssistance pipelining: Bool = true,
                                            withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                            withErrorHandling errorHandling: Bool = true) -> EventLoopFuture<Void> {
        self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling
        )
    }
    #endif

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
    /// - parameters:
    ///     - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///     - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///     - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///     - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///     - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                            withPipeliningAssistance pipelining: Bool = true,
                                            withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                            withErrorHandling errorHandling: Bool = true,
                                            withOutboundHeaderValidation headerValidation: Bool = true) -> EventLoopFuture<Void> {
        self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation
        )
    }
    
    private func _configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                              withPipeliningAssistance pipelining: Bool = true,
                                              withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                              withErrorHandling errorHandling: Bool = true,
                                              withOutboundHeaderValidation headerValidation: Bool = true) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<Void>

        if self.eventLoop.inEventLoop {
            let result = Result<Void, Error> {
                try self.syncOperations.configureHTTPServerPipeline(position: position,
                                                                    withPipeliningAssistance: pipelining,
                                                                    withServerUpgrade: upgrade,
                                                                    withErrorHandling: errorHandling,
                                                                    withOutboundHeaderValidation: headerValidation)
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                try self.syncOperations.configureHTTPServerPipeline(position: position,
                                                                    withPipeliningAssistance: pipelining,
                                                                    withServerUpgrade: upgrade,
                                                                    withErrorHandling: errorHandling,
                                                                    withOutboundHeaderValidation: headerValidation)
            }
        }

        return future
    }
}

extension ChannelPipeline.SynchronousOperations {
    #if swift(>=5.7)
    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///     - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - throws: If the pipeline could not be configured.
    @preconcurrency
    public func addHTTPClientHandlers(position: ChannelPipeline.Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                      withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil) throws {
        try self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: upgrade
        )
    }
    #else
    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///     - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - throws: If the pipeline could not be configured.
    public func addHTTPClientHandlers(position: ChannelPipeline.Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                      withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil) throws {
        try self._addHTTPClientHandlers(
            position: position,
            leftOverBytesStrategy: leftOverBytesStrategy,
            withClientUpgrade: upgrade
        )
    }
    #endif

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - important: This **must** be called on the Channel's event loop.
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - leftOverBytesStrategy: The strategy to use when dealing with leftover bytes after removing the `HTTPDecoder`
    ///         from the pipeline.
    ///     - upgrade: Add a ``NIOHTTPClientUpgradeHandler`` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of ``NIOHTTPClientProtocolUpgrader`` and
    ///         the upgrade completion handler. See the documentation on ``NIOHTTPClientUpgradeHandler``
    ///         for more details.
    /// - throws: If the pipeline could not be configured.
    public func addHTTPClientHandlers(position: ChannelPipeline.Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                      enableOutboundHeaderValidation: Bool = true,
                                      withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil) throws {
        try self._addHTTPClientHandlers(position: position,
                                        leftOverBytesStrategy: leftOverBytesStrategy,
                                        enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                                        withClientUpgrade: upgrade)
    }

    private func _addHTTPClientHandlers(position: ChannelPipeline.Position = .last,
                                        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                        enableOutboundHeaderValidation: Bool = true,
                                        withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration? = nil) throws {
        // Why two separate functions? With the fast-path (no upgrader, yes header validator) we can promote the Array of handlers
        // to the stack and skip an allocation.
        if upgrade != nil || enableOutboundHeaderValidation != true {
            try self._addHTTPClientHandlersFallback(position: position,
                                                    leftOverBytesStrategy: leftOverBytesStrategy,
                                                    enableOutboundHeaderValidation: enableOutboundHeaderValidation,
                                                    withClientUpgrade: upgrade)
        } else {
            try self._addHTTPClientHandlers(position: position,
                                            leftOverBytesStrategy: leftOverBytesStrategy)
        }
    }

    private func _addHTTPClientHandlers(position: ChannelPipeline.Position,
                                        leftOverBytesStrategy: RemoveAfterUpgradeStrategy) throws {
        self.eventLoop.assertInEventLoop()
        let requestEncoder = HTTPRequestEncoder()
        let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy: leftOverBytesStrategy)
        let requestHeaderValidator = NIOHTTPRequestHeadersValidator()
        let handlers: [ChannelHandler] = [requestEncoder, ByteToMessageHandler(responseDecoder), requestHeaderValidator]
        try self.addHandlers(handlers, position: position)
    }

    private func _addHTTPClientHandlersFallback(position: ChannelPipeline.Position,
                                                leftOverBytesStrategy: RemoveAfterUpgradeStrategy,
                                                enableOutboundHeaderValidation: Bool,
                                                withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration?) throws {
        self.eventLoop.assertInEventLoop()
        let requestEncoder = HTTPRequestEncoder()
        let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy: leftOverBytesStrategy)
        var handlers: [RemovableChannelHandler] = [requestEncoder, ByteToMessageHandler(responseDecoder)]

        if enableOutboundHeaderValidation {
            handlers.append(NIOHTTPRequestHeadersValidator())
        }

        if let upgrade = upgrade {
            let upgrader = NIOHTTPClientUpgradeHandler(upgraders: upgrade.upgraders,
                                                       httpHandlers: handlers,
                                                       upgradeCompletionHandler: upgrade.completionHandler)
            handlers.append(upgrader)
        }

        try self.addHandlers(handlers, position: position)
    }
    #if swift(>=5.7)
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
    /// - parameters:
    ///     - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///     - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///     - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///     - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    /// - throws: If the pipeline could not be configured.
    @preconcurrency
    public func configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                            withPipeliningAssistance pipelining: Bool = true,
                                            withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                            withErrorHandling errorHandling: Bool = true) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling
        )
    }
    #else
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
    /// - parameters:
    ///     - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///     - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///     - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///     - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    /// - throws: If the pipeline could not be configured.
    public func configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                            withPipeliningAssistance pipelining: Bool = true,
                                            withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                            withErrorHandling errorHandling: Bool = true) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling
        )
    }
    #endif

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
    /// - parameters:
    ///     - position: Where in the pipeline to add the HTTP server handlers, defaults to `.last`.
    ///     - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///     - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPServerProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///     - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `true`.
    ///     - headerValidation: Whether to validate outbound request headers to confirm that they meet
    ///         spec compliance. Defaults to `true`.
    /// - throws: If the pipeline could not be configured.
    public func configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                            withPipeliningAssistance pipelining: Bool = true,
                                            withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                            withErrorHandling errorHandling: Bool = true,
                                            withOutboundHeaderValidation headerValidation: Bool = true) throws {
        try self._configureHTTPServerPipeline(
            position: position,
            withPipeliningAssistance: pipelining,
            withServerUpgrade: upgrade,
            withErrorHandling: errorHandling,
            withOutboundHeaderValidation: headerValidation
        )
    }
    
    private func _configureHTTPServerPipeline(position: ChannelPipeline.Position = .last,
                                              withPipeliningAssistance pipelining: Bool = true,
                                              withServerUpgrade upgrade: NIOHTTPServerUpgradeConfiguration? = nil,
                                              withErrorHandling errorHandling: Bool = true,
                                              withOutboundHeaderValidation headerValidation: Bool = true) throws {
        self.eventLoop.assertInEventLoop()

        let responseEncoder = HTTPResponseEncoder()
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
            let upgrader = HTTPServerUpgradeHandler(upgraders: upgraders,
                                                    httpEncoder: responseEncoder,
                                                    extraHTTPHandlers: Array(handlers.dropFirst()),
                                                    upgradeCompletionHandler: completionHandler)
            handlers.append(upgrader)
        }

        try self.addHandlers(handlers, position: position)
    }
}
