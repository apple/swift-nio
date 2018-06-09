//
//  LineBasedFrameDecoder.swift
//  NIO
//
//  Created by Edward Arenberg on 6/8/18.
//

/// An inbound `ChannelHandler` that strips newlines from an inbound stream.
///
/// I added my LineBasedFrameDecoder into the channel.pipeline of the NIOEchoServer (main.swift)
/// Finding a crash in the creation of the ByteBufferView:
///
///  ByteBuffer generates its readableBytesView:
///   public var readableBytesView: ByteBufferView {
///     return ByteBufferView(buffer: self, range: self.readerIndex ..< self.readerIndex + self.readableBytes)
///   }
///
///  ByteBufferView init fails the precondition below.
///  range = 0..<N   range.upperBounds == N   buffer.capacity == N
///   internal init(buffer: ByteBuffer, range: Range<Index>) {
///     precondition(range.lowerBound >= 0 && range.upperBound < buffer.capacity)
///     self.buffer = buffer
///     self.range = range
///   }
///
///


public final class LineBasedFrameDecoder : ByteToMessageDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    
    public var cumulationBuffer: ByteBuffer?

    public init() { }
        
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
        let newLine = "\n".utf8.first!
        
        if let idx = buffer.readableBytesView.firstIndex(of: newLine) {
            if let buf = buffer.readSlice(length: idx) {
                ctx.fireChannelRead(self.wrapInboundOut(buf))
                buffer.moveReaderIndex(forwardBy: 1)    // Skip newline
                return .continue
            }
        }
        
        return .needMoreData
    }
}
