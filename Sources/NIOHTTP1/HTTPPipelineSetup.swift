//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Configuration required to configure a HTTP client pipeline for upgrade.
///
/// See the documentation for `HTTPClientUpgradeHandler` for details on these
/// properties.
public typealias NIOHTTPClientUpgradeConfiguration = (upgraders: [NIOHTTPClientProtocolUpgrader], completionHandler: (ChannelHandlerContext) -> Void)

/// Configuration required to configure a HTTP server pipeline for upgrade.
///
/// See the documentation for `HTTPServerUpgradeHandler` for details on these
/// properties.
@available(*, deprecated, renamed: "NIOHTTPServerUpgradeConfiguration")
public typealias HTTPUpgradeConfiguration = NIOHTTPServerUpgradeConfiguration

public typealias NIOHTTPServerUpgradeConfiguration = (upgraders: [HTTPServerProtocolUpgrader], completionHandler: (ChannelHandlerContext) -> Void)

extension ChannelPipeline {
    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func addHTTPClientHandlers(position: Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes) -> EventLoopFuture<Void> {
        return self.addHTTPClientHandlers(position: position,
                                          leftOverBytesStrategy: leftOverBytesStrategy,
                                          withClientUpgrade: nil)
    }
    /// Configure a `ChannelPipeline` for use as a HTTP client with a client upgrader configuration.
    ///
    /// - parameters:
    ///     - position: The position in the `ChannelPipeline` where to add the HTTP client handlers. Defaults to `.last`.
    ///     - upgrade: Add a `HTTPClientUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Should be a tuple of an array of `HTTPClientProtocolUpgrader` and
    ///         the upgrade completion handler. See the documentation on `HTTPClientUpgradeHandler`
    ///         for more details.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func addHTTPClientHandlers(position: Position = .last,
                                      leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
                                      withClientUpgrade upgrade: NIOHTTPClientUpgradeConfiguration?) -> EventLoopFuture<Void> {
        
        let requestEncoder = HTTPRequestEncoder()
        let responseDecoder = HTTPResponseDecoder(leftOverBytesStrategy: leftOverBytesStrategy)
        
        var handlers: [RemovableChannelHandler] = [requestEncoder, ByteToMessageHandler(responseDecoder)]
        
        if let (upgraders, completionHandler) = upgrade {
            let upgrader = NIOHTTPClientUpgradeHandler(upgraders: upgraders,
                                                       httpHandlers: handlers,
                                                       upgradeCompletionHandler: completionHandler)
            handlers.append(upgrader)
        }

        return self.addHandlers(handlers, position: position)
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
        let responseEncoder = HTTPResponseEncoder()
        let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: upgrade == nil ? .dropBytes : .forwardBytes)

        var handlers: [RemovableChannelHandler] = [responseEncoder, ByteToMessageHandler(requestDecoder)]

        if pipelining {
            handlers.append(HTTPServerPipelineHandler())
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

        return self.addHandlers(handlers, position: position)
    }
}
