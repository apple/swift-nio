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

#if compiler(>=5.5) && canImport(_Concurrency)

/// An object that implements `AsyncHTTPServerProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol on a server-side channel.
///
/// This is an async version of `HTTPServerProtocolUpgrader`
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
public protocol AsyncHTTPServerProtocolUpgrader: HTTPServerProtocolUpgrader {
    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// fail the future.
    func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) async throws -> HTTPHeaders

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required. Until the function returns, all received
    /// data will be buffered.
    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) async throws
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AsyncHTTPServerProtocolUpgrader {
    func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        let promise = channel.eventLoop.makePromise(of: HTTPHeaders.self)
        promise.completeWithTask {
            try await buildUpgradeResponse(channel: channel, upgradeRequest: upgradeRequest, initialResponseHeaders: initialResponseHeaders)
        }
        return promise.futureResult
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        promise.completeWithTask {
            try await upgrade(context: context, upgradeRequest: upgradeRequest)
        }
        return promise.futureResult
    }
}

#endif
