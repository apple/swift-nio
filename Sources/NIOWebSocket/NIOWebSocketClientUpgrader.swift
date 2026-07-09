//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1
import _NIOBase64

@available(*, deprecated, renamed: "NIOWebSocketClientUpgrader")
public typealias NIOWebClientSocketUpgrader = NIOWebSocketClientUpgrader

/// A `HTTPClientProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// This upgrader assumes that the `HTTPClientUpgradeHandler` will create and send the upgrade request.
/// This upgrader also assumes that the `HTTPClientUpgradeHandler` will appropriately mutate the
/// pipeline to remove the HTTP `ChannelHandler`s.
public final class NIOWebSocketClientUpgrader: NIOHTTPClientProtocolUpgrader, Sendable {
    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String = "websocket"
    /// None of the websocket headers are actually defined as 'required'.
    public let requiredUpgradeHeaders: [String] = []

    private let requestKey: String
    private let maxFrameSize: Int
    private let automaticErrorHandling: Bool
    private let enforceMaskingRules: Bool
    private let upgradePipelineHandler: @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<Void>

    /// - Parameters:
    ///   - requestKey: sent to the server in the `Sec-WebSocket-Key` HTTP header. Default is random request key.
    ///   - maxFrameSize: largest incoming `WebSocketFrame` size in bytes. Default is 16,384 bytes.
    ///   - automaticErrorHandling: If true, adds `WebSocketProtocolErrorHandler` to the channel pipeline to catch and respond to WebSocket protocol errors. Default is true.
    ///   - upgradePipelineHandler: called once the upgrade was successful
    public convenience init(
        requestKey: String = randomRequestKey(),
        maxFrameSize: Int = 1 << 14,
        automaticErrorHandling: Bool = true,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
    ) {
        self.init(
            requestKey: requestKey,
            maxFrameSize: maxFrameSize,
            automaticErrorHandling: automaticErrorHandling,
            enforceMaskingRules: true,
            upgradePipelineHandler: upgradePipelineHandler
        )
    }

    /// - Parameters:
    ///   - requestKey: sent to the server in the `Sec-WebSocket-Key` HTTP header. Default is random request key.
    ///   - maxFrameSize: largest incoming `WebSocketFrame` size in bytes. Default is 16,384 bytes.
    ///   - automaticErrorHandling: If true, adds `WebSocketProtocolErrorHandler` to the channel pipeline to catch and respond to WebSocket protocol errors. Default is true.
    ///   - enforceMaskingRules: Whether the decoder should reject masked frames from the server, as required by RFC 6455 (§5.1). Set to false to tolerate non-compliant servers that send masked frames.
    ///   - upgradePipelineHandler: called once the upgrade was successful
    public init(
        requestKey: String = randomRequestKey(),
        maxFrameSize: Int = 1 << 14,
        automaticErrorHandling: Bool = true,
        enforceMaskingRules: Bool,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
    ) {
        precondition(requestKey != "", "The request key must contain a valid Sec-WebSocket-Key")
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.requestKey = requestKey
        self.upgradePipelineHandler = upgradePipelineHandler
        self.maxFrameSize = maxFrameSize
        self.automaticErrorHandling = automaticErrorHandling
        self.enforceMaskingRules = enforceMaskingRules
    }

    /// Add additional headers that are needed for a WebSocket upgrade request.
    public func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        _addCustom(upgradeRequestHeaders: &upgradeRequestHeaders, requestKey: self.requestKey)
    }

    public func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        _shouldAllowUpgrade(upgradeResponse: upgradeResponse, requestKey: self.requestKey)
    }

    public func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        _upgrade(
            channel: context.channel,
            upgradeResponse: upgradeResponse,
            maxFrameSize: self.maxFrameSize,
            enableAutomaticErrorHandling: self.automaticErrorHandling,
            maskingVerification: self.enforceMaskingRules ? .clientExpectsUnmaskedFrames : .disabled,
            upgradePipelineHandler: self.upgradePipelineHandler
        )
    }
}

/// A `NIOTypedHTTPClientProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// This upgrader assumes that the `HTTPClientUpgradeHandler` will create and send the upgrade request.
/// This upgrader also assumes that the `HTTPClientUpgradeHandler` will appropriately mutate the
/// pipeline to remove the HTTP `ChannelHandler`s.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public final class NIOTypedWebSocketClientUpgrader<UpgradeResult: Sendable>: NIOTypedHTTPClientProtocolUpgrader {
    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String = "websocket"
    /// None of the websocket headers are actually defined as 'required'.
    public let requiredUpgradeHeaders: [String] = []

    private let requestKey: String
    private let maxFrameSize: Int
    private let enableAutomaticErrorHandling: Bool
    private let enforceMaskingRules: Bool
    private let upgradePipelineHandler: @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<UpgradeResult>

    /// - Parameters:
    ///   - requestKey: Sent to the server in the `Sec-WebSocket-Key` HTTP header. Default is random request key.
    ///   - maxFrameSize: Largest incoming `WebSocketFrame` size in bytes. Default is 16,384 bytes.
    ///   - enableAutomaticErrorHandling: If true, adds `WebSocketProtocolErrorHandler` to the channel pipeline to catch and respond to WebSocket protocol errors. Default is true.
    ///   - upgradePipelineHandler: Called once the upgrade was successful.
    public convenience init(
        requestKey: String = NIOWebSocketClientUpgrader.randomRequestKey(),
        maxFrameSize: Int = 1 << 14,
        enableAutomaticErrorHandling: Bool = true,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<UpgradeResult>
    ) {
        self.init(
            requestKey: requestKey,
            maxFrameSize: maxFrameSize,
            enableAutomaticErrorHandling: enableAutomaticErrorHandling,
            enforceMaskingRules: true,
            upgradePipelineHandler: upgradePipelineHandler
        )
    }

    /// - Parameters:
    ///   - requestKey: Sent to the server in the `Sec-WebSocket-Key` HTTP header. Default is random request key.
    ///   - maxFrameSize: Largest incoming `WebSocketFrame` size in bytes. Default is 16,384 bytes.
    ///   - enableAutomaticErrorHandling: If true, adds `WebSocketProtocolErrorHandler` to the channel pipeline to catch and respond to WebSocket protocol errors. Default is true.
    ///   - enforceMaskingRules: Whether the decoder should reject masked frames from the server, as required by RFC 6455 (§5.1). Set to false to tolerate non-compliant servers that send masked frames.
    ///   - upgradePipelineHandler: Called once the upgrade was successful.
    public init(
        requestKey: String = NIOWebSocketClientUpgrader.randomRequestKey(),
        maxFrameSize: Int = 1 << 14,
        enableAutomaticErrorHandling: Bool = true,
        enforceMaskingRules: Bool,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<UpgradeResult>
    ) {
        precondition(requestKey != "", "The request key must contain a valid Sec-WebSocket-Key")
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.requestKey = requestKey
        self.upgradePipelineHandler = upgradePipelineHandler
        self.maxFrameSize = maxFrameSize
        self.enableAutomaticErrorHandling = enableAutomaticErrorHandling
        self.enforceMaskingRules = enforceMaskingRules
    }

    public func addCustom(upgradeRequestHeaders: inout NIOHTTP1.HTTPHeaders) {
        _addCustom(upgradeRequestHeaders: &upgradeRequestHeaders, requestKey: self.requestKey)
    }

    public func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        _shouldAllowUpgrade(upgradeResponse: upgradeResponse, requestKey: self.requestKey)
    }

    public func upgrade(channel: Channel, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<UpgradeResult> {
        _upgrade(
            channel: channel,
            upgradeResponse: upgradeResponse,
            maxFrameSize: self.maxFrameSize,
            enableAutomaticErrorHandling: self.enableAutomaticErrorHandling,
            maskingVerification: self.enforceMaskingRules ? .clientExpectsUnmaskedFrames : .disabled,
            upgradePipelineHandler: self.upgradePipelineHandler
        )
    }
}

extension NIOWebSocketClientUpgrader {
    /// Generates a random WebSocket Request Key by generating 16 bytes randomly and encoding them as a base64 string as defined in RFC6455 https://tools.ietf.org/html/rfc6455#section-4.1
    /// - Parameter generator: the `RandomNumberGenerator` used as a the source of randomness
    /// - Returns: base64 encoded request key
    @inlinable
    public static func randomRequestKey<Generator>(
        using generator: inout Generator
    ) -> String where Generator: RandomNumberGenerator {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(minimumWritableBytes: 16)
        /// we may want to use `randomBytes(count:)` once the proposal is accepted: https://forums.swift.org/t/pitch-requesting-larger-amounts-of-randomness-from-systemrandomnumbergenerator/27226
        buffer.writeMultipleIntegers(
            UInt64.random(in: UInt64.min...UInt64.max, using: &generator),
            UInt64.random(in: UInt64.min...UInt64.max, using: &generator)
        )
        return String(_base64Encoding: buffer.readableBytesView)
    }
    /// Generates a random WebSocket Request Key by generating 16 bytes randomly using the `SystemRandomNumberGenerator` and encoding them as a base64 string as defined in RFC6455 https://tools.ietf.org/html/rfc6455#section-4.1.
    /// - Returns: base64 encoded request key
    @inlinable
    public static func randomRequestKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return NIOWebSocketClientUpgrader.randomRequestKey(using: &generator)
    }
}

/// Add additional headers that are needed for a WebSocket upgrade request.
private func _addCustom(upgradeRequestHeaders: inout HTTPHeaders, requestKey: String) {
    upgradeRequestHeaders.add(name: "Sec-WebSocket-Key", value: requestKey)
    upgradeRequestHeaders.add(name: "Sec-WebSocket-Version", value: "13")
}

/// Allow or deny the upgrade based on the upgrade HTTP response
/// headers containing the correct accept key.
private func _shouldAllowUpgrade(upgradeResponse: HTTPResponseHead, requestKey: String) -> Bool {
    let acceptValueHeader = upgradeResponse.headers["Sec-WebSocket-Accept"]

    guard acceptValueHeader.count == 1 else {
        return false
    }

    // Validate the response key in 'Sec-WebSocket-Accept'.
    var hasher = SHA1()
    hasher.update(string: requestKey)
    hasher.update(string: magicWebSocketGUID)
    let expectedAcceptValue = String(_base64Encoding: hasher.finish())

    return expectedAcceptValue == acceptValueHeader[0]
}

/// Called when the upgrade response has been flushed and it is safe to mutate the channel
/// pipeline. Adds channel handlers for websocket frame encoding, decoding and errors.
private func _upgrade<UpgradeResult: Sendable>(
    channel: Channel,
    upgradeResponse: HTTPResponseHead,
    maxFrameSize: Int,
    enableAutomaticErrorHandling: Bool,
    maskingVerification: WebSocketMaskingVerification,
    upgradePipelineHandler: @escaping @Sendable (Channel, HTTPResponseHead) -> EventLoopFuture<UpgradeResult>
) -> EventLoopFuture<UpgradeResult> {
    channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(
                WebSocketFrameDecoder(maxFrameSize: maxFrameSize, maskingVerification: maskingVerification)
            )
        )
        if enableAutomaticErrorHandling {
            try channel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler(isServer: false))
        }
    }
    .flatMap {
        upgradePipelineHandler(channel, upgradeResponse)
    }
}
