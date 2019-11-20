//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
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

let localhostPickPort = try! SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0)
let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

final class RepeatedRequests: ChannelInboundHandler {
	typealias InboundIn = HTTPClientResponsePart
	typealias OutboundOut = HTTPClientRequestPart

	private let numberOfRequests: Int
	private var remainingNumberOfRequests: Int
	private let isDonePromise: EventLoopPromise<Int>
	static var requestHead: HTTPRequestHead {
		var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/allocation-test-1")
		head.headers.add(name: "Host", value: "foo-\(ObjectIdentifier(self)).com")
		return head
	}

	init(numberOfRequests: Int, eventLoop: EventLoop) {
		self.remainingNumberOfRequests = numberOfRequests
		self.numberOfRequests = numberOfRequests
		self.isDonePromise = eventLoop.makePromise()
	}

	func wait() throws -> Int {
		let reqs = try self.isDonePromise.futureResult.wait()
		precondition(reqs == self.numberOfRequests)
		return reqs
	}

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		context.channel.close(promise: nil)
		self.isDonePromise.fail(error)
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let respPart = self.unwrapInboundIn(data)
		if case .end(nil) = respPart {
			if self.remainingNumberOfRequests <= 0 {
				context.channel.close().map { self.numberOfRequests - self.remainingNumberOfRequests }.cascade(to: self.isDonePromise)
			} else {
				self.remainingNumberOfRequests -= 1
				context.write(self.wrapOutboundOut(.head(RepeatedRequests.requestHead)), promise: nil)
				context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
			}
		}
	}
}

private final class SimpleHTTPServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let bodyLength = 100
    private let numberOfAdditionalHeaders = 3

    private var responseHead: HTTPResponseHead {
        var head = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok)
        head.headers.add(name: "Content-Length", value: "\(self.bodyLength)")
        for i in 0..<self.numberOfAdditionalHeaders {
            head.headers.add(name: "X-Random-Extra-Header", value: "\(i)")
        }
        return head
    }

    private func responseBody(allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: self.bodyLength)
        for i in 0..<self.bodyLength {
            buffer.writeInteger(UInt8(i % Int(UInt8.max)))
        }
        return buffer
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let req) = self.unwrapInboundIn(data), req.uri == "/allocation-test-1" {
            context.write(self.wrapOutboundOut(.head(self.responseHead)), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(self.responseBody(allocator: context.channel.allocator)))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

func doRequests(group: EventLoopGroup, number numberOfRequests: Int) throws -> Int {
    let serverChannel = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.Types.SocketOption.allowLocalAddressReuse, value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true,
                                                         withErrorHandling: false).flatMap {
                channel.pipeline.addHandler(SimpleHTTPServer())
            }
        }.bind(to: localhostPickPort).wait()

    defer {
        try! serverChannel.close().wait()
    }


    let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: numberOfRequests, eventLoop: group.next())

    let clientChannel = try ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHTTPClientHandlers().flatMap {
                channel.pipeline.addHandler(repeatedRequestsHandler)
            }
        }
        .connect(to: serverChannel.localAddress!)
        .wait()

    clientChannel.write(NIOAny(HTTPClientRequestPart.head(RepeatedRequests.requestHead)), promise: nil)
    try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
    return try repeatedRequestsHandler.wait()
}

func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try execute()
    #else
    return try autoreleasepool {
        try execute()
    }
    #endif
}
