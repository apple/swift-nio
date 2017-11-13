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

import NIO
import CNIOOpenSSL
import NIOTLS

/// The base class for all OpenSSL handlers. This class cannot actually be instantiated by
/// users directly: instead, users must select which mode they would like their handler to
/// operate in, client or server.
///
/// This class exists to deal with the reality that for almost the entirety of the lifetime
/// of a TLS connection there is no meaningful distinction between a server and a client.
/// For this reason almost the entirety of the implementation for the channel and server
/// handlers in OpenSSL is shared, in the form of this parent class.
public class OpenSSLHandler : ChannelInboundHandler, ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias InboundUserEventOut = TLSUserEvent

    private enum ConnectionState {
        case idle
        case handshaking
        case active
        case closing
        case closed
    }

    private var state: ConnectionState = .idle
    private var connection: SSLConnection
    private var bufferedWrites: MarkedCircularBuffer<BufferedEvent>
    private var closePromise: Promise<Void>?
    private var didDeliverData: Bool = false
    
    internal init (connection: SSLConnection) {
        self.connection = connection
        self.bufferedWrites = MarkedCircularBuffer(initialRingCapacity: 96)  // 96 brings the total size of the buffer to just shy of one page
    }

    public func handlerAdded(ctx: ChannelHandlerContext) {
        // If this channel is already active, immediately begin handshaking.
        if ctx.channel!.isActive {
            doHandshakeStep(ctx: ctx)
        }
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        // We fire this a bit early, entirely on purpose. This is because
        // in doHandshakeStep we may end up closing the channel again, and
        // if we do we want to make sure that the channelInactive message received
        // by later channel handlers makes sense.
        ctx.fireChannelActive()
        doHandshakeStep(ctx: ctx)
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) {
        // This fires when the TCP connection goes away.
        switch state {
        case .closed, .idle:
            // Nothing to do, but discard any buffered writes we still have.
            discardBufferedWrites(reason: ChannelError.ioOnClosedChannel)
        default:
            // This is a ragged EOF: we weren't sent a CLOSE_NOTIFY. We want to send a user
            // event to notify about this before we propagate channelInactive. We also want to fail all
            // these writes.
            ctx.fireErrorCaught(error: OpenSSLError.uncleanShutdown)
            discardBufferedWrites(reason: OpenSSLError.uncleanShutdown)
        }
        
        state = .closed
        ctx.fireChannelInactive()
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var binaryData = unwrapInboundIn(data)
        
        // The logic: feed the buffers, then take an action based on state.
        connection.consumeDataFromNetwork(&binaryData)
        
        switch state {
        case .handshaking:
            doHandshakeStep(ctx: ctx)
        case .active:
            doDecodeData(ctx: ctx)
            doUnbufferWrites(ctx: ctx)
        case .closing:
            doShutdownStep(ctx: ctx)
        default:
            fatalError("Read during invalid TLS state")
        }
    }
    
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        // We only want to fire channelReadComplete in a situation where we have actually sent the user some data, otherwise
        // we'll be confusing the hell out of them.
        if didDeliverData {
            didDeliverData = false
            ctx.fireChannelReadComplete()
        } else {
            // We didn't deliver data. If this channel has got autoread turned off then we should
            // call read again, because otherwise the user will never see any result from their
            // read call.
            let autoRead = try! ctx.channel!.getOption(option: ChannelOptions.AutoRead)
            if !autoRead {
                ctx.read(promise: nil)
            }
        }
    }
    
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: Promise<Void>?) {
        bufferWrite(data: unwrapOutboundIn(data), promise: promise)
    }

    public func flush(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        bufferFlush(promise: promise)
        doUnbufferWrites(ctx: ctx)
    }
    
    public func close(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        switch state {
        case .closing:
            // We're in the process of TLS shutdown, so let's let that happen. However,
            // we want to cascade the result of the first request into this new one.
            if let promise = promise {
                closePromise!.futureResult.cascade(promise: promise)
            }
        case .idle:
            state = .closed
            fallthrough
        case .closed:
            // For idle and closed connections we immediately pass this on to the next
            // channel handler.
            ctx.close(promise: promise)
        default:
            // We need to begin processing shutdown now. We can't fire the promise for a
            // while though.
            closePromise = promise
            doShutdownStep(ctx: ctx)
        }
    }
    
    private func doHandshakeStep(ctx: ChannelHandlerContext) {
        let result = connection.doHandshake()
        
        switch result {
        case .incomplete:
            state = .handshaking
            writeDataToNetwork(ctx: ctx, promise: nil)
        case .complete:
            state = .active
            writeDataToNetwork(ctx: ctx, promise: nil)
            
            // TODO(cory): This event should probably fire out of the OpenSSL info callback.
            let negotiatedProtocol = connection.getAlpnProtocol()
            ctx.fireUserInboundEventTriggered(event: wrapInboundUserEventOut(TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiatedProtocol)))
            
            // We need to unbuffer any pending writes. We will have pending writes if the user attempted to write
            // before we completed the handshake.
            doUnbufferWrites(ctx: ctx)
        case .failed(let err):
            writeDataToNetwork(ctx: ctx, promise: nil)
            
            // TODO(cory): This event should probably fire out of the OpenSSL info callback.
            ctx.fireErrorCaught(error: NIOOpenSSLError.handshakeFailed(err))
            channelClose(ctx: ctx)
        }
    }
    
    private func doShutdownStep(ctx: ChannelHandlerContext) {
        let result = connection.doShutdown()
        
        switch result {
        case .incomplete:
            state = .closing
            writeDataToNetwork(ctx: ctx, promise: nil)
        case .complete:
            state = .closed
            writeDataToNetwork(ctx: ctx, promise: nil)

            // TODO(cory): This should probably fire out of the OpenSSL info callback.
            ctx.fireUserInboundEventTriggered(event: wrapInboundUserEventOut(TLSUserEvent.shutdownCompleted))
            channelClose(ctx: ctx)
        case .failed(let err):
            // TODO(cory): This should probably fire out of the OpenSSL info callback.
            ctx.fireErrorCaught(error:NIOOpenSSLError.shutdownFailed(err))
            channelClose(ctx: ctx)
        }
    }
    
    private func doDecodeData(ctx: ChannelHandlerContext) {
        readLoop: while true {
            let result = connection.readDataFromNetwork(allocator: ctx.channel!.allocator)
            
            switch result {
            case .complete(let buf):
                // TODO(cory): Should we coalesce these instead of dispatching multiple times? I think so!
                // It'll also let us avoid this weird boolean flag, which is always good.
                didDeliverData = true
                ctx.fireChannelRead(data: self.wrapInboundOut(buf))
            case .incomplete:
                break readLoop
            case .failed(OpenSSLError.zeroReturn):
                // This is a clean EOF: we can just start doing our own clean shutdown.
                doShutdownStep(ctx: ctx)
                writeDataToNetwork(ctx: ctx, promise: nil)
                break readLoop
            case .failed(let err):
                ctx.fireErrorCaught(error: err)
                channelClose(ctx: ctx)
            }
        }
    }
    
    private func writeDataToNetwork(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        // There may be no data to write, in which case we can just exit early.
        guard let dataToWrite = connection.getDataForNetwork(allocator: ctx.channel!.allocator) else {
            promise?.succeed(result: ())
            return
        }

        ctx.writeAndFlush(data: self.wrapInboundOut(dataToWrite), promise: promise)
    }

    /// Close the underlying channel.
    ///
    /// This method does not perform any kind of I/O. Instead, it simply calls ChannelHandlerContext.close with
    /// any promise we may have already been given. It also transitions our state into closed. This should only be
    /// used to clean up after an error, or to perform the final call to close after a clean shutdown attempt.
    private func channelClose(ctx: ChannelHandlerContext) {
        state = .closed
        let closePromise = self.closePromise
        self.closePromise = nil
        ctx.close(promise: closePromise)
    }
}


