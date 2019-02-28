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

/// ChannelHandler which will emit data by calling `ChannelHandlerContext.write`.
///
/// We _strongly_ advice against implementing this protocol directly. Please implement `ChannelInboundHandler` or / and `ChannelOutboundHandler`.
public protocol _EmittingChannelHandler {
    /// The type of the outbound data which will be forwarded to the next `ChannelOutboundHandler` in the `ChannelPipeline`.
    associatedtype OutboundOut = Never

    /// Wrap the provided `OutboundOut` that will be passed to the next `ChannelOutboundHandler` by calling `ChannelHandlerContext.write`.
    @inlinable
    func wrapOutboundOut(_ value: OutboundOut) -> NIOAny
}

/// Default implementations for `_EmittingChannelHandler`.
extension _EmittingChannelHandler {
    @inlinable
    public func wrapOutboundOut(_ value: OutboundOut) -> NIOAny {
        return NIOAny(value)
    }
}

///  `ChannelHandler` which handles inbound I/O events for a `Channel`.
///
/// Please refer to `_ChannelInboundHandler` and `_EmittingChannelHandler` for more details on the provided methods.
public protocol ChannelInboundHandler: _ChannelInboundHandler, _EmittingChannelHandler {
    /// The type of the inbound data which is wrapped in `NIOAny`.
    associatedtype InboundIn

    /// The type of the inbound data which will be forwarded to the next `ChannelInboundHandler` in the `ChannelPipeline`.
    associatedtype InboundOut = Never

    /// Unwrap the provided `NIOAny` that was passed to `channelRead`.
    @inlinable
    func unwrapInboundIn(_ value: NIOAny) -> InboundIn

    /// Wrap the provided `InboundOut` that will be passed to the next `ChannelInboundHandler` by calling `ChannelHandlerContext.fireChannelRead`.
    @inlinable
    func wrapInboundOut(_ value: InboundOut) -> NIOAny
}

/// Default implementations for `ChannelInboundHandler`.
extension ChannelInboundHandler {
    @inlinable
    public func unwrapInboundIn(_ value: NIOAny) -> InboundIn {
        return value.forceAs()
    }

    @inlinable
    public func wrapInboundOut(_ value: InboundOut) -> NIOAny {
        return NIOAny(value)
    }
}

/// `ChannelHandler` which handles outbound I/O events or intercept an outbound I/O operation for a `Channel`.
///
/// Please refer to `_ChannelOutboundHandler` and `_EmittingChannelHandler` for more details on the provided methods.
public protocol ChannelOutboundHandler: _ChannelOutboundHandler, _EmittingChannelHandler {
    /// The type of the outbound data which is wrapped in `NIOAny`.
    associatedtype OutboundIn

    /// Unwrap the provided `NIOAny` that was passed to `write`.
    @inlinable
    func unwrapOutboundIn(_ value: NIOAny) -> OutboundIn
}

/// Default implementations for `ChannelOutboundHandler`.
extension ChannelOutboundHandler {
    @inlinable
    public func unwrapOutboundIn(_ value: NIOAny) -> OutboundIn {
        return value.forceAs()
    }
}

/// A combination of `ChannelInboundHandler` and `ChannelOutboundHandler`.
public typealias ChannelDuplexHandler = ChannelInboundHandler & ChannelOutboundHandler
