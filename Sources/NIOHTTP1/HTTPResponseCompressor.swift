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

import CNIOZlib
import NIO

internal extension String {
    /// Test if this `Collection` starts with the unicode scalars of `needle`.
    ///
    /// - note: This will be faster than `String.startsWith` as no unicode normalisations are performed.
    ///
    /// - parameters:
    ///    - needle: The `Collection` of `Unicode.Scalar`s to match at the beginning of `self`
    /// - returns: If `self` started with the elements contained in `needle`.
    func startsWithSameUnicodeScalars<S: StringProtocol>(string needle: S) -> Bool {
        return self.unicodeScalars.starts(with: needle.unicodeScalars)
    }
}


/// Given a header value, extracts the q value if there is one present. If one is not present,
/// returns the default q value, 1.0.
private func qValueFromHeader(_ text: String) -> Float {
    let headerParts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
    guard headerParts.count > 1 && headerParts[1].count > 0 else {
        return 1
    }

    // We have a Q value.
    let qValue = Float(headerParts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[1]) ?? 0
    if qValue < 0 || qValue > 1 || qValue.isNaN {
        return 0
    }
    return qValue
}

/// A HTTPResponseCompressor is a duplex channel handler that handles automatic streaming compression of
/// HTTP responses. It respects the client's Accept-Encoding preferences, including q-values if present,
/// and ensures that clients are served the compression algorithm that works best for them.
///
/// This compressor supports gzip and deflate. It works best if many writes are made between flushes.
///
/// Note that this compressor performs the compression on the event loop thread. This means that compressing
/// some resources, particularly those that do not benefit from compression or that could have been compressed
/// ahead-of-time instead of dynamically, could be a waste of CPU time and latency for relatively minimal
/// benefit. This channel handler should be present in the pipeline only for dynamically-generated and
/// highly-compressible content, which will see the biggest benefits from streaming compression.
public final class HTTPResponseCompressor: ChannelDuplexHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    public enum CompressionError: Error {
        case uncompressedWritesPending
        case noDataToWrite
    }

    fileprivate enum CompressionAlgorithm: String {
        case gzip = "gzip"
        case deflate = "deflate"
    }

    // Private variable for storing stream data.
    private var stream = z_stream()

    private var algorithm: CompressionAlgorithm?

    // A queue of accept headers.
    private var acceptQueue = CircularBuffer<[String]>(initialRingCapacity: 8)

    private var pendingResponse: PartialHTTPResponse!
    private var pendingWritePromise: EventLoopPromise<Void>!

    private let initialByteBufferCapacity: Int

    public init(initialByteBufferCapacity: Int = 1024) {
        self.initialByteBufferCapacity = initialByteBufferCapacity
    }

    public func handlerAdded(ctx: ChannelHandlerContext) {
        pendingResponse = PartialHTTPResponse(bodyBuffer: ctx.channel.allocator.buffer(capacity: initialByteBufferCapacity))
        pendingWritePromise = ctx.eventLoop.newPromise()
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        pendingWritePromise?.fail(error: CompressionError.uncompressedWritesPending)
        if algorithm != nil {
            deinitializeEncoder()
            algorithm = nil
        }
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if case .head(let requestHead) = unwrapInboundIn(data) {
            acceptQueue.append(requestHead.headers[canonicalForm: "accept-encoding"])
        }

        ctx.fireChannelRead(data)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let httpData = unwrapOutboundIn(data)
        switch httpData {
        case .head(var responseHead):
            algorithm = compressionAlgorithm()
            guard algorithm != nil else {
                ctx.write(wrapOutboundOut(.head(responseHead)), promise: promise)
                return
            }

            responseHead.headers.add(name: "Content-Encoding", value: algorithm!.rawValue)
            initializeEncoder(encoding: algorithm!)
            pendingResponse.bufferResponseHead(responseHead)
            chainPromise(promise)
        case .body(let body):
            if algorithm != nil {
                pendingResponse.bufferBodyPart(body)
                chainPromise(promise)
            } else {
                ctx.write(data, promise: promise)
            }
        case .end:
            // This compress is not done in flush because we need to be done with the
            // compressor now.
            guard algorithm != nil else {
                ctx.write(data, promise: promise)
                return
            }

            pendingResponse.bufferResponseEnd(httpData)
            chainPromise(promise)
            emitPendingWrites(ctx: ctx)
            algorithm = nil
            deinitializeEncoder()
        }
    }

    public func flush(ctx: ChannelHandlerContext) {
        emitPendingWrites(ctx: ctx)
        ctx.flush()
    }

    /// Determines the compression algorithm to use for the next response.
    ///
    /// Returns the compression algorithm to use, or nil if the next response
    /// should not be compressed.
    private func compressionAlgorithm() -> CompressionAlgorithm? {
        let acceptHeaders = acceptQueue.removeFirst()

        var gzipQValue: Float = -1
        var deflateQValue: Float = -1
        var anyQValue: Float = -1

        for acceptHeader in acceptHeaders {
            if acceptHeader.startsWithSameUnicodeScalars(string: "gzip") || acceptHeader.startsWithSameUnicodeScalars(string: "x-gzip") {
                gzipQValue = qValueFromHeader(acceptHeader)
            } else if acceptHeader.startsWithSameUnicodeScalars(string: "deflate") {
                deflateQValue = qValueFromHeader(acceptHeader)
            } else if acceptHeader.startsWithSameUnicodeScalars(string: "*") {
                anyQValue = qValueFromHeader(acceptHeader)
            }
        }

        if gzipQValue > 0 || deflateQValue > 0 {
            return gzipQValue > deflateQValue ? .gzip : .deflate
        } else if anyQValue > 0 {
            // Though gzip is usually less well compressed than deflate, it has slightly
            // wider support because it's unabiguous. We therefore default to that unless
            // the client has expressed a preference.
            return .gzip
        }

        return nil
    }

    /// Set up the encoder for compressing data according to a specific
    /// algorithm.
    private func initializeEncoder(encoding: CompressionAlgorithm) {
        // zlib docs say: The application must initialize zalloc, zfree and opaque before calling the init function.
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        let windowBits: Int32
        switch encoding {
        case .deflate:
            windowBits = 15
        case .gzip:
            windowBits = 16 + 15
        }

        let rc = CNIOZlib_deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY)
        precondition(rc == Z_OK, "Unexpected return from zlib init: \(rc)")
    }

    private func deinitializeEncoder() {
        // We deliberately discard the result here because we just want to free up
        // the pending data.
        deflateEnd(&stream)
    }

    private func chainPromise(_ promise: EventLoopPromise<Void>?) {
        if let promise = promise {
            pendingWritePromise.futureResult.cascade(promise: promise)
        }
    }

    /// Emits all pending buffered writes to the network, optionally compressing the
    /// data. Resets the pending write buffer and promise.
    ///
    /// Called either when a HTTP end message is received or our flush() method is called.
    private func emitPendingWrites(ctx: ChannelHandlerContext) {
        let writesToEmit = pendingResponse.flush(compressor: &stream, allocator: ctx.channel.allocator)
        var pendingPromise = pendingWritePromise

        if let writeHead = writesToEmit.0 {
            ctx.write(wrapOutboundOut(.head(writeHead)), promise: pendingPromise)
            pendingPromise = nil
        }

        if let writeBody = writesToEmit.1 {
            ctx.write(wrapOutboundOut(.body(.byteBuffer(writeBody))), promise: pendingPromise)
            pendingPromise = nil
        }

        if let writeEnd = writesToEmit.2 {
            ctx.write(wrapOutboundOut(writeEnd), promise: pendingPromise)
            pendingPromise = nil
        }

        // If we still have the pending promise, we never emitted a write. Fail the promise,
        // as anything that is listening for its data somehow lost it.
        if let stillPendingPromise = pendingPromise {
            stillPendingPromise.fail(error: CompressionError.noDataToWrite)
        }

        // Reset the pending promise.
        pendingWritePromise = ctx.eventLoop.newPromise()
    }
}
/// A buffer object that allows us to keep track of how much of a HTTP response we've seen before
/// a flush.
///
/// The strategy used in this module is that we want to have as much information as possible before
/// we compress, and to compress as few times as possible. This is because in the ideal situation we
/// will have a complete HTTP response to compress in one shot, allowing us to update the content
/// length, rather than force the response to be chunked. It is much easier to do the right thing
/// if we can encapsulate our ideas about how HTTP responses in an entity like this.
private struct PartialHTTPResponse {
    var head: HTTPResponseHead?
    var body: ByteBuffer
    var end: HTTPServerResponsePart?
    private let initialBufferSize: Int

