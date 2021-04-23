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

import NIO
import NIOHTTP1

#if compiler(>=5.5) // we cannot write this on one line with `&&` because Swift 5.0 doesn't like it...
#if compiler(>=5.5) && $AsyncAwait
@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
struct AsyncChannelIO<Request, Response> {
    let channel: Channel

    init(_ channel: Channel) {
        self.channel = channel
    }

    func start() async throws -> AsyncChannelIO<Request, Response> {
        try await channel.pipeline.addHandler(RequestResponseHandler<HTTPRequestHead, NIOHTTPClientResponseFull>()).get()
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
#endif
#endif
