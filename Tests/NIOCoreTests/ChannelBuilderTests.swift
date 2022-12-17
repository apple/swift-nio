//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIOCore
import NIOEmbedded
import NIOTestUtils

final class BytesToStringInboundHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var data = unwrapInboundIn(data)
        let string = data.readString(length: data.readableBytes)!
        context.fireChannelRead(wrapInboundOut(string))
    }
}

final class BytesToStringOutboundHandler: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = String
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var data = unwrapOutboundIn(data)
        let string = data.readString(length: data.readableBytes)!
        context.writeAndFlush(wrapOutboundOut(string), promise: promise)
    }
}

final class StringToIntInboundHandler<FWI: FixedWidthInteger>: ChannelInboundHandler {
    typealias InboundIn = String
    typealias InboundOut = FWI
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let string = unwrapInboundIn(data)
        let int = InboundOut(string)!
        context.fireChannelRead(wrapInboundOut(int))
    }
}

public final class ChannelTests: XCTestCase {
    func testSingleStepPipeline() async throws {
        let channel = EmbeddedChannel()
        try await channel.pipeline.addHandlers(
            reading: ByteBuffer.self,
            writing: ByteBuffer.self
        ) {
            BytesToStringInboundHandler()
        }
        
        try channel.writeInbound(ByteBuffer(string: "msg"))
        XCTAssertEqual(try channel.readInbound(as: String.self), "msg")
    }
    
    func testMisconfiguredPipelineFails() async throws {
        let channel = EmbeddedChannel()
        try await channel.pipeline.addHandlers(
            reading: ByteBuffer.self,
            writing: ByteBuffer.self
        ) {
            BytesToStringInboundHandler()
        }
        
        try channel.writeInbound(ByteBuffer(string: "msg"))
        await XCTAssertThrowsError(try channel.readInbound(as: ByteBuffer.self))
    }
    
    func testTwoStepPipeline() async throws {
        let channel = EmbeddedChannel()
        try await channel.pipeline.addHandlers(
            reading: ByteBuffer.self,
            writing: ByteBuffer.self
        ) {
            BytesToStringInboundHandler()
            StringToIntInboundHandler<Int>()
        }
        
        try channel.writeInbound(ByteBuffer(string: "2022"))
        XCTAssertEqual(try channel.readInbound(as: Int.self), 2022)
    }
}
