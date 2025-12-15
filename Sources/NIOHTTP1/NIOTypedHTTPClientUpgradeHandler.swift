//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

/// An object that implements `NIOTypedHTTPClientProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol on a client-side channel.
/// It has the option of denying this upgrade based upon the server response.
@preconcurrency
public protocol NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>: Sendable {
    associatedtype UpgradeResult: Sendable

    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol requires in the request to successfully upgrade.
    /// These header fields will be added to the outbound request's "Connection" header field.
    /// It is the responsibility of the custom headers call to actually add these required headers.
    var requiredUpgradeHeaders: [String] { get }

    /// Additional headers to be added to the request, beyond the "Upgrade" and "Connection" headers.
    func addCustom(upgradeRequestHeaders: inout HTTPHeaders)

    /// Gives the receiving upgrader the chance to deny the upgrade based on the upgrade HTTP response.
    func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel
    /// pipeline to add whatever channel handlers are required.
    /// Until the returned `EventLoopFuture` succeeds, all received data will be buffered.
    func upgrade(channel: Channel, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<UpgradeResult>
}

/// The upgrade configuration for the ``NIOTypedHTTPClientUpgradeHandler``.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult: Sendable>: Sendable {
    /// The initial request head that is sent out once the channel becomes active.
    public var upgradeRequestHead: HTTPRequestHead

    /// The array of potential upgraders.
    public var upgraders: [any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>]

    /// A closure that is run once it is determined that no protocol upgrade is happening. This can be used
    /// to configure handlers that expect HTTP.
    public var notUpgradingCompletionHandler: @Sendable (Channel) -> EventLoopFuture<UpgradeResult>

    public init(
        upgradeRequestHead: HTTPRequestHead,
        upgraders: [any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>],
        notUpgradingCompletionHandler: @Sendable @escaping (Channel) -> EventLoopFuture<UpgradeResult>
    ) {
        precondition(upgraders.count > 0, "A minimum of one protocol upgrader must be specified.")
        self.upgradeRequestHead = upgradeRequestHead
        self.upgraders = upgraders
        self.notUpgradingCompletionHandler = notUpgradingCompletionHandler
    }
}

