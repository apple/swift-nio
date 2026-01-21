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

import CNIOSHA1
import NIOCore
import NIOHTTP1
import _NIOBase64

let magicWebSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

@available(*, deprecated, renamed: "NIOWebSocketServerUpgrader")
public typealias WebSocketUpgrader = NIOWebSocketServerUpgrader

/// Errors that can be thrown by `NIOWebSocket` during protocol upgrade.
public struct NIOWebSocketUpgradeError: Error, Equatable {
    private enum ActualError {
        case invalidUpgradeHeader
        case unsupportedWebSocketTarget
    }

    private let actualError: ActualError

    private init(actualError: ActualError) {
        self.actualError = actualError
    }
    /// A HTTP header on the upgrade request was invalid.
    public static let invalidUpgradeHeader = NIOWebSocketUpgradeError(actualError: .invalidUpgradeHeader)

    /// The HTTP request targets a websocket pipeline that does not support
    /// it in some way.
    public static let unsupportedWebSocketTarget = NIOWebSocketUpgradeError(actualError: .unsupportedWebSocketTarget)
}

extension HTTPHeaders {
    fileprivate func nonListHeader(_ name: String) throws -> String {
        let fields = self[canonicalForm: name]
        guard fields.count == 1 else {
            throw NIOWebSocketUpgradeError.invalidUpgradeHeader
        }
        return String(fields.first!)
    }
}

/// A `HTTPServerProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// Users may frequently want to offer multiple websocket endpoints on the same port. For this
/// reason, this `WebServerSocketUpgrader` only knows how to do the required parts of the upgrade and to
/// complete the handshake. Users are expected to provide a callback that examines the HTTP headers
/// (including the path) and determines whether this is a websocket upgrade request that is acceptable
/// to them.
///
/// This upgrader assumes that the `HTTPServerUpgradeHandler` will appropriately mutate the pipeline to
/// remove the HTTP `ChannelHandler`s.
public final class NIOWebSocketServerUpgrader: HTTPServerProtocolUpgrader, Sendable {

    private typealias ShouldUpgrade = @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
    private typealias UpgradePipelineHandler = @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<Void>
    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String = "websocket"

    /// We deliberately do not actually set any required headers here, because the websocket
    /// spec annoyingly does not actually force the client to send these in the Upgrade header,
    /// which NIO requires. We check for these manually.
    public let requiredUpgradeHeaders: [String] = []

    private let shouldUpgrade: ShouldUpgrade
    private let upgradePipelineHandler: UpgradePipelineHandler
    private let maxFrameSize: Int
    private let automaticErrorHandling: Bool

    /// Create a new `NIOWebSocketServerUpgrader`.
    ///
    /// - Parameters:
    ///   - automaticErrorHandling: Whether the pipeline should automatically handle protocol
    ///         errors by sending error responses and closing the connection. Defaults to `true`,
    ///         may be set to `false` if the user wishes to handle their own errors.
    ///   - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         an `EventLoopFuture` containing `nil` if the upgrade should be refused.
    ///   - upgradePipelineHandler: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    @preconcurrency
    public convenience init(
        automaticErrorHandling: Bool = true,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<Void>
    ) {
        self.init(
            maxFrameSize: 1 << 14,
            automaticErrorHandling: automaticErrorHandling,
            shouldUpgrade: shouldUpgrade,
            upgradePipelineHandler: upgradePipelineHandler
        )
    }

    /// Create a new `NIOWebSocketServerUpgrader`.
    ///
    /// - Parameters:
    ///   - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even. Users may set this to any value up to `UInt32.max`.
    ///   - automaticErrorHandling: Whether the pipeline should automatically handle protocol
    ///         errors by sending error responses and closing the connection. Defaults to `true`,
    ///         may be set to `false` if the user wishes to handle their own errors.
    ///   - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         an `EventLoopFuture` containing `nil` if the upgrade should be refused.
    ///   - upgradePipelineHandler: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    @preconcurrency
    public convenience init(
        maxFrameSize: Int,
        automaticErrorHandling: Bool = true,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<Void>
    ) {
        self.init(
            _maxFrameSize: maxFrameSize,
            automaticErrorHandling: automaticErrorHandling,
            shouldUpgrade: shouldUpgrade,
            upgradePipelineHandler: upgradePipelineHandler
        )
    }

    private init(
        _maxFrameSize maxFrameSize: Int,
        automaticErrorHandling: Bool,
        shouldUpgrade: @escaping ShouldUpgrade,
        upgradePipelineHandler: @escaping UpgradePipelineHandler
    ) {
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.shouldUpgrade = shouldUpgrade
        self.upgradePipelineHandler = upgradePipelineHandler
        self.maxFrameSize = maxFrameSize
        self.automaticErrorHandling = automaticErrorHandling
    }

    public func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        _buildUpgradeResponse(
            channel: channel,
            upgradeRequest: upgradeRequest,
            initialResponseHeaders: initialResponseHeaders,
            shouldUpgrade: self.shouldUpgrade
        )
    }

    public func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        _upgrade(
            channel: context.channel,
            upgradeRequest: upgradeRequest,
            maxFrameSize: self.maxFrameSize,
            automaticErrorHandling: self.automaticErrorHandling,
            upgradePipelineHandler: self.upgradePipelineHandler
        )
    }
}

/// A `NIOTypedHTTPServerProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// Users may frequently want to offer multiple websocket endpoints on the same port. For this
/// reason, this `WebServerSocketUpgrader` only knows how to do the required parts of the upgrade and to
/// complete the handshake. Users are expected to provide a callback that examines the HTTP headers
/// (including the path) and determines whether this is a websocket upgrade request that is acceptable
/// to them.
///
/// This upgrader assumes that the `HTTPServerUpgradeHandler` will appropriately mutate the pipeline to
/// remove the HTTP `ChannelHandler`s.
public final class NIOTypedWebSocketServerUpgrader<UpgradeResult: Sendable>: NIOTypedHTTPServerProtocolUpgrader,
    Sendable
{
    private typealias ShouldUpgrade = @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
    private typealias UpgradePipelineHandler = @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<UpgradeResult>

    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String = "websocket"

    /// We deliberately do not actually set any required headers here, because the websocket
    /// spec annoyingly does not actually force the client to send these in the Upgrade header,
    /// which NIO requires. We check for these manually.
    public let requiredUpgradeHeaders: [String] = []

    private let shouldUpgrade: ShouldUpgrade
    private let upgradePipelineHandler: UpgradePipelineHandler
    private let maxFrameSize: Int
    private let enableAutomaticErrorHandling: Bool

    /// Create a new ``NIOTypedWebSocketServerUpgrader``.
    ///
    /// - Parameters:
    ///   - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even. Users may set this to any value up to `UInt32.max`.
    ///   - enableAutomaticErrorHandling: Whether the pipeline should automatically handle protocol
    ///         errors by sending error responses and closing the connection. Defaults to `true`,
    ///         may be set to `false` if the user wishes to handle their own errors.
    ///   - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         an `EventLoopFuture` containing `nil` if the upgrade should be refused.
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.to WebSocket protocol errors. Default is true.
    ///   - upgradePipelineHandler: called once the upgrade was successful.
    public init(
        maxFrameSize: Int = 1 << 14,
        enableAutomaticErrorHandling: Bool = true,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<UpgradeResult>
    ) {
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.shouldUpgrade = shouldUpgrade
        self.upgradePipelineHandler = upgradePipelineHandler
        self.maxFrameSize = maxFrameSize
        self.enableAutomaticErrorHandling = enableAutomaticErrorHandling
    }

    public func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        _buildUpgradeResponse(
            channel: channel,
            upgradeRequest: upgradeRequest,
            initialResponseHeaders: initialResponseHeaders,
            shouldUpgrade: self.shouldUpgrade
        )
    }

    public func upgrade(channel: Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<UpgradeResult> {
        _upgrade(
            channel: channel,
            upgradeRequest: upgradeRequest,
            maxFrameSize: self.maxFrameSize,
            automaticErrorHandling: self.enableAutomaticErrorHandling,
            upgradePipelineHandler: self.upgradePipelineHandler
        )
    }
}

private func _buildUpgradeResponse(
    channel: Channel,
    upgradeRequest: HTTPRequestHead,
    initialResponseHeaders: HTTPHeaders,
    shouldUpgrade: @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
) -> EventLoopFuture<HTTPHeaders> {
    let key: String
    let version: String

    do {
        key = try upgradeRequest.headers.nonListHeader("Sec-WebSocket-Key")
        version = try upgradeRequest.headers.nonListHeader("Sec-WebSocket-Version")
    } catch {
        return channel.eventLoop.makeFailedFuture(error)
    }

    // The version must be 13.
    guard version == "13" else {
        return channel.eventLoop.makeFailedFuture(NIOWebSocketUpgradeError.invalidUpgradeHeader)
    }

    return shouldUpgrade(channel, upgradeRequest)
        .flatMapThrowing { extraHeaders in
            guard var extraHeaders = extraHeaders else {
                throw NIOWebSocketUpgradeError.unsupportedWebSocketTarget
            }

            // Cool, we're good to go! Let's do our upgrade. We do this by concatenating the magic
            // GUID to the base64-encoded key and taking a SHA1 hash of the result.
            let acceptValue: String
            do {
                var hasher = SHA1()
                hasher.update(string: key)
                hasher.update(string: magicWebSocketGUID)
                acceptValue = String(_base64Encoding: hasher.finish())
            }

            extraHeaders.replaceOrAdd(name: "Upgrade", value: "websocket")
            extraHeaders.add(name: "Sec-WebSocket-Accept", value: acceptValue)
            extraHeaders.replaceOrAdd(name: "Connection", value: "upgrade")

            return extraHeaders
        }
}

private func _upgrade<UpgradeResult: Sendable>(
    channel: Channel,
    upgradeRequest: HTTPRequestHead,
    maxFrameSize: Int,
    automaticErrorHandling: Bool,
    upgradePipelineHandler: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<UpgradeResult>
) -> EventLoopFuture<UpgradeResult> {
    /// We never use the automatic error handling feature of the WebSocketFrameDecoder: we always use the separate channel
    /// handler.
    channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: maxFrameSize))
        )

        if automaticErrorHandling {
            try channel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler())
        }
    }.flatMap {
        upgradePipelineHandler(channel, upgradeRequest)
    }
}
