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

public enum ALPNResult: Equatable {
    case negotiated(String)
    case fallback

    public static func ==(lhs: ALPNResult, rhs: ALPNResult) -> Bool {
        switch (lhs, rhs) {
        case (.negotiated(let p1), .negotiated(let p2)):
            return p1 == p2
        case (.fallback, .fallback):
            return true
        default:
            return false
        }
    }
}

public class ApplicationProtocolNegotiationHandler: ChannelInboundHandler {
    public typealias InboundIn = Any
    public typealias InboundOut = Any
    public typealias InboundUserEventIn = TLSUserEvent

    private let completionHandler: (ALPNResult) -> EventLoopFuture<Void>
    private var waitingForUser: Bool
    private var eventBuffer: [NIOAny]

    public init(alpnCompleteHandler: @escaping (ALPNResult) -> EventLoopFuture<Void>) {
        self.completionHandler = alpnCompleteHandler
        self.waitingForUser = false
        self.eventBuffer = []
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        guard let tlsEvent = tryUnwrapInboundUserEventIn(event) else {
            ctx.fireUserInboundEventTriggered(event: event)
            return
        }

        switch tlsEvent {
        case .handshakeCompleted(let p):
            handshakeCompleted(context: ctx, negotiatedProtocol: p)
        default:
            ctx.fireUserInboundEventTriggered(event: event)
        }
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if waitingForUser {
            eventBuffer.append(data)
        } else {
            ctx.fireChannelRead(data: data)
        }
    }

    private func handshakeCompleted(context: ChannelHandlerContext, negotiatedProtocol: String?) {
        waitingForUser = true

        let result: ALPNResult
        if let negotiatedProtocol = negotiatedProtocol {
            result = .negotiated(negotiatedProtocol)
        } else {
            result = .fallback
        }

        let switchFuture = completionHandler(result)
        switchFuture.whenComplete { _ in
            self.unbuffer(context: context)
            _ = context.pipeline?.remove(handler: self)
        }
    }

    private func unbuffer(context: ChannelHandlerContext) {
        for datum in eventBuffer {
            context.fireChannelRead(data: datum)
        }
        let buffer = eventBuffer
        eventBuffer = []
        waitingForUser = false
        if buffer.count > 0 {
            context.fireChannelReadComplete()
        }
    }
}
