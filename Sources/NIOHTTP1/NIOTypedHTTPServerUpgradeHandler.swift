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

/// An object that implements `NIOTypedHTTPServerProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol on a server-side channel.
@preconcurrency
public protocol NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>: Sendable {
    associatedtype UpgradeResult: Sendable

    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol needs in the request to successfully upgrade. These header fields
    /// will be provided to the handler when it is asked to handle the upgrade. They will also be validated
    /// against the inbound request's `Connection` header field.
    var requiredUpgradeHeaders: [String] { get }

    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// return a failed future.
    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders>

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required. Until the returned `EventLoopFuture` succeeds, all received
    /// data will be buffered.
    func upgrade(
        channel: Channel,
        upgradeRequest: HTTPRequestHead
    ) -> EventLoopFuture<UpgradeResult>
}

/// The upgrade configuration for the ``NIOTypedHTTPServerUpgradeHandler``.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult: Sendable>: Sendable {
    /// The array of potential upgraders.
    public var upgraders: [any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>]

    /// A closure that is run once it is determined that no protocol upgrade is happening. This can be used
    /// to configure handlers that expect HTTP.
    public var notUpgradingCompletionHandler: @Sendable (Channel) -> EventLoopFuture<UpgradeResult>

    public init(
        upgraders: [any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>],
        notUpgradingCompletionHandler: @Sendable @escaping (Channel) -> EventLoopFuture<UpgradeResult>
    ) {
        self.upgraders = upgraders
        self.notUpgradingCompletionHandler = notUpgradingCompletionHandler
    }
}

