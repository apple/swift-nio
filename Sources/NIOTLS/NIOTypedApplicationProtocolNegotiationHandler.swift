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

/// A helper ``ChannelInboundHandler`` that makes it easy to swap channel pipelines
/// based on the result of an ALPN negotiation.
///
/// The standard pattern used by applications that want to use ALPN is to select
/// an application protocol based on the result, optionally falling back to some
/// default protocol. To do this in SwiftNIO requires that the channel pipeline be
/// reconfigured based on the result of the ALPN negotiation. This channel handler
/// encapsulates that logic in a generic form that doesn't depend on the specific
/// TLS implementation in use by using ``TLSUserEvent``
///
/// The user of this channel handler provides a single closure that is called with
/// an ``ALPNResult`` when the ALPN negotiation is complete. Based on that result
/// the user is free to reconfigure the ``ChannelPipeline`` as required, and should
/// return an ``EventLoopFuture`` that will complete when the pipeline is reconfigured.
///
/// Until the ``EventLoopFuture`` completes, this channel handler will buffer inbound
/// data. When the ``EventLoopFuture`` completes, the buffered data will be replayed
/// down the channel. Then, finally, this channel handler will automatically remove
/// itself from the channel pipeline, leaving the pipeline in its final
/// configuration.
///
/// Importantly, this is a typed variant of the ``ApplicationProtocolNegotiationHandler`` and allows the user to
/// specify a type that must be returned from the supplied closure. The result will then be used to succeed the ``NIOTypedApplicationProtocolNegotiationHandler/protocolNegotiationResult``
/// promise. This allows us to construct pipelines that include protocol negotiation handlers and be able to bridge them into ``NIOAsyncChannel``
/// based bootstraps.
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
    private var stateMachine = ProtocolNegotiationHandlerStateMachine<NIOProtocolNegotiationResult<NegotiationResult>>()

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
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch self.stateMachine.userInboundEventTriggered(event: event) {
        case .fireUserInboundEventTriggered:
            context.fireUserInboundEventTriggered(event)

        case .invokeUserClosure(let result):
            self.invokeUserClosure(context: context, result: result)
        }
    }

    @_spi(AsyncChannel)
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.stateMachine.channelRead(data: data) {
        case .fireChannelRead:
            context.fireChannelRead(data)

        case .none:
            break
        }
    }

    @_spi(AsyncChannel)
    public func channelInactive(context: ChannelHandlerContext) {
        self.stateMachine.channelInactive()
        
        self.negotiatedPromise.fail(ChannelError.outputClosed)
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

    private func userFutureCompleted(context: ChannelHandlerContext, result: Result<NIOProtocolNegotiationResult<NegotiationResult>, Error>) {
        switch self.stateMachine.userFutureCompleted(with: result) {
        case .fireErrorCaughtAndRemoveHandler(let error):
            self.negotiatedPromise.fail(error)
            context.fireErrorCaught(error)
            context.pipeline.removeHandler(self, promise: nil)

        case .fireErrorCaughtAndStartUnbuffering(let error):
            self.negotiatedPromise.fail(error)
            context.fireErrorCaught(error)
            self.unbuffer(context: context)

        case .startUnbuffering(let value):
            self.negotiatedPromise.succeed(value)
            self.unbuffer(context: context)

        case .removeHandler(let value):
            self.negotiatedPromise.succeed(value)
            context.pipeline.removeHandler(self, promise: nil)
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
extension NIOTypedApplicationProtocolNegotiationHandler: Sendable {}
