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


/// `NIOWebSocketFrameAggregator` buffers inbound fragmented `WebSocketFrame`'s and aggregates them into a single `WebSocketFrame`.
/// It guarantees that a `WebSocketFrame` with an `opcode` of `.continuation` is never forwarded.
/// Frames which are not fragmented are just forwarded without any processing.
/// Fragmented frames are unmasked, concatenated and forwarded as a new `WebSocketFrame` which is either a `.binary` or `.text` frame.
/// `extensionData`, `rsv1`, `rsv2` and `rsv3` are lost if a frame is fragmented because they cannot be concatenated.
/// - Note: `.ping`, `.pong`, `.closeConnection` frames are forwarded during frame aggregation
public final class NIOWebSocketFrameAggregator: ChannelInboundHandler {
    public enum Error: Swift.Error {
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
    private var accumulatedFrameSize: Int = 0
    
    
    /// Configures a `NIOWebSocketFrameAggregator`.
    /// - Parameters:
    ///   - minNonFinalFragmentSize: Minimum size in bytes of a fragment which is not the last fragment of a complete frame. Used to defend against many really small payloads.
    ///   - maxAccumulatedFrameCount: Maximum number of fragments which are allowed to result in a complete frame.
    ///   - maxAccumulatedFrameSize: Maximum accumulated size in bytes of buffered fragments. It is essentially the maximum allowed size of an incoming frame after all fragments are concatenated.
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
                guard let firstFrameOpcode = self.bufferedFrames.first?.opcode else {
                    throw Error.didReceiveFragmentBeforeReceivingTextOrBinaryFrame
                }
                try self.bufferFrame(frame)
                
                guard frame.fin else { break }
                // final frame received
                
                let aggregatedFrame = self.aggregateFrames(
                    opcode: firstFrameOpcode,
                    allocator: context.channel.allocator
                )
                self.clearBuffer()
                
                context.fireChannelRead(wrapInboundOut(aggregatedFrame))
            case .binary, .text:
                if frame.fin {
                    guard self.bufferedFrames.isEmpty else {
                        throw Error.receivedNewFrameWithoutFinishingPrevious
                    }
                    // fast path: no need to check any constraints nor unmask and copy data
                    context.fireChannelRead(data)
                } else {
                    try self.bufferFrame(frame)
                }
            default:
                // control frames can't be fragmented
                context.fireChannelRead(data)
            }
        } catch {
            // free memory early
            self.clearBuffer()
            context.fireErrorCaught(error)
        }
    }
    
    private func bufferFrame(_ frame: WebSocketFrame) throws {
        guard self.bufferedFrames.isEmpty || frame.opcode == .continuation else {
            throw Error.receivedNewFrameWithoutFinishingPrevious
        }
        guard frame.fin || frame.length >= self.minNonFinalFragmentSize else {
            throw Error.nonFinalFragmentSizeIsTooSmall
        }
        guard self.bufferedFrames.count < self.maxAccumulatedFrameCount else {
            throw Error.tooManyFragments
        }
        
        // if this is not a final frame, we will at least receive one more frame
        guard frame.fin || (self.bufferedFrames.count + 1) < self.maxAccumulatedFrameCount else {
            throw Error.tooManyFragments
        }
        
        self.bufferedFrames.append(frame)
        self.accumulatedFrameSize += frame.length
        
        guard self.accumulatedFrameSize <= self.maxAccumulatedFrameSize else {
            throw Error.accumulatedFrameSizeIsTooLarge
        }
    }
    
    private func aggregateFrames(opcode: WebSocketOpcode, allocator: ByteBufferAllocator) -> WebSocketFrame {
        var dataBuffer = allocator.buffer(capacity: self.accumulatedFrameSize)
        
        for frame in self.bufferedFrames {
            var unmaskedData = frame.unmaskedData
            dataBuffer.writeBuffer(&unmaskedData)
        }
        
        return WebSocketFrame(fin: true, opcode: opcode, data: dataBuffer)
    }
    
    private func clearBuffer() {
        self.bufferedFrames.removeAll(keepingCapacity: true)
        self.accumulatedFrameSize = 0
    }
}