/// A server-side channel handler that receives HTTP requests and optionally performs an HTTP-upgrade.
///
/// Removes itself from the channel pipeline after the first inbound request on the connection, regardless of
/// whether the upgrade succeeded or not.
///
/// This handler behaves a bit differently from its Netty counterpart because it does not allow upgrade
/// on any request but the first on a connection. This is primarily to handle clients that pipeline: it's
/// sufficiently difficult to ensure that the upgrade happens at a safe time while dealing with pipelined
/// requests that we choose to punt on it entirely and not allow it. As it happens this is mostly fine:
/// the odds of someone needing to upgrade midway through the lifetime of a connection are very low.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public final class NIOTypedHTTPServerUpgradeHandler<UpgradeResult: Sendable>: ChannelInboundHandler,
    RemovableChannelHandler
{
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private let upgraders: [String: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>]
    private let notUpgradingCompletionHandler: @Sendable (Channel) -> EventLoopFuture<UpgradeResult>
    private let httpEncoder: HTTPResponseEncoder
    private let extraHTTPHandlers: [RemovableChannelHandler]
    private var stateMachine = NIOTypedHTTPServerUpgraderStateMachine<UpgradeResult>()

    private var _upgradeResultPromise: EventLoopPromise<UpgradeResult>?
    private var upgradeResultPromise: EventLoopPromise<UpgradeResult> {
        precondition(
            self._upgradeResultPromise != nil,
            "Tried to access the upgrade result before the handler was added to a pipeline"
        )
        return self._upgradeResultPromise!
    }

    /// The upgrade future which will be completed once protocol upgrading has been done.
    public var upgradeResultFuture: EventLoopFuture<UpgradeResult> {
        self.upgradeResultPromise.futureResult
    }

    /// Create a ``NIOTypedHTTPServerUpgradeHandler``.
    ///
    /// - Parameters:
    ///   - httpEncoder: The ``HTTPResponseEncoder`` encoding responses from this handler and which will
    ///   be removed from the pipeline once the upgrade response is sent. This is used to ensure
    ///   that the pipeline will be in a clean state after upgrade.
    ///   - extraHTTPHandlers: Any other handlers that are directly related to handling HTTP. At the very least
    ///   this should include the `HTTPDecoder`, but should also include any other handler that cannot tolerate
    ///   receiving non-HTTP data.
    ///   - upgradeConfiguration: The upgrade configuration.
    public init(
        httpEncoder: HTTPResponseEncoder,
        extraHTTPHandlers: [RemovableChannelHandler],
        upgradeConfiguration: NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult>
    ) {
        var upgraderMap = [String: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>]()
        for upgrader in upgradeConfiguration.upgraders {
            upgraderMap[upgrader.supportedProtocol.lowercased()] = upgrader
        }
        self.upgraders = upgraderMap
        self.notUpgradingCompletionHandler = upgradeConfiguration.notUpgradingCompletionHandler
        self.httpEncoder = httpEncoder
        self.extraHTTPHandlers = extraHTTPHandlers
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self._upgradeResultPromise = context.eventLoop.makePromise(of: UpgradeResult.self)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        switch self.stateMachine.handlerRemoved() {
        case .failUpgradePromise:
            self.upgradeResultPromise.fail(ChannelError.inappropriateOperationForState)
        case .none:
            break
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.stateMachine.channelReadData(data) {
        case .unwrapData:
            let requestPart = NIOTypedHTTPServerUpgradeHandler.unwrapInboundIn(data)
            self.channelRead(context: context, requestPart: requestPart)

        case .fireChannelRead:
            context.fireChannelRead(data)

        case .none:
            break
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // The remote peer half-closed the channel during the upgrade. Should we close the other side
            switch self.stateMachine.inputClosed() {
            case .close:
                context.close(promise: nil)
                self.upgradeResultPromise.fail(ChannelError.inputClosed)
            case .continue:
                break
            case .fireInputClosedEvent:
                context.fireUserInboundEventTriggered(event)
            }

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func channelRead(context: ChannelHandlerContext, requestPart: HTTPServerRequestPart) {
        switch self.stateMachine.channelReadRequestPart(requestPart) {
        case .failUpgradePromise(let error):
            self.upgradeResultPromise.fail(error)

        case .runNotUpgradingInitializer:
            self.notUpgradingCompletionHandler(context.channel)
                .hop(to: context.eventLoop)
                .assumeIsolated()
                .whenComplete { result in
                    self.upgradingHandlerCompleted(context: context, result, requestHeadAndProtocol: nil)
                }

        case .findUpgrader(let head, let requestedProtocols, let allHeaderNames, let connectionHeader):
            let protocolIterator = requestedProtocols.makeIterator()
            self.handleUpgradeForProtocol(
                context: context,
                protocolIterator: protocolIterator,
                request: head,
                allHeaderNames: allHeaderNames,
                connectionHeader: connectionHeader
            ).whenComplete { result in
                self.findingUpgradeCompleted(context: context, requestHead: head, result)
            }

        case .startUpgrading(let upgrader, let requestHead, let responseHeaders, let proto):
            self.startUpgrading(
                context: context,
                upgrader: upgrader,
                requestHead: requestHead,
                responseHeaders: responseHeaders,
                proto: proto
            )

        case .none:
            break
        }
    }

    private func upgradingHandlerCompleted(
        context: ChannelHandlerContext,
        _ result: Result<UpgradeResult, Error>,
        requestHeadAndProtocol: (HTTPRequestHead, String)?
    ) {
        context.eventLoop.assertInEventLoop()
        switch self.stateMachine.upgradingHandlerCompleted(result) {
        case .fireErrorCaughtAndRemoveHandler(let error):
            self.upgradeResultPromise.fail(error)
            context.fireErrorCaught(error)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)

        case .fireErrorCaughtAndStartUnbuffering(let error):
            self.upgradeResultPromise.fail(error)
            context.fireErrorCaught(error)
            self.unbuffer(context: context)

        case .startUnbuffering(let value):
            if let requestHeadAndProtocol = requestHeadAndProtocol {
                context.fireUserInboundEventTriggered(
                    HTTPServerUpgradeEvents.upgradeComplete(
                        toProtocol: requestHeadAndProtocol.1,
                        upgradeRequest: requestHeadAndProtocol.0
                    )
                )
            }
            self.upgradeResultPromise.succeed(value)
            self.unbuffer(context: context)

        case .removeHandler(let value):
            if let requestHeadAndProtocol = requestHeadAndProtocol {
                context.fireUserInboundEventTriggered(
                    HTTPServerUpgradeEvents.upgradeComplete(
                        toProtocol: requestHeadAndProtocol.1,
                        upgradeRequest: requestHeadAndProtocol.0
                    )
                )
            }
            self.upgradeResultPromise.succeed(value)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)

        case .none:
            break
        }
    }

    /// Attempt to upgrade a single protocol.
    ///
    /// Will recurse through `protocolIterator` if upgrade fails.
    private func handleUpgradeForProtocol(
        context: ChannelHandlerContext,
        protocolIterator: Array<String>.Iterator,
        request: HTTPRequestHead,
        allHeaderNames: Set<String>,
        connectionHeader: Set<String>
    )
        -> EventLoopFuture<
            (
                upgrader: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>,
                responseHeaders: HTTPHeaders,
                proto: String
            )?
        >.Isolated
    {
        // We want a local copy of the protocol iterator. We'll pass it to the next invocation of the function.
        var protocolIterator = protocolIterator
        guard let proto = protocolIterator.next() else {
            // We're done! No suitable protocol for upgrade.
            return context.eventLoop.makeSucceededIsolatedFuture(nil)
        }

        guard let upgrader = self.upgraders[proto.lowercased()] else {
            return self.handleUpgradeForProtocol(
                context: context,
                protocolIterator: protocolIterator,
                request: request,
                allHeaderNames: allHeaderNames,
                connectionHeader: connectionHeader
            )
        }

        let requiredHeaders = Set(upgrader.requiredUpgradeHeaders.map { $0.lowercased() })
        guard requiredHeaders.isSubset(of: allHeaderNames) && requiredHeaders.isSubset(of: connectionHeader) else {
            return self.handleUpgradeForProtocol(
                context: context,
                protocolIterator: protocolIterator,
                request: request,
                allHeaderNames: allHeaderNames,
                connectionHeader: connectionHeader
            )
        }

        let responseHeaders = self.buildUpgradeHeaders(protocol: proto)
        return upgrader.buildUpgradeResponse(
            channel: context.channel,
            upgradeRequest: request,
            initialResponseHeaders: responseHeaders
        )
        .hop(to: context.eventLoop)
        .assumeIsolated()
        .map { (upgrader, $0, proto) }
        .flatMapError { error in
            // No upgrade here. We want to fire the error down the pipeline, and then try another loop iteration.
            context.fireErrorCaught(error)
            return self.handleUpgradeForProtocol(
                context: context,
                protocolIterator: protocolIterator,
                request: request,
                allHeaderNames: allHeaderNames,
                connectionHeader: connectionHeader
            ).nonisolated()
        }
    }

    private func findingUpgradeCompleted(
        context: ChannelHandlerContext,
        requestHead: HTTPRequestHead,
        _ result: Result<
            (
                upgrader: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>,
                responseHeaders: HTTPHeaders,
                proto: String
            )?,
            Error
        >
    ) {
        switch self.stateMachine.findingUpgraderCompleted(requestHead: requestHead, result) {
        case .startUpgrading(let upgrader, let responseHeaders, let proto):
            self.startUpgrading(
                context: context,
                upgrader: upgrader,
                requestHead: requestHead,
                responseHeaders: responseHeaders,
                proto: proto
            )

        case .runNotUpgradingInitializer:
            self.notUpgradingCompletionHandler(context.channel)
                .hop(to: context.eventLoop)
                .assumeIsolated()
                .whenComplete { result in
                    self.upgradingHandlerCompleted(context: context, result, requestHeadAndProtocol: nil)
                }

        case .fireErrorCaughtAndStartUnbuffering(let error):
            self.upgradeResultPromise.fail(error)
            context.fireErrorCaught(error)
            self.unbuffer(context: context)

        case .fireErrorCaughtAndRemoveHandler(let error):
            self.upgradeResultPromise.fail(error)
            context.fireErrorCaught(error)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)

        case .none:
            break
        }
    }

    private func startUpgrading(
        context: ChannelHandlerContext,
        upgrader: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>,
        requestHead: HTTPRequestHead,
        responseHeaders: HTTPHeaders,
        proto: String
    ) {
        // Before we finish the upgrade we have to remove the HTTPDecoder and any other non-Encoder HTTP
        // handlers from the pipeline, to prevent them parsing any more data. We'll buffer the data until
        // that completes.
        // While there are a lot of Futures involved here it's quite possible that all of this code will
        // actually complete synchronously: we just want to program for the possibility that it won't.
        // Once that's done, we send the upgrade response, then remove the HTTP encoder, then call the
        // internal handler, then call the user code, and then finally when the user code is done we do
        // our final cleanup steps, namely we replay the received data we buffered in the meantime and
        // then remove ourselves from the pipeline.
        let channel = context.channel
        let pipeline = context.pipeline

        self.removeExtraHandlers(pipeline: pipeline)
            .assumeIsolated()
            .flatMap {
                self.sendUpgradeResponse(context: context, responseHeaders: responseHeaders)
            }.flatMap {
                pipeline.syncOperations.removeHandler(self.httpEncoder)
            }.flatMap { () -> EventLoopFuture<UpgradeResult> in
                upgrader.upgrade(channel: channel, upgradeRequest: requestHead)
            }
            .whenComplete { result in
                self.upgradingHandlerCompleted(context: context, result, requestHeadAndProtocol: (requestHead, proto))
            }
    }

    /// Sends the 101 Switching Protocols response for the pipeline.
    private func sendUpgradeResponse(
        context: ChannelHandlerContext,
        responseHeaders: HTTPHeaders
    ) -> EventLoopFuture<Void> {
        var response = HTTPResponseHead(version: .http1_1, status: .switchingProtocols)
        response.headers = responseHeaders
        return context.writeAndFlush(wrapOutboundOut(HTTPServerResponsePart.head(response)))
    }

    /// Builds the initial mandatory HTTP headers for HTTP upgrade responses.
    private func buildUpgradeHeaders(`protocol`: String) -> HTTPHeaders {
        HTTPHeaders([("connection", "upgrade"), ("upgrade", `protocol`)])
    }

    /// Removes any extra HTTP-related handlers from the channel pipeline.
    private func removeExtraHandlers(pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        guard self.extraHTTPHandlers.count > 0 else {
            return pipeline.eventLoop.makeSucceededFuture(())
        }

        return .andAllSucceed(
            self.extraHTTPHandlers.map { pipeline.syncOperations.removeHandler($0) },
            on: pipeline.eventLoop
        )
    }

    private func unbuffer(context: ChannelHandlerContext) {
        while true {
            switch self.stateMachine.unbuffer() {
            case .close:
                context.close(promise: nil)

            case .fireChannelRead(let data):
                context.fireChannelRead(data)

            case .fireChannelReadCompleteAndRemoveHandler:
                context.fireChannelReadComplete()
                context.pipeline.syncOperations.removeHandler(self, promise: nil)
                return

            case .fireInputClosedEvent:
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }
        }
    }
}

@available(*, unavailable)
extension NIOTypedHTTPServerUpgradeHandler: Sendable {}
