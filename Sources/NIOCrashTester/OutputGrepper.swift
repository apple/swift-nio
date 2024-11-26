//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import NIOFoundationCompat
import NIOPosix

import class Foundation.Pipe

internal struct OutputGrepper {
    internal var result: EventLoopFuture<ProgramOutput>
    internal var processOutputPipe: NIOFileHandle

    internal static func make(group: EventLoopGroup) -> OutputGrepper {
        let processToChannel = Pipe()

        let eventLoop = group.next()
        let outputPromise = eventLoop.makePromise(of: ProgramOutput.self)

        // We gotta `dup` everything because Pipe is bad and closes file descriptors on `deinit` :(
        let channelFuture = NIOPipeBootstrap(group: group)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(NewlineFramer()),
                        GrepHandler(promise: outputPromise),
                    ])
                }
            }
            .takingOwnershipOfDescriptor(input: dup(processToChannel.fileHandleForReading.fileDescriptor))
        let processOutputPipe = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: dup(processToChannel.fileHandleForWriting.fileDescriptor)
        )
        processToChannel.fileHandleForReading.closeFile()
        processToChannel.fileHandleForWriting.closeFile()
        channelFuture.cascadeFailure(to: outputPromise)
        return OutputGrepper(
            result: outputPromise.futureResult,
            processOutputPipe: processOutputPipe
        )
    }
}

typealias ProgramOutput = String

private final class GrepHandler: ChannelInboundHandler {
    typealias InboundIn = String

    private let promise: EventLoopPromise<ProgramOutput>

    init(promise: EventLoopPromise<ProgramOutput>) {
        self.promise = promise
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.promise.fail(error)
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = Self.unwrapInboundIn(data)
        if line.lowercased().contains("fatal error") || line.lowercased().contains("precondition failed")
            || line.lowercased().contains("assertion failed")
        {
            self.promise.succeed(line)
            context.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            self.promise.succeed("")
            context.close(promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.promise.fail(ChannelError.alreadyClosed)
    }
}

private struct NewlineFramer: ByteToMessageDecoder {
    typealias InboundOut = String

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let firstNewline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let length = firstNewline - buffer.readerIndex + 1
            context.fireChannelRead(Self.wrapInboundOut(String(buffer.readString(length: length)!.dropLast())))
            return .continue
        } else {
            return .needMoreData
        }
    }
}
