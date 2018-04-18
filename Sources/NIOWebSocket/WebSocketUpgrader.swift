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

import CNIOSHA1
import NIO
import NIOHTTP1

private let magicWebSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

/// Errors that can be thrown by `NIOWebSocket` during protocol upgrade.
public enum NIOWebSocketUpgradeError: Error {
    /// A HTTP header on the upgrade request was invalid.
    case invalidUpgradeHeader

    /// The HTTP request targets a websocket pipeline that does not support
    /// it in some way.
    case unsupportedWebSocketTarget
}

fileprivate extension HTTPHeaders {
    fileprivate func nonListHeader(_ name: String) throws -> String {
        let fields = self[canonicalForm: name]
        guard fields.count == 1 else {
            throw NIOWebSocketUpgradeError.invalidUpgradeHeader
        }
        return fields.first!
    }
}

/// A `HTTPProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// Users may frequently want to offer multiple websocket endpoints on the same port. For this
/// reason, this `WebSocketUpgrader` only knows how to do the required parts of the upgrade and to
/// complete the handshake. Users are expected to provide a callback that examines the HTTP headers
/// (including the path) and determines whether this is a websocket upgrade request that is acceptable
/// to them.
///
/// This upgrader assumes that the `HTTPServerUpgradeHandler` will appropriately mutate the pipeline to
/// remove the HTTP `ChannelHandler`s.
public final class WebSocketUpgrader: HTTPProtocolUpgrader {
    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String = "websocket"

    /// We deliberately do not actually set any required headers here, because the websocket
    /// spec annoyingly does not actually force the client to send these in the Upgrade header,
    /// which NIO requires. We check for these manually.
    public let requiredUpgradeHeaders: [String] = []

    private let shouldUpgrade: (HTTPRequestHead) -> HTTPHeaders?
    private let upgradePipelineHandler: (Channel, HTTPRequestHead) -> EventLoopFuture<Void>
    private let maxFrameSize: Int

    /// Create a new `WebSocketUpgrader`.
    ///
    /// - parameters:
    ///     - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         `nil` if the upgrade should be refused.
    ///     - upgradePipelineHandler: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    ///     - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even allocate a buffer large enough to handle this size), so we
    ///         set a lower one. The default value is the same as the default HTTP/2 max frame
    ///         size, `2**14` bytes. Users may override this to any value up to `UInt32.max`.
    ///         Users are strongly encouraged not to increase this value unless they absolutely
    ///         must, as the decoder will not produce partial frames, meaning that it will hold
    ///         on to data until the *entire* body is received.
    public convenience init(shouldUpgrade: @escaping (HTTPRequestHead) -> HTTPHeaders?,
                upgradePipelineHandler: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<Void>) {
        self.init(maxFrameSize: 1 << 14, shouldUpgrade: shouldUpgrade, upgradePipelineHandler: upgradePipelineHandler)
    }


    /// Create a new `WebSocketUpgrader`.
    ///
    /// - parameters:
    ///     - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even. Users may set this to any value up to `UInt32.max`.
    ///     - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         `nil` if the upgrade should be refused.
    ///     - upgradePipelineHandler: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    public init(maxFrameSize: Int, shouldUpgrade: @escaping (HTTPRequestHead) -> HTTPHeaders?,
                upgradePipelineHandler: @escaping (Channel, HTTPRequestHead) -> EventLoopFuture<Void>) {
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.shouldUpgrade = shouldUpgrade
        self.upgradePipelineHandler = upgradePipelineHandler
        self.maxFrameSize = maxFrameSize
    }

    public func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders {
        let key = try upgradeRequest.headers.nonListHeader("Sec-WebSocket-Key")
        let version = try upgradeRequest.headers.nonListHeader("Sec-WebSocket-Version")

        // The version must be 13.
        guard version == "13" else {
            throw NIOWebSocketUpgradeError.invalidUpgradeHeader
        }

        guard var extraHeaders = self.shouldUpgrade(upgradeRequest) else {
            throw NIOWebSocketUpgradeError.unsupportedWebSocketTarget
        }

        // Cool, we're good to go! Let's do our upgrade. We do this by concatenating the magic
        // GUID to the base64-encoded key and taking a SHA1 hash of the result.
        let acceptValue: String
        do {
            var hasher = SHA1()
            hasher.update(string: key)
            hasher.update(string: magicWebSocketGUID)
            acceptValue = String(base64Encoding: hasher.finish())
        }

        extraHeaders.replaceOrAdd(name: "Upgrade", value: "websocket")
        extraHeaders.add(name: "Sec-WebSocket-Accept", value: acceptValue)
        extraHeaders.replaceOrAdd(name: "Connection", value: "upgrade")

        return extraHeaders
    }

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        return ctx.pipeline.add(handler: WebSocketFrameEncoder()).then {
            ctx.pipeline.add(handler: WebSocketFrameDecoder(maxFrameSize: self.maxFrameSize))
        }.then {
            self.upgradePipelineHandler(ctx.channel, upgradeRequest)
        }
    }
}
