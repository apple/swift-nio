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

/// Errors that may be raised by the `HTTPServerProtocolUpgrader`.
public enum HTTPServerUpgradeErrors: Error {
    case invalidHTTPOrdering
}

/// User events that may be fired by the `HTTPServerProtocolUpgrader`.
public enum HTTPServerUpgradeEvents {
    /// Fired when HTTP upgrade has completed and the
    /// `HTTPServerProtocolUpgrader` is about to remove itself from the
    /// `ChannelPipeline`.
    case upgradeComplete(toProtocol: String, upgradeRequest: HTTPRequestHead)
}


/// An object that implements `HTTPServerProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol on a server-side channel.
public protocol HTTPServerProtocolUpgrader {
    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol needs in the request to successfully upgrade. These header fields
    /// will be provided to the handler when it is asked to handle the upgrade. They will also be validated
    ///  against the inbound request's Connection header field.
    var requiredUpgradeHeaders: [String] { get }

    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// fail the future.
    func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders>

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required. Until the returned `EventLoopFuture` succeeds, all received
    /// data will be buffered.
    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void>
}

/// A server-side channel handler that receives HTTP requests and optionally performs a HTTP-upgrade.
/// Removes itself from the channel pipeline after the first inbound request on the connection, regardless of
/// whether the upgrade succeeded or not.
///
/// This handler behaves a bit differently from its Netty counterpart because it does not allow upgrade
/// on any request but the first on a connection. This is primarily to handle clients that pipeline: it's
/// sufficiently difficult to ensure that the upgrade happens at a safe time while dealing with pipelined
/// requests that we choose to punt on it entirely and not allow it. As it happens this is mostly fine:
/// the odds of someone needing to upgrade midway through the lifetime of a connection are very low.
public final class HTTPServerUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private let upgraders: [String: HTTPServerProtocolUpgrader]
    private let upgradeCompletionHandler: (ChannelHandlerContext) -> Void

    private let httpEncoder: HTTPResponseEncoder?
    private let extraHTTPHandlers: [RemovableChannelHandler]

    /// Whether we've already seen the first request.
    private var seenFirstRequest = false

    /// The closure that should be invoked when the end of the upgrade request is received if any.
    private var upgradeState: UpgradeState = .idle
    private var receivedMessages: CircularBuffer<NIOAny> = CircularBuffer()

    /// Create a `HTTPServerUpgradeHandler`.
    ///
    /// - Parameter upgraders: All `HTTPServerProtocolUpgrader` objects that this pipeline will be able
    ///     to use to handle HTTP upgrade.
    /// - Parameter httpEncoder: The `HTTPResponseEncoder` encoding responses from this handler and which will
    ///     be removed from the pipeline once the upgrade response is sent. This is used to ensure
    ///     that the pipeline will be in a clean state after upgrade.
    /// - Parameter extraHTTPHandlers: Any other handlers that are directly related to handling HTTP. At the very least
    ///     this should include the `HTTPDecoder`, but should also include any other handler that cannot tolerate
    ///     receiving non-HTTP data.
    /// - Parameter upgradeCompletionHandler: A block that will be fired when HTTP upgrade is complete.
    public init(upgraders: [HTTPServerProtocolUpgrader], httpEncoder: HTTPResponseEncoder, extraHTTPHandlers: [RemovableChannelHandler], upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) {
        var upgraderMap = [String: HTTPServerProtocolUpgrader]()
        for upgrader in upgraders {
            upgraderMap[upgrader.supportedProtocol.lowercased()] = upgrader
        }
        self.upgraders = upgraderMap
        self.upgradeCompletionHandler = upgradeCompletionHandler
        self.httpEncoder = httpEncoder
        self.extraHTTPHandlers = extraHTTPHandlers
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !self.seenFirstRequest else {
            // We're waiting for upgrade to complete: buffer this data.
            self.receivedMessages.append(data)
            return
        }

        let requestPart = unwrapInboundIn(data)

        switch self.upgradeState {
        case .idle:
            self.firstRequestHeadReceived(context: context, requestPart: requestPart)
        case .awaitingUpgrader:
            if case .end = requestPart {
                // This is the end of the first request. Swallow it, we're buffering the rest.
                self.seenFirstRequest = true
            }
        case .upgraderReady(let upgrade):
            if case .end = requestPart {
                // This is the end of the first request, and we can upgrade. Time to kick it off.
                self.seenFirstRequest = true
                upgrade()
            }
        case .upgradeFailed:
            // We were re-entrantly called while delivering the request head. We can just pass this through.
            context.fireChannelRead(data)
        case .upgradeComplete:
            preconditionFailure("Upgrade has completed but we have not seen a whole request and still got re-entrantly called.")
        case .upgrading:
            preconditionFailure("We think we saw .end before and began upgrading, but somehow we have not set seenFirstRequest")
        }
    }

    public func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        // We have been formally removed from the pipeline. We should send any buffered data we have.
        // Note that we loop twice. This is because we want to guard against being reentrantly called from fireChannelReadComplete.
        while self.receivedMessages.count > 0 {
            while self.receivedMessages.count > 0 {
                let bufferedPart = self.receivedMessages.removeFirst()
                context.fireChannelRead(bufferedPart)
            }

            context.fireChannelReadComplete()
        }

        context.leavePipeline(removalToken: removalToken)
    }

    private func firstRequestHeadReceived(context: ChannelHandlerContext, requestPart: HTTPServerRequestPart) {
        // We should decide if we're going to upgrade based on the first request header: if we aren't upgrading,
        // by the time the body comes in we should be out of the pipeline. That means that if we don't think we're
        // upgrading, the only thing we should see is a request head. Anything else in an error.
        guard case .head(let request) = requestPart else {
            context.fireErrorCaught(HTTPServerUpgradeErrors.invalidHTTPOrdering)
            self.notUpgrading(context: context, data: requestPart)
            return
        }

        // Ok, we have a HTTP request. Check if it's an upgrade. If it's not, we want to pass it on and remove ourselves
        // from the channel pipeline.
        let requestedProtocols = request.headers[canonicalForm: "upgrade"].map(String.init)
        guard requestedProtocols.count > 0 else {
            self.notUpgrading(context: context, data: requestPart)
            return
        }

        // Cool, this is an upgrade request.
        // We'll attempt to upgrade. This may take a while, so while we're waiting more data can come in.
        self.upgradeState = .awaitingUpgrader

        self.handleUpgrade(context: context, request: request, requestedProtocols: requestedProtocols)
            .hop(to: context.eventLoop) // the user might return a future from another EventLoop.
            .whenSuccess { callback in
                assert(context.eventLoop.inEventLoop)
                if let callback = callback {
                    self.gotUpgrader(upgrader: callback)
                } else {
                    self.notUpgrading(context: context, data: requestPart)
                }
        }
    }

    /// The core of the upgrade handling logic.
    ///
    /// - returns: An `EventLoopFuture` that will contain a callback to invoke if upgrade is requested, or nil if upgrade has failed. Never returns a failed future.
    private func handleUpgrade(context: ChannelHandlerContext, request: HTTPRequestHead, requestedProtocols: [String]) -> EventLoopFuture<(() -> Void)?> {
        let connectionHeader = Set(request.headers[canonicalForm: "connection"].map { $0.lowercased() })
        let allHeaderNames = Set(request.headers.map { $0.name.lowercased() })

        // We now set off a chain of Futures to try to find a protocol upgrade. While this is blocking, we need to buffer inbound data.
        let protocolIterator = requestedProtocols.makeIterator()
        return self.handleUpgradeForProtocol(context: context, protocolIterator: protocolIterator, request: request, allHeaderNames: allHeaderNames, connectionHeader: connectionHeader)
    }

    /// Attempt to upgrade a single protocol.
    ///
    /// Will recurse through `protocolIterator` if upgrade fails.
    private func handleUpgradeForProtocol(context: ChannelHandlerContext, protocolIterator: Array<String>.Iterator, request: HTTPRequestHead, allHeaderNames: Set<String>, connectionHeader: Set<String>) -> EventLoopFuture<(() -> Void)?> {
        // We want a local copy of the protocol iterator. We'll pass it to the next invocation of the function.
        var protocolIterator = protocolIterator
        guard let proto = protocolIterator.next() else {
            // We're done! No suitable protocol for upgrade.
            return context.eventLoop.makeSucceededFuture(nil)
        }

        guard let upgrader = self.upgraders[proto.lowercased()] else {
            return self.handleUpgradeForProtocol(context: context, protocolIterator: protocolIterator, request: request, allHeaderNames: allHeaderNames, connectionHeader: connectionHeader)
        }

        let requiredHeaders = Set(upgrader.requiredUpgradeHeaders.map { $0.lowercased() })
        guard requiredHeaders.isSubset(of: allHeaderNames) && requiredHeaders.isSubset(of: connectionHeader) else {
            return self.handleUpgradeForProtocol(context: context, protocolIterator: protocolIterator, request: request, allHeaderNames: allHeaderNames, connectionHeader: connectionHeader)
        }

        let responseHeaders = self.buildUpgradeHeaders(protocol: proto)
        return upgrader.buildUpgradeResponse(channel: context.channel, upgradeRequest: request, initialResponseHeaders: responseHeaders).map { finalResponseHeaders in
            return {
                // Ok, we're upgrading.
                self.upgradeState = .upgrading

                // Before we finish the upgrade we have to remove the HTTPDecoder and any other non-Encoder HTTP
                // handlers from the pipeline, to prevent them parsing any more data. We'll buffer the data until
                // that completes.
                // While there are a lot of Futures involved here it's quite possible that all of this code will
                // actually complete synchronously: we just want to program for the possibility that it won't.
                // Once that's done, we send the upgrade response, then remove the HTTP encoder, then call the
                // internal handler, then call the user code, and then finally when the user code is done we do
                // our final cleanup steps, namely we replay the received data we buffered in the meantime and
                // then remove ourselves from the pipeline.
                self.removeExtraHandlers(context: context).flatMap {
                    self.sendUpgradeResponse(context: context, upgradeRequest: request, responseHeaders: finalResponseHeaders)
                }.flatMap {
                    self.removeHandler(context: context, handler: self.httpEncoder)
                }.map {
                    self.upgradeCompletionHandler(context)
                }.flatMap {
                    upgrader.upgrade(context: context, upgradeRequest: request)
                }.map {
                    context.fireUserInboundEventTriggered(HTTPServerUpgradeEvents.upgradeComplete(toProtocol: proto, upgradeRequest: request))
                    self.upgradeState = .upgradeComplete
                }.whenComplete { (_: Result<Void, Error>) in
                    // When we remove ourselves we'll be delivering any buffered data.
                    context.pipeline.removeHandler(context: context, promise: nil)
                }
            }
        }.flatMapError { error in
            // No upgrade here. We want to fire the error down the pipeline, and then try another loop iteration.
            context.fireErrorCaught(error)
            return self.handleUpgradeForProtocol(context: context, protocolIterator: protocolIterator, request: request, allHeaderNames: allHeaderNames, connectionHeader: connectionHeader)
        }
    }

    private func gotUpgrader(upgrader: @escaping (() -> Void)) {
        switch self.upgradeState {
        case .awaitingUpgrader:
            self.upgradeState = .upgraderReady(upgrader)
            if self.seenFirstRequest {
                // Ok, we're good to go, we can upgrade. Otherwise we're waiting for .end, which
                // will trigger the upgrade.
                upgrader()
            }
        case .idle, .upgradeComplete, .upgraderReady, .upgradeFailed, .upgrading:
            preconditionFailure("Unexpected upgrader state: \(self.upgradeState)")
        }
    }

    /// Sends the 101 Switching Protocols response for the pipeline.
    private func sendUpgradeResponse(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead, responseHeaders: HTTPHeaders) -> EventLoopFuture<Void> {
        var response = HTTPResponseHead(version: .http1_1, status: .switchingProtocols)
        response.headers = responseHeaders
        return context.writeAndFlush(wrapOutboundOut(HTTPServerResponsePart.head(response)))
    }

    /// Called when we know we're not upgrading. Passes the data on and then removes this object from the pipeline.
    private func notUpgrading(context: ChannelHandlerContext, data: HTTPServerRequestPart) {
        self.upgradeState = .upgradeFailed

        if !self.seenFirstRequest {
            // We haven't seen the first request .end. That means we're not buffering anything, and we can
            // just deliver data.
            assert(self.receivedMessages.isEmpty)
            context.fireChannelRead(self.wrapInboundOut(data))
        } else {
            // This is trickier. We've seen the first request .end, so we now need to deliver the .head we
            // got passed, as well as the .end we swallowed, and any buffered parts. While we're doing this
            // we may be re-entrantly called, which will cause us to buffer new parts. To make that safe, we
            // must ensure we aren't holding the buffer mutably, so no for loop for us.
            context.fireChannelRead(self.wrapInboundOut(data))
            context.fireChannelRead(self.wrapInboundOut(.end(nil)))
        }

        context.fireChannelReadComplete()

        // Ok, we've delivered all the parts. We can now remove ourselves, which should happen synchronously.
        context.pipeline.removeHandler(context: context, promise: nil)
    }

    /// Builds the initial mandatory HTTP headers for HTTP upgrade responses.
    private func buildUpgradeHeaders(`protocol`: String) -> HTTPHeaders {
        return HTTPHeaders([("connection", "upgrade"), ("upgrade", `protocol`)])
    }

    /// Removes the given channel handler from the channel pipeline.
    private func removeHandler(context: ChannelHandlerContext, handler: RemovableChannelHandler?) -> EventLoopFuture<Void> {
        if let handler = handler {
            return context.pipeline.removeHandler(handler)
        } else {
            return context.eventLoop.makeSucceededFuture(())
        }
    }

    /// Removes any extra HTTP-related handlers from the channel pipeline.
    private func removeExtraHandlers(context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        guard self.extraHTTPHandlers.count > 0 else {
            return context.eventLoop.makeSucceededFuture(())
        }

        return .andAllSucceed(self.extraHTTPHandlers.map { context.pipeline.removeHandler($0) },
                              on: context.eventLoop)
    }
}

extension HTTPServerUpgradeHandler {
    /// The state of the upgrade handler.
    private enum UpgradeState {
        /// Awaiting some activity.
        case idle

        /// The request head has been received. We're currently running the future chain awaiting an upgrader.
        case awaitingUpgrader

        /// We have an upgrader, which means we can begin upgrade.
        case upgraderReady(() -> Void)

        /// The upgrade is in process.
        case upgrading

        /// The upgrade has failed, and we are being removed from the pipeline.
        case upgradeFailed

        /// The upgrade has succeeded, and we are being removed from the pipeline.
        case upgradeComplete
    }
}