// MARK: Code that handles buffering/unbuffering writes.
extension OpenSSLHandler {
    private enum BufferedEvent {
        case write(BufferedWrite)
        case flush(Promise<Void>?)
    }
    private typealias BufferedWrite = (data: ByteBuffer, promise: Promise<Void>?)

    private func bufferWrite(data: ByteBuffer, promise: Promise<Void>?) {
        bufferedWrites.append(.write((data: data, promise: promise)))
    }

    private func bufferFlush(promise: Promise<Void>?) {
        bufferedWrites.append(.flush(promise))
        bufferedWrites.mark()
    }

    private func discardBufferedWrites(reason: Error) {
        while bufferedWrites.count > 0 {
            let promise: Promise<Void>?
            switch bufferedWrites.removeFirst() {
            case .write(_, let p):
                promise = p
            case .flush(let p):
                promise = p
            }

            promise?.fail(error: reason)
        }
    }

    private func doUnbufferWrites(ctx: ChannelHandlerContext) {
        // Return early if the user hasn't called flush.
        guard bufferedWrites.hasMark() else {
            return
        }

        // These are some annoying variables we use to persist state across invocations of
        // our closures. A better version of this code might be able to simplify this somewhat.
        var writeCount = 0
        var promises: [Promise<Void>] = []

        /// Given a byte buffer to encode, passes it to OpenSSL and handles the result.
        func encodeWrite(buf: inout ByteBuffer, promise: Promise<Void>?) throws -> Bool {
            let result = connection.writeDataToNetwork(&buf)

            switch result {
            case .complete:
                if let promise = promise { promises.append(promise) }
                writeCount += 1
                return true
            case .incomplete:
                // Ok, we can't write. Let's stop.
                // We believe this can only ever happen on the first attempt to write.
                precondition(writeCount == 0, "Unexpected change in OpenSSL state during write unbuffering: write count \(writeCount)")
                return false
            case .failed(let err):
                // Once a write fails, all writes must fail. This includes prior writes
                // that successfully made it through OpenSSL.
                throw err
            }
        }

        /// Given a flush request, grabs the data from OpenSSL and flushes it to the network.
        func flushData(userFlushPromise: Promise<Void>?) throws -> Bool {
            // This is a flush. We can go ahead and flush now.
            if let promise = userFlushPromise { promises.append(promise) }
            let ourPromise: Promise<Void> = ctx.eventLoop.newPromise()
            promises.forEach { ourPromise.futureResult.cascade(promise: $0) }
            writeDataToNetwork(ctx: ctx, promise: ourPromise)
            return true
        }

        do {
            try bufferedWrites.forEachElementUntilMark { element in
                switch element {
                case .write(var d, let p):
                    return try encodeWrite(buf: &d, promise: p)
                case .flush(let p):
                    return try flushData(userFlushPromise: p)
                }
            }
        } catch {
            // We encountered an error, it's cleanup time. Close ourselves down.
            channelClose(ctx: ctx)
            // Fail any writes we've previously encoded but not flushed.
            promises.forEach { $0.fail(error: error) }
            // Fail everything else.
            bufferedWrites.forEachRemoving {
                switch $0 {
                case .write(_, let p), .flush(let p):
                    p?.fail(error: error)
                }
            }
        }
    }
}

fileprivate extension MarkedCircularBuffer {
    fileprivate mutating func forEachElementUntilMark(callback: (E) throws -> Bool) rethrows {
        while try self.hasMark() && callback(self.first!) {
            _ = self.removeFirst()
        }
    }

    fileprivate mutating func forEachRemoving(callback: (E) -> Void) {
        while self.count > 0 {
            callback(self.removeFirst())
        }
    }
}
