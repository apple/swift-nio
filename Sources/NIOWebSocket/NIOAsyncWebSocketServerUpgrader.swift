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

#if compiler(>=5.5) && canImport(_Concurrency)

import NIOCore
import NIOHTTP1

/// A `HTTPServerProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// Users may frequently want to offer multiple websocket endpoints on the same port. For this
/// reason, this `NIOAsyncWebServerSocketUpgrader` only knows how to do the required parts of the upgrade and to
/// complete the handshake. Users are expected to provide a callback that examines the HTTP headers
/// (including the path) and determines whether this is a websocket upgrade request that is acceptable
/// to them.
///
/// This upgrader assumes that the `HTTPServerUpgradeHandler` will appropriately mutate the pipeline to
/// remove the HTTP `ChannelHandler`s.
@available(macOS 12, iOS 15, watchOS 8, tvOS 15, *)
public final class NIOAsyncWebSocketServerUpgrader: AsyncHTTPServerProtocolUpgrader {
    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String = "websocket"

    /// We deliberately do not actually set any required headers here, because the websocket
    /// spec annoyingly does not actually force the client to send these in the Upgrade header,
    /// which NIO requires. We check for these manually.
    public let requiredUpgradeHeaders: [String] = []

    private let shouldUpgrade: (Channel, HTTPRequestHead) async throws -> HTTPHeaders?
    private let upgradePipelineHandler: (Channel, HTTPRequestHead) async throws -> Void
    private let maxFrameSize: Int
    private let automaticErrorHandling: Bool

    /// Create a new `NIOWebSocketServerUpgrader`.
    ///
    /// - parameters:
    ///     - automaticErrorHandling: Whether the pipeline should automatically handle protocol
    ///         errors by sending error responses and closing the connection. Defaults to `true`,
    ///         may be set to `false` if the user wishes to handle their own errors.
    ///     - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         an `EventLoopFuture` containing `nil` if the upgrade should be refused.
    ///     - upgradePipelineHandler: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    public convenience init(automaticErrorHandling: Bool = true, shouldUpgrade: @escaping (Channel, HTTPRequestHead) async throws -> HTTPHeaders?,
                upgradePipelineHandler: @escaping (Channel, HTTPRequestHead) async throws -> Void) {
        self.init(maxFrameSize: 1 << 14, automaticErrorHandling: automaticErrorHandling,
                  shouldUpgrade: shouldUpgrade, upgradePipelineHandler: upgradePipelineHandler)
    }


    /// Create a new `NIOWebSocketServerUpgrader`.
    ///
    /// - parameters:
    ///     - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even. Users may set this to any value up to `UInt32.max`.
    ///     - automaticErrorHandling: Whether the pipeline should automatically handle protocol
    ///         errors by sending error responses and closing the connection. Defaults to `true`,
    ///         may be set to `false` if the user wishes to handle their own errors.
    ///     - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         an `EventLoopFuture` containing `nil` if the upgrade should be refused.
    ///     - upgradePipelineHandler: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    public init(maxFrameSize: Int, automaticErrorHandling: Bool = true, shouldUpgrade: @escaping (Channel, HTTPRequestHead) async throws -> HTTPHeaders?,
                upgradePipelineHandler: @escaping (Channel, HTTPRequestHead) async throws -> Void) {
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.shouldUpgrade = shouldUpgrade
        self.upgradePipelineHandler = upgradePipelineHandler
        self.maxFrameSize = maxFrameSize
        self.automaticErrorHandling = automaticErrorHandling
    }

    public func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) async throws -> HTTPHeaders {
        let key = try NIOWebsocketServerUpgraderLogic.getWebsocketKeyAndCheckVersion(from: upgradeRequest)

        guard var extraHeaders = try await self.shouldUpgrade(channel, upgradeRequest) else {
            throw NIOWebSocketUpgradeError.unsupportedWebSocketTarget
        }

        NIOWebsocketServerUpgraderLogic.generateUpgradeHeaders(key: key, headers: &extraHeaders)
        return extraHeaders
    }

    public func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) async throws {
        /// We never use the automatic error handling feature of the WebSocketFrameDecoder: we always use the separate channel
        /// handler.
        try await context.pipeline.addHandler(WebSocketFrameEncoder())
        try await context.pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: self.maxFrameSize)))

        if self.automaticErrorHandling {
            try await context.pipeline.addHandler(WebSocketProtocolErrorHandler())
        }
        
        return try await self.upgradePipelineHandler(context.channel, upgradeRequest)
    }
}

#endif
