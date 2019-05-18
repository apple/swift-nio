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

/// Errors that may be raised by the `HTTPClientProtocolUpgrader`.
public struct NIOHTTPClientUpgradeError: Hashable, Error {

    // Uses the open enum style to allow additional errors to be added in future.
    private enum Code: Hashable {
        case responseProtocolNotFound
        case invalidHTTPOrdering
        case upgraderDeniedUpgrade
        case writingToHandlerDuringUpgrade
        case writingToHandlerAfterUpgradeCompleted
        case writingToHandlerAfterUpgradeFailed
        case receivedResponseBeforeRequestSent
        case receivedResponseAfterUpgradeCompleted
    }
    
    private var code: Code
    
    private init(_ code: Code) {
        self.code = code
    }

    public static let responseProtocolNotFound = NIOHTTPClientUpgradeError(.responseProtocolNotFound)
    public static let invalidHTTPOrdering = NIOHTTPClientUpgradeError(.invalidHTTPOrdering)
    public static let upgraderDeniedUpgrade = NIOHTTPClientUpgradeError(.upgraderDeniedUpgrade)
    public static let writingToHandlerDuringUpgrade = NIOHTTPClientUpgradeError(.writingToHandlerDuringUpgrade)
    public static let writingToHandlerAfterUpgradeCompleted = NIOHTTPClientUpgradeError(.writingToHandlerAfterUpgradeCompleted)
    public static let writingToHandlerAfterUpgradeFailed = NIOHTTPClientUpgradeError(.writingToHandlerAfterUpgradeFailed)
    public static let receivedResponseBeforeRequestSent = NIOHTTPClientUpgradeError(.receivedResponseBeforeRequestSent)
    public static let receivedResponseAfterUpgradeCompleted = NIOHTTPClientUpgradeError(.receivedResponseAfterUpgradeCompleted)
}

extension NIOHTTPClientUpgradeError: CustomStringConvertible {
    public var description: String {
        return String(describing: self.code)
    }
}

/// An object that implements `NIOHTTPClientProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol on a client-side channel.
/// It has the option of denying this upgrade based upon the server response.
public protocol NIOHTTPClientProtocolUpgrader {
    
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
    func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void>
}

/// A client-side channel handler that sends a HTTP upgrade handshake request to perform a HTTP-upgrade.
/// When the first HTTP request is sent, this handler will add all appropriate headers to perform an upgrade to
/// the a protocol. It may add headers for a set of protocols in preference order.
/// If the upgrade fails (i.e. response is not 101 Switching Protocols), this handler simply
/// removes itself from the pipeline. If the upgrade is successful, it upgrades the pipeline to the new protocol.
///
/// The request sends an order of preference to request which protocol it would like to use for the upgrade.
/// It will only upgrade to the protocol that is returned first in the list and does not currently
/// have the capability to upgrade to multiple simultaneous layered protocols.
public final class NIOHTTPClientUpgradeHandler: ChannelDuplexHandler, RemovableChannelHandler {
    
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTPClientRequestPart

    public typealias InboundIn = HTTPClientResponsePart
    public typealias InboundOut = HTTPClientResponsePart
    
    private var upgraders: [NIOHTTPClientProtocolUpgrader]
    private let httpHandlers: [RemovableChannelHandler]
    private let upgradeCompletionHandler: (ChannelHandlerContext) -> Void
    
    /// Whether we've already seen the first response from our initial upgrade request.
    private var seenFirstResponse = false
    
    private var upgradeState: UpgradeState = .requestRequired
    
    private var receivedMessages: CircularBuffer<NIOAny> = CircularBuffer()
    
