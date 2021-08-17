//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

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
            
        case .upgraderReady, .upgrading:
            promise?.fail(NIOHTTPClientUpgradeError.writingToHandlerDuringUpgrade)
            context.fireErrorCaught(NIOHTTPClientUpgradeError.writingToHandlerDuringUpgrade)

        case .upgradingAddingHandlers:
            // These are most likely messages immediately fired by a new protocol handler.
            // As that is added last we can just forward them on.
            context.write(data, promise: promise)
            
        case .upgradeComplete:
            // Upgrade complete and this handler should have been removed from the pipeline.
            promise?.fail(NIOHTTPClientUpgradeError.writingToHandlerAfterUpgradeCompleted)
            context.fireErrorCaught(NIOHTTPClientUpgradeError.writingToHandlerAfterUpgradeCompleted)

        case .upgradeFailed:
            // Upgrade failed and this handler should have been removed from the pipeline.
            promise?.fail(NIOHTTPClientUpgradeError.writingToHandlerAfterUpgradeCompleted)
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

        let requiredHeaders = ["upgrade"] + self.upgraders.flatMap { $0.requiredUpgradeHeaders }
        requestHead.headers.add(name: "Connection", value: requiredHeaders.joined(separator: ","))
    }

    private func addUpgradeHeaders(to requestHead: inout HTTPRequestHead) {
        
        let allProtocols = self.upgraders.map { $0.supportedProtocol.lowercased() }
        requestHead.headers.add(name: "Upgrade", value: allProtocols.joined(separator: ","))

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
        case .upgrading, .upgradingAddingHandlers:
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
            self.notUpgrading(context: context, data: responsePart, error: .invalidHTTPOrdering)
            return
        }
        
        // Assess whether the upgrade response has accepted our upgrade request.
        guard case .switchingProtocols = response.status else {
            self.notUpgrading(context: context, data: responsePart, error: nil)
            return
        }

        do {
            let callback = try self.handleUpgrade(context: context, upgradeResponse: response)
            self.gotUpgrader(upgrader: callback)
        } catch {
            let clientError = error as? NIOHTTPClientUpgradeError
            self.notUpgrading(context: context, data: responsePart, error: clientError)
        }
    }
    
    private func handleUpgrade(context: ChannelHandlerContext, upgradeResponse response: HTTPResponseHead) throws ->  (() -> Void) {

        // Ok, we have a HTTP response. Check if it's an upgrade confirmation.
        // If it's not, we want to pass it on and remove ourselves from the channel pipeline.
        let acceptedProtocols = response.headers[canonicalForm: "upgrade"]
        
        // At the moment we only upgrade to the first protocol returned from the server.
        guard let protocolName = acceptedProtocols.first?.lowercased() else {
            // There are no upgrade protocols returned.
            throw NIOHTTPClientUpgradeError.responseProtocolNotFound
        }

        return try self.handleUpgradeForProtocol(context: context,
                                                 protocolName: protocolName,
                                                 response: response)
    }
    
    /// Attempt to upgrade a single protocol.
    private func handleUpgradeForProtocol(context: ChannelHandlerContext, protocolName: String, response: HTTPResponseHead) throws -> (() -> Void) {

        let matchingUpgrader = self.upgraders
            .first(where: { $0.supportedProtocol.lowercased() == protocolName })
        
        guard let upgrader = matchingUpgrader else {
            // There is no upgrader for this protocol.
            throw NIOHTTPClientUpgradeError.responseProtocolNotFound
        }
        
        guard upgrader.shouldAllowUpgrade(upgradeResponse: response) else {
            // The upgrader says no.
            throw NIOHTTPClientUpgradeError.upgraderDeniedUpgrade
        }
        
        return self.performUpgrade(context: context, upgrader: upgrader, response: response)
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
                
                // We wait with the state change until _after_ the channel reads here.
                // This is to prevent firing writes in response to these reads after we went to .upgradeComplete
                // See: https://github.com/apple/swift-nio/issues/1279
                self.upgradeState = .upgradeComplete
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

        self.upgradeState = .upgraderReady(upgrader)
        if self.seenFirstResponse {
            // Ok, we're good to go, we can upgrade. Otherwise we're waiting for .end, which
            // will trigger the upgrade.
            upgrader()
        }
    }

    private func notUpgrading(context: ChannelHandlerContext, data: HTTPClientResponsePart, error: NIOHTTPClientUpgradeError?) {
        
        self.upgradeState = .upgradeFailed
        
        if let error = error {
            context.fireErrorCaught(error)
        }
        
        assert(self.receivedMessages.isEmpty)
        context.fireChannelRead(self.wrapInboundOut(data))
        
        // We've delivered the data. We can now remove ourselves, which should happen synchronously.
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
        
        /// The response head has been received. We have an upgrader, which means we can begin upgrade.
        case upgraderReady(() -> Void)
        
        /// The response head has been received. The upgrade is in process.
        case upgrading
        
        /// The upgrade is in process and all of the http handlers have been removed.
        case upgradingAddingHandlers
        
        /// The upgrade has succeeded, and we are being removed from the pipeline.
        case upgradeComplete
        
        /// The upgrade has failed.
        case upgradeFailed
    }
}
