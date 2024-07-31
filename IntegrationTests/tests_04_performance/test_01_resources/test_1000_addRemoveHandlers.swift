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
import NIOEmbedded

private final class RemovableHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    static let name: String = "RemovableHandler"

    var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }
}

@inline(__always)
private func addRemoveBench(
    iterations: Int,
    _ removalOperation: (Channel, RemovableHandler) -> EventLoopFuture<Void>
) -> Int {
    let channel = EmbeddedChannel()
    defer {
        _ = try! channel.finish()
    }

    for _ in 0..<iterations {
        let handler = RemovableHandler()
        try! channel.pipeline.syncOperations.addHandler(handler, name: RemovableHandler.name)
        try! removalOperation(channel, handler).wait()
    }

    return iterations
}

func run(identifier: String) {
    measure(identifier: identifier + "_handlertype") {
        addRemoveBench(iterations: 1000) { channel, handler in
            channel.pipeline.removeHandler(handler)
        }
    }

    measure(identifier: identifier + "_handlername") {
        addRemoveBench(iterations: 1000) { channel, _ in
            channel.pipeline.removeHandler(name: RemovableHandler.name)
        }
    }

    measure(identifier: identifier + "_handlercontext") {
        addRemoveBench(iterations: 1000) { channel, handler in
            channel.pipeline.removeHandler(context: handler.context!)
        }
    }
}