/// A client-side channel handler that sends a HTTP upgrade handshake request to perform a HTTP-upgrade.
/// This handler will add all appropriate headers to perform an upgrade to
/// the a protocol. It may add headers for a set of protocols in preference order.
/// If the upgrade fails (i.e. response is not 101 Switching Protocols), this handler simply
/// removes itself from the pipeline. If the upgrade is successful, it upgrades the pipeline to the new protocol.
///
/// The request sends an order of preference to request which protocol it would like to use for the upgrade.
/// It will only upgrade to the protocol that is returned first in the list and does not currently
/// have the capability to upgrade to multiple simultaneous layered protocols.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public final class NIOTypedHTTPClientUpgradeHandler<UpgradeResult: Sendable>: ChannelDuplexHandler,
    RemovableChannelHandler
{
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTPClientRequestPart
    public typealias InboundIn = HTTPClientResponsePart
    public typealias InboundOut = HTTPClientResponsePart

    /// The upgrade future which will be completed once protocol upgrading has been done.
    public var upgradeResultFuture: EventLoopFuture<UpgradeResult> {
        self.upgradeResultPromise.futureResult
    }

    private let upgradeRequestHead: HTTPRequestHead
    private let httpHandlers: [RemovableChannelHandler]
    private let notUpgradingCompletionHandler: @Sendable (Channel) -> EventLoopFuture<UpgradeResult>
    private var stateMachine: NIOTypedHTTPClientUpgraderStateMachine<UpgradeResult>
    private var _upgradeResultPromise: EventLoopPromise<UpgradeResult>?
    private var upgradeResultPromise: EventLoopPromise<UpgradeResult> {
        precondition(
            self._upgradeResultPromise != nil,
            "Tried to access the upgrade result before the handler was added to a pipeline"
        )
        return self._upgradeResultPromise!
    }

    /// Create a ``NIOTypedHTTPClientUpgradeHandler``.
    ///
    /// - Parameters:
    ///  - httpHandlers: All `RemovableChannelHandler` objects which will be removed from the pipeline
    ///     once the upgrade response is sent. This is used to ensure that the pipeline will be in a clean state
    ///     after the upgrade. It should include any handlers that are directly related to handling HTTP.
    ///     At the very least this should include the `HTTPEncoder` and `HTTPDecoder`, but should also include
    ///     any other handler that cannot tolerate receiving non-HTTP data.
    ///  - upgradeConfiguration: The upgrade configuration.
    public init(
        httpHandlers: [RemovableChannelHandler],
        upgradeConfiguration: NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>
    ) {
        self.httpHandlers = httpHandlers
        var upgradeRequestHead = upgradeConfiguration.upgradeRequestHead
        Self.addHeaders(
            to: &upgradeRequestHead,
            upgraders: upgradeConfiguration.upgraders
        )
        self.upgradeRequestHead = upgradeRequestHead
        self.stateMachine = .init(upgraders: upgradeConfiguration.upgraders)
        self.notUpgradingCompletionHandler = upgradeConfiguration.notUpgradingCompletionHandler
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

    public func channelActive(context: ChannelHandlerContext) {
        switch self.stateMachine.channelActive() {
        case .writeUpgradeRequest:
            context.write(
                NIOTypedHTTPClientUpgradeHandler.wrapOutboundOut(.head(self.upgradeRequestHead)),
                promise: nil
            )
            context.write(NIOTypedHTTPClientUpgradeHandler.wrapOutboundOut(.body(.byteBuffer(.init()))), promise: nil)
            context.writeAndFlush(NIOTypedHTTPClientUpgradeHandler.wrapOutboundOut(.end(nil)), promise: nil)

        case .none:
            break
        }
    }

    private static func addHeaders(
        to requestHead: inout HTTPRequestHead,
        upgraders: [any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>]
    ) {
        let requiredHeaders = ["upgrade"] + upgraders.flatMap { $0.requiredUpgradeHeaders }
        requestHead.headers.add(name: "Connection", value: requiredHeaders.joined(separator: ","))

        let allProtocols = upgraders.map { $0.supportedProtocol.lowercased() }
        requestHead.headers.add(name: "Upgrade", value: allProtocols.joined(separator: ","))

        // Allow each upgrader the chance to add custom headers.
        for upgrader in upgraders {
            upgrader.addCustom(upgradeRequestHeaders: &requestHead.headers)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.stateMachine.write() {
        case .failWrite(let error):
            promise?.fail(error)

        case .forwardWrite:
            context.write(data, promise: promise)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.stateMachine.channelReadData(data) {
        case .unwrapData:
            let responsePart = NIOTypedHTTPClientUpgradeHandler.unwrapInboundIn(data)
            self.channelRead(context: context, responsePart: responsePart)

        case .fireChannelRead:
            context.fireChannelRead(data)

        case .none:
            break
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.upgradeResultPromise.fail(error)
        context.fireErrorCaught(error)
    }

    private func channelRead(context: ChannelHandlerContext, responsePart: HTTPClientResponsePart) {
        switch self.stateMachine.channelReadResponsePart(responsePart) {
        case .fireErrorCaughtAndRemoveHandler(let error):
            self.upgradeResultPromise.fail(error)
            context.fireErrorCaught(error)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)

        case .runNotUpgradingInitializer:
            self.notUpgradingCompletionHandler(context.channel)
                .hop(to: context.eventLoop)
                .assumeIsolated()
                .whenComplete { result in
                    self.upgradingHandlerCompleted(context: context, result)
                }

        case .startUpgrading(let upgrader, let responseHead):
            self.startUpgrading(
                context: context,
                upgrader: upgrader,
                responseHead: responseHead
            )

        case .none:
            break
        }
    }

    private func startUpgrading(
        context: ChannelHandlerContext,
        upgrader: any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>,
        responseHead: HTTPResponseHead
    ) {
        // Before we start the upgrade we have to remove the HTTPEncoder and HTTPDecoder handlers from the
        // pipeline, to prevent them parsing any more data. We'll buffer the incoming data until that completes.
        let channel = context.channel
        self.removeHTTPHandlers(pipeline: context.pipeline)
            .flatMap {
                upgrader.upgrade(channel: channel, upgradeResponse: responseHead)
            }.hop(to: context.eventLoop)
            .assumeIsolated()
            .whenComplete { result in
                self.upgradingHandlerCompleted(context: context, result)
            }
    }

    private func upgradingHandlerCompleted(
        context: ChannelHandlerContext,
        _ result: Result<UpgradeResult, Error>
    ) {
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
            self.upgradeResultPromise.succeed(value)
            self.unbuffer(context: context)

        case .removeHandler(let value):
            self.upgradeResultPromise.succeed(value)
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

    /// Removes any extra HTTP-related handlers from the channel pipeline.
    private func removeHTTPHandlers(pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        guard self.httpHandlers.count > 0 else {
            return pipeline.eventLoop.makeSucceededFuture(())
        }

        let removeFutures = self.httpHandlers.map { pipeline.syncOperations.removeHandler($0) }
        return .andAllSucceed(removeFutures, on: pipeline.eventLoop)
    }
}

@available(*, unavailable)
extension NIOTypedHTTPClientUpgradeHandler: Sendable {}
