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

public enum HTTPUpgradeErrors: Error {
    case invalidHTTPOrdering
}

public enum HTTPUpgradeEvents {
    case upgradeComplete(toProtocol: String, upgradeRequest: HTTPRequestHead)
}


/// An object that implements protocol upgrader knows how to handle HTTP upgrade to
/// a protocol.
public protocol HTTPProtocolUpgrader {
    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol needs in the request to successfully upgrade. These header fields
    /// will be provided to the handler when it is asked to handle the upgrade. They will also be validated
    ///  against the inbound request's Connection header field.
    var requiredUpgradeHeaders: [String] { get }

    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// throw.
    func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required.
    func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> Void
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
public class HTTPServerUpgradeHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPRequestPart
    public typealias InboundOut = HTTPRequestPart
    public typealias OutboundOut = HTTPResponsePart

    private let upgraders: [String: HTTPProtocolUpgrader]
    private let upgradeCompletionHandler: (ChannelHandlerContext) -> Void

    /// Whether we've already seen the first request.
    private var seenFirstRequest = false

    public init(upgraders: [HTTPProtocolUpgrader], upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) {
        var upgraderMap = [String: HTTPProtocolUpgrader]()
        for upgrader in upgraders {
            upgraderMap[upgrader.supportedProtocol] = upgrader
        }
        self.upgraders = upgraderMap
        self.upgradeCompletionHandler = upgradeCompletionHandler
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        // We're trying to remove ourselves from the pipeline, so just pass this on.
        guard !seenFirstRequest else {
            ctx.fireChannelRead(data: data)
            return
        }

        let requestPart = unwrapInboundIn(data)
        seenFirstRequest = true

        // We should only ever see a request header: by the time the body comes in we should
        // be out of the pipeline. Anything else is an error.
        guard case .head(let request) = requestPart else {
            ctx.fireErrorCaught(error: HTTPUpgradeErrors.invalidHTTPOrdering)
            notUpgrading(ctx: ctx, data: data)
            return
        }

        // Ok, we have a HTTP request. Check if it's an upgrade. If it's not, we want to pass it on and remove ourselves
        // from the channel pipeline.
        let requestedProtocols = request.headers.getCanonicalForm("upgrade")
        guard requestedProtocols.count > 0 else {
            notUpgrading(ctx: ctx, data: data)
            return
        }

        // Cool, this is an upgrade! Let's go.
        if !handleUpgrade(ctx: ctx, request: request, requestedProtocols: requestedProtocols) {
            notUpgrading(ctx: ctx, data: data)
        }
    }

    /// The core of the upgrade handling logic.
    private func handleUpgrade(ctx: ChannelHandlerContext, request: HTTPRequestHead, requestedProtocols: [String]) -> Bool {
        let connectionHeader = Set(request.headers.getCanonicalForm("connection").map { $0.lowercased() })
        let allHeaderNames = Set(request.headers.map { $0.name.lowercased() })

        for proto in requestedProtocols {
            guard let upgrader = upgraders[proto] else {
                continue
            }

            let requiredHeaders = Set(upgrader.requiredUpgradeHeaders)
            guard requiredHeaders.isSubset(of: allHeaderNames) && requiredHeaders.isSubset(of: connectionHeader) else {
                continue
            }

            var responseHeaders = buildUpgradeHeaders(protocol: proto)
            do {
                responseHeaders = try upgrader.buildUpgradeResponse(upgradeRequest: request, initialResponseHeaders: responseHeaders)
            } catch {
                // We should fire this error so the user can log it, but keep going.
                ctx.fireErrorCaught(error: error)
                continue
            }

            sendUpgradeResponse(ctx: ctx, upgradeRequest: request, responseHeaders: responseHeaders).whenSuccess {
                self.upgradeCompletionHandler(ctx)
                upgrader.upgrade(ctx: ctx, upgradeRequest: request)
                ctx.fireUserInboundEventTriggered(event: HTTPUpgradeEvents.upgradeComplete(toProtocol: proto, upgradeRequest: request))
                let _ = ctx.pipeline!.remove(ctx: ctx)
            }

            return true
        }

        return false
    }

    /// Sends the 101 Switching Protocols response for the pipeline.
    private func sendUpgradeResponse(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead, responseHeaders: HTTPHeaders) -> Future<Void> {
        var response = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .switchingProtocols)
        response.headers = responseHeaders
        return ctx.writeAndFlush(data: wrapOutboundOut(HTTPResponsePart.head(response)))
    }

    /// Called when we know we're not upgrading. Passes the data on and then removes this object from the pipeline.
    private func notUpgrading(ctx: ChannelHandlerContext, data: NIOAny) {
        ctx.fireChannelRead(data: data)
        let _ = ctx.pipeline!.remove(ctx: ctx)
    }

    /// Builds the initial mandatory HTTP headers for HTTP ugprade responses.
    private func buildUpgradeHeaders(`protocol`: String) -> HTTPHeaders {
        return HTTPHeaders([("connection", "upgrade"), ("upgrade", `protocol`)])
    }
}
