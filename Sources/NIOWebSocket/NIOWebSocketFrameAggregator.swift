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
import NIO

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
    ///   - minNonFinalFragmentSize: Minimum size in bytes of a fragment which is not the last fragment of a complete frame. Used to defend agains many really small payloads.
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
                guard let firstFrameOpcode = bufferedFrames.first?.opcode else {
                    throw Error.didReceiveFragmentBeforeReceivingTextOrBinaryFrame
                }
                try bufferFrame(frame)

                guard frame.fin else { break }
                // final frame received

                let aggregatedFrame = aggregateFrames(
                    opcode: firstFrameOpcode,
                    allocator: context.channel.allocator
                )
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
        accumulatedFrameSize += frame.length

        guard accumulatedFrameSize <= maxAccumulatedFrameSize else {
            throw Error.accumulatedFrameSizeIsTooLarge
        }
    }

    private func aggregateFrames(opcode: WebSocketOpcode, allocator: ByteBufferAllocator) -> WebSocketFrame {
        var dataBuffer = allocator.buffer(capacity: accumulatedFrameSize)

        for frame in bufferedFrames {
            var unmaskedData = frame.unmaskedData
            dataBuffer.writeBuffer(&unmaskedData)
        }

        return WebSocketFrame(fin: true, opcode: opcode, data: dataBuffer)
    }

    private func clearBuffer() {
        bufferedFrames.removeAll(keepingCapacity: true)
        accumulatedFrameSize = 0
    }
}
