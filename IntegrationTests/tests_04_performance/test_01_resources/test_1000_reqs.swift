//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
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

func run(identifier: String) {
    let numberOfRequests = 1000
    
    let serverChannel = try! makeServerChannel()
    defer {
        try! serverChannel.close().wait()
    }
    
    let eventLoop = group.next()
    let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: numberOfRequests, eventLoop: eventLoop)

    let clientChannel = try! ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    return channel.pipeline.addHandler(repeatedRequestsHandler)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait()
    defer {
        try! clientChannel.close().wait()
    }
    
    measure(identifier: identifier) {
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(RepeatedRequests.requestHead)), promise: nil)
        try! clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
        repeatedRequestsHandler.reset(eventLoop: eventLoop)
        return try! repeatedRequestsHandler.wait()
    }
}
