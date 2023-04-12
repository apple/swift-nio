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

@_spi(AsyncChannel) import NIOCore
import DequeModule


@_spi(AsyncChannel)
public final class NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>: ChannelInboundHandler, RemovableChannelHandler, NIOProtocolNegotiationHandler {
    @_spi(AsyncChannel)
    public typealias InboundIn = Any

    @_spi(AsyncChannel)
    public typealias InboundOut = Any

    @_spi(AsyncChannel)
    public var protocolNegotiationResult: EventLoopFuture<NIOProtocolNegotiationResult<NegotiationResult>> {
        self.negotiatedPromise.futureResult
    }

    private let negotiatedPromise: EventLoopPromise<NIOProtocolNegotiationResult<NegotiationResult>>

    private let completionHandler: (ALPNResult, Channel) -> EventLoopFuture<NIOProtocolNegotiationResult<NegotiationResult>>
    private var hasSeenTLSEvent = false
    private var eventBuffer = Deque<NIOAny>()

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    @_spi(AsyncChannel)
    public init(eventLoop: EventLoop, alpnCompleteHandler: @escaping (ALPNResult, Channel) -> EventLoopFuture<NIOProtocolNegotiationResult<NegotiationResult>>) {
        self.completionHandler = alpnCompleteHandler
        self.negotiatedPromise = eventLoop.makePromise(of: NIOProtocolNegotiationResult<NegotiationResult>.self)
    }

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    @_spi(AsyncChannel)
    public convenience init(eventLoop: EventLoop, alpnCompleteHandler: @escaping (ALPNResult) -> EventLoopFuture<NIOProtocolNegotiationResult<NegotiationResult>>) {
        self.init(eventLoop: eventLoop) { result, _ in
            alpnCompleteHandler(result)
        }
    }

    @_spi(AsyncChannel)
    public func channelInactive(context: ChannelHandlerContext) {
        self.negotiatedPromise.fail(ChannelError.outputClosed)
        context.fireChannelInactive()
    }

    @_spi(AsyncChannel)
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let tlsEvent = event as? TLSUserEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        if case .handshakeCompleted(let p) = tlsEvent {
            self.handshakeCompleted(context: context, negotiatedProtocol: p)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    @_spi(AsyncChannel)
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if self.hasSeenTLSEvent {
            self.eventBuffer.append(data)
        } else {
            // We are being defensive here and just forward every read we get before we receive
            // a TLSEvent. We really don't know what types these reads are and can't do much with them
            context.fireChannelRead(data)
        }
    }

    private func handshakeCompleted(context: ChannelHandlerContext, negotiatedProtocol: String?) {
        self.hasSeenTLSEvent = true

        let result: ALPNResult
        if let negotiatedProtocol = negotiatedProtocol {
            result = .negotiated(negotiatedProtocol)
        } else {
            result = .fallback
        }

        let switchFuture = self.completionHandler(result, context.channel)
        switchFuture
            .whenComplete { result in
                // We must be in the event loop here to make sure no hops have happened
                context.eventLoop.preconditionInEventLoop()


                switch result {
                case .success(let success):
                    // We first complete the negotiated promise and then unbuffer
                    // This allows the users to setup their consumption.
                    self.negotiatedPromise.succeed(success)
                    self.unbuffer(context: context)
                    context.pipeline.removeHandler(self, promise: nil)

                case .failure(let error):
                    self.negotiatedPromise.fail(error)
                    context.pipeline.fireErrorCaught(error)
                    self.unbuffer(context: context)
                    context.pipeline.removeHandler(self, promise: nil)
                }
            }
    }

    private func unbuffer(context: ChannelHandlerContext) {
        // First we check if we have anything to unbuffer
        guard !self.eventBuffer.isEmpty else {
            return
        }

        // Now we unbuffer until there is nothing left.
        // Importantly firing a channel read can lead to new reads being buffered due to reentrancy!
        while let datum = self.eventBuffer.popFirst() {
            context.fireChannelRead(datum)
        }

        context.fireChannelReadComplete()
    }
}

#if swift(>=5.6)
@available(*, unavailable)
extension NIOTypedApplicationProtocolNegotiationHandler: Sendable {}
#endif