    /// Create a `HTTPClientUpgradeHandler`.
    ///
    /// - Parameter upgraders: All `HTTPClientProtocolUpgrader` objects that will add their upgrade request
    ///     headers and handle the upgrade if there is a response for their protocol. They should be placed in
    ///     order of the preference for the upgrade.
    /// - Parameter httpHandlers: All `RemovableChannelHandler` objects which will be removed from the pipeline
    ///     once the upgrade response is sent. This is used to ensure that the pipeline will be in a clean state
    ///     after the upgrade. It should include any handlers that are directly related to handling HTTP.
    ///     At the very least this should include the `HTTPEncoder` and `HTTPDecoder`, but should also include
    ///     any other handler that cannot tolerate receiving non-HTTP data.
    /// - Parameter upgradeCompletionHandler: A closure that will be fired when HTTP upgrade is complete.
    public init(upgraders: [NIOHTTPClientProtocolUpgrader],
                httpHandlers: [RemovableChannelHandler],
                upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) {

        precondition(upgraders.count > 0, "A minimum of one protocol upgrader must be specified.")

        self.upgraders = upgraders
        self.httpHandlers = httpHandlers
        self.upgradeCompletionHandler = upgradeCompletionHandler
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {

        switch self.upgradeState {
        
        case .requestRequired:
            let updatedData = self.addHeadersToOutboundOut(data: data)
            context.write(updatedData, promise: promise)

        case .awaitingConfirmationResponse:
            // Still have full http stack.
            context.write(data, promise: promise)
            
        case .awaitingUpgrader, .upgraderReady, .upgrading:
            /// We shouldn't be sending anything else until we get a response.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.writingToHandlerDuringUpgrade)

        case .upgradingAddingHandlers:
            // These are most likely messages immediately fired by a new protocol handler.
            // As that is added last we can just forward them on.
            context.write(data, promise: promise)
            
        case .upgradeComplete:
            //Upgrade complete and this handler should have been removed from the pipeline.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.writingToHandlerAfterUpgradeCompleted)
        case .upgradeFailed:
            //Upgrade failed and this handler should have been removed from the pipeline.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.writingToHandlerAfterUpgradeCompleted)
        }
    }

    private func addHeadersToOutboundOut(data: NIOAny) -> NIOAny {
        
        let interceptedOutgoingRequest = self.unwrapOutboundIn(data)
        
        if case .head(var requestHead) = interceptedOutgoingRequest {
            
            self.upgradeState = .awaitingConfirmationResponse
            
            self.addConnectionHeaders(to: &requestHead)
            self.addUpgradeHeaders(to: &requestHead)
            return self.wrapOutboundOut(.head(requestHead))
        }
        
        return data
    }

    private func addConnectionHeaders(to requestHead: inout HTTPRequestHead) {
        
        var connectionValue = "upgrade"
        
        for upgrader in self.upgraders where upgrader.requiredUpgradeHeaders.count > 0 {
            connectionValue.append("," + upgrader.requiredUpgradeHeaders.joined(separator: ","))
        }

        requestHead.headers.add(name: "Connection", value: connectionValue)
    }

    private func addUpgradeHeaders(to requestHead: inout HTTPRequestHead) {
        
        let upgraderList = self.upgraders.map({ $0.supportedProtocol.lowercased() }).joined(separator:",")
        requestHead.headers.add(name: "Upgrade", value: upgraderList)

        // Allow each upgrader the chance to add custom headers.
        for upgrader in self.upgraders {
            upgrader.addCustom(upgradeRequestHeaders: &requestHead.headers)
        }
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        
        guard !self.seenFirstResponse else {
            // We're waiting for upgrade to complete: buffer this data.
            self.receivedMessages.append(data)
            return
        }
        
        let responsePart = unwrapInboundIn(data)
        
        switch self.upgradeState {
        case .awaitingConfirmationResponse:
            self.firstResponseHeadReceived(context: context, responsePart: responsePart)
        case .awaitingUpgrader, .upgrading, .upgradingAddingHandlers:
            if case .end = responsePart {
                // This is the end of the first response. Swallow it, we're buffering the rest.
                self.seenFirstResponse = true
                
            }
        case .upgraderReady(let upgrade):
            if case .end = responsePart {
                // This is the end of the first response, and we can upgrade. Time to kick it off.
                self.seenFirstResponse = true
                upgrade()
            }
        case .upgradeFailed:
            // We were reentrantly called while delivering the response head. We can just pass this through.
            context.fireChannelRead(data)
        case .upgradeComplete:
            //Upgrade has completed but we have not seen a whole response and still got reentrantly called.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.receivedResponseAfterUpgradeCompleted)
        case .requestRequired:
            //We are receiving an upgrade response and we have not requested the upgrade.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.receivedResponseBeforeRequestSent)
        }
    }
    
    private func firstResponseHeadReceived(context: ChannelHandlerContext, responsePart: HTTPClientResponsePart) {
        
        // We should decide if we're can upgrade based on the first response header: if we aren't upgrading,
        // by the time the body comes in we should be out of the pipeline. That means that if we don't think we're
        // upgrading, the only thing we should see is a response head. Anything else in an error.
        guard case .head(let response) = responsePart else {
            context.fireErrorCaught(NIOHTTPClientUpgradeError.invalidHTTPOrdering)
            self.notUpgrading(context: context, data: responsePart)
            return
        }
        
        // Assess whether the upgrade response has accepted our upgrade request.
        guard case .switchingProtocols = response.status else {
            self.notUpgrading(context: context, data: responsePart)
            return
        }
        
        // Ok, we have a HTTP response. Check if it's an upgrade confirmation.
        // If it's not, we want to pass it on and remove ourselves from the channel pipeline.
        let acceptedProtocols = response.headers[canonicalForm: "upgrade"].map(String.init)
        
        guard acceptedProtocols.count > 0 else {
            // There is no upgrade protocols returned dspite status being 'switching protocols'.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.responseProtocolNotFound)
            self.notUpgrading(context: context, data: responsePart)
            return
        }

        // This is an upgrade response.
        // This may take a while, so while we're waiting more data can come in.
        self.upgradeState = .awaitingUpgrader
        
        self.handleUpgrade(context: context, upgradeResponse: response, receivedProtocols: acceptedProtocols).whenSuccess { callback in

            if let callback = callback {
                self.gotUpgrader(upgrader: callback)
            } else {
                self.notUpgrading(context: context, data: responsePart)
            }
        }
    }
    
    private func handleUpgrade(context: ChannelHandlerContext, upgradeResponse response: HTTPResponseHead, receivedProtocols: [String]) -> EventLoopFuture<(() -> Void)?> {
        
        let allHeaderNames = Set(response.headers.map { $0.name.lowercased() })
        
        // We now set off a chain of Futures to try to find a protocol upgrade.
        // While this is blocking, we need to buffer inbound data.
        let protocolIterator = receivedProtocols.makeIterator()
        
        return self.handleUpgradeForProtocol(context: context, protocolIterator: protocolIterator, response: response, allHeaderNames: allHeaderNames)
    }
    
    /// Attempt to upgrade a single protocol.
    private func handleUpgradeForProtocol(context: ChannelHandlerContext, protocolIterator: Array<String>.Iterator, response: HTTPResponseHead, allHeaderNames: Set<String>) -> EventLoopFuture<(() -> Void)?> {
        
        var protocolIterator = protocolIterator
        guard let lowercaseProtoName = protocolIterator.next()?.lowercased() else {
            // There are no upgrade protocols returned.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.responseProtocolNotFound)
            return context.eventLoop.makeSucceededFuture(nil)
        }

        let matchingUpgrader = self.upgraders
            .first(where: { $0.supportedProtocol.lowercased() == lowercaseProtoName })
        
        guard let upgrader = matchingUpgrader else {
            // There is no upgrader for this protocol.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.responseProtocolNotFound)
            return context.eventLoop.makeSucceededFuture(nil)
        }
        
        guard upgrader.shouldAllowUpgrade(upgradeResponse: response) else {
            // The upgrader says no.
            context.fireErrorCaught(NIOHTTPClientUpgradeError.upgraderDeniedUpgrade)
            return context.eventLoop.makeSucceededFuture(nil)
        }
        
        let upgradeFunction = self.performUpgrade(context: context, upgrader: upgrader, response: response)
        
        return context.eventLoop.makeSucceededFuture(upgradeFunction)
        .flatMapError { error in
            // No upgrade here.
            context.fireErrorCaught(error)
            return context.eventLoop.makeSucceededFuture(nil)
        }
    }
    
    private func performUpgrade(context: ChannelHandlerContext, upgrader: NIOHTTPClientProtocolUpgrader,  response: HTTPResponseHead) -> () -> Void {

        // Before we start the upgrade we have to remove the HTTPEncoder and HTTPDecoder handlers from the
        // pipeline, to prevent them parsing any more data. We'll buffer the incoming data until that completes.
        // While there are a lot of Futures involved here it's quite possible that all of this code will
        // actually complete synchronously: we just want to program for the possibility that it won't.
        // Once that's done, we call the internal handler, then call the upgrader code, and then finally when the
        // upgrader code is done, we do our final cleanup steps, namely we replay the received data we
        // buffered in the meantime and then remove ourselves from the pipeline.
        return {
            // Ok, we're upgrading.
            self.upgradeState = .upgrading
            
            self.removeHTTPHandlers(context: context)
            .map {
                // Let the other handlers be removed before continuing with upgrade.
                self.upgradeCompletionHandler(context)
                self.upgradeState = .upgradingAddingHandlers
            }
            .flatMap {
                upgrader.upgrade(context: context, upgradeResponse: response)
            }
            .map {
                self.upgradeState = .upgradeComplete
                
                // We unbuffer any buffered data here.
                
                // If we received any, we fire readComplete.
                let fireReadComplete = self.receivedMessages.count > 0
                while self.receivedMessages.count > 0 {
                    let bufferedPart = self.receivedMessages.removeFirst()
                    context.fireChannelRead(bufferedPart)
                }
                if fireReadComplete {
                    context.fireChannelReadComplete()
                }

            }
            .whenComplete { _ in
                context.pipeline.removeHandler(context: context, promise: nil)
            }
        }
    }
    
    /// Removes any extra HTTP-related handlers from the channel pipeline.
    private func removeHTTPHandlers(context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        guard self.httpHandlers.count > 0 else {
            return context.eventLoop.makeSucceededFuture(())
        }
        
        let removeFutures = self.httpHandlers.map { context.pipeline.removeHandler($0) }
        return .andAllSucceed(removeFutures, on: context.eventLoop)
    }
    
    private func gotUpgrader(upgrader: @escaping (() -> Void)) {

        guard case .awaitingUpgrader = self.upgradeState else {
            preconditionFailure("Unexpected upgrader state: \(self.upgradeState)")
        }

        self.upgradeState = .upgraderReady(upgrader)
        if self.seenFirstResponse {
            // Ok, we're good to go, we can upgrade. Otherwise we're waiting for .end, which
            // will trigger the upgrade.
            upgrader()
        }
    }
    
    private func notUpgrading(context: ChannelHandlerContext, data: HTTPClientResponsePart) {
        self.upgradeState = .upgradeFailed
        
        if !self.seenFirstResponse {
            // We haven't seen the first response .end. That means we're not buffering anything, and we can
            // just deliver data.
            assert(self.receivedMessages.count == 0)
            context.fireChannelRead(self.wrapInboundOut(data))
        } else {
            // We've seen the first request .end, so we now need to deliver the .head we got passed,
            // as well as the .end we swallowed, and any buffered parts. While we're doing this
            // we may be reentrantly called, which will cause us to buffer new parts. To make that safe, we
            // must ensure we aren't holding the buffer mutably, so no for loop for us.
            context.fireChannelRead(self.wrapInboundOut(data))
            context.fireChannelRead(self.wrapInboundOut(.end(nil)))
            
            while self.receivedMessages.count > 0 {
                let bufferedPart = self.receivedMessages.removeFirst()
                context.fireChannelRead(bufferedPart)
            }
        }
        
        // Ok, we've delivered all the parts. We can now remove ourselves, which should happen synchronously.
        context.pipeline.removeHandler(context: context, promise: nil)
    }
}

extension NIOHTTPClientUpgradeHandler {
    /// The state of the upgrade handler.
    fileprivate enum UpgradeState {
        /// Request not sent. This will need to be sent to initiate the upgrade.
        case requestRequired

        /// Awaiting confirmation response which will allow the upgrade to zero one or more protocols.
        case awaitingConfirmationResponse
        
        /// The response head has been received. We're currently running the future chain awaiting an upgrader.
        case awaitingUpgrader
        
        /// The upgrade is in process.
        case upgrading
        
        /// The upgrade is in process and all of the http handlers have been removed.
        case upgradingAddingHandlers
        
        /// We have an upgrader, which means we can begin upgrade.
        case upgraderReady(() -> Void)
        
        /// The upgrade has succeeded, and we are being removed from the pipeline.
        case upgradeComplete
        
        /// The upgrade has failed.
        case upgradeFailed
    }
}