    var isCompleteResponse: Bool {
        return head != nil && end != nil
    }

    var mustFlush: Bool {
        return end != nil
    }

    init(bodyBuffer: ByteBuffer) {
        body = bodyBuffer
        initialBufferSize = bodyBuffer.capacity
    }

    mutating func bufferResponseHead(_ head: HTTPResponseHead) {
        precondition(self.head == nil)
        self.head = head
    }

    mutating func bufferBodyPart(_ bodyPart: IOData) {
        switch bodyPart {
        case .byteBuffer(var buffer):
            body.write(buffer: &buffer)
        case .fileRegion:
            fatalError("Cannot currently compress file regions")
        }
    }

    mutating func bufferResponseEnd(_ end: HTTPServerResponsePart) {
        precondition(self.end == nil)
        guard case .end = end else {
            fatalError("Buffering wrong entity type: \(end)")
        }
        self.end = end
    }

    private mutating func clear() {
        head = nil
        end = nil
        body.clear()
        body.reserveCapacity(initialBufferSize)
    }

    mutating private func compressBody(compressor: inout z_stream, allocator: ByteBufferAllocator, flag: Int32) -> ByteBuffer? {
        guard body.readableBytes > 0 else {
            return nil
        }

        // deflateBound() provides an upper limit on the number of bytes the input can
        // compress to. We add 5 bytes to handle the fact that Z_SYNC_FLUSH will append
        // an empty stored block that is 5 bytes long.
        let bufferSize = Int(deflateBound(&compressor, UInt(body.readableBytes)))
        var outputBuffer = allocator.buffer(capacity: bufferSize)

        // Now do the one-shot compression. All the data should have been consumed.
        compressor.oneShotDeflate(from: &body, to: &outputBuffer, flag: flag)
        precondition(body.readableBytes == 0)
        precondition(outputBuffer.readableBytes > 0)
        return outputBuffer
    }

