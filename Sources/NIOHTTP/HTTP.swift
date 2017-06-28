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

    public init() { }

    public func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?) {
        if let response:HTTPResponse = data.tryAsOther() {
            do {
                // TODO: Is 256 really a good value here ?
                var buffer = try ctx.channel!.allocator.buffer(capacity: 256)
                response.version.write(buffer: &buffer)
                response.status.write(buffer: &buffer)
                response.headers.write(buffer: &buffer)

                ctx.write(data: .byteBuffer(buffer), promise: promise)
            } catch let err {
                promise?.fail(error: err)
            }
        } else if let content: HTTPContent = data.tryAsOther()  {
            // TODO: Implement chunked encoding
            switch content {
            case .more(let buffer):
                ctx.write(data: .byteBuffer(buffer), promise: promise)
            case .last(let buffer):
                if let buf = buffer {
                    ctx.write(data: .byteBuffer(buf), promise: promise)
                } else if promise != nil {
                    // We only need to pass the promise further if the user is even interested in the result.
                    do {
                        // Empty content so just write an empty buffer
                        ctx.write(data: .byteBuffer(try ctx.channel!.allocator.buffer(capacity: 0)), promise: promise)
                    } catch let err {
                        promise?.fail(error: err)
                    }
                }
            }
        } else {
            ctx.write(data: data, promise: promise)
        }
    }
}
