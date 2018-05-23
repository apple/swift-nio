//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Configuration required to configure a HTTP pipeline for upgrade.
///
/// See the documentation for `HTTPServerUpgradeHandler` for details on these
/// properties.
public typealias HTTPUpgradeConfiguration = (upgraders: [HTTPProtocolUpgrader], completionHandler: (ChannelHandlerContext) -> Void)

public extension ChannelPipeline {
    /// Configure a `ChannelPipeline` for use as a HTTP server.
    ///
    /// - parameters:
    ///     - first: Whether to add the HTTP server at the head of the channel pipeline,
    ///              or at the tail.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @available(*, deprecated, message: "Please use configureHTTPServerPipeline")
    public func addHTTPServerHandlers(first: Bool = false) -> EventLoopFuture<Void> {
        return addHandlers(HTTPResponseEncoder(), HTTPRequestDecoder(), first: first)
    }

    /// Configure a `ChannelPipeline` for use as a HTTP client.
    ///
    /// - parameters:
    ///     - first: Whether to add the HTTP client at the head of the channel pipeline,
    ///              or at the tail.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func addHTTPClientHandlers(first: Bool = false) -> EventLoopFuture<Void> {
        return addHandlers(HTTPRequestEncoder(), HTTPResponseDecoder(), first: first)
    }

    /// Configure a `ChannelPipeline` for use as a HTTP server that can perform a HTTP
    /// upgrade to a non-HTTP protocol: that is, after upgrade the channel pipeline must
    /// have none of the handlers added by this function in it.
    ///
    /// - parameters:
    ///     - first: Whether to add the HTTP server at the head of the channel pipeline,
    ///              or at the tail.
    ///     - upgraders: The HTTP protocol upgraders to offer.
    ///     - upgradeCompletionHandler: A block that will be fired when the HTTP upgrade is
    ///                                 complete.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    @available(*, deprecated, message: "Please use configureHTTPServerPipeline")
    public func addHTTPServerHandlersWithUpgrader(first: Bool = false,
                                                  upgraders: [HTTPProtocolUpgrader],
                                                  _ upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) -> EventLoopFuture<Void> {
        let responseEncoder = HTTPResponseEncoder()
        let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
        let upgrader = HTTPServerUpgradeHandler(upgraders: upgraders,
                                                httpEncoder: responseEncoder,
                                                extraHTTPHandlers: [requestDecoder],
                                                upgradeCompletionHandler: upgradeCompletionHandler)
        return addHandlers(responseEncoder, requestDecoder, upgrader, first: first)
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
    ///     - first: Whether to add the HTTP server at the head of the channel pipeline,
    ///         or at the tail.
    ///     - pipelining: Whether to provide assistance handling HTTP clients that pipeline
    ///         their requests. Defaults to `true`. If `false`, users will need to handle
    ///         clients that pipeline themselves.
    ///     - upgrade: Whether to add a `HTTPServerUpgradeHandler` to the pipeline, configured for
    ///         HTTP upgrade. Defaults to `nil`, which will not add the handler to the pipeline. If
    ///         provided should be a tuple of an array of `HTTPProtocolUpgrader` and the upgrade
    ///         completion handler. See the documentation on `HTTPServerUpgradeHandler` for more
    ///         details.
    ///     - errorHandling: Whether to provide assistance handling protocol errors (e.g.
    ///         failure to parse the HTTP request) by sending 400 errors. Defaults to `false` for
    ///         backward-compatibility reasons.
    /// - returns: An `EventLoopFuture` that will fire when the pipeline is configured.
    public func configureHTTPServerPipeline(first: Bool = false,
                                            withPipeliningAssistance pipelining: Bool = true,
                                            withServerUpgrade upgrade: HTTPUpgradeConfiguration? = nil,
                                            withErrorHandling errorHandling: Bool = false) -> EventLoopFuture<Void> {
        let responseEncoder = HTTPResponseEncoder()
        let requestDecoder = HTTPRequestDecoder(leftOverBytesStrategy: upgrade == nil ? .dropBytes : .forwardBytes)

        var handlers: [ChannelHandler] = [responseEncoder, requestDecoder]

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

        return self.addHandlers(handlers, first: first)
    }
}