    /// Flushes the buffered data into its constituent parts.
    ///
    /// Returns a three-tuple of a HTTP response head, compressed body bytes, and any end that
    /// may have been buffered. Each of these types is optional.
    ///
    /// If the head is flushed, it will have had its headers mutated based on whether we had the whole
    /// response or not. If nil, the head has previously been emitted.
    ///
    /// If the body is nil, it means no writes were buffered (that is, our buffer of bytes has no
    /// readable bytes in it). This should usually mean that no write is issued.
    ///
    /// Calling this function resets the buffer, freeing any excess memory allocated in the internal
    /// buffer and losing all copies of the other HTTP data. At this point it may freely be reused.
    mutating func flush(compressor: inout z_stream, allocator: ByteBufferAllocator) -> (HTTPResponseHead?, ByteBuffer?, HTTPServerResponsePart?) {
        let flag = mustFlush ? Z_FINISH : Z_SYNC_FLUSH

        let body = compressBody(compressor: &compressor, allocator: allocator, flag: flag)
        if let bodyLength = body?.readableBytes, isCompleteResponse && bodyLength > 0 {
            head!.headers.remove(name: "transfer-encoding")
            head!.headers.replaceOrAdd(name: "content-length", value: "\(bodyLength)")
        } else if head != nil && head!.status.mayHaveResponseBody {
            head!.headers.remove(name: "content-length")
            head!.headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")
        }

        let response = (head, body, end)
        clear()
        return response
    }
}

private extension z_stream {
    /// Executes deflate from one buffer to another buffer. The advantage of this method is that it
    /// will ensure that the stream is "safe" after each call (that is, that the stream does not have
    /// pointers to byte buffers any longer).
    mutating func oneShotDeflate(from: inout ByteBuffer, to: inout ByteBuffer, flag: Int32) {
        defer {
            self.avail_in = 0
            self.next_in = nil
            self.avail_out = 0
            self.next_out = nil
        }

        _ = from.readWithUnsafeMutableReadableBytes { dataPtr in
            let typedPtr = dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let typedDataPtr = UnsafeMutableBufferPointer(start: typedPtr,
                                                          count: dataPtr.count)

            self.avail_in = UInt32(typedDataPtr.count)
            self.next_in = typedDataPtr.baseAddress!

            let rc = deflateToBuffer(buffer: &to, flag: flag)
            precondition(rc == Z_OK || rc == Z_STREAM_END, "One-shot compression failed: \(rc)")

            return typedDataPtr.count - Int(self.avail_in)
        }
    }

    /// A private function that sets the deflate target buffer and then calls deflate.
    /// This relies on having the input set by the previous caller: it will use whatever input was
    /// configured.
    private mutating func deflateToBuffer(buffer: inout ByteBuffer, flag: Int32) -> Int32 {
        var rc = Z_OK

        _ = buffer.writeWithUnsafeMutableBytes { outputPtr in
            let typedOutputPtr = UnsafeMutableBufferPointer(start: outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                            count: outputPtr.count)
            self.avail_out = UInt32(typedOutputPtr.count)
            self.next_out = typedOutputPtr.baseAddress!
            rc = deflate(&self, flag)
            return typedOutputPtr.count - Int(self.avail_out)
        }

        return rc
    }
}
