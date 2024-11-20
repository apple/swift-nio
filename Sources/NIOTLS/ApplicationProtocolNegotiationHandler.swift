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

import NIOCore

/// The result of an ALPN negotiation.
///
/// In a system expecting an ALPN negotiation to occur, a wide range of
/// possible things can happen. In the best case scenario it is possible for
/// the server and client to agree on a protocol to speak, in which case this
/// will be `.negotiated` with the relevant protocol provided as the associated
/// value. However, if for any reason it was not possible to negotiate a
/// protocol, whether because one peer didn't support ALPN or because there was no
/// protocol overlap, we should `fallback` to a default choice of some kind.
///
/// Exactly what to do when falling back is the responsibility of a specific
/// implementation.
public enum ALPNResult: Equatable, Sendable {
    /// ALPN negotiation succeeded. The associated value is the ALPN token that
    /// was negotiated.
    case negotiated(String)

    /// ALPN negotiation either failed, or never took place. The application
    /// should fall back to a default protocol choice or close the connection.
    case fallback

    init(negotiated: String?) {
        if let negotiated = negotiated {
            self = .negotiated(negotiated)
        } else {
            self = .fallback
        }
    }
}

/// A helper `ChannelInboundHandler` that makes it easy to swap channel pipelines
/// based on the result of an ALPN negotiation.
///
/// The standard pattern used by applications that want to use ALPN is to select
/// an application protocol based on the result, optionally falling back to some
/// default protocol. To do this in SwiftNIO requires that the channel pipeline be
/// reconfigured based on the result of the ALPN negotiation. This channel handler
/// encapsulates that logic in a generic form that doesn't depend on the specific
/// TLS implementation in use by using `TLSUserEvent`
///
/// The user of this channel handler provides a single closure that is called with
/// an `ALPNResult` when the ALPN negotiation is complete. Based on that result
/// the user is free to reconfigure the `ChannelPipeline` as required, and should
/// return an `EventLoopFuture` that will complete when the pipeline is reconfigured.
///
/// Until the `EventLoopFuture` completes, this channel handler will buffer inbound
/// data. When the `EventLoopFuture` completes, the buffered data will be replayed
/// down the channel. Then, finally, this channel handler will automatically remove
/// itself from the channel pipeline, leaving the pipeline in its final
/// configuration.
public final class ApplicationProtocolNegotiationHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = Any
    public typealias InboundOut = Any

    private let completionHandler: (ALPNResult, Channel) -> EventLoopFuture<Void>
    private var stateMachine = ProtocolNegotiationHandlerStateMachine<Void>()

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    public init(alpnCompleteHandler: @escaping (ALPNResult, Channel) -> EventLoopFuture<Void>) {
        self.completionHandler = alpnCompleteHandler
    }

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    public convenience init(alpnCompleteHandler: @escaping (ALPNResult) -> EventLoopFuture<Void>) {
        self.init { result, _ in
            alpnCompleteHandler(result)
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch self.stateMachine.userInboundEventTriggered(event: event) {
        case .fireUserInboundEventTriggered:
            context.fireUserInboundEventTriggered(event)

        case .invokeUserClosure(let result):
            self.invokeUserClosure(context: context, result: result)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.stateMachine.channelRead(data: data) {
        case .fireChannelRead:
            context.fireChannelRead(data)

        case .none:
            break
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.stateMachine.channelInactive()

        context.fireChannelInactive()
    }

    private func invokeUserClosure(context: ChannelHandlerContext, result: ALPNResult) {
        let switchFuture = self.completionHandler(result, context.channel)

        switchFuture
            .hop(to: context.eventLoop)
            .whenComplete { result in
                self.userFutureCompleted(context: context, result: result)
            }
    }

    private func userFutureCompleted(context: ChannelHandlerContext, result: Result<Void, Error>) {
        switch self.stateMachine.userFutureCompleted(with: result) {
        case .fireErrorCaughtAndRemoveHandler(let error):
            context.fireErrorCaught(error)
            context.pipeline.removeHandler(self, promise: nil)

        case .fireErrorCaughtAndStartUnbuffering(let error):
            context.fireErrorCaught(error)
            self.unbuffer(context: context)

        case .startUnbuffering:
            self.unbuffer(context: context)

        case .removeHandler:
            context.pipeline.removeHandler(self, promise: nil)

        case .none:
            break
        }
    }

    private func unbuffer(context: ChannelHandlerContext) {
        while true {
            switch self.stateMachine.unbuffer() {
            case .fireChannelRead(let data):
                context.fireChannelRead(data)

            case .fireChannelReadCompleteAndRemoveHandler:
                context.fireChannelReadComplete()
                context.pipeline.removeHandler(self, promise: nil)
                return
            }
        }
    }
}

@available(*, unavailable)
extension ApplicationProtocolNegotiationHandler: Sendable {}
