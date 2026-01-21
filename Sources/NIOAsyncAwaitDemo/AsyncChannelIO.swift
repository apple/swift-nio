//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
struct AsyncChannelIO<Request: Sendable, Response: Sendable> {
    let channel: Channel

    init(_ channel: Channel) {
        self.channel = channel
    }

    func start() async throws -> AsyncChannelIO<Request, Response> {
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(
                RequestResponseHandler<HTTPRequestHead, NIOHTTPClientResponseFull>()
            )
        }.get()
        return self
    }

    func sendRequest(_ request: Request) async throws -> Response {
        let responsePromise: EventLoopPromise<Response> = channel.eventLoop.makePromise()
        try await self.channel.writeAndFlush((request, responsePromise)).get()
        return try await responsePromise.futureResult.get()
    }

    func close() async throws {
        try await self.channel.close()
    }
}
