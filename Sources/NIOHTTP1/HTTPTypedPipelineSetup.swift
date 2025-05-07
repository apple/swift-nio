//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

// MARK: - Server pipeline configuration

/// Configuration for an upgradable HTTP pipeline.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult: Sendable>: Sendable {
    /// Whether to provide assistance handling HTTP clients that pipeline
    /// their requests. Defaults to `true`. If `false`, users will need to handle clients that pipeline themselves.
    public var enablePipelining = true

    /// Whether to provide assistance handling protocol errors (e.g. failure to parse the HTTP
    /// request) by sending 400 errors. Defaults to `true`.
    public var enableErrorHandling = true

    /// Whether to validate outbound response headers to confirm that they are
    /// spec compliant. Defaults to `true`.
    public var enableResponseHeaderValidation = true

    /// The configuration for the ``HTTPResponseEncoder``.
    public var encoderConfiguration = HTTPResponseEncoder.Configuration()

    /// The configuration for the ``NIOTypedHTTPServerUpgradeHandler``.
    public var upgradeConfiguration: NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult>

    /// Initializes a new ``NIOUpgradableHTTPServerPipelineConfiguration`` with default values.
    ///
    /// The current defaults provide the following features:
    /// 1. Assistance handling clients that pipeline HTTP requests.
    /// 2. Assistance handling protocol errors.
    /// 3. Outbound header fields validation to protect against response splitting attacks.
    public init(
        upgradeConfiguration: NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult>
    ) {
        self.upgradeConfiguration = upgradeConfiguration
    }
}

extension ChannelPipeline {
    /// Configure a `ChannelPipeline` for use as an HTTP server.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured. The future contains an `EventLoopFuture`
    /// that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPServerPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult>
    ) -> EventLoopFuture<EventLoopFuture<UpgradeResult>> {
        self._configureUpgradableHTTPServerPipeline(
            configuration: configuration
        )
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    private func _configureUpgradableHTTPServerPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult>
    ) -> EventLoopFuture<EventLoopFuture<UpgradeResult>> {
        let future: EventLoopFuture<EventLoopFuture<UpgradeResult>>

        if self.eventLoop.inEventLoop {
            let result = Result<EventLoopFuture<UpgradeResult>, Error> {
                try self.syncOperations.configureUpgradableHTTPServerPipeline(
                    configuration: configuration
                )
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                try self.syncOperations.configureUpgradableHTTPServerPipeline(
                    configuration: configuration
                )
            }
        }

        return future
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Configure a `ChannelPipeline` for use as an HTTP server.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPServerPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult>
    ) throws -> EventLoopFuture<UpgradeResult> {
        self.eventLoop.assertInEventLoop()

        let responseEncoder = HTTPResponseEncoder(configuration: configuration.encoderConfiguration)
        let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))

        var extraHTTPHandlers = [RemovableChannelHandler]()
        extraHTTPHandlers.reserveCapacity(4)
        extraHTTPHandlers.append(requestDecoder)

        try self.addHandler(responseEncoder)
        try self.addHandler(requestDecoder)

        if configuration.enablePipelining {
            let pipeliningHandler = HTTPServerPipelineHandler()
            try self.addHandler(pipeliningHandler)
            extraHTTPHandlers.append(pipeliningHandler)
        }

        if configuration.enableResponseHeaderValidation {
            let headerValidationHandler = NIOHTTPResponseHeadersValidator()
            try self.addHandler(headerValidationHandler)
            extraHTTPHandlers.append(headerValidationHandler)
        }

        if configuration.enableErrorHandling {
            let errorHandler = HTTPServerProtocolErrorHandler()
            try self.addHandler(errorHandler)
            extraHTTPHandlers.append(errorHandler)
        }

        let upgrader = NIOTypedHTTPServerUpgradeHandler(
            httpEncoder: responseEncoder,
            extraHTTPHandlers: extraHTTPHandlers,
            upgradeConfiguration: configuration.upgradeConfiguration
        )
        try self.addHandler(upgrader)

        return upgrader.upgradeResultFuture
    }
}

// MARK: - Client pipeline configuration

/// Configuration for an upgradable HTTP pipeline.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult: Sendable>: Sendable {
    /// The strategy to use when dealing with leftover bytes after removing the ``HTTPDecoder`` from the pipeline.
    public var leftOverBytesStrategy = RemoveAfterUpgradeStrategy.dropBytes

    /// Whether to validate outbound response headers to confirm that they are
    /// spec compliant. Defaults to `true`.
    public var enableOutboundHeaderValidation = true

    /// The configuration for the ``HTTPRequestEncoder``.
    public var encoderConfiguration = HTTPRequestEncoder.Configuration()

    /// The configuration for the ``NIOTypedHTTPClientUpgradeHandler``.
    public var upgradeConfiguration: NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>

    /// Initializes a new ``NIOUpgradableHTTPClientPipelineConfiguration`` with default values.
    ///
    /// The current defaults provide the following features:
    /// 1. Outbound header fields validation to protect against response splitting attacks.
    public init(
        upgradeConfiguration: NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>
    ) {
        self.upgradeConfiguration = upgradeConfiguration
    }
}

extension ChannelPipeline {
    /// Configure a `ChannelPipeline` for use as an HTTP client.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured. The future contains an `EventLoopFuture`
    /// that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPClientPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>
    ) -> EventLoopFuture<EventLoopFuture<UpgradeResult>> {
        self._configureUpgradableHTTPClientPipeline(configuration: configuration)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    private func _configureUpgradableHTTPClientPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>
    ) -> EventLoopFuture<EventLoopFuture<UpgradeResult>> {
        let future: EventLoopFuture<EventLoopFuture<UpgradeResult>>

        if self.eventLoop.inEventLoop {
            let result = Result<EventLoopFuture<UpgradeResult>, Error> {
                try self.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: configuration
                )
            }
            future = self.eventLoop.makeCompletedFuture(result)
        } else {
            future = self.eventLoop.submit {
                try self.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: configuration
                )
            }
        }

        return future
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Configure a `ChannelPipeline` for use as an HTTP client.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPClientPipeline<UpgradeResult: Sendable>(
        configuration: NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>
    ) throws -> EventLoopFuture<UpgradeResult> {
        self.eventLoop.assertInEventLoop()

        let requestEncoder = HTTPRequestEncoder(configuration: configuration.encoderConfiguration)
        let responseDecoder = ByteToMessageHandler(
            HTTPResponseDecoder(leftOverBytesStrategy: configuration.leftOverBytesStrategy)
        )
        var httpHandlers = [RemovableChannelHandler]()
        httpHandlers.reserveCapacity(3)
        httpHandlers.append(requestEncoder)
        httpHandlers.append(responseDecoder)

        try self.addHandler(requestEncoder)
        try self.addHandler(responseDecoder)

        if configuration.enableOutboundHeaderValidation {
            let headerValidationHandler = NIOHTTPRequestHeadersValidator()
            try self.addHandler(headerValidationHandler)
            httpHandlers.append(headerValidationHandler)
        }

        let upgrader = NIOTypedHTTPClientUpgradeHandler(
            httpHandlers: httpHandlers,
            upgradeConfiguration: configuration.upgradeConfiguration
        )
        try self.addHandler(upgrader)

        return upgrader.upgradeResultFuture
    }
}
