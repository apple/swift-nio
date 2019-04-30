//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//


/// A `ChannelInboundHandler` that closes the channel when an error is caught
public final class NIOCloseOnErrorHandler: ChannelInboundHandler {

    public typealias InboundIn = NIOAny
    
    /// Initialize a `NIOCloseOnErrorHandler`
    public init() {}
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
