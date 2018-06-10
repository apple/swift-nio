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

public final class LengthFieldBasedFrameDecoder<T: FixedWidthInteger>: ByteToMessageDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    
    public var cumulationBuffer: ByteBuffer?
    
    private var state: State = .len
    
    enum State {
        case len
        case data(Int)
    }
    
    public init() { }
    
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
        switch state {
        case .len:
            guard let integer = buffer.readInteger(as: T.self) else {
                return .needMoreData
            }
            state = .data(Int(integer))
            return .continue
        case .data(let dataLength):
            guard let bytes = buffer.readSlice(length: dataLength) else {
                return .needMoreData
            }
            ctx.fireChannelRead(self.wrapInboundOut(bytes))
            state = .len
            return .continue
        }
    }
}
