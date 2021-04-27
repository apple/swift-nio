//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIO

public final class NIOWebSocketFrameAggregator: ChannelInboundHandler {
    enum Error: Swift.Error {
        case nonFinalFragmentSizeIsTooSmall
        case tooManyFragments
        case accumulatedFrameSizeIsTooLarge
        case receivedNewFrameWithoutFinishingPrevious
        case didReceiveFragmentBeforeReceivingTextOrBinaryFrame
    }
    public typealias InboundIn = WebSocketFrame
    public typealias InboundOut = WebSocketFrame
    
    private let minNonFinalFragmentSize: Int
    private let maxAccumulatedFrameCount: Int
    private let maxAccumulatedFrameSize: Int
    
    private var bufferedFrames: [WebSocketFrame] = []
    private var accumulatedFrameSize: Int {
        bufferedFrames
            .map({ $0.length })
            .reduce(0, +)
    }
    
    public init(
        minNonFinalFragmentSize: Int,
        maxAccumulatedFrameCount: Int,
        maxAccumulatedFrameSize: Int
    ) {
        self.minNonFinalFragmentSize = minNonFinalFragmentSize
        self.maxAccumulatedFrameCount = maxAccumulatedFrameCount
        self.maxAccumulatedFrameSize = maxAccumulatedFrameSize
    }
    
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        do {
            switch frame.opcode {
            case .continuation:
                guard let firstFrameOpcode = bufferedFrames.first?.opcode else {
                    throw Error.didReceiveFragmentBeforeReceivingTextOrBinaryFrame
                }
                try bufferFrame(frame)
                
                guard frame.fin else { break }
                // final frame received
                
                let aggregatedFrame = aggregateFrames(frames: bufferedFrames, opcode: firstFrameOpcode)
                clearBuffer()
                
                context.fireChannelRead(wrapInboundOut(aggregatedFrame))
            case .binary, .text:
                if frame.fin {
                    guard bufferedFrames.isEmpty else {
                        throw Error.receivedNewFrameWithoutFinishingPrevious
                    }
                    // fast path: no need to check any constraints nor unmask and copy data
                    context.fireChannelRead(data)
                } else {
                    try bufferFrame(frame)
                }
            default:
                // control frames can't be fragmented
                context.fireChannelRead(data)
            }
        } catch {
            // free memory early
            clearBuffer()
            context.fireErrorCaught(error)
        }
    }
    
    private func bufferFrame(_ frame: WebSocketFrame) throws {
        guard bufferedFrames.isEmpty || frame.opcode == .continuation else {
            throw Error.receivedNewFrameWithoutFinishingPrevious
        }
        guard frame.fin || frame.length >= minNonFinalFragmentSize else {
            throw Error.nonFinalFragmentSizeIsTooSmall
        }
        guard bufferedFrames.count < maxAccumulatedFrameCount else {
            throw Error.tooManyFragments
        }
        
        // if this is not a final frame, we will at least receive one more frame
        guard frame.fin || (bufferedFrames.count + 1) < maxAccumulatedFrameCount else {
            throw Error.tooManyFragments
        }
        
        bufferedFrames.append(frame)
        
        guard accumulatedFrameSize <= maxAccumulatedFrameSize else {
            throw Error.accumulatedFrameSizeIsTooLarge
        }
    }
    
    private func aggregateFrames(frames: [WebSocketFrame], opcode: WebSocketOpcode) -> WebSocketFrame {
        var dataBuffer = ByteBuffer()
        dataBuffer.reserveCapacity(minimumWritableBytes: accumulatedFrameSize)
        
        for frame in bufferedFrames {
            var unmaskedData = frame.unmaskedData
            dataBuffer.writeBuffer(&unmaskedData)
        }
        
        return WebSocketFrame(fin: true, opcode: opcode, data: dataBuffer)
    }
    
    private func clearBuffer() {
        bufferedFrames = []
    }
}
