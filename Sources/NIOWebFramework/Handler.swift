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
import NIOHTTP1

class Handler: ChannelInboundHandler {
    private enum FileIOMethod {
        case sendfile
        case nonblockingFileIO
    }
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart
    
    private var requestUri: String?
    private var keepAlive = false
    
    private let fileIO: NonBlockingFileIO
    private let router: Router
    
    public init(fileIO: NonBlockingFileIO, router: Router) {
        self.fileIO = fileIO
        self.router = router
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        
        switch reqPart {
        case .head(let request):
            keepAlive = request.isKeepAlive
            var buffer: ByteBuffer
            
            if let routerHandler = router.routingTable[request.uri] {
                let responseBody = routerHandler.respond()
                
                buffer = ctx.channel.allocator.buffer(capacity: responseBody.lengthOfBytes(using: String.Encoding.utf8))
                buffer.write(string: responseBody)
            }
            else {
                buffer = ctx.channel.allocator.buffer(capacity: 5)
                buffer.write(staticString: "ERROR")
            }
                
            var responseHead = HTTPResponseHead(version: request.version, status: HTTPResponseStatus.ok)
            responseHead.headers.add(name: "content-length", value: String(buffer.readableBytes))
            let response = HTTPServerResponsePart.head(responseHead)
            ctx.write(self.wrapOutboundOut(response), promise: nil)
            
            let content = HTTPServerResponsePart.body(.byteBuffer(buffer.slice()))
            ctx.write(self.wrapOutboundOut(content), promise: nil)
        case .body:
            break
        case .end:
            if keepAlive {
                ctx.write(self.wrapOutboundOut(HTTPServerResponsePart.end(nil)), promise: nil)
            } else {
                ctx.write(self.wrapOutboundOut(HTTPServerResponsePart.end(nil))).whenComplete {
                    ctx.close(promise: nil)
                }
            }
        }
    }
    
    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush()
    }
}
