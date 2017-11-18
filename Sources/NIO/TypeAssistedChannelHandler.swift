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

public protocol _EmittingChannelHandler {
    associatedtype OutboundOut = Never
    
    func wrapOutboundOut(_ value: OutboundOut) -> NIOAny
}

extension _EmittingChannelHandler {
    public func wrapOutboundOut(_ value: OutboundOut) -> NIOAny {
        return NIOAny(value)
    }
}

public protocol ChannelInboundHandler: _ChannelInboundHandler, _EmittingChannelHandler {
    associatedtype InboundIn
    associatedtype InboundUserEventIn = Never

    associatedtype InboundOut = Never
    associatedtype OutboundUserEventOut = Never
    associatedtype InboundUserEventOut = Never

    func unwrapInboundIn(_ value: NIOAny) -> InboundIn
    func tryUnwrapInboundIn(_ value: NIOAny) -> InboundIn?
    func wrapInboundOut(_ value: InboundOut) -> NIOAny
    func unwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn
    func tryUnwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn?
    func wrapInboundUserEventOut(_ value: InboundUserEventOut) -> Any
}

extension ChannelInboundHandler {
    public func unwrapInboundIn(_ value: NIOAny) -> InboundIn {
        return value.forceAs()
    }

    public func tryUnwrapInboundIn(_ value: NIOAny) -> InboundIn? {
        return value.tryAs()
    }

    public func wrapInboundOut(_ value: InboundOut) -> NIOAny {
        return NIOAny(value)
    }

    public func unwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn {
        return value as! InboundUserEventIn
    }

    public func tryUnwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn? {
        return value as? InboundUserEventIn
    }

    public func wrapInboundUserEventOut(_ value: InboundUserEventOut) -> Any {
        return value
    }
}

public protocol ChannelOutboundHandler: _ChannelOutboundHandler, _EmittingChannelHandler {
    associatedtype OutboundIn
    associatedtype OutboundUserEventIn = Never

    associatedtype InboundOut = Never
    associatedtype OutboundUserEventOut = Never
    associatedtype InboundUserEventOut = Never

    func unwrapOutboundIn(_ value: NIOAny) -> OutboundIn
    func tryUnwrapOutboundIn(_ value: NIOAny) -> OutboundIn?

    func unwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn
    func tryUnwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn?
    func wrapOutboundUserEventOut(_ value: OutboundUserEventOut) -> Any
}

extension ChannelOutboundHandler {
    public func unwrapOutboundIn(_ value: NIOAny) -> OutboundIn {
        return value.forceAs()
    }

    public func tryUnwrapOutboundIn(_ value: NIOAny) -> OutboundIn? {
        return value.tryAs()
    }

    public func unwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn {
        return value as! OutboundUserEventIn
    }

    public func tryUnwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn? {
        return value as? OutboundUserEventIn
    }

    public func wrapOutboundUserEventOut(_ value: OutboundUserEventOut) -> Any {
        return value
    }
}
