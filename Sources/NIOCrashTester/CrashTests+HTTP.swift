//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if !canImport(Darwin) || os(macOS)
import NIOEmbedded
import NIOCore
import NIOHTTP1

struct HTTPCrashTests {
    let testEncodingChunkedAndContentLengthForRequestsCrashes = CrashTest(
        regex:
            "Assertion failed: illegal HTTP sent: HTTPRequestHead .* contains both a content-length and transfer-encoding:chunked",
        {
            let channel = EmbeddedChannel(handler: HTTPRequestEncoder())
            _ = try? channel.writeAndFlush(
                HTTPClientRequestPart.head(
                    HTTPRequestHead(
                        version: .http1_1,
                        method: .POST,
                        uri: "/",
                        headers: [
                            "content-Length": "1",
                            "transfer-Encoding": "chunked",
                        ]
                    )
                )
            ).wait()
        }
    )

    let testEncodingChunkedAndContentLengthForResponseCrashes = CrashTest(
        regex:
            "Assertion failed: illegal HTTP sent: HTTPResponseHead .* contains both a content-length and transfer-encoding:chunked",
        {
            let channel = EmbeddedChannel(handler: HTTPResponseEncoder())
            _ = try? channel.writeAndFlush(
                HTTPServerResponsePart.head(
                    HTTPResponseHead(
                        version: .http1_1,
                        status: .ok,
                        headers: [
                            "content-Length": "1",
                            "transfer-Encoding": "chunked",
                        ]
                    )
                )
            ).wait()
        }
    )
}
#endif
