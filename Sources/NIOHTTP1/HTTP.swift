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

import Foundation
import NIO

public final class HTTPResponseEncoder : ChannelOutboundHandler {
    public typealias OutboundIn = HTTPResponse
    public typealias OutboundOut = ByteBuffer

    public init() {}

    public func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?) {
        switch self.tryUnwrapOutboundIn(data) {
        case .some(.head(let response)):
            // TODO: Is 256 really a good value here ?
            var buffer = ctx.channel!.allocator.buffer(capacity: 256)
            response.version.write(buffer: &buffer)
            response.status.write(buffer: &buffer)
            response.headers.write(buffer: &buffer)

            ctx.write(data: self.wrapOutboundOut(buffer), promise: promise)
        case .some(.body(.more(let buffer))):
                ctx.write(data: self.wrapOutboundOut(buffer), promise: promise)
        case .some(.body(.last(let buffer))):
            if let buf = buffer {
                ctx.write(data: self.wrapOutboundOut(buf), promise: promise)
            } else if promise != nil {
                // We only need to pass the promise further if the user is even interested in the result.
                // Empty content so just write an empty buffer
                ctx.write(data: self.wrapOutboundOut(ctx.channel!.allocator.buffer(capacity: 0)), promise: promise)
            }
        case .none:
            ctx.write(data: data, promise: promise)
        }
    }
}
