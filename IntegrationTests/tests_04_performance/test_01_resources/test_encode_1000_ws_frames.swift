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

import NIOCore
import NIOEmbedded
import NIOWebSocket

func doSendFramesHoldingBuffer(
    channel: EmbeddedChannel,
    number numberOfFrameSends: Int,
    data originalData: [UInt8],
    spareBytesAtFront: Int,
    mask: WebSocketMaskingKey? = nil
) throws -> Int {
    var data = channel.allocator.buffer(capacity: originalData.count + spareBytesAtFront)
    data.moveWriterIndex(forwardBy: spareBytesAtFront)
    data.moveReaderIndex(forwardBy: spareBytesAtFront)
    data.writeBytes(originalData)

    let frame = WebSocketFrame(opcode: .binary, maskKey: mask, data: data, extensionData: nil)

    // We're interested in counting allocations, so this test reads the data from the EmbeddedChannel
    // to force the data out of memory.
    for _ in 0..<numberOfFrameSends {
        channel.writeAndFlush(frame, promise: nil)
        _ = try channel.readOutbound(as: ByteBuffer.self)
        _ = try channel.readOutbound(as: ByteBuffer.self)
    }

    return numberOfFrameSends
}

func doSendFramesNewBuffer(
    channel: EmbeddedChannel,
    number numberOfFrameSends: Int,
    data originalData: [UInt8],
    spareBytesAtFront: Int,
    mask: WebSocketMaskingKey? = nil
) throws -> Int {
    for _ in 0..<numberOfFrameSends {
        // We need a new allocation every time to drop the original data ref.
        var data = channel.allocator.buffer(capacity: originalData.count + spareBytesAtFront)
        data.moveWriterIndex(forwardBy: spareBytesAtFront)
        data.moveReaderIndex(forwardBy: spareBytesAtFront)
        data.writeBytes(originalData)
        let frame = WebSocketFrame(opcode: .binary, maskKey: mask, data: data, extensionData: nil)

        // We're interested in counting allocations, so this test reads the data from the EmbeddedChannel
        // to force the data out of memory.
        channel.writeAndFlush(frame, promise: nil)
        _ = try channel.readOutbound(as: ByteBuffer.self)
        _ = try channel.readOutbound(as: ByteBuffer.self)
    }

    return numberOfFrameSends
}

func run(identifier: String) {
    let maskKey: WebSocketMaskingKey = [1, 2, 3, 4]
    let channel = EmbeddedChannel()
    try! channel.pipeline.addHandler(WebSocketFrameEncoder()).wait()
    let data = Array(repeating: UInt8(0), count: 1024)

    measure(identifier: identifier + "_holding_buffer") {
        let numberDone = try! doSendFramesHoldingBuffer(
            channel: channel,
            number: 1000,
            data: data,
            spareBytesAtFront: 0
        )
        precondition(numberDone == 1000)
        return numberDone
    }

    measure(identifier: identifier + "_holding_buffer_with_space") {
        let numberDone = try! doSendFramesHoldingBuffer(
            channel: channel,
            number: 1000,
            data: data,
            spareBytesAtFront: 8
        )
        precondition(numberDone == 1000)
        return numberDone
    }

    measure(identifier: identifier + "_holding_buffer_with_mask") {
        let numberDone = try! doSendFramesHoldingBuffer(
            channel: channel,
            number: 1000,
            data: data,
            spareBytesAtFront: 0,
            mask: maskKey
        )
        precondition(numberDone == 1000)
        return numberDone
    }

    measure(identifier: identifier + "_holding_buffer_with_space_with_mask") {
        let numberDone = try! doSendFramesHoldingBuffer(
            channel: channel,
            number: 1000,
            data: data,
            spareBytesAtFront: 8,
            mask: maskKey
        )
        precondition(numberDone == 1000)
        return numberDone
    }

    measure(identifier: identifier + "_new_buffer") {
        let numberDone = try! doSendFramesNewBuffer(channel: channel, number: 1000, data: data, spareBytesAtFront: 0)
        precondition(numberDone == 1000)
        return numberDone
    }

    measure(identifier: identifier + "_new_buffer_with_space") {
        let numberDone = try! doSendFramesNewBuffer(channel: channel, number: 1000, data: data, spareBytesAtFront: 8)
        precondition(numberDone == 1000)
        return numberDone
    }

    measure(identifier: identifier + "_new_buffer_with_mask") {
        let numberDone = try! doSendFramesNewBuffer(
            channel: channel,
            number: 1000,
            data: data,
            spareBytesAtFront: 0,
            mask: maskKey
        )
        precondition(numberDone == 1000)
        return numberDone
    }

    measure(identifier: identifier + "_new_buffer_with_space_with_mask") {
        let numberDone = try! doSendFramesNewBuffer(
            channel: channel,
            number: 1000,
            data: data,
            spareBytesAtFront: 8,
            mask: maskKey
        )
        precondition(numberDone == 1000)
        return numberDone
    }

    _ = try! channel.finish()
}
