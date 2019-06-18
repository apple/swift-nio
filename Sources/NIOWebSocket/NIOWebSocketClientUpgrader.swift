//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1

/// A `HTTPClientProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// This upgrader assumes that the `HTTPClientUpgradeHandler` will create and send the upgrade request. 
/// This upgrader also assumes that the `HTTPClientUpgradeHandler` will appropriately mutate the
/// pipeline to remove the HTTP `ChannelHandler`s.
public final class NIOWebClientSocketUpgrader: NIOHTTPClientProtocolUpgrader {
    
    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public var supportedProtocol: String = "websocket"
    /// None of the websocket headers are actually defined as 'required'.
    public var requiredUpgradeHeaders: [String] = []
    
    private let requestKey: String
    private let maxFrameSize: Int
    private let automaticErrorHandling: Bool
    private let upgradePipelineHandler: (Channel, HTTPResponseHead) -> EventLoopFuture<Void>
    
    public init(requestKey: String,
                maxFrameSize: Int = 1 << 14,
                automaticErrorHandling: Bool = true,
                upgradePipelineHandler: @escaping (Channel, HTTPResponseHead) -> EventLoopFuture<Void>) {

        precondition(requestKey != "", "The request key must contain a valid Sec-WebSocket-Key")
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.requestKey = requestKey
        self.upgradePipelineHandler = upgradePipelineHandler
        self.maxFrameSize = maxFrameSize
        self.automaticErrorHandling = automaticErrorHandling
    }

    public func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        upgradeRequestHeaders.add(name: "Sec-WebSocket-Key", value: self.requestKey)
        upgradeRequestHeaders.add(name: "Sec-WebSocket-Version", value: "13")
    }

    public func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        
        let acceptValueHeader = upgradeResponse.headers["Sec-WebSocket-Accept"]

        guard acceptValueHeader.count == 1 else {
            return false
        }

        // Validate the response key in 'Sec-WebSocket-Accept'.
        let expectedAcceptValue: String
        do {
            var hasher = SHA1()
            hasher.update(string: self.requestKey)
            hasher.update(string: magicWebSocketGUID)
            expectedAcceptValue = String(base64Encoding: hasher.finish())
        }

        return expectedAcceptValue == acceptValueHeader[0]
    }

    public func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {

        var upgradeFuture = context.pipeline.addHandler(WebSocketFrameEncoder()).flatMap {_ in
            context.pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: self.maxFrameSize)))
        }
        
        if self.automaticErrorHandling {
            upgradeFuture = upgradeFuture.flatMap { context.pipeline.addHandler(WebSocketProtocolErrorHandler())
            }
        }
        
        return upgradeFuture.flatMap { _ in
            self.upgradePipelineHandler(context.channel, upgradeResponse)
        }
    }
}
