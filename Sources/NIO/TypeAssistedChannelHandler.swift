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
    associatedtype InboundOut = Never

    func unwrapInboundIn(_ value: NIOAny) -> InboundIn
    func wrapInboundOut(_ value: InboundOut) -> NIOAny
}

extension ChannelInboundHandler {
    public func unwrapInboundIn(_ value: NIOAny) -> InboundIn {
        return value.forceAs()
    }

    public func wrapInboundOut(_ value: InboundOut) -> NIOAny {
        return NIOAny(value)
    }
}

public protocol ChannelOutboundHandler: _ChannelOutboundHandler, _EmittingChannelHandler {
    associatedtype OutboundIn
    associatedtype InboundOut = Never

    func unwrapOutboundIn(_ value: NIOAny) -> OutboundIn
}

extension ChannelOutboundHandler {
    public func unwrapOutboundIn(_ value: NIOAny) -> OutboundIn {
        return value.forceAs()
    }
}
