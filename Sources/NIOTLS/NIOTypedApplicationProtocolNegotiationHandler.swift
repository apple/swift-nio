//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// A helper `ChannelInboundHandler` that makes it easy to swap channel pipelines
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
/// the user is free to reconfigure the `ChannelPipeline` as required, and should
/// return an `EventLoopFuture` that will complete when the pipeline is reconfigured.
///
/// Until the `EventLoopFuture` completes, this channel handler will buffer inbound
/// data. When the `EventLoopFuture` completes, the buffered data will be replayed
/// down the channel. Then, finally, this channel handler will automatically remove
/// itself from the channel pipeline, leaving the pipeline in its final
/// configuration.
///
/// Importantly, this is a typed variant of the ``ApplicationProtocolNegotiationHandler`` and allows the user to
/// specify a type that must be returned from the supplied closure. The result will then be used to succeed the ``NIOTypedApplicationProtocolNegotiationHandler/protocolNegotiationResult``
/// promise. This allows us to construct pipelines that include protocol negotiation handlers and be able to bridge them into `NIOAsyncChannel`
/// based bootstraps.
@preconcurrency
public final class NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult: Sendable>: ChannelInboundHandler,
    RemovableChannelHandler
{
    public typealias InboundIn = Any

    public typealias InboundOut = Any

    public var protocolNegotiationResult: EventLoopFuture<NegotiationResult> {
        self.negotiatedPromise.futureResult
    }

    private var negotiatedPromise: EventLoopPromise<NegotiationResult> {
        precondition(
            self._negotiatedPromise != nil,
            "Tried to access the protocol negotiation result before the handler was added to a pipeline"
        )
        return self._negotiatedPromise!
    }
    private var _negotiatedPromise: EventLoopPromise<NegotiationResult>?

    private let completionHandler: (ALPNResult, Channel) -> EventLoopFuture<NegotiationResult>
    private var stateMachine = ProtocolNegotiationHandlerStateMachine<NegotiationResult>()

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    public init(alpnCompleteHandler: @escaping (ALPNResult, Channel) -> EventLoopFuture<NegotiationResult>) {
        self.completionHandler = alpnCompleteHandler
    }

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    public convenience init(alpnCompleteHandler: @escaping (ALPNResult) -> EventLoopFuture<NegotiationResult>) {
        self.init { result, _ in
            alpnCompleteHandler(result)
        }
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self._negotiatedPromise = context.eventLoop.makePromise()
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        switch self.stateMachine.handlerRemoved() {
        case .failPromise:
            self.negotiatedPromise.fail(ChannelError.inappropriateOperationForState)

        case .none:
            break
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

        self.negotiatedPromise.fail(ChannelError.outputClosed)
        context.fireChannelInactive()
    }

    private func invokeUserClosure(context: ChannelHandlerContext, result: ALPNResult) {
        let switchFuture = self.completionHandler(result, context.channel)
        let loopBoundSelfAndContext = NIOLoopBound((self, context), eventLoop: context.eventLoop)

        switchFuture
            .hop(to: context.eventLoop)
            .whenComplete { result in
                let (`self`, context) = loopBoundSelfAndContext.value
                self.userFutureCompleted(context: context, result: result)
            }
    }

    private func userFutureCompleted(context: ChannelHandlerContext, result: Result<NegotiationResult, Error>) {
        switch self.stateMachine.userFutureCompleted(with: result) {
        case .fireErrorCaughtAndRemoveHandler(let error):
            self.negotiatedPromise.fail(error)
            context.fireErrorCaught(error)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)

        case .fireErrorCaughtAndStartUnbuffering(let error):
            self.negotiatedPromise.fail(error)
            context.fireErrorCaught(error)
            self.unbuffer(context: context)

        case .startUnbuffering(let value):
            self.negotiatedPromise.succeed(value)
            self.unbuffer(context: context)

        case .removeHandler(let value):
            self.negotiatedPromise.succeed(value)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)

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
                context.pipeline.syncOperations.removeHandler(self, promise: nil)
                return
            }
        }
    }
}

@available(*, unavailable)
extension NIOTypedApplicationProtocolNegotiationHandler: Sendable {}
