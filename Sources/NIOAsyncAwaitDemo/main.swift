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
import _NIOConcurrency
import NIOHTTP1
import Dispatch

#if compiler(>=5.5) // we cannot write this on one line with `&&` because Swift 5.0 doesn't like it...
#if compiler(>=5.5) && $AsyncAwait

import _Concurrency

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer {
    try! group.syncShutdownGracefully()
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
func makeHTTPChannel(host: String, port: Int) async throws -> AsyncChannelIO<HTTPRequestHead, NIOHTTPClientResponseFull> {
    let channel = try await ClientBootstrap(group: group).connect(host: host, port: port).get()
    try await channel.pipeline.addHTTPClientHandlers().get()
    try await channel.pipeline.addHandler(NIOHTTPClientResponseAggregator(maxContentLength: 1_000_000))
    try await channel.pipeline.addHandler(MakeFullRequestHandler())
    return try await AsyncChannelIO<HTTPRequestHead, NIOHTTPClientResponseFull>(channel).start()
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
func main() async {
    do {
        let channel = try await makeHTTPChannel(host: "httpbin.org", port: 80)
        print("OK, connected to \(channel)")

        print("Sending request 1", terminator: "")
        let response1 = try await channel.sendRequest(HTTPRequestHead(version: .http1_1,
                                                                     method: .GET,
                                                                     uri: "/base64/SGVsbG8gV29ybGQsIGZyb20gSFRUUEJpbiEgCg==",
                                                                     headers: ["host": "httpbin.org"]))
        print(", response:", String(buffer: response1.body ?? ByteBuffer()))

        print("Sending request 2", terminator: "")
        let response2 = try await channel.sendRequest(HTTPRequestHead(version: .http1_1,
                                                                     method: .GET,
                                                                     uri: "/get",
                                                                     headers: ["host": "httpbin.org"]))
        print(", response:", String(buffer: response2.body ?? ByteBuffer()))

        try await channel.close()
        print("all, done")
    } catch {
        print("ERROR: \(error)")
    }
}

let dg = DispatchGroup()
dg.enter()
if #available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *) {
    detach {
        await main()
        dg.leave()
    }
} else {
    dg.leave()
}
dg.wait()
#else
print("ERROR: This demo only works with async/await enabled (NIO.System.hasAsyncAwaitSupport = \(NIO.System.hasAsyncAwaitSupport))")
print("Try:   swift run -Xswiftc -Xfrontend -Xswiftc -enable-experimental-concurrency NIOAsyncAwaitDemo")
#endif
#else
print("ERROR: Concurrency only supported on Swift > 5.4.")
#endif
